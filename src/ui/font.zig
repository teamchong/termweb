/// Font rendering using stb_truetype
/// Renders text directly to RGBA buffers for Kitty graphics
const std = @import("std");

const c = @cImport({
    @cInclude("stb_truetype.h");
});

pub const FontRenderer = struct {
    allocator: std.mem.Allocator,
    font_info: c.stbtt_fontinfo,
    font_data: []u8,
    scale: f32,
    ascent: i32,
    descent: i32,
    line_gap: i32,

    /// Initialize font renderer with system font
    pub fn init(allocator: std.mem.Allocator, font_size: f32) !FontRenderer {
        // Try to load SF Pro or fallback to Helvetica
        const font_paths = [_][]const u8{
            "/System/Library/Fonts/SFNS.ttf",
            "/System/Library/Fonts/Helvetica.ttc",
            "/System/Library/Fonts/HelveticaNeue.ttc",
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", // Linux fallback
        };

        var font_data: []u8 = undefined;
        var loaded = false;

        for (font_paths) |path| {
            const file = std.fs.openFileAbsolute(path, .{}) catch continue;
            defer file.close();

            const stat = file.stat() catch continue;
            if (stat.size > 50 * 1024 * 1024) continue; // Skip files > 50MB

            font_data = allocator.alloc(u8, stat.size) catch continue;

            const read = file.readAll(font_data) catch {
                allocator.free(font_data);
                continue;
            };
            if (read != stat.size) {
                allocator.free(font_data);
                continue;
            }

            loaded = true;
            break;
        }

        if (!loaded) {
            return error.FontNotFound;
        }

        // For TTC files, get the offset of the first font
        const font_offset = c.stbtt_GetFontOffsetForIndex(font_data.ptr, 0);
        if (font_offset < 0) {
            allocator.free(font_data);
            return error.FontInitFailed;
        }

        var font_info: c.stbtt_fontinfo = undefined;
        if (c.stbtt_InitFont(&font_info, font_data.ptr, font_offset) == 0) {
            allocator.free(font_data);
            return error.FontInitFailed;
        }

        const scale = c.stbtt_ScaleForPixelHeight(&font_info, font_size);

        var ascent: c_int = undefined;
        var descent: c_int = undefined;
        var line_gap: c_int = undefined;
        c.stbtt_GetFontVMetrics(&font_info, &ascent, &descent, &line_gap);

        return .{
            .allocator = allocator,
            .font_info = font_info,
            .font_data = font_data,
            .scale = scale,
            .ascent = ascent,
            .descent = descent,
            .line_gap = line_gap,
        };
    }

    pub fn deinit(self: *FontRenderer) void {
        self.allocator.free(self.font_data);
    }

    /// Get scaled line height
    pub fn getLineHeight(self: *const FontRenderer) u32 {
        const scaled_ascent: f32 = @as(f32, @floatFromInt(self.ascent)) * self.scale;
        const scaled_descent: f32 = @as(f32, @floatFromInt(self.descent)) * self.scale;
        const height = scaled_ascent - scaled_descent;
        return if (height > 0) @intFromFloat(height) else 14;
    }

    /// Measure text width
    pub fn measureText(self: *const FontRenderer, text: []const u8) u32 {
        var width: f32 = 0;

        for (text, 0..) |char, i| {
            if (char < 32 or char > 126) continue;

            var advance: c_int = undefined;
            var lsb: c_int = undefined;
            c.stbtt_GetCodepointHMetrics(&self.font_info, char, &advance, &lsb);

            width += @as(f32, @floatFromInt(advance)) * self.scale;

            // Kerning
            if (i + 1 < text.len) {
                const kern = c.stbtt_GetCodepointKernAdvance(&self.font_info, char, text[i + 1]);
                width += @as(f32, @floatFromInt(kern)) * self.scale;
            }
        }

        return if (width > 0) @intFromFloat(width) else 0;
    }

    /// Render text to existing RGBA buffer at position
    /// Color is [r, g, b, a]
    pub fn renderTextToBuffer(
        self: *const FontRenderer,
        buffer: []u8,
        buf_width: u32,
        buf_height: u32,
        text: []const u8,
        x_start: u32,
        y_start: u32,
        color: [4]u8,
    ) void {
        var x: f32 = @floatFromInt(x_start);
        const baseline: f32 = @as(f32, @floatFromInt(y_start)) + @as(f32, @floatFromInt(self.ascent)) * self.scale;

        for (text, 0..) |char, i| {
            if (char < 32 or char > 126) continue;

            var x0: c_int = undefined;
            var y0: c_int = undefined;
            var x1: c_int = undefined;
            var y1: c_int = undefined;
            c.stbtt_GetCodepointBitmapBox(
                &self.font_info,
                char,
                self.scale,
                self.scale,
                &x0,
                &y0,
                &x1,
                &y1,
            );

            // Skip if invalid dimensions
            if (x1 <= x0 or y1 <= y0) {
                // Still advance x for space characters
                var advance: c_int = undefined;
                var lsb: c_int = undefined;
                c.stbtt_GetCodepointHMetrics(&self.font_info, char, &advance, &lsb);
                x += @as(f32, @floatFromInt(advance)) * self.scale;
                continue;
            }

            const glyph_width: u32 = @intCast(x1 - x0);
            const glyph_height: u32 = @intCast(y1 - y0);

            if (glyph_width > 0 and glyph_height > 0 and glyph_width < 200 and glyph_height < 200) {
                // Render glyph to temp buffer
                const glyph_buf = self.allocator.alloc(u8, glyph_width * glyph_height) catch {
                    var advance: c_int = undefined;
                    var lsb: c_int = undefined;
                    c.stbtt_GetCodepointHMetrics(&self.font_info, char, &advance, &lsb);
                    x += @as(f32, @floatFromInt(advance)) * self.scale;
                    continue;
                };
                defer self.allocator.free(glyph_buf);

                c.stbtt_MakeCodepointBitmap(
                    &self.font_info,
                    glyph_buf.ptr,
                    @intCast(glyph_width),
                    @intCast(glyph_height),
                    @intCast(glyph_width),
                    self.scale,
                    self.scale,
                    char,
                );

                // Blend glyph into main buffer
                const gx: i32 = @intFromFloat(x + @as(f32, @floatFromInt(x0)));
                const gy: i32 = @intFromFloat(baseline + @as(f32, @floatFromInt(y0)));

                var py: u32 = 0;
                while (py < glyph_height) : (py += 1) {
                    const dst_y = @as(i32, @intCast(py)) + gy;
                    if (dst_y < 0 or dst_y >= @as(i32, @intCast(buf_height))) continue;

                    var px: u32 = 0;
                    while (px < glyph_width) : (px += 1) {
                        const dst_x = @as(i32, @intCast(px)) + gx;
                        if (dst_x < 0 or dst_x >= @as(i32, @intCast(buf_width))) continue;

                        const src_idx = py * glyph_width + px;
                        const alpha = glyph_buf[src_idx];
                        if (alpha == 0) continue;

                        const dst_idx = (@as(u32, @intCast(dst_y)) * buf_width + @as(u32, @intCast(dst_x))) * 4;
                        if (dst_idx + 3 >= buffer.len) continue;

                        // Alpha blend
                        const alpha_f = @as(f32, @floatFromInt(alpha)) / 255.0;
                        const inv_alpha = 1.0 - alpha_f;

                        buffer[dst_idx] = @intFromFloat(@as(f32, @floatFromInt(color[0])) * alpha_f + @as(f32, @floatFromInt(buffer[dst_idx])) * inv_alpha);
                        buffer[dst_idx + 1] = @intFromFloat(@as(f32, @floatFromInt(color[1])) * alpha_f + @as(f32, @floatFromInt(buffer[dst_idx + 1])) * inv_alpha);
                        buffer[dst_idx + 2] = @intFromFloat(@as(f32, @floatFromInt(color[2])) * alpha_f + @as(f32, @floatFromInt(buffer[dst_idx + 2])) * inv_alpha);
                        buffer[dst_idx + 3] = @max(buffer[dst_idx + 3], alpha);
                    }
                }
            }

            // Advance x position
            var advance: c_int = undefined;
            var lsb: c_int = undefined;
            c.stbtt_GetCodepointHMetrics(&self.font_info, char, &advance, &lsb);
            x += @as(f32, @floatFromInt(advance)) * self.scale;

            // Kerning
            if (i + 1 < text.len) {
                const kern = c.stbtt_GetCodepointKernAdvance(&self.font_info, char, text[i + 1]);
                x += @as(f32, @floatFromInt(kern)) * self.scale;
            }
        }
    }

    /// Render text cursor (line cursor) at position
    pub fn renderCursor(
        self: *const FontRenderer,
        buffer: []u8,
        buf_width: u32,
        buf_height: u32,
        text: []const u8,
        cursor_pos: u32,
        x_start: u32,
        y_start: u32,
        cursor_color: [4]u8,
        _: [4]u8, // text_color unused for line cursor
    ) void {
        // Calculate cursor x position
        var cursor_x: f32 = @floatFromInt(x_start);

        const end_pos = @min(cursor_pos, @as(u32, @intCast(text.len)));
        if (end_pos > 0) {
            for (text[0..end_pos]) |char| {
                if (char < 32 or char > 126) continue;

                var advance: c_int = undefined;
                var lsb: c_int = undefined;
                c.stbtt_GetCodepointHMetrics(&self.font_info, char, &advance, &lsb);
                cursor_x += @as(f32, @floatFromInt(advance)) * self.scale;
            }
        }

        const line_height = self.getLineHeight();
        const cursor_width: u32 = 2; // Thin line cursor

        // Draw cursor rectangle
        const cx: u32 = @intFromFloat(@max(0, cursor_x));
        var py: u32 = 0;
        while (py < line_height) : (py += 1) {
            const dst_y = y_start + py;
            if (dst_y >= buf_height) continue;

            var px: u32 = 0;
            while (px < cursor_width) : (px += 1) {
                const dst_x = cx + px;
                if (dst_x >= buf_width) continue;

                const dst_idx = (dst_y * buf_width + dst_x) * 4;
                if (dst_idx + 3 >= buffer.len) continue;

                buffer[dst_idx] = cursor_color[0];
                buffer[dst_idx + 1] = cursor_color[1];
                buffer[dst_idx + 2] = cursor_color[2];
                buffer[dst_idx + 3] = cursor_color[3];
            }
        }
    }
};
