/// Toolbar rendering using Kitty graphics protocol
/// Renders macOS-style SVG button images with proper font rendering
const std = @import("std");
const kitty_mod = @import("../terminal/kitty_graphics.zig");
const svg_mod = @import("svg.zig");
const font_mod = @import("font.zig");

const KittyGraphics = kitty_mod.KittyGraphics;
const ToolbarCache = svg_mod.ToolbarCache;
const FontRenderer = font_mod.FontRenderer;

/// Toolbar dimensions
pub const TOOLBAR_HEIGHT: u32 = 40;
pub const BUTTON_SIZE: u32 = 28;
pub const BUTTON_PADDING: u32 = 8;
pub const URL_BAR_HEIGHT: u32 = 28;

/// Placement IDs for toolbar elements
pub const Placement = struct {
    pub const TOOLBAR_BG: u32 = 100;
    pub const CLOSE_BTN: u32 = 101;
    pub const BACK_BTN: u32 = 102;
    pub const FWD_BTN: u32 = 103;
    pub const REFRESH_BTN: u32 = 104;
    pub const URL_BAR: u32 = 105;
};

/// Button state
pub const ButtonState = enum {
    normal,
    hover,
    active,
    disabled,
};

/// Button icons
pub const ButtonIcon = enum {
    close,
    back,
    forward,
    refresh,
};

/// Toolbar renderer using Kitty graphics and SVG
pub const ToolbarRenderer = struct {
    allocator: std.mem.Allocator,
    kitty: *KittyGraphics,
    width_px: u32,
    cell_width: u32,
    svg_cache: ToolbarCache,
    font_renderer: ?FontRenderer,

    // Current states
    close_hover: bool = false,
    can_go_back: bool = false,
    can_go_forward: bool = false,
    is_loading: bool = false,

    // URL state
    current_url: []const u8 = "",
    url_focused: bool = false,
    url_buffer: [512]u8 = undefined,
    url_len: u32 = 0,
    url_cursor: u32 = 0,

    // Cached image IDs
    bg_image_id: ?u32 = null,

    // Layout info
    url_bar_x: u32 = 0,
    url_bar_width: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, kitty: *KittyGraphics, width_px: u32, cell_width: u32) !ToolbarRenderer {
        // Initialize font renderer (14px for URL bar text)
        const font = FontRenderer.init(allocator, 14.0) catch null;

        return .{
            .allocator = allocator,
            .kitty = kitty,
            .width_px = width_px,
            .cell_width = if (cell_width > 0) cell_width else 10,
            .svg_cache = try ToolbarCache.init(allocator),
            .font_renderer = font,
        };
    }

    pub fn deinit(self: *ToolbarRenderer) void {
        if (self.font_renderer) |*font| {
            font.deinit();
        }
        self.svg_cache.deinit();
    }

    pub fn setNavState(self: *ToolbarRenderer, can_back: bool, can_forward: bool, loading: bool) void {
        self.can_go_back = can_back;
        self.can_go_forward = can_forward;
        self.is_loading = loading;
    }

    pub fn setUrl(self: *ToolbarRenderer, url: []const u8) void {
        self.current_url = url;
        // Copy to edit buffer if not focused
        if (!self.url_focused) {
            const copy_len = @min(url.len, self.url_buffer.len);
            @memcpy(self.url_buffer[0..copy_len], url[0..copy_len]);
            self.url_len = @intCast(copy_len);
            self.url_cursor = @intCast(copy_len);
        }
    }

    pub fn focusUrl(self: *ToolbarRenderer) void {
        self.url_focused = true;
        // Select all on focus
        self.url_cursor = self.url_len;
    }

    pub fn blurUrl(self: *ToolbarRenderer) void {
        self.url_focused = false;
    }

    pub fn getUrlText(self: *ToolbarRenderer) []const u8 {
        return self.url_buffer[0..self.url_len];
    }

    pub fn handleChar(self: *ToolbarRenderer, char: u8) void {
        if (!self.url_focused) return;
        if (char < 32 or char > 126) return;
        if (self.url_len >= self.url_buffer.len - 1) return;

        // Insert at cursor
        if (self.url_cursor < self.url_len) {
            var i = self.url_len;
            while (i > self.url_cursor) : (i -= 1) {
                self.url_buffer[i] = self.url_buffer[i - 1];
            }
        }
        self.url_buffer[self.url_cursor] = char;
        self.url_cursor += 1;
        self.url_len += 1;
    }

    pub fn handleBackspace(self: *ToolbarRenderer) void {
        if (!self.url_focused) return;
        if (self.url_cursor > 0) {
            var i = self.url_cursor - 1;
            while (i < self.url_len - 1) : (i += 1) {
                self.url_buffer[i] = self.url_buffer[i + 1];
            }
            self.url_cursor -= 1;
            self.url_len -= 1;
        }
    }

    pub fn handleLeft(self: *ToolbarRenderer) void {
        if (self.url_cursor > 0) self.url_cursor -= 1;
    }

    pub fn handleRight(self: *ToolbarRenderer) void {
        if (self.url_cursor < self.url_len) self.url_cursor += 1;
    }

    pub fn handleHome(self: *ToolbarRenderer) void {
        self.url_cursor = 0;
    }

    pub fn handleEnd(self: *ToolbarRenderer) void {
        self.url_cursor = self.url_len;
    }

    /// Render the toolbar using Kitty graphics
    pub fn render(self: *ToolbarRenderer, writer: anytype) !void {
        // Move to top-left
        try writer.writeAll("\x1b[1;1H");

        // Render toolbar background (dark bar)
        const bg_rgba = try generateToolbarBg(self.allocator, self.width_px, TOOLBAR_HEIGHT);
        defer self.allocator.free(bg_rgba);

        self.bg_image_id = try self.kitty.displayRawRGBA(writer, bg_rgba, self.width_px, TOOLBAR_HEIGHT, .{
            .placement_id = Placement.TOOLBAR_BG,
            .z = 50,
        });

        // Button positions
        var x_offset: u32 = BUTTON_PADDING;
        const y_offset: u32 = (TOOLBAR_HEIGHT - BUTTON_SIZE) / 2;

        // Close button (red traffic light)
        const close_rgba = try self.svg_cache.getCloseButton(self.close_hover);
        _ = try self.kitty.displayRawRGBA(writer, close_rgba, BUTTON_SIZE, BUTTON_SIZE, .{
            .placement_id = Placement.CLOSE_BTN,
            .z = 51,
            .x_offset = x_offset,
            .y_offset = y_offset,
        });
        x_offset += BUTTON_SIZE + BUTTON_PADDING;

        // Back button
        const back_rgba = try self.svg_cache.getBackButton(self.can_go_back);
        _ = try self.kitty.displayRawRGBA(writer, back_rgba, BUTTON_SIZE, BUTTON_SIZE, .{
            .placement_id = Placement.BACK_BTN,
            .z = 51,
            .x_offset = x_offset,
            .y_offset = y_offset,
        });
        x_offset += BUTTON_SIZE + BUTTON_PADDING;

        // Forward button
        const forward_rgba = try self.svg_cache.getForwardButton(self.can_go_forward);
        _ = try self.kitty.displayRawRGBA(writer, forward_rgba, BUTTON_SIZE, BUTTON_SIZE, .{
            .placement_id = Placement.FWD_BTN,
            .z = 51,
            .x_offset = x_offset,
            .y_offset = y_offset,
        });
        x_offset += BUTTON_SIZE + BUTTON_PADDING;

        // Refresh button
        const refresh_rgba = try self.svg_cache.getRefreshButton(self.is_loading);
        _ = try self.kitty.displayRawRGBA(writer, refresh_rgba, BUTTON_SIZE, BUTTON_SIZE, .{
            .placement_id = Placement.REFRESH_BTN,
            .z = 51,
            .x_offset = x_offset,
            .y_offset = y_offset,
        });
        x_offset += BUTTON_SIZE + BUTTON_PADDING * 2;

        // URL bar (remaining width)
        self.url_bar_x = x_offset;
        self.url_bar_width = if (self.width_px > x_offset + BUTTON_PADDING) self.width_px - x_offset - BUTTON_PADDING else 200;

        // Generate URL bar with text rendered directly
        const display_text = if (self.url_focused)
            self.url_buffer[0..self.url_len]
        else
            self.current_url;

        const url_rgba = try self.generateUrlBarWithText(
            self.url_bar_width,
            URL_BAR_HEIGHT,
            display_text,
            if (self.url_focused) self.url_cursor else null,
        );
        defer self.allocator.free(url_rgba);

        _ = try self.kitty.displayRawRGBA(writer, url_rgba, self.url_bar_width, URL_BAR_HEIGHT, .{
            .placement_id = Placement.URL_BAR,
            .z = 51,
            .x_offset = x_offset,
            .y_offset = (TOOLBAR_HEIGHT - URL_BAR_HEIGHT) / 2,
        });
    }

    /// Generate URL bar with text rendered directly into the image
    fn generateUrlBarWithText(self: *ToolbarRenderer, width: u32, height: u32, text: []const u8, cursor_pos: ?u32) ![]u8 {
        const size = width * height * 4;
        const data = try self.allocator.alloc(u8, size);

        const bg_color = [3]u8{ 30, 30, 30 };
        const border_color = [3]u8{ 60, 60, 62 };
        const radius: u32 = 6;

        // Draw rounded rectangle background
        var y: u32 = 0;
        while (y < height) : (y += 1) {
            var x: u32 = 0;
            while (x < width) : (x += 1) {
                const idx = (y * width + x) * 4;

                var inside = true;
                var on_border = false;

                // Check corners
                if (x < radius and y < radius) {
                    const dx = radius - x;
                    const dy = radius - y;
                    inside = dx * dx + dy * dy <= radius * radius;
                    on_border = dx * dx + dy * dy >= (radius - 1) * (radius - 1);
                } else if (x >= width - radius and y < radius) {
                    const dx = x - (width - radius - 1);
                    const dy = radius - y;
                    inside = dx * dx + dy * dy <= radius * radius;
                    on_border = dx * dx + dy * dy >= (radius - 1) * (radius - 1);
                } else if (x < radius and y >= height - radius) {
                    const dx = radius - x;
                    const dy = y - (height - radius - 1);
                    inside = dx * dx + dy * dy <= radius * radius;
                    on_border = dx * dx + dy * dy >= (radius - 1) * (radius - 1);
                } else if (x >= width - radius and y >= height - radius) {
                    const dx = x - (width - radius - 1);
                    const dy = y - (height - radius - 1);
                    inside = dx * dx + dy * dy <= radius * radius;
                    on_border = dx * dx + dy * dy >= (radius - 1) * (radius - 1);
                } else {
                    on_border = (x == 0 or x == width - 1 or y == 0 or y == height - 1);
                }

                if (!inside) {
                    data[idx] = 0;
                    data[idx + 1] = 0;
                    data[idx + 2] = 0;
                    data[idx + 3] = 0;
                } else if (on_border) {
                    data[idx] = border_color[0];
                    data[idx + 1] = border_color[1];
                    data[idx + 2] = border_color[2];
                    data[idx + 3] = 255;
                } else {
                    data[idx] = bg_color[0];
                    data[idx + 1] = bg_color[1];
                    data[idx + 2] = bg_color[2];
                    data[idx + 3] = 255;
                }
            }
        }

        // Render text using font renderer
        if (self.font_renderer) |*font| {
            const text_padding: u32 = 8;
            const text_y: u32 = (height - font.getLineHeight()) / 2;

            // Text color (light gray)
            const text_color = [4]u8{ 200, 200, 200, 255 };

            // Render text
            if (text.len > 0) {
                font.renderTextToBuffer(data, width, height, text, text_padding, text_y, text_color);
            }

            // Render cursor if focused
            if (cursor_pos) |pos| {
                const cursor_color = [4]u8{ 255, 255, 255, 255 };
                const cursor_text_color = [4]u8{ 0, 0, 0, 255 };
                font.renderCursor(data, width, height, text, pos, text_padding, text_y, cursor_color, cursor_text_color);
            }
        }

        return data;
    }

    /// Get button at pixel position
    pub fn hitTest(_: *ToolbarRenderer, pixel_x: u32, pixel_y: u32) ?ButtonIcon {
        if (pixel_y > TOOLBAR_HEIGHT) return null;

        var x: u32 = BUTTON_PADDING;

        // Close button
        if (pixel_x >= x and pixel_x < x + BUTTON_SIZE) return .close;
        x += BUTTON_SIZE + BUTTON_PADDING;

        // Back button
        if (pixel_x >= x and pixel_x < x + BUTTON_SIZE) return .back;
        x += BUTTON_SIZE + BUTTON_PADDING;

        // Forward button
        if (pixel_x >= x and pixel_x < x + BUTTON_SIZE) return .forward;
        x += BUTTON_SIZE + BUTTON_PADDING;

        // Refresh button
        if (pixel_x >= x and pixel_x < x + BUTTON_SIZE) return .refresh;

        return null;
    }
};

/// Generate toolbar background RGBA
fn generateToolbarBg(allocator: std.mem.Allocator, width: u32, height: u32) ![]u8 {
    const size = width * height * 4;
    const data = try allocator.alloc(u8, size);

    // macOS-style dark toolbar gradient
    const top_color = [3]u8{ 58, 58, 60 };
    const bottom_color = [3]u8{ 44, 44, 46 };
    const border_color = [3]u8{ 30, 30, 30 };

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        // Linear interpolation for gradient
        const t = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(height));
        const r = @as(u8, @intFromFloat(@as(f32, @floatFromInt(top_color[0])) * (1 - t) + @as(f32, @floatFromInt(bottom_color[0])) * t));
        const g = @as(u8, @intFromFloat(@as(f32, @floatFromInt(top_color[1])) * (1 - t) + @as(f32, @floatFromInt(bottom_color[1])) * t));
        const b = @as(u8, @intFromFloat(@as(f32, @floatFromInt(top_color[2])) * (1 - t) + @as(f32, @floatFromInt(bottom_color[2])) * t));

        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const idx = (y * width + x) * 4;
            // Bottom border
            if (y == height - 1) {
                data[idx] = border_color[0];
                data[idx + 1] = border_color[1];
                data[idx + 2] = border_color[2];
            } else {
                data[idx] = r;
                data[idx + 1] = g;
                data[idx + 2] = b;
            }
            data[idx + 3] = 255;
        }
    }

    return data;
}
