/// Zero-copy frame buffer pool for screencast frames
/// Avoids per-frame allocations by reusing a ring buffer of frame slots
const std = @import("std");
const simd = @import("dispatch.zig");

pub const FrameSlot = struct {
    /// Raw buffer - owned by the pool, zero-copy reference
    buffer: []u8,
    /// Actual data length (may be less than buffer.len)
    len: usize,
    /// Frame metadata
    session_id: u32,
    device_width: u32,
    device_height: u32,
    /// Generation counter for invalidation checking
    generation: u64,
    /// Chrome's timestamp from screencast metadata (ms since epoch, 0 if not available)
    chrome_timestamp_ms: i64 = 0,
    /// When Zig received the frame (nanoseconds from nanoTimestamp)
    receive_timestamp_ns: i128 = 0,
    /// Reference count - non-zero means slot is being read (don't overwrite)
    ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn data(self: *const FrameSlot) []const u8 {
        return self.buffer[0..self.len];
    }

    /// Acquire a reference (prevents overwrite)
    pub fn acquire(self: *FrameSlot) void {
        _ = self.ref_count.fetchAdd(1, .acquire);
    }

    /// Release a reference
    pub fn release(self: *FrameSlot) void {
        _ = self.ref_count.fetchSub(1, .release);
    }

    /// Check if slot is available for writing
    pub fn isAvailable(self: *const FrameSlot) bool {
        return self.ref_count.load(.acquire) == 0;
    }
};

pub const FramePool = struct {
    allocator: std.mem.Allocator,
    /// Ring buffer of frame slots
    slots: []FrameSlot,
    /// Current write index
    write_idx: usize,
    /// Global generation counter
    generation: std.atomic.Value(u64),
    /// Mutex for thread-safe access
    mutex: std.Thread.Mutex,
    /// Buffer size for each slot
    slot_size: usize,

    const DEFAULT_SLOT_COUNT = 16; // 16 slots for more headroom
    const DEFAULT_SLOT_SIZE = 1024 * 1024; // 1MB per slot (enough for most frames)

    pub fn init(allocator: std.mem.Allocator) !*FramePool {
        return initWithConfig(allocator, DEFAULT_SLOT_COUNT, DEFAULT_SLOT_SIZE);
    }

    pub fn initWithConfig(
        allocator: std.mem.Allocator,
        slot_count: usize,
        slot_size: usize,
    ) !*FramePool {
        const pool = try allocator.create(FramePool);
        errdefer allocator.destroy(pool);

        const slots = try allocator.alloc(FrameSlot, slot_count);
        errdefer allocator.free(slots);

        // Pre-allocate all slot buffers
        for (slots) |*slot| {
            slot.buffer = try allocator.alloc(u8, slot_size);
            slot.len = 0;
            slot.session_id = 0;
            slot.device_width = 0;
            slot.device_height = 0;
            slot.generation = 0;
            slot.chrome_timestamp_ms = 0;
            slot.receive_timestamp_ns = 0;
            slot.ref_count = std.atomic.Value(u32).init(0);
        }

        pool.* = .{
            .allocator = allocator,
            .slots = slots,
            .write_idx = 0,
            .generation = std.atomic.Value(u64).init(1),
            .mutex = .{},
            .slot_size = slot_size,
        };

        return pool;
    }

    pub fn deinit(self: *FramePool) void {
        for (self.slots) |*slot| {
            self.allocator.free(slot.buffer);
        }
        self.allocator.free(self.slots);
        self.allocator.destroy(self);
    }

    /// Reset pool - invalidate all frames (for screencast restart)
    /// This ensures stale frames aren't returned after reset
    pub fn reset(self: *FramePool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.slots) |*slot| {
            slot.len = 0;
            slot.generation = 0;
        }
        self.write_idx = 0;
        // Keep generation counter going up to avoid confusion
    }

    /// Write a frame into the pool (zero-copy if possible)
    /// Returns the generation number for this write, or null if all slots are in use
    pub fn writeFrame(
        self: *FramePool,
        data: []const u8,
        session_id: u32,
        device_width: u32,
        device_height: u32,
    ) !?u64 {
        return self.writeFrameWithTimestamp(data, session_id, device_width, device_height, 0, 0);
    }

    /// Write a frame with timestamp information for latency tracking
    /// chrome_timestamp_ms: Chrome's timestamp from screencast metadata (ms since epoch)
    /// receive_timestamp_ns: When Zig received the frame (from nanoTimestamp)
    pub fn writeFrameWithTimestamp(
        self: *FramePool,
        data: []const u8,
        session_id: u32,
        device_width: u32,
        device_height: u32,
        chrome_timestamp_ms: i64,
        receive_timestamp_ns: i128,
    ) !?u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Find next available slot (skip slots being read)
        var attempts: usize = 0;
        while (attempts < self.slots.len) : (attempts += 1) {
            const slot = &self.slots[self.write_idx];
            if (slot.isAvailable()) {
                const gen = self.generation.fetchAdd(1, .monotonic);

                // Check if data fits in pre-allocated buffer
                if (data.len <= slot.buffer.len) {
                    // SIMD-accelerated copy into existing buffer
                    simd.simdCopy(slot.buffer, data);
                    slot.len = data.len;
                } else {
                    // Rare case: frame too large, reallocate
                    self.allocator.free(slot.buffer);
                    slot.buffer = try self.allocator.alloc(u8, data.len);
                    simd.simdCopy(slot.buffer, data);
                    slot.len = data.len;
                }

                slot.session_id = session_id;
                slot.device_width = device_width;
                slot.device_height = device_height;
                slot.generation = gen;
                slot.chrome_timestamp_ms = chrome_timestamp_ms;
                slot.receive_timestamp_ns = receive_timestamp_ns;

                // Advance write pointer (ring buffer)
                self.write_idx = (self.write_idx + 1) % self.slots.len;

                return gen;
            }
            // Slot in use, try next
            self.write_idx = (self.write_idx + 1) % self.slots.len;
        }

        // All slots are in use - drop frame (backpressure)
        return null;
    }

    /// Acquire the latest frame for zero-copy reading
    /// Returns null if no frames have been written
    /// IMPORTANT: Caller MUST call releaseFrame() when done to allow slot reuse
    pub fn acquireLatestFrame(self: *FramePool) ?*FrameSlot {
        self.mutex.lock();
        defer self.mutex.unlock();

        // The latest frame is at write_idx - 1 (wrapped)
        const read_idx = if (self.write_idx == 0)
            self.slots.len - 1
        else
            self.write_idx - 1;

        const slot = &self.slots[read_idx];
        if (slot.generation == 0) return null; // Never written

        // Acquire reference to prevent overwrite
        slot.acquire();
        return slot;
    }

    /// Release a previously acquired frame slot
    pub fn releaseFrame(_: *FramePool, slot: *FrameSlot) void {
        slot.release();
    }

    /// Get the latest frame (for reading) - DEPRECATED, use acquireLatestFrame
    /// Returns null if no frames have been written
    pub fn getLatestFrame(self: *FramePool) ?*const FrameSlot {
        self.mutex.lock();
        defer self.mutex.unlock();

        const read_idx = if (self.write_idx == 0)
            self.slots.len - 1
        else
            self.write_idx - 1;

        const slot = &self.slots[read_idx];
        if (slot.generation == 0) return null;
        return slot;
    }

    /// Returned by copyLatestFrame - owns its data (non-zero-copy fallback)
    pub const OwnedFrame = struct {
        data: []u8,
        allocator: std.mem.Allocator,
        session_id: u32,
        device_width: u32,
        device_height: u32,
        generation: u64,

        pub fn deinit(self: *OwnedFrame) void {
            self.allocator.free(self.data);
        }
    };

    /// Copy the latest frame with owned data (thread-safe, non-zero-copy fallback)
    /// Returns null if no frames have been written or allocation fails
    pub fn copyLatestFrame(self: *FramePool, allocator: std.mem.Allocator) ?OwnedFrame {
        self.mutex.lock();
        defer self.mutex.unlock();

        const read_idx = if (self.write_idx == 0)
            self.slots.len - 1
        else
            self.write_idx - 1;

        const slot = &self.slots[read_idx];
        if (slot.generation == 0) return null;

        const data_copy = allocator.alloc(u8, slot.len) catch return null;
        @memcpy(data_copy, slot.buffer[0..slot.len]);

        return OwnedFrame{
            .data = data_copy,
            .allocator = allocator,
            .session_id = slot.session_id,
            .device_width = slot.device_width,
            .device_height = slot.device_height,
            .generation = slot.generation,
        };
    }

    /// Check if a generation is still valid (not overwritten)
    pub fn isGenerationValid(self: *FramePool, gen: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if any slot has this generation
        for (self.slots) |*slot| {
            if (slot.generation == gen) return true;
        }
        return false;
    }
};

test "FramePool basic" {
    const allocator = std.testing.allocator;
    const pool = try FramePool.init(allocator);
    defer pool.deinit();

    // Initially no frame
    try std.testing.expectEqual(@as(?*const FrameSlot, null), pool.getLatestFrame());

    // Write a frame
    const data = "test frame data";
    const gen = try pool.writeFrame(data, 1, 800, 600);
    try std.testing.expect(gen > 0);

    // Read it back
    const frame = pool.getLatestFrame().?;
    try std.testing.expectEqualStrings(data, frame.data());
    try std.testing.expectEqual(@as(u32, 1), frame.session_id);
    try std.testing.expectEqual(@as(u32, 800), frame.device_width);
}

test "FramePool ring buffer" {
    const allocator = std.testing.allocator;
    const pool = try FramePool.initWithConfig(allocator, 2, 1024);
    defer pool.deinit();

    // Write 3 frames (should wrap around)
    _ = try pool.writeFrame("frame1", 1, 100, 100);
    _ = try pool.writeFrame("frame2", 2, 200, 200);
    const gen3 = try pool.writeFrame("frame3", 3, 300, 300);

    // Latest should be frame3
    const frame = pool.getLatestFrame().?;
    try std.testing.expectEqualStrings("frame3", frame.data());
    try std.testing.expectEqual(gen3, frame.generation);
}
