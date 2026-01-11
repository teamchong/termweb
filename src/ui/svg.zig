/// SVG rendering using nanosvg
/// Provides macOS-style toolbar buttons
const std = @import("std");

const c = @cImport({
    @cInclude("nanosvg.h");
    @cInclude("nanosvgrast.h");
});

/// SVG Renderer wrapping nanosvg
pub const SvgRenderer = struct {
    rasterizer: *c.NSVGrasterizer,

    pub fn init() !SvgRenderer {
        const rast = c.nsvgCreateRasterizer() orelse return error.RasterizerCreateFailed;
        return .{ .rasterizer = rast };
    }

    pub fn deinit(self: *SvgRenderer) void {
        c.nsvgDeleteRasterizer(self.rasterizer);
    }

    /// Render SVG string to RGBA buffer
    /// Caller owns returned memory
    pub fn renderToRgba(
        self: *SvgRenderer,
        allocator: std.mem.Allocator,
        svg_data: [:0]const u8,
        width: u32,
        height: u32,
    ) ![]u8 {
        // Parse SVG (nsvgParse modifies the string, so we need a copy)
        const svg_copy = try allocator.allocSentinel(u8, svg_data.len, 0);
        defer allocator.free(svg_copy);
        @memcpy(svg_copy, svg_data);

        const image = c.nsvgParse(svg_copy.ptr, "px", 96.0) orelse return error.SvgParseFailed;
        defer c.nsvgDelete(image);

        // Calculate scale to fit target dimensions
        const scale_x = @as(f32, @floatFromInt(width)) / image.*.width;
        const scale_y = @as(f32, @floatFromInt(height)) / image.*.height;
        const scale = @min(scale_x, scale_y);

        // Allocate output buffer
        const buf_size = width * height * 4;
        const buffer = try allocator.alloc(u8, buf_size);
        @memset(buffer, 0);

        // Rasterize
        c.nsvgRasterize(
            self.rasterizer,
            image,
            0,
            0,
            scale,
            buffer.ptr,
            @intCast(width),
            @intCast(height),
            @intCast(width * 4),
        );

        return buffer;
    }
};

/// macOS-style toolbar SVG definitions
pub const ToolbarSvg = struct {
    /// Traffic light close button (red circle with X)
    pub const close_normal =
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 14 14">
        \\  <circle cx="7" cy="7" r="6" fill="#ff5f57"/>
        \\  <circle cx="7" cy="7" r="5.5" fill="none" stroke="#e0443e" stroke-width="0.5"/>
        \\</svg>
    ;

    pub const close_hover =
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 14 14">
        \\  <circle cx="7" cy="7" r="6" fill="#ff5f57"/>
        \\  <circle cx="7" cy="7" r="5.5" fill="none" stroke="#e0443e" stroke-width="0.5"/>
        \\  <path d="M4.5 4.5 L9.5 9.5 M9.5 4.5 L4.5 9.5" stroke="#4d0000" stroke-width="1.2" stroke-linecap="round"/>
        \\</svg>
    ;

    /// Back button (left arrow)
    pub const back_normal =
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
        \\  <path d="M15 18l-6-6 6-6" fill="none" stroke="#007aff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
        \\</svg>
    ;

    pub const back_hover =
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
        \\  <path d="M15 18l-6-6 6-6" fill="none" stroke="#4da3ff" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/>
        \\</svg>
    ;

    pub const back_disabled =
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
        \\  <path d="M15 18l-6-6 6-6" fill="none" stroke="#555555" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
        \\</svg>
    ;

    /// Forward button (right arrow)
    pub const forward_normal =
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
        \\  <path d="M9 18l6-6-6-6" fill="none" stroke="#007aff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
        \\</svg>
    ;

    pub const forward_hover =
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
        \\  <path d="M9 18l6-6-6-6" fill="none" stroke="#4da3ff" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/>
        \\</svg>
    ;

    pub const forward_disabled =
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
        \\  <path d="M9 18l6-6-6-6" fill="none" stroke="#555555" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
        \\</svg>
    ;

    /// Refresh button (circular arrow)
    pub const refresh_normal =
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
        \\  <path d="M23 4v6h-6" fill="none" stroke="#007aff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
        \\  <path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10" fill="none" stroke="#007aff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
        \\</svg>
    ;

    pub const refresh_hover =
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
        \\  <path d="M23 4v6h-6" fill="none" stroke="#4da3ff" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/>
        \\  <path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10" fill="none" stroke="#4da3ff" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/>
        \\</svg>
    ;

    /// Stop button (X mark for loading state)
    pub const stop_normal =
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
        \\  <path d="M6 6l12 12M18 6l-12 12" fill="none" stroke="#ff3b30" stroke-width="2" stroke-linecap="round"/>
        \\</svg>
    ;

    pub const stop_hover =
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
        \\  <path d="M6 6l12 12M18 6l-12 12" fill="none" stroke="#ff6b6b" stroke-width="2.5" stroke-linecap="round"/>
        \\</svg>
    ;

    pub const refresh_loading =
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
        \\  <circle cx="12" cy="12" r="1.5" fill="#007aff"/>
        \\</svg>
    ;

    /// URL bar background
    pub fn urlBar(width: u32, height: u32, focused: bool) ![:0]const u8 {
        _ = width;
        _ = height;
        _ = focused;
        // For URL bar we'll use a simple rounded rect
        return
            \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 28">
            \\  <rect x="1" y="1" width="98" height="26" rx="6" ry="6" fill="#1e1e1e" stroke="#3a3a3a" stroke-width="1"/>
            \\</svg>
        ;
    }

    /// Full toolbar background
    pub const toolbar_bg =
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 40">
        \\  <rect x="0" y="0" width="100" height="40" fill="#2d2d2d"/>
        \\  <rect x="0" y="39" width="100" height="1" fill="#1a1a1a"/>
        \\</svg>
    ;
};

/// Pre-rendered toolbar button cache
pub const ToolbarCache = struct {
    allocator: std.mem.Allocator,
    renderer: SvgRenderer,

    // Cached RGBA buffers
    close_normal: ?[]u8 = null,
    close_hover: ?[]u8 = null,
    back_normal: ?[]u8 = null,
    back_hover: ?[]u8 = null,
    back_disabled: ?[]u8 = null,
    forward_normal: ?[]u8 = null,
    forward_hover: ?[]u8 = null,
    forward_disabled: ?[]u8 = null,
    refresh_normal: ?[]u8 = null,
    refresh_hover: ?[]u8 = null,
    stop_normal: ?[]u8 = null,
    stop_hover: ?[]u8 = null,

    pub const BUTTON_SIZE: u32 = 28;

    pub fn init(allocator: std.mem.Allocator) !ToolbarCache {
        return .{
            .allocator = allocator,
            .renderer = try SvgRenderer.init(),
        };
    }

    pub fn deinit(self: *ToolbarCache) void {
        if (self.close_normal) |b| self.allocator.free(b);
        if (self.close_hover) |b| self.allocator.free(b);
        if (self.back_normal) |b| self.allocator.free(b);
        if (self.back_hover) |b| self.allocator.free(b);
        if (self.back_disabled) |b| self.allocator.free(b);
        if (self.forward_normal) |b| self.allocator.free(b);
        if (self.forward_hover) |b| self.allocator.free(b);
        if (self.forward_disabled) |b| self.allocator.free(b);
        if (self.refresh_normal) |b| self.allocator.free(b);
        if (self.refresh_hover) |b| self.allocator.free(b);
        if (self.stop_normal) |b| self.allocator.free(b);
        if (self.stop_hover) |b| self.allocator.free(b);
        self.renderer.deinit();
    }

    pub fn getCloseButton(self: *ToolbarCache, hover: bool) ![]u8 {
        if (hover) {
            if (self.close_hover == null) {
                self.close_hover = try self.renderer.renderToRgba(
                    self.allocator,
                    ToolbarSvg.close_hover,
                    BUTTON_SIZE,
                    BUTTON_SIZE,
                );
            }
            return self.close_hover.?;
        } else {
            if (self.close_normal == null) {
                self.close_normal = try self.renderer.renderToRgba(
                    self.allocator,
                    ToolbarSvg.close_normal,
                    BUTTON_SIZE,
                    BUTTON_SIZE,
                );
            }
            return self.close_normal.?;
        }
    }

    pub fn getBackButton(self: *ToolbarCache, enabled: bool, hover: bool) ![]u8 {
        if (!enabled) {
            if (self.back_disabled == null) {
                self.back_disabled = try self.renderer.renderToRgba(
                    self.allocator,
                    ToolbarSvg.back_disabled,
                    BUTTON_SIZE,
                    BUTTON_SIZE,
                );
            }
            return self.back_disabled.?;
        }
        if (hover) {
            if (self.back_hover == null) {
                self.back_hover = try self.renderer.renderToRgba(
                    self.allocator,
                    ToolbarSvg.back_hover,
                    BUTTON_SIZE,
                    BUTTON_SIZE,
                );
            }
            return self.back_hover.?;
        }
        if (self.back_normal == null) {
            self.back_normal = try self.renderer.renderToRgba(
                self.allocator,
                ToolbarSvg.back_normal,
                BUTTON_SIZE,
                BUTTON_SIZE,
            );
        }
        return self.back_normal.?;
    }

    pub fn getForwardButton(self: *ToolbarCache, enabled: bool, hover: bool) ![]u8 {
        if (!enabled) {
            if (self.forward_disabled == null) {
                self.forward_disabled = try self.renderer.renderToRgba(
                    self.allocator,
                    ToolbarSvg.forward_disabled,
                    BUTTON_SIZE,
                    BUTTON_SIZE,
                );
            }
            return self.forward_disabled.?;
        }
        if (hover) {
            if (self.forward_hover == null) {
                self.forward_hover = try self.renderer.renderToRgba(
                    self.allocator,
                    ToolbarSvg.forward_hover,
                    BUTTON_SIZE,
                    BUTTON_SIZE,
                );
            }
            return self.forward_hover.?;
        }
        if (self.forward_normal == null) {
            self.forward_normal = try self.renderer.renderToRgba(
                self.allocator,
                ToolbarSvg.forward_normal,
                BUTTON_SIZE,
                BUTTON_SIZE,
            );
        }
        return self.forward_normal.?;
    }

    pub fn getRefreshButton(self: *ToolbarCache, hover: bool) ![]u8 {
        if (hover) {
            if (self.refresh_hover == null) {
                self.refresh_hover = try self.renderer.renderToRgba(
                    self.allocator,
                    ToolbarSvg.refresh_hover,
                    BUTTON_SIZE,
                    BUTTON_SIZE,
                );
            }
            return self.refresh_hover.?;
        }
        if (self.refresh_normal == null) {
            self.refresh_normal = try self.renderer.renderToRgba(
                self.allocator,
                ToolbarSvg.refresh_normal,
                BUTTON_SIZE,
                BUTTON_SIZE,
            );
        }
        return self.refresh_normal.?;
    }

    pub fn getStopButton(self: *ToolbarCache, hover: bool) ![]u8 {
        if (hover) {
            if (self.stop_hover == null) {
                self.stop_hover = try self.renderer.renderToRgba(
                    self.allocator,
                    ToolbarSvg.stop_hover,
                    BUTTON_SIZE,
                    BUTTON_SIZE,
                );
            }
            return self.stop_hover.?;
        }
        if (self.stop_normal == null) {
            self.stop_normal = try self.renderer.renderToRgba(
                self.allocator,
                ToolbarSvg.stop_normal,
                BUTTON_SIZE,
                BUTTON_SIZE,
            );
        }
        return self.stop_normal.?;
    }
};
