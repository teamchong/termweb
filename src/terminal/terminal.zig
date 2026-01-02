const std = @import("std");

pub const TerminalSize = struct {
    cols: u16,
    rows: u16,
    width_px: u16,
    height_px: u16,
};

pub const Terminal = struct {
    stdin_fd: std.posix.fd_t,
    original_termios: ?std.posix.termios,

    pub fn init() Terminal {
        return .{
            .stdin_fd = std.posix.STDIN_FILENO,
            .original_termios = null,
        };
    }

    /// Enter raw mode (disable line buffering, echo)
    pub fn enterRawMode(self: *Terminal) !void {
        // Check if stdin is a TTY
        if (!std.posix.isatty(self.stdin_fd)) {
            std.debug.print("Error: stdin is not a terminal\n", .{});
            std.debug.print("termweb requires an interactive terminal (TTY) to run.\n", .{});
            return error.NotATty;
        }

        // Save original settings
        self.original_termios = try std.posix.tcgetattr(self.stdin_fd);

        var raw = self.original_termios.?;

        // Disable canonical mode, echo, signals
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;

        // Disable input processing
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.iflag.BRKINT = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;

        // Disable output processing
        raw.oflag.OPOST = false;

        // Character-at-a-time input (non-blocking)
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;

        try std.posix.tcsetattr(self.stdin_fd, .FLUSH, raw);
    }

    /// Restore original terminal settings
    pub fn restore(self: *Terminal) !void {
        if (self.original_termios) |orig| {
            try std.posix.tcsetattr(self.stdin_fd, .FLUSH, orig);
        }
    }

    /// Get terminal size with pixel dimensions
    pub fn getSize(self: *Terminal) !TerminalSize {
        var ws: std.posix.winsize = undefined;

        const result = std.c.ioctl(self.stdin_fd, std.posix.T.IOCGWINSZ, &ws);

        if (result != 0) {
            return error.IoctlFailed;
        }

        return TerminalSize{
            .cols = ws.col,
            .rows = ws.row,
            .width_px = ws.xpixel,
            .height_px = ws.ypixel,
        };
    }

    /// Cleanup (called on deinit or crash)
    pub fn deinit(self: *Terminal) void {
        self.restore() catch {};
    }
};
