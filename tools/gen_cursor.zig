//! Generate cursor PNG asset
//! Run with: zig run tools/gen_cursor.zig

const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cwd = std.fs.cwd();

    // Ensure output directory exists
    cwd.makePath("src/ui/assets") catch {};

    std.debug.print("Generating cursor asset...\n", .{});

    // Generate 16x16 arrow cursor PNG
    try writeCursorPng(allocator, cwd, "src/ui/assets/cursor.png");

    std.debug.print("Done! Cursor saved to src/ui/assets/cursor.png\n", .{});
}

/// Write a 16x16 arrow cursor PNG
fn writeCursorPng(allocator: std.mem.Allocator, dir: std.fs.Dir, path: []const u8) !void {
    const width: u32 = 16;
    const height: u32 = 16;

    // Arrow cursor pattern:
    // 0 = transparent, 1 = white (fill), 2 = black (outline)
    const pattern = [16][16]u8{
        .{ 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 1, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 1, 1, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 1, 1, 1, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 1, 1, 1, 1, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 1, 1, 1, 1, 1, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 1, 1, 1, 1, 1, 1, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 1, 1, 1, 1, 1, 1, 1, 1, 2, 0, 0, 0, 0, 0, 0, 0 },
        .{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 0, 0, 0, 0, 0, 0 },
        .{ 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 0, 0, 0, 0, 0, 0 },
        .{ 1, 1, 1, 2, 1, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 1, 1, 2, 0, 2, 1, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 1, 2, 0, 0, 0, 2, 1, 1, 2, 0, 0, 0, 0, 0, 0, 0 },
        .{ 2, 0, 0, 0, 0, 0, 2, 1, 1, 2, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 2, 1, 2, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 2, 2, 0, 0, 0, 0, 0, 0 },
    };

    // Create raw pixel data: filter byte + RGBA for each row
    const row_bytes = 1 + @as(usize, width) * 4;
    const raw_size = row_bytes * @as(usize, height);
    const raw_data = try allocator.alloc(u8, raw_size);
    defer allocator.free(raw_data);

    var i: usize = 0;
    for (0..height) |y| {
        raw_data[i] = 0; // filter: none
        i += 1;
        for (0..width) |x| {
            const pixel = pattern[y][x];
            switch (pixel) {
                0 => { // Transparent
                    raw_data[i] = 0;
                    raw_data[i + 1] = 0;
                    raw_data[i + 2] = 0;
                    raw_data[i + 3] = 0;
                },
                1 => { // White fill
                    raw_data[i] = 255;
                    raw_data[i + 1] = 255;
                    raw_data[i + 2] = 255;
                    raw_data[i + 3] = 255;
                },
                2 => { // Black outline
                    raw_data[i] = 0;
                    raw_data[i + 1] = 0;
                    raw_data[i + 2] = 0;
                    raw_data[i + 3] = 255;
                },
                else => { // Fallback transparent
                    raw_data[i] = 0;
                    raw_data[i + 1] = 0;
                    raw_data[i + 2] = 0;
                    raw_data[i + 3] = 0;
                },
            }
            i += 4;
        }
    }

    // Create zlib-wrapped uncompressed data
    const max_block_size: usize = 65535;
    var block_count = (raw_size + max_block_size - 1) / max_block_size;
    if (block_count == 0) block_count = 1;

    const compressed_size = 2 + (5 * block_count) + raw_size + 4;
    const compressed_buf = try allocator.alloc(u8, compressed_size);
    defer allocator.free(compressed_buf);

    var pos: usize = 0;

    // zlib header
    compressed_buf[pos] = 0x78;
    pos += 1;
    compressed_buf[pos] = 0x01;
    pos += 1;

    // Write store blocks
    var remaining = raw_size;
    var src_pos: usize = 0;
    while (remaining > 0) {
        const block_size: u16 = @intCast(@min(remaining, max_block_size));
        const is_final = remaining <= max_block_size;

        compressed_buf[pos] = if (is_final) 0x01 else 0x00;
        pos += 1;

        std.mem.writeInt(u16, compressed_buf[pos..][0..2], block_size, .little);
        pos += 2;

        std.mem.writeInt(u16, compressed_buf[pos..][0..2], ~block_size, .little);
        pos += 2;

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
    ihdr_data[8] = 8;
    ihdr_data[9] = 6;
    ihdr_data[10] = 0;
    ihdr_data[11] = 0;
    ihdr_data[12] = 0;
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
    try writer.writeInt(u32, @intCast(data.len), .big);
    try writer.writeAll(chunk_type);
    try writer.writeAll(data);
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
