/// Fast JPEG decoding using libjpeg-turbo
/// 2-4x faster than stb_image due to SIMD optimizations
const std = @import("std");

const c = @cImport({
    @cInclude("turbojpeg.h");
});

pub const DecodedImage = struct {
    data: []u8,
    width: u32,
    height: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DecodedImage) void {
        self.allocator.free(self.data);
    }
};

/// Decode JPEG from memory to raw RGBA pixels using turbojpeg
/// Returns null if decoding fails or not a JPEG
pub fn decode(allocator: std.mem.Allocator, data: []const u8) ?DecodedImage {
    // Check JPEG magic bytes (FFD8FF)
    if (data.len < 3 or data[0] != 0xFF or data[1] != 0xD8 or data[2] != 0xFF) {
        return null; // Not a JPEG
    }

    const handle = c.tjInitDecompress();
    if (handle == null) return null;
    defer _ = c.tjDestroy(handle);

    var width: c_int = 0;
    var height: c_int = 0;
    var subsamp: c_int = 0;
    var colorspace: c_int = 0;

    // Get image dimensions
    if (c.tjDecompressHeader3(
        handle,
        data.ptr,
        @intCast(data.len),
        &width,
        &height,
        &subsamp,
        &colorspace,
    ) != 0) {
        return null;
    }

    const w: u32 = @intCast(width);
    const h: u32 = @intCast(height);
    const size = w * h * 4;

    // Allocate output buffer
    const output = allocator.alloc(u8, size) catch return null;
    errdefer allocator.free(output);

    // Decode to RGBA
    if (c.tjDecompress2(
        handle,
        data.ptr,
        @intCast(data.len),
        output.ptr,
        width,
        0, // pitch (0 = tight packing)
        height,
        c.TJPF_RGBA,
        0, // flags
    ) != 0) {
        allocator.free(output);
        return null;
    }

    return DecodedImage{
        .data = output,
        .width = w,
        .height = h,
        .allocator = allocator,
    };
}

/// Result type for decodeWithError
pub const DecodeResult = struct {
    image: ?DecodedImage,
    error_msg: []const u8,
};

/// Decode JPEG with detailed error message
pub fn decodeWithError(allocator: std.mem.Allocator, data: []const u8) DecodeResult {
    // Check JPEG magic bytes (FFD8FF)
    if (data.len < 3 or data[0] != 0xFF or data[1] != 0xD8 or data[2] != 0xFF) {
        return .{ .image = null, .error_msg = "not a JPEG (bad magic)" };
    }

    const handle = c.tjInitDecompress();
    if (handle == null) return .{ .image = null, .error_msg = "tjInitDecompress failed" };
    defer _ = c.tjDestroy(handle);

    var width: c_int = 0;
    var height: c_int = 0;
    var subsamp: c_int = 0;
    var colorspace: c_int = 0;

    // Get image dimensions
    if (c.tjDecompressHeader3(
        handle,
        data.ptr,
        @intCast(data.len),
        &width,
        &height,
        &subsamp,
        &colorspace,
    ) != 0) {
        const err_str = c.tjGetErrorStr2(handle);
        if (err_str != null) {
            return .{ .image = null, .error_msg = std.mem.span(err_str) };
        }
        return .{ .image = null, .error_msg = "header parse failed" };
    }

    const w: u32 = @intCast(width);
    const h: u32 = @intCast(height);
    const size = w * h * 4;

    // Allocate output buffer
    const output = allocator.alloc(u8, size) catch {
        return .{ .image = null, .error_msg = "alloc failed" };
    };

    // Decode to RGBA
    if (c.tjDecompress2(
        handle,
        data.ptr,
        @intCast(data.len),
        output.ptr,
        width,
        0,
        height,
        c.TJPF_RGBA,
        0,
    ) != 0) {
        const err_str = c.tjGetErrorStr2(handle);
        allocator.free(output);
        if (err_str != null) {
            return .{ .image = null, .error_msg = std.mem.span(err_str) };
        }
        return .{ .image = null, .error_msg = "decompress failed" };
    }

    return .{
        .image = DecodedImage{
            .data = output,
            .width = w,
            .height = h,
            .allocator = allocator,
        },
        .error_msg = "",
    };
}
