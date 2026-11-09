const std = @import("std");
const px = @import("mutex.zig");

// The io object the mutex ops go through; set once from main() before the
// first print (sync ops in the std.Io world are performed through an io).
pub var io: std.Io = undefined;

pub fn initIo(i: std.Io) void {
    io = i;
    mutex.init();
}

var mutex = px.Mutex{};

pub var debug_enabled = false;

// print() allocates a temp buffer from this; set it to the
// mutex-serialized app allocator before the first print (direct
// page_allocator use from multiple threads races and corrupts heap).
pub var alloc: std.mem.Allocator = std.heap.page_allocator;

pub fn initAlloc(a: std.mem.Allocator) void {
    alloc = a;
}

fn write2(dst: []u8, v: u64) void {
    dst[0] = '0' + @as(u8, @intCast((v / 10) % 10));
    dst[1] = '0' + @as(u8, @intCast(v % 10));
}

fn timeStr(buf: *[8]u8) void {
    // toNanoseconds() is signed (i96) in 0.16; truncate, then go unsigned
    const ns = std.Io.Clock.awake.now(io).toNanoseconds();
    const secs = @as(u64, @intCast(@divTrunc(ns, 1_000_000_000)));
    write2(buf[0..], (secs % 86400) / 3600);
    buf[2] = ':';
    write2(buf[3..], (secs % 3600) / 60);
    buf[5] = ':';
    write2(buf[6..], secs % 60);
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    mutex.lock(io) catch return;
    defer mutex.unlock(io);
    const msg = std.fmt.allocPrint(alloc, fmt, args) catch return;
    defer alloc.free(msg);
    var ts: [8]u8 = undefined;
    timeStr(&ts);
    std.debug.print("{s} {s}\n", .{ ts[0..], msg });
}

pub fn debugPrint(comptime fmt: []const u8, args: anytype) void {
    if (debug_enabled) print(fmt, args);
}
