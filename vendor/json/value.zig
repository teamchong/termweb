//! JSON Value type - generic, no PyObject dependencies
//! This is the shared representation used by all JSON operations in metal0.

const std = @import("std");
const hashmap_helper = @import("utils.hashmap_helper");

/// Generic JSON value representation
/// Used as intermediate format for parsing and stringify operations
pub const Value = union(enum) {
    null_value,
    bool_value: bool,
    number_int: i64,
    number_float: f64,
    string: []const u8,
    array: std.ArrayList(Value),
    object: hashmap_helper.StringHashMap(Value),

    /// Free all resources held by this Value
    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |s| {
                allocator.free(s);
            },
            .array => |*arr| {
                for (arr.items) |*item| {
                    item.deinit(allocator);
                }
                arr.deinit(allocator);
            },
            .object => |*obj| {
                var it = obj.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                obj.deinit();
            },
            else => {},
        }
    }

    /// Shallow deinit - only free containers, not contents
    /// Use when contents have been transferred elsewhere
    pub fn shallowDeinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .array => |*arr| arr.deinit(allocator),
            .object => |*obj| obj.deinit(),
            else => {},
        }
    }

    /// Create a deep copy of this Value
    pub fn clone(self: *const Value, allocator: std.mem.Allocator) !Value {
        return switch (self.*) {
            .null_value => .null_value,
            .bool_value => |b| .{ .bool_value = b },
            .number_int => |n| .{ .number_int = n },
            .number_float => |f| .{ .number_float = f },
            .string => |s| .{ .string = try allocator.dupe(u8, s) },
            .array => |arr| blk: {
                var new_arr = std.ArrayList(Value){};
                errdefer {
                    for (new_arr.items) |*item| item.deinit(allocator);
                    new_arr.deinit(allocator);
                }
                try new_arr.ensureTotalCapacity(allocator, arr.items.len);
                for (arr.items) |*item| {
                    new_arr.appendAssumeCapacity(try item.clone(allocator));
                }
                break :blk .{ .array = new_arr };
            },
            .object => |obj| blk: {
                var new_obj = hashmap_helper.StringHashMap(Value).init(allocator);
                errdefer {
                    var it = new_obj.iterator();
                    while (it.next()) |entry| {
                        allocator.free(entry.key_ptr.*);
                        entry.value_ptr.deinit(allocator);
                    }
                    new_obj.deinit();
                }
                var it = obj.iterator();
                while (it.next()) |entry| {
                    const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
                    errdefer allocator.free(key_copy);
                    const val_copy = try entry.value_ptr.clone(allocator);
                    try new_obj.put(key_copy, val_copy);
                }
                break :blk .{ .object = new_obj };
            },
        };
    }
};

/// Check if character is JSON whitespace
pub inline fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Skip whitespace and return new position
pub fn skipWhitespace(data: []const u8, pos: usize) usize {
    var i = pos;
    while (i < data.len and isWhitespace(data[i])) : (i += 1) {}
    return i;
}

/// Check if we've reached end of input
pub inline fn isEof(data: []const u8, pos: usize) bool {
    return pos >= data.len;
}

/// Peek at current character without consuming
pub inline fn peek(data: []const u8, pos: usize) ?u8 {
    if (pos >= data.len) return null;
    return data[pos];
}

/// Consume current character and advance
pub inline fn consume(data: []const u8, pos: usize) struct { char: u8, next_pos: usize } {
    std.debug.assert(pos < data.len);
    return .{ .char = data[pos], .next_pos = pos + 1 };
}

/// Expect a specific character at current position
pub fn expect(data: []const u8, pos: usize, expected: u8) bool {
    if (pos >= data.len) return false;
    return data[pos] == expected;
}

test "Value.deinit" {
    const allocator = std.testing.allocator;

    // Test string deinit
    var str_val = Value{ .string = try allocator.dupe(u8, "hello") };
    str_val.deinit(allocator);

    // Test array deinit
    var arr = std.ArrayList(Value){};
    try arr.append(allocator, Value{ .number_int = 42 });
    try arr.append(allocator, Value{ .string = try allocator.dupe(u8, "test") });
    var arr_val = Value{ .array = arr };
    arr_val.deinit(allocator);

    // Test object deinit
    var obj = hashmap_helper.StringHashMap(Value).init(allocator);
    try obj.put(try allocator.dupe(u8, "key"), Value{ .bool_value = true });
    var obj_val = Value{ .object = obj };
    obj_val.deinit(allocator);
}

test "Value.clone" {
    const allocator = std.testing.allocator;

    // Test cloning string
    var original = Value{ .string = try allocator.dupe(u8, "hello") };
    defer original.deinit(allocator);
    var cloned = try original.clone(allocator);
    defer cloned.deinit(allocator);

    try std.testing.expectEqualStrings("hello", cloned.string);
}
