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

    is_pixel_mode: bool,

    /// Initialize coordinate mapper with terminal and viewport dimensions
    pub fn init(
        terminal_width_px: u16,
        terminal_height_px: u16,
        terminal_cols: u16,
        terminal_rows: u16,
        viewport_width: u32,
        viewport_height: u32,
    ) CoordinateMapper {
        return initWithToolbar(terminal_width_px, terminal_height_px, terminal_cols, terminal_rows, viewport_width, viewport_height, null);
    }

    /// Initialize coordinate mapper with explicit toolbar height
    pub fn initWithToolbar(
        terminal_width_px: u16,
        terminal_height_px: u16,
        terminal_cols: u16,
        terminal_rows: u16,
        viewport_width: u32,
        viewport_height: u32,
        toolbar_height: ?u16,
    ) CoordinateMapper {
        // Calculate cell dimensions
        const cell_height: u16 = if (terminal_rows > 0)
            @divTrunc(terminal_height_px, terminal_rows)
        else
            20; // fallback

        // Use explicit toolbar height if provided, otherwise default to 1 row
        // This is used for HIT DETECTION only
        const tabbar_h: u16 = toolbar_height orelse cell_height;

        // Content area: rows 2 to end, i.e., (rows-1) rows
        // Only toolbar row is reserved at top
        const content_rows = if (terminal_rows > 1) terminal_rows - 1 else 1;
        const content_pixel_height = content_rows * cell_height;

        // If terminal reports pixel dimensions, assume we're using SGR pixel mode (1016h)
        const is_pixel_mode = terminal_width_px > 0;

        return CoordinateMapper{
            .terminal_width_px = terminal_width_px,
            .terminal_height_px = terminal_height_px,
            .terminal_cols = terminal_cols,
            .terminal_rows = terminal_rows,
            .viewport_width = viewport_width,
            .viewport_height = viewport_height,
            .cell_height = cell_height,
            .tabbar_height = tabbar_h,
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

        // Content graphic starts at row 2 (cell_height pixels from top)
        // This is where coordinate mapping happens, independent of toolbar visual height
        const content_top = self.cell_height;
        const content_bottom = content_top + self.content_pixel_height;

        // Check if click is in status bar (bottom)
        if (pixel_y >= content_bottom) return null;

        // Adjust Y coordinate to content space (subtract content top, not toolbar height)
        const content_y = if (pixel_y >= content_top) pixel_y - content_top else 0;

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
