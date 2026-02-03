// Cross-platform terminal abstraction
// Uses comptime to select:
// - macOS: libghostty
// - Linux: PTY-based terminal

const std = @import("std");
const builtin = @import("builtin");

pub const is_macos = builtin.os.tag == .macos;
pub const is_linux = builtin.os.tag == .linux;

// Import platform-specific implementation
const PtyTerminal = if (is_linux) @import("pty_terminal.zig").Terminal else void;

// C imports for macOS
pub const c = if (is_macos) @cImport({
    @cInclude("libdeflate.h");
    @cInclude("ghostty.h");
    @cInclude("IOSurface/IOSurfaceRef.h");
}) else @cImport({
    @cInclude("libdeflate.h");
});

// Objective-C runtime (macOS only)
pub const objc = if (is_macos) @cImport({
    @cInclude("objc/runtime.h");
    @cInclude("objc/message.h");
}) else struct {
    pub const id = ?*anyopaque;
};

/// Cross-platform terminal handle
pub const TerminalHandle = if (is_macos)
    struct {
        app: c.ghostty_app_t,
        surface: c.ghostty_surface_t,
        nsview: objc.id,
    }
else
    *PtyTerminal;

/// Initialize terminal subsystem
pub fn initTerminal() !void {
    if (is_macos) {
        const init_result = c.ghostty_init(0, null);
        if (init_result != c.GHOSTTY_SUCCESS) return error.GhosttyInitFailed;
    }
    // Linux: no global init needed
}

/// Create a new terminal surface
pub fn createSurface(allocator: std.mem.Allocator, width: u32, height: u32) !TerminalHandle {
    if (is_macos) {
        @compileError("macOS surface creation not implemented in this abstraction");
    } else {
        return try PtyTerminal.init(allocator, width, height);
    }
}

/// Destroy terminal surface
pub fn destroySurface(handle: TerminalHandle) void {
    if (is_macos) {
        c.ghostty_surface_free(handle.surface);
    } else {
        handle.deinit();
    }
}

/// Get framebuffer data for encoding
pub fn getFramebuffer(handle: TerminalHandle) ?[]const u8 {
    if (is_macos) {
        // macOS: get from IOSurface
        return null; // Handled differently in main.zig
    } else {
        handle.render();
        return handle.getFramebuffer();
    }
}

/// Process terminal (read PTY, render)
pub fn tick(handle: TerminalHandle) !void {
    if (is_macos) {
        // macOS: ghostty_app_tick called separately
    } else {
        try handle.tick();
    }
}

/// Write input to terminal
pub fn writeInput(handle: TerminalHandle, data: []const u8) !void {
    if (is_macos) {
        // macOS: handled through ghostty_surface_key
    } else {
        try handle.write(data);
    }
}

/// Resize terminal
pub fn resize(handle: TerminalHandle, width: u32, height: u32) !void {
    if (is_macos) {
        c.ghostty_surface_set_size(handle.surface, width, height);
    } else {
        try handle.resize(width, height);
    }
}

/// Get terminal size
pub fn getSize(handle: TerminalHandle) struct { cols: u32, rows: u32, width: u32, height: u32 } {
    if (is_macos) {
        const size = c.ghostty_surface_size(handle.surface);
        return .{
            .cols = size.columns,
            .rows = size.rows,
            .width = size.width_px,
            .height = size.height_px,
        };
    } else {
        return handle.getSize();
    }
}
