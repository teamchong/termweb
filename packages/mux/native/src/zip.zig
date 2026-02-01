const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;

const c = @cImport({
    @cInclude("libdeflate.h");
});

// ============================================================================
// ZIP File Format (using libdeflate for compression)
// ============================================================================

// ZIP signatures
const LOCAL_FILE_HEADER_SIG: u32 = 0x04034b50;
const CENTRAL_DIR_HEADER_SIG: u32 = 0x02014b50;
const END_OF_CENTRAL_DIR_SIG: u32 = 0x06054b50;

// Compression methods
const COMPRESSION_STORE: u16 = 0; // No compression
const COMPRESSION_DEFLATE: u16 = 8; // DEFLATE

pub const ZipEntry = struct {
    path: []const u8, // Path within zip
    data: []const u8, // Uncompressed data
    compressed: []const u8, // Compressed data
    crc32: u32,
    compressed_size: u32,
    uncompressed_size: u32,
    offset: u32, // Offset of local header in zip
};

pub const ZipWriter = struct {
    allocator: Allocator,
    entries: std.ArrayListUnmanaged(ZipEntry),
    compressor: *c.libdeflate_compressor,
    buffer: std.ArrayListUnmanaged(u8),

    pub fn init(allocator: Allocator) !ZipWriter {
        const compressor = c.libdeflate_alloc_compressor(6) orelse return error.CompressorFailed;
        return .{
            .allocator = allocator,
            .entries = .{},
            .compressor = compressor,
            .buffer = .{},
        };
    }

    pub fn deinit(self: *ZipWriter) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.compressed);
        }
        self.entries.deinit(self.allocator);
        self.buffer.deinit(self.allocator);
        c.libdeflate_free_compressor(self.compressor);
    }

    // Add a file to the zip
    pub fn addFile(self: *ZipWriter, path: []const u8, data: []const u8) !void {
        // Calculate CRC32
        const crc = c.libdeflate_crc32(0, data.ptr, data.len);

        // Compress with libdeflate
        const max_compressed = c.libdeflate_deflate_compress_bound(self.compressor, data.len);
        const compressed_buf = try self.allocator.alloc(u8, max_compressed);
        errdefer self.allocator.free(compressed_buf);

        const compressed_size = c.libdeflate_deflate_compress(
            self.compressor,
            data.ptr,
            data.len,
            compressed_buf.ptr,
            compressed_buf.len,
        );

        // Use stored if compression doesn't help
        const use_deflate = compressed_size > 0 and compressed_size < data.len;
        const final_compressed = if (use_deflate)
            try self.allocator.dupe(u8, compressed_buf[0..compressed_size])
        else
            try self.allocator.dupe(u8, data);
        self.allocator.free(compressed_buf);

        try self.entries.append(self.allocator, .{
            .path = path,
            .data = data,
            .compressed = final_compressed,
            .crc32 = @intCast(crc),
            .compressed_size = @intCast(if (use_deflate) compressed_size else data.len),
            .uncompressed_size = @intCast(data.len),
            .offset = 0, // Set during finalize
        });
    }

    // Add a directory entry to the zip
    pub fn addDirectory(self: *ZipWriter, path: []const u8) !void {
        // Directory entries have zero-length data and path ends with /
        const dir_path = try self.allocator.alloc(u8, path.len + 1);
        @memcpy(dir_path[0..path.len], path);
        dir_path[path.len] = '/';

        try self.entries.append(self.allocator, .{
            .path = dir_path,
            .data = "",
            .compressed = try self.allocator.dupe(u8, ""),
            .crc32 = 0,
            .compressed_size = 0,
            .uncompressed_size = 0,
            .offset = 0,
        });
    }

    // Finalize and get the complete zip data
    pub fn finalize(self: *ZipWriter) ![]const u8 {
        self.buffer.clearRetainingCapacity();

        // Write local file headers and data
        for (self.entries.items) |*entry| {
            entry.offset = @intCast(self.buffer.items.len);
            try self.writeLocalFileHeader(entry.*);
            try self.buffer.appendSlice(self.allocator, entry.compressed);
        }

        // Remember central directory start
        const central_dir_offset: u32 = @intCast(self.buffer.items.len);

        // Write central directory
        for (self.entries.items) |entry| {
            try self.writeCentralDirHeader(entry);
        }

        const central_dir_size: u32 = @intCast(self.buffer.items.len - central_dir_offset);

        // Write end of central directory
        try self.writeEndOfCentralDir(central_dir_offset, central_dir_size);

        return self.buffer.items;
    }

    fn writeLocalFileHeader(self: *ZipWriter, entry: ZipEntry) !void {
        const is_deflate = entry.compressed_size < entry.uncompressed_size and entry.uncompressed_size > 0;

        // Local file header: 30 bytes + filename
        var header: [30]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], LOCAL_FILE_HEADER_SIG, .little);
        std.mem.writeInt(u16, header[4..6], 20, .little); // Version needed (2.0)
        std.mem.writeInt(u16, header[6..8], 0, .little); // General purpose flags
        std.mem.writeInt(u16, header[8..10], if (is_deflate) COMPRESSION_DEFLATE else COMPRESSION_STORE, .little);
        std.mem.writeInt(u16, header[10..12], 0, .little); // Mod time
        std.mem.writeInt(u16, header[12..14], 0, .little); // Mod date
        std.mem.writeInt(u32, header[14..18], entry.crc32, .little);
        std.mem.writeInt(u32, header[18..22], entry.compressed_size, .little);
        std.mem.writeInt(u32, header[22..26], entry.uncompressed_size, .little);
        std.mem.writeInt(u16, header[26..28], @intCast(entry.path.len), .little);
        std.mem.writeInt(u16, header[28..30], 0, .little); // Extra field length

        try self.buffer.appendSlice(self.allocator, &header);
        try self.buffer.appendSlice(self.allocator, entry.path);
    }

    fn writeCentralDirHeader(self: *ZipWriter, entry: ZipEntry) !void {
        const is_deflate = entry.compressed_size < entry.uncompressed_size and entry.uncompressed_size > 0;
        const is_dir = entry.path.len > 0 and entry.path[entry.path.len - 1] == '/';

        // Central directory header: 46 bytes + filename
        var header: [46]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], CENTRAL_DIR_HEADER_SIG, .little);
        std.mem.writeInt(u16, header[4..6], 20, .little); // Version made by
        std.mem.writeInt(u16, header[6..8], 20, .little); // Version needed
        std.mem.writeInt(u16, header[8..10], 0, .little); // General purpose flags
        std.mem.writeInt(u16, header[10..12], if (is_deflate) COMPRESSION_DEFLATE else COMPRESSION_STORE, .little);
        std.mem.writeInt(u16, header[12..14], 0, .little); // Mod time
        std.mem.writeInt(u16, header[14..16], 0, .little); // Mod date
        std.mem.writeInt(u32, header[16..20], entry.crc32, .little);
        std.mem.writeInt(u32, header[20..24], entry.compressed_size, .little);
        std.mem.writeInt(u32, header[24..28], entry.uncompressed_size, .little);
        std.mem.writeInt(u16, header[28..30], @intCast(entry.path.len), .little);
        std.mem.writeInt(u16, header[30..32], 0, .little); // Extra field length
        std.mem.writeInt(u16, header[32..34], 0, .little); // Comment length
        std.mem.writeInt(u16, header[34..36], 0, .little); // Disk number
        std.mem.writeInt(u16, header[36..38], 0, .little); // Internal attributes
        // External attributes: directory flag
        std.mem.writeInt(u32, header[38..42], if (is_dir) 0x10 else 0, .little);
        std.mem.writeInt(u32, header[42..46], entry.offset, .little);

        try self.buffer.appendSlice(self.allocator, &header);
        try self.buffer.appendSlice(self.allocator, entry.path);
    }

    fn writeEndOfCentralDir(self: *ZipWriter, central_dir_offset: u32, central_dir_size: u32) !void {
        // End of central directory: 22 bytes
        var footer: [22]u8 = undefined;
        const entry_count: u16 = @intCast(self.entries.items.len);

        std.mem.writeInt(u32, footer[0..4], END_OF_CENTRAL_DIR_SIG, .little);
        std.mem.writeInt(u16, footer[4..6], 0, .little); // Disk number
        std.mem.writeInt(u16, footer[6..8], 0, .little); // Disk with central dir
        std.mem.writeInt(u16, footer[8..10], entry_count, .little); // Entries on this disk
        std.mem.writeInt(u16, footer[10..12], entry_count, .little); // Total entries
        std.mem.writeInt(u32, footer[12..16], central_dir_size, .little);
        std.mem.writeInt(u32, footer[16..20], central_dir_offset, .little);
        std.mem.writeInt(u16, footer[20..22], 0, .little); // Comment length

        try self.buffer.appendSlice(self.allocator, &footer);
    }
};

// ============================================================================
// Helper: Create zip from directory
// ============================================================================

pub fn zipDirectory(allocator: Allocator, dir_path: []const u8, base_name: []const u8) ![]const u8 {
    var zip = try ZipWriter.init(allocator);
    defer zip.deinit();

    // Walk directory and add files
    try walkAndAddFiles(allocator, &zip, dir_path, base_name);

    // Finalize and return owned copy
    const data = try zip.finalize();
    return try allocator.dupe(u8, data);
}

fn walkAndAddFiles(allocator: Allocator, zip: *ZipWriter, dir_path: []const u8, prefix: []const u8) !void {
    var dir = fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        // Build full path
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
        defer allocator.free(full_path);

        // Build zip path (relative to base)
        const zip_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
        defer allocator.free(zip_path);

        switch (entry.kind) {
            .file => {
                // Read file and add to zip
                const file = fs.openFileAbsolute(full_path, .{}) catch continue;
                defer file.close();

                const stat = file.stat() catch continue;
                if (stat.size > 100 * 1024 * 1024) continue; // Skip files > 100MB

                const data = file.readToEndAlloc(allocator, 100 * 1024 * 1024) catch continue;
                defer allocator.free(data);

                try zip.addFile(zip_path, data);
            },
            .directory => {
                // Skip hidden directories
                if (entry.name[0] == '.') continue;

                // Recurse
                try walkAndAddFiles(allocator, zip, full_path, zip_path);
            },
            else => {},
        }
    }
}
