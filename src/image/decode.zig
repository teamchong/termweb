/// Image decoding - turbojpeg for JPEG (screencast), stb_image for PNG (toolbar icons)
const std = @import("std");
const turbojpeg = @import("turbojpeg.zig");

const c = @cImport({
    @cInclude("stb_image.h");
});

pub const ImageSource = enum { stb, turbojpeg };

pub const DecodedImage = struct {
    data: []u8,
    width: u32,
    height: u32,
    source: ImageSource,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DecodedImage) void {
        switch (self.source) {
            .stb => c.stbi_image_free(self.data.ptr),
            .turbojpeg => self.allocator.free(self.data),
        }
    }
};

// Thread-local allocator for decode
threadlocal var tl_allocator: ?std.mem.Allocator = null;

/// Set allocator for decode()
pub fn setAllocator(allocator: std.mem.Allocator) void {
    tl_allocator = allocator;
}

/// Decode JPEG using turbojpeg (fast, SIMD optimized)
pub fn decodeJpeg(allocator: std.mem.Allocator, data: []const u8) ?DecodedImage {
    if (turbojpeg.decode(allocator, data)) |img| {
        return DecodedImage{
            .data = img.data,
            .width = img.width,
            .height = img.height,
            .source = .turbojpeg,
            .allocator = allocator,
        };
    }
    return null;
}

/// Decode PNG using stb_image
pub fn decodePng(allocator: std.mem.Allocator, data: []const u8) ?DecodedImage {
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
        .source = .stb,
        .allocator = allocator,
    };
}

/// Decode image - auto-detect format from magic bytes
pub fn decode(data: []const u8) ?DecodedImage {
    const allocator = tl_allocator orelse return null;

    // JPEG magic: FF D8 FF
    if (data.len >= 3 and data[0] == 0xFF and data[1] == 0xD8 and data[2] == 0xFF) {
        return decodeJpeg(allocator, data);
    }

    // PNG magic: 89 50 4E 47
    if (data.len >= 4 and data[0] == 0x89 and data[1] == 0x50 and data[2] == 0x4E and data[3] == 0x47) {
        return decodePng(allocator, data);
    }

    return null;
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
