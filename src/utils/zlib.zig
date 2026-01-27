/// Zlib compression using libdeflate (2-3x faster than system zlib)
/// Used for Kitty graphics o=z compression to reduce SSH bandwidth
const std = @import("std");

const c = @cImport({
    @cInclude("libdeflate.h");
});

pub const ZlibError = error{
    CompressionError,
    DecompressionError,
    OutOfMemory,
};

/// Compress data using zlib format
/// Returns compressed data - caller owns the memory
pub fn compress(allocator: std.mem.Allocator, data: []const u8, level: i32) ![]u8 {
    // Map level: 1=fast, 6=default, 9=best, -1=default
    const actual_level: c_int = if (level < 0) 6 else @min(12, @max(1, level));

    const compressor = c.libdeflate_alloc_compressor(actual_level) orelse return ZlibError.OutOfMemory;
    defer c.libdeflate_free_compressor(compressor);

    // Get worst-case bound
    const max_size = c.libdeflate_zlib_compress_bound(compressor, data.len);
    const output = try allocator.alloc(u8, max_size);
    errdefer allocator.free(output);

    const compressed_size = c.libdeflate_zlib_compress(
        compressor,
        data.ptr,
        data.len,
        output.ptr,
        output.len,
    );

    if (compressed_size == 0) {
        allocator.free(output);
        return ZlibError.CompressionError;
    }

    // Resize to actual size (or return slice if realloc fails)
    return allocator.realloc(output, compressed_size) catch output[0..compressed_size];
}

/// Compress with best speed (level 1) - optimal for real-time streaming
pub fn compressFast(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    return compress(allocator, data, 1);
}

/// Decompress zlib-compressed data
pub fn decompress(allocator: std.mem.Allocator, data: []const u8, max_size: usize) ![]u8 {
    const decompressor = c.libdeflate_alloc_decompressor() orelse return ZlibError.OutOfMemory;
    defer c.libdeflate_free_decompressor(decompressor);

    // Allocate output buffer
    var output_size = if (max_size > 0) max_size else data.len * 4;
    var output = try allocator.alloc(u8, output_size);
    errdefer allocator.free(output);

    // Try to decompress, grow buffer if needed
    while (true) {
        var actual_out_size: usize = 0;
        const result = c.libdeflate_zlib_decompress(
            decompressor,
            data.ptr,
            data.len,
            output.ptr,
            output.len,
            &actual_out_size,
        );

        switch (result) {
            c.LIBDEFLATE_SUCCESS => {
                return allocator.realloc(output, actual_out_size) catch output[0..actual_out_size];
            },
            c.LIBDEFLATE_INSUFFICIENT_SPACE => {
                output_size *= 2;
                output = try allocator.realloc(output, output_size);
            },
            else => {
                allocator.free(output);
                return ZlibError.DecompressionError;
            },
        }
    }
}
