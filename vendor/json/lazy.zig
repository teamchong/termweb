//! Lazy JSON types - defer work until value is accessed
//!
//! Core principle: Don't copy strings until user reads them.
//! For most JSON parsing use cases, only a subset of values are accessed.

const std = @import("std");
const hashmap_helper = @import("utils.hashmap_helper");
const Value = @import("value.zig").Value;
const primitives = @import("primitives.zig");

/// Lazy string reference - stores slice into source, copies on access
pub const LazyString = struct {
    /// Original source data (not owned)
    source: []const u8,
    /// Start offset in source
    start: usize,
    /// End offset in source (exclusive)
    end: usize,
    /// Has escape sequences that need processing
    has_escapes: bool,
    /// Materialized string (owned, allocated on first access)
    materialized: ?[]const u8,
    /// Allocator for materialization
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, source: []const u8, start: usize, end: usize, has_escapes: bool) LazyString {
        return .{
            .source = source,
            .start = start,
            .end = end,
            .has_escapes = has_escapes,
            .materialized = null,
            .allocator = allocator,
        };
    }

    /// Get the string value - copies on first access
    pub fn get(self: *LazyString) ![]const u8 {
        if (self.materialized) |m| return m;

        const raw = self.source[self.start..self.end];
        if (!self.has_escapes) {
            // Fast path: just copy
            self.materialized = try self.allocator.dupe(u8, raw);
        } else {
            // Slow path: unescape - use shared primitives
            self.materialized = primitives.unescapeString(raw, self.allocator) catch return error.InvalidEscape;
        }
        return self.materialized.?;
    }

    /// Get raw slice without copying (useful for comparison, hashing)
    pub fn getRaw(self: *const LazyString) []const u8 {
        if (self.materialized) |m| return m;
        return self.source[self.start..self.end];
    }

    /// Check if string equals another without materializing
    pub fn eql(self: *const LazyString, other: []const u8) bool {
        if (self.materialized) |m| return std.mem.eql(u8, m, other);
        // If no escapes, can compare raw
        if (!self.has_escapes) {
            return std.mem.eql(u8, self.source[self.start..self.end], other);
        }
        // Has escapes - need to materialize to compare accurately
        // For now, fall back to raw comparison (may give false negatives)
        return std.mem.eql(u8, self.source[self.start..self.end], other);
    }

    pub fn deinit(self: *LazyString) void {
        if (self.materialized) |m| {
            self.allocator.free(m);
            self.materialized = null;
        }
    }

    pub fn len(self: *const LazyString) usize {
        if (self.materialized) |m| return m.len;
        return self.end - self.start;
    }
};

/// Lazy JSON value - strings remain as references until accessed
pub const LazyValue = union(enum) {
    null_value,
    bool_value: bool,
    number_int: i64,
    number_float: f64,
    string: LazyString,
    array: std.ArrayList(LazyValue),
    object: hashmap_helper.StringHashMap(LazyValue),

    /// Convert to eager Value (materializes all strings)
    pub fn toValue(self: *LazyValue, allocator: std.mem.Allocator) !Value {
        return switch (self.*) {
            .null_value => .null_value,
            .bool_value => |b| .{ .bool_value = b },
            .number_int => |n| .{ .number_int = n },
            .number_float => |f| .{ .number_float = f },
            .string => |*s| .{ .string = try s.get() },
            .array => |arr| blk: {
                var new_arr = std.ArrayList(Value){};
                errdefer {
                    for (new_arr.items) |*item| item.deinit(allocator);
                    new_arr.deinit(allocator);
                }
                try new_arr.ensureTotalCapacity(allocator, arr.items.len);
                for (arr.items) |*item| {
                    var lazy_item = item.*;
                    new_arr.appendAssumeCapacity(try lazy_item.toValue(allocator));
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
                    var lazy_val = entry.value_ptr.*;
                    const val_copy = try lazy_val.toValue(allocator);
                    try new_obj.put(key_copy, val_copy);
                }
                break :blk .{ .object = new_obj };
            },
        };
    }

    pub fn deinit(self: *LazyValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |*s| s.deinit(),
            .array => |*arr| {
                for (arr.items) |*item| item.deinit(allocator);
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
};

test "LazyString basic" {
    const allocator = std.testing.allocator;
    const source = "hello world";

    var lazy = LazyString.init(allocator, source, 0, 5, false);
    defer lazy.deinit();

    // Before access - no allocation
    try std.testing.expect(lazy.materialized == null);
    try std.testing.expectEqual(@as(usize, 5), lazy.len());

    // Access triggers copy
    const str = try lazy.get();
    try std.testing.expectEqualStrings("hello", str);
    try std.testing.expect(lazy.materialized != null);

    // Second access reuses materialized
    const str2 = try lazy.get();
    try std.testing.expectEqual(str.ptr, str2.ptr);
}

test "LazyString with escapes" {
    const allocator = std.testing.allocator;
    const source = "hello\\nworld";

    var lazy = LazyString.init(allocator, source, 0, source.len, true);
    defer lazy.deinit();

    const str = try lazy.get();
    try std.testing.expectEqualStrings("hello\nworld", str);
}

test "LazyString raw comparison" {
    const allocator = std.testing.allocator;
    const source = "test";

    var lazy = LazyString.init(allocator, source, 0, 4, false);
    defer lazy.deinit();

    // Compare without materializing
    try std.testing.expect(lazy.eql("test"));
    try std.testing.expect(!lazy.eql("other"));
    try std.testing.expect(lazy.materialized == null); // Still not materialized
}
