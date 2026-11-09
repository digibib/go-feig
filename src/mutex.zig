const std = @import("std");
const builtin = @import("builtin");

// Cross-thread synchronization for the whole app. std.Io.Mutex in
// this 0.16 dev build does not give reliable exclusion between
// threads (the startup stress test in main.zig checks it), so these
// are real OS primitives: a pthread mutex on linux, a
// CRITICAL_SECTION on windows.
//
// The lock/unlock signatures keep the (io) argument and error union
// of std.Io.Mutex so existing call sites are unchanged.
//
// Platform dispatch is a plain if on a comptime-known const - a
// top-level `comptime if` does not parse in this build. The dead
// branch is eliminated, so the unused platform's externs are never
// referenced and never linked.
const is_linux = builtin.os.tag == .linux;

extern fn pthread_mutex_lock(mu: *MutexT) c_int;
extern fn pthread_mutex_unlock(mu: *MutexT) c_int;
extern fn InitializeCriticalSection(cs: *MutexT) void;
extern fn EnterCriticalSection(cs: *MutexT) void;
extern fn LeaveCriticalSection(cs: *MutexT) void;

// 48 bytes, 8-aligned. A glibc pthread mutex occupies the first 40
// bytes (zero-init == PTHREAD_MUTEX_INITIALIZER); on windows the
// whole block is a CRITICAL_SECTION, set up once by init().
const MutexT = extern struct {
    _head: u64 = 0,
    _pad: [40]u8 = .{0} ** 40,
};

pub const Mutex = struct {
    raw: MutexT = .{},

    // No-op on linux (zero-init is already initialized); the one-time
    // CRITICAL_SECTION setup on windows.
    pub fn init(self: *Mutex) void {
        if (is_linux) {
            // a zero-init pthread mutex is already initialized
        } else {
            InitializeCriticalSection(&self.raw);
        }
    }

    pub fn lock(self: *Mutex, io: std.Io) error{Unavailable}!void {
        _ = io;
        if (is_linux) {
            _ = pthread_mutex_lock(&self.raw);
        } else {
            EnterCriticalSection(&self.raw);
        }
    }

    pub fn unlock(self: *Mutex, io: std.Io) void {
        _ = io;
        if (is_linux) {
            _ = pthread_mutex_unlock(&self.raw);
        } else {
            LeaveCriticalSection(&self.raw);
        }
    }
};
