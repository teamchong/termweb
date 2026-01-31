const std = @import("std");
const builtin = @import("builtin");

const is_x86_64 = builtin.cpu.arch == .x86_64;
const is_aarch64 = builtin.cpu.arch == .aarch64;
const has_avx2 = is_x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);

/// SIMD-accelerated WebSocket frame masking/unmasking.
/// Processes 16-32 bytes per iteration instead of 1 byte at a time.
/// Handles unaligned data correctly by processing head/tail bytes scalar.
/// Works for both masking (client->server) and unmasking (server->client).
pub fn xorMask(payload: []u8, mask: [4]u8) void {
    if (payload.len == 0) return;

    if (comptime has_avx2) {
        xorMaskSimd(payload, mask, 32);
    } else if (comptime is_aarch64 or is_x86_64) {
        xorMaskSimd(payload, mask, 16);
    } else {
        xorMaskScalar(payload, mask);
    }
}

/// Generic SIMD implementation that handles alignment properly.
/// VEC_SIZE must be 16 or 32.
fn xorMaskSimd(payload: []u8, mask: [4]u8, comptime VEC_SIZE: usize) void {
    const Vec = @Vector(VEC_SIZE, u8);

    var i: usize = 0;

    // Process unaligned head bytes until we reach VEC_SIZE alignment
    const addr = @intFromPtr(payload.ptr);
    const aligned_addr = std.mem.alignForward(usize, addr, VEC_SIZE);
    const head_bytes = @min(aligned_addr - addr, payload.len);

    while (i < head_bytes) : (i += 1) {
        payload[i] ^= mask[i % 4];
    }

    // Check if we have any SIMD work to do
    if (i + VEC_SIZE > payload.len) {
        // Just finish with scalar
        while (i < payload.len) : (i += 1) {
            payload[i] ^= mask[i % 4];
        }
        return;
    }

    // Build mask vector rotated to current index
    // mask_vec[j] = mask[(i + j) % 4]
    const rotation = i % 4;
    var mask_arr: [VEC_SIZE]u8 = undefined;
    for (0..VEC_SIZE) |j| {
        mask_arr[j] = mask[(rotation + j) % 4];
    }
    const mask_vec: Vec = mask_arr;

    // Process aligned middle portion with SIMD
    while (i + VEC_SIZE <= payload.len) : (i += VEC_SIZE) {
        const ptr: *align(VEC_SIZE) [VEC_SIZE]u8 = @alignCast(payload[i..][0..VEC_SIZE]);
        const chunk: Vec = ptr.*;
        ptr.* = chunk ^ mask_vec;
    }

    // Process remaining tail bytes
    while (i < payload.len) : (i += 1) {
        payload[i] ^= mask[i % 4];
    }
}

/// Scalar fallback implementation
fn xorMaskScalar(payload: []u8, mask: [4]u8) void {
    for (payload, 0..) |*byte, i| {
        byte.* ^= mask[i % 4];
    }
}

test "xorMask basic" {
    var data = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };
    const mask = [_]u8{ 0xFF, 0x00, 0xFF, 0x00 };
    xorMask(&data, mask);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xFE, 0x02, 0xFC, 0x04, 0xFA, 0x06, 0xF8, 0x08 }, &data);
}

test "xorMask empty" {
    var data = [_]u8{};
    const mask = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
    xorMask(&data, mask);
}

test "xorMask large aligned" {
    var data: [1024]u8 = undefined;
    for (&data, 0..) |*byte, i| {
        byte.* = @truncate(i);
    }
    const mask = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD };
    xorMask(&data, mask);

    for (data, 0..) |byte, i| {
        const expected: u8 = @truncate(i);
        try std.testing.expectEqual(expected ^ mask[i % 4], byte);
    }
}

test "xorMask unaligned" {
    // Test with unaligned slice
    var buffer: [1050]u8 = undefined;
    for (&buffer, 0..) |*byte, i| {
        byte.* = @truncate(i);
    }

    // Create unaligned slice by offsetting by 3 bytes
    const data = buffer[3..1027];
    const mask = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    xorMask(data, mask);

    for (data, 0..) |byte, i| {
        const original: u8 = @truncate(i + 3);
        try std.testing.expectEqual(original ^ mask[i % 4], byte);
    }
}

test "xorMask various sizes" {
    const mask = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };

    // Test sizes around vector boundaries
    const sizes = [_]usize{ 1, 3, 4, 15, 16, 17, 31, 32, 33, 63, 64, 65, 100, 256 };

    for (sizes) |size| {
        const data = try std.testing.allocator.alloc(u8, size);
        defer std.testing.allocator.free(data);

        for (data, 0..) |*byte, i| {
            byte.* = @truncate(i);
        }

        xorMask(data, mask);

        for (data, 0..) |byte, i| {
            const original: u8 = @truncate(i);
            try std.testing.expectEqual(original ^ mask[i % 4], byte);
        }
    }
}
