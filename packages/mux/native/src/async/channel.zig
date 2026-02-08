//! Go-style typed channel for OS thread communication.
//!
//! Adapted from metal0's channel primitive. Uses std.Thread.Condition
//! for blocking instead of green thread task state, making it suitable
//! for OS thread communication without a scheduler.
//!
//! Supports buffered and unbuffered modes:
//! - Unbuffered (capacity=0): send blocks until a receiver is ready (rendezvous)
//! - Buffered (capacity>0): send blocks only when buffer is full
//!
//! Usage:
//!   const ch = try Channel(u32).initBuffered(allocator, 16);
//!   defer ch.deinit();
//!
//!   // Producer thread:
//!   ch.send(42);
//!
//!   // Consumer thread:
//!   const val = ch.recv() orelse break; // null when closed + empty

const std = @import("std");

pub fn Channel(comptime T: type) type {
    return struct {
        buffer: ?[]T,
        capacity: usize,
        head: usize,
        tail: usize,
        size: usize,
        mutex: std.Thread.Mutex,
        /// Signaled when buffer has space (or receiver ready for unbuffered)
        not_full: std.Thread.Condition,
        /// Signaled when buffer has items (or sender ready for unbuffered)
        not_empty: std.Thread.Condition,
        closed: bool,
        allocator: std.mem.Allocator,

        // For unbuffered rendezvous: sender writes here, receiver reads
        rendezvous_value: ?T,
        rendezvous_done: bool,

        const Self = @This();

        /// Create unbuffered channel (rendezvous semantics)
        pub fn init(allocator: std.mem.Allocator) !*Self {
            return initBuffered(allocator, 0);
        }

        /// Create buffered channel with given capacity
        pub fn initBuffered(allocator: std.mem.Allocator, capacity: usize) !*Self {
            const chan = try allocator.create(Self);
            errdefer allocator.destroy(chan);

            chan.* = Self{
                .buffer = if (capacity > 0) try allocator.alloc(T, capacity) else null,
                .capacity = capacity,
                .head = 0,
                .tail = 0,
                .size = 0,
                .mutex = .{},
                .not_full = .{},
                .not_empty = .{},
                .closed = false,
                .allocator = allocator,
                .rendezvous_value = null,
                .rendezvous_done = false,
            };

            return chan;
        }

        pub fn deinit(self: *Self) void {
            if (self.buffer) |buf| {
                self.allocator.free(buf);
            }
            self.allocator.destroy(self);
        }

        /// Send value to channel. Blocks if buffer is full (or no receiver for unbuffered).
        /// Returns false if channel is closed.
        pub fn send(self: *Self, value: T) bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.closed) return false;

            if (self.capacity == 0) {
                // Unbuffered: wait for receiver to pick up
                self.rendezvous_value = value;
                self.rendezvous_done = false;
                self.not_empty.signal(); // Wake waiting receiver

                // Wait until receiver has taken the value
                while (!self.rendezvous_done and !self.closed) {
                    self.not_full.wait(&self.mutex);
                }
                return !self.closed;
            }

            // Buffered: wait for space
            while (self.size >= self.capacity and !self.closed) {
                self.not_full.wait(&self.mutex);
            }
            if (self.closed) return false;

            self.buffer.?[self.tail] = value;
            self.tail = (self.tail + 1) % self.capacity;
            self.size += 1;

            self.not_empty.signal();
            return true;
        }

        /// Receive value from channel. Blocks if buffer is empty.
        /// Returns null if channel is closed and buffer is empty.
        pub fn recv(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.capacity == 0) {
                // Unbuffered: wait for sender
                while (self.rendezvous_value == null and !self.closed) {
                    self.not_empty.wait(&self.mutex);
                }
                if (self.rendezvous_value) |val| {
                    self.rendezvous_value = null;
                    self.rendezvous_done = true;
                    self.not_full.signal(); // Wake sender
                    return val;
                }
                return null; // Closed
            }

            // Buffered: wait for items
            while (self.size == 0 and !self.closed) {
                self.not_empty.wait(&self.mutex);
            }
            if (self.size == 0) return null; // Closed + empty

            const value = self.buffer.?[self.head];
            self.head = (self.head + 1) % self.capacity;
            self.size -= 1;

            self.not_full.signal();
            return value;
        }

        /// Try send without blocking. Returns true if sent, false if full or closed.
        pub fn trySend(self: *Self, value: T) bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.closed) return false;

            if (self.capacity == 0) {
                // Unbuffered: only succeeds if receiver is already waiting
                // (simplified: always fails for trySend on unbuffered)
                return false;
            }

            if (self.size >= self.capacity) return false;

            self.buffer.?[self.tail] = value;
            self.tail = (self.tail + 1) % self.capacity;
            self.size += 1;

            self.not_empty.signal();
            return true;
        }

        /// Try receive without blocking. Returns null if empty.
        pub fn tryRecv(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.capacity == 0) {
                if (self.rendezvous_value) |val| {
                    self.rendezvous_value = null;
                    self.rendezvous_done = true;
                    self.not_full.signal();
                    return val;
                }
                return null;
            }

            if (self.size == 0) return null;

            const value = self.buffer.?[self.head];
            self.head = (self.head + 1) % self.capacity;
            self.size -= 1;

            self.not_full.signal();
            return value;
        }

        /// Close the channel. Wakes all blocked senders and receivers.
        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.closed = true;
            self.not_full.broadcast();
            self.not_empty.broadcast();
        }

        /// Check if channel is closed.
        pub fn isClosed(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.closed;
        }

        /// Get number of items currently buffered.
        pub fn len(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.size;
        }
    };
}

/// Create unbuffered channel (like Go's `make(chan T)`)
pub fn make(comptime T: type, allocator: std.mem.Allocator) !*Channel(T) {
    return Channel(T).init(allocator);
}

/// Create buffered channel (like Go's `make(chan T, capacity)`)
pub fn makeBuffered(comptime T: type, allocator: std.mem.Allocator, capacity: usize) !*Channel(T) {
    return Channel(T).initBuffered(allocator, capacity);
}
