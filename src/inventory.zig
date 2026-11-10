const std = @import("std");

// Tag data model, tag content standards and CRC16 (port of the
// original Go implementation). JSON field names mirror the Go structs
// exactly. The active content standard is selected with -tagStandard
// (see TagStandard below).

pub const CCITT_REVERSED = 0x1021;

// CRC CCITT reversed table for fast lookup
const CRCTable: [256]u16 = blk: {
    // 256 x 8 comptime loop iterations, over the default 1000-branch quota
    @setEvalBranchQuota(10000);
    var tbl: [256]u16 = undefined;
    var i: u16 = 0;
    while (i < 256) : (i += 1) {
        var crc: u16 = i << 8;
        var j: u32 = 0;
        while (j < 8) : (j += 1) {
            crc = if (crc & 0x8000 != 0) (crc << 1) ^ 0x1021 else crc << 1;
        }
        tbl[i] = crc;
    }
    break :blk tbl;
};

pub fn crc16(b: []const u8) [2]u8 {
    var crc: u16 = 0xFFFF;
    for (b) |v| {
        crc = CRCTable[@intCast(@as(u16, crc >> 8) ^ v)] ^ (crc << 8);
    }
    return .{ @intCast(crc & 0x00FF), @intCast(crc >> 8) };
}

const HEXU = "0123456789ABCDEF";

const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

// RFC 4648 standard base64 with padding (same output as Go's
// base64.StdEncoding). Only the 8-byte and 2-byte cases are needed; the
// 0.16 std.base64 encode signature is unverified, so it is hand rolled.
pub fn base64Encode(dst: []u8, src: []const u8) void {
    var i: usize = 0;
    var o: usize = 0;
    while (i + 3 <= src.len) : (i += 3) {
        const v = (@as(u32, src[i]) << 16) | (@as(u32, src[i + 1]) << 8) | @as(u32, src[i + 2]);
        dst[o] = B64[@intCast((v >> 18) & 0x3F)];
        dst[o + 1] = B64[@intCast((v >> 12) & 0x3F)];
        dst[o + 2] = B64[@intCast((v >> 6) & 0x3F)];
        dst[o + 3] = B64[@intCast(v & 0x3F)];
        o += 4;
    }
    const rem = src.len - i;
    if (rem == 2) {
        const v = (@as(u32, src[i]) << 16) | (@as(u32, src[i + 1]) << 8);
        dst[o] = B64[@intCast((v >> 18) & 0x3F)];
        dst[o + 1] = B64[@intCast((v >> 12) & 0x3F)];
        dst[o + 2] = B64[@intCast((v >> 6) & 0x3F)];
        dst[o + 3] = '=';
    } else if (rem == 1) {
        const v = @as(u32, src[i]) << 16;
        dst[o] = B64[@intCast((v >> 18) & 0x3F)];
        dst[o + 1] = B64[@intCast((v >> 12) & 0x3F)];
        dst[o + 2] = '=';
        dst[o + 3] = '=';
    }
}

// Tag UID bytes as "AA:BB:CC:DD:EE:FF" (port of tagIDtoMAC).
// The result is always 23 bytes: 8 hex pairs + 7 colons.
pub fn tagIdToMac(alloc: std.mem.Allocator, id: [8]u8) ![]u8 {
    var out: [23]u8 = undefined;
    var i: usize = 0;
    for (id, 0..) |b, k| {
        if (k > 0) {
            out[i] = ':';
            i += 1;
        }
        out[i] = HEXU[b >> 4];
        out[i + 1] = HEXU[b & 0x0F];
        i += 2;
    }
    return alloc.dupe(u8, out[0..]);
}

// Even-length hex string (a FedmTag.iddHex) to bytes. Decodes
// hexs.len/2 bytes; `id` must be zero-initialized for the remaining
// high bytes. Mirrors Go's hex.DecodeString, which accepts any even
// length.
pub fn hexDecode(id: *[8]u8, hexs: []const u8) !void {
    const nbytes = hexs.len / 2;
    for (0..nbytes) |i| {
        id[i] = try std.fmt.parseInt(u8, hexs[i * 2 .. i * 2 + 2], 16);
    }
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

// Minimal percent-decoding of a query value (port of Go's URL query decoding).
// The decoded result is never longer than the input, so decode into a
// same-sized buffer and return the used prefix.
pub fn percentDecode(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf = try alloc.alloc(u8, s.len);
    errdefer alloc.free(buf);
    var i: usize = 0;
    var o: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            if (hexVal(s[i + 1])) |h| {
                if (hexVal(s[i + 2])) |l| {
                    buf[o] = h * 16 + l;
                    o += 1;
                    i += 2;
                    continue;
                }
            }
        }
        buf[o] = s[i];
        o += 1;
    }
    return buf[0..o];
}

pub fn jsonEscapeString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.write("\\\""),
        '\\' => try w.write("\\\\"),
        '\n' => try w.write("\\n"),
        '\r' => try w.write("\\r"),
        '\t' => try w.write("\\t"),
        else => {
            if (c < 0x20) {
                try w.print("\\u{X:0>4}", .{c});
            } else {
                try w.writeByte(c);
            }
        },
    };
    try w.writeByte('"');
}

fn trimZeros(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and s[end - 1] == 0) : (end -= 1) {}
    return s[0..end];
}

pub const TagContent = struct {
    seq_num: u8 = 0,
    num_items: u8 = 0, // number in sequence and number of items
    barcode: []const u8 = "",
    crc: [2]u8 = .{ 0, 0 },
    country: []const u8 = "",
    library: []const u8 = "",

    pub fn json(self: *const TagContent, w: anytype) !void {
        try w.writeByte('{');
        try w.print("\"SeqNum\":{d},", .{self.seq_num});
        try w.print("\"NumItems\":{d},", .{self.num_items});
        try w.write("\"Barcode\":");
        try jsonEscapeString(w, self.barcode);
        try w.write("\",\"Crc\":");
        var b64: [8]u8 = undefined;
        base64Encode(b64[0..], self.crc[0..]);
        try w.write(b64[0..]);
        try w.write("\",\"Country\":");
        try jsonEscapeString(w, self.country);
        try w.write(",\"Library\":");
        try jsonEscapeString(w, self.library);
        try w.writeByte('}');
    }

    pub fn free(self: *const TagContent, alloc: std.mem.Allocator) void {
        alloc.free(self.barcode);
        alloc.free(self.country);
        alloc.free(self.library);
    }
};

// A tag standard defines how tag content is laid out on the tag: parsing
// raw tag bytes into a TagContent and encoding it back. The active
// standard is selected at startup with -tagStandard (main.zig). To
// support another standard, write a parse/encode pair and register it in
// tagStandards below.
pub const TagStandard = struct {
    name: []const u8,
    // Raw tag bytes the standard occupies (a multiple of 4 - one
    // ISO15693 data block).
    contentLen: usize,
    parse: *const fn (alloc: std.mem.Allocator, bs: []const u8) error{PrepareReadTagBytes, NotEnoughTagContentBytes, OutOfMemory}!TagContent,
    encode: *const fn (tc: *const TagContent, alloc: std.mem.Allocator) error{OutOfMemory}![]u8,
};

// Registry of known tag standards. The first entry is the default.
const tagStandards = [_]TagStandard{
    .{ .name = "dansk", .contentLen = 36, .parse = danskParse, .encode = danskEncode },
};

pub fn tagStandardByName(name: []const u8) ?TagStandard {
    for (tagStandards) |ts| {
        if (std.mem.eql(u8, ts.name, name)) return ts;
    }
    return null;
}

// The active tag standard, selected at startup. Written once on the main
// thread before any worker thread is spawned.
pub var current: TagStandard = tagStandards[0];

// Comma-separated registered standard names, for error messages.
pub const availableStandards: []const u8 = blk: {
    var s: []const u8 = "";
    var first = true;
    for (tagStandards) |ts| {
        if (!first) s = s ++ ",";
        first = false;
        s = s ++ ts.name;
    }
    break :blk s;
};

// Tag content following Dansk standard (36 bytes):
// [0] version(4bit) + type(4bit)
// [1] sequence number
// [2] number of items
// [3:19]  barcode (16 bytes)
// [19:21] CRC of bytes 0-18 and 21-33
// [21:23] country
// [23:32] library
pub fn danskEncode(tc: *const TagContent, alloc: std.mem.Allocator) error{OutOfMemory}![]u8 {
    var bs: [36]u8 = undefined;
    @memset(bs[0..], 0);
    bs[0] = 0x11; // 17 (4bit version, 4bit type)
    bs[1] = tc.num_items;
    bs[2] = tc.seq_num;
    @memcpy(bs[3..19], tc.barcode);
    @memcpy(bs[21..23], tc.country);
    @memcpy(bs[23..32], tc.library);
    // crc over bytes 0-18 and 21-33 (the crc field itself is skipped)
    var csum: [32]u8 = undefined;
    @memset(csum[0..], 0);
    @memcpy(csum[0..19], bs[0..19]);
    @memcpy(csum[19..32], bs[21..34]);
    const crc = crc16(csum[0..]);
    bs[19] = crc[0];
    bs[20] = crc[1];
    return alloc.dupe(u8, bs[0..]);
}

// Tags are exactly 10 bytes on the wire (see FedmTag)
pub const Tag = struct {
    trtype: u16 = 0, // transponder type
    dfsid: u16 = 0, // Data Storage Family Identifier
    id: [8]u8 = zeroId(),
    mac: []const u8 = "", // string formatted ID
    content: TagContent = .{},

    fn zeroId() [8]u8 {
        var r: [8]u8 = undefined;
        @memset(r[0..], 0);
        return r;
    }

    pub fn json(self: *const Tag, w: anytype) !void {
        try w.writeByte('{');
        try w.print("\"Trtype\":{d},", .{self.trtype});
        try w.print("\"Dfsid\":{d},", .{self.dfsid});
        try w.write("\",\"Id\":");
        var b64: [16]u8 = undefined;
        base64Encode(b64[0..], self.id[0..]);
        try w.write(b64[0..]);
        try w.write("\",\"Mac\":");
        try jsonEscapeString(w, self.mac);
        try w.write(",\"Content\":");
        try self.content.json(w);
        try w.writeByte('}');
    }

    pub fn free(self: *const Tag, alloc: std.mem.Allocator) void {
        alloc.free(self.mac);
        self.content.free(alloc);
    }
};

// Parse the Dansk standard layout read from a tag (port of newTagContent).
// The FEDM SDK returns the read data blocks in memory order, which is the
// Dansk standard layout itself, no transformation needed.
pub fn danskParse(alloc: std.mem.Allocator, bs: []const u8) error{PrepareReadTagBytes, NotEnoughTagContentBytes, OutOfMemory}!TagContent {
    if (bs.len < 4 or bs.len % 4 != 0) return error.PrepareReadTagBytes;
    if (bs.len < 32) return error.NotEnoughTagContentBytes;
    var tc = TagContent{
        .num_items = bs[1],
        .seq_num = bs[2],
        .barcode = try alloc.dupe(u8, trimZeros(bs[3..19])),
        .crc = .{ bs[19], bs[20] },
        .country = try alloc.dupe(u8, bs[21..23]),
        .library = try alloc.dupe(u8, trimZeros(bs[23..32])),
    };
    // Strip leading "10" if the item belongs to Deichman
    // (books before 2016 were initiated with 10)
    if (std.mem.eql(u8, tc.country, "NO") and tc.barcode.len == 16 and std.mem.startsWith(u8, tc.barcode, "10")) {
        const old = tc.barcode;
        tc.barcode = alloc.dupe(u8, tc.barcode[2..]) catch {
            alloc.free(old);
            return error.OutOfMemory;
        };
        alloc.free(old);
    }
    return tc;
}

// A writer over a caller-owned buffer, for building JSON bodies with a
// known Content-Length (replaces the removed std.Io.AllocatingWriter).
pub const MemWriter = struct {
    buf: []u8,
    pos: usize = 0,
    // print() allocates a temp buffer from this. On hot paths it must be
    // the mutex-serialized app allocator (see safealloc.zig): direct
    // page_allocator use from multiple threads races and corrupts heap.
    alloc: std.mem.Allocator = std.heap.page_allocator,

    pub fn writeByte(self: *MemWriter, b: u8) !void {
        if (self.pos >= self.buf.len) return error.BufferOverflow;
        self.buf[self.pos] = b;
        self.pos += 1;
    }

    pub fn write(self: *MemWriter, s: []const u8) !void {
        if (self.pos + s.len > self.buf.len) return error.BufferOverflow;
        var i: usize = 0;
        while (i < s.len) : (i += 1) self.buf[self.pos + i] = s[i];
        self.pos += s.len;
    }

    pub fn print(self: *MemWriter, comptime fmt: []const u8, args: anytype) !void {
        const tmp = std.fmt.allocPrint(self.alloc, fmt, args) catch return error.BufferOverflow;
        defer self.alloc.free(tmp);
        try self.write(tmp);
    }

    pub fn flush() !void {}

    pub fn slice(self: MemWriter) []const u8 {
        return self.buf[0..self.pos];
    }
};
