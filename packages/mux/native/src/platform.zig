//! Platform abstraction layer for termweb-mux.
//!
//! Uses comptime to select platform-specific implementations:
//! - macOS: libghostty + IOSurface + VideoToolbox
//! - Linux: PTY terminal + shared memory + VA-API
//!
//! This module centralizes platform detection and provides unified types
//! for cross-platform code. Import this instead of repeating platform
//! checks throughout the codebase.
//!
const std = @import("std");
const builtin = @import("builtin");

pub const is_macos = builtin.os.tag == .macos;
pub const is_linux = builtin.os.tag == .linux;

// Platform-specific C imports
pub const c = if (is_macos) @cImport({
    @cInclude("libdeflate.h");
    @cInclude("ghostty.h");
    @cInclude("IOSurface/IOSurfaceRef.h");
}) else @cImport({
    @cInclude("libdeflate.h");
    // Linux: no ghostty/IOSurface
});

// Objective-C runtime (macOS only)
pub const objc = if (is_macos) @cImport({
    @cInclude("objc/runtime.h");
    @cInclude("objc/message.h");
}) else struct {
    // Stubs for Linux
    pub const id = *anyopaque;
    pub const SEL = *anyopaque;
    pub const Class = *anyopaque;
};


// Terminal Backend Abstraction


pub const TerminalBackend = if (is_macos) MacOSTerminal else LinuxTerminal;

/// macOS terminal using libghostty
pub const MacOSTerminal = struct {
    app: c.ghostty_app_t,
    surface: c.ghostty_surface_t,

    pub fn init() !MacOSTerminal {
        // Initialize ghostty app
        var runtime_cfg = std.mem.zeroes(c.ghostty_runtime_config_s);
        runtime_cfg.quit_after_last_window_closed = false;

        const app = c.ghostty_app_init(&runtime_cfg) orelse return error.GhosttyInitFailed;
        errdefer c.ghostty_app_release(app);

        return MacOSTerminal{
            .app = app,
            .surface = undefined,
        };
    }

    pub fn deinit(self: *MacOSTerminal) void {
        c.ghostty_app_release(self.app);
    }

    pub fn getIOSurface(self: *MacOSTerminal) ?*anyopaque {
        return c.ghostty_surface_get_iosurface(self.surface);
    }
};

/// Linux terminal using PTY (stub - to be implemented with VTE or raw PTY)
pub const LinuxTerminal = struct {
    pty_fd: ?std.posix.fd_t,
    width: u32,
    height: u32,

    pub fn init() !LinuxTerminal {
        std.debug.print("LinuxTerminal: stub implementation\n", .{});
        return LinuxTerminal{
            .pty_fd = null,
            .width = 80,
            .height = 24,
        };
    }

    pub fn deinit(self: *LinuxTerminal) void {
        if (self.pty_fd) |fd| {
            std.posix.close(fd);
        }
    }

    /// Linux doesn't have IOSurface - returns null
    pub fn getIOSurface(self: *LinuxTerminal) ?*anyopaque {
        _ = self;
        return null;
    }
};


// Surface/Rendering Abstraction


/// Get pixel data from rendering surface
pub fn getSurfacePixels(backend: *TerminalBackend, width: u32, height: u32) ?[]const u8 {
    if (is_macos) {
        // macOS: Get from IOSurface
        const iosurface = backend.getIOSurface() orelse return null;
        const surface_ref: c.IOSurfaceRef = @ptrCast(iosurface);

        _ = c.IOSurfaceLock(surface_ref, c.kIOSurfaceLockReadOnly, null);
        defer _ = c.IOSurfaceUnlock(surface_ref, c.kIOSurfaceLockReadOnly, null);

        const base_addr = c.IOSurfaceGetBaseAddress(surface_ref);
        if (base_addr == null) return null;

        const bytes_per_row = c.IOSurfaceGetBytesPerRow(surface_ref);
        const total_bytes = bytes_per_row * height;

        return @as([*]const u8, @ptrCast(base_addr))[0..total_bytes];
    } else {
        // Linux: Would get from framebuffer/shared memory
        _ = backend;
        _ = width;
        _ = height;
        return null;
    }
}


// Utility Functions


/// Get platform name for logging
pub fn getPlatformName() []const u8 {
    return if (is_macos) "macOS" else if (is_linux) "Linux" else "Unknown";
}

/// Check if video encoding is available
pub fn hasVideoEncoding() bool {
    return is_macos; // Linux stub doesn't encode yet
}
