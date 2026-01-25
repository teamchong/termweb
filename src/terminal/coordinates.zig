const std = @import("std");

/// Debug logging for coordinate mapping - writes to file
var debug_file: ?std.fs.File = null;
var debug_counter: u32 = 0;

fn debugLog(comptime fmt: []const u8, args: anytype) void {
    debug_counter += 1;
    // Log every 5th call to reduce spam but still capture enough data
    if (debug_counter % 5 != 1) return;

    if (debug_file == null) {
        debug_file = std.fs.createFileAbsolute("/tmp/coord_debug.log", .{ .truncate = true }) catch return;
    }
    if (debug_file) |f| {
        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "[{d}] " ++ fmt ++ "\n", .{debug_counter} ++ args) catch return;
        _ = f.write(msg) catch {};
        f.sync() catch {}; // Flush immediately
    }
}

/// Coordinate mapping between terminal pixel space and browser viewport space.
///
/// Terminal space: (0,0) to (width_px, height_px) - from TIOCGWINSZ
/// Display space: (0,0) to (width_px, height_px - status_line_height) - where graphics render
/// Frame space: (0,0) to (frame_width, frame_height) - displayed screencast frame dimensions
/// Browser viewport: (0,0) to (chrome_width, chrome_height) - Chrome's actual viewport
///
/// Mapping: Terminal pixels -> Frame pixels -> Chrome pixels
pub const CoordinateMapper = struct {
    terminal_width_px: u16,
    terminal_height_px: u16,
    terminal_cols: u16,
    terminal_rows: u16,
    frame_width: u32, // Displayed frame dimensions
    frame_height: u32,
    chrome_width: u32, // Chrome's actual viewport (for output coords)
    chrome_height: u32,
    cell_height: u16,
    tabbar_height: u16,
    tabbar_rows: u16, // Number of rows toolbar occupies
    content_pixel_height: u16, // Actual rendered content height

    is_pixel_mode: bool,

    /// Initialize coordinate mapper with terminal and viewport dimensions (legacy)
    /// Uses same dimensions for frame and chrome (no scaling)
    pub fn init(
        terminal_width_px: u16,
        terminal_height_px: u16,
        terminal_cols: u16,
        terminal_rows: u16,
        viewport_width: u32,
        viewport_height: u32,
    ) CoordinateMapper {
        return initWithToolbar(terminal_width_px, terminal_height_px, terminal_cols, terminal_rows, viewport_width, viewport_height, null, null);
    }

    /// Initialize coordinate mapper with explicit toolbar height and pixel mode (legacy)
    /// Uses same dimensions for frame and chrome (no scaling)
    pub fn initWithToolbar(
        terminal_width_px: u16,
        terminal_height_px: u16,
        terminal_cols: u16,
        terminal_rows: u16,
        viewport_width: u32,
        viewport_height: u32,
        toolbar_height: ?u16,
        pixel_mode: ?bool,
    ) CoordinateMapper {
        // Legacy: use same dimensions for frame and chrome
        return initFull(terminal_width_px, terminal_height_px, terminal_cols, terminal_rows, viewport_width, viewport_height, viewport_width, viewport_height, toolbar_height, pixel_mode, null);
    }

    /// Initialize coordinate mapper with separate frame and chrome dimensions
    /// frame_width/height: displayed screencast frame dimensions
    /// chrome_width/height: Chrome's actual viewport (output coordinate space)
    /// content_height_override: if provided, use this instead of calculating from terminal height
    pub fn initFull(
        terminal_width_px: u16,
        terminal_height_px: u16,
        terminal_cols: u16,
        terminal_rows: u16,
        frame_width: u32,
        frame_height: u32,
        chrome_width: u32,
        chrome_height: u32,
        toolbar_height: ?u16,
        pixel_mode: ?bool,
        content_height_override: ?u16,
    ) CoordinateMapper {
        // Calculate cell dimensions
        const cell_height: u16 = if (terminal_rows > 0)
            @divTrunc(terminal_height_px, terminal_rows)
        else
            20; // fallback

        // Use explicit toolbar height if provided, otherwise default to 1 row
        const tabbar_h: u16 = toolbar_height orelse cell_height;

        // Calculate how many rows the toolbar occupies (round up)
        const tabbar_rows: u16 = (tabbar_h + cell_height - 1) / cell_height;

        // Content area: use override if provided, otherwise calculate from terminal height
        const content_pixel_height: u16 = content_height_override orelse blk: {
            const content_available: u16 = if (terminal_height_px > tabbar_h)
                terminal_height_px - tabbar_h
            else
                terminal_height_px;
            const content_rows: u16 = content_available / cell_height;
            break :blk content_rows * cell_height;
        };

        // Determine pixel mode: use explicit setting, or auto-detect based on terminal size
        // Note: Ghostty reports pixel dimensions but uses cell-based mouse coords, so
        // callers should pass pixel_mode=false for Ghostty
        const is_pixel_mode = pixel_mode orelse (terminal_width_px > 0);

        return CoordinateMapper{
            .terminal_width_px = terminal_width_px,
            .terminal_height_px = terminal_height_px,
            .terminal_cols = terminal_cols,
            .terminal_rows = terminal_rows,
            .frame_width = frame_width,
            .frame_height = frame_height,
            .chrome_width = chrome_width,
            .chrome_height = chrome_height,
            .cell_height = cell_height,
            .tabbar_height = tabbar_h,
            .tabbar_rows = tabbar_rows,
            .content_pixel_height = content_pixel_height,
            .is_pixel_mode = is_pixel_mode,
        };
    }

    /// Convert cell coordinates (column/row) to pixel coordinates
    pub fn cellToPixel(
        self: *const CoordinateMapper,
        col: u16,
        row: u16,
    ) struct { x: u16, y: u16 } {
        // Calculate cell dimensions
        const cell_width = if (self.terminal_cols > 0)
            @divTrunc(self.terminal_width_px, self.terminal_cols)
        else
            14; // Fallback

        const cell_height = if (self.terminal_rows > 0)
            @divTrunc(self.terminal_height_px, self.terminal_rows)
        else
            14; // Fallback

        // ANSI coordinates are 1-indexed
        const c_x = if (col > 0) col - 1 else 0;
        const c_y = if (row > 0) row - 1 else 0;

        // Convert to pixel coordinates (center of cell)
        const pixel_x = c_x * cell_width + cell_width / 2;
        const pixel_y = c_y * cell_height + cell_height / 2;

        return .{ .x = pixel_x, .y = pixel_y };
    }

    /// Convert terminal coordinates to browser viewport coordinates.
    /// Handles both pixel coordinates (SGR 1016h) and cell
    /// coordinates (SGR 1006h fallback).
    /// Returns null if the coordinates are in the tab bar, status bar, or letterbox padding.
    pub fn terminalToBrowser(
        self: *const CoordinateMapper,
        pixel_x_in: u16,
        pixel_y_in: u16,
    ) ?struct { x: u32, y: u32 } {
        var pixel_x: u16 = undefined;
        var pixel_y: u16 = undefined;

        if (self.is_pixel_mode) {
            // Already pixels (expecting 0-indexed)
            pixel_x = pixel_x_in;
            pixel_y = pixel_y_in;
        } else {
            // Convert cell coordinates to pixel coordinates (center of cell)
            const cell_width = if (self.terminal_cols > 0)
                @divTrunc(self.terminal_width_px, self.terminal_cols)
            else
                14;

            pixel_x = pixel_x_in * cell_width + cell_width / 2;
            pixel_y = pixel_y_in * self.cell_height + self.cell_height / 2;
        }

        // Check if click is in tab bar (top) - use actual toolbar pixel height for hit detection
        if (pixel_y < self.tabbar_height) return null;

        // Content graphic starts right after toolbar (using actual pixel height)
        const content_top = self.tabbar_height;
        const content_bottom = content_top + self.content_pixel_height;

        // Check if click is in status bar (bottom)
        if (pixel_y >= content_bottom) return null;

        // Adjust Y coordinate to content space (subtract content top, not toolbar height)
        const content_y = if (pixel_y >= content_top) pixel_y - content_top else 0;

        // Prevent division by zero
        if (self.terminal_width_px == 0 or self.content_pixel_height == 0) return null;
        if (self.frame_width == 0 or self.frame_height == 0) return null;
        if (self.chrome_width == 0 or self.chrome_height == 0) return null;

        // Use floating point for precise coordinate mapping to avoid sub-pixel rounding errors
        // (Terminal width may not be evenly divisible by DPR, causing accumulated offset)
        const pixel_x_f: f64 = @floatFromInt(pixel_x);
        const content_y_f: f64 = @floatFromInt(content_y);
        const term_w_f: f64 = @floatFromInt(self.terminal_width_px);
        const content_h_f: f64 = @floatFromInt(self.content_pixel_height);
        const frame_w_f: f64 = @floatFromInt(self.frame_width);
        const frame_h_f: f64 = @floatFromInt(self.frame_height);
        const chrome_w_f: f64 = @floatFromInt(self.chrome_width);
        const chrome_h_f: f64 = @floatFromInt(self.chrome_height);

        // Direct mapping: Terminal pixels -> Chrome CSS pixels (single calculation for precision)
        // browser_x = (pixel_x / terminal_width) * chrome_width
        const browser_x_f = (pixel_x_f * chrome_w_f) / term_w_f;
        const browser_y_f = (content_y_f * chrome_h_f) / content_h_f;

        // Round to nearest integer (avoid truncation bias)
        var browser_x: u32 = @intFromFloat(@round(browser_x_f));
        var browser_y: u32 = @intFromFloat(@round(browser_y_f));

        // Also compute frame coords for debug logging
        const frame_x: u32 = @intFromFloat(@round((pixel_x_f * frame_w_f) / term_w_f));
        const frame_y: u32 = @intFromFloat(@round((content_y_f * frame_h_f) / content_h_f));

        debugLog("raw=({},{}) px=({},{}) cy={} -> frame=({},{}) -> chrome=({},{}) term={}x{} content_h={} toolbar={} frame={}x{} chrome={}x{} pixel_mode={}", .{
            pixel_x_in, pixel_y_in,
            pixel_x, pixel_y,
            content_y,
            frame_x, frame_y,
            browser_x, browser_y,
            self.terminal_width_px, self.terminal_height_px,
            self.content_pixel_height, self.tabbar_height,
            self.frame_width, self.frame_height,
            self.chrome_width, self.chrome_height,
            self.is_pixel_mode,
        });

        // Clamp to Chrome viewport bounds
        browser_x = @min(browser_x, self.chrome_width -| 1);
        browser_y = @min(browser_y, self.chrome_height -| 1);

        return .{ .x = browser_x, .y = browser_y };
    }
};
