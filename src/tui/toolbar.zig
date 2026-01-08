/// Browser toolbar using notcurses TUI
const std = @import("std");
const nc = @import("notcurses.zig");

pub const ButtonState = enum {
    normal,
    hover,
    active,
    disabled,
};

pub const ToolbarEvent = union(enum) {
    none,
    back,
    forward,
    refresh,
    close,
    navigate: []const u8,
    url_focus,
    url_blur,
};

/// Browser toolbar with navigation buttons and address bar
pub const Toolbar = struct {
    allocator: std.mem.Allocator,
    plane: *nc.Plane,
    reader: ?*nc.Reader,
    url_plane: ?*nc.Plane,

    // Button states
    back_state: ButtonState = .normal,
    forward_state: ButtonState = .normal,
    refresh_state: ButtonState = .normal,
    close_state: ButtonState = .normal,

    // Navigation state
    can_go_back: bool = false,
    can_go_forward: bool = false,
    is_loading: bool = false,

    // URL state
    current_url: []const u8 = "",
    url_focused: bool = false,

    // Layout constants
    const TOOLBAR_HEIGHT = 3;
    const BUTTON_WIDTH = 5;
    const URL_START_X = 22;

    pub fn init(allocator: std.mem.Allocator, parent: *nc.Plane, width: u32) !*Toolbar {
        const toolbar = try allocator.create(Toolbar);

        // Create toolbar plane at top of screen
        var opts = nc.PlaneOptions{
            .y = 0,
            .x = 0,
            .rows = TOOLBAR_HEIGHT,
            .cols = width,
        };

        const plane = nc.plane.create(parent, &opts) orelse {
            allocator.destroy(toolbar);
            return error.PlaneCreateFailed;
        };

        // Create URL input plane
        var url_opts = nc.PlaneOptions{
            .y = 1,
            .x = URL_START_X,
            .rows = 1,
            .cols = width - URL_START_X - 2,
        };
        const url_plane = nc.plane.create(plane, &url_opts);

        // Create reader for URL input
        var reader_opts = nc.ReaderOptions{};
        const reader_widget = if (url_plane) |up| nc.reader.create(up, &reader_opts) else null;

        toolbar.* = .{
            .allocator = allocator,
            .plane = plane,
            .reader = reader_widget,
            .url_plane = url_plane,
        };

        return toolbar;
    }

    pub fn deinit(self: *Toolbar) void {
        if (self.reader) |r| nc.reader.destroy(r);
        if (self.url_plane) |p| nc.plane.destroy(p);
        nc.plane.destroy(self.plane);
        self.allocator.destroy(self);
    }

    /// Set navigation state
    pub fn setNavState(self: *Toolbar, can_back: bool, can_forward: bool, loading: bool) void {
        self.can_go_back = can_back;
        self.can_go_forward = can_forward;
        self.is_loading = loading;
        self.back_state = if (can_back) .normal else .disabled;
        self.forward_state = if (can_forward) .normal else .disabled;
    }

    /// Set current URL
    pub fn setUrl(self: *Toolbar, url: []const u8) void {
        self.current_url = url;
    }

    /// Render the toolbar
    pub fn render(self: *Toolbar) void {
        nc.plane.erase(self.plane);

        // Background
        nc.plane.setBgRgb8(self.plane, 30, 30, 30);
        nc.plane.setFgRgb8(self.plane, 200, 200, 200);

        // Fill background
        var y: i32 = 0;
        while (y < TOOLBAR_HEIGHT) : (y += 1) {
            _ = nc.plane.cursorMoveYx(self.plane, y, 0) catch {};
            const dim = nc.plane.dimYx(self.plane);
            var x: u32 = 0;
            while (x < dim.cols) : (x += 1) {
                _ = nc.plane.putstr(self.plane, " ");
            }
        }

        // Close button [X]
        self.renderButton(1, "[X]", self.close_state, 255, 80, 80);

        // Back button [<]
        self.renderButton(6, "[<]", self.back_state, 100, 150, 255);

        // Forward button [>]
        self.renderButton(11, "[>]", self.forward_state, 100, 150, 255);

        // Refresh button [R]
        const refresh_label = if (self.is_loading) "[.]" else "[R]";
        self.renderButton(16, refresh_label, .normal, 100, 200, 100);

        // URL bar
        self.renderUrlBar();
    }

    fn renderButton(self: *Toolbar, x: i32, label: []const u8, state: ButtonState, r: u8, g: u8, b: u8) void {
        _ = nc.plane.cursorMoveYx(self.plane, 1, x) catch {};

        switch (state) {
            .normal => {
                nc.plane.setFgRgb8(self.plane, r, g, b);
                nc.plane.setBgRgb8(self.plane, 50, 50, 50);
            },
            .hover => {
                nc.plane.setFgRgb8(self.plane, 255, 255, 255);
                nc.plane.setBgRgb8(self.plane, r / 2, g / 2, b / 2);
            },
            .active => {
                nc.plane.setFgRgb8(self.plane, 255, 255, 255);
                nc.plane.setBgRgb8(self.plane, r, g, b);
            },
            .disabled => {
                nc.plane.setFgRgb8(self.plane, 80, 80, 80);
                nc.plane.setBgRgb8(self.plane, 40, 40, 40);
            },
        }

        _ = nc.plane.putstr(self.plane, @ptrCast(label.ptr));
    }

    fn renderUrlBar(self: *Toolbar) void {
        const dim = nc.plane.dimYx(self.plane);
        const url_width = dim.cols - URL_START_X - 2;

        _ = nc.plane.cursorMoveYx(self.plane, 1, URL_START_X - 1) catch {};

        // URL bar background
        if (self.url_focused) {
            nc.plane.setBgRgb8(self.plane, 50, 50, 60);
            nc.plane.setFgRgb8(self.plane, 255, 255, 255);
        } else {
            nc.plane.setBgRgb8(self.plane, 40, 40, 40);
            nc.plane.setFgRgb8(self.plane, 180, 180, 180);
        }

        // Draw URL bar frame
        _ = nc.plane.putstr(self.plane, " ");

        // URL text (truncate if needed)
        const max_url_len = @min(self.current_url.len, url_width - 2);
        if (max_url_len > 0) {
            var buf: [512]u8 = undefined;
            const display_url = if (self.current_url.len > max_url_len)
                std.fmt.bufPrintZ(&buf, "{s}...", .{self.current_url[0 .. max_url_len - 3]}) catch ""
            else
                std.fmt.bufPrintZ(&buf, "{s}", .{self.current_url[0..max_url_len]}) catch "";
            _ = nc.plane.putstr(self.plane, display_url);
        }

        // Pad rest of URL bar
        var x: u32 = @intCast(URL_START_X + @as(i32, @intCast(max_url_len)));
        while (x < dim.cols - 1) : (x += 1) {
            _ = nc.plane.putstr(self.plane, " ");
        }

        // Reset colors
        nc.plane.setFgDefault(self.plane);
        nc.plane.setBgDefault(self.plane);
    }

    /// Handle mouse click at terminal coordinates
    pub fn handleClick(self: *Toolbar, term_y: i32, term_x: i32) ToolbarEvent {
        // Check if click is in toolbar area (row 1 is the button row)
        if (term_y != 1) return .none;

        // Close button [X] at x=1-3
        if (term_x >= 1 and term_x <= 3) {
            self.close_state = .active;
            return .close;
        }

        // Back button [<] at x=6-8
        if (term_x >= 6 and term_x <= 8) {
            if (self.can_go_back) {
                self.back_state = .active;
                return .back;
            }
            return .none;
        }

        // Forward button [>] at x=11-13
        if (term_x >= 11 and term_x <= 13) {
            if (self.can_go_forward) {
                self.forward_state = .active;
                return .forward;
            }
            return .none;
        }

        // Refresh button [R] at x=16-18
        if (term_x >= 16 and term_x <= 18) {
            self.refresh_state = .active;
            return .refresh;
        }

        // URL bar
        if (term_x >= URL_START_X) {
            self.url_focused = true;
            return .url_focus;
        }

        return .none;
    }

    /// Handle mouse hover
    pub fn handleHover(self: *Toolbar, term_y: i32, term_x: i32) void {
        // Reset all hover states
        if (self.back_state != .disabled) self.back_state = .normal;
        if (self.forward_state != .disabled) self.forward_state = .normal;
        self.refresh_state = .normal;
        self.close_state = .normal;

        if (term_y != 1) return;

        if (term_x >= 1 and term_x <= 3) {
            self.close_state = .hover;
        } else if (term_x >= 6 and term_x <= 8 and self.can_go_back) {
            self.back_state = .hover;
        } else if (term_x >= 11 and term_x <= 13 and self.can_go_forward) {
            self.forward_state = .hover;
        } else if (term_x >= 16 and term_x <= 18) {
            self.refresh_state = .hover;
        }
    }

    /// Handle mouse release
    pub fn handleRelease(self: *Toolbar) void {
        if (self.back_state == .active and self.can_go_back) self.back_state = .normal;
        if (self.forward_state == .active and self.can_go_forward) self.forward_state = .normal;
        if (self.refresh_state == .active) self.refresh_state = .normal;
        if (self.close_state == .active) self.close_state = .normal;
    }

    /// Handle keyboard input when URL bar is focused
    pub fn handleUrlInput(self: *Toolbar, ni: *const nc.Input) ?ToolbarEvent {
        if (!self.url_focused) return null;

        if (ni.id == nc.KEY_ENTER) {
            self.url_focused = false;
            if (self.reader) |r| {
                if (nc.reader.contents(r)) |url| {
                    return .{ .navigate = std.mem.span(url) };
                }
            }
            return .url_blur;
        }

        if (ni.id == nc.KEY_ESC) {
            self.url_focused = false;
            return .url_blur;
        }

        // Pass input to reader widget
        if (self.reader) |r| {
            _ = nc.reader.offerInput(r, ni);
        }

        return null;
    }

    /// Check if a point is in the toolbar area
    pub fn containsPoint(self: *Toolbar, y: i32, x: i32) bool {
        _ = x;
        _ = self;
        return y < TOOLBAR_HEIGHT;
    }

    /// Get toolbar height
    pub fn getHeight() u32 {
        return TOOLBAR_HEIGHT;
    }
};
