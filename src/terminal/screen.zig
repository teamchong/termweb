const std = @import("std");

/// Screen control utilities
pub const Screen = struct {
    pub fn clear(writer: anytype) !void {
        // Clear screen and home cursor
        try writer.writeAll("\x1b[2J\x1b[H");
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
