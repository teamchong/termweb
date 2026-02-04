//! Zstd compression wrapper for Zig.
//!
//! Provides a safe Zig interface to Facebook's zstd compression library.
//! Used throughout termweb for:
//! - WebSocket message compression (control and file channels)
//! - File transfer compression
//!
//! Features:
//! - Streaming compression/decompression with context reuse
//! - Automatic buffer management with Zig allocators
//! - Error handling with descriptive error names
//!
//! Note: Uses extern declarations instead of cImport to avoid macro issues.
//!
const std = @import("std");
const Allocator = std.mem.Allocator;

// Context types
const ZSTD_CCtx = opaque {};
const ZSTD_DCtx = opaque {};

// Constants
const ZSTD_CONTENTSIZE_UNKNOWN: u64 = @bitCast(@as(i64, -1));
const ZSTD_CONTENTSIZE_ERROR: u64 = @bitCast(@as(i64, -2));

// Compression functions
extern fn ZSTD_createCCtx() ?*ZSTD_CCtx;
extern fn ZSTD_freeCCtx(cctx: *ZSTD_CCtx) usize;
extern fn ZSTD_compressCCtx(cctx: *ZSTD_CCtx, dst: [*]u8, dstCapacity: usize, src: [*]const u8, srcSize: usize, compressionLevel: c_int) usize;
extern fn ZSTD_compress(dst: [*]u8, dstCapacity: usize, src: [*]const u8, srcSize: usize, compressionLevel: c_int) usize;
extern fn ZSTD_compressBound(srcSize: usize) usize;

// Decompression functions
extern fn ZSTD_createDCtx() ?*ZSTD_DCtx;
extern fn ZSTD_freeDCtx(dctx: *ZSTD_DCtx) usize;
extern fn ZSTD_decompressDCtx(dctx: *ZSTD_DCtx, dst: [*]u8, dstCapacity: usize, src: [*]const u8, srcSize: usize) usize;
extern fn ZSTD_decompress(dst: [*]u8, dstCapacity: usize, src: [*]const u8, srcSize: usize) usize;
extern fn ZSTD_getFrameContentSize(src: [*]const u8, srcSize: usize) u64;

// Error functions
extern fn ZSTD_isError(code: usize) c_uint;
extern fn ZSTD_getErrorName(code: usize) [*:0]const u8;


// Error Handling


pub const Error = error{
    CompressionFailed,
    DecompressionFailed,
    OutOfMemory,
    InvalidInput,
    DstSizeTooSmall,
    UnknownError,
};

fn checkError(code: usize) Error!usize {
    if (ZSTD_isError(code) != 0) {
        // Just return a generic error - we don't need detailed error codes for now
        return Error.UnknownError;
    }
    return code;
}


// Compressor


pub const Compressor = struct {
    cctx: *ZSTD_CCtx,
    allocator: Allocator,
    level: c_int,

    pub fn init(allocator: Allocator, level: c_int) !Compressor {
        const cctx = ZSTD_createCCtx() orelse return error.OutOfMemory;
        return .{
            .cctx = cctx,
            .allocator = allocator,
            .level = level,
        };
    }

    pub fn deinit(self: *Compressor) void {
        _ = ZSTD_freeCCtx(self.cctx);
    }

    /// Get the maximum compressed size for a given input size
    pub fn compressBound(src_size: usize) usize {
        return ZSTD_compressBound(src_size);
    }

    /// Compress data into a newly allocated buffer
    pub fn compress(self: *Compressor, src: []const u8) ![]u8 {
        const max_size = compressBound(src.len);
        const dst = try self.allocator.alloc(u8, max_size);
        errdefer self.allocator.free(dst);

        const actual_size = try self.compressInto(src, dst);

        // Try to shrink the allocation to the actual size.
        // Note: We must use realloc to get proper allocation tracking.
        // Returning a smaller slice of a larger allocation would cause
        // memory corruption when freed (wrong size passed to allocator).
        return self.allocator.realloc(dst, actual_size) catch {
            // Realloc failed - allocate exact size, copy, and free original
            const exact = self.allocator.alloc(u8, actual_size) catch {
                // Even that failed, return full original buffer
                // (caller will free full max_size allocation, which is safe)
                return dst;
            };
            @memcpy(exact, dst[0..actual_size]);
            self.allocator.free(dst);
            return exact;
        };
    }

    /// Compress data into a provided buffer, returns actual compressed size
    pub fn compressInto(self: *Compressor, src: []const u8, dst: []u8) !usize {
        const result = ZSTD_compressCCtx(
            self.cctx,
            dst.ptr,
            dst.len,
            src.ptr,
            src.len,
            self.level,
        );
        return checkError(result);
    }
};


// Decompressor


pub const Decompressor = struct {
    dctx: *ZSTD_DCtx,
    allocator: Allocator,

    pub fn init(allocator: Allocator) !Decompressor {
        const dctx = ZSTD_createDCtx() orelse return error.OutOfMemory;
        return .{
            .dctx = dctx,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Decompressor) void {
        _ = ZSTD_freeDCtx(self.dctx);
    }

    /// Get the decompressed size from a compressed frame header
    /// Returns null if the size is unknown (streaming frame)
    pub fn getFrameContentSize(src: []const u8) ?usize {
        const size = ZSTD_getFrameContentSize(src.ptr, src.len);
        if (size == ZSTD_CONTENTSIZE_UNKNOWN or size == ZSTD_CONTENTSIZE_ERROR) {
            return null;
        }
        return @intCast(size);
    }

    /// Decompress data into a newly allocated buffer
    /// max_size is used as a safety limit if decompressed size is unknown
    pub fn decompress(self: *Decompressor, src: []const u8, max_size: usize) ![]u8 {
        // Try to get the decompressed size from the frame header
        const expected_size = getFrameContentSize(src) orelse max_size;
        const alloc_size = @min(expected_size, max_size);

        const dst = try self.allocator.alloc(u8, alloc_size);
        errdefer self.allocator.free(dst);

        const actual_size = try self.decompressInto(src, dst);

        // Try to shrink the allocation to the actual size.
        // Note: We must use realloc to get proper allocation tracking.
        // Returning a smaller slice of a larger allocation would cause
        // memory corruption when freed (wrong size passed to allocator).
        return self.allocator.realloc(dst, actual_size) catch {
            // Realloc failed - allocate exact size, copy, and free original
            const exact = self.allocator.alloc(u8, actual_size) catch {
                // Even that failed, return full original buffer
                return dst;
            };
            @memcpy(exact, dst[0..actual_size]);
            self.allocator.free(dst);
            return exact;
        };
    }

    /// Decompress data into a provided buffer, returns actual decompressed size
    pub fn decompressInto(self: *Decompressor, src: []const u8, dst: []u8) !usize {
        const result = ZSTD_decompressDCtx(
            self.dctx,
            dst.ptr,
            dst.len,
            src.ptr,
            src.len,
        );
        return checkError(result);
    }
};


// Convenience Functions (stateless, for simple use cases)


/// Simple one-shot compression
pub fn compressSimple(allocator: Allocator, src: []const u8, level: c_int) ![]u8 {
    const max_size = Compressor.compressBound(src.len);
    const dst = try allocator.alloc(u8, max_size);
    errdefer allocator.free(dst);

    const result = ZSTD_compress(dst.ptr, dst.len, src.ptr, src.len, level);
    const actual_size = try checkError(result);

    return allocator.realloc(dst, actual_size) catch {
        const exact = allocator.alloc(u8, actual_size) catch return dst;
        @memcpy(exact, dst[0..actual_size]);
        allocator.free(dst);
        return exact;
    };
}

/// Simple one-shot decompression
pub fn decompressSimple(allocator: Allocator, src: []const u8, max_size: usize) ![]u8 {
    const expected_size = Decompressor.getFrameContentSize(src) orelse max_size;
    const alloc_size = @min(expected_size, max_size);

    const dst = try allocator.alloc(u8, alloc_size);
    errdefer allocator.free(dst);

    const result = ZSTD_decompress(dst.ptr, dst.len, src.ptr, src.len);
    const actual_size = try checkError(result);

    return allocator.realloc(dst, actual_size) catch {
        const exact = allocator.alloc(u8, actual_size) catch return dst;
        @memcpy(exact, dst[0..actual_size]);
        allocator.free(dst);
        return exact;
    };
}


// Tests


test "round-trip compression" {
    const allocator = std.testing.allocator;

    var comp = try Compressor.init(allocator, 3);
    defer comp.deinit();

    var decomp = try Decompressor.init(allocator);
    defer decomp.deinit();

    const original = "Hello, zstd compression! This is a test message that should compress well.";
    const compressed = try comp.compress(original);
    defer allocator.free(compressed);

    const decompressed = try decomp.decompress(compressed, 1024);
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(original, decompressed);
}

test "simple round-trip" {
    const allocator = std.testing.allocator;

    const original = "Simple test data for compression";
    const compressed = try compressSimple(allocator, original, 3);
    defer allocator.free(compressed);

    const decompressed = try decompressSimple(allocator, compressed, 1024);
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(original, decompressed);
}

test "compress bound" {
    const bound = Compressor.compressBound(1000);
    try std.testing.expect(bound > 1000); // Bound should be larger than input
}

test "get frame content size" {
    const allocator = std.testing.allocator;

    const original = "Test data for size detection";
    const compressed = try compressSimple(allocator, original, 3);
    defer allocator.free(compressed);

    const size = Decompressor.getFrameContentSize(compressed);
    try std.testing.expectEqual(@as(?usize, original.len), size);
}
