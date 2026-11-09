const std = @import("std");
const mutex = @import("mutex.zig");

// Thread-safe, process-lifetime allocator.
//
// The service allocates from the app allocator on two threads: the
// reader loop (tag MACs, tag content, inventory map, broadcast
// payloads) and the main thread (SSE clients, the /scan path, status).
// This serializes the allocations in a pthread mutex (see mutex.zig)
// and hands out aligned blocks from the page allocator.
//
// free() is a no-op by design: nothing is ever freed individually,
// memory lives until process exit. resize/remap fail, so containers
// relying on in-place growth are out (the app allocates fresh
// buffers).
pub const SafeAlloc = struct {
    mu: mutex.Mutex = .{},
    io: std.Io,

    const vtable = std.mem.Allocator.VTable{
        .alloc = allocFn,
        .resize = resizeFn,
        .remap = remapFn,
        .free = freeFn,
    };

    pub fn init(io: std.Io) SafeAlloc {
        var s = SafeAlloc{ .io = io };
        s.mu.init();
        return s;
    }

    pub fn allocator(self: *SafeAlloc) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn selfFromCtx(ctx: *anyopaque) *SafeAlloc {
        return @ptrCast(@alignCast(ctx));
    }

    fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self = selfFromCtx(ctx);
        if (self.mu.lock(self.io)) |_| {} else |_| return null;
        defer self.mu.unlock(self.io);
        // The page allocator's raw vtable takes the alignment directly;
        // the 2-arg public alloc() cannot express it.
        return std.heap.page_allocator.vtable.alloc(ctx, len, alignment, ret_addr);
    }

    fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return false; // never resizes in place
    }

    fn remapFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return null;
    }

    fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = ret_addr;
    }
};
