//! JSON Parser - shared library implementation
//! SIMD-accelerated parsing with scalar fallback for portability
//!
//! Based on packages/runtime/src/json/parse.zig but without PyObject dependencies.

const std = @import("std");
const hashmap_helper = @import("utils.hashmap_helper");
const Value = @import("value.zig").Value;
const simd = @import("json_simd");
const primitives = @import("primitives.zig");

// Use SIMD-accelerated whitespace skipping
fn skipWhitespace(data: []const u8, offset: usize) usize {
    return simd.skipWhitespace(data, offset);
}

// Re-export ParseError from primitives for compatibility
pub const ParseError = primitives.ParseError;

/// Result of a parse operation
const ParseResult = struct {
    value: Value,
    consumed: usize,

    fn init(val: Value, bytes: usize) ParseResult {
        return .{ .value = val, .consumed = bytes };
    }
};

/// Parse JSON string into Value
pub fn parse(allocator: std.mem.Allocator, input: []const u8) ParseError!Value {
    const i = skipWhitespace(input, 0);
    if (i >= input.len) return ParseError.UnexpectedEndOfInput;

    const result = try parseValue(input, i, allocator);

    // Check for trailing content
    const final_pos = skipWhitespace(input, i + result.consumed);
    if (final_pos < input.len) {
        var val = result.value;
        val.deinit(allocator);
        return ParseError.TrailingData;
    }

    return result.value;
}

/// Parse any JSON value based on first non-whitespace character
fn parseValue(data: []const u8, pos: usize, allocator: std.mem.Allocator) ParseError!ParseResult {
    const i = skipWhitespace(data, pos);
    if (i >= data.len) return ParseError.UnexpectedEndOfInput;

    const c = data[i];
    return switch (c) {
        '{' => try parseObject(data, i, allocator),
        '[' => try parseArray(data, i, allocator),
        '"' => try parseString(data, i, allocator),
        '-', '0'...'9' => try parseNumber(data, i),
        'n', 't', 'f' => try parsePrimitive(data, i),
        else => ParseError.UnexpectedToken,
    };
}

// ============================================================================
// Primitive parsing (null, true, false) - delegates to shared primitives
// ============================================================================

fn parsePrimitive(data: []const u8, pos: usize) ParseError!ParseResult {
    if (pos >= data.len) return ParseError.UnexpectedEndOfInput;

    const c = data[pos];
    return switch (c) {
        'n' => {
            const consumed = try primitives.parseNull(data, pos);
            return ParseResult.init(.null_value, consumed);
        },
        't' => {
            const consumed = try primitives.parseTrue(data, pos);
            return ParseResult.init(.{ .bool_value = true }, consumed);
        },
        'f' => {
            const consumed = try primitives.parseFalse(data, pos);
            return ParseResult.init(.{ .bool_value = false }, consumed);
        },
        else => ParseError.UnexpectedToken,
    };
}

// ============================================================================
// Number parsing - delegates to shared primitives
// ============================================================================

fn parseNumber(data: []const u8, pos: usize) ParseError!ParseResult {
    const result = try primitives.parseNumber(data, pos);
    return switch (result.value) {
        .int => |v| ParseResult.init(.{ .number_int = v }, result.consumed),
        .float => |v| ParseResult.init(.{ .number_float = v }, result.consumed),
    };
}

// ============================================================================
// String parsing (with escape handling)
// ============================================================================

fn parseString(data: []const u8, pos: usize, allocator: std.mem.Allocator) ParseError!ParseResult {
    if (pos >= data.len or data[pos] != '"') return ParseError.UnexpectedToken;

    const start = pos + 1; // Skip opening quote

    // Use SIMD to find closing quote AND check for escapes in single pass
    if (simd.findClosingQuoteAndEscapes(data[start..])) |result| {
        const i = start + result.quote_pos;

        if (!result.has_escapes) {
            // Fast path: No escapes, just copy
            const str = allocator.dupe(u8, data[start..i]) catch return ParseError.OutOfMemory;
            return ParseResult.init(
                .{ .string = str },
                i + 1 - pos,
            );
        } else {
            // Slow path: Need to unescape - use shared primitives
            const unescaped = try primitives.unescapeString(data[start..i], allocator);
            return ParseResult.init(
                .{ .string = unescaped },
                i + 1 - pos,
            );
        }
    }

    return ParseError.UnterminatedString;
}

// ============================================================================
// Array parsing
// ============================================================================

fn parseArray(data: []const u8, pos: usize, allocator: std.mem.Allocator) ParseError!ParseResult {
    if (pos >= data.len or data[pos] != '[') return ParseError.UnexpectedToken;

    var array = std.ArrayList(Value){};
    var cleanup_needed = true;
    defer if (cleanup_needed) {
        for (array.items) |*item| {
            item.deinit(allocator);
        }
        array.deinit(allocator);
    };

    var i = skipWhitespace(data, pos + 1);

    // Check for empty array
    if (i < data.len and data[i] == ']') {
        cleanup_needed = false;
        return ParseResult.init(
            .{ .array = array },
            i + 1 - pos,
        );
    }

    // Parse elements
    while (true) {
        // Parse value
        const value_result = try parseValue(data, i, allocator);
        array.append(allocator, value_result.value) catch {
            var val = value_result.value;
            val.deinit(allocator);
            return ParseError.OutOfMemory;
        };
        i += value_result.consumed;

        // Skip whitespace
        i = skipWhitespace(data, i);
        if (i >= data.len) return ParseError.UnexpectedEndOfInput;

        const c = data[i];
        if (c == ']') {
            // End of array - success, don't cleanup
            cleanup_needed = false;
            return ParseResult.init(
                .{ .array = array },
                i + 1 - pos,
            );
        } else if (c == ',') {
            // More elements
            i = skipWhitespace(data, i + 1);

            // Check for trailing comma
            if (i < data.len and data[i] == ']') {
                return ParseError.TrailingComma;
            }
        } else {
            return ParseError.UnexpectedToken;
        }
    }
}

// ============================================================================
// Object parsing
// ============================================================================

fn parseObject(data: []const u8, pos: usize, allocator: std.mem.Allocator) ParseError!ParseResult {
    if (pos >= data.len or data[pos] != '{') return ParseError.UnexpectedToken;

    var object = hashmap_helper.StringHashMap(Value).init(allocator);
    var cleanup_needed = true;
    defer if (cleanup_needed) {
        var it = object.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        object.deinit();
    };

    var i = skipWhitespace(data, pos + 1);

    // Check for empty object
    if (i < data.len and data[i] == '}') {
        cleanup_needed = false;
        return ParseResult.init(
            .{ .object = object },
            i + 1 - pos,
        );
    }

    // Parse key-value pairs
    while (true) {
        // Parse key (must be string)
        if (i >= data.len or data[i] != '"') return ParseError.UnexpectedToken;

        const key_result = try parseString(data, i, allocator);
        const key = key_result.value.string;
        i += key_result.consumed;

        // Skip whitespace and expect colon
        i = skipWhitespace(data, i);
        if (i >= data.len or data[i] != ':') {
            allocator.free(key);
            return ParseError.UnexpectedToken;
        }
        i = skipWhitespace(data, i + 1);

        // Parse value
        const value_result = parseValue(data, i, allocator) catch |err| {
            allocator.free(key);
            return err;
        };
        i += value_result.consumed;

        // Check for duplicate key
        if (object.contains(key)) {
            allocator.free(key);
            var val = value_result.value;
            val.deinit(allocator);
            return ParseError.DuplicateKey;
        }

        // Insert into object
        object.put(key, value_result.value) catch {
            allocator.free(key);
            var val = value_result.value;
            val.deinit(allocator);
            return ParseError.OutOfMemory;
        };

        // Skip whitespace
        i = skipWhitespace(data, i);
        if (i >= data.len) return ParseError.UnexpectedEndOfInput;

        const c = data[i];
        if (c == '}') {
            // End of object - success, don't cleanup
            cleanup_needed = false;
            return ParseResult.init(
                .{ .object = object },
                i + 1 - pos,
            );
        } else if (c == ',') {
            // More pairs
            i = skipWhitespace(data, i + 1);

            // Check for trailing comma
            if (i < data.len and data[i] == '}') {
                return ParseError.TrailingComma;
            }
        } else {
            return ParseError.UnexpectedToken;
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "parse null" {
    const allocator = std.testing.allocator;
    var value = try parse(allocator, "null");
    defer value.deinit(allocator);
    try std.testing.expect(value == .null_value);
}

test "parse boolean" {
    const allocator = std.testing.allocator;

    var t = try parse(allocator, "true");
    defer t.deinit(allocator);
    try std.testing.expect(t.bool_value == true);

    var f = try parse(allocator, "false");
    defer f.deinit(allocator);
    try std.testing.expect(f.bool_value == false);
}

test "parse number" {
    const allocator = std.testing.allocator;

    var int_val = try parse(allocator, "42");
    defer int_val.deinit(allocator);
    try std.testing.expectEqual(@as(i64, 42), int_val.number_int);

    var neg_val = try parse(allocator, "-123");
    defer neg_val.deinit(allocator);
    try std.testing.expectEqual(@as(i64, -123), neg_val.number_int);

    var float_val = try parse(allocator, "3.14");
    defer float_val.deinit(allocator);
    try std.testing.expectApproxEqRel(@as(f64, 3.14), float_val.number_float, 0.0001);

    var exp_val = try parse(allocator, "1.5e10");
    defer exp_val.deinit(allocator);
    try std.testing.expectApproxEqRel(@as(f64, 1.5e10), exp_val.number_float, 0.0001);
}

test "parse string" {
    const allocator = std.testing.allocator;

    var value = try parse(allocator, "\"hello\"");
    defer value.deinit(allocator);
    try std.testing.expectEqualStrings("hello", value.string);
}

test "parse string with escapes" {
    const allocator = std.testing.allocator;

    var value = try parse(allocator, "\"hello\\nworld\"");
    defer value.deinit(allocator);
    try std.testing.expectEqualStrings("hello\nworld", value.string);
}

test "parse string with unicode" {
    const allocator = std.testing.allocator;

    var value = try parse(allocator, "\"\\u0048\\u0065\\u006C\\u006C\\u006F\"");
    defer value.deinit(allocator);
    try std.testing.expectEqualStrings("Hello", value.string);
}

test "parse empty array" {
    const allocator = std.testing.allocator;
    var value = try parse(allocator, "[]");
    defer value.deinit(allocator);

    try std.testing.expect(value == .array);
    try std.testing.expectEqual(@as(usize, 0), value.array.items.len);
}

test "parse array with numbers" {
    const allocator = std.testing.allocator;
    var value = try parse(allocator, "[1, 2, 3]");
    defer value.deinit(allocator);

    try std.testing.expect(value == .array);
    try std.testing.expectEqual(@as(usize, 3), value.array.items.len);
    try std.testing.expectEqual(@as(i64, 1), value.array.items[0].number_int);
    try std.testing.expectEqual(@as(i64, 2), value.array.items[1].number_int);
    try std.testing.expectEqual(@as(i64, 3), value.array.items[2].number_int);
}

test "parse empty object" {
    const allocator = std.testing.allocator;
    var value = try parse(allocator, "{}");
    defer value.deinit(allocator);

    try std.testing.expect(value == .object);
    try std.testing.expectEqual(@as(usize, 0), value.object.count());
}

test "parse object with values" {
    const allocator = std.testing.allocator;
    var value = try parse(allocator, "{\"name\": \"metal0\", \"count\": 3}");
    defer value.deinit(allocator);

    try std.testing.expect(value == .object);
    try std.testing.expectEqual(@as(usize, 2), value.object.count());

    const name = value.object.get("name").?;
    try std.testing.expectEqualStrings("metal0", name.string);

    const count = value.object.get("count").?;
    try std.testing.expectEqual(@as(i64, 3), count.number_int);
}

test "parse nested structure" {
    const allocator = std.testing.allocator;
    var value = try parse(allocator, "{\"items\": [1, 2], \"meta\": {\"count\": 2}}");
    defer value.deinit(allocator);

    try std.testing.expect(value == .object);

    const items = value.object.get("items").?;
    try std.testing.expectEqual(@as(usize, 2), items.array.items.len);

    const meta = value.object.get("meta").?;
    const count = meta.object.get("count").?;
    try std.testing.expectEqual(@as(i64, 2), count.number_int);
}

test "parse with whitespace" {
    const allocator = std.testing.allocator;
    var value = try parse(allocator, "  { \"key\" : \"value\" }  ");
    defer value.deinit(allocator);

    try std.testing.expect(value == .object);
    const v = value.object.get("key").?;
    try std.testing.expectEqualStrings("value", v.string);
}

test "parse trailing data error" {
    const allocator = std.testing.allocator;
    const result = parse(allocator, "null extra");
    try std.testing.expectError(ParseError.TrailingData, result);
}

test "parse trailing comma error" {
    const allocator = std.testing.allocator;

    const arr_result = parse(allocator, "[1, 2,]");
    try std.testing.expectError(ParseError.TrailingComma, arr_result);

    const obj_result = parse(allocator, "{\"a\": 1,}");
    try std.testing.expectError(ParseError.TrailingComma, obj_result);
}
