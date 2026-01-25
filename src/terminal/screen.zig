const std = @import("std");

/// Screen control utilities
pub const Screen = struct {
    pub fn clear(writer: anytype) !void {
        // Clear screen and home cursor
        try writer.writeAll("\x1b[2J\x1b[H");
    }

    /// Enter alternate screen buffer (used by fullscreen apps)
    pub fn enterAlternateBuffer(writer: anytype) !void {
        try writer.writeAll("\x1b[?1049h");
    }

    /// Exit alternate screen buffer (restores previous screen content)
    pub fn exitAlternateBuffer(writer: anytype) !void {
        try writer.writeAll("\x1b[?1049l");
    }

    pub fn hideCursor(writer: anytype) !void {
        try writer.writeAll("\x1b[?25l");
    }

    pub fn showCursor(writer: anytype) !void {
        try writer.writeAll("\x1b[?25h");
    }

    pub fn moveCursor(writer: anytype, row: u16, col: u16) !void {
        try writer.print("\x1b[{d};{d}H", .{ row, col });
    }

    pub fn clearLine(writer: anytype) !void {
        try writer.writeAll("\x1b[2K");
    }
};
