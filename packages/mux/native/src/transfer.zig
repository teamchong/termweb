const std = @import("std");
const fs = std.fs;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

// zstd compression
const zstd = @import("zstd.zig");

// XXH3 SIMD-accelerated hashing
// Use extern declaration directly to avoid cImport macro expansion issues
// XXH3 is SIMD-accelerated on ARM64 (NEON) and x86-64 (AVX2/SSE2)
// 3-5x faster than xxHash64 for large inputs
extern fn XXH3_64bits(input: ?*const anyopaque, length: usize) u64;

inline fn xxh3Hash(data: []const u8) u64 {
    return XXH3_64bits(data.ptr, data.len);
}

// ============================================================================
// Platform Detection (comptime)
// ============================================================================

const is_linux = builtin.os.tag == .linux;
const is_darwin = builtin.os.tag == .macos;

// Platform-specific imports
const dispatch = if (is_darwin) @cImport({
    @cInclude("dispatch/dispatch.h");
}) else void;

// Linux io_uring
const linux = if (is_linux) std.os.linux else void;
const IoUring = if (is_linux) linux.IoUring else void;

// ============================================================================
// Linux io_uring for async I/O
// ============================================================================

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
        var iovecs = [_]posix.iovec{.{
            .base = buf.ptr,
            .len = buf.len,
        }};
        _ = try self.ring.read(0, self.fd, .{ .buffer = &iovecs }, offset);
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

        const iovecs = try allocator.alloc(posix.iovec, count);
        defer allocator.free(iovecs);

        // Allocate buffers and submit all reads
        for (0..count) |i| {
            const buf = try allocator.alloc(u8, lengths[i]);
            results[i] = buf;
            iovecs[i] = .{ .base = buf.ptr, .len = buf.len };

            _ = try self.ring.read(@intCast(i), self.fd, .{ .buffer = iovecs[i..][0..1] }, offsets[i]);
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

// ============================================================================
// macOS dispatch_io for async/parallel I/O
// ============================================================================

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
        // Set high water mark for better throughput
        dispatch.dispatch_io_set_high_water(channel, 256 * 1024);
        return .{ .channel = channel, .queue = queue };
    }

    pub fn deinit(self: *@This()) void {
        dispatch.dispatch_io_close(self.channel, dispatch.DISPATCH_IO_STOP);
        dispatch.dispatch_release(self.channel);
    }

    // Read file data asynchronously
    pub fn read(self: *@This(), offset: u64, length: usize, allocator: Allocator) ![]u8 {
        var result: ?[]u8 = null;
        var read_error: bool = false;
        var done = std.atomic.Value(bool).init(false);

        const State = struct {
            result: *?[]u8,
            err: *bool,
            done: *std.atomic.Value(bool),
            alloc: Allocator,
        };
        var state = State{
            .result = &result,
            .err = &read_error,
            .done = &done,
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

        // Wait for completion
        while (!done.load(.acquire)) {
            std.time.sleep(100);
        }

        if (read_error) return error.ReadFailed;
        return result orelse error.NoData;
    }

    fn handleReadComplete(ctx: ?*anyopaque, data: dispatch.dispatch_data_t, err: c_int) callconv(.C) void {
        const State = struct {
            result: *?[]u8,
            err: *bool,
            done: *std.atomic.Value(bool),
            alloc: Allocator,
        };
        const state = @as(*State, @ptrCast(@alignCast(ctx)));

        if (err != 0) {
            state.err.* = true;
        } else if (data != null) {
            var buffer: ?*const anyopaque = null;
            var size: usize = 0;
            _ = dispatch.dispatch_data_create_map(data, &buffer, &size);
            if (buffer != null and size > 0) {
                const buf = state.alloc.alloc(u8, size) catch {
                    state.err.* = true;
                    state.done.store(true, .release);
                    return;
                };
                @memcpy(buf, @as([*]const u8, @ptrCast(buffer))[0..size]);
                state.result.* = buf;
            }
        }
        state.done.store(true, .release);
    }
} else struct {
    // Non-macOS fallback - uses IoUringReader on Linux, standard I/O otherwise
    fd: posix.fd_t,

    pub fn init(fd: posix.fd_t) @This() {
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
};

// ============================================================================
// Parallel Chunk Compression (dispatch on macOS)
// ============================================================================

pub const ParallelCompressor = struct {
    const CHUNK_SIZE: usize = 256 * 1024; // 256KB chunks

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
            // Sequential fallback for Linux (TODO: use std.Thread.Pool)
            for (0..chunk_count) |i| {
                const start = i * CHUNK_SIZE;
                const end = @min(start + CHUNK_SIZE, data.len);
                const chunk = data[start..end];

                // Use zstd for compression
                const compressed = zstd.compressSimple(allocator, chunk, compression_level) catch {
                    for (results[0..i]) |result| {
                        allocator.free(result);
                    }
                    allocator.free(results);
                    return error.CompressionFailed;
                };

                results[i] = compressed;
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

    // Free all compressed chunks
    pub fn freeChunks(allocator: Allocator, chunks: [][]u8) void {
        for (chunks) |chunk| {
            if (chunk.len > 0) allocator.free(chunk);
        }
        allocator.free(chunks);
    }
};

// ============================================================================
// Parallel File Hasher (dispatch on macOS)
// ============================================================================

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
            // Sequential fallback for Linux (TODO: use std.Thread.Pool)
            for (file_names, 0..) |name, i| {
                results[i] = hashFileMmapStatic(dir, name) catch 0;
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

// ============================================================================
// File Transfer Protocol
// ============================================================================

// Message types from client (0x20-0x2F)
pub const ClientMsgType = enum(u8) {
    transfer_init = 0x20,     // Start transfer
    file_list_request = 0x21, // Request folder listing
    file_data = 0x22,         // File chunk data (upload)
    transfer_resume = 0x23,   // Resume interrupted transfer
    transfer_cancel = 0x24,   // Cancel transfer
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

// ============================================================================
// Transfer Session
// ============================================================================

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

        if (self.compressor) |*comp| comp.deinit();
        if (self.decompressor) |*decomp| decomp.deinit();

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

// ============================================================================
// Message Builders
// ============================================================================

// Build TRANSFER_READY message
// [0x30][transfer_id:u32]
pub fn buildTransferReady(allocator: Allocator, transfer_id: u32) ![]u8 {
    var msg = try allocator.alloc(u8, 5);
    msg[0] = @intFromEnum(ServerMsgType.transfer_ready);
    std.mem.writeInt(u32, msg[1..5], transfer_id, .little);
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

// ============================================================================
// Message Parsers
// ============================================================================

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

// ============================================================================
// Glob Pattern Matching
// ============================================================================

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

// ============================================================================
// Transfer Manager
// ============================================================================

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
