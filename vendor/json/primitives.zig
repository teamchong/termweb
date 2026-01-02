//! JSON Parsing Primitives - shared low-level functions
//! Used by both shared/json and runtime/json_impl to avoid code duplication.
//!
//! These are pure functions that operate on byte slices without any
//! dependency on Value, PyObject, or other high-level types.

const std = @import("std");

/// Shared error types for JSON parsing
pub const ParseError = error{
    UnexpectedToken,
    InvalidNumber,
    InvalidString,
    InvalidEscape,
    InvalidUnicode,
    UnterminatedString,
    MaxDepthExceeded,
    OutOfMemory,
    TrailingData,
    TrailingComma,
    DuplicateKey,
    UnexpectedEndOfInput,
    NumberOutOfRange,
};

/// Result of parsing a number
pub const NumberResult = union(enum) {
    int: i64,
    float: f64,
};

/// Result of parsing a number with consumed bytes
pub const ParsedNumber = struct {
    value: NumberResult,
    consumed: usize,
};

// ============================================================================
// Number Parsing
// ============================================================================

/// Fast path for positive integers (most common case)
pub fn parsePositiveInt(data: []const u8, pos: usize) ?struct { value: i64, consumed: usize } {
    var value: i64 = 0;
    var i: usize = 0;

    while (pos + i < data.len) : (i += 1) {
        const c = data[pos + i];
        if (c < '0' or c > '9') break;

        const digit = c - '0';
        // Check for overflow
        if (value > @divTrunc((@as(i64, std.math.maxInt(i64)) - digit), 10)) {
            return null; // Overflow
        }
        value = value * 10 + digit;
    }

    if (i == 0) return null;
    return .{ .value = value, .consumed = i };
}

/// Check if character continues a number (decimal or exponent)
pub inline fn isNumberContinuation(c: u8) bool {
    return c == '.' or c == 'e' or c == 'E';
}

/// Parse a JSON number (integer or float)
pub fn parseNumber(data: []const u8, pos: usize) ParseError!ParsedNumber {
    if (pos >= data.len) return ParseError.UnexpectedEndOfInput;

    var i = pos;
    var is_negative = false;
    var has_decimal = false;
    var has_exponent = false;

    // Handle negative sign
    if (data[i] == '-') {
        is_negative = true;
        i += 1;
        if (i >= data.len) return ParseError.InvalidNumber;
    }

    // Fast path: simple positive integer
    if (!is_negative) {
        if (parsePositiveInt(data, i)) |result| {
            // Check if number ends here (no decimal or exponent)
            const next_pos = i + result.consumed;
            if (next_pos >= data.len or !isNumberContinuation(data[next_pos])) {
                return .{
                    .value = .{ .int = result.value },
                    .consumed = next_pos - pos,
                };
            }
        }
    }

    // Full number parsing (handles decimals and exponents)
    // Integer part
    if (data[i] == '0') {
        i += 1;
        // Leading zero - must be followed by decimal or end
        if (i < data.len and data[i] >= '0' and data[i] <= '9') {
            return ParseError.InvalidNumber;
        }
    } else {
        // Parse digits
        const digit_start = i;
        while (i < data.len and data[i] >= '0' and data[i] <= '9') : (i += 1) {}
        if (i == digit_start) return ParseError.InvalidNumber;
    }

    // Decimal part
    if (i < data.len and data[i] == '.') {
        has_decimal = true;
        i += 1;
        const decimal_start = i;
        while (i < data.len and data[i] >= '0' and data[i] <= '9') : (i += 1) {}
        if (i == decimal_start) return ParseError.InvalidNumber; // Must have digits after decimal
    }

    // Exponent part
    if (i < data.len and (data[i] == 'e' or data[i] == 'E')) {
        has_exponent = true;
        i += 1;
        if (i >= data.len) return ParseError.InvalidNumber;

        // Optional sign
        if (data[i] == '+' or data[i] == '-') {
            i += 1;
        }

        const exp_start = i;
        while (i < data.len and data[i] >= '0' and data[i] <= '9') : (i += 1) {}
        if (i == exp_start) return ParseError.InvalidNumber; // Must have digits in exponent
    }

    const num_str = data[pos..i];

    // Parse as integer if no decimal or exponent
    if (!has_decimal and !has_exponent) {
        const value = std.fmt.parseInt(i64, num_str, 10) catch return ParseError.NumberOutOfRange;
        return .{ .value = .{ .int = value }, .consumed = i - pos };
    }

    // Parse as float
    const value = std.fmt.parseFloat(f64, num_str) catch return ParseError.InvalidNumber;
    return .{ .value = .{ .float = value }, .consumed = i - pos };
}

// ============================================================================
// String Unescaping (optimized with lookup tables and bulk copy)
// ============================================================================

/// Comptime hex digit lookup table (like Rust serde_json)
/// Returns 0-15 for valid hex, 255 for invalid
const HEX_TABLE: [256]u8 = blk: {
    var table: [256]u8 = [_]u8{255} ** 256;
    for ('0'..'9' + 1) |c| table[c] = @intCast(c - '0');
    for ('a'..'f' + 1) |c| table[c] = @intCast(c - 'a' + 10);
    for ('A'..'F' + 1) |c| table[c] = @intCast(c - 'A' + 10);
    break :blk table;
};

/// Comptime escape character lookup table
const ESCAPE_CHARS: [256]u8 = blk: {
    var table: [256]u8 = [_]u8{0} ** 256;
    table['"'] = '"';
    table['\\'] = '\\';
    table['/'] = '/';
    table['b'] = '\x08';
    table['f'] = '\x0C';
    table['n'] = '\n';
    table['r'] = '\r';
    table['t'] = '\t';
    table['u'] = 'u'; // Special marker for unicode
    break :blk table;
};

/// Parse 4 hex digits to u16 using lookup table (no branching)
inline fn parseHex4(hex: *const [4]u8) ?u16 {
    const a = HEX_TABLE[hex[0]];
    const b = HEX_TABLE[hex[1]];
    const c = HEX_TABLE[hex[2]];
    const d = HEX_TABLE[hex[3]];
    // Single check: if any is 255, result will overflow
    if ((a | b | c | d) > 15) return null;
    return (@as(u16, a) << 12) | (@as(u16, b) << 8) | (@as(u16, c) << 4) | @as(u16, d);
}

/// Unescape a JSON string (handles \n, \t, \uXXXX, surrogate pairs)
/// Optimized with lookup tables and bulk copy.
/// Caller owns returned memory.
pub fn unescapeString(escaped: []const u8, allocator: std.mem.Allocator) ParseError![]const u8 {
    // Pre-allocate: result is at most same length as input (escapes shrink)
    var result = allocator.alloc(u8, escaped.len) catch return ParseError.OutOfMemory;
    errdefer allocator.free(result);

    var write_pos: usize = 0;
    var read_pos: usize = 0;

    while (read_pos < escaped.len) {
        // Find next backslash - scan for bulk copy
        const chunk_start = read_pos;
        while (read_pos < escaped.len and escaped[read_pos] != '\\') : (read_pos += 1) {}

        // Bulk copy non-escaped chunk
        const chunk_len = read_pos - chunk_start;
        if (chunk_len > 0) {
            @memcpy(result[write_pos..][0..chunk_len], escaped[chunk_start..][0..chunk_len]);
            write_pos += chunk_len;
        }

        // Handle escape sequence
        if (read_pos < escaped.len and escaped[read_pos] == '\\') {
            read_pos += 1;
            if (read_pos >= escaped.len) {
                allocator.free(result);
                return ParseError.InvalidEscape;
            }

            const c = escaped[read_pos];
            const replacement = ESCAPE_CHARS[c];

            if (replacement == 'u') {
                // Unicode escape: \uXXXX
                if (read_pos + 4 >= escaped.len) {
                    allocator.free(result);
                    return ParseError.InvalidUnicode;
                }
                const hex = escaped[read_pos + 1 ..][0..4];
                const codepoint = parseHex4(hex) orelse {
                    allocator.free(result);
                    return ParseError.InvalidUnicode;
                };

                // Handle surrogate pairs for characters > U+FFFF (emoji, etc.)
                if (codepoint >= 0xD800 and codepoint <= 0xDBFF) {
                    // High surrogate - expect low surrogate \uXXXX
                    if (read_pos + 10 >= escaped.len or escaped[read_pos + 5] != '\\' or escaped[read_pos + 6] != 'u') {
                        allocator.free(result);
                        return ParseError.InvalidUnicode;
                    }
                    const low_hex = escaped[read_pos + 7 ..][0..4];
                    const low_surrogate = parseHex4(low_hex) orelse {
                        allocator.free(result);
                        return ParseError.InvalidUnicode;
                    };
                    if (low_surrogate < 0xDC00 or low_surrogate > 0xDFFF) {
                        allocator.free(result);
                        return ParseError.InvalidUnicode;
                    }
                    // Decode surrogate pair to full codepoint
                    const full_codepoint: u21 = 0x10000 + (@as(u21, codepoint - 0xD800) << 10) + (low_surrogate - 0xDC00);
                    var utf8_buf: [4]u8 = undefined;
                    const utf8_len = std.unicode.utf8Encode(full_codepoint, &utf8_buf) catch {
                        allocator.free(result);
                        return ParseError.InvalidUnicode;
                    };
                    @memcpy(result[write_pos..][0..utf8_len], utf8_buf[0..utf8_len]);
                    write_pos += utf8_len;
                    read_pos += 11; // Skip uXXXX\uXXXX
                } else if (codepoint >= 0xDC00 and codepoint <= 0xDFFF) {
                    // Lone low surrogate is invalid
                    allocator.free(result);
                    return ParseError.InvalidUnicode;
                } else {
                    // Regular BMP character
                    var utf8_buf: [4]u8 = undefined;
                    const utf8_len = std.unicode.utf8Encode(@as(u21, codepoint), &utf8_buf) catch {
                        allocator.free(result);
                        return ParseError.InvalidUnicode;
                    };
                    @memcpy(result[write_pos..][0..utf8_len], utf8_buf[0..utf8_len]);
                    write_pos += utf8_len;
                    read_pos += 5; // Skip uXXXX
                }
            } else if (replacement != 0) {
                result[write_pos] = replacement;
                write_pos += 1;
                read_pos += 1;
            } else {
                allocator.free(result);
                return ParseError.InvalidEscape;
            }
        }
    }

    // Shrink to actual size
    if (write_pos < result.len) {
        result = allocator.realloc(result, write_pos) catch result[0..write_pos];
    }
    return result[0..write_pos];
}

/// Unescape a JSON string into a pre-allocated buffer (arena-friendly)
/// Optimized with lookup tables and bulk copy.
/// Returns the actual length used.
pub fn unescapeStringInto(escaped: []const u8, dest: []u8) ParseError!usize {
    var write_pos: usize = 0;
    var read_pos: usize = 0;

    while (read_pos < escaped.len) {
        // Find next backslash - scan for bulk copy
        const chunk_start = read_pos;
        while (read_pos < escaped.len and escaped[read_pos] != '\\') : (read_pos += 1) {}

        // Bulk copy non-escaped chunk
        const chunk_len = read_pos - chunk_start;
        if (chunk_len > 0) {
            if (write_pos + chunk_len > dest.len) return ParseError.OutOfMemory;
            @memcpy(dest[write_pos..][0..chunk_len], escaped[chunk_start..][0..chunk_len]);
            write_pos += chunk_len;
        }

        // Handle escape sequence
        if (read_pos < escaped.len and escaped[read_pos] == '\\') {
            read_pos += 1;
            if (read_pos >= escaped.len) return ParseError.InvalidEscape;

            const c = escaped[read_pos];
            const replacement = ESCAPE_CHARS[c];

            if (replacement == 'u') {
                // Unicode escape: \uXXXX
                if (read_pos + 4 >= escaped.len) return ParseError.InvalidUnicode;
                const hex = escaped[read_pos + 1 ..][0..4];
                const codepoint = parseHex4(hex) orelse return ParseError.InvalidUnicode;

                // Handle surrogate pairs
                if (codepoint >= 0xD800 and codepoint <= 0xDBFF) {
                    if (read_pos + 10 >= escaped.len or escaped[read_pos + 5] != '\\' or escaped[read_pos + 6] != 'u') {
                        return ParseError.InvalidUnicode;
                    }
                    const low_hex = escaped[read_pos + 7 ..][0..4];
                    const low_surrogate = parseHex4(low_hex) orelse return ParseError.InvalidUnicode;
                    if (low_surrogate < 0xDC00 or low_surrogate > 0xDFFF) {
                        return ParseError.InvalidUnicode;
                    }
                    const full_codepoint: u21 = 0x10000 + (@as(u21, codepoint - 0xD800) << 10) + (low_surrogate - 0xDC00);
                    if (write_pos + 4 > dest.len) return ParseError.OutOfMemory;
                    const utf8_len = std.unicode.utf8Encode(full_codepoint, dest[write_pos..][0..4]) catch return ParseError.InvalidUnicode;
                    write_pos += utf8_len;
                    read_pos += 11; // Skip uXXXX\uXXXX
                } else if (codepoint >= 0xDC00 and codepoint <= 0xDFFF) {
                    return ParseError.InvalidUnicode;
                } else {
                    if (write_pos + 4 > dest.len) return ParseError.OutOfMemory;
                    const utf8_len = std.unicode.utf8Encode(@as(u21, codepoint), dest[write_pos..][0..4]) catch return ParseError.InvalidUnicode;
                    write_pos += utf8_len;
                    read_pos += 5; // Skip uXXXX
                }
            } else if (replacement != 0) {
                if (write_pos >= dest.len) return ParseError.OutOfMemory;
                dest[write_pos] = replacement;
                write_pos += 1;
                read_pos += 1;
            } else {
                return ParseError.InvalidEscape;
            }
        }
    }

    return write_pos;
}

// ============================================================================
// Primitive Parsing (null, true, false)
// ============================================================================

/// Parse "null" literal, returns bytes consumed (4) or error
pub fn parseNull(data: []const u8, pos: usize) ParseError!usize {
    if (pos + 4 > data.len) return ParseError.UnexpectedEndOfInput;
    if (!std.mem.eql(u8, data[pos .. pos + 4], "null")) {
        return ParseError.UnexpectedToken;
    }
    return 4;
}

/// Parse "true" literal, returns bytes consumed (4) or error
pub fn parseTrue(data: []const u8, pos: usize) ParseError!usize {
    if (pos + 4 > data.len) return ParseError.UnexpectedEndOfInput;
    if (!std.mem.eql(u8, data[pos .. pos + 4], "true")) {
        return ParseError.UnexpectedToken;
    }
    return 4;
}

/// Parse "false" literal, returns bytes consumed (5) or error
pub fn parseFalse(data: []const u8, pos: usize) ParseError!usize {
    if (pos + 5 > data.len) return ParseError.UnexpectedEndOfInput;
    if (!std.mem.eql(u8, data[pos .. pos + 5], "false")) {
        return ParseError.UnexpectedToken;
    }
    return 5;
}

// ============================================================================
// String Escaping (for stringify)
// ============================================================================

/// Comptime lookup table for escape detection
pub const NEEDS_ESCAPE: [256]bool = blk: {
    var table: [256]bool = [_]bool{false} ** 256;
    table['"'] = true;
    table['\\'] = true;
    table['\x08'] = true;
    table['\x0C'] = true;
    table['\n'] = true;
    table['\r'] = true;
    table['\t'] = true;
    // Control characters 0x00-0x1F
    var i: u8 = 0;
    while (i <= 0x1F) : (i += 1) {
        table[i] = true;
    }
    break :blk table;
};

/// Comptime lookup table for escape sequences
pub const ESCAPE_SEQUENCES: [256][]const u8 = blk: {
    var table: [256][]const u8 = [_][]const u8{""} ** 256;
    table['"'] = "\\\"";
    table['\\'] = "\\\\";
    table['\x08'] = "\\b";
    table['\x0C'] = "\\f";
    table['\n'] = "\\n";
    table['\r'] = "\\r";
    table['\t'] = "\\t";
    break :blk table;
};

// ============================================================================
// Tests
// ============================================================================

test "parseNumber: positive integer" {
    const result = try parseNumber("42", 0);
    try std.testing.expectEqual(@as(i64, 42), result.value.int);
    try std.testing.expectEqual(@as(usize, 2), result.consumed);
}

test "parseNumber: negative integer" {
    const result = try parseNumber("-123", 0);
    try std.testing.expectEqual(@as(i64, -123), result.value.int);
    try std.testing.expectEqual(@as(usize, 4), result.consumed);
}

test "parseNumber: float" {
    const result = try parseNumber("3.14159", 0);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14159), result.value.float, 0.00001);
}

test "parseNumber: scientific notation" {
    const result = try parseNumber("1.5e10", 0);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5e10), result.value.float, 1.0);
}

test "unescapeString: basic escapes" {
    const allocator = std.testing.allocator;
    const result = try unescapeString("hello\\nworld", allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello\nworld", result);
}

test "unescapeString: unicode escape" {
    const allocator = std.testing.allocator;
    const result = try unescapeString("\\u0048\\u0065\\u006c\\u006c\\u006f", allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello", result);
}

test "parseNull" {
    try std.testing.expectEqual(@as(usize, 4), try parseNull("null", 0));
}

test "parseTrue" {
    try std.testing.expectEqual(@as(usize, 4), try parseTrue("true", 0));
}

test "parseFalse" {
    try std.testing.expectEqual(@as(usize, 5), try parseFalse("false", 0));
}
