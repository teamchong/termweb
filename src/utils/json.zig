/// Centralized JSON string escaping utilities.
/// All JSON string building should use these functions to properly escape
/// special characters (newlines, quotes, backslashes, control chars).
const std = @import("std");

/// Escape string for JSON, returns slice WITH surrounding quotes.
/// Use this when building JSON with format strings.
/// Example: `std.fmt.bufPrint(&buf, "{\"text\":{s}}", .{json.escapeString(input, &escape_buf)});`
pub fn escapeString(input: []const u8, buf: []u8) ![]const u8 {
    var i: usize = 0;
    if (i >= buf.len) return error.OutOfMemory;
    buf[i] = '"';
    i += 1;

    for (input) |c| {
        switch (c) {
            '"' => {
                if (i + 2 > buf.len) return error.OutOfMemory;
                buf[i] = '\\';
                buf[i + 1] = '"';
                i += 2;
            },
            '\\' => {
                if (i + 2 > buf.len) return error.OutOfMemory;
                buf[i] = '\\';
                buf[i + 1] = '\\';
                i += 2;
            },
            '\n' => {
                if (i + 2 > buf.len) return error.OutOfMemory;
                buf[i] = '\\';
                buf[i + 1] = 'n';
                i += 2;
            },
            '\r' => {
                if (i + 2 > buf.len) return error.OutOfMemory;
                buf[i] = '\\';
                buf[i + 1] = 'r';
                i += 2;
            },
            '\t' => {
                if (i + 2 > buf.len) return error.OutOfMemory;
                buf[i] = '\\';
                buf[i + 1] = 't';
                i += 2;
            },
            else => {
                if (c < 0x20) {
                    // Control character - escape as \uXXXX
                    if (i + 6 > buf.len) return error.OutOfMemory;
                    buf[i] = '\\';
                    buf[i + 1] = 'u';
                    buf[i + 2] = '0';
                    buf[i + 3] = '0';
                    buf[i + 4] = hexDigit(@truncate(c >> 4));
                    buf[i + 5] = hexDigit(@truncate(c & 0xf));
                    i += 6;
                } else {
                    if (i >= buf.len) return error.OutOfMemory;
                    buf[i] = c;
                    i += 1;
                }
            },
        }
    }

    if (i >= buf.len) return error.OutOfMemory;
    buf[i] = '"';
    i += 1;

    return buf[0..i];
}

/// Escape string for JSON using allocator, returns WITH quotes.
/// Caller owns returned memory.
pub fn escapeStringAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    // Worst case: every char needs \uXXXX (6 chars) + 2 quotes
    const max_size = input.len * 6 + 2;
    var buf = try allocator.alloc(u8, max_size);
    errdefer allocator.free(buf);

    const result = try escapeString(input, buf);
    // Shrink to actual size
    if (result.len < buf.len) {
        if (allocator.resize(buf, result.len)) |resized| {
            return resized;
        }
    }
    return buf[0..result.len];
}

/// Escape string WITHOUT surrounding quotes (for embedding in templates).
/// Use when you already have quotes in your format string.
/// Example: `std.fmt.bufPrint(&buf, "{{\"text\":\"{s}\"}}", .{json.escapeContents(input, &escape_buf)});`
pub fn escapeContents(input: []const u8, buf: []u8) ![]const u8 {
    var i: usize = 0;

    for (input) |c| {
        switch (c) {
            '"' => {
                if (i + 2 > buf.len) return error.OutOfMemory;
                buf[i] = '\\';
                buf[i + 1] = '"';
                i += 2;
            },
            '\\' => {
                if (i + 2 > buf.len) return error.OutOfMemory;
                buf[i] = '\\';
                buf[i + 1] = '\\';
                i += 2;
            },
            '\n' => {
                if (i + 2 > buf.len) return error.OutOfMemory;
                buf[i] = '\\';
                buf[i + 1] = 'n';
                i += 2;
            },
            '\r' => {
                if (i + 2 > buf.len) return error.OutOfMemory;
                buf[i] = '\\';
                buf[i + 1] = 'r';
                i += 2;
            },
            '\t' => {
                if (i + 2 > buf.len) return error.OutOfMemory;
                buf[i] = '\\';
                buf[i + 1] = 't';
                i += 2;
            },
            else => {
                if (c < 0x20) {
                    // Control character - escape as \uXXXX
                    if (i + 6 > buf.len) return error.OutOfMemory;
                    buf[i] = '\\';
                    buf[i + 1] = 'u';
                    buf[i + 2] = '0';
                    buf[i + 3] = '0';
                    buf[i + 4] = hexDigit(@truncate(c >> 4));
                    buf[i + 5] = hexDigit(@truncate(c & 0xf));
                    i += 6;
                } else {
                    if (i >= buf.len) return error.OutOfMemory;
                    buf[i] = c;
                    i += 1;
                }
            },
        }
    }

    return buf[0..i];
}

fn hexDigit(n: u4) u8 {
    const v: u8 = n;
    return if (v < 10) '0' + v else 'a' + v - 10;
}

test "escapeString basic" {
    var buf: [256]u8 = undefined;
    const result = try escapeString("hello", &buf);
    try std.testing.expectEqualStrings("\"hello\"", result);
}

test "escapeString with quotes" {
    var buf: [256]u8 = undefined;
    const result = try escapeString("say \"hello\"", &buf);
    try std.testing.expectEqualStrings("\"say \\\"hello\\\"\"", result);
}

test "escapeString with newlines" {
    var buf: [256]u8 = undefined;
    const result = try escapeString("line1\nline2", &buf);
    try std.testing.expectEqualStrings("\"line1\\nline2\"", result);
}

test "escapeString with backslash" {
    var buf: [256]u8 = undefined;
    const result = try escapeString("path\\to\\file", &buf);
    try std.testing.expectEqualStrings("\"path\\\\to\\\\file\"", result);
}

test "escapeContents basic" {
    var buf: [256]u8 = undefined;
    const result = try escapeContents("hello\nworld", &buf);
    try std.testing.expectEqualStrings("hello\\nworld", result);
}
