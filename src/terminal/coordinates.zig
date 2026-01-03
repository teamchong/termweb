const std = @import("std");

/// Coordinate mapping between terminal pixel space and browser viewport space.
///
/// Terminal space: (0,0) to (width_px, height_px) - from TIOCGWINSZ
/// Display space: (0,0) to (width_px, height_px - status_line_height) - where graphics render
/// Browser viewport: (0,0) to (viewport_width, viewport_height) - set in cli.zig
pub const CoordinateMapper = struct {
    terminal_width_px: u16,
    terminal_height_px: u16,
    terminal_cols: u16,
    terminal_rows: u16,
    viewport_width: u32,
    viewport_height: u32,
    cell_height: u16,
    tabbar_height: u16,
    content_pixel_height: u16, // Actual rendered content height

    /// Initialize coordinate mapper with terminal and viewport dimensions
    pub fn init(
        terminal_width_px: u16,
        terminal_height_px: u16,
        terminal_cols: u16,
        terminal_rows: u16,
        viewport_width: u32,
        viewport_height: u32,
    ) CoordinateMapper {
        // Calculate cell height (one row)
        const cell_height: u16 = if (terminal_rows > 0)
            @divTrunc(terminal_height_px, terminal_rows)
        else
            20; // fallback

        // Content rows = total rows - tab bar - status bar
        const content_rows: u16 = if (terminal_rows > 2) terminal_rows - 2 else 1;
        // Actual pixel height the image is rendered in
        const content_pixel_height = content_rows * cell_height;

        return CoordinateMapper{
            .terminal_width_px = terminal_width_px,
            .terminal_height_px = terminal_height_px,
            .terminal_cols = terminal_cols,
            .terminal_rows = terminal_rows,
            .viewport_width = viewport_width,
            .viewport_height = viewport_height,
            .cell_height = cell_height,
            .tabbar_height = cell_height, // 1 row for tab bar
            .content_pixel_height = content_pixel_height,
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

        // Convert to pixel coordinates (center of cell)
        const pixel_x = col * cell_width;
        const pixel_y = row * cell_height;

        return .{ .x = pixel_x, .y = pixel_y };
    }

    /// Convert terminal pixel coordinates to browser viewport coordinates.
    /// With SGR pixel mode (1016h), coordinates are actual pixels.
    /// Returns null if the coordinates are in the tab bar, status bar, or letterbox padding.
    pub fn terminalToBrowser(
        self: *const CoordinateMapper,
        term_x: u16,
        term_y: u16,
    ) ?struct { x: u32, y: u32 } {
        const pixel_x = term_x;
        const pixel_y = term_y;

        // Check if click is in tab bar (top)
        if (pixel_y < self.tabbar_height) return null;

        // Content area starts after tab bar
        const content_top = self.tabbar_height;
        const content_bottom = content_top + self.content_pixel_height;

        // Check if click is in status bar (bottom)
        if (pixel_y >= content_bottom) return null;

        // Adjust Y coordinate to content space (subtract tab bar)
        const content_y = pixel_y - content_top;

        // Prevent division by zero
        if (self.terminal_width_px == 0 or self.content_pixel_height == 0) return null;

        // Kitty stretches image to fit content area (content_rows * cell_height)
        // Scale from terminal content pixels to browser viewport
        var browser_x = (@as(u32, pixel_x) * self.viewport_width) / self.terminal_width_px;
        var browser_y = (@as(u32, content_y) * self.viewport_height) / self.content_pixel_height;

        // Clamp to viewport bounds
        browser_x = @min(browser_x, self.viewport_width -| 1);
        browser_y = @min(browser_y, self.viewport_height -| 1);

        return .{ .x = browser_x, .y = browser_y };
    }
};
