/// Image decoding using stb_image
/// Decodes JPEG/PNG to raw RGBA pixels for zero-copy SHM transfer
const std = @import("std");

const c = @cImport({
    @cInclude("stb_image.h");
});

pub const DecodedImage = struct {
    data: []u8,
    width: u32,
    height: u32,

    pub fn deinit(self: *DecodedImage) void {
        c.stbi_image_free(self.data.ptr);
    }
};

/// Decode JPEG or PNG from memory to raw RGBA pixels
/// Returns null if decoding fails
pub fn decode(data: []const u8) ?DecodedImage {
    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;

    const ptr = c.stbi_load_from_memory(
        data.ptr,
        @intCast(data.len),
        &width,
        &height,
        &channels,
        4, // Force RGBA output
    );

    if (ptr == null) return null;

    const size: usize = @intCast(width * height * 4);
    return DecodedImage{
        .data = ptr[0..size],
        .width = @intCast(width),
        .height = @intCast(height),
    };
}

/// Decode base64-encoded image data
pub fn decodeBase64(allocator: std.mem.Allocator, base64_data: []const u8) !?DecodedImage {
    // Decode base64 first
    const decoder = std.base64.standard.Decoder;
    const decoded_len = try decoder.calcSizeForSlice(base64_data);
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);

    try decoder.decode(decoded, base64_data);

    return decode(decoded);
}

test "decode stub" {
    // Just ensure it compiles
    _ = decode;
    _ = decodeBase64;
}
