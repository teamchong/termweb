/// Scalar and SWAR implementations for SIMD operations
/// SWAR (SIMD Within A Register) processes 8 bytes at a time using 64-bit operations
/// This is PyPy's technique for fast JSON string scanning
const std = @import("std");

/// SWAR constants for 64-bit word operations
const EVERY_BYTE_ONE: u64 = 0x0101010101010101;
const EVERY_BYTE_HIGH: u64 = 0x8080808080808080;

/// Create a 64-bit word with byte repeated 8 times
inline fn byteRepeated(byte: u8) u64 {
    return EVERY_BYTE_ONE * @as(u64, byte);
}

/// Check if any byte in word is zero (SWAR technique)
/// Uses the formula: (word - 0x0101...) & ~word & 0x8080...
inline fn hasZeroByte(word: u64) bool {
    return ((word -% EVERY_BYTE_ONE) & ~word & EVERY_BYTE_HIGH) != 0;
}

/// Check if word has any string-ending char: " or \ or control char (<0x20)
inline fn hasStringEnder(word: u64) u64 {
    const mask_quote = byteRepeated('"');
    const mask_backslash = byteRepeated('\\');
    const mask_control = byteRepeated(0xff - 0x1f); // For detecting chars < 0x20

    // XOR to check equality (zero byte means match)
    const x1 = mask_quote ^ word;
    const x2 = mask_backslash ^ word;
    // AND with mask_control makes bytes < 0x20 become 0
    const x3 = mask_control & word;

    // Combine: check if any of these has a zero byte
    const result = ((x1 -% EVERY_BYTE_ONE) & ~x1) |
        ((x2 -% EVERY_BYTE_ONE) & ~x2) |
        ((x3 -% EVERY_BYTE_ONE) & ~x3);

    return result & EVERY_BYTE_HIGH;
}

/// Find index of first non-zero byte in result from hasStringEnder
inline fn firstNonZeroByteIndex(word: u64) usize {
    // Use trailing zeros to find position (little endian)
    return @ctz(word) / 8;
}

/// Find next special JSON character: { } [ ] : , " \
pub fn findSpecialChar(data: []const u8, offset: usize) ?usize {
    var i = offset;
    while (i < data.len) : (i += 1) {
        const c = data[i];
        switch (c) {
            '{', '}', '[', ']', ':', ',', '"', '\\' => return i,
            else => {},
        }
    }
    return null;
}

/// Find closing quote, tracking escapes
pub fn findClosingQuote(data: []const u8, offset: usize) ?usize {
    var i = offset;
    while (i < data.len) : (i += 1) {
        const c = data[i];
        if (c == '"') {
            return i;
        } else if (c == '\\') {
            i += 1; // Skip escaped character
            if (i >= data.len) return null;
        } else if (c < 0x20) {
            // Control characters must be escaped
            return null;
        }
    }
    return null;
}

/// Find closing quote AND detect escapes using SWAR (PyPy technique)
/// Processes 8 bytes at a time for ~4x speedup on long strings
pub fn findClosingQuoteAndEscapes(data: []const u8) ?@import("dispatch.zig").QuoteAndEscapeResult {
    var i: usize = 0;
    var has_escapes = false;

    // SWAR fast path: process 8 bytes at a time
    const word_ptr = @as([*]align(1) const u64, @ptrCast(data.ptr));
    const num_words = data.len / 8;

    var word_idx: usize = 0;
    while (word_idx < num_words) : (word_idx += 1) {
        const word = word_ptr[word_idx];
        const ender = hasStringEnder(word);

        if (ender != 0) {
            // Found a string-ending character, need to check which one
            const byte_idx = firstNonZeroByteIndex(ender);
            i = word_idx * 8 + byte_idx;

            // Fall through to byte-by-byte from this position
            break;
        }
    } else {
        // No string-ender found in words, start from remainder
        i = num_words * 8;
    }

    // Byte-by-byte for remainder and to handle escapes
    while (i < data.len) {
        const c = data[i];
        if (c == '"') {
            return .{
                .quote_pos = i,
                .has_escapes = has_escapes,
            };
        } else if (c == '\\') {
            has_escapes = true;
            i += 2; // Skip escape + escaped char
            if (i > data.len) return null;
        } else if (c < 0x20) {
            // Control characters must be escaped
            return null;
        } else {
            i += 1;
        }
    }
    return null;
}

/// Validate UTF-8 encoding
pub fn validateUtf8(data: []const u8) bool {
    var i: usize = 0;
    while (i < data.len) {
        const c = data[i];

        if (c < 0x80) {
            // ASCII
            i += 1;
        } else if (c < 0xC0) {
            // Invalid - continuation byte without leader
            return false;
        } else if (c < 0xE0) {
            // 2-byte sequence
            if (i + 1 >= data.len) return false;
            if (!isContinuation(data[i + 1])) return false;
            i += 2;
        } else if (c < 0xF0) {
            // 3-byte sequence
            if (i + 2 >= data.len) return false;
            if (!isContinuation(data[i + 1])) return false;
            if (!isContinuation(data[i + 2])) return false;
            i += 3;
        } else if (c < 0xF8) {
            // 4-byte sequence
            if (i + 3 >= data.len) return false;
            if (!isContinuation(data[i + 1])) return false;
            if (!isContinuation(data[i + 2])) return false;
            if (!isContinuation(data[i + 3])) return false;
            i += 4;
        } else {
            // Invalid UTF-8
            return false;
        }
    }
    return true;
}

/// Check if byte is UTF-8 continuation byte (0b10xxxxxx)
inline fn isContinuation(byte: u8) bool {
    return (byte & 0xC0) == 0x80;
}

/// Count characters matching target
pub fn countMatching(data: []const u8, target: u8) usize {
    var count: usize = 0;
    for (data) |c| {
        if (c == target) count += 1;
    }
    return count;
}

/// Check if string has any escape sequences
pub fn hasEscapes(data: []const u8) bool {
    for (data) |c| {
        if (c == '\\') return true;
    }
    return false;
}

test "findSpecialChar" {
    const data = "hello{world}";
    try std.testing.expectEqual(@as(?usize, 5), findSpecialChar(data, 0));
    try std.testing.expectEqual(@as(?usize, 11), findSpecialChar(data, 6));
    try std.testing.expectEqual(@as(?usize, null), findSpecialChar(data, 12));
}

test "findClosingQuote" {
    const data = "hello\"world";
    try std.testing.expectEqual(@as(?usize, 5), findClosingQuote(data, 0));

    // Escaped quote: hello\"world"end -> quote at position 12
    const escaped = "hello\\\"world\"end";
    try std.testing.expectEqual(@as(?usize, 12), findClosingQuote(escaped, 0));
}

test "validateUtf8" {
    try std.testing.expect(validateUtf8("hello"));
    try std.testing.expect(validateUtf8("hello 世界"));
    try std.testing.expect(!validateUtf8(&[_]u8{0xFF, 0xFE})); // Invalid
}
