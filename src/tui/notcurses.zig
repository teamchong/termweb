/// Zig bindings for notcurses TUI library
const std = @import("std");
const c = @cImport({
    @cInclude("notcurses/notcurses.h");
});

pub const Notcurses = c.notcurses;
pub const Plane = c.ncplane;
pub const Visual = c.ncvisual;
pub const Reader = c.ncreader;
pub const Input = c.ncinput;

pub const Align = enum(c_uint) {
    unaligned = c.NCALIGN_UNALIGNED,
    left = c.NCALIGN_LEFT,
    center = c.NCALIGN_CENTER,
    right = c.NCALIGN_RIGHT,
};

pub const Scale = enum(c_uint) {
    none = c.NCSCALE_NONE,
    scale = c.NCSCALE_SCALE,
    stretch = c.NCSCALE_STRETCH,
    none_hires = c.NCSCALE_NONE_HIRES,
    scale_hires = c.NCSCALE_SCALE_HIRES,
};

pub const Blitter = enum(c_uint) {
    default = c.NCBLIT_DEFAULT,
    @"1x1" = c.NCBLIT_1x1,
    @"2x1" = c.NCBLIT_2x1,
    @"2x2" = c.NCBLIT_2x2,
    @"3x2" = c.NCBLIT_3x2,
    @"4x2" = c.NCBLIT_4x2,
    braille = c.NCBLIT_BRAILLE,
    pixel = c.NCBLIT_PIXEL,
};

pub const Options = extern struct {
    termtype: [*c]const u8 = null,
    loglevel: c_int = 0,
    margin_t: c_uint = 0,
    margin_r: c_uint = 0,
    margin_b: c_uint = 0,
    margin_l: c_uint = 0,
    flags: u64 = 0,
};

pub const PlaneOptions = extern struct {
    y: c_int = 0,
    x: c_int = 0,
    rows: c_uint = 0,
    cols: c_uint = 0,
    userptr: ?*anyopaque = null,
    name: [*c]const u8 = null,
    resizecb: ?*const fn (*Plane) callconv(.C) c_int = null,
    flags: u64 = 0,
    margin_b: c_uint = 0,
    margin_r: c_uint = 0,
};

pub const VisualOptions = extern struct {
    n: ?*Plane = null,
    scaling: Scale = .none,
    y: c_int = 0,
    x: c_int = 0,
    begy: c_uint = 0,
    begx: c_uint = 0,
    leny: c_uint = 0,
    lenx: c_uint = 0,
    blitter: Blitter = .default,
    flags: u64 = 0,
    transcolor: u32 = 0,
    pxoffy: c_uint = 0,
    pxoffx: c_uint = 0,
};

pub const ReaderOptions = extern struct {
    tchannels: u64 = 0,
    tattrword: u32 = 0,
    flags: u64 = 0,
};

/// Initialize notcurses
pub fn init(opts: ?*const Options) ?*Notcurses {
    return c.notcurses_init(@ptrCast(opts), null);
}

/// Stop notcurses and restore terminal
pub fn stop(nc: *Notcurses) void {
    _ = c.notcurses_stop(nc);
}

/// Get the standard plane
pub fn stdplane(nc: *Notcurses) *Plane {
    return c.notcurses_stdplane(nc).?;
}

/// Render all planes to the terminal
pub fn render(nc: *Notcurses) !void {
    if (c.notcurses_render(nc) != 0) {
        return error.RenderFailed;
    }
}

/// Get terminal dimensions
pub fn termDimYx(nc: *Notcurses) struct { rows: u32, cols: u32 } {
    var rows: c_uint = 0;
    var cols: c_uint = 0;
    _ = c.notcurses_term_dim_yx(nc, &rows, &cols);
    return .{ .rows = rows, .cols = cols };
}

/// Poll for input (non-blocking)
pub fn inputreadyFd(nc: *Notcurses) c_int {
    return c.notcurses_inputready_fd(nc);
}

/// Get input (blocking with timeout in ns, 0 = non-blocking, -1 = blocking)
pub fn get(nc: *Notcurses, timeout_ns: i64, ni: *Input) u32 {
    var ts: c.struct_timespec = undefined;
    if (timeout_ns >= 0) {
        ts.tv_sec = @intCast(@divFloor(timeout_ns, std.time.ns_per_s));
        ts.tv_nsec = @intCast(@mod(timeout_ns, std.time.ns_per_s));
        return c.notcurses_get(nc, &ts, ni);
    }
    return c.notcurses_get(nc, null, ni);
}

// Plane functions
pub const plane = struct {
    /// Create a new plane
    pub fn create(parent: *Plane, opts: *const PlaneOptions) ?*Plane {
        return c.ncplane_create(parent, @ptrCast(opts));
    }

    /// Destroy a plane
    pub fn destroy(n: *Plane) void {
        _ = c.ncplane_destroy(n);
    }

    /// Get plane dimensions
    pub fn dimYx(n: *const Plane) struct { rows: u32, cols: u32 } {
        var rows: c_uint = 0;
        var cols: c_uint = 0;
        c.ncplane_dim_yx(n, &rows, &cols);
        return .{ .rows = rows, .cols = cols };
    }

    /// Move cursor to position
    pub fn cursorMoveYx(n: *Plane, y: i32, x: i32) !void {
        if (c.ncplane_cursor_move_yx(n, y, x) != 0) {
            return error.CursorMoveFailed;
        }
    }

    /// Put a string at current cursor position
    pub fn putstr(n: *Plane, s: [*:0]const u8) i32 {
        return c.ncplane_putstr(n, s);
    }

    /// Put a string at specific position
    pub fn putstrYx(n: *Plane, y: i32, x: i32, s: [*:0]const u8) i32 {
        return c.ncplane_putstr_yx(n, y, x, s);
    }

    /// Put aligned string
    pub fn putstrAligned(n: *Plane, y: i32, align_: Align, s: [*:0]const u8) i32 {
        return c.ncplane_putstr_aligned(n, y, @intFromEnum(align_), s);
    }

    /// Set foreground color (RGB)
    pub fn setFgRgb8(n: *Plane, r: u8, g: u8, b: u8) void {
        _ = c.ncplane_set_fg_rgb8(n, r, g, b);
    }

    /// Set background color (RGB)
    pub fn setBgRgb8(n: *Plane, r: u8, g: u8, b: u8) void {
        _ = c.ncplane_set_bg_rgb8(n, r, g, b);
    }

    /// Set foreground to default
    pub fn setFgDefault(n: *Plane) void {
        _ = c.ncplane_set_fg_default(n);
    }

    /// Set background to default
    pub fn setBgDefault(n: *Plane) void {
        _ = c.ncplane_set_bg_default(n);
    }

    /// Erase the plane
    pub fn erase(n: *Plane) void {
        c.ncplane_erase(n);
    }

    /// Set styles (bold, italic, etc.)
    pub fn setStyles(n: *Plane, stylebits: u16) void {
        c.ncplane_set_styles(n, stylebits);
    }

    /// Turn on styles
    pub fn stylesOn(n: *Plane, stylebits: u16) void {
        c.ncplane_on_styles(n, stylebits);
    }

    /// Turn off styles
    pub fn stylesOff(n: *Plane, stylebits: u16) void {
        c.ncplane_off_styles(n, stylebits);
    }

    /// Draw a horizontal line
    pub fn hline(n: *Plane, egc: [*:0]const u8, len: u32) i32 {
        var cell: c.nccell = std.mem.zeroes(c.nccell);
        _ = c.nccell_load(n, &cell, egc);
        const result = c.ncplane_hline(n, &cell, len);
        c.nccell_release(n, &cell);
        return result;
    }

    /// Draw a box
    pub fn boxDouble(n: *Plane, ystop: u32, xstop: u32) !void {
        if (c.ncplane_double_box(n, 0, 0, ystop, xstop, 0) != 0) {
            return error.BoxFailed;
        }
    }

    /// Move plane to position
    pub fn moveYx(n: *Plane, y: i32, x: i32) !void {
        if (c.ncplane_move_yx(n, y, x) != 0) {
            return error.MoveFailed;
        }
    }

    /// Resize plane
    pub fn resize(n: *Plane, rows: u32, cols: u32) !void {
        if (c.ncplane_resize_simple(n, rows, cols) != 0) {
            return error.ResizeFailed;
        }
    }
};

// Visual functions (for images/video)
pub const visual = struct {
    /// Create visual from RGBA data
    pub fn fromRgba(rgba: [*]const u8, rows: i32, rowstride: i32, cols: i32) ?*Visual {
        return c.ncvisual_from_rgba(rgba, rows, rowstride, cols);
    }

    /// Create visual from file
    pub fn fromFile(path: [*:0]const u8) ?*Visual {
        return c.ncvisual_from_file(path);
    }

    /// Destroy visual
    pub fn destroy(ncv: *Visual) void {
        c.ncvisual_destroy(ncv);
    }

    /// Blit visual to plane
    pub fn blit(nc: *Notcurses, ncv: *Visual, opts: ?*const VisualOptions) ?*Plane {
        return c.ncvisual_blit(nc, ncv, @ptrCast(opts));
    }

    /// Decode next frame (for video/animation)
    pub fn decode(ncv: *Visual) !void {
        if (c.ncvisual_decode(ncv) != 0) {
            return error.DecodeFailed;
        }
    }

    /// Resize visual
    pub fn resizeNoninterpolative(ncv: *Visual, rows: u32, cols: u32) !void {
        if (c.ncvisual_resize_noninterpolative(ncv, rows, cols) != 0) {
            return error.ResizeFailed;
        }
    }
};

// Reader widget (for text input like address bar)
pub const reader = struct {
    /// Create a reader widget
    pub fn create(n: *Plane, opts: ?*const ReaderOptions) ?*Reader {
        return c.ncreader_create(n, @ptrCast(opts));
    }

    /// Destroy reader
    pub fn destroy(nr: *Reader) void {
        c.ncreader_destroy(nr, null);
    }

    /// Get the reader's plane
    pub fn getPlane(nr: *Reader) *Plane {
        return c.ncreader_plane(nr).?;
    }

    /// Offer input to reader
    pub fn offerInput(nr: *Reader, ni: *const Input) bool {
        return c.ncreader_offer_input(nr, ni);
    }

    /// Get reader contents
    pub fn contents(nr: *const Reader) ?[*:0]u8 {
        return c.ncreader_contents(nr);
    }

    /// Clear reader
    pub fn clear(nr: *Reader) void {
        _ = c.ncreader_clear(nr);
    }

    /// Write text to reader
    pub fn writeEgc(nr: *Reader, egc: [*:0]const u8) !void {
        if (c.ncreader_write_egc(nr, egc) != 0) {
            return error.WriteFailed;
        }
    }
};

// Style constants
pub const STYLE_BOLD: u16 = c.NCSTYLE_BOLD;
pub const STYLE_ITALIC: u16 = c.NCSTYLE_ITALIC;
pub const STYLE_UNDERLINE: u16 = c.NCSTYLE_UNDERLINE;
pub const STYLE_STRUCK: u16 = c.NCSTYLE_STRUCK;

// Key constants
pub const KEY_RESIZE: u32 = c.NCKEY_RESIZE;
pub const KEY_UP: u32 = c.NCKEY_UP;
pub const KEY_DOWN: u32 = c.NCKEY_DOWN;
pub const KEY_LEFT: u32 = c.NCKEY_LEFT;
pub const KEY_RIGHT: u32 = c.NCKEY_RIGHT;
pub const KEY_ENTER: u32 = c.NCKEY_ENTER;
pub const KEY_BACKSPACE: u32 = c.NCKEY_BACKSPACE;
pub const KEY_TAB: u32 = c.NCKEY_TAB;
pub const KEY_ESC: u32 = c.NCKEY_ESC;
pub const KEY_BUTTON1: u32 = c.NCKEY_BUTTON1;
pub const KEY_BUTTON2: u32 = c.NCKEY_BUTTON2;
pub const KEY_BUTTON3: u32 = c.NCKEY_BUTTON3;
pub const KEY_SCROLL_UP: u32 = c.NCKEY_SCROLL_UP;
pub const KEY_SCROLL_DOWN: u32 = c.NCKEY_SCROLL_DOWN;

// Option flags
pub const OPTION_SUPPRESS_BANNERS: u64 = c.NCOPTION_SUPPRESS_BANNERS;
pub const OPTION_NO_ALTERNATE_SCREEN: u64 = c.NCOPTION_NO_ALTERNATE_SCREEN;
pub const OPTION_NO_CLEAR_BITMAPS: u64 = c.NCOPTION_NO_CLEAR_BITMAPS;
pub const OPTION_PRESERVE_CURSOR: u64 = c.NCOPTION_PRESERVE_CURSOR;

// Helper to check if input is a mouse event
pub fn inputIsMouse(ni: *const Input) bool {
    return ni.id >= c.NCKEY_BUTTON1 and ni.id <= c.NCKEY_BUTTON11;
}

// Helper to get mouse coordinates
pub fn inputMouseYx(ni: *const Input) struct { y: i32, x: i32 } {
    return .{ .y = ni.y, .x = ni.x };
}
