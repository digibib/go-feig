const std = @import("std");
const logger = @import("logger.zig");
const inventory = @import("inventory.zig");
const mutex = @import("mutex.zig");
const Tag = inventory.Tag;
const reader_mod = @import("reader.zig");
const http = std.http;

// Raw socket syscalls for the SSE delivery thread (linux): std.Io's
// net writes only work on the main thread, so subscriber sockets are
// driven directly with write(2)/close(2); SO_NOSIGNAL keeps a client
// going away from raising SIGPIPE. On other OSes the dispatchers
// below degrade to failure stubs, so SSE delivery is disabled there
// (a subscriber is closed on its first failed write); port to
// Winsock send() when /events/ is needed on windows.
//
// Declared under their plain C names: this build's extern has no
// separate symbol-name syntax, the identifier IS the symbol. The
// platform dispatch is a plain if on a comptime-known const - a
// top-level `comptime if` does not parse in this build. The dead
// branch is eliminated, so the unused platform's externs are never
// referenced and never linked.
const is_linux = @import("builtin").os.tag == .linux;
extern fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern fn close(fd: c_int) c_int;
extern fn setsockopt(fd: c_int, level: c_int, optname: c_int, optval: *const anyopaque, optlen: c_uint) c_int;

fn sockWrite(fd: c_int, buf: [*]const u8, count: usize) isize {
    if (is_linux) {
        return write(fd, buf, count);
    } else {
        // SSE delivery is disabled on this OS
        return -1;
    }
}

fn sockClose(fd: c_int) c_int {
    if (is_linux) {
        return close(fd);
    } else {
        // SSE delivery is disabled on this OS
        return 0;
    }
}

// write(2) may return short or be interrupted; a bounded retry
// survives EINTR, any persistent error means the peer is gone.
fn rawWriteAll(fd: c_int, data: []const u8) bool {
    var off: usize = 0;
    while (off < data.len) {
        var tries: u8 = 0;
        while (true) {
            const n = sockWrite(fd, data[off..].ptr, data.len - off);
            if (n >= 0) {
                off += @as(usize, @intCast(n));
                break;
            }
            tries += 1;
            if (tries >= 3) return false;
        }
    }
    return true;
}

pub const VERSION = "2.0.0";

// Keep reader state for sanity (port of modeType)
pub const Mode = enum {
    idle,
    read,
    read_once,
    write,
    write_afi,
    scan,

    pub fn str(self: Mode) []const u8 {
        return switch (self) {
            .idle => "IDLE",
            .read => "READ",
            .read_once => "READONCE",
            .write => "WRITE",
            .write_afi => "WRITEAFI",
            .scan => "SCAN",
        };
    }
};

// An event pushed to connected EventSource clients
pub const BroadcastMsg = struct {
    event: []u8,
    data: []u8,
};

// Per-subscriber event queue (drop-newest when the subscriber falls
// too far behind). Shared between the reader thread (broadcast) and
// the delivery thread under App.sse_mu.
const RingSize = 64;
const Ring = struct {
    items: [RingSize]?*BroadcastMsg = nullItems(),
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,

    fn nullItems() [RingSize]?*BroadcastMsg {
        var r: [RingSize]?*BroadcastMsg = undefined;
        var i: usize = 0;
        while (i < RingSize) : (i += 1) r[i] = null;
        return r;
    }

    fn push(self: *Ring, m: *BroadcastMsg) bool {
        if (self.count == RingSize) return false;
        self.items[self.head % RingSize] = m;
        self.head += 1;
        self.count += 1;
        return true;
    }

    fn pop(self: *Ring) ?*BroadcastMsg {
        if (self.count == 0) return null;
        const m = self.items[self.tail % RingSize] orelse return null;
        self.items[self.tail % RingSize] = null;
        self.tail += 1;
        self.count -= 1;
        return m;
    }

};

// State for one connected /events/ subscriber. sent/last_write and
// the fd belong to the delivery thread (single writer and closer);
// the queue is shared with broadcast() under sse_mu.
pub const Subscriber = struct {
    fd: c_int,
    queue: Ring = .{},
    sent: bool = false,
    closing: bool = false,
    last_write: i96 = 0,
    canary: u64 = SSE_CANARY,
};

const SSE_CANARY: u64 = 0xA5A5A5A55A5A5A5A;

// A pointer value is "canonical" when its top 16 bits are all equal;
// anything else (JSON text, a small integer, a length reinterpreted as
// a pointer) faults with #GP - no address - on dereference.
fn canonical(va: u64) bool {
    const hi = va >> 47;
    return hi == 0 or hi == 0x1FFFF;
}

// Dump the subscriber canary and queue to stderr; the slot contents
// fingerprint whatever clobbered the memory.
fn dumpSelf(s: *Subscriber, where: []const u8) void {
    std.debug.print("{s}: canary=0x{X:0>16} sent={any} closing={any}\n", .{ where, s.canary, s.sent, s.closing });
    std.debug.print("  queue head={d} tail={d} count={d}\n", .{ s.queue.head, s.queue.tail, s.queue.count });
    var i: usize = 0;
    while (i < RingSize) : (i += 1) {
        if (s.queue.items[i]) |m| {
            const va = @intFromPtr(m);
            std.debug.print("  slot[{d}] 0x{X:0>16} {s}\n", .{ i, va, if (canonical(va)) "ok" else "BAD" });
        } else {
            std.debug.print("  slot[{d}] null\n", .{i});
        }
    }
}

// The UI file (src/assets/index.html) is embedded
const Html = @embedFile("assets/index.html");

// A pending HTTP response (std.http responses are one-shot; SSE
// streams raw, bypassing this).
const Resp = struct {
    self: *App,
    req: *http.Server.Request,

    fn send(r: *const Resp, code: u16, ct: []const u8, body: []const u8) !void {
        // CORS, same set as the Go server
        var hdrs: [7]http.Header = undefined;
        hdrs[0] = .{ .name = "Content-Type", .value = ct };
        hdrs[1] = .{ .name = "Access-Control-Allow-Origin", .value = "*" };
        hdrs[2] = .{ .name = "Access-Control-Allow-Methods", .value = "GET, POST, OPTIONS, PUT, DELETE" };
        hdrs[3] = .{ .name = "Access-Control-Allow-Headers", .value = "Content-Type, Access-Control-Allow-Headers, Authorization, X-Requested-With" };
        hdrs[4] = .{ .name = "Access-Control-Allow-Credentials", .value = "true" };
        hdrs[5] = .{ .name = "Access-Control-Max-Age", .value = "300" };
        hdrs[6] = .{ .name = "Access-Control-Allow-Private-Network", .value = "true" };
        const status = switch (code) {
            200 => http.Status.ok,
            204 => http.Status.no_content,
            400 => http.Status.bad_request,
            404 => http.Status.not_found,
            else => http.Status.internal_server_error,
        };
        try r.req.respond(body, .{ .status = status, .extra_headers = &hdrs });
    }
};

pub const App = struct {
    const Self = @This();

    gpa: std.mem.Allocator,
    io: std.Io,
    reader: *reader_mod.Reader,
    inventory: std.StringHashMap(Tag),
    mode: Mode = .idle,
    keep_transponders_awake: bool,
    only_one_active: bool,
    library: []const u8,
    start_ts: std.Io.Timestamp,
    my_ip: []const u8,
    // protects inventory and mode
    mu: mutex.Mutex = .{},
    // protects sse_clients and each subscriber's queue
    sse_mu: mutex.Mutex = .{},
    // per-subscriber state for the /events/ stream; the delivery
    // thread drains each queue onto its socket (raw write(2))
    sse_clients: std.ArrayList(*Subscriber),

    pub fn init(alloc: std.mem.Allocator, io: std.Io, r: *reader_mod.Reader, wake: bool, only_one: bool, library: []const u8) !Self {
        var a: Self = .{
            .gpa = alloc,
            .io = io,
            .reader = r,
            .inventory = std.StringHashMap(Tag).init(alloc),
            .keep_transponders_awake = wake,
            .only_one_active = only_one,
            .library = library,
            .start_ts = std.Io.Clock.awake.now(io),
            .my_ip = getMyIp(io, alloc),
            .sse_clients = .empty,
        };
        // one-time mutex setup (no-op on linux; CRITICAL_SECTION on
        // windows); all app mutexes are inited before any thread spawns
        a.mu.init();
        a.sse_mu.init();
        return a;
    }

    // ---------- reader loop (port of server.readRFID) ----------

    pub fn readerLoop(self: *Self) void {
        // No per-thread engine here: the reader's data path goes through
        // the FEDM C SDK (its own transport); only sleep/mutex touch
        // std.Io, and those work without an engine.
        while (true) {
            self.io.sleep(std.Io.Duration.fromMilliseconds(100), .real) catch continue;
            var m: Mode = .idle;
            self.mu.lock(self.io) catch continue;
            m = self.mode;
            self.mu.unlock(self.io);
            if (m == .scan) self.reader.readTagsInRange(self);
        }
    }

    // ---------- inventory processing (port of Inventory.Process) ----------

    // Takes the presently read inventory and diffs it against the previous
    // state. Called with the reader lock held (from readTagsInRange).
    pub fn processInventory(self: *Self, tags: *std.AutoHashMap([8]u8, Tag)) void {
        const t0 = std.Io.Clock.awake.now(self.io);
        logger.debugPrint("PROCESSING INVENTORY...", .{});

        // add new tags and read their content
        var it = tags.iterator();
        while (it.next()) |entry| {
            const id = entry.value_ptr.id;
            const tag = tags.get(id) orelse continue;
            const mac = tag.mac;
            logger.debugPrint("TAG ID {s}", .{mac});
            // self.inventory is keyed by the mac string
            if (self.inventory.contains(mac)) {
                logger.debugPrint("TAG ALREADY READ: {s}", .{mac});
                continue;
            }
            logger.debugPrint("NEW TAG ADDED: {s}", .{mac});
            var t = tag;
            const data = self.reader.doReadTagContent(&t.id) catch {
                self.reader.read_tag_fail += 1;
                continue;
            };
            const tc = inventory.current.parse(self.gpa, data) catch {
                self.gpa.free(data);
                logger.debugPrint("ERROR PROCESSING TAG DATA", .{});
                self.reader.read_tag_fail += 1;
                continue;
            };
            self.gpa.free(data);
            t.content = tc;
            self.mu.lock(self.io) catch {};
            self.inventory.put(mac, t) catch {};
            self.mu.unlock(self.io);
            self.reader.read_tag_succ += 1;

            var buf: [4096]u8 = undefined;
            var mw = inventory.MemWriter{ .buf = buf[0..], .alloc = self.gpa };
            if (t.json(&mw)) |_| {} else |_| continue;
            self.broadcast("addTag", mw.slice());
        }

        // remove tags no longer in range. Removals are bounded by the
        // inventory size (read under mu, which all put paths also take),
        // so a plain pre-allocated slice suffices.
        self.mu.lock(self.io) catch return;
        const to_remove = self.gpa.alloc([]const u8, self.inventory.count()) catch {
            self.mu.unlock(self.io);
            return;
        };
        defer self.gpa.free(to_remove);
        var n_remove: usize = 0;
        var inv = self.inventory.iterator();
        while (inv.next()) |entry| {
            const id = entry.value_ptr.id;
            if (tags.contains(id)) continue; // still in range
            const mac = entry.value_ptr.mac;
            logger.debugPrint("TAG NO LONGER IN RANGE, REMOVING: {s}", .{mac});
            const t = self.inventory.get(mac) orelse continue;
            var buf: [4096]u8 = undefined;
            var mw = inventory.MemWriter{ .buf = buf[0..], .alloc = self.gpa };
            if (t.json(&mw)) |_| {} else |_| continue;
            to_remove[n_remove] = mac;
            n_remove += 1;
            self.broadcast("removeTag", mw.slice());
        }
        for (to_remove[0..n_remove]) |mac| {
            _ = self.inventory.remove(mac);
            self.gpa.free(mac);
        }
        self.mu.unlock(self.io);
        const ms = @as(u64, @intCast(@divTrunc(t0.untilNow(self.io, .awake).toNanoseconds(), 1_000_000)));
        logger.debugPrint("ALL INVENTORY TAG READ TIMING: {d}ms", .{ms});
    }

    // ---------- event source (SSE) ----------

    // One message to each connected subscriber (those being killed are
    // skipped); the delivery thread writes it out.
    fn broadcast(self: *Self, event: []const u8, data: []const u8) void {
        self.sse_mu.lock(self.io) catch return;
        defer self.sse_mu.unlock(self.io);
        for (self.sse_clients.items) |s| {
            if (s.closing) continue;
            const msg = self.gpa.create(BroadcastMsg) catch continue;
            const ev = self.gpa.dupe(u8, event) catch {
                self.gpa.destroy(msg);
                continue;
            };
            const da = self.gpa.dupe(u8, data) catch {
                self.gpa.free(ev);
                self.gpa.destroy(msg);
                continue;
            };
            msg.* = .{ .event = ev, .data = da };
            if (!s.queue.push(msg)) {
                // subscriber fell too far behind: drop this event for it
                self.gpa.free(ev);
                self.gpa.free(da);
                self.gpa.destroy(msg);
            }
        }
    }

    // Called with sse_mu held. Only flags the victims; the delivery
    // thread is the single closer for each fd.
    fn killSubscribersLocked(self: *Self) void {
        for (self.sse_clients.items) |s| {
            if (!s.closing) s.closing = true;
        }
    }

    // /events/: register a subscriber. The delivery thread sends the
    // headers and events on the socket; from here the connection
    // belongs to it, so main must not close it.
    fn sseSubscribe(self: *Self, conn: std.Io.net.Stream) void {
        // the socket handle is a raw fd (int) on linux, a pointer
        // value (SOCKET) on windows
        const fd: c_int = if (is_linux) conn.socket.handle else @as(c_int, @intCast(@intFromPtr(conn.socket.handle)));
        const s = self.gpa.create(Subscriber) catch {
            _ = sockClose(fd);
            return;
        };
        // explicit full init: create() does not guarantee zeroed memory
        s.* = .{ .fd = fd };
        // a disconnecting client must not take the process down with
        // SIGPIPE (SOL_SOCKET, SO_NOSIGNAL - linux)
        if (is_linux) {
            var on: c_int = 1;
            _ = setsockopt(fd, 1, 26, &on, 4);
        }
        self.sse_mu.lock(self.io) catch {
            _ = sockClose(s.fd);
            self.gpa.destroy(s);
            return;
        };
        if (self.only_one_active) self.killSubscribersLocked();
        self.sse_clients.append(self.gpa, s) catch {
            self.sse_mu.unlock(self.io);
            _ = sockClose(s.fd); // never registered: we own it
            self.gpa.destroy(s);
            return;
        };
        self.sse_mu.unlock(self.io);
    }

    // Dedicated SSE delivery thread: std.Io net writes only work on
    // the main thread, so each subscriber's queue is drained onto its
    // socket with raw write(2). sleep/clock work on any thread with
    // the main's io (same as readerLoop).
    pub fn sseLoop(self: *Self) void {
        while (true) {
            self.deliverOnce();
            self.io.sleep(std.Io.Duration.fromMilliseconds(100), .real) catch continue;
        }
    }

    // One pass over all subscribers: first headers, queued events,
    // keep-alive ping. Called from the delivery thread.
    fn deliverOnce(self: *Self) void {
        // snapshot the current subscribers (bounded; more is a bug)
        var subs: [16]?*Subscriber = undefined;
        var n: usize = 0;
        self.sse_mu.lock(self.io) catch return;
        {
            const items = self.sse_clients.items;
            if (items.len > 16) {
                self.sse_mu.unlock(self.io);
                std.debug.panic("sse: more than 16 subscribers", .{});
            }
            n = items.len;
            var i: usize = 0;
            while (i < n) : (i += 1) subs[i] = items[i];
        }
        self.sse_mu.unlock(self.io);

        const now = std.Io.Clock.awake.now(self.io).toNanoseconds();
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const s = subs[i].?;
            // corruption checks (remove once /events is stable)
            if (!canonical(@intFromPtr(s))) {
                std.debug.panic("sseLoop: subscriber ptr not canonical 0x{X:0>16}", .{@intFromPtr(s)});
            }
            var msg: ?*BroadcastMsg = null;
            var closing = false;
            self.sse_mu.lock(self.io) catch return;
            if (s.canary != SSE_CANARY) {
                self.sse_mu.unlock(self.io);
                dumpSelf(s, "sseLoop: canary clobbered");
                std.debug.panic("subscriber block corrupted", .{});
            }
            if (s.queue.count > RingSize or s.queue.head > 1_000_000 or s.queue.tail > 1_000_000) {
                self.sse_mu.unlock(self.io);
                dumpSelf(s, "sseLoop: queue counters corrupted");
                std.debug.panic("queue counters corrupted", .{});
            }
            closing = s.closing;
            if (!closing) msg = s.queue.pop();
            self.sse_mu.unlock(self.io);

            if (closing) {
                self.subscriberGone(s);
                continue;
            }
            if (!s.sent) {
                var hbuf: [512]u8 = undefined;
                var mw = inventory.MemWriter{ .buf = hbuf[0..], .alloc = self.gpa };
                if (sseHeaders(&mw)) |_| {} else |_| {
                    self.subscriberGone(s);
                    continue;
                }
                if (!rawWriteAll(s.fd, mw.slice())) {
                    self.subscriberGone(s);
                    continue;
                }
                s.sent = true;
                s.last_write = now;
            }
            if (msg) |m| {
                const va = @intFromPtr(m);
                if (!canonical(va)) {
                    dumpSelf(s, "sseLoop: popped bad pointer");
                    std.debug.panic("queue slot corrupted 0x{X:0>16}", .{va});
                }
                var ebuf: [4096]u8 = undefined;
                var mw = inventory.MemWriter{ .buf = ebuf[0..], .alloc = self.gpa };
                if (mw.print("event: {s}\ndata: {s}\n\n", .{ m.event, m.data })) |_| {} else |_| {
                    // event does not fit the frame buffer: drop it
                    self.gpa.free(m.event);
                    self.gpa.free(m.data);
                    self.gpa.destroy(m);
                    continue;
                }
                const ev = m.event;
                const da = m.data;
                if (!rawWriteAll(s.fd, mw.slice())) {
                    self.gpa.free(ev);
                    self.gpa.free(da);
                    self.gpa.destroy(m);
                    self.subscriberGone(s);
                    continue;
                }
                self.gpa.free(ev);
                self.gpa.free(da);
                self.gpa.destroy(m);
                s.last_write = now;
            } else if (now - s.last_write > @as(i96, 15_000_000_000)) {
                // 15s without data: an SSE comment keeps proxies alive
                // and detects a dead peer (write fails -> gone)
                if (!rawWriteAll(s.fd, ": ping\n\n")) self.subscriberGone(s);
            }
        }
    }

    // Called ONLY from the delivery thread: it is the single writer
    // and closer for each subscriber fd (prevents fd-reuse races).
    // Swap-removes under sse_mu, drains the queue, closes the socket.
    fn subscriberGone(self: *Self, s: *Subscriber) void {
        self.sse_mu.lock(self.io) catch unreachable;
        const items = self.sse_clients.items;
        for (items, 0..) |x, i| {
            if (x == s) {
                if (i + 1 < items.len) self.sse_clients.items[i] = items[items.len - 1];
                self.sse_clients.items.len -= 1;
                break;
            }
        }
        self.sse_mu.unlock(self.io);
        // gone from the list: no other thread can push to the queue
        while (s.queue.pop()) |m| {
            self.gpa.free(m.event);
            self.gpa.free(m.data);
            self.gpa.destroy(m);
        }
        _ = sockClose(s.fd);
        self.gpa.destroy(s);
    }

    // First write to a subscriber socket: the HTTP head of the
    // persistent event stream (no retry line - the stream stays open).
    fn sseHeaders(w: *inventory.MemWriter) !void {
        try w.write("HTTP/1.1 200 OK\r\n");
        try w.write("Content-Type: text/event-stream\r\n");
        try w.write("Cache-Control: no-cache\r\n");
        try w.write("Connection: keep-alive\r\n");
        try writeCors(w);
        try w.write("\r\n");
    }

    // ---------- http server ----------
    // The hologlobe pattern - the only 0.16 net shape that works on
    // this zig: single-threaded on main, the conn.reader/writer structs
    // stay alive in named locals for the whole request, std.http works
    // on &reader.interface. Every other shape tried (per-connection
    // std.Thread.spawn or Io.async workers, init.io or a user-created
    // engine, a copied .interface value) faulted in netRead at
    // NULL+0x1328. SSE is the exception: /events/ hands the socket to
    // the delivery thread, which drives it with raw write(2) (sseLoop),
    // so the accept loop never blocks on an open stream.

    pub fn httpLoop(self: *Self, tcp: *std.Io.net.Server) !void {
        while (true) {
            const conn = tcp.accept(self.io) catch return;
            self.handleConnection(conn);
        }
    }

    fn handleConnection(self: *Self, conn: std.Io.net.Stream) void {
        var recvBuf: [8192]u8 = undefined;
        var sendBuf: [4096]u8 = undefined;
        var reader = conn.reader(self.io, &recvBuf);
        var writer = conn.writer(self.io, &sendBuf);
        var httpServer = http.Server.init(&reader.interface, &writer.interface);
        var req = httpServer.receiveHead() catch {
            conn.close(self.io);
            return;
        };
        req.head.keep_alive = false; // zig issue 25017

        // /events/: the socket belongs to the SSE delivery thread from
        // here on - register and return WITHOUT closing the connection.
        var path = req.head.target;
        if (std.mem.indexOfScalar(u8, path, '?')) |qi| path = path[0..qi];
        if (std.mem.eql(u8, path, "/events/")) {
            self.sseSubscribe(conn);
            return;
        }
        self.route(&req) catch {};
        conn.close(self.io);
    }

    fn route(self: *Self, req: *http.Server.Request) !void {
        var path = req.head.target;
        var query: []const u8 = "";
        if (std.mem.indexOfScalar(u8, path, '?')) |qi| {
            path = path[0..qi];
            query = path[qi + 1 ..];
        }
        logger.debugPrint("HTTP {s} {s}", .{ @tagName(req.head.method), path });

        const r = Resp{ .self = self, .req = req };
        if (std.mem.eql(u8, @tagName(req.head.method), "OPTIONS")) {
            return r.send(204, "text/plain", "");
        }
        if (std.mem.eql(u8, path, "/.status")) {
            var buf: [65536]u8 = undefined;
            var mw = inventory.MemWriter{ .buf = buf[0..], .alloc = self.gpa };
            if (!self.statusJson(&mw)) return r.send(500, "text/plain", "json error");
            return r.send(200, "application/json", mw.slice());
        }
        if (std.mem.eql(u8, path, "/scan")) return self.handleScan(&r);
        if (std.mem.eql(u8, path, "/start")) {
            self.mu.lock(self.io) catch {};
            self.mode = .scan;
            self.mu.unlock(self.io);
            return r.send(200, "text/plain", "");
        }
        if (std.mem.eql(u8, path, "/stop")) {
            self.mu.lock(self.io) catch {};
            self.mode = .idle;
            self.mu.unlock(self.io);
            return r.send(200, "text/plain", "");
        }
        if (std.mem.eql(u8, path, "/write")) return self.handleWrite(&r, query);
        if (std.mem.eql(u8, path, "/writetagbarcode")) return self.handleWriteTagBarcode(&r, query);
        if (std.mem.eql(u8, path, "/alarmOff")) return self.handleAlarm(&r, 0xc2, "Failed turning off alarm");
        if (std.mem.eql(u8, path, "/alarmOn")) return self.handleAlarm(&r, 0x07, "Failed activating alarm");
        if (std.mem.eql(u8, path, "/ble/scan")) return self.handleBleScan(&r);
        if (std.mem.eql(u8, path, "/ble/stop")) return self.handleBleStop(&r);
        if (std.mem.eql(u8, path, "/html/index.html") or std.mem.eql(u8, path, "/html/") or std.mem.eql(u8, path, "/")) {
            return r.send(200, "text/html; charset=utf-8", Html);
        }
        return r.send(404, "text/plain", "404 page not found");
    }

    // CORS, same set as the Go server
    fn writeCors(w: anytype) !void {
        _ = try w.write("Access-Control-Allow-Origin: *\r\n");
        _ = try w.write("Access-Control-Allow-Methods: GET, POST, OPTIONS, PUT, DELETE\r\n");
        _ = try w.write("Access-Control-Allow-Headers: Content-Type, Access-Control-Allow-Headers, Authorization, X-Requested-With\r\n");
        _ = try w.write("Access-Control-Allow-Credentials: true\r\n");
        _ = try w.write("Access-Control-Max-Age: 300\r\n");
        _ = try w.write("Access-Control-Allow-Private-Network: true\r\n");
    }

    fn queryParam(self: *Self, query: []const u8, name: []const u8) ?[]const u8 {
        var s = std.mem.splitScalar(u8, query, '&');
        while (s.next()) |pair| {
            if (std.mem.indexOfScalar(u8, pair, '=')) |ei| {
                if (std.mem.eql(u8, pair[0..ei], name)) {
                    const v = pair[ei + 1 ..];
                    return inventory.percentDecode(self.gpa, v) catch v;
                }
            }
        }
        return null;
    }

    fn errTextAlloc(_: *Self, err: anyerror) []const u8 {
        return @errorName(err);
    }

    // /scan: read all tags in range once and return the current
    // inventory. Reader.mu serializes with the reader loop, so a scan
    // works while a /start loop is running.
    fn handleScan(self: *Self, r: *const Resp) !void {
        self.reader.readTagsInRange(self);
        var buf: [65536]u8 = undefined;
        var mw = inventory.MemWriter{ .buf = buf[0..], .alloc = self.gpa };
        if (!self.inventoryJson(&mw)) return r.send(500, "text/plain", "json error");
        return r.send(200, "application/json", mw.slice());
    }

    // /write: write the barcode (with sequence number and count) to all
    // tags in range
    fn handleWrite(self: *Self, r: *const Resp, query: []const u8) !void {
        const barcode = self.queryParam(query, "barcode") orelse return r.send(400, "text/plain", "Url Param 'barcode' is missing");
        self.mu.lock(self.io) catch {};
        const empty = self.inventory.count() == 0;
        self.mu.unlock(self.io);
        if (empty) return r.send(400, "text/plain", "Inventory empty");

        self.mu.lock(self.io) catch {};
        const orig = self.mode;
        self.mode = .write;
        self.mu.unlock(self.io);
        const res = self.reader.writeToTagsInRange(self, barcode);
        self.mu.lock(self.io) catch {};
        self.mode = orig;
        self.mu.unlock(self.io);
        if (res) |_| {} else |err| {
            const t = std.fmt.allocPrint(self.gpa, "Error writing inventory: {s}", .{self.errTextAlloc(err)}) catch "error";
            defer self.gpa.free(t);
            return r.send(400, "text/plain", t);
        }
        var buf: [65536]u8 = undefined;
        var mw = inventory.MemWriter{ .buf = buf[0..], .alloc = self.gpa };
        if (!self.inventoryJson(&mw)) return r.send(500, "text/plain", "json error");
        return r.send(200, "application/json", mw.slice());
    }

    // /writetagbarcode: write a single tag in range (tag from last inventory)
    fn handleWriteTagBarcode(self: *Self, r: *const Resp, query: []const u8) !void {
        const tagid = self.queryParam(query, "tagid") orelse return r.send(400, "text/plain", "Url Param 'tagid' is missing");
        const barcode = self.queryParam(query, "barcode") orelse return r.send(400, "text/plain", "Url Param 'barcode' is missing");
        self.mu.lock(self.io) catch {};
        const empty = self.inventory.count() == 0;
        self.mu.unlock(self.io);
        if (empty) return r.send(400, "text/plain", "Inventory empty");

        self.mu.lock(self.io) catch {};
        const orig = self.mode;
        self.mode = .write;
        self.mu.unlock(self.io);
        const tag = self.reader.writeTagBarcode(self, tagid, barcode) catch |err| {
            self.mu.lock(self.io) catch {};
            self.mode = orig;
            self.mu.unlock(self.io);
            const t = std.fmt.allocPrint(self.gpa, "Error writing tag: {s}", .{self.errTextAlloc(err)}) catch "error";
            defer self.gpa.free(t);
            return r.send(400, "text/plain", t);
        };
        self.mu.lock(self.io) catch {};
        self.mode = orig;
        self.mu.unlock(self.io);
        var buf: [65536]u8 = undefined;
        var mw = inventory.MemWriter{ .buf = buf[0..], .alloc = self.gpa };
        if (tag.json(&mw)) |_| {} else |_| return r.send(500, "text/plain", "json error");
        return r.send(200, "application/json", mw.slice());
    }

    // /alarmOn /alarmOff: turn the AFI alarm on or off on all tags in range
    fn handleAlarm(self: *Self, r: *const Resp, afi: u8, label: []const u8) !void {
        self.mu.lock(self.io) catch {};
        const empty = self.inventory.count() == 0;
        self.mu.unlock(self.io);
        if (empty) return r.send(400, "text/plain", "Inventory empty");

        self.mu.lock(self.io) catch {};
        const orig = self.mode;
        self.mode = .write_afi;
        self.mu.unlock(self.io);
        const res = self.reader.writeAFI(afi);
        self.mu.lock(self.io) catch {};
        self.mode = orig;
        self.mu.unlock(self.io);
        if (res) |_| {
            return r.send(200, "text/plain", "OK");
        } else |err| {
            const t = std.fmt.allocPrint(self.gpa, "{s}, err: {s}", .{ label, self.errTextAlloc(err) }) catch "error";
            defer self.gpa.free(t);
            return r.send(500, "text/plain", t);
        }
    }

    // /ble/scan: start (or continue) Bluetooth LE discovery and return the
    // readers found so far. Discovery keeps running until /ble/stop.
    fn handleBleScan(self: *Self, r: *const Resp) !void {
        const res = self.reader.bleStartDiscover();
        if (res) |_| {} else |_| {
            logger.debugPrint("BLE scan: {s}", .{self.reader.last_err});
            const t = std.fmt.allocPrint(self.gpa, "ble start: {s}", .{reader_mod.pluginLoadHint(self.gpa, self.reader.last_err)}) catch "ble start failed";
            defer self.gpa.free(t);
            return r.send(500, "text/plain", t);
        }
        const items = self.reader.bleList() catch return r.send(500, "text/plain", "ble list failed");
        defer self.freeBleItems(items);
        var buf: [65536]u8 = undefined;
        var mw = inventory.MemWriter{ .buf = buf[0..], .alloc = self.gpa };
        mw.writeByte('[') catch return r.send(500, "text/plain", "json error");
        for (items, 0..) |it, i| {
            if (i > 0) mw.writeByte(',') catch return r.send(500, "text/plain", "json error");
            it.json(&mw) catch return r.send(500, "text/plain", "json error");
        }
        mw.writeByte(']') catch return r.send(500, "text/plain", "json error");
        return r.send(200, "application/json", mw.slice());
    }

    // /ble/stop: stop Bluetooth LE discovery
    fn handleBleStop(self: *Self, r: *const Resp) !void {
        const res = self.reader.bleStopDiscover();
        if (res) |_| {
            return r.send(200, "text/plain", "OK");
        } else |_| {
            return r.send(500, "text/plain", self.reader.last_err);
        }
    }

    fn freeBleItems(self: *Self, items: []reader_mod.BleItem) void {
        for (items) |*it| it.free(self.gpa);
        if (items.len > 0) self.gpa.free(items);
    }

    // ---------- json ----------

    // Go time.Duration.String() style: "1m2.345s", "500ms", "1h2m"
    fn writeUptime(w: anytype, ms: u64) !void {
        const secs = ms / 1000;
        const d = secs / 86400;
        const h = (secs % 86400) / 3600;
        const m = (secs % 3600) / 60;
        const s = secs % 60;
        const msr = ms % 1000;
        if (d > 0) return w.print("{d}d{d}h", .{ d, h });
        if (h > 0) return w.print("{d}h{d}m", .{ h, m });
        if (m > 0) return w.print("{d}m{d}.{d:0>3}s", .{ m, s, msr });
        if (secs > 0) return w.print("{d}.{d:0>3}s", .{ s, msr });
        if (ms > 0) return w.print("{d}ms", .{ms});
        return w.print("0s", .{});
    }

    // /.status payload (port of ServerStatus); writes into the given buffer
    fn statusJson(self: *Self, w: *inventory.MemWriter) bool {
        self.mu.lock(self.io) catch return false;
        defer self.mu.unlock(self.io);
        w.writeByte('{') catch return false;
        w.write("\"Uptime\":\"") catch return false;
        self.writeUptimeLocked(w) catch return false;
        w.write("\",\"Reader\":") catch return false;
        self.reader.json(w) catch return false;
        w.write(",\"LastInventory\":") catch return false;
        self.writeInventoryMap(w) catch return false;
        w.print(",\"Client\":\"{s}\",", .{self.my_ip}) catch return false;
        w.print("\"Mode\":\"{s}\",", .{self.mode.str()}) catch return false;
        w.print("\"Version\":\"{s}\"", .{VERSION}) catch return false;
        w.writeByte('}') catch return false;
        return true;
    }

    // caller holds mu
    fn writeUptimeLocked(self: *Self, w: anytype) !void {
        const ms = @as(u64, @intCast(@divTrunc(self.start_ts.untilNow(self.io, .awake).toNanoseconds(), 1_000_000)));
        try writeUptime(w, ms);
    }

    fn inventoryJson(self: *Self, w: *inventory.MemWriter) bool {
        self.mu.lock(self.io) catch return false;
        defer self.mu.unlock(self.io);
        self.writeInventoryMap(w) catch return false;
        return true;
    }

    // caller holds mu
    fn writeInventoryMap(self: *Self, w: anytype) !void {
        try w.writeByte('{');
        var first = true;
        var inv = self.inventory.iterator();
        while (inv.next()) |entry| {
            const tag = entry.value_ptr;
            if (!first) {
                _ = try w.writeByte(',');
            }
            first = false;
            try inventory.jsonEscapeString(w, tag.mac);
            _ = try w.writeByte(':');
            _ = try tag.json(w);
        }
        try w.writeByte('}');
    }
};

// dummy UDP "connection" to get the outbound IP (port of getMyIP)
fn getMyIp(io: std.Io, alloc: std.mem.Allocator) []const u8 {
    const local = std.Io.net.IpAddress.parse("0.0.0.0", 0) catch return "127.0.0.1";
    const remote = std.Io.net.IpAddress.parse("1.1.1.1", 0) catch return "127.0.0.1";
    var socket = local.bind(io, .{ .mode = .dgram, .protocol = .udp }) catch return "127.0.0.1";
    defer socket.close(io);
    const conn = remote.connect(io, .{ .mode = .dgram }) catch return "127.0.0.1";
    const address = conn.socket.address;
    const s = std.fmt.allocPrint(alloc, "{f}", .{address}) catch return "127.0.0.1";
    // the Go version returns the IP without a port
    if (std.mem.lastIndexOfScalar(u8, s, ':')) |i| return s[0..i];
    return s;
}
