const std = @import("std");
const ShmBuffer = @import("shm.zig").ShmBuffer;
const decode = @import("../image/decode.zig");

pub const DisplayOptions = struct {
    // Image placement
    columns: ?u32 = null, // Terminal columns to span
    rows: ?u32 = null, // Terminal rows to span

    // Pixel dimensions (for scaling)
    width: ?u32 = null,
    height: ?u32 = null,

    // Cell-based positioning
    x: u32 = 0, // Column offset
    y: u32 = 0, // Row offset

    // Pixel-based positioning within cell
    x_offset: ?u32 = null, // X pixel offset within cell
    y_offset: ?u32 = null, // Y pixel offset within cell

    // Z-index for layering
    z: i32 = 0,

    // Placement ID (use same ID to replace in place)
    placement_id: ?u32 = null,

    // Image ID (use fixed ID to replace image data in place)
    image_id: ?u32 = null,
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

    /// Display PNG image data, returns the image ID used
    pub fn displayPNG(
        self: *KittyGraphics,
        writer: anytype,
        png_data: []const u8,
        opts: DisplayOptions,
    ) !u32 {
        const image_id = opts.image_id orelse blk: {
            const id = self.next_image_id;
            self.next_image_id += 1;
            // Wrap around to prevent u32 overflow (after ~2072 days of continuous use at 24fps)
            if (self.next_image_id > 0xFFFFFFF0) self.next_image_id = 1;
            break :blk id;
        };

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
        // q=2 suppresses OK responses (only show errors)
        try writer.print("a=T,f=100,t=d,i={d},q=2", .{image_id});

        // Use placement ID if provided (for in-place replacement)
        if (opts.placement_id) |p| try writer.print(",p={d}", .{p});

        if (opts.columns) |c| try writer.print(",c={d}", .{c});
        if (opts.rows) |r| try writer.print(",r={d}", .{r});
        if (opts.width) |w| try writer.print(",s={d}", .{w});
        if (opts.height) |h| try writer.print(",v={d}", .{h});

        // Z-index for layering (negative = behind text, positive = in front)
        if (opts.z != 0) try writer.print(",z={d}", .{opts.z});

        // Pixel offsets within cell
        if (opts.x_offset) |xo| try writer.print(",X={d}", .{xo});
        if (opts.y_offset) |yo| try writer.print(",Y={d}", .{yo});

        // Don't move cursor after displaying
        try writer.writeAll(",C=1");

        // Send payload
        try writer.writeByte(';');
        try writer.writeAll(encoded);
        try writer.writeAll("\x1b\\");

        return image_id;
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

    /// Delete specific placement by placement ID
    pub fn deletePlacement(self: *KittyGraphics, writer: anytype, placement_id: u32) !void {
        _ = self;
        // d=p deletes by placement ID, p=<id> specifies which placement
        try writer.print("\x1b_Ga=d,d=p,p={d}\x1b\\", .{placement_id});
    }

    fn displayBase64ImageWithFormat(
        self: *KittyGraphics,
        writer: anytype,
        base64_data: []const u8,
        opts: DisplayOptions,
        format_code: u32,
    ) !u32 {
        const image_id = opts.image_id orelse blk: {
            const id = self.next_image_id;
            self.next_image_id += 1;
            break :blk id;
        };

        // Kitty protocol chunk size (4096 bytes max per chunk)
        const CHUNK_SIZE: usize = 4096;

        var offset: usize = 0;
        var first_chunk = true;

        while (offset < base64_data.len) {
            const remaining = base64_data.len - offset;
            const chunk_len = @min(remaining, CHUNK_SIZE);
            const is_last = (offset + chunk_len >= base64_data.len);

            // Write escape sequence start
            try writer.writeAll("\x1b_G");

            if (first_chunk) {
                // First chunk: include all control data
                // a=T (transmit+display), t=d (direct data)
                // m=1 means more data coming, m=0 means this is the last chunk
                try writer.print("a=T,f={d},t=d,i={d},q=2,m={d}", .{
                    format_code,
                    image_id,
                    if (is_last) @as(u8, 0) else @as(u8, 1),
                });

                if (opts.placement_id) |p| try writer.print(",p={d}", .{p});
                if (opts.columns) |c| try writer.print(",c={d}", .{c});
                if (opts.rows) |r| try writer.print(",r={d}", .{r});
                if (opts.width) |w| try writer.print(",s={d}", .{w});
                if (opts.height) |h| try writer.print(",v={d}", .{h});
                if (opts.z != 0) try writer.print(",z={d}", .{opts.z});
                if (opts.x_offset) |xo| try writer.print(",X={d}", .{xo});
                if (opts.y_offset) |yo| try writer.print(",Y={d}", .{yo});

                // Don't move cursor after displaying
                try writer.writeAll(",C=1");

                first_chunk = false;
            } else {
                // Continuation chunks: only need m flag (and i for safety)
                try writer.print("m={d}", .{if (is_last) @as(u8, 0) else @as(u8, 1)});
            }

            // Send payload for this chunk
            try writer.writeByte(';');
            try writer.writeAll(base64_data[offset..offset + chunk_len]);
            try writer.writeAll("\x1b\\");

            offset += chunk_len;
        }

        return image_id;
    }

    /// Display already base64-encoded image data directly
    /// Uses chunked transfer for large images (Kitty protocol requirement)
    pub fn displayBase64Image(
        self: *KittyGraphics,
        writer: anytype,
        base64_data: []const u8,
        opts: DisplayOptions,
    ) !u32 {
        return self.displayBase64ImageWithFormat(writer, base64_data, opts, 32);
    }

    /// Alias for backwards compatibility
    pub fn displayBase64PNG(
        self: *KittyGraphics,
        writer: anytype,
        base64_data: []const u8,
        opts: DisplayOptions,
    ) !u32 {
        return self.displayBase64ImageWithFormat(writer, base64_data, opts, 100);
    }
    /// Display raw RGBA pixel data from memory
    pub fn displayRawRGBA(
        self: *KittyGraphics,
        writer: anytype,
        rgba_data: []const u8,
        width: u32,
        height: u32,
        opts: DisplayOptions,
    ) !u32 {
        const encoder = std.base64.standard.Encoder;
        const encoded_len = encoder.calcSize(rgba_data.len);
        const encoded = try self.allocator.alloc(u8, encoded_len);
        defer self.allocator.free(encoded);
        _ = encoder.encode(encoded, rgba_data);

        var local_opts = opts;
        if (local_opts.width == null) local_opts.width = width;
        if (local_opts.height == null) local_opts.height = height;

        return self.displayBase64ImageWithFormat(writer, encoded, local_opts, 32);
    }

    /// Display raw RGBA data via SHM (t=s)
    /// Uses fixed image_id to replace existing image data (no delete needed)
    pub fn displayRGBA(
        self: *KittyGraphics,
        writer: anytype,
        shm: *const ShmBuffer,
        width: u32,
        height: u32,
        opts: DisplayOptions,
    ) !u32 {
        const image_id = opts.image_id orelse blk: {
            const id = self.next_image_id;
            self.next_image_id += 1;
            break :blk id;
        };

        // Use proper POSIX Shared Memory (t=s)
        // Data is already in the buffer via shm.write()
        const shm_name = shm.getName();

        // Write Kitty graphics escape sequence
        try writer.writeAll("\x1b_G");

        // a=T (transmit + display), f=32 = raw RGBA, t=s = shared memory
        // Using same image_id replaces existing image data
        try writer.print("a=T,f=32,t=s,s={d},v={d},i={d},q=2", .{ width, height, image_id });

        // Placement options
        if (opts.placement_id) |p| try writer.print(",p={d}", .{p});
        if (opts.columns) |c_col| try writer.print(",c={d}", .{c_col});
        if (opts.rows) |r| try writer.print(",r={d}", .{r});
        if (opts.z != 0) try writer.print(",z={d}", .{opts.z});
        if (opts.x_offset) |xo| try writer.print(",X={d}", .{xo});
        if (opts.y_offset) |yo| try writer.print(",Y={d}", .{yo});

        // Don't move cursor
        try writer.writeAll(",C=1");

        // SHM name must be base64 encoded
        try writer.writeByte(';');
        const encoder = std.base64.standard.Encoder;
        var encoded_buf: [256]u8 = undefined;
        const encoded = encoder.encode(&encoded_buf, shm_name);
        try writer.writeAll(encoded);
        try writer.writeAll("\x1b\\");

        return image_id;
    }

    /// Decode base64 image and display via SHM (decode once, zero-copy transfer)
    /// Returns null if decode fails, image_id on success
    pub fn displayBase64ImageViaSHM(
        self: *KittyGraphics,
        writer: anytype,
        base64_data: []const u8,
        shm: *ShmBuffer,
        opts: DisplayOptions,
    ) !?u32 {
        // Decode base64 to get raw bytes
        const decoder = std.base64.standard.Decoder;
        const decoded_len = decoder.calcSizeForSlice(base64_data) catch return null;

        // Use stack buffer for small images, allocate for large
        var stack_buf: [256 * 1024]u8 = undefined;
        var decoded: []u8 = undefined;
        var heap_buf: ?[]u8 = null;
        defer if (heap_buf) |buf| self.allocator.free(buf);

        if (decoded_len <= stack_buf.len) {
            decoded = stack_buf[0..decoded_len];
        } else {
            heap_buf = try self.allocator.alloc(u8, decoded_len);
            decoded = heap_buf.?;
        }

        decoder.decode(decoded, base64_data) catch return null;

        // Decode image to RGBA
        var img = decode.decode(decoded) orelse return null;
        defer img.deinit();

        // Write RGBA to SHM
        shm.write(img.data);

        // Display via SHM
        return try self.displayRGBA(writer, shm, img.width, img.height, opts);
    }
};
