/// Shared memory frame pool for cross-process IPC
///
/// This module extends the frame_pool concept with shared memory backing,
/// enabling zero-copy frame transfer between processes (e.g., termweb <-> mux server).
///
/// Architecture:
/// ┌──────────────────────────────────────────────────────────────┐
/// │              Shared Memory Region                            │
/// ├──────────────────────────────────────────────────────────────┤
/// │ Header (64B) │ Slot Metadata Array │ Frame Data Slots        │
/// └──────────────────────────────────────────────────────────────┘
///
/// Uses comptime for platform-specific shared memory (memfd on Linux).
const std = @import("std");
const builtin = @import("builtin");
const SharedMemory = @import("shared_memory.zig").SharedMemory;
const SharedMemoryHeader = @import("shared_memory.zig").SharedMemoryHeader;

/// Shared frame slot metadata (stored in shared memory)
/// Each slot has fixed-size metadata followed by variable frame data
pub const SharedFrameSlotMeta = extern struct {
    /// Frame data length (0 = slot empty)
    len: u32 = 0,
    /// Session ID from screencast
    session_id: u32 = 0,
    /// Device dimensions
    device_width: u32 = 0,
    device_height: u32 = 0,
    /// Generation counter (incremented on each write)
    generation: u64 = 0,
    /// Chrome's timestamp (ms since epoch)
    chrome_timestamp_ms: i64 = 0,
    /// Zig receive timestamp (ns)
    receive_timestamp_ns: i128 = 0,
    /// Reference count for reader synchronization
    ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Padding for alignment
    _padding: [4]u8 = [_]u8{0} ** 4,

    comptime {
        // Ensure metadata is a nice power-of-2 size for alignment
        std.debug.assert(@sizeOf(SharedFrameSlotMeta) == 64);
    }

    pub fn isAvailable(self: *const SharedFrameSlotMeta) bool {
        return self.ref_count.load(.acquire) == 0;
    }

    pub fn acquire(self: *SharedFrameSlotMeta) void {
        _ = self.ref_count.fetchAdd(1, .acquire);
    }

    pub fn release(self: *SharedFrameSlotMeta) void {
        _ = self.ref_count.fetchSub(1, .release);
    }
};

/// Pool header stored at the start of shared memory (after SharedMemoryHeader)
pub const SharedPoolHeader = extern struct {
    /// Magic for validation (0x5346504C = "SFPL")
    magic: u32 = 0x5346504C,
    /// Number of slots
    slot_count: u32 = 0,
    /// Size of each slot's data area
    slot_data_size: u32 = 0,
    /// Current write index
    write_idx: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Global generation counter
    generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),
    /// Offset from pool header to metadata array
    metadata_offset: u32 = 0,
    /// Offset from pool header to data area
    data_offset: u32 = 0,
    /// Reserved for future use
    _reserved: [28]u8 = [_]u8{0} ** 28,

    comptime {
        std.debug.assert(@sizeOf(SharedPoolHeader) == 64);
    }

    pub fn isValid(self: *const SharedPoolHeader) bool {
        return self.magic == 0x5346504C;
    }
};

/// Shared memory frame pool for IPC
pub const SharedFramePool = struct {
    shm: SharedMemory,
    allocator: std.mem.Allocator,
    /// Pointer to pool header (in shared memory)
    pool_header: *SharedPoolHeader,
    /// Pointer to metadata array (in shared memory)
    metadata: [*]SharedFrameSlotMeta,
    /// Pointer to data area (in shared memory)
    data_base: [*]u8,
    /// Whether this instance is the producer (can write)
    is_producer: bool,

    const Self = @This();

    pub const Config = struct {
        slot_count: u32 = 8,
        slot_data_size: u32 = 2 * 1024 * 1024, // 2MB per slot
    };

    /// Create a new shared frame pool (producer side)
    pub fn create(allocator: std.mem.Allocator, name: []const u8, config: Config) !*Self {
        // Calculate required size
        const shm_header_size = @sizeOf(SharedMemoryHeader);
        const pool_header_size = @sizeOf(SharedPoolHeader);
        const metadata_size = @sizeOf(SharedFrameSlotMeta) * config.slot_count;
        const data_size = config.slot_data_size * config.slot_count;
        const total_size = shm_header_size + pool_header_size + metadata_size + data_size;

        var shm = SharedMemory.create(name, total_size) catch return error.OutOfMemory;
        errdefer shm.deinit();

        return initFromShm(allocator, shm, config, true);
    }

    /// Open an existing shared frame pool by fd (consumer side)
    pub fn openFd(allocator: std.mem.Allocator, fd: std.posix.fd_t, size: usize) !*Self {
        var shm = SharedMemory.openFd(fd, size) catch return error.OutOfMemory;
        errdefer shm.deinit();

        // Read config from existing pool header
        const base = shm.data().ptr;
        const pool_header: *SharedPoolHeader = @ptrCast(@alignCast(base));

        if (!pool_header.isValid()) {
            return error.InvalidHeader;
        }

        const config = Config{
            .slot_count = pool_header.slot_count,
            .slot_data_size = pool_header.slot_data_size,
        };

        return initFromShm(allocator, shm, config, false);
    }

    fn initFromShm(allocator: std.mem.Allocator, shm: SharedMemory, config: Config, is_producer: bool) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        // Get base pointer from mapped region, skip SharedMemoryHeader
        const shm_header_size = @sizeOf(@import("shared_memory.zig").SharedMemoryHeader);
        const base = shm.mapped.ptr + shm_header_size;
        const pool_header: *SharedPoolHeader = @ptrCast(@alignCast(base));

        // Calculate offsets
        const metadata_offset = @sizeOf(SharedPoolHeader);
        const metadata_size = @sizeOf(SharedFrameSlotMeta) * config.slot_count;
        const data_offset = metadata_offset + metadata_size;

        if (is_producer) {
            // Initialize pool header
            pool_header.* = SharedPoolHeader{
                .slot_count = config.slot_count,
                .slot_data_size = config.slot_data_size,
                .metadata_offset = metadata_offset,
                .data_offset = @intCast(data_offset),
            };

            // Initialize metadata slots
            const metadata: [*]SharedFrameSlotMeta = @ptrCast(@alignCast(base + metadata_offset));
            for (0..config.slot_count) |i| {
                metadata[i] = SharedFrameSlotMeta{};
            }
        }

        self.* = Self{
            .shm = shm,
            .allocator = allocator,
            .pool_header = pool_header,
            .metadata = @ptrCast(@alignCast(base + metadata_offset)),
            .data_base = base + data_offset,
            .is_producer = is_producer,
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.shm.deinit();
        self.allocator.destroy(self);
    }

    /// Write a frame to the pool (producer only)
    /// Returns generation number on success, null if all slots busy
    pub fn writeFrame(
        self: *Self,
        data: []const u8,
        session_id: u32,
        device_width: u32,
        device_height: u32,
    ) ?u64 {
        return self.writeFrameWithTimestamp(data, session_id, device_width, device_height, 0, 0);
    }

    /// Write a frame with timestamp data
    pub fn writeFrameWithTimestamp(
        self: *Self,
        data: []const u8,
        session_id: u32,
        device_width: u32,
        device_height: u32,
        chrome_timestamp_ms: i64,
        receive_timestamp_ns: i128,
    ) ?u64 {
        if (!self.is_producer) return null;
        if (data.len > self.pool_header.slot_data_size) return null;

        const slot_count = self.pool_header.slot_count;
        var attempts: u32 = 0;

        while (attempts < slot_count) : (attempts += 1) {
            const idx = self.pool_header.write_idx.load(.acquire);
            const slot_idx = idx % slot_count;
            const meta = &self.metadata[slot_idx];

            if (meta.isAvailable()) {
                const gen = self.pool_header.generation.fetchAdd(1, .monotonic);

                // Copy data to slot
                const slot_data = self.getSlotData(slot_idx);
                @memcpy(slot_data[0..data.len], data);

                // Update metadata
                meta.len = @intCast(data.len);
                meta.session_id = session_id;
                meta.device_width = device_width;
                meta.device_height = device_height;
                meta.generation = gen;
                meta.chrome_timestamp_ms = chrome_timestamp_ms;
                meta.receive_timestamp_ns = receive_timestamp_ns;

                // Advance write index
                _ = self.pool_header.write_idx.fetchAdd(1, .release);

                return gen;
            }

            // Slot in use, try next
            _ = self.pool_header.write_idx.fetchAdd(1, .release);
        }

        return null; // All slots busy
    }

    /// Frame reference returned by acquireLatestFrame
    pub const FrameRef = struct {
        data: []const u8,
        meta: *SharedFrameSlotMeta,
        session_id: u32,
        device_width: u32,
        device_height: u32,
        generation: u64,
        chrome_timestamp_ms: i64,
        receive_timestamp_ns: i128,

        pub fn deinit(self: *const FrameRef) void {
            self.meta.release();
        }
    };

    /// Acquire the latest frame for reading (consumer side)
    /// MUST call FrameRef.deinit() when done to release the slot
    pub fn acquireLatestFrame(self: *Self) ?FrameRef {
        const slot_count = self.pool_header.slot_count;
        const write_idx = self.pool_header.write_idx.load(.acquire);

        if (write_idx == 0) return null; // No frames written yet

        // Latest frame is at write_idx - 1
        const slot_idx = (write_idx - 1) % slot_count;
        const meta = &self.metadata[slot_idx];

        if (meta.generation == 0 or meta.len == 0) return null;

        meta.acquire();

        return FrameRef{
            .data = self.getSlotData(slot_idx)[0..meta.len],
            .meta = meta,
            .session_id = meta.session_id,
            .device_width = meta.device_width,
            .device_height = meta.device_height,
            .generation = meta.generation,
            .chrome_timestamp_ms = meta.chrome_timestamp_ms,
            .receive_timestamp_ns = meta.receive_timestamp_ns,
        };
    }

    /// Get the file descriptor for passing to another process
    pub fn getFd(self: *const Self) ?std.posix.fd_t {
        return self.shm.getFd();
    }

    /// Get total shared memory size (for passing to consumer)
    pub fn getTotalSize(self: *const Self) usize {
        return self.shm.size;
    }

    fn getSlotData(self: *Self, slot_idx: u32) []u8 {
        const offset = slot_idx * self.pool_header.slot_data_size;
        return self.data_base[offset..][0..self.pool_header.slot_data_size];
    }

    /// Reset the pool (invalidate all frames)
    pub fn reset(self: *Self) void {
        if (!self.is_producer) return;

        for (0..self.pool_header.slot_count) |i| {
            self.metadata[i].len = 0;
            self.metadata[i].generation = 0;
        }
        self.pool_header.write_idx.store(0, .release);
    }

    /// Get implementation info
    pub fn getInfo() []const u8 {
        return SharedMemory.getInfo();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "SharedFramePool basic write/read" {
    const allocator = std.testing.allocator;

    var pool = try SharedFramePool.create(allocator, "test_pool", .{
        .slot_count = 4,
        .slot_data_size = 1024,
    });
    defer pool.deinit();

    const test_data = "Hello, shared frame pool!";
    const gen = pool.writeFrame(test_data, 1, 800, 600);
    try std.testing.expect(gen != null);

    if (pool.acquireLatestFrame()) |*frame| {
        defer frame.deinit();
        try std.testing.expectEqualStrings(test_data, frame.data);
        try std.testing.expectEqual(@as(u32, 1), frame.session_id);
        try std.testing.expectEqual(@as(u32, 800), frame.device_width);
        try std.testing.expectEqual(@as(u32, 600), frame.device_height);
    } else {
        try std.testing.expect(false);
    }
}

test "SharedFramePool ring buffer" {
    const allocator = std.testing.allocator;

    var pool = try SharedFramePool.create(allocator, "ring_test", .{
        .slot_count = 2,
        .slot_data_size = 256,
    });
    defer pool.deinit();

    // Write 3 frames (should wrap)
    _ = pool.writeFrame("frame1", 1, 100, 100);
    _ = pool.writeFrame("frame2", 2, 200, 200);
    const gen3 = pool.writeFrame("frame3", 3, 300, 300);

    // Latest should be frame3
    if (pool.acquireLatestFrame()) |*frame| {
        defer frame.deinit();
        try std.testing.expectEqualStrings("frame3", frame.data);
        try std.testing.expectEqual(gen3, frame.generation);
    } else {
        try std.testing.expect(false);
    }
}

test "SharedFrameSlotMeta size" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(SharedFrameSlotMeta));
}

test "SharedPoolHeader size" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(SharedPoolHeader));
}
