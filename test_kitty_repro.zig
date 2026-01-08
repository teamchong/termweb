const std = @import("std");
const kitty_mod = @import("src/terminal/kitty_graphics.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var kitty = kitty_mod.KittyGraphics.init(allocator);

    const stdout = std.io.getStdOut();
    const writer = stdout.writer();

    try writer.print("\x1b[2J", .{}); // Clear screen
    try writer.print("\x1b[H", .{});  // Home cursor

    // 1. Create a simple red 100x100 PNG
    // This is a base64 of a simple red square
    const red_square_base64 = "iVBORw0KGgoAAAANSUhEUgAAAGQAAABkCAYAAABw4pVUAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAAcSURBVHhe7cExAQAAAMKg9U9tCy8gAAAAAAAADmz1QAAB6d546AAAAABJRU5ErkJggg==";

    try writer.print("Displaying Image 1 (Base64)...\n", .{});
    
    // Display it
    const opts = kitty_mod.DisplayOptions{
        .columns = 20,
        .rows = 10,
        .placement_id = 1,
        .z = 0,
    };
    
    const id = try kitty.displayBase64PNG(writer, red_square_base64, opts);
    try writer.print("\nImage ID: {d}\n\n", .{id});
    
    try writer.print("Press Enter to clear...\n", .{});
    var buf: [10]u8 = undefined;
    _ = try std.io.getStdIn().reader().readUntilDelimiterOrEof(&buf, '\n');

    try kitty.clearAll(writer);
}
