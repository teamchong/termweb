//! Ghostty C API stub types for Linux compilation.
//!
//! Provides type-compatible stubs for the ghostty.h C API, allowing the
//! codebase to compile on Linux without libghostty. These stubs define:
//! - Opaque handle types (ghostty_app_t, ghostty_surface_t, etc.)
//! - Input constants (modifier keys, mouse buttons, actions)
//! - Callback signatures for clipboard and title operations
//!
//! On Linux, actual terminal emulation uses `pty_terminal.zig` instead.
//! These stubs only exist to satisfy type checking at compile time.
//!
const std = @import("std");

// Constants
pub const GHOSTTY_SUCCESS: c_int = 0;
pub const GHOSTTY_ACTION_SET_TITLE: c_int = 1;
pub const GHOSTTY_ACTION_SET_MOUSE_SHAPE: c_int = 2;
pub const GHOSTTY_ACTION_COPY_TO_CLIPBOARD: c_int = 3;
pub const GHOSTTY_ACTION_PASTE_FROM_CLIPBOARD: c_int = 4;
pub const GHOSTTY_ACTION_REPORT_TITLE: c_int = 5;
pub const GHOSTTY_CLIPBOARD_STANDARD: c_int = 0;
pub const GHOSTTY_CLIPBOARD_SELECTION: c_int = 1;
pub const GHOSTTY_CLIPBOARD_PRIMARY: c_int = 2;

// Input constants
pub const GHOSTTY_MODS_SHIFT: u32 = 1;
pub const GHOSTTY_MODS_CTRL: u32 = 2;
pub const GHOSTTY_MODS_ALT: u32 = 4;
pub const GHOSTTY_MODS_SUPER: u32 = 8;
pub const GHOSTTY_ACTION_RELEASE: u32 = 0;
pub const GHOSTTY_ACTION_PRESS: u32 = 1;
pub const GHOSTTY_ACTION_REPEAT: u32 = 2;
pub const GHOSTTY_MOUSE_PRESS: u32 = 1;
pub const GHOSTTY_MOUSE_RELEASE: u32 = 0;
pub const GHOSTTY_MOUSE_LEFT: u32 = 0;
pub const GHOSTTY_MOUSE_RIGHT: u32 = 1;
pub const GHOSTTY_MOUSE_MIDDLE: u32 = 2;
pub const GHOSTTY_PLATFORM_MACOS: u32 = 0;
pub const GHOSTTY_PLATFORM_LINUX: u32 = 1;

// Opaque handle types (pointers to incomplete structs)
pub const ghostty_app_t = ?*anyopaque;
pub const ghostty_surface_t = ?*anyopaque;
pub const ghostty_config_t = ?*anyopaque;

pub const ghostty_runtime_config_s = extern struct {
    userdata: ?*anyopaque = null,
    supports_selection_clipboard: bool = true,
    wakeup_cb: ?*const fn (?*anyopaque) callconv(.c) void = null,
    action_cb: ?*const fn (ghostty_app_t, ghostty_target_s, ghostty_action_s) callconv(.c) bool = null,
    read_clipboard_cb: ?*const fn (?*anyopaque, ghostty_clipboard_e, ?*anyopaque) callconv(.c) void = null,
    confirm_read_clipboard_cb: ?*const fn (?*anyopaque, [*c]const u8, ?*anyopaque, ghostty_clipboard_request_e) callconv(.c) void = null,
    write_clipboard_cb: ?*const fn (?*anyopaque, ghostty_clipboard_e, [*c]const ghostty_clipboard_content_s, usize, bool) callconv(.c) void = null,
    close_surface_cb: ?*const fn (?*anyopaque, bool) callconv(.c) void = null,
};

pub const ghostty_surface_config_s = extern struct {
    platform_tag: u32 = GHOSTTY_PLATFORM_LINUX,
    platform: ?*anyopaque = null,
    width: u32 = 800,
    height: u32 = 600,
    scale_factor: f64 = 1.0,
    font_size: f32 = 12.0,
    working_directory: ?[*:0]const u8 = null,
    command: ?[*:0]const u8 = null,
    _padding: [64]u8 = [_]u8{0} ** 64,
};

pub const ghostty_input_key_s = extern struct {
    action: u8 = 0,
    mods: ghostty_input_mods_e = 0,
    keycode: u32 = 0,
    text: [32]u8 = [_]u8{0} ** 32,
    text_len: u8 = 0,
    composing: bool = false,
};

pub const ghostty_input_mods_e = u32;
pub const ghostty_input_mouse_state_e = u32;
pub const ghostty_input_mouse_button_e = u32;
pub const ghostty_clipboard_e = u32;
pub const ghostty_clipboard_request_e = u32;

pub const ghostty_clipboard_content_s = extern struct {
    mime: ?[*:0]const u8 = null,
    data: ?[*]const u8 = null,
    len: usize = 0,
};

pub const ghostty_action_s = extern struct {
    tag: c_int = 0,
    data: extern union {
        set_title: [*:0]const u8,
        _padding: [64]u8,
    } = .{ ._padding = [_]u8{0} ** 64 },
};

pub const ghostty_target_s = extern struct {
    tag: u32 = 0,
    surface: ghostty_surface_t = null,
};

pub const ghostty_size_s = extern struct {
    width: u32 = 0,
    height: u32 = 0,
    columns: u32 = 80,
    rows: u32 = 24,
};

// Stub functions - all return failure or no-op
pub fn ghostty_init(_: c_int, _: ?*?*anyopaque) callconv(.c) c_int {
    std.debug.print("ghostty_stub: ghostty_init (Linux stub)\n", .{});
    return 0; // Success
}

pub fn ghostty_config_new() callconv(.c) ghostty_config_t {
    return null;
}

pub fn ghostty_config_load_default_files(_: ghostty_config_t) callconv(.c) void {}

pub fn ghostty_config_finalize(_: ghostty_config_t) callconv(.c) void {}

pub fn ghostty_config_free(_: ghostty_config_t) callconv(.c) void {}

pub fn ghostty_app_new(_: *const ghostty_runtime_config_s, _: ghostty_config_t) callconv(.c) ghostty_app_t {
    std.debug.print("ghostty_stub: ghostty_app_new (Linux stub - no terminal yet)\n", .{});
    // Return a sentinel value instead of null so the app can "run"
    return @ptrFromInt(0xDEADBEEF);
}

pub fn ghostty_app_free(_: ghostty_app_t) callconv(.c) void {}

pub fn ghostty_app_tick(_: ghostty_app_t) callconv(.c) void {}

pub fn ghostty_surface_config_new() callconv(.c) ghostty_surface_config_s {
    return ghostty_surface_config_s{};
}

pub fn ghostty_surface_new(_: ghostty_app_t, _: *ghostty_surface_config_s) callconv(.c) ghostty_surface_t {
    std.debug.print("ghostty_stub: ghostty_surface_new (Linux stub)\n", .{});
    return @ptrFromInt(0xCAFEBABE);
}

pub fn ghostty_surface_free(_: ghostty_surface_t) callconv(.c) void {}

pub fn ghostty_surface_set_focus(_: ghostty_surface_t, _: bool) callconv(.c) void {}

pub fn ghostty_surface_set_occlusion(_: ghostty_surface_t, _: bool) callconv(.c) void {}

pub fn ghostty_surface_set_size(_: ghostty_surface_t, _: u32, _: u32) callconv(.c) void {}

pub fn ghostty_surface_size(_: ghostty_surface_t) callconv(.c) ghostty_size_s {
    return ghostty_size_s{ .width = 800, .height = 600 };
}

pub fn ghostty_surface_draw(_: ghostty_surface_t) callconv(.c) void {}

pub fn ghostty_surface_key(_: ghostty_surface_t, _: ghostty_input_key_s) callconv(.c) bool {
    return true;
}

pub fn ghostty_surface_text(_: ghostty_surface_t, _: *const [*]const u8, _: usize) callconv(.c) void {}

pub fn ghostty_surface_mouse_pos(_: ghostty_surface_t, _: f64, _: f64, _: ghostty_input_mods_e) callconv(.c) void {}

pub fn ghostty_surface_mouse_button(_: ghostty_surface_t, _: ghostty_input_mouse_state_e, _: ghostty_input_mouse_button_e, _: ghostty_input_mods_e) callconv(.c) bool {
    return true;
}

pub fn ghostty_surface_mouse_scroll(_: ghostty_surface_t, _: f64, _: f64, _: ghostty_input_mods_e) callconv(.c) void {}

pub fn ghostty_surface_binding_action(_: ghostty_surface_t, _: [*]const u8, _: usize) callconv(.c) bool {
    return false;
}

pub fn ghostty_surface_complete_clipboard_request(_: ghostty_surface_t, _: [*c]const u8, _: ?*anyopaque, _: bool) callconv(.c) void {}

// IOSurface stubs
pub const struct___IOSurface = opaque {};
pub const IOSurfaceRef = ?*struct___IOSurface;
pub const kIOSurfaceLockReadOnly: u32 = 1;

pub fn IOSurfaceLock(_: IOSurfaceRef, _: u32, _: ?*anyopaque) callconv(.c) c_int {
    return 0;
}

pub fn IOSurfaceUnlock(_: IOSurfaceRef, _: u32, _: ?*anyopaque) callconv(.c) c_int {
    return 0;
}

pub fn IOSurfaceGetSeed(_: IOSurfaceRef) callconv(.c) u32 {
    return 0;
}

pub fn IOSurfaceGetBaseAddress(_: IOSurfaceRef) callconv(.c) ?*anyopaque {
    return null;
}

pub fn IOSurfaceGetBytesPerRow(_: IOSurfaceRef) callconv(.c) usize {
    return 0;
}

pub fn IOSurfaceGetWidth(_: IOSurfaceRef) callconv(.c) usize {
    return 0;
}

pub fn IOSurfaceGetHeight(_: IOSurfaceRef) callconv(.c) usize {
    return 0;
}
