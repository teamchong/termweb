/// Hint Mode - Vimium-style click navigation
///
/// Divides the viewport into a grid of clickable regions labeled with letters.
/// User types letters to click at that location.
const std = @import("std");

/// Single hint representing a clickable region
pub const Hint = struct {
    label: [2]u8, // 1 or 2 letter label
    label_len: u8, // 1 or 2
    term_col: u16, // Terminal column for rendering (1-indexed)
    term_row: u16, // Terminal row for rendering (1-indexed)
    browser_x: u32, // Click target X (browser coords - center of region)
    browser_y: u32, // Click target Y (browser coords - center of region)
};

/// Grid of hints covering the viewport
pub const HintGrid = struct {
    hints: []Hint,
    allocator: std.mem.Allocator,
    input_buffer: [2]u8,
    input_len: u8,

    /// Generate hint grid based on terminal/viewport dimensions
    /// Grid squares are 3x3 terminal cells each
    pub fn generate(
        allocator: std.mem.Allocator,
        content_start_row: u16,
        content_rows: u16,
        terminal_cols: u16,
        _: u16, // cell_width - reserved for future use
        _: u16, // cell_height - reserved for future use
        viewport_width: u32,
        viewport_height: u32,
    ) !HintGrid {
        const GRID_SIZE: u16 = 3; // 3x3 cells per hint square

        // Calculate grid dimensions
        const grid_cols = terminal_cols / GRID_SIZE;
        const grid_rows = content_rows / GRID_SIZE;
        const hint_count = @as(usize, grid_cols) * @as(usize, grid_rows);

        if (hint_count == 0) {
            return HintGrid{
                .hints = &[_]Hint{},
                .allocator = allocator,
                .input_buffer = undefined,
                .input_len = 0,
            };
        }

        // Allocate hints
        const hints = try allocator.alloc(Hint, hint_count);
        errdefer allocator.free(hints);

        // Calculate browser pixel dimensions for each grid cell
        const browser_cell_w = viewport_width / @as(u32, grid_cols);
        const browser_cell_h = viewport_height / @as(u32, grid_rows);

        // Use 2-letter labels if we need more than 26 hints
        const use_two_letter = hint_count > 26;

        var idx: usize = 0;
        for (0..grid_rows) |row_idx| {
            for (0..grid_cols) |col_idx| {
                // Terminal position (1-indexed, center of the grid square)
                const term_col: u16 = @intCast(col_idx * GRID_SIZE + GRID_SIZE / 2 + 1);
                const term_row: u16 = content_start_row + @as(u16, @intCast(row_idx * GRID_SIZE + GRID_SIZE / 2)) + 1;

                // Browser coordinates (center of the region)
                const browser_x: u32 = @as(u32, @intCast(col_idx)) * browser_cell_w + browser_cell_w / 2;
                const browser_y: u32 = @as(u32, @intCast(row_idx)) * browser_cell_h + browser_cell_h / 2;

                // Generate label
                var label: [2]u8 = undefined;
                var label_len: u8 = undefined;

                if (use_two_letter) {
                    label[0] = 'a' + @as(u8, @intCast(idx / 26));
                    label[1] = 'a' + @as(u8, @intCast(idx % 26));
                    label_len = 2;
                } else {
                    label[0] = 'a' + @as(u8, @intCast(idx));
                    label[1] = 0;
                    label_len = 1;
                }

                hints[idx] = Hint{
                    .label = label,
                    .label_len = label_len,
                    .term_col = term_col,
                    .term_row = term_row,
                    .browser_x = browser_x,
                    .browser_y = browser_y,
                };
                idx += 1;
            }
        }

        return HintGrid{
            .hints = hints,
            .allocator = allocator,
            .input_buffer = undefined,
            .input_len = 0,
        };
    }

    pub fn deinit(self: *HintGrid) void {
        if (self.hints.len > 0) {
            self.allocator.free(self.hints);
        }
        self.hints = &[_]Hint{};
    }

    /// Add a character to the input buffer
    /// Returns the matched hint if a unique match is found, null otherwise
    pub fn addChar(self: *HintGrid, c: u8) ?*const Hint {
        if (self.input_len >= 2) return null;

        self.input_buffer[self.input_len] = c;
        self.input_len += 1;

        // Check for matches
        var match_count: usize = 0;
        var matched_hint: ?*const Hint = null;

        for (self.hints) |*hint| {
            if (self.matchesFilter(hint)) {
                match_count += 1;
                matched_hint = hint;
            }
        }

        // If exactly one match, return it
        if (match_count == 1) {
            return matched_hint;
        }

        // If no matches, reset input
        if (match_count == 0) {
            self.input_len = 0;
        }

        return null;
    }

    /// Check if a hint matches the current filter
    fn matchesFilter(self: *const HintGrid, hint: *const Hint) bool {
        if (self.input_len == 0) return true;

        // Check first character
        if (hint.label[0] != self.input_buffer[0]) return false;

        // If we have two chars in filter, check second too
        if (self.input_len >= 2 and hint.label_len >= 2) {
            if (hint.label[1] != self.input_buffer[1]) return false;
        }

        // If filter has 1 char and hint has 2 chars, still matches (partial)
        return true;
    }

    /// Get hints that match the current filter
    pub fn getFilteredHints(self: *const HintGrid) []const Hint {
        // Return all hints - filtering is done during rendering
        return self.hints;
    }

    /// Clear input buffer
    pub fn clear(self: *HintGrid) void {
        self.input_len = 0;
    }

    /// Get current input as slice
    pub fn getInput(self: *const HintGrid) []const u8 {
        return self.input_buffer[0..self.input_len];
    }
};

/// Render hints as text overlays using terminal cursor positioning
/// Uses inverse video styling for visibility
pub fn renderHints(
    writer: anytype,
    grid: *const HintGrid,
) !void {
    const filter = grid.getInput();

    for (grid.hints) |hint| {
        // Skip hints that don't match filter
        if (filter.len > 0) {
            if (hint.label[0] != filter[0]) continue;
            if (filter.len >= 2 and hint.label_len >= 2 and hint.label[1] != filter[1]) continue;
        }

        // Move cursor to hint position
        try writer.print("\x1b[{d};{d}H", .{ hint.term_row, hint.term_col });

        // Render with inverse video (swap fg/bg)
        // Yellow background, black text for visibility
        try writer.writeAll("\x1b[43;30m"); // Yellow bg, black fg

        // Write the label
        if (hint.label_len == 1) {
            try writer.writeByte(hint.label[0]);
        } else {
            // For 2-letter labels, highlight matched portion differently
            if (filter.len >= 1) {
                // First letter already matched - show dimmed
                try writer.writeAll("\x1b[2m"); // Dim
                try writer.writeByte(hint.label[0]);
                try writer.writeAll("\x1b[22m"); // Reset dim
                try writer.writeByte(hint.label[1]);
            } else {
                try writer.writeByte(hint.label[0]);
                try writer.writeByte(hint.label[1]);
            }
        }

        // Reset styling
        try writer.writeAll("\x1b[0m");
    }
}

// Tests
test "HintGrid generate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var grid = try HintGrid.generate(
        allocator,
        2, // content_start_row
        24, // content_rows
        80, // terminal_cols
        10, // cell_width
        20, // cell_height
        800, // viewport_width
        480, // viewport_height
    );
    defer grid.deinit();

    // 80/3 = 26 cols, 24/3 = 8 rows = 208 hints
    try std.testing.expect(grid.hints.len > 0);
}

test "HintGrid addChar single letter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var grid = try HintGrid.generate(
        allocator,
        2,
        9, // 3 rows of hints
        9, // 3 cols of hints = 9 hints total
        10,
        20,
        90,
        60,
    );
    defer grid.deinit();

    // Should have 9 hints (3x3 grid = 9 squares, but 9/3=3 cols, 9/3=3 rows = 9)
    // Actually: 9/3 = 3 cols, 9/3 = 3 rows = 9 hints
    try std.testing.expect(grid.hints.len == 9);

    // Type 'a' should match first hint
    const hint = grid.addChar('a');
    try std.testing.expect(hint != null);
    try std.testing.expect(hint.?.label[0] == 'a');
}
