//! JSON Benchmark: shared/json vs std.json
//! Run: zig build-exe -OReleaseFast bench.zig -o bench && ./bench

const std = @import("std");
const shared_json = @import("json.zig");

const SMALL_JSON =
    \\{"name":"test","value":42,"active":true}
;

const MEDIUM_JSON =
    \\{"users":[{"id":1,"name":"Alice","email":"alice@example.com"},{"id":2,"name":"Bob","email":"bob@example.com"}],"meta":{"page":1,"total":100}}
;

fn generateLargeJson(allocator: std.mem.Allocator) ![]const u8 {
    var list = std.ArrayList(u8){};
    errdefer list.deinit(allocator);

    try list.appendSlice(allocator, "[");
    for (0..100) |i| {
        if (i > 0) try list.appendSlice(allocator, ",");
        try list.writer(allocator).print(
            \\{{"id":{d},"name":"User{d}","email":"user{d}@example.com","active":true,"score":98.5}}
        , .{ i, i, i });
    }
    try list.appendSlice(allocator, "]");

    return list.toOwnedSlice(allocator);
}

pub fn main() !void {
    // Use c_allocator for performance (29x faster than GPA)
    const allocator = std.heap.c_allocator;

    const large_json = try generateLargeJson(allocator);
    defer allocator.free(large_json);

    std.debug.print("=== JSON Benchmark: shared/json vs std.json ===\n\n", .{});

    std.debug.print("PARSE:\n", .{});
    try benchParse(allocator, "Small (~40B)", SMALL_JSON, 100_000);
    try benchParse(allocator, "Medium (~180B)", MEDIUM_JSON, 50_000);
    try benchParse(allocator, "Large (~10KB)", large_json, 5_000);

    std.debug.print("\nSTRINGIFY:\n", .{});
    try benchStringify(allocator, "Small", SMALL_JSON, 100_000);
    try benchStringify(allocator, "Medium", MEDIUM_JSON, 50_000);
}

fn benchParse(base_allocator: std.mem.Allocator, name: []const u8, json_data: []const u8, iterations: usize) !void {
    // Warmup with arena
    {
        var arena = std.heap.ArenaAllocator.init(base_allocator);
        defer arena.deinit();
        for (0..100) |_| {
            _ = try shared_json.parse(arena.allocator(), json_data);
            _ = arena.reset(.retain_capacity);
        }
    }

    // shared/json with arena (bulk free)
    var shared_time: u64 = 0;
    {
        var arena = std.heap.ArenaAllocator.init(base_allocator);
        defer arena.deinit();
        const start = std.time.nanoTimestamp();
        for (0..iterations) |_| {
            _ = try shared_json.parse(arena.allocator(), json_data);
            _ = arena.reset(.retain_capacity);
        }
        shared_time = @intCast(std.time.nanoTimestamp() - start);
    }

    // std.json with arena (fair comparison)
    var std_time: u64 = 0;
    {
        var arena = std.heap.ArenaAllocator.init(base_allocator);
        defer arena.deinit();
        const start = std.time.nanoTimestamp();
        for (0..iterations) |_| {
            _ = try std.json.parseFromSlice(std.json.Value, arena.allocator(), json_data, .{});
            _ = arena.reset(.retain_capacity);
        }
        std_time = @intCast(std.time.nanoTimestamp() - start);
    }

    const speedup = @as(f64, @floatFromInt(std_time)) / @as(f64, @floatFromInt(shared_time));
    std.debug.print("  {s:14} shared:{d:6}ms  std:{d:6}ms  {d:.2}x\n", .{
        name,
        shared_time / 1_000_000,
        std_time / 1_000_000,
        speedup,
    });
}

fn benchStringify(base_allocator: std.mem.Allocator, name: []const u8, json_data: []const u8, iterations: usize) !void {
    var parsed = try shared_json.parse(base_allocator, json_data);
    defer parsed.deinit(base_allocator);

    // Warmup with arena
    {
        var arena = std.heap.ArenaAllocator.init(base_allocator);
        defer arena.deinit();
        for (0..100) |_| {
            _ = try shared_json.stringify(arena.allocator(), parsed);
            _ = arena.reset(.retain_capacity);
        }
    }

    // shared/json with arena
    var shared_time: u64 = 0;
    {
        var arena = std.heap.ArenaAllocator.init(base_allocator);
        defer arena.deinit();
        const start = std.time.nanoTimestamp();
        for (0..iterations) |_| {
            _ = try shared_json.stringify(arena.allocator(), parsed);
            _ = arena.reset(.retain_capacity);
        }
        shared_time = @intCast(std.time.nanoTimestamp() - start);
    }

    // std.json stringify with arena (fair comparison)
    var std_parsed = try std.json.parseFromSlice(std.json.Value, base_allocator, json_data, .{});
    defer std_parsed.deinit();

    var std_time: u64 = 0;
    {
        var arena = std.heap.ArenaAllocator.init(base_allocator);
        defer arena.deinit();
        const start = std.time.nanoTimestamp();
        for (0..iterations) |_| {
            var out: std.io.Writer.Allocating = .init(arena.allocator());
            var ws: std.json.Stringify = .{ .writer = &out.writer };
            try ws.write(std_parsed.value);
            _ = arena.reset(.retain_capacity);
        }
        std_time = @intCast(std.time.nanoTimestamp() - start);
    }

    const speedup = @as(f64, @floatFromInt(std_time)) / @as(f64, @floatFromInt(shared_time));
    std.debug.print("  {s:14} shared:{d:6}ms  std:{d:6}ms  {d:.2}x\n", .{
        name,
        shared_time / 1_000_000,
        std_time / 1_000_000,
        speedup,
    });
}
