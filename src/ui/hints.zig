/// Hint Mode - Vimium-style click navigation
///
/// Shows hints only on clickable elements (links, buttons, inputs, etc.)
/// User types letters to click at that location.
const std = @import("std");

/// Single hint representing a clickable element
pub const Hint = struct {
    label: [4]u8, // up to 4 letter label (a-z, aa-zz, aaa-zzz, aaaa-zzzz)
    label_len: u8, // 1-4
    term_col: u16, // Terminal column for rendering (1-indexed)
    term_row: u16, // Terminal row for rendering (1-indexed)
    browser_x: u32, // Click target X (browser coords - center of element)
    browser_y: u32, // Click target Y (browser coords - center of element)
};

/// Clickable element from DOM query
pub const ClickableElement = struct {
    x: u32, // Browser X coordinate (center)
    y: u32, // Browser Y coordinate (center)
    width: u32,
    height: u32,
};

/// Grid of hints for clickable elements
pub const HintGrid = struct {
    hints: []Hint,
    allocator: std.mem.Allocator,
    input_buffer: [4]u8,
    input_len: u8,

    /// Generate hints from clickable elements
    /// elements: list of clickable element positions from DOM
    pub fn generateFromElements(
        allocator: std.mem.Allocator,
        elements: []const ClickableElement,
        content_start_row: u16,
        terminal_cols: u16,
        terminal_rows: u16,
        cell_width: u16,
        cell_height: u16,
        viewport_width: u32,
        viewport_height: u32,
    ) !HintGrid {
        if (elements.len == 0) {
            return HintGrid{
                .hints = &[_]Hint{},
                .allocator = allocator,
                .input_buffer = undefined,
                .input_len = 0,
            };
        }

        // Calculate terminal pixel dimensions
        const term_width_px = @as(u32, terminal_cols) * @as(u32, cell_width);
        const term_height_px = @as(u32, terminal_rows) * @as(u32, cell_height);

        // Scale factors from browser to terminal
        const scale_to_term_x = @as(f32, @floatFromInt(term_width_px)) / @as(f32, @floatFromInt(viewport_width));
        const scale_to_term_y = @as(f32, @floatFromInt(term_height_px)) / @as(f32, @floatFromInt(viewport_height));

        // Allocate hints (one per element)
        const hints = try allocator.alloc(Hint, elements.len);
        errdefer allocator.free(hints);

        for (elements, 0..) |elem, idx| {
            // Convert browser coords to terminal pixel coords
            const term_px_x: u32 = @intFromFloat(@as(f32, @floatFromInt(elem.x)) * scale_to_term_x);
            const term_px_y: u32 = @intFromFloat(@as(f32, @floatFromInt(elem.y)) * scale_to_term_y);

            // Terminal cell position
            const term_col: u16 = @as(u16, @intCast(@min(term_px_x / @as(u32, cell_width), terminal_cols - 1))) + 1;
            const term_row: u16 = content_start_row + @as(u16, @intCast(@min(term_px_y / @as(u32, cell_height), terminal_rows - 1))) + 1;

            // Generate label
            const label = indexToLabel(idx);

            hints[idx] = Hint{
                .label = label.chars,
                .label_len = label.len,
                .term_col = term_col,
                .term_row = term_row,
                .browser_x = elem.x,
                .browser_y = elem.y,
            };
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
        if (self.input_len >= 4) return null;

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

        // If exactly one match and input length equals label length, return it
        if (match_count == 1 and matched_hint != null and self.input_len == matched_hint.?.label_len) {
            return matched_hint;
        }

        // If no matches, reset input
        if (match_count == 0) {
            self.input_len = 0;
        }

        return null;
    }

    /// Find exact match - returns hint if input exactly matches a label
    /// Used for timeout-based auto-selection
    pub fn findExactMatch(self: *const HintGrid) ?*const Hint {
        if (self.input_len == 0) return null;

        for (self.hints) |*hint| {
            if (hint.label_len == self.input_len) {
                var matches = true;
                var i: u8 = 0;
                while (i < self.input_len) : (i += 1) {
                    if (hint.label[i] != self.input_buffer[i]) {
                        matches = false;
                        break;
                    }
                }
                if (matches) return hint;
            }
        }
        return null;
    }

    /// Check if a hint matches the current filter
    fn matchesFilter(self: *const HintGrid, hint: *const Hint) bool {
        if (self.input_len == 0) return true;

        // Check each character in input against hint label
        var i: u8 = 0;
        while (i < self.input_len) : (i += 1) {
            if (i >= hint.label_len) return false;
            if (hint.label[i] != self.input_buffer[i]) return false;
        }

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

/// Render hints as individual small badge images
/// Each badge is placed at its cell position using kitty graphics
pub fn renderHintsOverlay(
    allocator: std.mem.Allocator,
    writer: anytype,
    grid: *const HintGrid,
    term_width_px: u32,
    term_height_px: u32,
    term_cols: u16,
    cell_width: u16,
    cell_height: u16,
    content_start_row: u16,
) !void {
    _ = term_width_px;
    _ = term_height_px;
    _ = term_cols;
    _ = cell_width;
    _ = cell_height;

    if (grid.hints.len == 0) return;

    const filter = grid.getInput();

    // Badge dimensions - dynamic width, fixed height
    const badge_h: u32 = 24;
    const max_badge_w: u32 = 70; // Fits 4 chars (4 * 16 = 64 + 6 padding)
    const max_badge_size = max_badge_w * badge_h * 4;

    // Create single badge buffer (reused for each hint, sized for max width)
    const badge_buf = try allocator.alloc(u8, max_badge_size);
    defer allocator.free(badge_buf);

    // Pre-allocate base64 buffer for max size
    const encoder = std.base64.standard.Encoder;
    const max_encoded_len = encoder.calcSize(max_badge_size);
    const encoded = try allocator.alloc(u8, max_encoded_len);
    defer allocator.free(encoded);

    // No limit - terminal size naturally limits hint count
    var rendered: usize = 0;

    // First, delete old hint images
    try writer.writeAll("\x1b_Ga=d,d=i,i=500\x1b\\");

    for (grid.hints) |hint| {
        // Skip hints that don't match filter (check all filter chars)
        if (filter.len > 0) {
            var matches = true;
            for (filter, 0..) |fc, i| {
                if (i >= hint.label_len or hint.label[i] != fc) {
                    matches = false;
                    break;
                }
            }
            if (!matches) continue;
        }

        // Calculate badge width for this hint's label length
        // 16px per char + 6px padding
        const badge_w: u32 = @as(u32, hint.label_len) * 16 + 6;
        const badge_size = badge_w * badge_h * 4;

        // Clear badge buffer
        @memset(badge_buf[0..badge_size], 0);

        // Draw badge at (0,0) in the small buffer
        drawBadge(badge_buf, badge_w, badge_h, 0, 0, badge_w, badge_h, &hint.label, hint.label_len);

        // Encode badge
        const encoded_len = encoder.calcSize(badge_size);
        _ = encoder.encode(encoded[0..encoded_len], badge_buf[0..badge_size]);

        // Position cursor at hint location
        const row = hint.term_row;
        const col = hint.term_col;
        if (row <= content_start_row) continue;

        try writer.print("\x1b[{d};{d}H", .{ row, col });

        // Send as kitty graphics - small image, no chunking needed
        // Use unique image ID for each hint (501 + index)
        const image_id: u32 = 501 + @as(u32, @intCast(rendered));
        try writer.print("\x1b_Ga=T,f=32,t=d,q=2,z=100,C=1,i={d},s={d},v={d};", .{
            image_id,
            badge_w,
            badge_h,
        });
        try writer.writeAll(encoded[0..encoded_len]);
        try writer.writeAll("\x1b\\");

        rendered += 1;
    }
}

/// Public wrapper for drawing a badge (used by viewer.zig)
pub fn drawBadgePublic(buf: []u8, w: u32, h: u32, label: *const [4]u8, label_len: u8) void {
    drawBadge(buf, w, h, 0, 0, w, h, label, label_len);
}

/// Draw a hint badge onto the overlay buffer
/// Uses solid yellow background with black border and black text
/// No left padding - text starts immediately
fn drawBadge(buf: []u8, stride: u32, height: u32, x: u32, y: u32, w: u32, h: u32, label: *const [4]u8, label_len: u8) void {
    const border: u32 = 2; // 2px black border

    // Draw black border first (fill entire badge area)
    var py: u32 = 0;
    while (py < h and y + py < height) : (py += 1) {
        var px: u32 = 0;
        while (px < w and x + px < stride) : (px += 1) {
            const idx = ((y + py) * stride + (x + px)) * 4;
            if (idx + 3 >= buf.len) continue;
            buf[idx] = 0; // R
            buf[idx + 1] = 0; // G
            buf[idx + 2] = 0; // B
            buf[idx + 3] = 255; // Fully opaque
        }
    }

    // Draw yellow background with 90% opacity (inside border)
    py = border;
    while (py < h - border and y + py < height) : (py += 1) {
        var px: u32 = border;
        while (px < w - border and x + px < stride) : (px += 1) {
            const idx = ((y + py) * stride + (x + px)) * 4;
            if (idx + 3 >= buf.len) continue;
            buf[idx] = 255; // R
            buf[idx + 1] = 220; // G (slightly darker yellow)
            buf[idx + 2] = 0; // B
            buf[idx + 3] = 230; // 90% opacity (0.9 * 255)
        }
    }

    // Draw 2x scaled black text - account for border
    const text_x = x + border + 1; // Border + minimal padding
    const text_y = y + border + 2;
    const char_width: u32 = 16; // 8px glyph * 2x scale

    // Draw black text
    var i: u8 = 0;
    while (i < label_len) : (i += 1) {
        drawChar2x(buf, stride, height, label[i], text_x + @as(u32, i) * char_width, text_y, 0, 0, 0);
    }
}

/// Draw a character at 2x scale onto overlay buffer
fn drawChar2x(buf: []u8, stride: u32, height: u32, char: u8, x: u32, y: u32, r: u8, g: u8, b: u8) void {
    const glyph = getGlyph(char);
    for (glyph, 0..) |row, dy| {
        var bit: u8 = 0x80;
        var dx: u32 = 0;
        while (dx < 8) : (dx += 1) {
            if (row & bit != 0) {
                // Draw 2x2 block for each pixel
                const px = x + dx * 2;
                const py = y + @as(u32, @intCast(dy)) * 2;
                // Top-left
                if (px < stride and py < height) {
                    const idx = (py * stride + px) * 4;
                    if (idx + 3 < buf.len) {
                        buf[idx] = r;
                        buf[idx + 1] = g;
                        buf[idx + 2] = b;
                        buf[idx + 3] = 255;
                    }
                }
                // Top-right
                if (px + 1 < stride and py < height) {
                    const idx = (py * stride + px + 1) * 4;
                    if (idx + 3 < buf.len) {
                        buf[idx] = r;
                        buf[idx + 1] = g;
                        buf[idx + 2] = b;
                        buf[idx + 3] = 255;
                    }
                }
                // Bottom-left
                if (px < stride and py + 1 < height) {
                    const idx = ((py + 1) * stride + px) * 4;
                    if (idx + 3 < buf.len) {
                        buf[idx] = r;
                        buf[idx + 1] = g;
                        buf[idx + 2] = b;
                        buf[idx + 3] = 255;
                    }
                }
                // Bottom-right
                if (px + 1 < stride and py + 1 < height) {
                    const idx = ((py + 1) * stride + px + 1) * 4;
                    if (idx + 3 < buf.len) {
                        buf[idx] = r;
                        buf[idx + 1] = g;
                        buf[idx + 2] = b;
                        buf[idx + 3] = 255;
                    }
                }
            }
            bit >>= 1;
        }
    }
}

/// Draw a character onto overlay buffer with specified color
fn drawCharOnOverlayColor(buf: []u8, stride: u32, height: u32, char: u8, x: u32, y: u32, r: u8, g: u8, b: u8) void {
    const glyph = getGlyph(char);
    for (glyph, 0..) |row, dy| {
        var bit: u8 = 0x80;
        var dx: u32 = 0;
        while (dx < 8) : (dx += 1) {
            if (row & bit != 0) {
                const px = x + dx;
                const py = y + @as(u32, @intCast(dy));
                if (px < stride and py < height) {
                    const idx = (py * stride + px) * 4;
                    if (idx + 3 < buf.len) {
                        buf[idx] = r;
                        buf[idx + 1] = g;
                        buf[idx + 2] = b;
                        buf[idx + 3] = 255; // Fully opaque
                    }
                }
            }
            bit >>= 1;
        }
    }
}

/// Draw a character onto overlay buffer (black)
fn drawCharOnOverlay(buf: []u8, stride: u32, height: u32, char: u8, x: u32, y: u32) void {
    drawCharOnOverlayColor(buf, stride, height, char, x, y, 0, 0, 0);
}

/// Label result from index conversion
const LabelResult = struct {
    chars: [4]u8,
    len: u8,
};

/// Convert index to label: 0-25 -> a-z, 26-701 -> aa-zz, 702-18277 -> aaa-zzz, etc.
fn indexToLabel(idx: usize) LabelResult {
    var result = LabelResult{ .chars = .{ 0, 0, 0, 0 }, .len = 0 };

    // Single letter: a-z (0-25)
    if (idx < 26) {
        result.chars[0] = 'a' + @as(u8, @intCast(idx));
        result.len = 1;
        return result;
    }

    // Two letters: aa-zz (26-701)
    const two_start: usize = 26;
    const two_count: usize = 26 * 26; // 676
    if (idx < two_start + two_count) {
        const adjusted = idx - two_start;
        result.chars[0] = 'a' + @as(u8, @intCast(adjusted / 26));
        result.chars[1] = 'a' + @as(u8, @intCast(adjusted % 26));
        result.len = 2;
        return result;
    }

    // Three letters: aaa-zzz (702-18277)
    const three_start: usize = two_start + two_count; // 702
    const three_count: usize = 26 * 26 * 26; // 17576
    if (idx < three_start + three_count) {
        const adjusted = idx - three_start;
        result.chars[0] = 'a' + @as(u8, @intCast(adjusted / (26 * 26)));
        result.chars[1] = 'a' + @as(u8, @intCast((adjusted / 26) % 26));
        result.chars[2] = 'a' + @as(u8, @intCast(adjusted % 26));
        result.len = 3;
        return result;
    }

    // Four letters: aaaa-zzzz
    const four_start: usize = three_start + three_count; // 18278
    const adjusted = idx - four_start;
    result.chars[0] = 'a' + @as(u8, @intCast(adjusted / (26 * 26 * 26)));
    result.chars[1] = 'a' + @as(u8, @intCast((adjusted / (26 * 26)) % 26));
    result.chars[2] = 'a' + @as(u8, @intCast((adjusted / 26) % 26));
    result.chars[3] = 'a' + @as(u8, @intCast(adjusted % 26));
    result.len = 4;
    return result;
}

/// Simple 5x8 bitmap font glyphs for a-z
fn getGlyph(char: u8) [8]u8 {
    return switch (char) {
        'a' => .{ 0x00, 0x00, 0x3C, 0x06, 0x3E, 0x66, 0x3E, 0x00 },
        'b' => .{ 0x60, 0x60, 0x7C, 0x66, 0x66, 0x66, 0x7C, 0x00 },
        'c' => .{ 0x00, 0x00, 0x3C, 0x66, 0x60, 0x66, 0x3C, 0x00 },
        'd' => .{ 0x06, 0x06, 0x3E, 0x66, 0x66, 0x66, 0x3E, 0x00 },
        'e' => .{ 0x00, 0x00, 0x3C, 0x66, 0x7E, 0x60, 0x3C, 0x00 },
        'f' => .{ 0x1C, 0x30, 0x7C, 0x30, 0x30, 0x30, 0x30, 0x00 },
        'g' => .{ 0x00, 0x00, 0x3E, 0x66, 0x66, 0x3E, 0x06, 0x3C },
        'h' => .{ 0x60, 0x60, 0x7C, 0x66, 0x66, 0x66, 0x66, 0x00 },
        'i' => .{ 0x18, 0x00, 0x38, 0x18, 0x18, 0x18, 0x3C, 0x00 },
        'j' => .{ 0x0C, 0x00, 0x1C, 0x0C, 0x0C, 0x0C, 0x6C, 0x38 },
        'k' => .{ 0x60, 0x60, 0x66, 0x6C, 0x78, 0x6C, 0x66, 0x00 },
        'l' => .{ 0x38, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00 },
        'm' => .{ 0x00, 0x00, 0x76, 0x7F, 0x6B, 0x63, 0x63, 0x00 },
        'n' => .{ 0x00, 0x00, 0x7C, 0x66, 0x66, 0x66, 0x66, 0x00 },
        'o' => .{ 0x00, 0x00, 0x3C, 0x66, 0x66, 0x66, 0x3C, 0x00 },
        'p' => .{ 0x00, 0x00, 0x7C, 0x66, 0x66, 0x7C, 0x60, 0x60 },
        'q' => .{ 0x00, 0x00, 0x3E, 0x66, 0x66, 0x3E, 0x06, 0x06 },
        'r' => .{ 0x00, 0x00, 0x7C, 0x66, 0x60, 0x60, 0x60, 0x00 },
        's' => .{ 0x00, 0x00, 0x3E, 0x60, 0x3C, 0x06, 0x7C, 0x00 },
        't' => .{ 0x30, 0x30, 0x7C, 0x30, 0x30, 0x30, 0x1C, 0x00 },
        'u' => .{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x66, 0x3E, 0x00 },
        'v' => .{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x3C, 0x18, 0x00 },
        'w' => .{ 0x00, 0x00, 0x63, 0x63, 0x6B, 0x7F, 0x36, 0x00 },
        'x' => .{ 0x00, 0x00, 0x66, 0x3C, 0x18, 0x3C, 0x66, 0x00 },
        'y' => .{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x3E, 0x06, 0x3C },
        'z' => .{ 0x00, 0x00, 0x7E, 0x0C, 0x18, 0x30, 0x7E, 0x00 },
        else => .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    };
}

/// Legacy text-based render (doesn't work with kitty images)
pub fn renderHints(
    writer: anytype,
    grid: *const HintGrid,
) !void {
    _ = writer;
    _ = grid;
    // Text rendering doesn't work on top of kitty images
    // Use renderHintsOverlay instead
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
