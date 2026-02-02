/// Example usage of cross-platform shared memory for IPC
///
/// This demonstrates how to use the shared memory abstraction for
/// zero-copy frame transfer between processes (e.g., termweb <-> mux server).
///
/// Comptime platform selection ensures zero runtime overhead:
/// - Linux (Ubuntu): Uses memfd_create + mmap
/// - macOS: Uses MAP_ANONYMOUS or file-backed
///
/// Usage patterns:
/// 1. Producer creates SharedFramePool, gets fd via getFd()
/// 2. Pass fd to consumer process (via pipe, socket, or env var)
/// 3. Consumer opens pool via openFd(), reads frames with acquireLatestFrame()
const std = @import("std");
const builtin = @import("builtin");
const SharedMemory = @import("shared_memory.zig").SharedMemory;
const SharedFramePool = @import("shared_frame_pool.zig").SharedFramePool;

/// Example: Producer side (e.g., termweb writing screencast frames)
pub fn producerExample(allocator: std.mem.Allocator) !void {
    // Create shared frame pool with 8 slots, 2MB each
    var pool = try SharedFramePool.create(allocator, "termweb_screencast", .{
        .slot_count = 8,
        .slot_data_size = 2 * 1024 * 1024,
    });
    defer pool.deinit();

    // Get the file descriptor to pass to consumer
    const maybe_fd = pool.getFd();
    const total_size = pool.getTotalSize();

    std.debug.print("Shared memory created:\n", .{});
    std.debug.print("  Implementation: {s}\n", .{SharedFramePool.getInfo()});
    std.debug.print("  Total size: {} bytes\n", .{total_size});

    if (maybe_fd) |fd| {
        std.debug.print("  File descriptor: {d} (pass to consumer)\n", .{fd});
    } else {
        std.debug.print("  Anonymous mapping (same-process only)\n", .{});
    }

    // Simulate writing frames
    var frame_num: u32 = 0;
    while (frame_num < 10) : (frame_num += 1) {
        // Simulate frame data (in real use, this would be base64 JPEG from Chrome)
        var frame_data: [1024]u8 = undefined;
        @memset(&frame_data, @as(u8, @truncate(frame_num)));

        const gen = pool.writeFrameWithTimestamp(
            &frame_data,
            frame_num, // session_id
            1920, // device_width
            1080, // device_height
            std.time.milliTimestamp(), // chrome_timestamp_ms
            std.time.nanoTimestamp(), // receive_timestamp_ns
        );

        if (gen) |g| {
            std.debug.print("  Wrote frame {} (generation {})\n", .{ frame_num, g });
        } else {
            std.debug.print("  Frame {} dropped (all slots busy)\n", .{frame_num});
        }

        // Small delay to simulate frame interval
        std.time.sleep(16 * std.time.ns_per_ms);
    }
}

/// Example: Consumer side (e.g., mux server reading frames)
pub fn consumerExample(allocator: std.mem.Allocator, fd: std.posix.fd_t, size: usize) !void {
    // Open existing shared frame pool by fd
    var pool = try SharedFramePool.openFd(allocator, fd, size);
    defer pool.deinit();

    std.debug.print("Consumer attached to shared memory\n", .{});

    // Read frames in a loop
    var frames_read: u32 = 0;
    while (frames_read < 10) {
        if (pool.acquireLatestFrame()) |frame| {
            defer frame.deinit();

            std.debug.print("  Read frame: session={} size={} {}x{}\n", .{
                frame.session_id,
                frame.data.len,
                frame.device_width,
                frame.device_height,
            });

            // Calculate latency if timestamps available
            if (frame.chrome_timestamp_ms > 0) {
                const now_ms = std.time.milliTimestamp();
                const latency_ms = now_ms - frame.chrome_timestamp_ms;
                std.debug.print("    Latency: {}ms\n", .{latency_ms});
            }

            frames_read += 1;
        }

        std.time.sleep(10 * std.time.ns_per_ms);
    }
}

/// Integration example with existing FramePool interface
/// Shows how to switch between local and shared memory pools
pub fn hybridPoolExample(allocator: std.mem.Allocator, use_ipc: bool) !void {
    // The comptime selection happens at the SharedMemory level,
    // but we can also choose at runtime whether to use IPC or local pool

    if (use_ipc) {
        // IPC mode: Use shared memory pool
        var pool = try SharedFramePool.create(allocator, "termweb", .{});
        defer pool.deinit();

        std.debug.print("Using IPC shared memory pool ({s})\n", .{SharedFramePool.getInfo()});

        // Write a test frame
        _ = pool.writeFrame("test frame data", 1, 800, 600);
    } else {
        // Local mode: Use existing FramePool (from frame_pool.zig)
        const FramePool = @import("frame_pool.zig").FramePool;
        var pool = try FramePool.init(allocator);
        defer pool.deinit();

        std.debug.print("Using local in-process frame pool\n", .{});

        // Write a test frame
        _ = try pool.writeFrame("test frame data", 1, 800, 600);
    }
}

/// Simple ring buffer example (lower level)
pub fn ringBufferExample() !void {
    var shm = try SharedMemory.create("ring_test", 4096);
    defer shm.deinit();

    std.debug.print("Ring buffer example ({s}):\n", .{SharedMemory.getInfo()});

    // Producer writes
    const messages = [_][]const u8{
        "Hello from termweb!",
        "This is a test message",
        "Frame data would go here",
    };

    for (messages) |msg| {
        if (shm.write(msg)) {
            std.debug.print("  Wrote: \"{s}\"\n", .{msg});
        }
    }

    // Consumer reads
    var read_buf: [64]u8 = undefined;
    for (0..3) |_| {
        const len = shm.read(&read_buf);
        if (len > 0) {
            std.debug.print("  Read: \"{s}\"\n", .{read_buf[0..len]});
        }
    }
}

test "producer-consumer in same process" {
    const allocator = std.testing.allocator;

    // This test simulates IPC within the same process
    var pool = try SharedFramePool.create(allocator, "test", .{
        .slot_count = 4,
        .slot_data_size = 1024,
    });
    defer pool.deinit();

    // Producer writes
    _ = pool.writeFrame("frame 1", 1, 100, 100);
    _ = pool.writeFrame("frame 2", 2, 200, 200);

    // Consumer reads latest
    if (pool.acquireLatestFrame()) |frame| {
        defer frame.deinit();
        try std.testing.expectEqualStrings("frame 2", frame.data);
    } else {
        try std.testing.expect(false);
    }
}

test "platform info available" {
    const info = SharedMemory.getInfo();
    try std.testing.expect(info.len > 0);

    // On Linux, should use memfd
    if (comptime builtin.os.tag == .linux) {
        try std.testing.expect(std.mem.indexOf(u8, info, "memfd") != null);
    }
}
