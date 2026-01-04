/// Compile-time SIMD dispatcher for termweb
/// Automatically selects best implementation based on CPU architecture:
/// - ARM64/M1/M2: NEON (16-byte vectors)
/// - x86_64 + AVX2: AVX2 (32-byte vectors)
/// - x86_64 + SSE2: SSE2 (16-byte vectors)
/// - Other: Scalar fallback
const std = @import("std");
const builtin = @import("builtin");

// Detect architecture at compile time
const is_x86_64 = builtin.cpu.arch == .x86_64;
const is_aarch64 = builtin.cpu.arch == .aarch64;

// Detect x86 features
const has_avx2 = is_x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);
const has_sse2 = is_x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .sse2);

/// Find a byte pattern in data using SIMD acceleration
/// Returns the position of the first match, or null if not found
pub fn findPattern(data: []const u8, pattern: []const u8, offset: usize) ?usize {
    if (pattern.len == 0 or offset >= data.len) return null;
    if (data.len - offset < pattern.len) return null;

    // For short patterns or small data, use scalar
    if (pattern.len > 16 or data.len - offset < 32) {
        return findPatternScalar(data, pattern, offset);
    }

    // Use SIMD to find first byte, then verify rest
    const first_byte = pattern[0];
    var pos = offset;

    while (pos <= data.len - pattern.len) {
        // Find next occurrence of first byte using SIMD
        const found = findByteSimd(data[pos..], first_byte) orelse break;
        const match_pos = pos + found;

        if (match_pos + pattern.len > data.len) break;

        // Verify the rest of the pattern
        if (std.mem.eql(u8, data[match_pos..][0..pattern.len], pattern)) {
            return match_pos;
        }

        pos = match_pos + 1;
    }

    return null;
}

/// Find a single byte using SIMD - dispatches to best available implementation
fn findByteSimd(data: []const u8, target: u8) ?usize {
    if (comptime has_avx2) {
        return findByteAvx2(data, target);
    } else if (comptime has_sse2) {
        return findByteSse2(data, target);
    } else if (comptime is_aarch64) {
        return findByteNeon(data, target);
    }
    return findByteScalar(data, target);
}

// ============================================================================
// ARM64 NEON Implementation (16-byte vectors)
// ============================================================================

fn findByteNeon(data: []const u8, target: u8) ?usize {
    const VEC_SIZE = 16;
    if (data.len < VEC_SIZE) {
        return findByteScalar(data, target);
    }

    var i: usize = 0;
    const end = data.len - VEC_SIZE;
    const target_vec: @Vector(VEC_SIZE, u8) = @splat(target);

    while (i <= end) : (i += VEC_SIZE) {
        const chunk: @Vector(VEC_SIZE, u8) = data[i..][0..VEC_SIZE].*;
        const matches = chunk == target_vec;

        if (@reduce(.Or, matches)) {
            // Find exact position using trailing zeros
            inline for (0..VEC_SIZE) |j| {
                if (matches[j]) return i + j;
            }
        }
    }

    // Handle remainder
    return if (findByteScalar(data[i..], target)) |pos| i + pos else null;
}

// ============================================================================
// x86_64 AVX2 Implementation (32-byte vectors)
// ============================================================================

fn findByteAvx2(data: []const u8, target: u8) ?usize {
    const VEC_SIZE = 32;
    if (data.len < VEC_SIZE) {
        return findByteSse2(data, target); // Fall back to SSE2 for small data
    }

    var i: usize = 0;
    const end = data.len - VEC_SIZE;
    const target_vec: @Vector(VEC_SIZE, u8) = @splat(target);

    while (i <= end) : (i += VEC_SIZE) {
        const chunk: @Vector(VEC_SIZE, u8) = data[i..][0..VEC_SIZE].*;
        const matches = chunk == target_vec;

        if (@reduce(.Or, matches)) {
            inline for (0..VEC_SIZE) |j| {
                if (matches[j]) return i + j;
            }
        }
    }

    // Handle remainder with SSE2
    return if (findByteSse2(data[i..], target)) |pos| i + pos else null;
}

// ============================================================================
// x86_64 SSE2 Implementation (16-byte vectors) - fallback for older CPUs
// ============================================================================

fn findByteSse2(data: []const u8, target: u8) ?usize {
    const VEC_SIZE = 16;
    if (data.len < VEC_SIZE) {
        return findByteScalar(data, target);
    }

    var i: usize = 0;
    const end = data.len - VEC_SIZE;
    const target_vec: @Vector(VEC_SIZE, u8) = @splat(target);

    while (i <= end) : (i += VEC_SIZE) {
        const chunk: @Vector(VEC_SIZE, u8) = data[i..][0..VEC_SIZE].*;
        const matches = chunk == target_vec;

        if (@reduce(.Or, matches)) {
            inline for (0..VEC_SIZE) |j| {
                if (matches[j]) return i + j;
            }
        }
    }

    return if (findByteScalar(data[i..], target)) |pos| i + pos else null;
}

// ============================================================================
// Scalar Fallback (for any architecture)
// ============================================================================

fn findByteScalar(data: []const u8, target: u8) ?usize {
    return std.mem.indexOfScalar(u8, data, target);
}

fn findPatternScalar(data: []const u8, pattern: []const u8, offset: usize) ?usize {
    return std.mem.indexOfPos(u8, data, offset, pattern);
}

// ============================================================================
// Closing Quote Detection (handles escape sequences)
// ============================================================================

/// Find closing quote after a string starts (handles escapes correctly)
pub fn findClosingQuote(data: []const u8, offset: usize) ?usize {
    // Use SIMD to quickly scan for quote or backslash, then handle escapes
    if (comptime has_avx2) {
        return findClosingQuoteSimd(data, offset, 32);
    } else if (comptime has_sse2 or is_aarch64) {
        return findClosingQuoteSimd(data, offset, 16);
    }
    return findClosingQuoteScalar(data, offset);
}

fn findClosingQuoteSimd(data: []const u8, offset: usize, comptime VEC_SIZE: usize) ?usize {
    if (data.len - offset < VEC_SIZE) {
        return findClosingQuoteScalar(data, offset);
    }

    var i = offset;
    const end = data.len - VEC_SIZE;

    const quote_vec: @Vector(VEC_SIZE, u8) = @splat('"');
    const backslash_vec: @Vector(VEC_SIZE, u8) = @splat('\\');

    // SIMD fast path: scan for quote or backslash
    while (i <= end) {
        const chunk: @Vector(VEC_SIZE, u8) = data[i..][0..VEC_SIZE].*;
        const is_quote = chunk == quote_vec;
        const is_backslash = chunk == backslash_vec;
        const is_terminator = is_quote | is_backslash;

        if (@reduce(.Or, is_terminator)) {
            // Found something, switch to scalar for correct escape handling
            break;
        }
        i += VEC_SIZE;
    }

    // Scalar for remainder and escape handling
    return findClosingQuoteScalar(data, i);
}

fn findClosingQuoteScalar(data: []const u8, offset: usize) ?usize {
    var i = offset;
    while (i < data.len) {
        const c = data[i];
        if (c == '"') {
            return i;
        } else if (c == '\\') {
            i += 2; // Skip escape sequence
            if (i > data.len) return null;
        } else {
            i += 1;
        }
    }
    return null;
}

// ============================================================================
// Bulk Operations (useful for counting, validation)
// ============================================================================

/// Count occurrences of a byte using SIMD
pub fn countByte(data: []const u8, target: u8) usize {
    if (comptime has_avx2) {
        return countByteSimd(data, target, 32);
    } else if (comptime has_sse2 or is_aarch64) {
        return countByteSimd(data, target, 16);
    }
    return countByteScalar(data, target);
}

fn countByteSimd(data: []const u8, target: u8, comptime VEC_SIZE: usize) usize {
    if (data.len < VEC_SIZE) {
        return countByteScalar(data, target);
    }

    var count: usize = 0;
    var i: usize = 0;
    const end = data.len - VEC_SIZE;
    const target_vec: @Vector(VEC_SIZE, u8) = @splat(target);

    while (i <= end) : (i += VEC_SIZE) {
        const chunk: @Vector(VEC_SIZE, u8) = data[i..][0..VEC_SIZE].*;
        const matches = chunk == target_vec;
        // Use popcount for efficient counting
        count += @popCount(@as(@Vector(VEC_SIZE, u1), @bitCast(matches)));
    }

    count += countByteScalar(data[i..], target);
    return count;
}

fn countByteScalar(data: []const u8, target: u8) usize {
    var count: usize = 0;
    for (data) |c| {
        if (c == target) count += 1;
    }
    return count;
}

/// Check if data contains any of the specified bytes (useful for JSON special char detection)
pub fn containsAny(data: []const u8, targets: []const u8) bool {
    if (comptime has_avx2) {
        return containsAnySimd(data, targets, 32);
    } else if (comptime has_sse2 or is_aarch64) {
        return containsAnySimd(data, targets, 16);
    }
    return containsAnyScalar(data, targets);
}

fn containsAnySimd(data: []const u8, targets: []const u8, comptime VEC_SIZE: usize) bool {
    if (data.len < VEC_SIZE or targets.len == 0) {
        return containsAnyScalar(data, targets);
    }

    var i: usize = 0;
    const end = data.len - VEC_SIZE;

    while (i <= end) : (i += VEC_SIZE) {
        const chunk: @Vector(VEC_SIZE, u8) = data[i..][0..VEC_SIZE].*;

        // Check each target character
        inline for (0..8) |t| { // Unroll up to 8 targets
            if (t < targets.len) {
                const target_vec: @Vector(VEC_SIZE, u8) = @splat(targets[t]);
                if (@reduce(.Or, chunk == target_vec)) return true;
            }
        }
        // Handle more than 8 targets with scalar
        if (targets.len > 8) {
            for (targets[8..]) |target| {
                const target_vec: @Vector(VEC_SIZE, u8) = @splat(target);
                if (@reduce(.Or, chunk == target_vec)) return true;
            }
        }
    }

    return containsAnyScalar(data[i..], targets);
}

fn containsAnyScalar(data: []const u8, targets: []const u8) bool {
    for (data) |c| {
        for (targets) |t| {
            if (c == t) return true;
        }
    }
    return false;
}

// ============================================================================
// Memory Operations (SIMD memcpy for large blocks)
// ============================================================================

/// SIMD-accelerated memory copy for large blocks
pub fn simdCopy(dst: []u8, src: []const u8) void {
    if (src.len == 0) return;
    std.debug.assert(dst.len >= src.len);

    if (comptime has_avx2) {
        simdCopyImpl(dst, src, 32);
    } else if (comptime has_sse2 or is_aarch64) {
        simdCopyImpl(dst, src, 16);
    } else {
        @memcpy(dst[0..src.len], src);
    }
}

fn simdCopyImpl(dst: []u8, src: []const u8, comptime VEC_SIZE: usize) void {
    var i: usize = 0;
    const end = src.len - (src.len % VEC_SIZE);

    // Copy VEC_SIZE bytes at a time
    while (i < end) : (i += VEC_SIZE) {
        const chunk: @Vector(VEC_SIZE, u8) = src[i..][0..VEC_SIZE].*;
        dst[i..][0..VEC_SIZE].* = chunk;
    }

    // Copy remainder
    if (i < src.len) {
        @memcpy(dst[i..src.len], src[i..]);
    }
}

// ============================================================================
// Debug Info
// ============================================================================

/// Get SIMD implementation info for debugging
pub fn getSimdInfo() []const u8 {
    if (comptime has_avx2) {
        return "AVX2 (x86_64, 32-byte vectors)";
    } else if (comptime has_sse2) {
        return "SSE2 (x86_64, 16-byte vectors)";
    } else if (comptime is_aarch64) {
        return "NEON (ARM64/M1, 16-byte vectors)";
    }
    return "Scalar (no SIMD)";
}

// ============================================================================
// Tests
// ============================================================================

test "findPattern basic" {
    const data = "hello world, this has \"data\":\"value\" here";
    try std.testing.expectEqual(@as(?usize, 23), findPattern(data, "\"data\":\"", 0));
}

test "findPattern not found" {
    const data = "hello world";
    try std.testing.expectEqual(@as(?usize, null), findPattern(data, "xyz", 0));
}

test "findPattern at start" {
    const data = "\"id\":123";
    try std.testing.expectEqual(@as(?usize, 0), findPattern(data, "\"id\":", 0));
}

test "findByteSimd" {
    const data = "abcdefghijklmnopqrstuvwxyz0123456789";
    try std.testing.expectEqual(@as(?usize, 0), findByteSimd(data, 'a'));
    try std.testing.expectEqual(@as(?usize, 25), findByteSimd(data, 'z'));
    try std.testing.expectEqual(@as(?usize, null), findByteSimd(data, '!'));
}

test "findClosingQuote basic" {
    const data = "hello world\"rest";
    try std.testing.expectEqual(@as(?usize, 11), findClosingQuote(data, 0));
}

test "findClosingQuote with escape" {
    const data = "hello \\\"world\"rest";
    try std.testing.expectEqual(@as(?usize, 13), findClosingQuote(data, 0));
}

test "countByte" {
    const data = "aaabbbcccaaabbb";
    try std.testing.expectEqual(@as(usize, 6), countByte(data, 'a'));
    try std.testing.expectEqual(@as(usize, 6), countByte(data, 'b'));
    try std.testing.expectEqual(@as(usize, 3), countByte(data, 'c'));
}

test "containsAny" {
    const data = "hello world";
    try std.testing.expect(containsAny(data, "aeiou")); // has 'e' and 'o'
    try std.testing.expect(!containsAny(data, "xyz"));
}

test "simdCopy" {
    const src = "hello world, this is a test string for SIMD copy";
    var dst: [64]u8 = undefined;
    simdCopy(&dst, src);
    try std.testing.expectEqualStrings(src, dst[0..src.len]);
}

test "getSimdInfo returns non-empty" {
    const info = getSimdInfo();
    try std.testing.expect(info.len > 0);
}
