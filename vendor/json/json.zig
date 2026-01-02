//! Shared JSON library for metal0
//! SIMD-accelerated JSON parser/stringifier
//! Parse: 2.7-3.1x faster than std.json
//! Stringify: 1.2-1.3x faster than std.json
//!
//! Usage (eager - copies all strings):
//!   const json = @import("json");
//!   var parsed = try json.parse(allocator, input);
//!   defer parsed.deinit(allocator);
//!
//! Usage (lazy - defers string copy until access):
//!   var parsed = try json.parseLazy(allocator, input);
//!   defer parsed.deinit(allocator);
//!   const name = try parsed.object.get("name").?.string.get(); // copies only "name"

const std = @import("std");

pub const Value = @import("value.zig").Value;
pub const ParseError = @import("parse.zig").ParseError;
pub const StringifyError = @import("stringify.zig").StringifyError;

// Lazy types
pub const LazyValue = @import("lazy.zig").LazyValue;
pub const LazyString = @import("lazy.zig").LazyString;

// Stream parsing (fast extraction without full parse tree)
pub const stream = @import("stream.zig");

// Shared primitives for JSON parsing (used by runtime/json_impl too)
pub const primitives = @import("primitives.zig");

// SIMD utilities (used by runtime/json_impl too)
// Imported via module dependency from build.zig to avoid duplicate module error
pub const simd = @import("json_simd");

// Re-export utility functions from value.zig
pub const isWhitespace = @import("value.zig").isWhitespace;
pub const skipWhitespace = @import("value.zig").skipWhitespace;
pub const isEof = @import("value.zig").isEof;
pub const peek = @import("value.zig").peek;
pub const consume = @import("value.zig").consume;
pub const expect = @import("value.zig").expect;

/// Parse JSON string into Value (eager - copies all strings)
pub fn parse(allocator: std.mem.Allocator, input: []const u8) ParseError!Value {
    return @import("parse.zig").parse(allocator, input);
}

/// Parse JSON into LazyValue (lazy - strings copied on access)
/// Use when only accessing subset of values for better performance
pub fn parseLazy(allocator: std.mem.Allocator, input: []const u8) @import("parse_lazy.zig").ParseError!LazyValue {
    return @import("parse_lazy.zig").parseLazy(allocator, input);
}

/// Stringify Value to JSON string (caller owns returned memory)
pub fn stringify(allocator: std.mem.Allocator, value: Value) StringifyError![]u8 {
    return @import("stringify.zig").stringify(allocator, value);
}

test {
    _ = @import("value.zig");
    _ = @import("parse.zig");
    _ = @import("stringify.zig");
    _ = @import("lazy.zig");
    _ = @import("parse_lazy.zig");
    _ = @import("stream.zig");
    _ = @import("primitives.zig");
}
