/// Notcurses-based browser viewer
///
/// Replaces the old terminal/kitty-based viewer with full notcurses rendering:
/// - Toolbar with navigation buttons and URL bar
/// - Content area for screencast frames
/// - Mouse and keyboard input handling
const std = @import("std");
const nc = @import("notcurses.zig");
const Toolbar = @import("toolbar.zig").Toolbar;
const ToolbarEvent = @import("toolbar.zig").ToolbarEvent;

pub const ViewerError = error{
    InitFailed,
    RenderFailed,
    PlaneCreateFailed,
    VisualFailed,
};

pub const ViewerEvent = union(enum) {
    none,
    quit,
    back,
    forward,
    refresh,
    navigate: []const u8,
    click: struct { x: u32, y: u32 },
    scroll: struct { delta: i32 },
    key: u32,
    resize,
};

/// Notcurses-based browser viewer
pub const NcViewer = struct {
    allocator: std.mem.Allocator,
    nc_ctx: *nc.Notcurses,
    stdplane: *nc.Plane,
    content_plane: ?*nc.Plane,
    toolbar: *Toolbar,

    // Dimensions
    term_rows: u32,
    term_cols: u32,
    content_y: u32, // Start row for content (after toolbar)

    // Current frame visual
    current_visual: ?*nc.Visual,

    // State
    current_url: []const u8,
    can_go_back: bool,
    can_go_forward: bool,
    is_loading: bool,

    pub fn init(allocator: std.mem.Allocator) !*NcViewer {
        const viewer = try allocator.create(NcViewer);
        errdefer allocator.destroy(viewer);

        // Initialize notcurses with suppress banners
        var opts = nc.Options{
            .flags = nc.OPTION_SUPPRESS_BANNERS,
        };

        const nc_ctx = nc.init(&opts) orelse {
            allocator.destroy(viewer);
            return ViewerError.InitFailed;
        };
        errdefer nc.stop(nc_ctx);

        const stdplane = nc.stdplane(nc_ctx);
        const dim = nc.termDimYx(nc_ctx);

        // Create toolbar
        const toolbar = try Toolbar.init(allocator, stdplane, dim.cols);
        errdefer toolbar.deinit();

        // Create content plane below toolbar
        const toolbar_height = Toolbar.getHeight();
        var content_opts = nc.PlaneOptions{
            .y = @intCast(toolbar_height),
            .x = 0,
            .rows = dim.rows - toolbar_height,
            .cols = dim.cols,
        };
        const content_plane = nc.plane.create(stdplane, &content_opts);

        viewer.* = .{
            .allocator = allocator,
            .nc_ctx = nc_ctx,
            .stdplane = stdplane,
            .content_plane = content_plane,
            .toolbar = toolbar,
            .term_rows = dim.rows,
            .term_cols = dim.cols,
            .content_y = toolbar_height,
            .current_visual = null,
            .current_url = "",
            .can_go_back = false,
            .can_go_forward = false,
            .is_loading = false,
        };

        return viewer;
    }

    pub fn deinit(self: *NcViewer) void {
        if (self.current_visual) |v| nc.visual.destroy(v);
        if (self.content_plane) |p| nc.plane.destroy(p);
        self.toolbar.deinit();
        nc.stop(self.nc_ctx);
        self.allocator.destroy(self);
    }

    /// Set the current URL
    pub fn setUrl(self: *NcViewer, url: []const u8) void {
        self.current_url = url;
        self.toolbar.setUrl(url);
    }

    /// Set navigation state
    pub fn setNavState(self: *NcViewer, can_back: bool, can_forward: bool, loading: bool) void {
        self.can_go_back = can_back;
        self.can_go_forward = can_forward;
        self.is_loading = loading;
        self.toolbar.setNavState(can_back, can_forward, loading);
    }

    /// Update the screencast frame from RGBA data
    pub fn updateFrame(self: *NcViewer, rgba_data: [*]const u8, width: u32, height: u32) !void {
        // Destroy old visual
        if (self.current_visual) |v| {
            nc.visual.destroy(v);
            self.current_visual = null;
        }

        // Create new visual from RGBA data
        const rowstride: i32 = @intCast(width * 4);
        const visual = nc.visual.fromRgba(
            rgba_data,
            @intCast(height),
            rowstride,
            @intCast(width),
        ) orelse return ViewerError.VisualFailed;

        self.current_visual = visual;
    }

    /// Render everything
    pub fn render(self: *NcViewer) !void {
        // Render toolbar
        self.toolbar.render();

        // Render content frame if available
        if (self.current_visual) |visual| {
            if (self.content_plane) |content| {
                var vopts = nc.VisualOptions{
                    .n = content,
                    .scaling = .scale,
                    .blitter = .pixel, // Use pixel blitter for best quality
                };
                _ = nc.visual.blit(self.nc_ctx, visual, &vopts);
            }
        }

        // Present to terminal
        try nc.render(self.nc_ctx);
    }

    /// Poll for input events (non-blocking)
    pub fn pollEvent(self: *NcViewer) ViewerEvent {
        var ni: nc.Input = undefined;
        const id = nc.get(self.nc_ctx, 0, &ni); // 0 = non-blocking

        if (id == 0) return .none;

        // Handle resize
        if (id == nc.KEY_RESIZE) {
            self.handleResize();
            return .resize;
        }

        // Handle mouse events
        if (nc.inputIsMouse(&ni)) {
            return self.handleMouse(&ni);
        }

        // Handle keyboard
        return self.handleKeyboard(id, &ni);
    }

    /// Wait for input event (blocking)
    pub fn waitEvent(self: *NcViewer) ViewerEvent {
        var ni: nc.Input = undefined;
        const id = nc.get(self.nc_ctx, -1, &ni); // -1 = blocking

        if (id == nc.KEY_RESIZE) {
            self.handleResize();
            return .resize;
        }

        if (nc.inputIsMouse(&ni)) {
            return self.handleMouse(&ni);
        }

        return self.handleKeyboard(id, &ni);
    }

    fn handleResize(self: *NcViewer) void {
        const dim = nc.termDimYx(self.nc_ctx);
        self.term_rows = dim.rows;
        self.term_cols = dim.cols;

        // Resize content plane
        if (self.content_plane) |content| {
            const toolbar_height = Toolbar.getHeight();
            nc.plane.resize(content, dim.rows - toolbar_height, dim.cols) catch {};
        }
    }

    fn handleMouse(self: *NcViewer, ni: *const nc.Input) ViewerEvent {
        const pos = nc.inputMouseYx(ni);
        const y = pos.y;
        const x = pos.x;

        // Check if in toolbar area
        if (self.toolbar.containsPoint(y, x)) {
            if (ni.id == nc.KEY_BUTTON1) {
                const event = self.toolbar.handleClick(y, x);
                return self.toolbarEventToViewerEvent(event);
            } else {
                self.toolbar.handleHover(y, x);
            }
            return .none;
        }

        // Content area click
        if (ni.id == nc.KEY_BUTTON1) {
            // Convert to content coordinates
            const content_y = @as(u32, @intCast(@max(0, y - @as(i32, @intCast(self.content_y)))));
            return .{ .click = .{ .x = @intCast(@max(0, x)), .y = content_y } };
        }

        // Scroll
        if (ni.id == nc.KEY_SCROLL_UP) {
            return .{ .scroll = .{ .delta = -3 } };
        }
        if (ni.id == nc.KEY_SCROLL_DOWN) {
            return .{ .scroll = .{ .delta = 3 } };
        }

        return .none;
    }

    fn handleKeyboard(self: *NcViewer, id: u32, ni: *const nc.Input) ViewerEvent {
        // If URL bar is focused, handle input there
        if (self.toolbar.url_focused) {
            if (self.toolbar.handleUrlInput(ni)) |event| {
                return self.toolbarEventToViewerEvent(event);
            }
            return .none;
        }

        // Global shortcuts
        return switch (id) {
            'q' => .quit,
            'b', nc.KEY_BACKSPACE => if (self.can_go_back) .back else .none,
            'r' => .refresh,
            'g' => blk: {
                self.toolbar.url_focused = true;
                break :blk .none;
            },
            nc.KEY_ESC => .quit,
            else => .{ .key = id },
        };
    }

    fn toolbarEventToViewerEvent(self: *NcViewer, event: ToolbarEvent) ViewerEvent {
        _ = self;
        return switch (event) {
            .none => .none,
            .back => .back,
            .forward => .forward,
            .refresh => .refresh,
            .close => .quit,
            .navigate => |url| .{ .navigate = url },
            .url_focus, .url_blur => .none,
        };
    }

    /// Get content area dimensions in pixels (for coordinate mapping)
    pub fn getContentDimensions(self: *NcViewer) struct { width: u32, height: u32 } {
        if (self.content_plane) |content| {
            const dim = nc.plane.dimYx(content);
            // Approximate pixel dimensions (assuming ~10px per cell)
            return .{ .width = dim.cols * 10, .height = dim.rows * 20 };
        }
        return .{ .width = 0, .height = 0 };
    }
};
