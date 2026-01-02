const std = @import("std");

pub const DisplayOptions = struct {
    // Image placement
    columns: ?u32 = null, // Terminal columns to span
    rows: ?u32 = null, // Terminal rows to span

    // Pixel dimensions (for scaling)
    width: ?u32 = null,
    height: ?u32 = null,

    // Positioning
    x: u32 = 0, // Column offset
    y: u32 = 0, // Row offset

    // Z-index
    z: i32 = 0,
};

pub const KittyGraphics = struct {
    allocator: std.mem.Allocator,
    next_image_id: u32,

    pub fn init(allocator: std.mem.Allocator) KittyGraphics {
        return .{
            .allocator = allocator,
            .next_image_id = 1,
        };
    }

    /// Display PNG image data
    pub fn displayPNG(
        self: *KittyGraphics,
        writer: anytype,
        png_data: []const u8,
        opts: DisplayOptions,
    ) !void {
        const image_id = self.next_image_id;
        self.next_image_id += 1;

        // Base64 encode the PNG data
        const encoder = std.base64.standard.Encoder;
        const encoded_len = encoder.calcSize(png_data.len);
        const encoded = try self.allocator.alloc(u8, encoded_len);
        defer self.allocator.free(encoded);
        _ = encoder.encode(encoded, png_data);

        // Write Kitty graphics escape sequence
        // Format: \x1b_G<control>;<data>\x1b\\
        try writer.writeAll("\x1b_G");

        // Control data (key=value pairs)
        try writer.print("a=T,f=100,t=d,i={d}", .{image_id});

        if (opts.columns) |c| try writer.print(",c={d}", .{c});
        if (opts.rows) |r| try writer.print(",r={d}", .{r});
        if (opts.width) |w| try writer.print(",s={d}", .{w});
        if (opts.height) |h| try writer.print(",v={d}", .{h});

        // Don't move cursor after displaying
        try writer.writeAll(",C=1");

        // Send payload
        try writer.writeByte(';');
        try writer.writeAll(encoded);
        try writer.writeAll("\x1b\\");
    }

    /// Clear all images
    pub fn clearAll(self: *KittyGraphics, writer: anytype) !void {
        _ = self;
        // Delete all images: a=d,d=a
        try writer.writeAll("\x1b_Ga=d,d=a\x1b\\");
    }

    /// Delete specific image by ID
    pub fn deleteImage(self: *KittyGraphics, writer: anytype, id: u32) !void {
        _ = self;
        try writer.print("\x1b_Ga=d,d=i,i={d}\x1b\\", .{id});
    }
};
