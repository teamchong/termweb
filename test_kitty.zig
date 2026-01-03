const std = @import("std");
const kitty_mod = @import("src/terminal/kitty_graphics.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a 1x1 red pixel PNG (minimal test)
    const png_data = "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90wS\xde\x00\x00\x00\x0cIDATx\x9cc\xf8\xcf\xc0\x00\x00\x00\x03\x00\x01\x00\x00\x00\x00IEND\xaeB`\x82";
    
    var stdout_buf: [4096]u8 = undefined;
    const stdout_file = std.fs.File.stdout();
    var stdout_writer = stdout_file.writer(&stdout_buf);
    const writer = &stdout_writer.interface;

    var kitty = kitty_mod.KittyGraphics.init(allocator);
    
    try writer.print("Testing Kitty Graphics Protocol...\n", .{});
    try kitty.displayPNG(writer, png_data, .{ .rows = 1 });
    try writer.print("\nTest complete!\n", .{});
}
