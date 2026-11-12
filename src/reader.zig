const std = @import("std");
const logger = @import("logger.zig");
const inventory = @import("inventory.zig");
const Tag = inventory.Tag;
const App = @import("server.zig").App;
const mutex = @import("mutex.zig");

// C interface of the shim (src/fedm_shim.h). On linux the shim is
// compiled into the exe; on windows it is feigshim.dll (MSVC-ABI, plain
// C boundary - no C++ objects cross it).

const FedmTag = extern struct {
    iddHex: [17]u8, // 8-byte UID as 16 hex chars, null-terminated
    trType: c_int,
    dsfid: c_int, // -1 if not available
};

const FedmBleItem = extern struct {
    mac: [32]u8,
    deviceId: [16]u8,
    readerType: [64]u8,
    state: c_int, // 1 = new reader, -1 = reader gone
};

const FedmUsbItem = extern struct {
    deviceId: [16]u8,
    readerType: [64]u8,
    state: c_int,
};

extern "C" fn fedm_lib_version(buf: [*c]u8, len: c_int) c_int;
extern "C" fn fedm_connect_usb() c_int;
extern "C" fn fedm_connect_tcp(host: [*c]const u8, port: c_int) c_int;
extern "C" fn fedm_connect_com(port: [*c]const u8, frame: [*c]const u8, baud: c_int) c_int;
extern "C" fn fedm_connect_ble(mac: [*c]const u8) c_int;
extern "C" fn fedm_disconnect() void;
extern "C" fn fedm_is_connected() c_int;
extern "C" fn fedm_reader_serial(buf: [*c]u8, len: c_int) c_int;
extern "C" fn fedm_reader_name(buf: [*c]u8, len: c_int) c_int;
extern "C" fn fedm_reader_fwversion(buf: [*c]u8, len: c_int) c_int;
extern "C" fn fedm_last_error_text(buf: [*c]u8, len: c_int) c_int;
extern "C" fn fedm_last_status_text(buf: [*c]u8, len: c_int) c_int;
extern "C" fn fedm_inventory(out: [*c]FedmTag, max_tags: c_int) c_int;
extern "C" fn fedm_tag_read(idd: [*c]const u8, idd_len: c_int, out: [*c]u8, out_len: c_int) c_int;
extern "C" fn fedm_tag_write(idd: [*c]const u8, idd_len: c_int, data: [*c]const u8, data_len: c_int) c_int;
extern "C" fn fedm_tag_write_afi(afi: u8) c_int;
extern "C" fn fedm_tag_reset_to_ready() c_int;
extern "C" fn fedm_tag_stay_quiet() c_int;
extern "C" fn fedm_ble_start_discover() c_int;
extern "C" fn fedm_ble_stop_discover() c_int;
extern "C" fn fedm_ble_reader_count() c_int;
extern "C" fn fedm_ble_pop(out: [*c]FedmBleItem) c_int;
extern "C" fn fedm_ble_last_error(buf: [*c]u8, len: c_int) c_int;
extern "C" fn fedm_usb_start_discover() c_int;
extern "C" fn fedm_usb_stop_discover() c_int;
extern "C" fn fedm_usb_reader_count() c_int;
extern "C" fn fedm_usb_pop(out: [*c]FedmUsbItem) c_int;

pub const ReaderError = error{
    ConnectFailed,
    TagNotFound,
    WrongContentLength,
    TagReadFailed,
    TagWriteFailed,
    AfiWriteFailed,
    BleStartFailed,
    BleStopFailed,
    NotConnected,
};

pub const BleItem = struct {
    mac: []const u8,
    device_id: []const u8,
    reader_type: []const u8,
    is_new: bool,

    pub fn json(self: *const BleItem, w: anytype) !void {
        try w.writeByte('{');
        try w.write("\"mac\":");
        try inventory.jsonEscapeString(w, self.mac);
        try w.write(",\"deviceId\":");
        try inventory.jsonEscapeString(w, self.device_id);
        try w.write(",\"readerType\":");
        try inventory.jsonEscapeString(w, self.reader_type);
        try w.print(",\"new\":{s}", .{ if (self.is_new) "true" else "false" });
        try w.writeByte('}');
    }

    pub fn free(self: *const BleItem, alloc: std.mem.Allocator) void {
        alloc.free(self.mac);
        alloc.free(self.device_id);
        alloc.free(self.reader_type);
    }
};

// One cumulative BLE discovery entry (fixed buffers; mac is the dedupe key)
const BleSeen = struct {
    mac: [32]u8,
    device_id: [16]u8,
    reader_type: [64]u8,
    is_new: bool,
};
const maxBleSeen = 64;

// pluginLoadHint annotates SDK errors where one of the on-demand transport
// plugins failed to load. The BLE plugin (libfeble.so) is not part of the
// FEDM SDK 7.1.0 linux package.
pub fn pluginLoadHint(alloc: std.mem.Allocator, s: []const u8) []const u8 {
    if (std.mem.indexOf(u8, s, "Cannot load plugin")) |_| {
        return std.fmt.allocPrint(alloc, "{s} (missing FEBLE plugin library libfeble.so - not included in the FEDM SDK 7.1.0 linux package, obtain from FEIG)", .{s}) catch s;
    }
    return s;
}

const maxTagsPerInventory = 256;
// Raw tag content buffer: must cover the largest registered tag
// standard (inventory.current.contentLen).
const tagContentBytes = 36; // 9 blocks x 4 bytes

// Reader wraps the FEIG FEDM SDK (via the shim). All methods take the
// reader mutex internally; the do* helpers assume the lock is held.
pub const Reader = struct {
    const Self = @This();

    alloc: std.mem.Allocator,
    io: std.Io,
    mu: mutex.Mutex = .{},
    connected: bool = false,
    conn_type: []const u8 = "", // "usb" | "tcp" | "com" | "ble"
    serial: []const u8 = "", // reader device ID (hex)
    name: []const u8 = "", // reader type
    fw_version: []const u8 = "",
    lib_version: []const u8 = "",
    last_err: []const u8 = "",
    // Plain u64s: every mutation happens under self.mu (or app.mu), so no
    // atomics needed. json() reads them unlocked, which is fine on x86 for
    // aligned u64s (no tearing).
    read_inv_fail: u64 = 0,
    read_inv_succ: u64 = 0,
    read_tag_fail: u64 = 0,
    read_tag_succ: u64 = 0,
    write_tag_succ: u64 = 0,
    write_tag_fail: u64 = 0,
    write_afi_succ: u64 = 0,
    write_afi_fail: u64 = 0,
    // cumulative BLE discovery results, see bleList
    ble_seen: [maxBleSeen]BleSeen = undefined,
    ble_seen_count: usize = 0,

    pub fn init(alloc: std.mem.Allocator, io: std.Io) Self {
        var r: Self = .{ .alloc = alloc, .io = io };
        r.mu.init();
        var buf: [256]u8 = undefined;
        _ = fedm_lib_version(&buf[0], buf.len);
        r.lib_version = alloc.dupe(u8, std.mem.sliceTo(buf[0..], 0)) catch "";
        return r;
    }

    pub fn json(self: *const Self, w: anytype) !void {
        try w.writeByte('{');
        try w.print("\"Connected\":{s},", .{ if (self.connected) "true" else "false" });
        try w.write("\"ConnType\":");
        try inventory.jsonEscapeString(w, self.conn_type);
        try w.write(",\"Serial\":");
        try inventory.jsonEscapeString(w, self.serial);
        try w.write(",\"Name\":");
        try inventory.jsonEscapeString(w, self.name);
        try w.write(",\"FwVersion\":");
        try inventory.jsonEscapeString(w, self.fw_version);
        try w.write(",\"LibVersion\":");
        try inventory.jsonEscapeString(w, self.lib_version);
        try w.print(",\"ReadInvFail\":{d},", .{self.read_inv_fail});
        try w.print("\"ReadInvSucc\":{d},", .{self.read_inv_succ});
        try w.print("\"ReadTagFail\":{d},", .{self.read_tag_fail});
        try w.print("\"ReadTagSucc\":{d},", .{self.read_tag_succ});
        try w.print("\"WriteTagSucc\":{d},", .{self.write_tag_succ});
        try w.print("\"WriteTagFail\":{d},", .{self.write_tag_fail});
        try w.print("\"WriteAFISucc\":{d},", .{self.write_afi_succ});
        try w.print("\"WriteAFIFail\":{d}", .{self.write_afi_fail});
        try w.writeByte('}');
    }

    // Last library error / reader status text (allocates from self.alloc)
    pub fn errorText(self: *Self) []const u8 {
        var buf: [256]u8 = undefined;
        _ = fedm_last_error_text(&buf[0], buf.len);
        return self.alloc.dupe(u8, std.mem.sliceTo(buf[0..], 0)) catch "unknown error";
    }

    // CONNECTION

    fn connect(self: *Self, kind: []const u8, ret: c_int) ReaderError!void {
        self.mu.lock(self.io) catch return error.ConnectFailed;
        defer self.mu.unlock(self.io);
        if (ret != 0) {
            self.last_err = self.errorText();
            return error.ConnectFailed;
        }
        self.connected = true;
        self.conn_type = kind;
        var buf: [256]u8 = undefined;
        _ = fedm_reader_serial(&buf[0], buf.len);
        self.serial = self.alloc.dupe(u8, std.mem.sliceTo(buf[0..], 0)) catch "";
        _ = fedm_reader_name(&buf[0], buf.len);
        self.name = self.alloc.dupe(u8, std.mem.sliceTo(buf[0..], 0)) catch "";
        _ = fedm_reader_fwversion(&buf[0], buf.len);
        self.fw_version = self.alloc.dupe(u8, std.mem.sliceTo(buf[0..], 0)) catch "";
    }

    // ConnectUsb scans for a plugged USB reader and connects to the first one found
    pub fn connectUsb(self: *Self) ReaderError!void {
        try self.connect("usb", fedm_connect_usb());
    }

    pub fn connectTcp(self: *Self, host: []const u8, port: u16) ReaderError!void {
        const c = self.alloc.dupeZ(u8, host) catch return error.ConnectFailed;
        defer self.alloc.free(c);
        try self.connect("tcp", fedm_connect_tcp(c, @intCast(port)));
    }

    // ConnectCom connects to a reader on a serial COM port (frame: 8E1 | 8N1 | 8O1)
    pub fn connectCom(self: *Self, port: []const u8, frame: []const u8, baud: u32) ReaderError!void {
        const cp = self.alloc.dupeZ(u8, port) catch return error.ConnectFailed;
        defer self.alloc.free(cp);
        const cf = self.alloc.dupeZ(u8, frame) catch return error.ConnectFailed;
        defer self.alloc.free(cf);
        try self.connect("com", fedm_connect_com(cp, cf, @intCast(baud)));
    }

    // ConnectBle connects to a reader over Bluetooth Low Energy using its MAC address
    pub fn connectBle(self: *Self, mac: []const u8) ReaderError!void {
        const cm = self.alloc.dupeZ(u8, mac) catch return error.ConnectFailed;
        defer self.alloc.free(cm);
        try self.connect("ble", fedm_connect_ble(cm));
    }

    // ReadTagsInRange reads the inventory and content of all new tags in range.
    // The current inventory is kept and tags out of range are removed.
    pub fn readTagsInRange(self: *Self, app: *App) void {
        self.mu.lock(self.io) catch return;
        defer self.mu.unlock(self.io);
        if (!self.connected) return;

        var buf: [maxTagsPerInventory]FedmTag = undefined;
        const n = fedm_inventory(&buf[0], buf.len);
        if (n < 0) {
            const txt = self.errorText();
            logger.debugPrint("ERROR READING INVENTORY: {s}", .{txt});
            self.read_inv_fail += 1;
            return;
        }
        self.read_inv_succ += 1;

        var tags: std.AutoHashMap([8]u8, Tag) = .init(app.gpa);
        for (0..@as(usize, @intCast(n))) |i| {
            const hexs = std.mem.sliceTo(buf[i].iddHex[0..], 0);
            // Same tolerance as the go version: any non-empty even-length
            // hex string; ids shorter than 8 bytes are zero-padded.
            if (hexs.len == 0 or hexs.len % 2 != 0 or hexs.len > 16) continue;
            var id: [8]u8 = .{ 0 } ** 8;
            inventory.hexDecode(&id, hexs) catch continue;
            const mac = inventory.tagIdToMac(app.gpa, id) catch continue;
            const t = Tag{
                .trtype = @intCast(buf[i].trType),
                .dfsid = @intCast(if (buf[i].dsfid < 0) 0 else @as(u16, @intCast(buf[i].dsfid))),
                .id = id,
                .mac = mac,
            };
            tags.put(id, t) catch continue;
        }
        defer tags.deinit();

        if (app.keep_transponders_awake) {
            doResetToReady() catch |err| logger.debugPrint("ERROR RESET TO READY: {}", .{err});
        }

        app.processInventory(&tags);
    }

    // doReadTagContent reads data blocks 0..8 (36 bytes) of the given tag.
    // Assumes self.mu is held.
    pub fn doReadTagContent(self: *Self, id: *[8]u8) ![]u8 {
        var out: [tagContentBytes]u8 = undefined;
        const n = fedm_tag_read(&id[0], 8, &out[0], out.len);
        if (n < 0) {
            const txt = self.errorText();
            logger.debugPrint("TAG READ: {s}", .{txt});
            return error.TagReadFailed;
        }
        return self.alloc.dupe(u8, out[0..@as(usize, @intCast(n))]);
    }

    // doWriteTagContent writes blocks 0..8 of the given tag, a few retries
    // (BLE and busy readers can be flaky). Assumes self.mu is held.
    fn doWriteTagContent(self: *Self, id: *[8]u8, data: []const u8) !void {
        for (0..3) |attempt| {
            if (attempt > 0) self.io.sleep(std.Io.Duration.fromMilliseconds(100), .real) catch return error.TagWriteFailed;
            const ret = fedm_tag_write(&id[0], 8, data.ptr, @intCast(data.len));
            if (ret >= 0) return;
        }
        const txt = self.errorText();
        logger.debugPrint("TAG WRITE: {s}", .{txt});
        return error.TagWriteFailed;
    }

    // doResetToReady performs a non-addressed (broadcast) reset to ready.
    // Assumes the caller holds the reader mutex.
    fn doResetToReady() !void {
        if (fedm_tag_reset_to_ready() < 0) return error.TagWriteFailed;
    }

    // WriteTagBarcode overwrites the barcode on a single tag in the current inventory
    pub fn writeTagBarcode(self: *Self, app: *App, tag_id: []const u8, barcode: []const u8) !Tag {
        var tag: Tag = undefined;
        {
            app.mu.lock(app.io) catch return error.LockFailed;
            defer app.mu.unlock(app.io);
            const g = app.inventory.get(tag_id) orelse return error.TagNotFound;
            tag = if (@TypeOf(g) == Tag) g else g.*;
        }
        self.mu.lock(self.io) catch return error.LockFailed;
        defer self.mu.unlock(self.io);
        tag.content.barcode = barcode;
        const bs = try inventory.current.encode(&tag.content, self.alloc);
        defer self.alloc.free(bs);
        if (bs.len != inventory.current.contentLen) return error.WrongContentLength;
        try self.doWriteTagContent(&tag.id, bs);
        self.write_tag_succ += 1;
        app.mu.lock(app.io) catch {};
        defer app.mu.unlock(app.io);
        app.inventory.put(tag_id, tag) catch {};
        return tag;
    }

    // WriteToTagsInRange writes the barcode (with sequence number and total
    // count) to all tags in the current inventory
    pub fn writeToTagsInRange(self: *Self, app: *App, barcode: []const u8) !void {
        // Snapshot the current inventory (map is not safe to iterate while
        // we write tags back into it)
        var ids: [maxTagsPerInventory][]const u8 = undefined;
        var tags: [maxTagsPerInventory]Tag = undefined;
        var l: usize = 0;
        app.mu.lock(app.io) catch return error.LockFailed;
        var it = app.inventory.iterator();
        while (it.next()) |entry| {
            const id = entry.value_ptr.id;
            const g = app.inventory.get(&id) orelse continue;
            if (l >= maxTagsPerInventory) break;
            ids[l] = &id;
            tags[l] = g;
            l += 1;
        }
        app.mu.unlock(app.io);

        var c: u32 = 0;
        for (0..l) |i| {
            c += 1;
            tags[i].content = .{
                .seq_num = @truncate(c),
                .num_items = @truncate(l),
                .barcode = barcode,
                .country = "NO", // hard coded for now
                .library = app.library,
            };
            const bs = try inventory.current.encode(&tags[i].content, self.alloc);
            self.mu.lock(self.io) catch {
                self.alloc.free(bs);
                return error.LockFailed;
            };
            const res = self.doWriteTagContent(&tags[i].id, bs);
            self.mu.unlock(self.io);
            self.alloc.free(bs);
            if (res) |_| {
                self.write_tag_succ += 1;
                app.mu.lock(app.io) catch {};
                app.inventory.put(ids[i], tags[i]) catch {};
                app.mu.unlock(app.io);
            } else |err| {
                self.write_tag_fail += 1;
                logger.debugPrint("ERROR WRITING INVENTORY: {}", .{err});
                return err;
            }
        }
    }

    // WriteAFI turns the AFI alarm on or off on all tags in range (broadcast)
    pub fn writeAFI(self: *Self, afi: u8) !void {
        self.mu.lock(self.io) catch return error.AfiWriteFailed;
        defer self.mu.unlock(self.io);
        for (0..3) |attempt| {
            if (attempt > 0) self.io.sleep(std.Io.Duration.fromMilliseconds(50), .real) catch return error.AfiWriteFailed;
            if (fedm_tag_write_afi(afi) >= 0) {
                self.write_afi_succ += 1;
                return;
            }
        }
        const txt = self.errorText();
        logger.debugPrint("AFI WRITE: {s}", .{txt});
        self.write_afi_fail += 1;
        return error.AfiWriteFailed;
    }

    // BLE DISCOVERY

    // BleStartDiscover starts the Bluetooth LE discovery, idempotent
    pub fn bleStartDiscover(self: *Self) error{BleStartFailed}!void {
        self.mu.lock(self.io) catch return error.BleStartFailed;
        defer self.mu.unlock(self.io);
        if (fedm_ble_start_discover() == 0) return;
        var buf: [256]u8 = undefined;
        _ = fedm_ble_last_error(&buf[0], buf.len);
        self.last_err = self.alloc.dupe(u8, std.mem.sliceTo(buf[0..], 0)) catch "ble start failed";
        return error.BleStartFailed;
    }

    pub fn bleStopDiscover(self: *Self) error{BleStopFailed}!void {
        self.mu.lock(self.io) catch return error.BleStopFailed;
        defer self.mu.unlock(self.io);
        if (fedm_ble_stop_discover() == 0) return;
        var buf: [256]u8 = undefined;
        _ = fedm_ble_last_error(&buf[0], buf.len);
        self.last_err = self.alloc.dupe(u8, std.mem.sliceTo(buf[0..], 0)) catch "ble stop failed";
        return error.BleStopFailed;
    }

    // BleList drains the BLE discovery queue into the cumulative list
    // and returns the readers seen so far (the queue is consumed on
    // every poll, so without accumulation the list would be empty on
    // every poll after the first)
    pub fn bleList(self: *Self) ![]BleItem {
        const n = @as(usize, @intCast(@max(fedm_ble_reader_count(), 0)));
        var i: usize = 0;
        while (i < n) : (i += 1) {
            var it: FedmBleItem = undefined;
            if (fedm_ble_pop(&it) != 0) break;
            self.bleSeenAdd(&it);
        }
        var items = try self.alloc.alloc(BleItem, self.ble_seen_count);
        errdefer self.alloc.free(items);
        var k: usize = 0;
        while (k < self.ble_seen_count) : (k += 1) {
            const seen = self.ble_seen[k];
            items[k] = .{
                .mac = self.alloc.dupe(u8, std.mem.sliceTo(seen.mac[0..], 0)) catch return error.BleStopFailed,
                .device_id = self.alloc.dupe(u8, std.mem.sliceTo(seen.device_id[0..], 0)) catch return error.BleStopFailed,
                .reader_type = self.alloc.dupe(u8, std.mem.sliceTo(seen.reader_type[0..], 0)) catch return error.BleStopFailed,
                .is_new = seen.is_new,
            };
        }
        return items;
    }

    // Merge one popped discovery result into the cumulative list:
    // dedupe by mac, "gone" (state -1) removes the entry
    fn bleSeenAdd(self: *Self, it: *const FedmBleItem) void {
        const mac = std.mem.sliceTo(it.mac[0..], 0);
        var idx: ?usize = null;
        var k: usize = 0;
        while (k < self.ble_seen_count) : (k += 1) {
            if (std.mem.eql(u8, std.mem.sliceTo(self.ble_seen[k].mac[0..], 0), mac)) {
                idx = k;
                break;
            }
        }
        if (it.state == -1) {
            if (idx) |i| {
                self.ble_seen[i] = self.ble_seen[self.ble_seen_count - 1];
                self.ble_seen_count -= 1;
            }
            return;
        }
        if (idx) |i| {
            self.bleSeenCopy(i, it);
            return;
        }
        if (self.ble_seen_count >= maxBleSeen) return; // full: skip
        self.bleSeenCopy(self.ble_seen_count, it);
        self.ble_seen_count += 1;
    }

    fn bleSeenCopy(self: *Self, idx: usize, it: *const FedmBleItem) void {
        const dst = &self.ble_seen[idx];
        const nm = std.mem.sliceTo(it.mac[0..], 0).len;
        @memcpy(dst.mac[0..nm], it.mac[0..nm]);
        dst.mac[nm] = 0;
        const nd = std.mem.sliceTo(it.deviceId[0..], 0).len;
        @memcpy(dst.device_id[0..nd], it.deviceId[0..nd]);
        dst.device_id[nd] = 0;
        const nt = std.mem.sliceTo(it.readerType[0..], 0).len;
        @memcpy(dst.reader_type[0..nt], it.readerType[0..nt]);
        dst.reader_type[nt] = 0;
        dst.is_new = it.state == 1;
    }
};
