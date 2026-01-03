//! Generate placeholder PNG assets for UI testing
//! Run with: zig run tools/gen_placeholders.zig
//!
//! This creates simple solid-color placeholder images.
//! Replace with proper glassmorphism renders later.

const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cwd = std.fs.cwd();

    // Create output directories
    cwd.makePath("src/ui/assets/dark") catch {};
    cwd.makePath("src/ui/assets/light") catch {};

    std.debug.print("Generating placeholder UI assets...\n", .{});

    // Button assets (32x32)
    const button_states = [_]struct { name: []const u8, dark_color: [4]u8, light_color: [4]u8 }{
        .{ .name = "back-normal", .dark_color = .{ 60, 60, 60, 200 }, .light_color = .{ 230, 230, 230, 200 } },
        .{ .name = "back-hover", .dark_color = .{ 80, 80, 80, 220 }, .light_color = .{ 210, 210, 210, 220 } },
        .{ .name = "back-active", .dark_color = .{ 90, 90, 90, 240 }, .light_color = .{ 200, 200, 200, 240 } },
        .{ .name = "back-disabled", .dark_color = .{ 40, 40, 40, 100 }, .light_color = .{ 180, 180, 180, 100 } },
        .{ .name = "forward-normal", .dark_color = .{ 60, 60, 60, 200 }, .light_color = .{ 230, 230, 230, 200 } },
        .{ .name = "forward-hover", .dark_color = .{ 80, 80, 80, 220 }, .light_color = .{ 210, 210, 210, 220 } },
        .{ .name = "forward-active", .dark_color = .{ 90, 90, 90, 240 }, .light_color = .{ 200, 200, 200, 240 } },
        .{ .name = "forward-disabled", .dark_color = .{ 40, 40, 40, 100 }, .light_color = .{ 180, 180, 180, 100 } },
        .{ .name = "refresh-normal", .dark_color = .{ 60, 60, 60, 200 }, .light_color = .{ 230, 230, 230, 200 } },
        .{ .name = "refresh-hover", .dark_color = .{ 80, 80, 80, 220 }, .light_color = .{ 210, 210, 210, 220 } },
        .{ .name = "refresh-active", .dark_color = .{ 90, 90, 90, 240 }, .light_color = .{ 200, 200, 200, 240 } },
        .{ .name = "refresh-loading", .dark_color = .{ 74, 158, 255, 200 }, .light_color = .{ 0, 102, 204, 200 } },
        .{ .name = "close-normal", .dark_color = .{ 60, 60, 60, 200 }, .light_color = .{ 230, 230, 230, 200 } },
        .{ .name = "close-hover", .dark_color = .{ 255, 59, 48, 220 }, .light_color = .{ 255, 59, 48, 220 } },
        .{ .name = "close-active", .dark_color = .{ 255, 59, 48, 255 }, .light_color = .{ 255, 59, 48, 255 } },
    };

    // Generate button PNGs (32x32)
    for (button_states) |btn| {
        // Dark theme
        const dark_path = try std.fmt.allocPrint(allocator, "src/ui/assets/dark/{s}.png", .{btn.name});
        defer allocator.free(dark_path);
        try writePng(allocator, cwd, dark_path, 32, 32, btn.dark_color);

        // Light theme
        const light_path = try std.fmt.allocPrint(allocator, "src/ui/assets/light/{s}.png", .{btn.name});
        defer allocator.free(light_path);
        try writePng(allocator, cwd, light_path, 32, 32, btn.light_color);

        std.debug.print("  {s}\n", .{btn.name});
    }

    // Tab bar (1280x40) - gradient placeholder
    try writePng(allocator, cwd, "src/ui/assets/dark/tabbar-normal.png", 1280, 40, .{ 30, 30, 30, 180 });
    try writePng(allocator, cwd, "src/ui/assets/light/tabbar-normal.png", 1280, 40, .{ 250, 250, 250, 180 });
    std.debug.print("  tabbar-normal\n", .{});

    // Status bar (1280x24)
    try writePng(allocator, cwd, "src/ui/assets/dark/statusbar-normal.png", 1280, 24, .{ 30, 30, 30, 180 });
    try writePng(allocator, cwd, "src/ui/assets/light/statusbar-normal.png", 1280, 24, .{ 250, 250, 250, 180 });
    std.debug.print("  statusbar-normal\n", .{});

    std.debug.print("\nDone! Assets saved to src/ui/assets/\n", .{});
}

/// Write a simple solid-color PNG file
fn writePng(allocator: std.mem.Allocator, dir: std.fs.Dir, path: []const u8, width: u32, height: u32, rgba: [4]u8) !void {
    // Create raw pixel data: filter byte + RGBA for each row
    const row_bytes = 1 + @as(usize, width) * 4;
    const raw_size = row_bytes * @as(usize, height);
    const raw_data = try allocator.alloc(u8, raw_size);
    defer allocator.free(raw_data);

    var i: usize = 0;
    for (0..height) |_| {
        raw_data[i] = 0; // filter: none
        i += 1;
        for (0..width) |_| {
            raw_data[i] = rgba[0];
            raw_data[i + 1] = rgba[1];
            raw_data[i + 2] = rgba[2];
            raw_data[i + 3] = rgba[3];
            i += 4;
        }
    }

    // Create zlib-wrapped uncompressed data (store blocks)
    // zlib header: CMF=0x78 (deflate, 32K window), FLG=0x01 (no dict, check bits)
    // For simplicity, use store (uncompressed) blocks
    const max_block_size: usize = 65535;
    var block_count = (raw_size + max_block_size - 1) / max_block_size;
    if (block_count == 0) block_count = 1;

    // Each store block: 5 bytes header (BFINAL/BTYPE=0, LEN, NLEN) + data
    const compressed_size = 2 + (5 * block_count) + raw_size + 4; // zlib header + blocks + adler32
    const compressed_buf = try allocator.alloc(u8, compressed_size);
    defer allocator.free(compressed_buf);

    var pos: usize = 0;

    // zlib header
    compressed_buf[pos] = 0x78;
    pos += 1;
    compressed_buf[pos] = 0x01; // FCHECK bits for CMF=0x78
    pos += 1;

    // Write store blocks
    var remaining = raw_size;
    var src_pos: usize = 0;
    while (remaining > 0) {
        const block_size: u16 = @intCast(@min(remaining, max_block_size));
        const is_final = remaining <= max_block_size;

        // Block header: BFINAL (1 bit) + BTYPE=00 (2 bits) = 0x00 or 0x01
        compressed_buf[pos] = if (is_final) 0x01 else 0x00;
        pos += 1;

        // LEN (little-endian 16-bit)
        std.mem.writeInt(u16, compressed_buf[pos..][0..2], block_size, .little);
        pos += 2;

        // NLEN (one's complement of LEN)
        std.mem.writeInt(u16, compressed_buf[pos..][0..2], ~block_size, .little);
        pos += 2;

        // Data
        @memcpy(compressed_buf[pos..][0..block_size], raw_data[src_pos..][0..block_size]);
        pos += block_size;
        src_pos += block_size;
        remaining -= block_size;
    }

    // Adler-32 checksum
    const adler = adler32(raw_data);
    std.mem.writeInt(u32, compressed_buf[pos..][0..4], adler, .big);
    pos += 4;

    const compressed = compressed_buf[0..pos];

    // Calculate total PNG size
    // signature (8) + IHDR chunk (25) + IDAT chunk (12 + compressed.len) + IEND (12)
    const png_size = 8 + 25 + 12 + compressed.len + 12;
    const png_buf = try allocator.alloc(u8, png_size);
    defer allocator.free(png_buf);

    var png_fbs = std.io.fixedBufferStream(png_buf);
    const writer = png_fbs.writer();

    // PNG signature
    try writer.writeAll("\x89PNG\r\n\x1a\n");

    // IHDR chunk
    var ihdr_data: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr_data[0..4], width, .big);
    std.mem.writeInt(u32, ihdr_data[4..8], height, .big);
    ihdr_data[8] = 8; // bit depth
    ihdr_data[9] = 6; // color type (RGBA)
    ihdr_data[10] = 0; // compression
    ihdr_data[11] = 0; // filter
    ihdr_data[12] = 0; // interlace
    try writeChunk(writer, "IHDR", &ihdr_data);

    // IDAT chunk
    try writeChunk(writer, "IDAT", compressed);

    // IEND chunk
    try writeChunk(writer, "IEND", &[0]u8{});

    // Write to file
    const file = try dir.createFile(path, .{});
    defer file.close();
    try file.writeAll(png_fbs.getWritten());
}

fn writeChunk(writer: anytype, chunk_type: *const [4]u8, data: []const u8) !void {
    // Length (big endian)
    try writer.writeInt(u32, @intCast(data.len), .big);
    // Type
    try writer.writeAll(chunk_type);
    // Data
    try writer.writeAll(data);
    // CRC32 of type + data
    var hasher = std.hash.Crc32.init();
    hasher.update(chunk_type);
    hasher.update(data);
    try writer.writeInt(u32, hasher.final(), .big);
}

fn adler32(data: []const u8) u32 {
    const MOD_ADLER: u32 = 65521;
    var a: u32 = 1;
    var b: u32 = 0;

    for (data) |byte| {
        a = (a + byte) % MOD_ADLER;
        b = (b + a) % MOD_ADLER;
    }

    return (b << 16) | a;
}
