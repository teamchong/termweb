//! Goroutine — lightweight userspace thread with its own stack.
//!
//! Each goroutine has a fixed-size stack and a saved CPU context.
//! The scheduler context-switches between goroutines cooperatively
//! via swapContext. Goroutines never preempt each other; they yield
//! explicitly (on I/O, channel operations, or explicit yield calls).

const std = @import("std");
const context_mod = @import("context.zig");

const Allocator = std.mem.Allocator;

pub const Goroutine = struct {
    id: u64,
    state: State,
    context: context_mod.Context,
    stack: []align(16) u8,
    func: *const fn (*anyopaque) callconv(.c) void,
    arg: *anyopaque,

    /// Result of an async I/O operation (set by poller before unpark).
    io_result: IoResult = .{},

    /// Intrusive linked list pointer for run queues.
    next: ?*Goroutine = null,

    /// Which processor is currently running this goroutine (set by scheduler).
    processor_id: ?usize = null,

    pub const stack_size: usize = 64 * 1024; // 64KB per goroutine

    pub const State = enum {
        /// Ready to run, sitting in a run queue.
        runnable,
        /// Currently executing on an OS thread.
        running,
        /// Blocked on I/O or channel, waiting to be unparked.
        blocked,
        /// Function completed, goroutine can be freed.
        dead,
    };

    pub const IoResult = struct {
        bytes: usize = 0,
        err: bool = false,
    };

    /// Allocate a goroutine with its own stack.
    /// The goroutine is initialized in `runnable` state but its context
    /// is not set up until `prepare()` is called (which needs the on_exit trampoline).
    pub fn init(
        allocator: Allocator,
        id: u64,
        func: *const fn (*anyopaque) callconv(.c) void,
        arg: *anyopaque,
    ) !*Goroutine {
        const stack = try allocator.alignedAlloc(u8, .@"16", stack_size);
        errdefer allocator.free(stack);

        const g = try allocator.create(Goroutine);
        g.* = .{
            .id = id,
            .state = .runnable,
            .context = .{},
            .stack = stack,
            .func = func,
            .arg = arg,
        };
        return g;
    }

    /// Set up the goroutine's context so swapContext into it starts executing func(arg).
    /// `on_exit` is called when func returns — typically marks goroutine as dead and
    /// switches back to the scheduler.
    pub fn prepare(self: *Goroutine, on_exit: *const fn () callconv(.c) noreturn) void {
        context_mod.makeContext(
            &self.context,
            self.stack,
            self.func,
            self.arg,
            on_exit,
        );
    }

    pub fn deinit(self: *Goroutine, allocator: Allocator) void {
        allocator.free(self.stack);
        allocator.destroy(self);
    }
};

/// Intrusive FIFO queue of goroutines (for run queues and blocked queues).
/// Thread-safe via mutex. O(1) push/pop.
pub const GoroutineQueue = struct {
    head: ?*Goroutine = null,
    tail: ?*Goroutine = null,
    len: usize = 0,
    mutex: std.Thread.Mutex = .{},

    /// Push a goroutine to the back of the queue.
    pub fn push(self: *GoroutineQueue, g: *Goroutine) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.pushUnlocked(g);
    }

    pub fn pushUnlocked(self: *GoroutineQueue, g: *Goroutine) void {
        g.next = null;
        if (self.tail) |t| {
            t.next = g;
        } else {
            self.head = g;
        }
        self.tail = g;
        self.len += 1;
    }

    /// Pop a goroutine from the front of the queue. Returns null if empty.
    pub fn pop(self: *GoroutineQueue) ?*Goroutine {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.popUnlocked();
    }

    pub fn popUnlocked(self: *GoroutineQueue) ?*Goroutine {
        const g = self.head orelse return null;
        self.head = g.next;
        if (self.head == null) {
            self.tail = null;
        }
        g.next = null;
        self.len -= 1;
        return g;
    }

    /// Steal half the goroutines from this queue (for work-stealing).
    /// Returns a new queue with the stolen goroutines.
    pub fn stealHalf(self: *GoroutineQueue) GoroutineQueue {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.len <= 1) return .{};

        const steal_count = self.len / 2;
        var stolen = GoroutineQueue{};
        var i: usize = 0;
        while (i < steal_count) : (i += 1) {
            if (self.popUnlocked()) |g| {
                stolen.pushUnlocked(g);
            } else break;
        }
        return stolen;
    }

    /// Get the number of goroutines in the queue (approximate, no lock).
    pub fn size(self: *const GoroutineQueue) usize {
        return @atomicLoad(usize, &self.len, .monotonic);
    }
};
