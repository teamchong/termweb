//! M:N Goroutine Runtime — work-stealing scheduler with io_uring integration.
//!
//! Runs N OS threads (processors), each executing goroutines from its local
//! run queue. When a queue is empty, the processor steals from others or
//! falls back to a global queue. Idle processors block on a condition
//! variable (zero CPU waste — no spin-sleep).
//!
//! On Linux, io_uring is integrated: goroutines can submit async I/O,
//! yield, and be woken when the I/O completes. On other platforms,
//! I/O is blocking (goroutine occupies its OS thread during I/O).
//!
//! Usage:
//!   const rt = try Runtime.init(allocator, 0); // 0 = auto-detect
//!   defer rt.deinit();
//!
//!   _ = try rt.go(myFunc, myArg);
//!   rt.waitAll();

const std = @import("std");
const builtin = @import("builtin");
const context_mod = @import("context.zig");
const goroutine_mod = @import("goroutine.zig");

const Goroutine = goroutine_mod.Goroutine;
const GoroutineQueue = goroutine_mod.GoroutineQueue;
const Allocator = std.mem.Allocator;
const posix = std.posix;

const is_linux = builtin.os.tag == .linux;

pub const Runtime = struct {
    processors: []Processor,
    global_queue: GoroutineQueue,
    allocator: Allocator,
    next_id: std.atomic.Value(u64),
    active_count: std.atomic.Value(usize),
    shutdown: std.atomic.Value(bool),

    // Wakeup mechanism for idle processors
    wake_mutex: std.Thread.Mutex,
    wake_cond: std.Thread.Condition,

    // io_uring ring for async I/O (Linux only)
    io_ring: if (is_linux) ?std.os.linux.IoUring else void,
    io_mutex: if (is_linux) std.Thread.Mutex else void,
    io_pending: if (is_linux) std.AutoHashMap(u64, *Goroutine) else void,

    /// Per-OS-thread processor state.
    pub const Processor = struct {
        id: usize,
        local_queue: GoroutineQueue,
        current: ?*Goroutine,
        thread: ?std.Thread,
        runtime: *Runtime,
        /// Scheduler's saved context — swapContext saves here when running a goroutine,
        /// and goroutines swap back here when yielding/parking.
        scheduler_context: context_mod.Context,
    };

    /// Thread-local: which processor is running on this OS thread.
    pub threadlocal var current_processor: ?*Processor = null;

    pub fn init(allocator: Allocator, num_processors: usize) !*Runtime {
        const cpu_count = std.Thread.getCpuCount() catch 4;
        const n = if (num_processors == 0) @min(cpu_count, 8) else num_processors;

        const rt = try allocator.create(Runtime);
        errdefer allocator.destroy(rt);

        const procs = try allocator.alloc(Processor, n);
        errdefer allocator.free(procs);
        for (procs, 0..) |*p, i| {
            p.* = .{
                .id = i,
                .local_queue = .{},
                .current = null,
                .thread = null,
                .runtime = rt,
                .scheduler_context = .{},
            };
        }

        rt.* = .{
            .processors = procs,
            .global_queue = .{},
            .allocator = allocator,
            .next_id = std.atomic.Value(u64).init(1),
            .active_count = std.atomic.Value(usize).init(0),
            .shutdown = std.atomic.Value(bool).init(false),
            .wake_mutex = .{},
            .wake_cond = .{},
            .io_ring = if (is_linux) null else {},
            .io_mutex = if (is_linux) .{} else {},
            .io_pending = if (is_linux) std.AutoHashMap(u64, *Goroutine).init(allocator) else {},
        };

        // Initialize io_uring on Linux
        if (comptime is_linux) {
            rt.io_ring = std.os.linux.IoUring.init(256, 0) catch null;
        }

        // Start processor threads (skip P0 — used by caller via waitAll)
        for (rt.processors[1..]) |*p| {
            p.thread = try std.Thread.spawn(.{}, processorLoop, .{p});
        }

        return rt;
    }

    pub fn deinit(self: *Runtime) void {
        // Signal shutdown
        self.shutdown.store(true, .release);

        // Wake all idle processors
        self.wake_cond.broadcast();

        // Join all processor threads (skip P0)
        for (self.processors[1..]) |*p| {
            if (p.thread) |t| {
                t.join();
                p.thread = null;
            }
        }

        // Free any remaining goroutines in queues
        self.drainQueue(&self.global_queue);
        for (self.processors) |*p| {
            self.drainQueue(&p.local_queue);
        }

        // Cleanup io_uring
        if (comptime is_linux) {
            if (self.io_ring) |*ring| {
                ring.deinit();
            }
            self.io_pending.deinit();
        }

        self.allocator.free(self.processors);
        self.allocator.destroy(self);
    }

    fn drainQueue(self: *Runtime, queue: *GoroutineQueue) void {
        while (queue.pop()) |g| {
            g.deinit(self.allocator);
        }
    }

    /// Spawn a new goroutine. The goroutine is placed on the current processor's
    /// local queue (if called from a processor thread) or the global queue.
    pub fn go(self: *Runtime, func: *const fn (*anyopaque) void, arg: *anyopaque) !*Goroutine {
        const id = self.next_id.fetchAdd(1, .monotonic);
        const g = try Goroutine.init(self.allocator, id, func, arg);
        g.prepare(&goroutineExit);

        _ = self.active_count.fetchAdd(1, .monotonic);

        // Place on current processor's local queue if possible, else global
        if (current_processor) |p| {
            p.local_queue.push(g);
        } else {
            self.global_queue.push(g);
        }

        // Wake an idle processor
        self.wake_cond.signal();

        return g;
    }

    /// Yield the current goroutine. It goes back to runnable and the scheduler
    /// picks the next goroutine (or this one again if nothing else is ready).
    pub fn yield(_: *Runtime) void {
        const p = current_processor orelse return;
        const g = p.current orelse return;

        g.state = .runnable;
        p.local_queue.push(g);

        // Switch back to scheduler (scheduler resumes in runGoroutine)
        context_mod.swapContext(&g.context, &p.scheduler_context);
    }

    /// Park the current goroutine. It enters `blocked` state and does NOT go
    /// back to any queue. The caller must arrange for `unpark(g)` to be called
    /// later (e.g., by a channel or I/O poller).
    pub fn park(_: *Runtime) void {
        const p = current_processor orelse return;
        const g = p.current orelse return;

        g.state = .blocked;

        // Switch back to scheduler (scheduler resumes in runGoroutine)
        context_mod.swapContext(&g.context, &p.scheduler_context);
    }

    /// Unpark a blocked goroutine. Makes it runnable and places it on the
    /// global queue. Wakes an idle processor.
    pub fn unpark(self: *Runtime, g: *Goroutine) void {
        g.state = .runnable;
        self.global_queue.push(g);
        self.wake_cond.signal();
    }

    /// Submit an async read via io_uring and park the goroutine until completion.
    /// On non-Linux, falls back to blocking pread.
    pub fn asyncRead(self: *Runtime, fd: posix.fd_t, buf: []u8, offset: u64) !usize {
        if (comptime is_linux) {
            if (self.io_ring) |*ring| {
                const p = current_processor orelse return error.NotInGoroutine;
                const g = p.current orelse return error.NotInGoroutine;

                // Submit read SQE with goroutine ID as user_data
                self.io_mutex.lock();
                errdefer self.io_mutex.unlock();

                var sqe = try ring.read(@intCast(g.id), fd, .{ .buffer = buf }, offset);
                sqe.flags |= std.os.linux.IOSQE_IO_LINK;
                _ = try ring.submit();
                try self.io_pending.put(g.id, g);

                self.io_mutex.unlock();

                // Park goroutine — poller will unpark when CQE arrives
                self.park();

                // When we resume, io_result has been set
                if (g.io_result.err) return error.IoError;
                return g.io_result.bytes;
            }
        }

        // Fallback: blocking pread (goroutine occupies OS thread)
        return try posix.pread(fd, buf, offset);
    }

    /// Wait for all goroutines to complete.
    pub fn waitAll(self: *Runtime) void {
        // Run P0 on the current thread while waiting
        const p0 = &self.processors[0];
        current_processor = p0;
        defer current_processor = null;

        while (self.active_count.load(.acquire) > 0) {
            if (self.shutdown.load(.acquire)) break;

            // Try to run goroutines on P0
            if (self.findRunnable(p0)) |g| {
                self.executeGoroutine(p0, g);
            } else {
                // Poll io_uring for completions
                if (comptime is_linux) {
                    self.pollIoUring();
                }

                // Brief sleep if nothing to do (avoid busy-wait)
                self.wake_mutex.lock();
                self.wake_cond.timedWait(&self.wake_mutex, 1 * std.time.ns_per_ms) catch {};
                self.wake_mutex.unlock();
            }
        }
    }

    // ========================================================================
    // Internal: processor loop and scheduling
    // ========================================================================

    fn processorLoop(p: *Processor) void {
        const rt = p.runtime;
        current_processor = p;

        while (!rt.shutdown.load(.acquire)) {
            if (rt.findRunnable(p)) |g| {
                rt.executeGoroutine(p, g);
            } else {
                // Poll io_uring for completions
                if (comptime is_linux) {
                    rt.pollIoUring();
                }

                // No work — wait on condition variable (zero CPU when idle)
                rt.wake_mutex.lock();
                if (!rt.shutdown.load(.acquire)) {
                    rt.wake_cond.timedWait(&rt.wake_mutex, 10 * std.time.ns_per_ms) catch {};
                }
                rt.wake_mutex.unlock();
            }
        }
    }

    /// Find a runnable goroutine: local queue → global queue → steal from others.
    fn findRunnable(self: *Runtime, p: *Processor) ?*Goroutine {
        // 1. Try local queue
        if (p.local_queue.pop()) |g| return g;

        // 2. Try global queue
        if (self.global_queue.pop()) |g| return g;

        // 3. Work-stealing: try to steal from other processors
        for (self.processors) |*other| {
            if (other.id == p.id) continue;
            var stolen = other.local_queue.stealHalf();
            if (stolen.len > 0) {
                const first = stolen.popUnlocked();
                // Move remaining stolen goroutines to our local queue
                while (stolen.popUnlocked()) |g| {
                    p.local_queue.push(g);
                }
                if (first) |g| return g;
            }
        }

        return null;
    }

    /// Run a goroutine and handle cleanup when it completes.
    /// After swapContext returns (goroutine yielded, parked, or died),
    /// dead goroutines are freed here (can't free own stack from goroutineExit).
    fn executeGoroutine(self: *Runtime, p: *Processor, g: *Goroutine) void {
        g.state = .running;
        g.processor_id = p.id;
        p.current = g;

        // Switch from scheduler context to goroutine context
        context_mod.swapContext(&p.scheduler_context, &g.context);

        // Back in scheduler. goroutineExit or yield/park already cleared p.current.
        p.current = null;

        // If goroutine is dead, free its resources now (safe — we're on scheduler stack)
        if (g.state == .dead) {
            g.deinit(self.allocator);
        }
    }

    /// Called when a goroutine's function returns. Marks it as dead and
    /// switches back to the scheduler. The scheduler frees the goroutine
    /// in executeGoroutine after this swap.
    fn goroutineExit() callconv(.c) noreturn {
        const p = current_processor orelse unreachable;
        const g = p.current orelse unreachable;

        g.state = .dead;
        p.current = null;

        // Decrement active count and wake anyone waiting in waitAll
        _ = p.runtime.active_count.fetchSub(1, .monotonic);
        p.runtime.wake_cond.signal();

        // Switch back to scheduler — must never return.
        // The scheduler (executeGoroutine) will free g after this swap.
        context_mod.swapContext(&g.context, &p.scheduler_context);

        unreachable;
    }

    /// Poll io_uring for completed I/O operations and unpark waiting goroutines.
    fn pollIoUring(self: *Runtime) void {
        if (comptime !is_linux) return;

        const ring = &(self.io_ring orelse return);

        var cqes: [32]std.os.linux.io_uring_cqe = undefined;
        const n = ring.copy_cqes(&cqes, 0) catch return;

        if (n == 0) return;

        // Collect goroutines to unpark under io_mutex, then release mutex
        // before doing the actual unparks (avoids holding two locks)
        var to_unpark: [32]*Goroutine = undefined;
        var unpark_count: usize = 0;

        self.io_mutex.lock();
        for (cqes[0..n]) |*cqe| {
            const gid: u64 = @intCast(cqe.user_data);
            if (self.io_pending.get(gid)) |g| {
                if (cqe.res < 0) {
                    g.io_result = .{ .bytes = 0, .err = true };
                } else {
                    g.io_result = .{ .bytes = @intCast(cqe.res), .err = false };
                }
                _ = self.io_pending.remove(gid);
                to_unpark[unpark_count] = g;
                unpark_count += 1;
            }
        }
        self.io_mutex.unlock();

        // Now unpark without holding io_mutex
        for (to_unpark[0..unpark_count]) |g| {
            g.state = .runnable;
            self.global_queue.push(g);
        }

        if (unpark_count > 0) {
            self.wake_cond.broadcast();
        }
    }
};
