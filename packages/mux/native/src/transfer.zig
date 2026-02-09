//! File transfer protocol with compression and integrity verification.
//!
//! Handles bidirectional file transfers between server and browser:
//! - Upload: Browser sends files to server filesystem
//! - Download: Server sends files/directories to browser
//!
//! Features:
//! - zstd compression for bandwidth efficiency
//! - XXH3 SIMD-accelerated hashing for integrity (3-5x faster than xxHash64)
//! - Incremental sync with hash comparison (only transfer changed files)
//! - Directory traversal with exclude patterns
//! - Dry-run preview mode
//!
//! Platform-specific async I/O:
//! - Linux: io_uring for high-performance async reads
//! - macOS: libdispatch for concurrent file operations
//!
const std = @import("std");
const fs = std.fs;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const zstd = @import("zstd.zig");

/// Errors that can occur during async I/O operations.
pub const IoError = error{
    /// Async read operation failed.
    ReadFailed,
    /// No data returned from read operation.
    NoData,
    /// Invalid arguments provided.
    InvalidArgs,
} || std.mem.Allocator.Error;

/// Errors that can occur during compression operations.
pub const CompressionError = error{
    /// Parallel compression failed.
    CompressionFailed,
} || std.mem.Allocator.Error || zstd.Error;

/// XXH3 SIMD-accelerated hashing.
/// Uses NEON on ARM64 and AVX2/SSE2 on x86-64.
extern fn XXH3_64bits(input: ?*const anyopaque, length: usize) u64;

inline fn xxh3Hash(data: []const u8) u64 {
    return XXH3_64bits(data.ptr, data.len);
}

const is_linux = builtin.os.tag == .linux;
const is_darwin = builtin.os.tag == .macos;

/// Chunk size for parallel compression (256KB).
/// Balances parallelism overhead with compression efficiency.
const default_chunk_size = 256 * 1024;

/// Files smaller than this threshold are batched together for better compression.
/// 16KB captures most JS/TS source files, package.json, type declarations, etc.
pub const batch_threshold: u64 = 16 * 1024;

/// High water mark for dispatch I/O (256KB).
/// Controls buffer size for macOS async I/O.
const dispatch_high_water = 256 * 1024;

/// Maximum file size to read into memory (1MB).
const max_read_size = 1024 * 1024;

// Platform-specific imports
const dispatch = if (is_darwin) @cImport({
    @cInclude("dispatch/dispatch.h");
}) else void;

// Linux io_uring
const linux = if (is_linux) std.os.linux else void;
const IoUring = if (is_linux) linux.IoUring else void;


// Linux io_uring for async I/O


pub const IoUringReader = if (is_linux) struct {
    ring: IoUring,
    fd: posix.fd_t,

    pub fn init(fd: posix.fd_t) !@This() {
        const ring = try IoUring.init(32, 0);
        return .{ .ring = ring, .fd = fd };
    }

    pub fn deinit(self: *@This()) void {
        self.ring.deinit();
    }

    // Read file data using io_uring
    pub fn read(self: *@This(), offset: u64, length: usize, allocator: Allocator) ![]u8 {
        const buf = try allocator.alloc(u8, length);
        errdefer allocator.free(buf);

        // Submit read request
        _ = try self.ring.read(0, self.fd, .{ .buffer = buf }, offset);
        _ = try self.ring.submit();

        // Wait for completion
        var cqes: [1]linux.io_uring_cqe = undefined;
        _ = try self.ring.copy_cqes(&cqes, 1);

        const cqe = cqes[0];
        if (cqe.res < 0) {
            allocator.free(buf);
            return error.ReadFailed;
        }

        const bytes_read: usize = @intCast(cqe.res);
        return buf[0..bytes_read];
    }

    // Submit multiple reads and wait for all (pipelined)
    pub fn readMultiple(
        self: *@This(),
        offsets: []const u64,
        lengths: []const usize,
        allocator: Allocator,
    ) ![][]u8 {
        if (offsets.len != lengths.len) return error.InvalidArgs;
        if (offsets.len == 0) return &[_][]u8{};

        const count = offsets.len;
        const results = try allocator.alloc([]u8, count);
        errdefer allocator.free(results);

        // Allocate buffers and submit all reads
        for (0..count) |i| {
            const buf = try allocator.alloc(u8, lengths[i]);
            results[i] = buf;

            _ = try self.ring.read(@intCast(i), self.fd, .{ .buffer = buf }, offsets[i]);
        }

        _ = try self.ring.submit();

        // Wait for all completions
        var completed: usize = 0;
        while (completed < count) {
            var cqes: [32]linux.io_uring_cqe = undefined;
            const n = try self.ring.copy_cqes(&cqes, 1);
            for (cqes[0..n]) |cqe| {
                if (cqe.res < 0) {
                    // Free all on error
                    for (results) |buf| allocator.free(buf);
                    allocator.free(results);
                    return error.ReadFailed;
                }
                const idx: usize = @intCast(cqe.user_data);
                const bytes_read: usize = @intCast(cqe.res);
                results[idx] = results[idx][0..bytes_read];
                completed += 1;
            }
        }

        return results;
    }
} else struct {
    // Non-Linux fallback
    fd: posix.fd_t,

    pub fn init(fd: posix.fd_t) !@This() {
        return .{ .fd = fd };
    }

    pub fn deinit(_: *@This()) void {}

    pub fn read(self: *@This(), offset: u64, length: usize, allocator: Allocator) ![]u8 {
        const file = std.fs.File{ .handle = self.fd };
        try file.seekTo(offset);
        const buf = try allocator.alloc(u8, length);
        const n = try file.read(buf);
        return buf[0..n];
    }

    pub fn readMultiple(
        self: *@This(),
        offsets: []const u64,
        lengths: []const usize,
        allocator: Allocator,
    ) ![][]u8 {
        const results = try allocator.alloc([]u8, offsets.len);
        for (offsets, lengths, 0..) |offset, length, i| {
            results[i] = try self.read(offset, length, allocator);
        }
        return results;
    }
};


// macOS dispatch_io for async/parallel I/O


pub const DispatchIO = if (is_darwin) struct {
    channel: dispatch.dispatch_io_t,
    queue: dispatch.dispatch_queue_t,

    pub fn init(fd: posix.fd_t) @This() {
        const queue = dispatch.dispatch_get_global_queue(dispatch.DISPATCH_QUEUE_PRIORITY_HIGH, 0);
        const channel = dispatch.dispatch_io_create(
            dispatch.DISPATCH_IO_RANDOM,
            fd,
            queue,
            null, // cleanup handler
        );
        dispatch.dispatch_io_set_high_water(channel, dispatch_high_water);
        return .{ .channel = channel, .queue = queue };
    }

    pub fn deinit(self: *@This()) void {
        dispatch.dispatch_io_close(self.channel, dispatch.DISPATCH_IO_STOP);
        dispatch.dispatch_release(self.channel);
    }

    const ReadState = struct {
        result: *?[]u8,
        err: *bool,
        sema: dispatch.dispatch_semaphore_t,
        alloc: Allocator,
    };

    /// Read a single chunk. Blocks via dispatch_semaphore (no busy-wait).
    pub fn read(self: *@This(), offset: u64, length: usize, allocator: Allocator) ![]u8 {
        var result: ?[]u8 = null;
        var read_error: bool = false;
        const sema = dispatch.dispatch_semaphore_create(0);
        defer dispatch.dispatch_release(sema);

        var state = ReadState{
            .result = &result,
            .err = &read_error,
            .sema = sema,
            .alloc = allocator,
        };

        dispatch.dispatch_io_read(
            self.channel,
            @intCast(offset),
            length,
            self.queue,
            &handleReadComplete,
            @ptrCast(&state),
        );

        _ = dispatch.dispatch_semaphore_wait(sema, dispatch.DISPATCH_TIME_FOREVER);

        if (read_error) return error.ReadFailed;
        return result orelse error.NoData;
    }

    /// Read multiple chunks in parallel. All reads are dispatched at once,
    /// then we wait for all completions via semaphore.
    pub fn readMultiple(
        self: *@This(),
        offsets: []const u64,
        lengths: []const usize,
        allocator: Allocator,
    ) ![][]u8 {
        const count = offsets.len;
        if (count == 0) return &[_][]u8{};

        const results_opt = try allocator.alloc(?[]u8, count);
        defer allocator.free(results_opt);
        @memset(results_opt, null);

        const errors = try allocator.alloc(bool, count);
        defer allocator.free(errors);
        @memset(errors, false);

        const sema = dispatch.dispatch_semaphore_create(0);
        defer dispatch.dispatch_release(sema);

        const states = try allocator.alloc(ReadState, count);
        defer allocator.free(states);

        // Dispatch all reads
        for (0..count) |i| {
            states[i] = .{
                .result = &results_opt[i],
                .err = &errors[i],
                .sema = sema,
                .alloc = allocator,
            };
            dispatch.dispatch_io_read(
                self.channel,
                @intCast(offsets[i]),
                lengths[i],
                self.queue,
                &handleReadComplete,
                @ptrCast(&states[i]),
            );
        }

        // Wait for all completions (each signals the semaphore once)
        for (0..count) |_| {
            _ = dispatch.dispatch_semaphore_wait(sema, dispatch.DISPATCH_TIME_FOREVER);
        }

        // Collect results
        const results = try allocator.alloc([]u8, count);
        for (0..count) |i| {
            if (errors[i] or results_opt[i] == null) {
                // Free all on error
                for (0..i) |j| allocator.free(results[j]);
                for (results_opt) |r| if (r) |buf| allocator.free(buf);
                allocator.free(results);
                return error.ReadFailed;
            }
            results[i] = results_opt[i].?;
        }
        return results;
    }

    fn handleReadComplete(ctx: ?*anyopaque, data: dispatch.dispatch_data_t, err: c_int) callconv(.C) void {
        if (comptime !is_darwin) return;
        const state = @as(*ReadState, @ptrCast(@alignCast(ctx)));
        defer _ = dispatch.dispatch_semaphore_signal(state.sema);

        if (err != 0) {
            state.err.* = true;
            return;
        }
        if (data != null) {
            var buffer: ?*const anyopaque = null;
            var size: usize = 0;
            _ = dispatch.dispatch_data_create_map(data, &buffer, &size);
            if (buffer != null and size > 0) {
                const buf = state.alloc.alloc(u8, size) catch {
                    state.err.* = true;
                    return;
                };
                @memcpy(buf, @as([*]const u8, @ptrCast(buffer))[0..size]);
                state.result.* = buf;
            }
        }
    }
} else struct {
    // Non-macOS: compile-only stub — callers must guard with comptime is_darwin
    fd: posix.fd_t,

    pub fn init(fd: posix.fd_t) @This() {
        return .{ .fd = fd };
    }
    pub fn deinit(_: *@This()) void {}
    pub fn read(_: *@This(), _: u64, _: usize, _: Allocator) ![]u8 {
        @compileError("DispatchIO is macOS-only; wrap call with comptime is_darwin guard");
    }
    pub fn readMultiple(_: *@This(), _: []const u64, _: []const usize, _: Allocator) ![][]u8 {
        @compileError("DispatchIO is macOS-only; wrap call with comptime is_darwin guard");
    }
};


// Multi-file batch reader — io_uring on Linux, dispatch_apply + pread on macOS


/// Batched multi-file reader that minimizes syscall overhead.
/// On Linux: uses io_uring to batch openat/read/close across multiple files.
/// On macOS: uses dispatch_apply for parallel pread.
/// Fallback: sequential pread.
pub const MultiFileReader = if (is_linux) struct {
    ring: IoUring,
    dir_fd: posix.fd_t,
    allocator: Allocator,

    /// Ring size 256: accommodates batches of up to ~128 files
    /// (2 SQEs per file in phase 2: linked read + close).
    const ring_size: u13 = 256;
    /// Max files per io_uring batch (ring_size / 2 for read+close pairs).
    const batch_limit: usize = 128;

    pub const ReadResult = struct {
        data: []u8,
        size: usize,
    };

    pub fn init(dir_fd: posix.fd_t, allocator: Allocator) !@This() {
        const ring = try IoUring.init(ring_size, 0);
        return .{ .ring = ring, .dir_fd = dir_fd, .allocator = allocator };
    }

    pub fn deinit(self: *@This()) void {
        self.ring.deinit();
    }

    /// Batch-read multiple files relative to dir_fd.
    /// Uses two-phase io_uring: phase 1 opens all files, phase 2 reads+closes them.
    /// Returns owned ReadResult array; caller must free each .data and the slice.
    pub fn readFiles(
        self: *@This(),
        paths: []const [*:0]const u8,
        sizes: []const u64,
    ) ![]ReadResult {
        const count = paths.len;
        if (count == 0) return &[_]ReadResult{};

        const results = try self.allocator.alloc(ReadResult, count);
        @memset(results, ReadResult{ .data = &[_]u8{}, .size = 0 });
        errdefer {
            for (results) |r| {
                if (r.data.len > 0) self.allocator.free(r.data);
            }
            self.allocator.free(results);
        }

        // Process in chunks of batch_limit
        var offset: usize = 0;
        while (offset < count) {
            const batch_end = @min(offset + batch_limit, count);
            try self.readFilesBatch(
                paths[offset..batch_end],
                sizes[offset..batch_end],
                results[offset..batch_end],
            );
            offset = batch_end;
        }

        return results;
    }

    fn readFilesBatch(
        self: *@This(),
        paths: []const [*:0]const u8,
        sizes: []const u64,
        results: []ReadResult,
    ) !void {
        const batch_count = paths.len;

        // Phase 1: Batch OPENAT — submit all opens in one syscall
        const fds = try self.allocator.alloc(posix.fd_t, batch_count);
        defer self.allocator.free(fds);
        @memset(fds, -1);

        for (paths, 0..) |path, i| {
            _ = try self.ring.openat(
                @intCast(i), // user_data = file index
                self.dir_fd,
                path,
                .{ .ACCMODE = .RDONLY },
                0,
            );
        }
        _ = try self.ring.submit();

        // Collect OPENAT completions
        var completed: usize = 0;
        while (completed < batch_count) {
            var cqes: [32]linux.io_uring_cqe = undefined;
            const n = try self.ring.copy_cqes(&cqes, 1);
            for (cqes[0..n]) |cqe| {
                const idx: usize = @intCast(cqe.user_data);
                if (cqe.res >= 0) {
                    fds[idx] = @intCast(cqe.res);
                }
                // On error, fd stays -1 (file skipped)
                completed += 1;
            }
        }

        // Phase 2: Batch READ + CLOSE for each successfully opened fd
        var read_count: usize = 0;
        for (fds, 0..) |fd, i| {
            if (fd < 0) continue;

            const size: usize = @intCast(sizes[i]);
            const buf = self.allocator.alloc(u8, size) catch {
                posix.close(fd);
                continue;
            };
            results[i].data = buf;

            // Submit linked READ → CLOSE
            const read_sqe = self.ring.read(
                @as(u64, @intCast(i)) | (1 << 32), // user_data: index + read flag
                fd,
                .{ .buffer = buf },
                0,
            ) catch {
                self.allocator.free(buf);
                results[i].data = &[_]u8{};
                posix.close(fd);
                continue;
            };
            read_sqe.flags |= linux.IOSQE_IO_LINK;

            _ = self.ring.close(
                @as(u64, @intCast(i)) | (2 << 32), // user_data: index + close flag
                fd,
            ) catch {
                // If we can't queue close, close manually after read completes
                continue;
            };

            read_count += 1;
        }

        if (read_count == 0) return;
        _ = try self.ring.submit();

        // Collect READ + CLOSE completions (2 CQEs per file)
        var read_completed: usize = 0;
        const total_cqes = read_count * 2;
        while (read_completed < total_cqes) {
            var cqes: [32]linux.io_uring_cqe = undefined;
            const n = try self.ring.copy_cqes(&cqes, 1);
            for (cqes[0..n]) |cqe| {
                const idx: usize = @intCast(cqe.user_data & 0xFFFFFFFF);
                const op: u2 = @truncate(cqe.user_data >> 32);

                if (op == 1) { // READ
                    if (cqe.res >= 0) {
                        results[idx].size = @intCast(cqe.res);
                    } else {
                        // Read failed — free buffer
                        if (results[idx].data.len > 0) {
                            self.allocator.free(results[idx].data);
                            results[idx] = .{ .data = &[_]u8{}, .size = 0 };
                        }
                    }
                }
                // op == 2 (CLOSE) — nothing to do
                read_completed += 1;
            }
        }
    }

    /// Batch-read files and compute xxh3 hash for each.
    /// Returns array of hashes (0 on per-file failure). Caller owns the slice.
    pub fn readAndHashFiles(
        self: *@This(),
        paths: []const [*:0]const u8,
        sizes: []const u64,
    ) ![]u64 {
        const results = try self.readFiles(paths, sizes);
        defer {
            for (results) |r| {
                if (r.data.len > 0) self.allocator.free(r.data);
            }
            self.allocator.free(results);
        }

        const hashes = try self.allocator.alloc(u64, paths.len);
        for (results, 0..) |r, i| {
            hashes[i] = if (r.size > 0) xxh3Hash(r.data[0..r.size]) else 0;
        }
        return hashes;
    }
} else struct {
    // Non-Linux: dispatch_apply on macOS, sequential on other platforms
    dir_fd: posix.fd_t,
    allocator: Allocator,

    pub const ReadResult = struct { data: []u8, size: usize };

    pub fn init(dir_fd: posix.fd_t, allocator: Allocator) !@This() {
        return .{ .dir_fd = dir_fd, .allocator = allocator };
    }

    pub fn deinit(_: *@This()) void {}

    pub fn readFiles(
        self: *@This(),
        paths: []const [*:0]const u8,
        sizes: []const u64,
    ) ![]ReadResult {
        const count = paths.len;
        if (count == 0) return &[_]ReadResult{};

        const results = try self.allocator.alloc(ReadResult, count);
        @memset(results, ReadResult{ .data = &[_]u8{}, .size = 0 });

        if (comptime is_darwin) {
            // macOS: parallel reads via dispatch_apply
            const Ctx = struct {
                dir_fd: posix.fd_t,
                paths: []const [*:0]const u8,
                sizes: []const u64,
                results: []ReadResult,
                alloc: Allocator,
            };
            var ctx = Ctx{
                .dir_fd = self.dir_fd,
                .paths = paths,
                .sizes = sizes,
                .results = results,
                .alloc = self.allocator,
            };
            const queue = dispatch.dispatch_get_global_queue(dispatch.DISPATCH_QUEUE_PRIORITY_HIGH, 0);
            dispatch.dispatch_apply(count, queue, &dispatchReadFile, @ptrCast(&ctx));
        } else {
            // Sequential fallback
            for (paths, sizes, 0..) |path, size, i| {
                self.readSingleFile(path, @intCast(size), &results[i]);
            }
        }
        return results;
    }

    fn dispatchReadFile(context: ?*anyopaque, idx: usize) callconv(.C) void {
        if (comptime is_darwin) {
            const Ctx = struct {
                dir_fd: posix.fd_t,
                paths: []const [*:0]const u8,
                sizes: []const u64,
                results: []ReadResult,
                alloc: Allocator,
            };
            const ctx = @as(*Ctx, @ptrCast(@alignCast(context)));
            const self_proxy = @This(){ .dir_fd = ctx.dir_fd, .allocator = ctx.alloc };
            _ = self_proxy;

            const size: usize = @intCast(ctx.sizes[idx]);
            const buf = ctx.alloc.alloc(u8, size) catch return;

            const fd = posix.openatZ(ctx.dir_fd, ctx.paths[idx], .{ .ACCMODE = .RDONLY }, 0) catch {
                ctx.alloc.free(buf);
                return;
            };
            defer posix.close(fd);

            const file = std.fs.File{ .handle = fd };
            const n = file.preadAll(buf, 0) catch {
                ctx.alloc.free(buf);
                return;
            };

            ctx.results[idx] = .{ .data = buf, .size = n };
        }
    }

    fn readSingleFile(self: *@This(), path: [*:0]const u8, size: usize, result: *ReadResult) void {
        const buf = self.allocator.alloc(u8, size) catch return;
        const fd = posix.openatZ(self.dir_fd, path, .{ .ACCMODE = .RDONLY }, 0) catch {
            self.allocator.free(buf);
            return;
        };
        defer posix.close(fd);

        const file = std.fs.File{ .handle = fd };
        const n = file.preadAll(buf, 0) catch {
            self.allocator.free(buf);
            return;
        };

        result.* = .{ .data = buf, .size = n };
    }

    pub fn readAndHashFiles(
        self: *@This(),
        paths: []const [*:0]const u8,
        sizes: []const u64,
    ) ![]u64 {
        const results = try self.readFiles(paths, sizes);
        defer {
            for (results) |r| {
                if (r.data.len > 0) self.allocator.free(r.data);
            }
            self.allocator.free(results);
        }

        const hashes = try self.allocator.alloc(u64, paths.len);
        for (results, 0..) |r, i| {
            hashes[i] = if (r.size > 0) xxh3Hash(r.data[0..r.size]) else 0;
        }
        return hashes;
    }
};


// Parallel Chunk Compression (dispatch on macOS)


pub const ParallelCompressor = struct {
    const CHUNK_SIZE: usize = default_chunk_size;

    // Compress multiple chunks in parallel using dispatch on macOS
    // Returns array of compressed chunks - caller owns all memory
    pub fn compressChunksParallel(
        allocator: Allocator,
        data: []const u8,
        compression_level: c_int,
    ) ![][]u8 {
        if (data.len == 0) return &[_][]u8{};

        // Calculate number of chunks
        const chunk_count = (data.len + CHUNK_SIZE - 1) / CHUNK_SIZE;
        const results = try allocator.alloc([]u8, chunk_count);
        @memset(results, &[_]u8{});

        // Track errors
        const errors = try allocator.alloc(bool, chunk_count);
        defer allocator.free(errors);
        @memset(errors, false);

        if (comptime is_darwin) {
            // Use dispatch_apply for parallel compression on macOS
            const queue = dispatch.dispatch_get_global_queue(dispatch.DISPATCH_QUEUE_PRIORITY_HIGH, 0);

            const Context = struct {
                data: []const u8,
                results: [][]u8,
                errors: []bool,
                alloc: Allocator,
                level: c_int,
            };
            var ctx = Context{
                .data = data,
                .results = results,
                .errors = errors,
                .alloc = allocator,
                .level = compression_level,
            };

            dispatch.dispatch_apply(chunk_count, queue, &dispatchCompress, @ptrCast(&ctx));

            // Check for errors
            for (errors, 0..) |err, i| {
                if (err) {
                    // Free all allocated chunks
                    for (results) |chunk| {
                        if (chunk.len > 0) allocator.free(chunk);
                    }
                    allocator.free(results);
                    return error.CompressionFailed;
                }
                _ = i;
            }
        } else {
            // Linux: parallel compression using threads
            const max_threads: usize = 8;
            const thread_count = @min(chunk_count, max_threads);

            if (thread_count <= 1) {
                // Single chunk: no threading overhead
                const compressed = zstd.compressSimple(allocator, data, compression_level) catch {
                    allocator.free(results);
                    return error.CompressionFailed;
                };
                results[0] = compressed;
            } else {
                const ThreadCtx = struct {
                    data: []const u8,
                    results: [][]u8,
                    errors: []bool,
                    alloc: Allocator,
                    level: c_int,
                    chunk_count: usize,
                };
                var ctx = ThreadCtx{
                    .data = data,
                    .results = results,
                    .errors = errors,
                    .alloc = allocator,
                    .level = compression_level,
                    .chunk_count = chunk_count,
                };

                // Spawn worker threads
                var threads: [8]?std.Thread = .{null} ** 8;
                for (0..thread_count) |t| {
                    threads[t] = std.Thread.spawn(.{}, threadCompress, .{ &ctx, t, thread_count }) catch null;
                }

                // Wait for all threads
                for (0..thread_count) |t| {
                    if (threads[t]) |thread| thread.join();
                }

                // Check for errors
                for (errors) |err| {
                    if (err) {
                        for (results) |chunk| {
                            if (chunk.len > 0) allocator.free(chunk);
                        }
                        allocator.free(results);
                        return error.CompressionFailed;
                    }
                }
            }
        }

        return results;
    }

    fn dispatchCompress(context: ?*anyopaque, idx: usize) callconv(.C) void {
        if (comptime is_darwin) {
            const Context = struct {
                data: []const u8,
                results: [][]u8,
                errors: []bool,
                alloc: Allocator,
                level: c_int,
            };
            const ctx = @as(*Context, @ptrCast(@alignCast(context)));

            const start = idx * CHUNK_SIZE;
            const end = @min(start + CHUNK_SIZE, ctx.data.len);
            const chunk = ctx.data[start..end];

            // Use zstd for compression
            const compressed = zstd.compressSimple(ctx.alloc, chunk, ctx.level) catch {
                ctx.errors[idx] = true;
                return;
            };

            ctx.results[idx] = compressed;
        }
    }

    fn threadCompress(ctx: anytype, thread_id: usize, thread_count: usize) void {
        // Each thread handles a strided range of chunks
        var i = thread_id;
        while (i < ctx.chunk_count) : (i += thread_count) {
            const start = i * CHUNK_SIZE;
            const end = @min(start + CHUNK_SIZE, ctx.data.len);
            const chunk = ctx.data[start..end];

            const compressed = zstd.compressSimple(ctx.alloc, chunk, ctx.level) catch {
                ctx.errors[i] = true;
                return;
            };

            ctx.results[i] = compressed;
        }
    }

    // Free all compressed chunks
    pub fn freeChunks(allocator: Allocator, chunks: [][]u8) void {
        for (chunks) |chunk| {
            if (chunk.len > 0) allocator.free(chunk);
        }
        allocator.free(chunks);
    }
};


// Parallel File Hasher (dispatch on macOS)


// Parallel file hasher - dispatch on macOS, thread pool on Linux
pub const ParallelHasher = struct {
    // Hash multiple files in parallel
    pub fn hashFilesParallel(
        allocator: Allocator,
        dir: fs.Dir,
        file_names: []const []const u8,
    ) ![]u64 {
        const results = try allocator.alloc(u64, file_names.len);
        @memset(results, 0);

        if (comptime is_darwin) {
            // Use dispatch_apply for parallel iteration on macOS
            const queue = dispatch.dispatch_get_global_queue(dispatch.DISPATCH_QUEUE_PRIORITY_HIGH, 0);

            const Context = struct {
                dir: fs.Dir,
                names: []const []const u8,
                hashes: []u64,
            };
            var ctx = Context{ .dir = dir, .names = file_names, .hashes = results };

            dispatch.dispatch_apply(file_names.len, queue, &dispatchWork, @ptrCast(&ctx));
        } else {
            // Threaded hashing on Linux (up to 8 threads, strided)
            if (file_names.len <= 2) {
                // Too few files to justify threading overhead
                for (file_names, 0..) |name, i| {
                    results[i] = hashFileMmapStatic(dir, name) catch 0;
                }
            } else {
                const thread_count = @min(file_names.len, 8);
                const HashThreadCtx = struct {
                    dir: fs.Dir,
                    names: []const []const u8,
                    hashes: []u64,
                };
                var ctx = HashThreadCtx{
                    .dir = dir,
                    .names = file_names,
                    .hashes = results,
                };

                var threads: [8]?std.Thread = .{null} ** 8;
                for (0..thread_count) |t| {
                    threads[t] = std.Thread.spawn(.{}, threadHash, .{ &ctx, t, thread_count }) catch null;
                }
                for (0..thread_count) |t| {
                    if (threads[t]) |thread| thread.join();
                }
            }
        }

        return results;
    }

    fn dispatchWork(context: ?*anyopaque, idx: usize) callconv(.C) void {
        if (comptime is_darwin) {
            const Context = struct {
                dir: fs.Dir,
                names: []const []const u8,
                hashes: []u64,
            };
            const ctx = @as(*Context, @ptrCast(@alignCast(context)));
            ctx.hashes[idx] = hashFileMmapStatic(ctx.dir, ctx.names[idx]) catch 0;
        }
    }

    fn threadHash(ctx: anytype, thread_id: usize, thread_count: usize) void {
        var i = thread_id;
        while (i < ctx.names.len) : (i += thread_count) {
            ctx.hashes[i] = hashFileMmapStatic(ctx.dir, ctx.names[i]) catch 0;
        }
    }

    fn hashFileMmapStatic(dir: fs.Dir, name: []const u8) !u64 {
        var mapped = try MappedFile.initFromDir(dir, name);
        defer mapped.deinit();
        mapped.adviseSequential();
        return xxh3Hash(mapped.data);
    }
};

// Memory-mapped file for zero-copy reads
pub const MappedFile = struct {
    data: []align(std.heap.page_size_min) u8,
    fd: posix.fd_t,

    pub fn init(path: []const u8) !MappedFile {
        const fd = try posix.open(path, .{ .ACCMODE = .RDONLY }, 0);
        errdefer posix.close(fd);

        const stat = try posix.fstat(fd);
        const size: usize = @intCast(stat.size);

        if (size == 0) {
            return MappedFile{ .data = &[_]u8{}, .fd = fd };
        }

        const mapped = try posix.mmap(
            null,
            size,
            posix.PROT.READ,
            .{ .TYPE = .SHARED },
            fd,
            0,
        );

        return MappedFile{
            .data = mapped[0..size],
            .fd = fd,
        };
    }

    pub fn initFromDir(dir: fs.Dir, name: []const u8) !MappedFile {
        const fd = try posix.openat(dir.fd, name, .{ .ACCMODE = .RDONLY }, 0);
        errdefer posix.close(fd);

        const stat = try posix.fstat(fd);
        const size: usize = @intCast(stat.size);

        if (size == 0) {
            return MappedFile{ .data = &[_]u8{}, .fd = fd };
        }

        const mapped = try posix.mmap(
            null,
            size,
            posix.PROT.READ,
            .{ .TYPE = .SHARED },
            fd,
            0,
        );

        return MappedFile{
            .data = mapped[0..size],
            .fd = fd,
        };
    }

    pub fn deinit(self: *MappedFile) void {
        if (self.data.len > 0) {
            posix.munmap(self.data);
        }
        posix.close(self.fd);
    }

    // Advise kernel about access pattern for better performance
    pub fn adviseSequential(self: *MappedFile) void {
        if (self.data.len == 0) return;
        posix.madvise(self.data.ptr, self.data.len, posix.MADV.SEQUENTIAL) catch {};
    }

    pub fn adviseWillNeed(self: *MappedFile) void {
        if (self.data.len == 0) return;
        posix.madvise(self.data.ptr, self.data.len, posix.MADV.WILLNEED) catch {};
    }
};


// File Transfer Protocol


// Message types from client (0x20-0x2F)
pub const ClientMsgType = enum(u8) {
    transfer_init = 0x20,     // Start transfer
    file_list_request = 0x21, // Request folder listing
    file_data = 0x22,         // File chunk data (upload)
    transfer_resume = 0x23,   // Resume interrupted transfer
    transfer_cancel = 0x24,   // Cancel transfer
    // Rsync/sync messages
    sync_request = 0x25,      // Start incremental sync
    block_checksums = 0x26,   // Client sends block checksums of cached copy
    sync_ack = 0x27,          // Client confirms delta applied
};

// Message types from server (0x30-0x3F)
pub const ServerMsgType = enum(u8) {
    transfer_ready = 0x30,    // Session created
    file_list = 0x31,         // File listing response
    file_request = 0x32,      // Request next chunk (download)
    file_ack = 0x33,          // Acknowledge chunk
    transfer_complete = 0x34, // Done
    transfer_error = 0x35,    // Error
    dry_run_report = 0x36,    // Preview results
    batch_data = 0x37,        // Batched small files (compressed together)
    // Rsync/sync messages
    sync_file_list = 0x38,    // File list for sync (with mtime comparison)
    delta_data = 0x39,        // Delta commands (COPY + LITERAL)
    sync_complete = 0x3A,     // Sync finished
};

// Transfer direction
pub const TransferDirection = enum(u8) {
    upload = 0,   // Browser -> Server
    download = 1, // Server -> Browser
};

// Transfer flags (bit field)
pub const TransferFlags = packed struct {
    delete_extra: bool = false,  // Delete files not in source
    dry_run: bool = false,       // Preview only, don't transfer
    _reserved: u6 = 0,
};

// File entry in file list
pub const FileEntry = struct {
    path: []const u8,
    size: u64,
    mtime: u64,      // Modification time (Unix timestamp)
    hash: u64,       // xxHash64 of file content
    is_dir: bool,

    pub fn deinit(self: *FileEntry, allocator: Allocator) void {
        allocator.free(self.path);
    }
};

// Dry run action types
pub const DryRunAction = enum(u8) {
    create = 0,
    update = 1,
    delete = 2,
};


// Transfer Session


pub const TransferSession = struct {
    id: u32,
    direction: TransferDirection,
    flags: TransferFlags,
    base_path: []const u8,       // Server-side base path
    exclude_patterns: std.ArrayListUnmanaged([]const u8),

    // File list
    files: std.ArrayListUnmanaged(FileEntry),
    total_bytes: u64,

    // Progress tracking
    current_file_index: u32,
    current_file_offset: u64,
    bytes_transferred: u64,

    // State
    is_active: bool,
    allocator: Allocator,

    // Compression (zstd)
    compressor: ?zstd.Compressor,
    decompressor: ?zstd.Decompressor,

    // Currently mapped file for streaming downloads
    current_mapped_file: ?MappedFile,

    pub fn init(allocator: Allocator, id: u32, direction: TransferDirection, flags: TransferFlags, base_path: []const u8) !*TransferSession {
        const session = try allocator.create(TransferSession);
        session.* = .{
            .id = id,
            .direction = direction,
            .flags = flags,
            .base_path = try allocator.dupe(u8, base_path),
            .exclude_patterns = .{},
            .files = .{},
            .total_bytes = 0,
            .current_file_index = 0,
            .current_file_offset = 0,
            .bytes_transferred = 0,
            .is_active = true,
            .allocator = allocator,
            .compressor = zstd.Compressor.init(allocator, 3) catch null,
            .decompressor = zstd.Decompressor.init(allocator) catch null,
            .current_mapped_file = null,
        };
        return session;
    }

    pub fn deinit(self: *TransferSession) void {
        // Close any mapped file
        if (self.current_mapped_file) |*mf| {
            mf.deinit();
        }

        self.allocator.free(self.base_path);

        for (self.exclude_patterns.items) |pattern| {
            self.allocator.free(pattern);
        }
        self.exclude_patterns.deinit(self.allocator);

        for (self.files.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.files.deinit(self.allocator);

        // Free zstd resources - null out after freeing to prevent double-free
        if (self.compressor) |*comp| {
            comp.deinit();
            self.compressor = null;
        }
        if (self.decompressor) |*decomp| {
            decomp.deinit();
            self.decompressor = null;
        }

        self.allocator.destroy(self);
    }

    // Add exclude pattern
    pub fn addExcludePattern(self: *TransferSession, pattern: []const u8) !void {
        try self.exclude_patterns.append(self.allocator, try self.allocator.dupe(u8, pattern));
    }

    // Check if path matches any exclude pattern
    pub fn isExcluded(self: *const TransferSession, path: []const u8) bool {
        for (self.exclude_patterns.items) |pattern| {
            if (matchGlob(pattern, path)) return true;
        }
        return false;
    }

    // Build file list from directory (for downloads)
    pub fn buildFileList(self: *TransferSession) !void {
        self.files.clearRetainingCapacity();
        self.total_bytes = 0;

        var dir = fs.openDirAbsolute(self.base_path, .{ .iterate = true }) catch |err| {
            std.debug.print("Failed to open directory {s}: {}\n", .{ self.base_path, err });
            return err;
        };
        defer dir.close();

        try self.walkDirectory(dir, "");
    }

    fn walkDirectory(self: *TransferSession, dir: fs.Dir, prefix: []const u8) !void {
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            // Build relative path
            const rel_path = if (prefix.len > 0)
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, entry.name })
            else
                try self.allocator.dupe(u8, entry.name);

            // Check exclusion
            if (self.isExcluded(rel_path)) {
                self.allocator.free(rel_path);
                continue;
            }

            if (entry.kind == .directory) {
                // Add directory entry
                try self.files.append(self.allocator, .{
                    .path = rel_path,
                    .size = 0,
                    .mtime = 0,
                    .hash = 0,
                    .is_dir = true,
                });

                // Recurse into subdirectory
                var subdir = dir.openDir(entry.name, .{ .iterate = true }) catch continue;
                defer subdir.close();
                try self.walkDirectory(subdir, rel_path);
            } else if (entry.kind == .file) {
                // Get file stats
                const stat = dir.statFile(entry.name) catch continue;
                const mtime: u64 = @intCast(@divFloor(stat.mtime, std.time.ns_per_s));

                // Hash file using mmap for zero-copy
                const hash = self.hashFileMmap(dir, entry.name) catch 0;

                try self.files.append(self.allocator, .{
                    .path = rel_path,
                    .size = stat.size,
                    .mtime = mtime,
                    .hash = hash,
                    .is_dir = false,
                });

                self.total_bytes += stat.size;
            } else {
                self.allocator.free(rel_path);
            }
        }
    }

    // Hash a file using mmap + xxHash64 (zero-copy)
    fn hashFileMmap(self: *TransferSession, dir: fs.Dir, name: []const u8) !u64 {
        _ = self;

        var mapped = try MappedFile.initFromDir(dir, name);
        defer mapped.deinit();

        // Tell kernel we're reading sequentially
        mapped.adviseSequential();

        // xxHash64 on the entire mapped region - single pass, no copies
        return xxh3Hash(mapped.data);
    }

    /// Build file list with deferred batch hashing.
    /// Phase 1: walk directory tree without hashing (hash = 0).
    /// Phase 2: batch-hash all files using MultiFileReader (io_uring/dispatch_apply).
    /// Falls back to sync buildFileList on failure.
    pub fn buildFileListAsync(self: *TransferSession) !void {
        self.files.clearRetainingCapacity();
        self.total_bytes = 0;

        var dir = fs.openDirAbsolute(self.base_path, .{ .iterate = true }) catch |err| {
            std.debug.print("Failed to open directory {s}: {}\n", .{ self.base_path, err });
            return err;
        };
        defer dir.close();

        // Phase 1: walk without hashing
        try self.walkDirectoryNoHash(dir, "");

        // Phase 2: batch hash all non-directory files
        self.batchHashFiles(dir) catch {
            // Fallback: hash each file individually (same as sync buildFileList)
            for (self.files.items) |*entry| {
                if (!entry.is_dir and entry.hash == 0 and entry.size > 0) {
                    entry.hash = self.hashFileMmap(dir, entry.path) catch 0;
                }
            }
        };
    }

    /// Walk directory tree without hashing (deferred for batch hashing).
    fn walkDirectoryNoHash(self: *TransferSession, dir: fs.Dir, prefix: []const u8) !void {
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            const rel_path = if (prefix.len > 0)
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, entry.name })
            else
                try self.allocator.dupe(u8, entry.name);

            if (self.isExcluded(rel_path)) {
                self.allocator.free(rel_path);
                continue;
            }

            if (entry.kind == .directory) {
                try self.files.append(self.allocator, .{
                    .path = rel_path,
                    .size = 0,
                    .mtime = 0,
                    .hash = 0,
                    .is_dir = true,
                });

                var subdir = dir.openDir(entry.name, .{ .iterate = true }) catch continue;
                defer subdir.close();
                try self.walkDirectoryNoHash(subdir, rel_path);
            } else if (entry.kind == .file) {
                const stat = dir.statFile(entry.name) catch continue;
                const mtime: u64 = @intCast(@divFloor(stat.mtime, std.time.ns_per_s));

                try self.files.append(self.allocator, .{
                    .path = rel_path,
                    .size = stat.size,
                    .mtime = mtime,
                    .hash = 0, // Deferred — will be batch-hashed
                    .is_dir = false,
                });

                self.total_bytes += stat.size;
            } else {
                self.allocator.free(rel_path);
            }
        }
    }

    /// Batch-hash all non-directory files using io_uring (Linux) or dispatch_apply (macOS).
    fn batchHashFiles(self: *TransferSession, dir: fs.Dir) !void {
        // Collect indices of files needing hashing
        var file_indices = std.ArrayListUnmanaged(usize){};
        defer file_indices.deinit(self.allocator);

        for (self.files.items, 0..) |entry, i| {
            if (!entry.is_dir and entry.size > 0) {
                try file_indices.append(self.allocator, i);
            }
        }

        if (file_indices.items.len == 0) return;

        // Build name arrays for ParallelHasher
        const names = try self.allocator.alloc([]const u8, file_indices.items.len);
        defer self.allocator.free(names);

        for (file_indices.items, 0..) |fi, i| {
            names[i] = self.files.items[fi].path;
        }

        // Use ParallelHasher (threads on Linux, dispatch_apply on macOS)
        const hashes = try ParallelHasher.hashFilesParallel(self.allocator, dir, names);
        defer self.allocator.free(hashes);

        // Write hashes back to file entries
        for (file_indices.items, 0..) |fi, i| {
            self.files.items[fi].hash = hashes[i];
        }
    }

    // Read a file chunk using mmap for downloads
    pub fn readFileChunk(self: *TransferSession, file_index: u32, offset: u64, max_size: usize) ![]const u8 {
        if (file_index >= self.files.items.len) return error.InvalidFileIndex;

        const file_entry = self.files.items[file_index];
        if (file_entry.is_dir) return error.IsDirectory;

        // Build full path
        const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.base_path, file_entry.path });
        defer self.allocator.free(full_path);

        // Map the file if not already mapped or if it's a different file
        if (self.current_mapped_file == null or self.current_file_index != file_index) {
            // Close previous mapped file
            if (self.current_mapped_file) |*mf| {
                mf.deinit();
            }

            self.current_mapped_file = try MappedFile.init(full_path);
            self.current_mapped_file.?.adviseSequential();
            self.current_file_index = file_index;
        }

        const mapped = &self.current_mapped_file.?;

        // Calculate chunk bounds
        const file_size = mapped.data.len;
        if (offset >= file_size) return &[_]u8{};

        const start: usize = @intCast(offset);
        const end = @min(start + max_size, file_size);

        return mapped.data[start..end];
    }

    // Close the current mapped file (call when done with a file)
    pub fn closeCurrentFile(self: *TransferSession) void {
        if (self.current_mapped_file) |*mf| {
            mf.deinit();
            self.current_mapped_file = null;
        }
    }

    /// Read an entire file via io_uring pipelined multi-chunk reads.
    /// Linux only — callers must wrap with `if (comptime is_linux)`.
    /// Returns owned buffer — caller must free with allocator.
    pub fn readFileViaUring(self: *TransferSession, file_index: u32, allocator: Allocator) ![]u8 {
        if (comptime !is_linux) @compileError("readFileViaUring is Linux-only; wrap call with comptime is_linux guard");
        if (file_index >= self.files.items.len) return error.InvalidFileIndex;
        const file_entry = self.files.items[file_index];
        if (file_entry.is_dir) return error.IsDirectory;
        if (file_entry.size == 0) return allocator.alloc(u8, 0);

        const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.base_path, file_entry.path });
        defer self.allocator.free(full_path);

        const fd = try posix.open(full_path, .{ .ACCMODE = .RDONLY }, 0);
        errdefer posix.close(fd);

        const file_size: usize = @intCast(file_entry.size);
        const uring_chunk_size: usize = 256 * 1024; // 256KB chunks for io_uring pipelining
        const chunk_count = (file_size + uring_chunk_size - 1) / uring_chunk_size;

        if (chunk_count <= 1) {
            // Single read — no pipelining needed
            const buf = try allocator.alloc(u8, file_size);
            errdefer allocator.free(buf);
            const file = std.fs.File{ .handle = fd };
            const n = try file.readAll(buf);
            posix.close(fd);
            return buf[0..n];
        }

        // Build offset/length arrays for pipelined read
        const offsets = try self.allocator.alloc(u64, chunk_count);
        defer self.allocator.free(offsets);
        const lengths = try self.allocator.alloc(usize, chunk_count);
        defer self.allocator.free(lengths);

        for (0..chunk_count) |i| {
            offsets[i] = @intCast(i * uring_chunk_size);
            lengths[i] = @min(uring_chunk_size, file_size - i * uring_chunk_size);
        }

        var reader = try IoUringReader.init(fd);
        defer reader.deinit();

        const chunks = try reader.readMultiple(offsets, lengths, allocator);
        defer allocator.free(chunks);

        // Assemble into single buffer
        const result = try allocator.alloc(u8, file_size);
        var written: usize = 0;
        for (chunks) |chunk| {
            @memcpy(result[written..][0..chunk.len], chunk);
            written += chunk.len;
            allocator.free(chunk);
        }

        posix.close(fd);
        return result[0..written];
    }

    /// Read an entire file via dispatch_io pipelined multi-chunk reads.
    /// macOS only — callers must wrap with `if (comptime is_darwin)`.
    /// Returns owned buffer — caller must free with allocator.
    pub fn readFileViaDispatchIO(self: *TransferSession, file_index: u32, allocator: Allocator) ![]u8 {
        if (comptime !is_darwin) @compileError("readFileViaDispatchIO is macOS-only; wrap call with comptime is_darwin guard");
        if (file_index >= self.files.items.len) return error.InvalidFileIndex;
        const file_entry = self.files.items[file_index];
        if (file_entry.is_dir) return error.IsDirectory;
        if (file_entry.size == 0) return allocator.alloc(u8, 0);

        const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.base_path, file_entry.path });
        defer self.allocator.free(full_path);

        const fd = try posix.open(full_path, .{ .ACCMODE = .RDONLY }, 0);

        const file_size: usize = @intCast(file_entry.size);
        const dio_chunk_size: usize = 256 * 1024; // 256KB chunks for dispatch_io pipelining
        const chunk_count = (file_size + dio_chunk_size - 1) / dio_chunk_size;

        if (chunk_count <= 1) {
            // Single read
            const buf = try allocator.alloc(u8, file_size);
            errdefer allocator.free(buf);
            const file = std.fs.File{ .handle = fd };
            const n = try file.readAll(buf);
            posix.close(fd);
            return buf[0..n];
        }

        // Build offset/length arrays for pipelined dispatch_io reads
        const offsets = try self.allocator.alloc(u64, chunk_count);
        defer self.allocator.free(offsets);
        const lengths = try self.allocator.alloc(usize, chunk_count);
        defer self.allocator.free(lengths);

        for (0..chunk_count) |i| {
            offsets[i] = @intCast(i * dio_chunk_size);
            lengths[i] = @min(dio_chunk_size, file_size - i * dio_chunk_size);
        }

        var dio = DispatchIO.init(fd);
        defer dio.deinit(); // dispatch_io_close also closes the fd

        const chunks = try dio.readMultiple(offsets, lengths, allocator);
        defer allocator.free(chunks);

        // Assemble into single buffer
        const result = try allocator.alloc(u8, file_size);
        var written: usize = 0;
        for (chunks) |chunk| {
            @memcpy(result[written..][0..chunk.len], chunk);
            written += chunk.len;
            allocator.free(chunk);
        }

        return result[0..written];
    }

    // Compress data using zstd
    pub fn compress(self: *TransferSession, input: []const u8) ![]u8 {
        if (self.compressor) |*comp| {
            return comp.compress(input);
        }
        return error.NoCompressor;
    }

    // Compress directly from mapped memory (zero-copy input)
    pub fn compressFromMapped(self: *TransferSession, file_index: u32, offset: u64, max_size: usize) ![]u8 {
        const chunk = try self.readFileChunk(file_index, offset, max_size);
        return self.compress(chunk);
    }

    // Decompress data using zstd
    pub fn decompress(self: *TransferSession, input: []const u8, expected_size: usize) ![]u8 {
        if (self.decompressor) |*decomp| {
            return decomp.decompress(input, expected_size);
        }
        return error.NoDecompressor;
    }

    // Persist session state for resume
    pub fn saveState(self: *const TransferSession) !void {
        // Get state directory
        const home = std.posix.getenv("HOME") orelse return error.NoHome;
        const state_dir = try std.fmt.allocPrint(self.allocator, "{s}/.termweb/transfers", .{home});
        defer self.allocator.free(state_dir);

        // Create directory if needed
        fs.makeDirAbsolute(state_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        // Write state file
        const state_path = try std.fmt.allocPrint(self.allocator, "{s}/{d}.state", .{ state_dir, self.id });
        defer self.allocator.free(state_path);

        var file = try fs.createFileAbsolute(state_path, .{});
        defer file.close();

        // Write header directly using file.write
        var header_buf: [26]u8 = undefined;
        std.mem.writeInt(u32, header_buf[0..4], self.id, .little);
        header_buf[4] = @intFromEnum(self.direction);
        header_buf[5] = @as(u8, @bitCast(self.flags));
        std.mem.writeInt(u32, header_buf[6..10], self.current_file_index, .little);
        std.mem.writeInt(u64, header_buf[10..18], self.current_file_offset, .little);
        std.mem.writeInt(u64, header_buf[18..26], self.bytes_transferred, .little);
        _ = try file.write(&header_buf);

        // Write base path
        var path_len_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &path_len_buf, @intCast(self.base_path.len), .little);
        _ = try file.write(&path_len_buf);
        _ = try file.write(self.base_path);

        // Write file count
        var count_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &count_buf, @intCast(self.files.items.len), .little);
        _ = try file.write(&count_buf);

        // Write entries
        for (self.files.items) |entry| {
            std.mem.writeInt(u16, &path_len_buf, @intCast(entry.path.len), .little);
            _ = try file.write(&path_len_buf);
            _ = try file.write(entry.path);

            var entry_buf: [25]u8 = undefined;
            std.mem.writeInt(u64, entry_buf[0..8], entry.size, .little);
            std.mem.writeInt(u64, entry_buf[8..16], entry.mtime, .little);
            std.mem.writeInt(u64, entry_buf[16..24], entry.hash, .little);
            entry_buf[24] = if (entry.is_dir) 1 else 0;
            _ = try file.write(&entry_buf);
        }
    }

    // Load session state for resume
    pub fn loadState(allocator: Allocator, id: u32) !*TransferSession {
        const home = std.posix.getenv("HOME") orelse return error.NoHome;
        const state_path = try std.fmt.allocPrint(allocator, "{s}/.termweb/transfers/{d}.state", .{ home, id });
        defer allocator.free(state_path);

        var file = try fs.openFileAbsolute(state_path, .{});
        defer file.close();

        // Read header
        var header_buf: [26]u8 = undefined;
        _ = try file.readAll(&header_buf);

        const saved_id = std.mem.readInt(u32, header_buf[0..4], .little);
        if (saved_id != id) return error.InvalidStateFile;

        const direction: TransferDirection = @enumFromInt(header_buf[4]);
        const flags: TransferFlags = @bitCast(header_buf[5]);
        const current_file_index = std.mem.readInt(u32, header_buf[6..10], .little);
        const current_file_offset = std.mem.readInt(u64, header_buf[10..18], .little);
        const bytes_transferred = std.mem.readInt(u64, header_buf[18..26], .little);

        // Read base path
        var path_len_buf: [2]u8 = undefined;
        _ = try file.readAll(&path_len_buf);
        const path_len = std.mem.readInt(u16, &path_len_buf, .little);
        const base_path = try allocator.alloc(u8, path_len);
        _ = try file.readAll(base_path);

        // Create session
        const session = try allocator.create(TransferSession);
        session.* = .{
            .id = id,
            .direction = direction,
            .flags = flags,
            .base_path = base_path,
            .exclude_patterns = .{},
            .files = .{},
            .total_bytes = 0,
            .current_file_index = current_file_index,
            .current_file_offset = current_file_offset,
            .bytes_transferred = bytes_transferred,
            .is_active = true,
            .allocator = allocator,
            .compressor = zstd.Compressor.init(allocator, 3) catch null,
            .decompressor = zstd.Decompressor.init(allocator) catch null,
            .current_mapped_file = null,
        };

        // Read file count
        var count_buf: [4]u8 = undefined;
        _ = try file.readAll(&count_buf);
        const file_count = std.mem.readInt(u32, &count_buf, .little);
        try session.files.ensureTotalCapacity(allocator, file_count);

        var i: u32 = 0;
        while (i < file_count) : (i += 1) {
            _ = try file.readAll(&path_len_buf);
            const entry_path_len = std.mem.readInt(u16, &path_len_buf, .little);
            const entry_path = try allocator.alloc(u8, entry_path_len);
            _ = try file.readAll(entry_path);

            var entry_buf: [25]u8 = undefined;
            _ = try file.readAll(&entry_buf);

            const size = std.mem.readInt(u64, entry_buf[0..8], .little);
            const mtime = std.mem.readInt(u64, entry_buf[8..16], .little);
            const hash = std.mem.readInt(u64, entry_buf[16..24], .little);
            const is_dir = entry_buf[24] != 0;

            try session.files.append(allocator, .{
                .path = entry_path,
                .size = size,
                .mtime = mtime,
                .hash = hash,
                .is_dir = is_dir,
            });

            session.total_bytes += size;
        }

        return session;
    }

    // Delete state file
    pub fn deleteState(self: *const TransferSession) void {
        const home = std.posix.getenv("HOME") orelse return;
        const state_path = std.fmt.allocPrint(self.allocator, "{s}/.termweb/transfers/{d}.state", .{ home, self.id }) catch return;
        defer self.allocator.free(state_path);

        fs.deleteFileAbsolute(state_path) catch {};
    }
};


// Message Builders


/// Build TRANSFER_READY message with resume position.
/// [0x30][transfer_id:u32][current_file_index:u32][current_file_offset:u64][bytes_transferred:u64]
/// Resume fields are 0 for new transfers.
pub fn buildTransferReady(allocator: Allocator, transfer_id: u32) ![]u8 {
    return buildTransferReadyEx(allocator, transfer_id, 0, 0, 0);
}

pub fn buildTransferReadyEx(
    allocator: Allocator,
    transfer_id: u32,
    current_file_index: u32,
    current_file_offset: u64,
    bytes_transferred: u64,
) ![]u8 {
    var msg = try allocator.alloc(u8, 25);
    msg[0] = @intFromEnum(ServerMsgType.transfer_ready);
    std.mem.writeInt(u32, msg[1..5], transfer_id, .little);
    std.mem.writeInt(u32, msg[5..9], current_file_index, .little);
    std.mem.writeInt(u64, msg[9..17], current_file_offset, .little);
    std.mem.writeInt(u64, msg[17..25], bytes_transferred, .little);
    return msg;
}

// Build FILE_LIST message
// [0x31][transfer_id:u32][file_count:u32][total_bytes:u64][files...]
// file: [path_len:u16][path][size:u64][mtime:u64][hash:u64][is_dir:u8]
pub fn buildFileList(allocator: Allocator, session: *const TransferSession) ![]u8 {
    // Calculate total size
    var total_len: usize = 1 + 4 + 4 + 8; // header
    for (session.files.items) |entry| {
        total_len += 2 + entry.path.len + 8 + 8 + 8 + 1;
    }

    var msg = try allocator.alloc(u8, total_len);
    var offset: usize = 0;

    msg[offset] = @intFromEnum(ServerMsgType.file_list);
    offset += 1;

    std.mem.writeInt(u32, msg[offset..][0..4], session.id, .little);
    offset += 4;

    std.mem.writeInt(u32, msg[offset..][0..4], @intCast(session.files.items.len), .little);
    offset += 4;

    std.mem.writeInt(u64, msg[offset..][0..8], session.total_bytes, .little);
    offset += 8;

    for (session.files.items) |entry| {
        std.mem.writeInt(u16, msg[offset..][0..2], @intCast(entry.path.len), .little);
        offset += 2;

        @memcpy(msg[offset..][0..entry.path.len], entry.path);
        offset += entry.path.len;

        std.mem.writeInt(u64, msg[offset..][0..8], entry.size, .little);
        offset += 8;

        std.mem.writeInt(u64, msg[offset..][0..8], entry.mtime, .little);
        offset += 8;

        std.mem.writeInt(u64, msg[offset..][0..8], entry.hash, .little);
        offset += 8;

        msg[offset] = if (entry.is_dir) 1 else 0;
        offset += 1;
    }

    return msg;
}

// Build FILE_REQUEST message (for download - server sends file chunk to browser)
// [0x32][transfer_id:u32][file_index:u32][chunk_offset:u64][chunk_size:u32][compressed_data...]
pub fn buildFileChunk(allocator: Allocator, session: *TransferSession, file_index: u32, chunk_offset: u64, chunk_size: usize) ![]u8 {
    // Read and compress directly from mmap (zero-copy read)
    const compressed = try session.compressFromMapped(file_index, chunk_offset, chunk_size);
    defer allocator.free(compressed);

    // Get actual uncompressed size
    const chunk = try session.readFileChunk(file_index, chunk_offset, chunk_size);

    const header_len: usize = 1 + 4 + 4 + 8 + 4;
    var msg = try allocator.alloc(u8, header_len + compressed.len);

    var offset: usize = 0;
    msg[offset] = @intFromEnum(ServerMsgType.file_request);
    offset += 1;

    std.mem.writeInt(u32, msg[offset..][0..4], session.id, .little);
    offset += 4;

    std.mem.writeInt(u32, msg[offset..][0..4], file_index, .little);
    offset += 4;

    std.mem.writeInt(u64, msg[offset..][0..8], chunk_offset, .little);
    offset += 8;

    std.mem.writeInt(u32, msg[offset..][0..4], @intCast(chunk.len), .little);
    offset += 4;

    @memcpy(msg[offset..], compressed);

    return msg;
}

/// Build FILE_REQUEST message from pre-compressed data (used by pipelined download).
/// Avoids re-reading and re-compressing when data was already compressed in parallel.
pub fn buildFileChunkPrecompressed(
    allocator: Allocator,
    transfer_id: u32,
    file_index: u32,
    chunk_offset: u64,
    uncompressed_size: u32,
    compressed: []const u8,
) ![]u8 {
    const header_len: usize = 1 + 4 + 4 + 8 + 4;
    var msg = try allocator.alloc(u8, header_len + compressed.len);

    var offset: usize = 0;
    msg[offset] = @intFromEnum(ServerMsgType.file_request);
    offset += 1;

    std.mem.writeInt(u32, msg[offset..][0..4], transfer_id, .little);
    offset += 4;

    std.mem.writeInt(u32, msg[offset..][0..4], file_index, .little);
    offset += 4;

    std.mem.writeInt(u64, msg[offset..][0..8], chunk_offset, .little);
    offset += 8;

    std.mem.writeInt(u32, msg[offset..][0..4], uncompressed_size, .little);
    offset += 4;

    @memcpy(msg[offset..], compressed);

    return msg;
}

/// Entry for a file to include in a batch message.
pub const BatchEntry = struct {
    file_index: u32,
    data: []const u8,
};

/// Build BATCH_DATA message — multiple small files compressed as one block.
/// Wire format: [0x37][transfer_id:u32][uncompressed_size:u32][compressed_data...]
/// Uncompressed payload: [file_count:u16] then per file: [file_index:u32][size:u32][data...]
pub fn buildBatchData(allocator: Allocator, session: *TransferSession, entries: []const BatchEntry) ![]u8 {
    // Calculate uncompressed payload size
    var payload_size: usize = 2; // file_count:u16
    for (entries) |entry| {
        payload_size += 4 + 4 + entry.data.len; // file_index:u32 + size:u32 + data
    }

    // Build uncompressed payload
    const payload = try allocator.alloc(u8, payload_size);
    defer allocator.free(payload);

    var offset: usize = 0;
    std.mem.writeInt(u16, payload[offset..][0..2], @intCast(entries.len), .little);
    offset += 2;

    for (entries) |entry| {
        std.mem.writeInt(u32, payload[offset..][0..4], entry.file_index, .little);
        offset += 4;
        std.mem.writeInt(u32, payload[offset..][0..4], @intCast(entry.data.len), .little);
        offset += 4;
        @memcpy(payload[offset..][0..entry.data.len], entry.data);
        offset += entry.data.len;
    }

    // Compress entire payload as one block
    const compressed = try session.compress(payload);
    defer allocator.free(compressed);

    // Build wire message
    const header_len: usize = 1 + 4 + 4; // msg_type + transfer_id + uncompressed_size
    var msg = try allocator.alloc(u8, header_len + compressed.len);

    msg[0] = @intFromEnum(ServerMsgType.batch_data);
    std.mem.writeInt(u32, msg[1..5], session.id, .little);
    std.mem.writeInt(u32, msg[5..9], @intCast(payload_size), .little);
    @memcpy(msg[9..], compressed);

    return msg;
}

// Build FILE_REQUEST message (for download - server requests browser to receive)
// [0x32][transfer_id:u32][file_index:u32][chunk_offset:u64][chunk_size:u32][compressed_data...]
pub fn buildFileRequest(allocator: Allocator, session: *TransferSession, file_index: u32, chunk_offset: u64, data: []const u8) ![]u8 {
    // Compress the data
    const compressed = try session.compress(data);
    defer allocator.free(compressed);

    const header_len: usize = 1 + 4 + 4 + 8 + 4;
    var msg = try allocator.alloc(u8, header_len + compressed.len);

    var offset: usize = 0;
    msg[offset] = @intFromEnum(ServerMsgType.file_request);
    offset += 1;

    std.mem.writeInt(u32, msg[offset..][0..4], session.id, .little);
    offset += 4;

    std.mem.writeInt(u32, msg[offset..][0..4], file_index, .little);
    offset += 4;

    std.mem.writeInt(u64, msg[offset..][0..8], chunk_offset, .little);
    offset += 8;

    std.mem.writeInt(u32, msg[offset..][0..4], @intCast(data.len), .little);
    offset += 4;

    @memcpy(msg[offset..], compressed);

    return msg;
}

// Build FILE_ACK message
// [0x33][transfer_id:u32][file_index:u32][bytes_received:u64]
pub fn buildFileAck(allocator: Allocator, transfer_id: u32, file_index: u32, bytes_received: u64) ![]u8 {
    var msg = try allocator.alloc(u8, 17);
    var offset: usize = 0;

    msg[offset] = @intFromEnum(ServerMsgType.file_ack);
    offset += 1;

    std.mem.writeInt(u32, msg[offset..][0..4], transfer_id, .little);
    offset += 4;

    std.mem.writeInt(u32, msg[offset..][0..4], file_index, .little);
    offset += 4;

    std.mem.writeInt(u64, msg[offset..][0..8], bytes_received, .little);

    return msg;
}

// Build TRANSFER_COMPLETE message
// [0x34][transfer_id:u32][total_bytes:u64]
pub fn buildTransferComplete(allocator: Allocator, transfer_id: u32, total_bytes: u64) ![]u8 {
    var msg = try allocator.alloc(u8, 13);
    msg[0] = @intFromEnum(ServerMsgType.transfer_complete);
    std.mem.writeInt(u32, msg[1..5], transfer_id, .little);
    std.mem.writeInt(u64, msg[5..13], total_bytes, .little);
    return msg;
}

// Build TRANSFER_ERROR message
// [0x35][transfer_id:u32][error_len:u16][error:bytes]
pub fn buildTransferError(allocator: Allocator, transfer_id: u32, message: []const u8) ![]u8 {
    var msg = try allocator.alloc(u8, 7 + message.len);
    msg[0] = @intFromEnum(ServerMsgType.transfer_error);
    std.mem.writeInt(u32, msg[1..5], transfer_id, .little);
    std.mem.writeInt(u16, msg[5..7], @intCast(message.len), .little);
    @memcpy(msg[7..], message);
    return msg;
}

// Build DRY_RUN_REPORT message
// [0x36][transfer_id:u32][new_count:u32][update_count:u32][delete_count:u32][entries...]
// entry: [action:u8][path_len:u16][path][size:u64]
pub const DryRunEntry = struct {
    action: DryRunAction,
    path: []const u8,
    size: u64,
};

pub fn buildDryRunReport(allocator: Allocator, transfer_id: u32, entries: []const DryRunEntry) ![]u8 {
    // Count by action type
    var new_count: u32 = 0;
    var update_count: u32 = 0;
    var delete_count: u32 = 0;

    var total_len: usize = 1 + 4 + 4 + 4 + 4; // header
    for (entries) |entry| {
        total_len += 1 + 2 + entry.path.len + 8;
        switch (entry.action) {
            .create => new_count += 1,
            .update => update_count += 1,
            .delete => delete_count += 1,
        }
    }

    var msg = try allocator.alloc(u8, total_len);
    var offset: usize = 0;

    msg[offset] = @intFromEnum(ServerMsgType.dry_run_report);
    offset += 1;

    std.mem.writeInt(u32, msg[offset..][0..4], transfer_id, .little);
    offset += 4;

    std.mem.writeInt(u32, msg[offset..][0..4], new_count, .little);
    offset += 4;

    std.mem.writeInt(u32, msg[offset..][0..4], update_count, .little);
    offset += 4;

    std.mem.writeInt(u32, msg[offset..][0..4], delete_count, .little);
    offset += 4;

    for (entries) |entry| {
        msg[offset] = @intFromEnum(entry.action);
        offset += 1;

        std.mem.writeInt(u16, msg[offset..][0..2], @intCast(entry.path.len), .little);
        offset += 2;

        @memcpy(msg[offset..][0..entry.path.len], entry.path);
        offset += entry.path.len;

        std.mem.writeInt(u64, msg[offset..][0..8], entry.size, .little);
        offset += 8;
    }

    return msg;
}


// Message Parsers


// Parse TRANSFER_INIT message
// [0x20][direction:u8][flags:u8][exclude_count:u8][path_len:u16][path][excludes...]
// excludes: [len:u8][pattern]...
pub const TransferInitData = struct {
    direction: TransferDirection,
    flags: TransferFlags,
    path: []const u8,
    excludes: []const []const u8,

    pub fn deinit(self: *TransferInitData, allocator: Allocator) void {
        allocator.free(self.path);
        for (self.excludes) |pattern| {
            allocator.free(pattern);
        }
        allocator.free(self.excludes);
    }
};

pub fn parseTransferInit(allocator: Allocator, data: []const u8) !TransferInitData {
    if (data.len < 6) return error.MessageTooShort;

    var offset: usize = 1; // Skip msg type

    const direction: TransferDirection = @enumFromInt(data[offset]);
    offset += 1;

    const flags: TransferFlags = @bitCast(data[offset]);
    offset += 1;

    const exclude_count = data[offset];
    offset += 1;

    const path_len = std.mem.readInt(u16, data[offset..][0..2], .little);
    offset += 2;

    if (data.len < offset + path_len) return error.MessageTooShort;

    const path = try allocator.dupe(u8, data[offset..][0..path_len]);
    offset += path_len;

    // Parse exclude patterns
    var excludes = try allocator.alloc([]const u8, exclude_count);
    var i: u8 = 0;
    while (i < exclude_count) : (i += 1) {
        if (offset >= data.len) {
            // Free already allocated
            for (excludes[0..i]) |pattern| allocator.free(pattern);
            allocator.free(excludes);
            allocator.free(path);
            return error.MessageTooShort;
        }

        const pattern_len = data[offset];
        offset += 1;

        if (data.len < offset + pattern_len) {
            for (excludes[0..i]) |pattern| allocator.free(pattern);
            allocator.free(excludes);
            allocator.free(path);
            return error.MessageTooShort;
        }

        excludes[i] = try allocator.dupe(u8, data[offset..][0..pattern_len]);
        offset += pattern_len;
    }

    return .{
        .direction = direction,
        .flags = flags,
        .path = path,
        .excludes = excludes,
    };
}

// Parse FILE_DATA message (upload from browser)
// [0x22][transfer_id:u32][file_index:u32][chunk_offset:u64][uncompressed_size:u32][compressed_data...]
pub const FileDataMsg = struct {
    transfer_id: u32,
    file_index: u32,
    chunk_offset: u64,
    uncompressed_size: u32,
    compressed_data: []const u8,
};

pub fn parseFileData(data: []const u8) !FileDataMsg {
    if (data.len < 21) return error.MessageTooShort;

    var offset: usize = 1; // Skip msg type

    const transfer_id = std.mem.readInt(u32, data[offset..][0..4], .little);
    offset += 4;

    const file_index = std.mem.readInt(u32, data[offset..][0..4], .little);
    offset += 4;

    const chunk_offset = std.mem.readInt(u64, data[offset..][0..8], .little);
    offset += 8;

    const uncompressed_size = std.mem.readInt(u32, data[offset..][0..4], .little);
    offset += 4;

    return .{
        .transfer_id = transfer_id,
        .file_index = file_index,
        .chunk_offset = chunk_offset,
        .uncompressed_size = uncompressed_size,
        .compressed_data = data[offset..],
    };
}


// Glob Pattern Matching


fn matchGlob(pattern: []const u8, path: []const u8) bool {
    var p_idx: usize = 0;
    var s_idx: usize = 0;
    var star_p: ?usize = null;
    var star_s: ?usize = null;

    while (s_idx < path.len) {
        if (p_idx < pattern.len) {
            const pc = pattern[p_idx];
            const sc = path[s_idx];

            if (pc == '*') {
                star_p = p_idx;
                star_s = s_idx;
                p_idx += 1;
                continue;
            } else if (pc == '?' or pc == sc) {
                p_idx += 1;
                s_idx += 1;
                continue;
            }
        }

        if (star_p) |sp| {
            p_idx = sp + 1;
            star_s.? += 1;
            s_idx = star_s.?;
        } else {
            return false;
        }
    }

    // Match remaining wildcards
    while (p_idx < pattern.len and pattern[p_idx] == '*') {
        p_idx += 1;
    }

    return p_idx == pattern.len;
}


// Rsync Protocol — Block-Level Delta Sync


/// Rolling checksum (rsync-style Adler32 variant).
/// Fast to compute incrementally as a sliding window moves through data.
pub const RollingChecksum = struct {
    a: u16,
    b: u16,
    count: u32,

    pub fn init() RollingChecksum {
        return .{ .a = 0, .b = 0, .count = 0 };
    }

    /// Compute checksum over a block of data.
    pub fn compute(data: []const u8) RollingChecksum {
        var a: u32 = 0;
        var b: u32 = 0;
        for (data) |byte| {
            a +%= byte;
            b +%= a;
        }
        return .{
            .a = @truncate(a),
            .b = @truncate(b),
            .count = @intCast(data.len),
        };
    }

    /// Combined 32-bit hash for hash table lookup.
    pub fn hash(self: RollingChecksum) u32 {
        return (@as(u32, self.b) << 16) | @as(u32, self.a);
    }

    /// Roll the window forward: remove old_byte, add new_byte.
    pub fn roll(self: *RollingChecksum, old_byte: u8, new_byte: u8) void {
        self.a -%= old_byte;
        self.a +%= new_byte;
        self.b -%= @as(u16, @truncate(self.count)) *% old_byte;
        self.b +%= self.a;
    }
};

/// Block checksum pair: rolling (fast) + strong (XXH3, collision-resistant).
pub const BlockChecksum = struct {
    rolling: u32,  // RollingChecksum.hash()
    strong: u64,   // XXH3 64-bit hash (server computes via xxh3Hash)
};

/// Delta command types.
pub const DeltaCmd = enum(u8) {
    copy = 0x00,    // Reuse block from client's cached copy
    literal = 0x01, // New data from server
};

/// Compute adaptive block size: sqrt(file_size) clamped to [512, 65536].
pub fn computeBlockSize(file_size: u64) u32 {
    if (file_size == 0) return 512;
    const sqrt = std.math.sqrt(file_size);
    return @intCast(std.math.clamp(sqrt, 512, 65536));
}

/// Parse SYNC_REQUEST from client.
/// [0x25][flags:u8][path_len:u16][path][exclude_count:u8][excludes...]
pub const SyncRequestData = struct {
    flags: u8,
    path: []const u8,
    excludes: []const []const u8,

    pub fn deinit(self: *SyncRequestData, allocator: Allocator) void {
        allocator.free(self.path);
        for (self.excludes) |pattern| {
            allocator.free(pattern);
        }
        allocator.free(self.excludes);
    }
};

pub fn parseSyncRequest(allocator: Allocator, data: []const u8) !SyncRequestData {
    if (data.len < 5) return error.MessageTooShort;

    var offset: usize = 1; // Skip msg type

    const flags = data[offset];
    offset += 1;

    const path_len = std.mem.readInt(u16, data[offset..][0..2], .little);
    offset += 2;

    if (data.len < offset + path_len) return error.MessageTooShort;
    const path = try allocator.dupe(u8, data[offset..][0..path_len]);
    offset += path_len;

    if (offset >= data.len) {
        return .{ .flags = flags, .path = path, .excludes = &[_][]const u8{} };
    }

    const exclude_count = data[offset];
    offset += 1;

    var excludes = try allocator.alloc([]const u8, exclude_count);
    var i: u8 = 0;
    while (i < exclude_count) : (i += 1) {
        if (offset >= data.len) break;
        const pattern_len = data[offset];
        offset += 1;
        if (data.len < offset + pattern_len) break;
        excludes[i] = try allocator.dupe(u8, data[offset..][0..pattern_len]);
        offset += pattern_len;
    }

    return .{ .flags = flags, .path = path, .excludes = excludes[0..i] };
}

/// Parse BLOCK_CHECKSUMS from client.
/// [0x26][transfer_id:u32][file_index:u32][block_size:u32][count:u32][rolling:u32 × N][strong:u64 × N]
pub const BlockChecksumsMsg = struct {
    transfer_id: u32,
    file_index: u32,
    block_size: u32,
    checksums: []BlockChecksum,
};

pub fn parseBlockChecksums(allocator: Allocator, data: []const u8) !BlockChecksumsMsg {
    if (data.len < 17) return error.MessageTooShort;

    var offset: usize = 1; // Skip msg type

    const transfer_id = std.mem.readInt(u32, data[offset..][0..4], .little);
    offset += 4;
    const file_index = std.mem.readInt(u32, data[offset..][0..4], .little);
    offset += 4;
    const block_size = std.mem.readInt(u32, data[offset..][0..4], .little);
    offset += 4;
    const count = std.mem.readInt(u32, data[offset..][0..4], .little);
    offset += 4;

    // Each checksum: rolling:u32 + strong:u64 = 12 bytes
    const needed = @as(usize, count) * 12;
    if (data.len < offset + needed) return error.MessageTooShort;

    const checksums = try allocator.alloc(BlockChecksum, count);
    for (0..count) |i| {
        checksums[i] = .{
            .rolling = std.mem.readInt(u32, data[offset..][0..4], .little),
            .strong = std.mem.readInt(u64, data[offset + 4 ..][0..8], .little),
        };
        offset += 12;
    }

    return .{
        .transfer_id = transfer_id,
        .file_index = file_index,
        .block_size = block_size,
        .checksums = checksums,
    };
}

/// Build SYNC_FILE_LIST message.
/// [0x38][transfer_id:u32][file_count:u32][total_bytes:u64][entries...]
/// entry: [path_len:u16][path][size:u64][mtime:u64][hash:u64][is_dir:u8]
pub fn buildSyncFileList(allocator: Allocator, session: *const TransferSession) ![]u8 {
    // Same format as FILE_LIST but with sync_file_list type
    var total_len: usize = 1 + 4 + 4 + 8;
    for (session.files.items) |entry| {
        total_len += 2 + entry.path.len + 8 + 8 + 8 + 1;
    }

    var msg = try allocator.alloc(u8, total_len);
    var offset: usize = 0;

    msg[offset] = @intFromEnum(ServerMsgType.sync_file_list);
    offset += 1;

    std.mem.writeInt(u32, msg[offset..][0..4], session.id, .little);
    offset += 4;
    std.mem.writeInt(u32, msg[offset..][0..4], @intCast(session.files.items.len), .little);
    offset += 4;
    std.mem.writeInt(u64, msg[offset..][0..8], session.total_bytes, .little);
    offset += 8;

    for (session.files.items) |entry| {
        std.mem.writeInt(u16, msg[offset..][0..2], @intCast(entry.path.len), .little);
        offset += 2;
        @memcpy(msg[offset..][0..entry.path.len], entry.path);
        offset += entry.path.len;
        std.mem.writeInt(u64, msg[offset..][0..8], entry.size, .little);
        offset += 8;
        std.mem.writeInt(u64, msg[offset..][0..8], entry.mtime, .little);
        offset += 8;
        std.mem.writeInt(u64, msg[offset..][0..8], entry.hash, .little);
        offset += 8;
        msg[offset] = if (entry.is_dir) 1 else 0;
        offset += 1;
    }

    return msg;
}

/// Build DELTA_DATA message for a file.
/// [0x39][transfer_id:u32][file_index:u32][compressed_delta...]
/// Delta payload (before compression): sequence of commands:
///   COPY:    [0x00][offset:u64][length:u32]
///   LITERAL: [0x01][length:u32][data...]
pub fn buildDeltaData(
    allocator: Allocator,
    session: *TransferSession,
    file_index: u32,
    delta_payload: []const u8,
) ![]u8 {
    // Compress the delta payload
    const compressed = try session.compress(delta_payload);
    defer allocator.free(compressed);

    const header_len: usize = 1 + 4 + 4 + 4; // type + transfer_id + file_index + uncompressed_size
    var msg = try allocator.alloc(u8, header_len + compressed.len);

    msg[0] = @intFromEnum(ServerMsgType.delta_data);
    std.mem.writeInt(u32, msg[1..5], session.id, .little);
    std.mem.writeInt(u32, msg[5..9], file_index, .little);
    std.mem.writeInt(u32, msg[9..13], @intCast(delta_payload.len), .little);
    @memcpy(msg[13..], compressed);

    return msg;
}

/// Build SYNC_COMPLETE message.
/// [0x3A][transfer_id:u32][files_synced:u32][bytes_transferred:u64]
pub fn buildSyncComplete(allocator: Allocator, transfer_id: u32, files_synced: u32, bytes_transferred: u64) ![]u8 {
    var msg = try allocator.alloc(u8, 17);
    msg[0] = @intFromEnum(ServerMsgType.sync_complete);
    std.mem.writeInt(u32, msg[1..5], transfer_id, .little);
    std.mem.writeInt(u32, msg[5..9], files_synced, .little);
    std.mem.writeInt(u64, msg[9..17], bytes_transferred, .little);
    return msg;
}

/// Compute delta between server file and client's block checksums.
/// Returns a delta payload (sequence of COPY/LITERAL commands).
pub fn computeDelta(
    allocator: Allocator,
    server_data: []const u8,
    client_checksums: []const BlockChecksum,
    block_size: u32,
) ![]u8 {
    // Build hash table of client checksums for O(1) rolling lookup
    const HashEntry = struct { index: u32, strong: u64 };
    var hash_table = std.AutoHashMap(u32, std.ArrayListUnmanaged(HashEntry)).init(allocator);
    defer {
        var iter = hash_table.valueIterator();
        while (iter.next()) |list| {
            list.deinit(allocator);
        }
        hash_table.deinit();
    }

    for (client_checksums, 0..) |cs, i| {
        const gop = try hash_table.getOrPut(cs.rolling);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }
        try gop.value_ptr.append(allocator, .{ .index = @intCast(i), .strong = cs.strong });
    }

    // Build delta commands
    var delta: std.ArrayListUnmanaged(u8) = .{};
    defer delta.deinit(allocator);

    var literal_start: usize = 0;
    var pos: usize = 0;

    while (pos + block_size <= server_data.len) {
        const block = server_data[pos..][0..block_size];
        const rolling = RollingChecksum.compute(block);
        const rolling_hash = rolling.hash();

        if (hash_table.get(rolling_hash)) |entries| {
            // Check strong hash
            const strong = xxh3Hash(block);
            for (entries.items) |entry| {
                if (entry.strong == strong) {
                    // Match found — emit any pending literal data first
                    if (pos > literal_start) {
                        const literal = server_data[literal_start..pos];
                        try delta.append(allocator, @intFromEnum(DeltaCmd.literal));
                        var len_buf: [4]u8 = undefined;
                        std.mem.writeInt(u32, &len_buf, @intCast(literal.len), .little);
                        try delta.appendSlice(allocator, &len_buf);
                        try delta.appendSlice(allocator, literal);
                    }

                    // Emit COPY command
                    try delta.append(allocator, @intFromEnum(DeltaCmd.copy));
                    var offset_buf: [8]u8 = undefined;
                    std.mem.writeInt(u64, &offset_buf, @as(u64, entry.index) * @as(u64, block_size), .little);
                    try delta.appendSlice(allocator, &offset_buf);
                    var copy_len_buf: [4]u8 = undefined;
                    std.mem.writeInt(u32, &copy_len_buf, block_size, .little);
                    try delta.appendSlice(allocator, &copy_len_buf);

                    pos += block_size;
                    literal_start = pos;
                    break;
                }
            } else {
                pos += 1;
            }
        } else {
            pos += 1;
        }
    }

    // Emit remaining data as literal
    if (literal_start < server_data.len) {
        const literal = server_data[literal_start..];
        try delta.append(allocator, @intFromEnum(DeltaCmd.literal));
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(literal.len), .little);
        try delta.appendSlice(allocator, &len_buf);
        try delta.appendSlice(allocator, literal);
    }

    return try allocator.dupe(u8, delta.items);
}


// Transfer Manager


pub const TransferManager = struct {
    sessions: std.AutoHashMap(u32, *TransferSession),
    next_id: u32,
    allocator: Allocator,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: Allocator) TransferManager {
        return .{
            .sessions = std.AutoHashMap(u32, *TransferSession).init(allocator),
            .next_id = 1,
            .allocator = allocator,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *TransferManager) void {
        var iter = self.sessions.valueIterator();
        while (iter.next()) |session| {
            session.*.deinit();
        }
        self.sessions.deinit();
    }

    pub fn createSession(self: *TransferManager, direction: TransferDirection, flags: TransferFlags, base_path: []const u8) !*TransferSession {
        self.mutex.lock();
        defer self.mutex.unlock();

        const id = self.next_id;
        self.next_id += 1;

        const session = try TransferSession.init(self.allocator, id, direction, flags, base_path);
        try self.sessions.put(id, session);

        return session;
    }

    pub fn getSession(self: *TransferManager, id: u32) ?*TransferSession {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.sessions.get(id);
    }

    pub fn removeSession(self: *TransferManager, id: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.fetchRemove(id)) |entry| {
            entry.value.deinit();
        }
    }

    // Resume a session from saved state
    pub fn resumeSession(self: *TransferManager, id: u32) !*TransferSession {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = try TransferSession.loadState(self.allocator, id);
        try self.sessions.put(id, session);
        return session;
    }
};
