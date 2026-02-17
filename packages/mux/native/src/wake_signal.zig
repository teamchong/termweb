//! Cross-platform wake signal for event-driven thread coordination.
//!
//! Allows one or more producer threads to wake a consumer thread that is
//! blocked waiting for events. The consumer waits with a timeout so it
//! can also wake periodically (e.g. for frame rendering).
//!
//! Uses eventfd on Linux (single fd, no pipe overhead) and pipe on macOS.
//! Both are waited on via poll() for unified timeout semantics.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const is_linux = builtin.os.tag == .linux;
const is_macos = builtin.os.tag == .macos;

pub const WakeSignal = struct {
    // Linux: eventfd (single fd). macOS: pipe (read_fd, write_fd).
    read_fd: posix.fd_t,
    write_fd: posix.fd_t,

    pub fn init() !WakeSignal {
        if (comptime is_linux) {
            const fd = try posix.eventfd(0, std.os.linux.EFD.NONBLOCK | std.os.linux.EFD.CLOEXEC);
            return .{ .read_fd = fd, .write_fd = fd };
        } else {
            const fds = try posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
            return .{ .read_fd = fds[0], .write_fd = fds[1] };
        }
    }

    pub fn deinit(self: *WakeSignal) void {
        posix.close(self.read_fd);
        if (self.write_fd != self.read_fd) {
            posix.close(self.write_fd);
        }
    }

    /// Wake the waiting thread. Safe to call from any thread.
    /// Multiple calls before a wait coalesce into a single wakeup.
    pub fn notify(self: *WakeSignal) void {
        if (comptime is_linux) {
            // eventfd: write u64(1) to increment counter
            const val: u64 = 1;
            _ = posix.write(self.write_fd, std.mem.asBytes(&val)) catch {};
        } else {
            // pipe: write single byte
            _ = posix.write(self.write_fd, &[_]u8{1}) catch {};
        }
    }

    /// Wait until notified or timeout expires.
    /// Returns true if woken by notify(), false on timeout.
    pub fn waitTimeout(self: *WakeSignal, timeout_ns: u64) bool {
        var fds = [_]posix.pollfd{.{
            .fd = self.read_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};

        if (comptime is_linux) {
            // ppoll: nanosecond precision avoids poll()'s ms truncation
            // which loses up to 999us per wait — critical for sub-5ms input latency
            var ts = std.os.linux.timespec{
                .sec = @intCast(timeout_ns / std.time.ns_per_s),
                .nsec = @intCast(timeout_ns % std.time.ns_per_s),
            };
            const rc = std.os.linux.ppoll(@ptrCast(&fds), 1, &ts, null);
            // ppoll returns number of ready fds, 0 on timeout, or
            // negative (wrapped to large usize) on error
            if (rc > 0 and rc < 0x8000_0000_0000_0000) {
                self.drain();
                return true;
            }
            return false;
        } else {
            const timeout_ms: i32 = if (timeout_ns >= std.time.ns_per_s * 60)
                std.math.maxInt(i32) // cap at ~24 days
            else
                @intCast(timeout_ns / std.time.ns_per_ms);

            const ready = posix.poll(&fds, timeout_ms) catch return false;
            if (ready > 0) {
                self.drain();
                return true;
            }
            return false;
        }
    }

    /// Drain all pending notifications without blocking.
    fn drain(self: *WakeSignal) void {
        if (comptime is_linux) {
            var buf: u64 = undefined;
            _ = posix.read(self.read_fd, std.mem.asBytes(&buf)) catch {};
        } else {
            var buf: [64]u8 = undefined;
            while (true) {
                _ = posix.read(self.read_fd, &buf) catch break;
            }
        }
    }
};
