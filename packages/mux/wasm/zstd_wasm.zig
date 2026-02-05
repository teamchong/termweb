//! zstd WASM module for browser-side compression/decompression.
//! Exports zstd_* functions for use from JavaScript.
//! Built with: zig build wasm

const std = @import("std");

const c = @cImport({
    @cInclude("zstd.h");
});

/// WASM page allocator for all memory management
const wasm_allocator = std.heap.wasm_allocator;

/// Required by WASI libc. Not called (we use exported functions as entry points).
pub fn main() void {}

/// Allocate memory from WASM linear memory.
/// Returns pointer offset for JS to use, or 0 on failure.
export fn zstd_alloc(size: u32) u32 {
    const slice = wasm_allocator.alloc(u8, size) catch return 0;
    return @intFromPtr(slice.ptr);
}

/// Free memory previously allocated with zstd_alloc.
export fn zstd_free(ptr: u32, size: u32) void {
    if (ptr == 0) return;
    const slice: [*]u8 = @ptrFromInt(ptr);
    wasm_allocator.free(slice[0..size]);
}

/// Compress src into dst using zstd.
/// Returns compressed size, or 0 on error.
export fn zstd_compress(
    dst_ptr: u32,
    dst_cap: u32,
    src_ptr: u32,
    src_size: u32,
    level: c_int,
) u32 {
    const src: [*]const u8 = @ptrFromInt(src_ptr);
    const dst: [*]u8 = @ptrFromInt(dst_ptr);
    const result = c.ZSTD_compress(dst, dst_cap, src, src_size, level);
    if (c.ZSTD_isError(result) != 0) return 0;
    return @intCast(result);
}

/// Decompress src into dst using zstd.
/// Returns decompressed size, or 0 on error.
export fn zstd_decompress(
    dst_ptr: u32,
    dst_cap: u32,
    src_ptr: u32,
    src_size: u32,
) u32 {
    const src: [*]const u8 = @ptrFromInt(src_ptr);
    const dst: [*]u8 = @ptrFromInt(dst_ptr);
    const result = c.ZSTD_decompress(dst, dst_cap, src, src_size);
    if (c.ZSTD_isError(result) != 0) return 0;
    return @intCast(result);
}

/// Get the maximum compressed size for a given input size.
export fn zstd_compress_bound(src_size: u32) u32 {
    return @intCast(c.ZSTD_compressBound(src_size));
}

/// Get the decompressed size from a zstd frame header.
/// Returns 0 if unknown or error.
export fn zstd_frame_content_size(src_ptr: u32, src_size: u32) u32 {
    const src: [*]const u8 = @ptrFromInt(src_ptr);
    const result = c.ZSTD_getFrameContentSize(src, src_size);
    // ZSTD_CONTENTSIZE_UNKNOWN = (0ULL - 1), ZSTD_CONTENTSIZE_ERROR = (0ULL - 2)
    const CONTENTSIZE_UNKNOWN: c_ulonglong = @bitCast(@as(i64, -1));
    const CONTENTSIZE_ERROR: c_ulonglong = @bitCast(@as(i64, -2));
    if (result == CONTENTSIZE_UNKNOWN or result == CONTENTSIZE_ERROR) return 0;
    return @intCast(result);
}
