const std = @import("std");

pub fn main() !void {
    // Create a simple 1x1 red pixel PNG
    const png_data = "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90wS\xde\x00\x00\x00\x0cIDATx\x9cc\xf8\xcf\xc0\x00\x00\x00\x03\x00\x01\x00\x00\x00\x00IEND\xaeB`\x82";

    // Encode to base64
    const encoder = std.base64.standard.Encoder;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const base64_size = encoder.calcSize(png_data.len);
    const base64_data = try allocator.alloc(u8, base64_size);
    defer allocator.free(base64_data);
    _ = encoder.encode(base64_data, png_data);

    std.debug.print("Testing Kitty graphics...\n", .{});

    // Write Kitty graphics escape sequence directly
    const stdout_file = std.fs.File.stdout();
    var escape_buf: [2048]u8 = undefined;
    const escape_seq = try std.fmt.bufPrint(&escape_buf, "\x1b_Ga=T,f=100;{s}\x1b\\\n", .{base64_data});
    try stdout_file.writeAll(escape_seq);

    std.debug.print("Done! You should see a tiny red pixel above.\n", .{});
    std.debug.print("Press Enter to exit...\n", .{});

    // Wait for user
    var buf: [1]u8 = undefined;
    const stdin = std.fs.File.stdin();
    _ = try stdin.read(&buf);
}
