//! JSON Stringify - serialization with comptime lookup tables
//!
//! Usage:
//!   const json = @import("json");
//!   var output = try json.stringify(allocator, value);
//!   defer allocator.free(output);

const std = @import("std");
const hashmap_helper = @import("utils.hashmap_helper");
const Value = @import("value.zig").Value;

pub const StringifyError = error{
    OutOfMemory,
};

/// Comptime string constants - avoids strlen at runtime
const JSON_NULL = "null";
const JSON_TRUE = "true";
const JSON_FALSE = "false";

/// Comptime lookup table for escape detection (much faster than switch!)
const NEEDS_ESCAPE: [256]bool = blk: {
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

/// Comptime lookup table for escape sequences (eliminates switch!)
const ESCAPE_SEQUENCES: [256][]const u8 = blk: {
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

/// Stringify Value to JSON string (caller owns returned memory)
pub fn stringify(allocator: std.mem.Allocator, value: Value) StringifyError![]u8 {
    // Start with 64KB buffer - matches typical JSON output size, eliminates growth
    var buffer = std.ArrayList(u8).initCapacity(allocator, 65536) catch {
        // Fallback to smaller buffer if 64KB fails
        var small_buffer = std.ArrayList(u8){};
        stringifyValue(value, &small_buffer, allocator) catch |err| {
            small_buffer.deinit(allocator);
            return err;
        };
        return small_buffer.toOwnedSlice(allocator) catch |err| {
            small_buffer.deinit(allocator);
            return err;
        };
    };

    stringifyValue(value, &buffer, allocator) catch |err| {
        buffer.deinit(allocator);
        return err;
    };

    return buffer.toOwnedSlice(allocator) catch |err| {
        buffer.deinit(allocator);
        return err;
    };
}

/// Direct stringify - writes to ArrayList without writer() overhead
fn stringifyValue(value: Value, buffer: *std.ArrayList(u8), allocator: std.mem.Allocator) StringifyError!void {
    switch (value) {
        .null_value => try buffer.appendSlice(allocator, JSON_NULL),
        .bool_value => |b| {
            try buffer.appendSlice(allocator, if (b) JSON_TRUE else JSON_FALSE);
        },
        .number_int => |n| {
            var buf: [32]u8 = undefined;
            const formatted = std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable;
            try buffer.appendSlice(allocator, formatted);
        },
        .number_float => |f| {
            // Handle special float values
            if (std.math.isNan(f) or std.math.isInf(f)) {
                try buffer.appendSlice(allocator, JSON_NULL);
            } else {
                var buf: [32]u8 = undefined;
                const formatted = std.fmt.bufPrint(&buf, "{d}", .{f}) catch unreachable;
                try buffer.appendSlice(allocator, formatted);
            }
        },
        .string => |s| {
            try buffer.append(allocator, '"');
            try writeEscapedStringDirect(s, buffer, allocator);
            try buffer.append(allocator, '"');
        },
        .array => |arr| {
            try buffer.append(allocator, '[');
            if (arr.items.len > 0) {
                try stringifyValue(arr.items[0], buffer, allocator);
                for (arr.items[1..]) |item| {
                    try buffer.append(allocator, ',');
                    try stringifyValue(item, buffer, allocator);
                }
            }
            try buffer.append(allocator, ']');
        },
        .object => |obj| {
            try buffer.append(allocator, '{');

            // Fast path: process first entry without comma check
            var it = obj.iterator();
            if (it.next()) |entry| {
                try buffer.appendSlice(allocator, "\"");
                try writeEscapedStringDirect(entry.key_ptr.*, buffer, allocator);
                try buffer.appendSlice(allocator, "\":");
                try stringifyValue(entry.value_ptr.*, buffer, allocator);

                // Rest of entries always have comma
                while (it.next()) |next_entry| {
                    try buffer.appendSlice(allocator, ",\"");
                    try writeEscapedStringDirect(next_entry.key_ptr.*, buffer, allocator);
                    try buffer.appendSlice(allocator, "\":");
                    try stringifyValue(next_entry.value_ptr.*, buffer, allocator);
                }
            }

            try buffer.append(allocator, '}');
        },
    }
}

/// Write escaped string directly to ArrayList with SIMD acceleration
inline fn writeEscapedStringDirect(str: []const u8, buffer: *std.ArrayList(u8), allocator: std.mem.Allocator) StringifyError!void {
    var start: usize = 0;
    var i: usize = 0;

    // SIMD fast path: check 16 bytes at once using vectors
    const Vec16 = @Vector(16, u8);
    const threshold: Vec16 = @splat(32); // Control chars (0-31) need escaping
    const quote: Vec16 = @splat('"');
    const backslash: Vec16 = @splat('\\');

    while (i + 16 <= str.len) {
        const chunk: Vec16 = str[i..][0..16].*;

        // Check for control chars, quotes, backslashes in one SIMD op
        const has_control = chunk < threshold;
        const has_quote = chunk == quote;
        const has_backslash = chunk == backslash;
        const needs_escape_vec = has_control | has_quote | has_backslash;

        // If any bit set, at least one char needs escaping
        if (@reduce(.Or, needs_escape_vec)) {
            // Fall back to scalar for this chunk
            const end = @min(i + 16, str.len);
            while (i < end) : (i += 1) {
                const c = str[i];
                if (NEEDS_ESCAPE[c]) {
                    if (start < i) {
                        try buffer.appendSlice(allocator, str[start..i]);
                    }
                    const escape_seq = ESCAPE_SEQUENCES[c];
                    if (escape_seq.len > 0) {
                        try buffer.appendSlice(allocator, escape_seq);
                    } else {
                        var buf: [6]u8 = undefined;
                        const formatted = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable;
                        try buffer.appendSlice(allocator, formatted);
                    }
                    start = i + 1;
                }
            }
        } else {
            // Fast path: no escapes needed, skip 16 bytes
            i += 16;
        }
    }

    // Handle remaining bytes (< 16)
    while (i < str.len) : (i += 1) {
        const c = str[i];
        if (NEEDS_ESCAPE[c]) {
            if (start < i) {
                try buffer.appendSlice(allocator, str[start..i]);
            }
            const escape_seq = ESCAPE_SEQUENCES[c];
            if (escape_seq.len > 0) {
                try buffer.appendSlice(allocator, escape_seq);
            } else {
                var buf: [6]u8 = undefined;
                const formatted = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable;
                try buffer.appendSlice(allocator, formatted);
            }
            start = i + 1;
        }
    }

    if (start < str.len) {
        try buffer.appendSlice(allocator, str[start..]);
    }
}

// =============================================================================
// Tests
// =============================================================================

test "stringify null" {
    const allocator = std.testing.allocator;
    const result = try stringify(allocator, .null_value);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("null", result);
}

test "stringify bool true" {
    const allocator = std.testing.allocator;
    const result = try stringify(allocator, .{ .bool_value = true });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("true", result);
}

test "stringify bool false" {
    const allocator = std.testing.allocator;
    const result = try stringify(allocator, .{ .bool_value = false });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("false", result);
}

test "stringify integer" {
    const allocator = std.testing.allocator;
    const result = try stringify(allocator, .{ .number_int = 42 });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("42", result);
}

test "stringify negative integer" {
    const allocator = std.testing.allocator;
    const result = try stringify(allocator, .{ .number_int = -123 });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("-123", result);
}

test "stringify float" {
    const allocator = std.testing.allocator;
    const result = try stringify(allocator, .{ .number_float = 3.14 });
    defer allocator.free(result);
    // Float formatting may vary, just check it contains the expected digits
    try std.testing.expect(std.mem.indexOf(u8, result, "3.14") != null);
}

test "stringify simple string" {
    const allocator = std.testing.allocator;
    const result = try stringify(allocator, .{ .string = "hello" });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("\"hello\"", result);
}

test "stringify string with escapes" {
    const allocator = std.testing.allocator;
    const result = try stringify(allocator, .{ .string = "hello\nworld" });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("\"hello\\nworld\"", result);
}

test "stringify string with quotes" {
    const allocator = std.testing.allocator;
    const result = try stringify(allocator, .{ .string = "say \"hi\"" });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("\"say \\\"hi\\\"\"", result);
}

test "stringify empty array" {
    const allocator = std.testing.allocator;
    var arr = std.ArrayList(Value){};
    defer arr.deinit(allocator);
    const result = try stringify(allocator, .{ .array = arr });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("[]", result);
}

test "stringify array with values" {
    const allocator = std.testing.allocator;
    var arr = std.ArrayList(Value){};
    defer arr.deinit(allocator);
    try arr.append(allocator, .{ .number_int = 1 });
    try arr.append(allocator, .{ .number_int = 2 });
    try arr.append(allocator, .{ .number_int = 3 });
    const result = try stringify(allocator, .{ .array = arr });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("[1,2,3]", result);
}

test "stringify empty object" {
    const allocator = std.testing.allocator;
    var obj = hashmap_helper.StringHashMap(Value).init(allocator);
    defer obj.deinit();
    const result = try stringify(allocator, .{ .object = obj });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("{}", result);
}

test "stringify object with values" {
    const allocator = std.testing.allocator;
    var obj = hashmap_helper.StringHashMap(Value).init(allocator);
    defer obj.deinit();
    try obj.put("name", .{ .string = "metal0" });
    const result = try stringify(allocator, .{ .object = obj });
    defer allocator.free(result);
    // Object order may vary, check contains expected parts
    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"metal0\"") != null);
}

test "stringify nested structure" {
    const allocator = std.testing.allocator;

    // Create nested array
    var inner_arr = std.ArrayList(Value){};
    defer inner_arr.deinit(allocator);
    try inner_arr.append(allocator, .{ .number_int = 1 });
    try inner_arr.append(allocator, .{ .number_int = 2 });

    // Create outer object
    var obj = hashmap_helper.StringHashMap(Value).init(allocator);
    defer obj.deinit();
    try obj.put("nums", .{ .array = inner_arr });
    try obj.put("active", .{ .bool_value = true });

    const result = try stringify(allocator, .{ .object = obj });
    defer allocator.free(result);

    // Check structure (order may vary)
    try std.testing.expect(std.mem.indexOf(u8, result, "[1,2]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "true") != null);
}

test "stringify NaN becomes null" {
    const allocator = std.testing.allocator;
    const result = try stringify(allocator, .{ .number_float = std.math.nan(f64) });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("null", result);
}

test "stringify Infinity becomes null" {
    const allocator = std.testing.allocator;
    const result = try stringify(allocator, .{ .number_float = std.math.inf(f64) });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("null", result);
}
