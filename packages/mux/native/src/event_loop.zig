const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");

// ============================================================================
// Platform-specific event loop (kqueue on macOS, epoll on Linux)
// ============================================================================

const is_darwin = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;

pub const Event = struct {
    fd: posix.fd_t,
    userdata: ?*anyopaque,
    readable: bool,
    eof: bool,
};

// ============================================================================
// macOS kqueue implementation
// ============================================================================

const KqueueLoop = struct {
    const EVFILT_READ: i16 = -1;
    const EV_ADD: u16 = 0x0001;
    const EV_DELETE: u16 = 0x0002;
    const EV_ENABLE: u16 = 0x0004;
    const EV_CLEAR: u16 = 0x0020;
    const EV_EOF: u16 = 0x8000;

    const kevent_t = extern struct {
        ident: usize,
        filter: i16,
        flags: u16,
        fflags: u32,
        data: isize,
        udata: ?*anyopaque,
    };

    extern "c" fn kqueue() c_int;
    extern "c" fn kevent64(
        kq: c_int,
        changelist: ?[*]const kevent_t,
        nchanges: c_int,
        eventlist: ?[*]kevent_t,
        nevents: c_int,
        flags: c_uint,
        timeout: ?*const posix.timespec,
    ) c_int;

    kq: c_int,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        const kq = kqueue();
        if (kq < 0) return error.KqueueFailed;
        return Self{ .kq = kq, .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        posix.close(self.kq);
    }

    pub fn addRead(self: *Self, fd: posix.fd_t, userdata: ?*anyopaque) !void {
        var changes = [_]kevent_t{.{
            .ident = @intCast(fd),
            .filter = EVFILT_READ,
            .flags = EV_ADD | EV_ENABLE | EV_CLEAR,
            .fflags = 0,
            .data = 0,
            .udata = userdata,
        }};
        const result = kevent64(self.kq, &changes, 1, null, 0, 0, null);
        if (result < 0) return error.KqueueRegisterFailed;
    }

    pub fn remove(self: *Self, fd: posix.fd_t) void {
        var changes = [_]kevent_t{.{
            .ident = @intCast(fd),
            .filter = EVFILT_READ,
            .flags = EV_DELETE,
            .fflags = 0,
            .data = 0,
            .udata = null,
        }};
        _ = kevent64(self.kq, &changes, 1, null, 0, 0, null);
    }

    pub fn wait(self: *Self, events: []Event, timeout_ms: ?u32) !usize {
        var kevents: [64]kevent_t = undefined;
        const max_events = @min(events.len, kevents.len);

        var timeout: ?posix.timespec = null;
        var ts: posix.timespec = undefined;
        if (timeout_ms) |ms| {
            ts = .{
                .sec = @intCast(ms / 1000),
                .nsec = @intCast((ms % 1000) * 1_000_000),
            };
            timeout = &ts;
        }

        const result = kevent64(self.kq, null, 0, &kevents, @intCast(max_events), 0, timeout);
        if (result < 0) return error.KqueueWaitFailed;

        const count: usize = @intCast(result);
        for (0..count) |i| {
            events[i] = .{
                .fd = @intCast(kevents[i].ident),
                .userdata = kevents[i].udata,
                .readable = true,
                .eof = (kevents[i].flags & EV_EOF) != 0,
            };
        }
        return count;
    }
};

// ============================================================================
// Linux epoll implementation
// ============================================================================

const EpollLoop = struct {
    const EPOLLIN: u32 = 0x001;
    const EPOLLHUP: u32 = 0x010;
    const EPOLLRDHUP: u32 = 0x2000;
    const EPOLLET: u32 = 1 << 31;
    const EPOLL_CTL_ADD: c_int = 1;
    const EPOLL_CTL_DEL: c_int = 2;

    const epoll_data = extern union {
        ptr: ?*anyopaque,
        fd: c_int,
        u32: u32,
        u64: u64,
    };

    const epoll_event = extern struct {
        events: u32,
        data: epoll_data,
    };

    extern "c" fn epoll_create1(flags: c_int) c_int;
    extern "c" fn epoll_ctl(epfd: c_int, op: c_int, fd: c_int, event: ?*epoll_event) c_int;
    extern "c" fn epoll_wait(epfd: c_int, events: [*]epoll_event, maxevents: c_int, timeout: c_int) c_int;

    epfd: c_int,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        const epfd = epoll_create1(0);
        if (epfd < 0) return error.EpollFailed;
        return Self{ .epfd = epfd, .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        posix.close(self.epfd);
    }

    pub fn addRead(self: *Self, fd: posix.fd_t, userdata: ?*anyopaque) !void {
        var ev = epoll_event{
            .events = EPOLLIN | EPOLLRDHUP | EPOLLET,
            .data = .{ .ptr = userdata },
        };
        const result = epoll_ctl(self.epfd, EPOLL_CTL_ADD, fd, &ev);
        if (result < 0) return error.EpollRegisterFailed;
    }

    pub fn remove(self: *Self, fd: posix.fd_t) void {
        _ = epoll_ctl(self.epfd, EPOLL_CTL_DEL, fd, null);
    }

    pub fn wait(self: *Self, events: []Event, timeout_ms: ?u32) !usize {
        var epoll_events: [64]epoll_event = undefined;
        const max_events: c_int = @intCast(@min(events.len, epoll_events.len));

        const timeout: c_int = if (timeout_ms) |ms| @intCast(ms) else -1;

        const result = epoll_wait(self.epfd, &epoll_events, max_events, timeout);
        if (result < 0) return error.EpollWaitFailed;

        const count: usize = @intCast(result);
        for (0..count) |i| {
            const ev = epoll_events[i];
            events[i] = .{
                .fd = 0, // epoll doesn't return fd directly, use userdata
                .userdata = ev.data.ptr,
                .readable = (ev.events & EPOLLIN) != 0,
                .eof = (ev.events & (EPOLLHUP | EPOLLRDHUP)) != 0,
            };
        }
        return count;
    }
};

// ============================================================================
// Platform-agnostic EventLoop type
// ============================================================================

pub const EventLoop = if (is_darwin)
    KqueueLoop
else if (is_linux)
    EpollLoop
else
    @compileError("EventLoop only supports macOS and Linux");

// ============================================================================
// Simple blocking I/O helper (works on all platforms)
// ============================================================================

pub fn setReadTimeout(fd: posix.fd_t, timeout_ms: u32) !void {
    const tv = posix.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv));
}
