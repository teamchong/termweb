//! Goroutine-aware typed channel for inter-goroutine communication.
//!
//! Like Go channels: send blocks the goroutine (not the OS thread) when
//! the buffer is full, recv blocks when empty. Uses park/unpark via the
//! goroutine runtime — blocked goroutines yield their OS thread to other
//! goroutines instead of blocking the entire thread.
//!
//! Supports buffered and unbuffered modes:
//! - Unbuffered (capacity=0): send parks until a receiver is ready (rendezvous)
//! - Buffered (capacity>0): send parks only when buffer is full
//!
//! Also works from OS threads (non-goroutine context) using a condition
//! variable fallback — useful for the WS handler thread receiving results.
//!
//! Note: Unbuffered channels assume a single concurrent sender. Use buffered
//! channels (capacity >= 1) for multi-sender scenarios.
//!
//! Usage:
//!   const ch = try GChannel(u32).initBuffered(allocator, rt, 8);
//!   defer ch.deinit();
//!
//!   // In goroutine:
//!   ch.send(42);
//!
//!   // In goroutine or OS thread:
//!   const val = ch.recv() orelse break; // null when closed + empty

const std = @import("std");
const goroutine_mod = @import("goroutine.zig");
const runtime_mod = @import("runtime.zig");

const Goroutine = goroutine_mod.Goroutine;
const GoroutineQueue = goroutine_mod.GoroutineQueue;
const Runtime = runtime_mod.Runtime;
const Allocator = std.mem.Allocator;

pub fn GChannel(comptime T: type) type {
    return struct {
        buffer: ?[]T,
        capacity: usize,
        head: usize,
        tail: usize,
        size: usize,
        blocked_senders: GoroutineQueue,
        blocked_receivers: GoroutineQueue,
        mutex: std.Thread.Mutex,
        closed: bool,
        runtime: *Runtime,
        allocator: Allocator,

        os_not_empty: std.Thread.Condition,
        os_not_full: std.Thread.Condition,

        rendezvous_value: ?T,
        rendezvous_done: bool,

        const Self = @This();

        pub fn init(allocator: Allocator, rt: *Runtime) !*Self {
            return initBuffered(allocator, rt, 0);
        }

        pub fn initBuffered(allocator: Allocator, rt: *Runtime, capacity: usize) !*Self {
            const ch = try allocator.create(Self);
            errdefer allocator.destroy(ch);

            ch.* = .{
                .buffer = if (capacity > 0) try allocator.alloc(T, capacity) else null,
                .capacity = capacity,
                .head = 0,
                .tail = 0,
                .size = 0,
                .blocked_senders = .{},
                .blocked_receivers = .{},
                .mutex = .{},
                .closed = false,
                .runtime = rt,
                .allocator = allocator,
                .os_not_empty = .{},
                .os_not_full = .{},
                .rendezvous_value = null,
                .rendezvous_done = false,
            };

            return ch;
        }

        pub fn deinit(self: *Self) void {
            if (self.buffer) |buf| {
                self.allocator.free(buf);
            }
            self.allocator.destroy(self);
        }

        /// Send a value. Parks goroutine if buffer is full, returns false if closed.
        pub fn send(self: *Self, value: T) bool {
            if (self.capacity == 0) return self.sendUnbuffered(value);
            return self.sendBuffered(value);
        }

        /// Receive a value. Parks goroutine if buffer is empty, returns null if closed+empty.
        pub fn recv(self: *Self) ?T {
            if (self.capacity == 0) return self.recvUnbuffered();
            return self.recvBuffered();
        }

        /// Close the channel. Wakes all blocked senders and receivers.
        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.closed = true;

            while (self.blocked_senders.popUnlocked()) |g| {
                self.runtime.unpark(g);
            }
            while (self.blocked_receivers.popUnlocked()) |g| {
                self.runtime.unpark(g);
            }

            self.os_not_empty.broadcast();
            self.os_not_full.broadcast();
        }

        pub fn isClosed(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.closed;
        }

        fn sendBuffered(self: *Self, value: T) bool {
            while (true) {
                self.mutex.lock();

                if (self.closed) {
                    self.mutex.unlock();
                    return false;
                }

                if (self.size < self.capacity) {
                    self.buffer.?[self.tail] = value;
                    self.tail = (self.tail + 1) % self.capacity;
                    self.size += 1;
                    self.wakeOneReceiver();
                    self.mutex.unlock();
                    return true;
                }

                if (self.isInGoroutine()) {
                    const g = self.getCurrentGoroutine().?;
                    self.blocked_senders.pushUnlocked(g);
                    self.mutex.unlock();
                    self.runtime.park();
                    continue;
                }

                while (self.size >= self.capacity and !self.closed) {
                    self.os_not_full.wait(&self.mutex);
                }
                if (self.closed) {
                    self.mutex.unlock();
                    return false;
                }
                self.buffer.?[self.tail] = value;
                self.tail = (self.tail + 1) % self.capacity;
                self.size += 1;
                self.wakeOneReceiver();
                self.mutex.unlock();
                return true;
            }
        }

        fn recvBuffered(self: *Self) ?T {
            while (true) {
                self.mutex.lock();

                if (self.size > 0) {
                    const value = self.buffer.?[self.head];
                    self.head = (self.head + 1) % self.capacity;
                    self.size -= 1;
                    self.wakeOneSender();
                    self.mutex.unlock();
                    return value;
                }

                if (self.closed) {
                    self.mutex.unlock();
                    return null;
                }

                if (self.isInGoroutine()) {
                    const g = self.getCurrentGoroutine().?;
                    self.blocked_receivers.pushUnlocked(g);
                    self.mutex.unlock();
                    self.runtime.park();
                    continue;
                }

                while (self.size == 0 and !self.closed) {
                    self.os_not_empty.wait(&self.mutex);
                }
                if (self.size == 0) {
                    self.mutex.unlock();
                    return null;
                }
                const value = self.buffer.?[self.head];
                self.head = (self.head + 1) % self.capacity;
                self.size -= 1;
                self.wakeOneSender();
                self.mutex.unlock();
                return value;
            }
        }

        fn sendUnbuffered(self: *Self, value: T) bool {
            self.mutex.lock();

            if (self.closed) {
                self.mutex.unlock();
                return false;
            }

            if (self.blocked_receivers.popUnlocked()) |receiver_g| {
                self.rendezvous_value = value;
                self.mutex.unlock();
                self.runtime.unpark(receiver_g);
                return true;
            }

            self.rendezvous_value = value;
            self.rendezvous_done = false;

            if (self.isInGoroutine()) {
                const g = self.getCurrentGoroutine().?;
                self.blocked_senders.pushUnlocked(g);
                self.os_not_empty.signal();
                self.mutex.unlock();
                self.runtime.park();

                self.mutex.lock();
                const was_closed = self.closed;
                self.mutex.unlock();
                return !was_closed;
            }

            self.os_not_empty.signal();
            while (!self.rendezvous_done and !self.closed) {
                self.os_not_full.wait(&self.mutex);
            }
            const was_closed = self.closed;
            self.mutex.unlock();
            return !was_closed;
        }

        fn recvUnbuffered(self: *Self) ?T {
            while (true) {
                self.mutex.lock();

                if (self.rendezvous_value) |val| {
                    self.rendezvous_value = null;
                    self.rendezvous_done = true;

                    if (self.blocked_senders.popUnlocked()) |sender_g| {
                        self.mutex.unlock();
                        self.runtime.unpark(sender_g);
                    } else {
                        self.os_not_full.signal();
                        self.mutex.unlock();
                    }
                    return val;
                }

                if (self.closed) {
                    self.mutex.unlock();
                    return null;
                }

                if (self.isInGoroutine()) {
                    const g = self.getCurrentGoroutine().?;
                    self.blocked_receivers.pushUnlocked(g);
                    self.mutex.unlock();
                    self.runtime.park();
                    continue;
                }

                while (self.rendezvous_value == null and !self.closed) {
                    self.os_not_empty.wait(&self.mutex);
                }
                if (self.rendezvous_value) |val| {
                    self.rendezvous_value = null;
                    self.rendezvous_done = true;
                    if (self.blocked_senders.popUnlocked()) |sender_g| {
                        self.mutex.unlock();
                        self.runtime.unpark(sender_g);
                    } else {
                        self.os_not_full.signal();
                        self.mutex.unlock();
                    }
                    return val;
                }
                self.mutex.unlock();
                return null;
            }
        }

        fn isInGoroutine(_: *Self) bool {
            if (Runtime.current_processor) |p| {
                return p.current != null;
            }
            return false;
        }

        fn getCurrentGoroutine(_: *Self) ?*Goroutine {
            if (Runtime.current_processor) |p| {
                return p.current;
            }
            return null;
        }

        fn wakeOneReceiver(self: *Self) void {
            if (self.blocked_receivers.popUnlocked()) |g| {
                self.runtime.unpark(g);
            }
            self.os_not_empty.signal();
        }

        fn wakeOneSender(self: *Self) void {
            if (self.blocked_senders.popUnlocked()) |g| {
                self.runtime.unpark(g);
            }
            self.os_not_full.signal();
        }
    };
}

pub fn make(comptime T: type, allocator: Allocator, rt: *Runtime) !*GChannel(T) {
    return GChannel(T).init(allocator, rt);
}

pub fn makeBuffered(comptime T: type, allocator: Allocator, rt: *Runtime, capacity: usize) !*GChannel(T) {
    return GChannel(T).initBuffered(allocator, rt, capacity);
}
