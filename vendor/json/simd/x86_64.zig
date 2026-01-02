/// AVX2 SIMD implementations for x86_64
/// Processes 32 bytes at a time for high throughput
const std = @import("std");
const scalar = @import("scalar.zig");

/// Find next special JSON character using AVX2: { } [ ] : , " \
pub fn findSpecialCharAvx2(data: []const u8, offset: usize) ?usize {
    if (data.len - offset < 32) {
        return scalar.findSpecialChar(data, offset);
    }

    var i = offset;
    const end = data.len - 32;

    while (i <= end) : (i += 32) {
        // Load 32 bytes
        const chunk: @Vector(32, u8) = data[i..][0..32].*;

        // Check for each special character
        const is_brace_open = chunk == @as(@Vector(32, u8), @splat('{'));
        const is_brace_close = chunk == @as(@Vector(32, u8), @splat('}'));
        const is_bracket_open = chunk == @as(@Vector(32, u8), @splat('['));
        const is_bracket_close = chunk == @as(@Vector(32, u8), @splat(']'));
        const is_colon = chunk == @as(@Vector(32, u8), @splat(':'));
        const is_comma = chunk == @as(@Vector(32, u8), @splat(','));
        const is_quote = chunk == @as(@Vector(32, u8), @splat('"'));
        const is_backslash = chunk == @as(@Vector(32, u8), @splat('\\'));

        // Combine all special character masks
        const is_special = is_brace_open | is_brace_close |
            is_bracket_open | is_bracket_close |
            is_colon | is_comma |
            is_quote | is_backslash;

        // Check if any special character found
        if (@reduce(.Or, is_special)) {
            // Find exact position within chunk
            for (0..32) |j| {
                if (is_special[j]) {
                    return i + j;
                }
            }
        }
    }

    // Handle remaining bytes with scalar
    return scalar.findSpecialChar(data, i);
}

/// Find closing quote using AVX2, handling escapes
pub fn findClosingQuoteAvx2(data: []const u8, offset: usize) ?usize {
    // IMPORTANT: Escapes make this tricky for SIMD - use scalar for correctness
    // The SIMD approach has subtle bugs with escape sequences, so we use the
    // proven scalar implementation which correctly tracks escape state.
    return scalar.findClosingQuote(data, offset);
}

/// Validate UTF-8 using AVX2
pub fn validateUtf8Avx2(data: []const u8) bool {
    if (data.len < 32) {
        return scalar.validateUtf8(data);
    }

    var i: usize = 0;
    const end = data.len - 32;

    while (i <= end) : (i += 32) {
        const chunk: @Vector(32, u8) = data[i..][0..32].*;

        // Fast path: Check if all bytes are ASCII
        const ascii_mask: @Vector(32, u8) = @splat(0x80);
        const has_high_bit = (chunk & ascii_mask) != @as(@Vector(32, u8), @splat(0));

        if (!@reduce(.Or, has_high_bit)) {
            // All ASCII, valid
            continue;
        }

        // Has multi-byte sequences, need careful validation
        // For now, fall back to scalar for this chunk
        if (!scalar.validateUtf8(data[i .. i + 32])) {
            return false;
        }
    }

    // Validate remainder
    return scalar.validateUtf8(data[i..]);
}

/// Count matching characters using AVX2
pub fn countMatchingAvx2(data: []const u8, target: u8) usize {
    if (data.len < 32) {
        return scalar.countMatching(data, target);
    }

    var count: usize = 0;
    var i: usize = 0;
    const end = data.len - 32;

    const target_vec: @Vector(32, u8) = @splat(target);

    while (i <= end) : (i += 32) {
        const chunk: @Vector(32, u8) = data[i..][0..32].*;
        const matches = chunk == target_vec;

        // Count true values
        for (0..32) |j| {
            if (matches[j]) count += 1;
        }
    }

    // Handle remainder
    count += scalar.countMatching(data[i..], target);

    return count;
}

/// Check if string has escapes using AVX2
pub fn hasEscapesAvx2(data: []const u8) bool {
    if (data.len < 32) {
        return scalar.hasEscapes(data);
    }

    var i: usize = 0;
    const end = data.len - 32;

    const backslash_vec: @Vector(32, u8) = @splat('\\');

    while (i <= end) : (i += 32) {
        const chunk: @Vector(32, u8) = data[i..][0..32].*;
        const has_backslash = chunk == backslash_vec;

        if (@reduce(.Or, has_backslash)) {
            return true;
        }
    }

    return scalar.hasEscapes(data[i..]);
}

/// Skip whitespace using AVX2
pub fn skipWhitespaceAvx2(data: []const u8, offset: usize) usize {
    if (data.len - offset < 32) {
        var i = offset;
        while (i < data.len) : (i += 1) {
            const c = data[i];
            if (c != ' ' and c != '\t' and c != '\n' and c != '\r') {
                return i;
            }
        }
        return data.len;
    }

    var i = offset;
    const end = data.len - 32;

    while (i <= end) : (i += 32) {
        const chunk: @Vector(32, u8) = data[i..][0..32].*;

        const is_space = chunk == @as(@Vector(32, u8), @splat(' '));
        const is_tab = chunk == @as(@Vector(32, u8), @splat('\t'));
        const is_newline = chunk == @as(@Vector(32, u8), @splat('\n'));
        const is_cr = chunk == @as(@Vector(32, u8), @splat('\r'));

        const is_whitespace = is_space | is_tab | is_newline | is_cr;

        // If any non-whitespace found
        if (!@reduce(.And, is_whitespace)) {
            // Find first non-whitespace
            for (0..32) |j| {
                if (!is_whitespace[j]) {
                    return i + j;
                }
            }
        }
    }

    // Handle remainder
    var pos = i;
    while (pos < data.len) : (pos += 1) {
        const c = data[pos];
        if (c != ' ' and c != '\t' and c != '\n' and c != '\r') {
            return pos;
        }
    }
    return data.len;
}

test "findSpecialCharAvx2" {
    const data = "hello world, this is a test {with} special [chars]";
    const result = findSpecialCharAvx2(data, 0);
    try std.testing.expectEqual(@as(?usize, 11), result); // comma
}

test "countMatchingAvx2" {
    const data = "aaabbbcccaaabbb";
    try std.testing.expectEqual(@as(usize, 6), countMatchingAvx2(data, 'a'));
    try std.testing.expectEqual(@as(usize, 6), countMatchingAvx2(data, 'b'));
    try std.testing.expectEqual(@as(usize, 3), countMatchingAvx2(data, 'c'));
}

test "hasEscapesAvx2" {
    try std.testing.expect(!hasEscapesAvx2("hello world"));
    try std.testing.expect(hasEscapesAvx2("hello\\nworld"));
}

pub fn findClosingQuoteAndEscapesAvx2(data: []const u8) ?@import("dispatch.zig").QuoteAndEscapeResult {
    // Use scalar implementation (SIMD escape tracking is complex, scalar is proven correct)
    return scalar.findClosingQuoteAndEscapes(data);
}
