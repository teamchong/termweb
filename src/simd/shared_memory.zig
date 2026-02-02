/// Cross-platform shared memory implementation for zero-copy IPC
///
/// Uses comptime to select platform-specific implementation:
/// - Linux: memfd_create + mmap (anonymous shared memory)
/// - macOS: mmap with MAP_ANONYMOUS or file-backed fallback
/// - Other: File-backed mmap fallback
///
/// Memory layout follows Ghostty's ring buffer pattern:
/// ┌─────────────────────────────────────────────────────┐
/// │ Header (64 bytes, cache-line aligned)               │
/// ├─────────────────────────────────────────────────────┤
/// │ Ring Buffer Data (configurable size)                │
/// └─────────────────────────────────────────────────────┘
const std = @import("std");
const builtin = @import("builtin");

/// Platform detection at compile time
const is_linux = builtin.os.tag == .linux;
const is_macos = builtin.os.tag == .macos;
const is_windows = builtin.os.tag == .windows;

/// Page size constant (4096 on most systems)
const PAGE_SIZE = 4096;

/// Shared memory header - 64 bytes for cache line alignment
/// All fields use atomics for lock-free producer/consumer access
pub const SharedMemoryHeader = extern struct {
    /// Magic number for validation (0x54455257 = "TERW")
    magic: u32 = 0x54455257,
    /// Version for compatibility checking
    version: u32 = 1,
    /// Write position (producer increments)
    write_pos: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Read position (consumer increments)
    read_pos: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Total buffer capacity (excluding header)
    capacity: u64 = 0,
    /// Current frame count (for debugging/stats)
    frame_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Flags (reserved for future use)
    flags: u32 = 0,
    /// Padding to 64 bytes (cache line alignment)
    _padding: [20]u8 = [_]u8{0} ** 20,

    comptime {
        // Ensure header is exactly 64 bytes (cache line)
        std.debug.assert(@sizeOf(SharedMemoryHeader) == 64);
    }

    /// Check if this is a valid termweb shared memory region
    pub fn isValid(self: *const SharedMemoryHeader) bool {
        return self.magic == 0x54455257 and self.version == 1;
    }

    /// Get available space for writing
    pub fn availableWrite(self: *const SharedMemoryHeader) u64 {
        const w = self.write_pos.load(.acquire);
        const r = self.read_pos.load(.acquire);
        // Ring buffer: available = capacity - (write - read)
        return self.capacity - (w - r);
    }

    /// Get available data for reading
    pub fn availableRead(self: *const SharedMemoryHeader) u64 {
        const w = self.write_pos.load(.acquire);
        const r = self.read_pos.load(.acquire);
        return w - r;
    }
};

pub const SharedMemoryError = error{
    CreateFailed,
    MapFailed,
    TruncateFailed,
    InvalidHeader,
    InvalidSize,
    OutOfMemory,
    NotSupported,
};

/// Cross-platform shared memory region
/// Automatically selects best implementation at compile time
pub const SharedMemory = struct {
    /// Mapped memory region (includes header + data)
    mapped: []align(PAGE_SIZE) u8,
    /// File descriptor (for memfd) or handle
    fd: std.posix.fd_t,
    /// Whether we own the fd (should close on deinit)
    owns_fd: bool,
    /// Size of the region
    size: usize,

    const Self = @This();

    /// Create a new shared memory region
    /// `name` is used for debugging (Linux memfd name, or temp file name)
    /// `size` is the desired data capacity (header is added automatically)
    pub fn create(name: []const u8, size: usize) SharedMemoryError!Self {
        const total_size = size + @sizeOf(SharedMemoryHeader);
        // Round up to page size
        const aligned_size = std.mem.alignForward(usize, total_size, PAGE_SIZE);

        if (comptime is_linux) {
            return createLinux(name, aligned_size);
        } else if (comptime is_macos) {
            return createMacos(name, aligned_size);
        } else {
            return createFallback(name, aligned_size);
        }
    }

    /// Open an existing shared memory region by file descriptor
    /// Used by the consumer process to attach to producer's shared memory
    pub fn openFd(fd: std.posix.fd_t, size: usize) SharedMemoryError!Self {
        const aligned_size = std.mem.alignForward(usize, size, PAGE_SIZE);

        const mapped = std.posix.mmap(
            null,
            aligned_size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            fd,
            0,
        ) catch return SharedMemoryError.MapFailed;

        const hdr_ptr = @as(*SharedMemoryHeader, @ptrCast(@alignCast(mapped.ptr)));
        if (!hdr_ptr.isValid()) {
            std.posix.munmap(mapped);
            return SharedMemoryError.InvalidHeader;
        }

        return Self{
            .mapped = mapped,
            .fd = fd,
            .owns_fd = false, // Caller owns the fd
            .size = aligned_size,
        };
    }

    /// Linux implementation using memfd_create
    fn createLinux(name: []const u8, size: usize) SharedMemoryError!Self {
        // Prepare name (must be null-terminated, max 249 chars)
        var name_buf: [250]u8 = undefined;
        const name_len = @min(name.len, 249);
        @memcpy(name_buf[0..name_len], name[0..name_len]);
        name_buf[name_len] = 0;

        // MFD_CLOEXEC = 1
        const MFD_CLOEXEC: u32 = 1;

        const result = std.os.linux.memfd_create(
            @ptrCast(&name_buf),
            MFD_CLOEXEC,
        );

        if (@as(isize, @bitCast(result)) < 0) {
            // memfd_create failed, fall back to temp file
            return createFallback(name, size);
        }

        const fd: std.posix.fd_t = @intCast(result);
        errdefer std.posix.close(fd);

        // Set size
        std.posix.ftruncate(fd, @intCast(size)) catch {
            return SharedMemoryError.TruncateFailed;
        };

        // Map the memory
        const mapped = std.posix.mmap(
            null,
            size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            fd,
            0,
        ) catch return SharedMemoryError.MapFailed;

        // Initialize header
        const hdr_ptr = @as(*SharedMemoryHeader, @ptrCast(@alignCast(mapped.ptr)));
        hdr_ptr.* = SharedMemoryHeader{
            .capacity = size - @sizeOf(SharedMemoryHeader),
        };

        return Self{
            .mapped = mapped,
            .fd = fd,
            .owns_fd = true,
            .size = size,
        };
    }

    /// macOS implementation using MAP_ANONYMOUS
    fn createMacos(name: []const u8, size: usize) SharedMemoryError!Self {
        _ = name; // macOS anonymous mmap doesn't use name

        // Use MAP_ANONYMOUS for private anonymous mapping
        // For IPC, we'd need to use shm_open or create a temp file
        // This implementation is for same-process use (threads)
        const mapped = std.posix.mmap(
            null,
            size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED, .ANONYMOUS = true },
            -1,
            0,
        ) catch return SharedMemoryError.MapFailed;

        // Initialize header
        const hdr_ptr = @as(*SharedMemoryHeader, @ptrCast(@alignCast(mapped.ptr)));
        hdr_ptr.* = SharedMemoryHeader{
            .capacity = size - @sizeOf(SharedMemoryHeader),
        };

        return Self{
            .mapped = mapped,
            .fd = -1, // No fd for anonymous mapping
            .owns_fd = false,
            .size = size,
        };
    }

    /// Fallback implementation using temp file
    fn createFallback(name: []const u8, size: usize) SharedMemoryError!Self {
        // Create temp file in /tmp
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/tmp/termweb_shm_{s}_{d}", .{
            name,
            std.time.nanoTimestamp(),
        }) catch return SharedMemoryError.OutOfMemory;

        const file = std.fs.createFileAbsolute(path, .{
            .read = true,
            .truncate = true,
        }) catch return SharedMemoryError.CreateFailed;
        const fd = file.handle;
        errdefer std.posix.close(fd);

        // Unlink immediately so file disappears when closed
        std.fs.deleteFileAbsolute(path) catch {};

        // Set size
        std.posix.ftruncate(fd, @intCast(size)) catch {
            return SharedMemoryError.TruncateFailed;
        };

        // Map the memory
        const mapped = std.posix.mmap(
            null,
            size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            fd,
            0,
        ) catch return SharedMemoryError.MapFailed;

        // Initialize header
        const hdr_ptr = @as(*SharedMemoryHeader, @ptrCast(@alignCast(mapped.ptr)));
        hdr_ptr.* = SharedMemoryHeader{
            .capacity = size - @sizeOf(SharedMemoryHeader),
        };

        return Self{
            .mapped = mapped,
            .fd = fd,
            .owns_fd = true,
            .size = size,
        };
    }

    /// Clean up shared memory
    pub fn deinit(self: *Self) void {
        std.posix.munmap(self.mapped);
        if (self.owns_fd and self.fd >= 0) {
            std.posix.close(self.fd);
        }
    }

    /// Get the header for atomic operations
    pub fn header(self: *Self) *SharedMemoryHeader {
        return @as(*SharedMemoryHeader, @ptrCast(@alignCast(self.mapped.ptr)));
    }

    /// Get the data region (after header)
    pub fn data(self: *Self) []u8 {
        const header_size = @sizeOf(SharedMemoryHeader);
        return self.mapped[header_size..];
    }

    /// Get file descriptor for passing to another process
    /// Returns null if this is an anonymous mapping
    pub fn getFd(self: *const Self) ?std.posix.fd_t {
        if (self.fd < 0) return null;
        return self.fd;
    }

    /// Write data to the ring buffer (producer side)
    /// Returns false if not enough space (would need to wait or drop)
    pub fn write(self: *Self, bytes: []const u8) bool {
        const hdr = self.header();
        const buf = self.data();

        if (bytes.len > hdr.availableWrite()) {
            return false; // Not enough space
        }

        const cap = hdr.capacity;
        const w = hdr.write_pos.load(.acquire);
        const start_offset = w % cap;

        // Handle wrap-around
        if (start_offset + bytes.len <= cap) {
            // No wrap, single copy
            @memcpy(buf[start_offset..][0..bytes.len], bytes);
        } else {
            // Wrap around - two copies
            const first_part = cap - start_offset;
            @memcpy(buf[start_offset..][0..first_part], bytes[0..first_part]);
            @memcpy(buf[0..bytes.len - first_part], bytes[first_part..]);
        }

        // Update write position (release to make data visible)
        _ = hdr.write_pos.fetchAdd(bytes.len, .release);
        return true;
    }

    /// Read data from the ring buffer (consumer side)
    /// Returns slice of read data (may be less than requested if not enough available)
    /// The returned slice is only valid until the next read operation
    pub fn read(self: *Self, dest: []u8) usize {
        const hdr = self.header();
        const buf = self.data();

        const available = hdr.availableRead();
        const to_read = @min(dest.len, available);

        if (to_read == 0) return 0;

        const cap = hdr.capacity;
        const r = hdr.read_pos.load(.acquire);
        const start_offset = r % cap;

        // Handle wrap-around
        if (start_offset + to_read <= cap) {
            // No wrap, single copy
            @memcpy(dest[0..to_read], buf[start_offset..][0..to_read]);
        } else {
            // Wrap around - two copies
            const first_part = cap - start_offset;
            @memcpy(dest[0..first_part], buf[start_offset..][0..first_part]);
            @memcpy(dest[first_part..to_read], buf[0..to_read - first_part]);
        }

        // Update read position (release to allow producer to reuse space)
        _ = hdr.read_pos.fetchAdd(to_read, .release);
        return to_read;
    }

    /// Peek at data without consuming it (useful for parsing headers)
    pub fn peek(self: *Self, dest: []u8) usize {
        const hdr = self.header();
        const buf = self.data();

        const available = hdr.availableRead();
        const to_read = @min(dest.len, available);

        if (to_read == 0) return 0;

        const cap = hdr.capacity;
        const r = hdr.read_pos.load(.acquire);
        const start_offset = r % cap;

        if (start_offset + to_read <= cap) {
            @memcpy(dest[0..to_read], buf[start_offset..][0..to_read]);
        } else {
            const first_part = cap - start_offset;
            @memcpy(dest[0..first_part], buf[start_offset..][0..first_part]);
            @memcpy(dest[first_part..to_read], buf[0..to_read - first_part]);
        }

        return to_read;
    }

    /// Skip bytes without reading (advance read position)
    pub fn skip(self: *Self, count: usize) void {
        const hdr = self.header();
        const available = hdr.availableRead();
        const to_skip = @min(count, available);
        _ = hdr.read_pos.fetchAdd(to_skip, .release);
    }

    /// Get platform-specific implementation info
    pub fn getInfo() []const u8 {
        if (comptime is_linux) {
            return "Linux memfd_create + mmap";
        } else if (comptime is_macos) {
            return "macOS MAP_ANONYMOUS";
        } else {
            return "File-backed mmap fallback";
        }
    }
};

/// Frame-oriented shared memory for screencast data
/// Wraps SharedMemory with frame length prefixes for message boundaries
pub const SharedFrameBuffer = struct {
    shm: SharedMemory,
    allocator: std.mem.Allocator,

    const Self = @This();
    const FRAME_HEADER_SIZE = 8; // 4 bytes length + 4 bytes metadata

    pub fn create(allocator: std.mem.Allocator, name: []const u8, capacity: usize) !Self {
        const shm = try SharedMemory.create(name, capacity);
        return Self{
            .shm = shm,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.shm.deinit();
    }

    /// Write a frame with length prefix
    /// Format: [4 bytes length][4 bytes metadata][data]
    pub fn writeFrame(self: *Self, frame_data: []const u8, metadata: u32) bool {
        const total_size = FRAME_HEADER_SIZE + frame_data.len;

        // Check if we have space
        if (self.shm.header().availableWrite() < total_size) {
            return false;
        }

        // Write length prefix
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(frame_data.len), .little);
        if (!self.shm.write(&len_buf)) return false;

        // Write metadata
        var meta_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &meta_buf, metadata, .little);
        if (!self.shm.write(&meta_buf)) return false;

        // Write data
        if (!self.shm.write(frame_data)) return false;

        // Increment frame count
        _ = self.shm.header().frame_count.fetchAdd(1, .monotonic);
        return true;
    }

    /// Read a complete frame
    /// Returns null if no complete frame available
    /// Caller owns the returned memory
    pub fn readFrame(self: *Self) ?struct { data: []u8, metadata: u32 } {
        const available = self.shm.header().availableRead();
        if (available < FRAME_HEADER_SIZE) return null;

        // Peek at length
        var header_buf: [FRAME_HEADER_SIZE]u8 = undefined;
        if (self.shm.peek(&header_buf) < FRAME_HEADER_SIZE) return null;

        const frame_len = std.mem.readInt(u32, header_buf[0..4], .little);
        const metadata = std.mem.readInt(u32, header_buf[4..8], .little);

        const total_size = FRAME_HEADER_SIZE + frame_len;
        if (available < total_size) return null;

        // Skip header
        self.shm.skip(FRAME_HEADER_SIZE);

        // Allocate and read data
        const data = self.allocator.alloc(u8, frame_len) catch return null;
        const read_len = self.shm.read(data);
        if (read_len < frame_len) {
            self.allocator.free(data);
            return null;
        }

        return .{ .data = data, .metadata = metadata };
    }

    /// Get file descriptor for IPC
    pub fn getFd(self: *const Self) ?std.posix.fd_t {
        return self.shm.getFd();
    }

    /// Get frame count
    pub fn frameCount(self: *Self) u64 {
        return self.shm.header().frame_count.load(.monotonic);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "SharedMemory create and write" {
    var shm = try SharedMemory.create("test", 4096);
    defer shm.deinit();

    const test_data = "Hello, shared memory!";
    try std.testing.expect(shm.write(test_data));

    var read_buf: [64]u8 = undefined;
    const read_len = shm.read(&read_buf);
    try std.testing.expectEqual(test_data.len, read_len);
    try std.testing.expectEqualStrings(test_data, read_buf[0..read_len]);
}

test "SharedMemory ring buffer wrap" {
    var shm = try SharedMemory.create("wrap_test", 256);
    defer shm.deinit();

    // Fill most of the buffer
    const data1 = "A" ** 200;
    try std.testing.expect(shm.write(data1));

    // Read some to make space
    var buf1: [100]u8 = undefined;
    _ = shm.read(&buf1);

    // Write more (should wrap)
    const data2 = "B" ** 100;
    try std.testing.expect(shm.write(data2));

    // Read everything
    var buf2: [200]u8 = undefined;
    const len2 = shm.read(&buf2);
    try std.testing.expectEqual(@as(usize, 200), len2);
}

test "SharedMemoryHeader size" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(SharedMemoryHeader));
}

test "SharedFrameBuffer basic" {
    const allocator = std.testing.allocator;
    var fb = try SharedFrameBuffer.create(allocator, "frame_test", 4096);
    defer fb.deinit();

    const frame_data = "test frame data";
    try std.testing.expect(fb.writeFrame(frame_data, 42));

    if (fb.readFrame()) |frame| {
        defer allocator.free(frame.data);
        try std.testing.expectEqualStrings(frame_data, frame.data);
        try std.testing.expectEqual(@as(u32, 42), frame.metadata);
    } else {
        try std.testing.expect(false); // Should have gotten a frame
    }
}

test "getInfo returns non-empty" {
    const info = SharedMemory.getInfo();
    try std.testing.expect(info.len > 0);
}
