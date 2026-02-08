//! Lock-free SPSC (single-producer, single-consumer) circular buffer queue.
//!
//! Adapted from metal0's lock-free queue (Tokio-style).
//! Generic over element type T instead of hardcoded *Task.
//! Capacity must be power of 2 for fast modulo via bitwise AND.
//!
//! Thread safety:
//! - push(): single producer only
//! - pop(): single consumer only (same thread as producer, or exclusive)
//! - steal(): safe from any thread (work-stealing)
//!
//! Usage:
//!   var queue = LockFreeQueue(u32, 256).init();
//!   _ = queue.push(42);
//!   const val = queue.pop(); // 42

const std = @import("std");

pub fn LockFreeQueue(comptime T: type, comptime capacity: usize) type {
    comptime {
        if (capacity == 0 or (capacity & (capacity - 1)) != 0) {
            @compileError("LockFreeQueue capacity must be power of 2");
        }
    }

    return struct {
        buffer: [capacity]?T,
        head: std.atomic.Value(usize),
        tail: std.atomic.Value(usize),

        const Self = @This();
        const mask = capacity - 1;

        pub fn init() Self {
            var queue = Self{
                .buffer = undefined,
                .head = std.atomic.Value(usize).init(0),
                .tail = std.atomic.Value(usize).init(0),
            };
            for (&queue.buffer) |*slot| {
                slot.* = null;
            }
            return queue;
        }

        /// Push item (single producer). Returns false if full.
        pub fn push(self: *Self, item: T) bool {
            const tail = self.tail.load(.acquire);
            const next_tail = (tail + 1) & mask;
            if (next_tail == self.head.load(.acquire)) return false;

            self.buffer[tail] = item;
            self.tail.store(next_tail, .release);
            return true;
        }

        /// Pop item (single consumer). Returns null if empty.
        pub fn pop(self: *Self) ?T {
            const head = self.head.load(.acquire);
            if (head == self.tail.load(.acquire)) return null;

            const item = self.buffer[head];
            self.buffer[head] = null;
            self.head.store((head + 1) & mask, .release);
            return item;
        }

        /// Steal item from another thread (atomic). Returns null if empty or race lost.
        pub fn steal(self: *Self) ?T {
            const old_head = self.head.fetchAdd(1, .acquire);
            if (old_head >= self.tail.load(.acquire)) {
                _ = self.head.fetchSub(1, .release);
                return null;
            }
            const item = self.buffer[old_head & mask];
            self.buffer[old_head & mask] = null;
            return item;
        }

        /// Approximate size (may be stale).
        pub fn size(self: *Self) usize {
            const head = self.head.load(.acquire);
            const tail = self.tail.load(.acquire);
            return if (tail >= head) tail - head else capacity - (head - tail);
        }

        pub fn isEmpty(self: *Self) bool {
            return self.head.load(.acquire) == self.tail.load(.acquire);
        }

        pub fn clear(self: *Self) void {
            while (self.pop()) |_| {}
        }
    };
}
