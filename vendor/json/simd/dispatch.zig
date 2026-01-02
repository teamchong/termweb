/// Compile-time SIMD dispatcher for JSON parsing
/// Automatically selects best implementation based on CPU architecture
const std = @import("std");
const builtin = @import("builtin");

// Import all implementations
const scalar = @import("scalar.zig");
const x86_64 = if (@hasDecl(@This(), "x86_available")) @import("x86_64.zig") else struct {};
const aarch64 = if (@hasDecl(@This(), "aarch64_available")) @import("aarch64.zig") else struct {};

// Detect architecture at compile time
const x86_available = builtin.cpu.arch == .x86_64;
const aarch64_available = builtin.cpu.arch == .aarch64;

/// Find next special JSON character: { } [ ] : , " \
pub fn findSpecialChar(data: []const u8, offset: usize) ?usize {
    if (comptime x86_available) {
        // Check for AVX2 support at compile time
        const has_avx2 = comptime std.Target.x86.featureSetHas(
            builtin.cpu.features,
            .avx2,
        );

        if (has_avx2) {
            return x86_64.findSpecialCharAvx2(data, offset);
        }
    } else if (comptime aarch64_available) {
        return aarch64.findSpecialCharNeon(data, offset);
    }

    // Fallback to scalar
    return scalar.findSpecialChar(data, offset);
}

/// Find closing quote, handling escapes
pub fn findClosingQuote(data: []const u8, offset: usize) ?usize {
    if (comptime x86_available) {
        const has_avx2 = comptime std.Target.x86.featureSetHas(
            builtin.cpu.features,
            .avx2,
        );

        if (has_avx2) {
            return x86_64.findClosingQuoteAvx2(data, offset);
        }
    } else if (comptime aarch64_available) {
        return aarch64.findClosingQuoteNeon(data, offset);
    }

    return scalar.findClosingQuote(data, offset);
}

/// Validate UTF-8 encoding
pub fn validateUtf8(data: []const u8) bool {
    if (comptime x86_available) {
        const has_avx2 = comptime std.Target.x86.featureSetHas(
            builtin.cpu.features,
            .avx2,
        );

        if (has_avx2) {
            return x86_64.validateUtf8Avx2(data);
        }
    } else if (comptime aarch64_available) {
        return aarch64.validateUtf8Neon(data);
    }

    return scalar.validateUtf8(data);
}

/// Count characters matching target
pub fn countMatching(data: []const u8, target: u8) usize {
    if (comptime x86_available) {
        const has_avx2 = comptime std.Target.x86.featureSetHas(
            builtin.cpu.features,
            .avx2,
        );

        if (has_avx2) {
            return x86_64.countMatchingAvx2(data, target);
        }
    } else if (comptime aarch64_available) {
        return aarch64.countMatchingNeon(data, target);
    }

    return scalar.countMatching(data, target);
}

/// Check if string has any escape sequences
pub fn hasEscapes(data: []const u8) bool {
    if (comptime x86_available) {
        const has_avx2 = comptime std.Target.x86.featureSetHas(
            builtin.cpu.features,
            .avx2,
        );

        if (has_avx2) {
            return x86_64.hasEscapesAvx2(data);
        }
    } else if (comptime aarch64_available) {
        return aarch64.hasEscapesNeon(data);
    }

    return scalar.hasEscapes(data);
}

/// Result of combined quote and escape detection
pub const QuoteAndEscapeResult = struct {
    quote_pos: usize,
    has_escapes: bool,
};

/// Find closing quote AND check for escapes in a single pass (faster than separate calls!)
pub fn findClosingQuoteAndEscapes(data: []const u8) ?QuoteAndEscapeResult {
    if (comptime x86_available) {
        const has_avx2 = comptime std.Target.x86.featureSetHas(
            builtin.cpu.features,
            .avx2,
        );

        if (has_avx2) {
            return x86_64.findClosingQuoteAndEscapesAvx2(data);
        }
    } else if (comptime aarch64_available) {
        return aarch64.findClosingQuoteAndEscapesNeon(data);
    }

    return scalar.findClosingQuoteAndEscapes(data);
}

/// Skip whitespace characters
pub fn skipWhitespace(data: []const u8, offset: usize) usize {
    if (comptime x86_available) {
        const has_avx2 = comptime std.Target.x86.featureSetHas(
            builtin.cpu.features,
            .avx2,
        );

        if (has_avx2) {
            return x86_64.skipWhitespaceAvx2(data, offset);
        }
    } else if (comptime aarch64_available) {
        return aarch64.skipWhitespaceNeon(data, offset);
    }

    // Scalar fallback
    var i = offset;
    while (i < data.len) : (i += 1) {
        const c = data[i];
        if (c != ' ' and c != '\t' and c != '\n' and c != '\r') {
            return i;
        }
    }
    return data.len;
}

/// Get SIMD implementation info for debugging
pub fn getSimdInfo() []const u8 {
    if (comptime x86_available) {
        const has_avx2 = comptime std.Target.x86.featureSetHas(
            builtin.cpu.features,
            .avx2,
        );

        if (has_avx2) {
            return "AVX2 (x86_64, 32-byte vectors)";
        } else {
            return "Scalar (x86_64, no AVX2)";
        }
    } else if (comptime aarch64_available) {
        return "NEON (ARM64, 16-byte vectors)";
    }

    return "Scalar (unknown architecture)";
}

test "dispatch selection" {
    const info = getSimdInfo();
    try std.testing.expect(info.len > 0);
}

test "findSpecialChar dispatch" {
    const data = "hello{world}";
    try std.testing.expectEqual(@as(?usize, 5), findSpecialChar(data, 0));
}

test "validateUtf8 dispatch" {
    try std.testing.expect(validateUtf8("hello"));
    try std.testing.expect(validateUtf8("hello 世界"));
}
