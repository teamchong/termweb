const std = @import("std");

pub const TerminalSize = struct {
    cols: u16,
    rows: u16,
    width_px: u16,
    height_px: u16,
};

/// Global flag for SIGWINCH (terminal resize) detection
/// Using atomic to safely communicate between signal handler and main thread
var resize_pending = std.atomic.Value(bool).init(false);
var interrupt_pending = std.atomic.Value(bool).init(false);

/// Global state for emergency cleanup on signal
var global_original_termios: ?std.posix.termios = null;
var global_stdin_fd: std.posix.fd_t = std.posix.STDIN_FILENO;

/// SIGWINCH signal handler - sets the resize flag
fn handleSigwinch(_: c_int) callconv(.c) void {
    resize_pending.store(true, .release);
}

/// Signal handler for SIGINT/SIGTERM
/// Sets a flag so the main loop can exit cleanly
fn handleTermSignal(_: c_int) callconv(.c) void {
    if (interrupt_pending.swap(true, .acq_rel)) {
        // Force exit on second signal
        std.process.exit(1);
    }
}

pub const Terminal = struct {
    stdin_fd: std.posix.fd_t,
    original_termios: ?std.posix.termios,
    mouse_enabled: bool,
    sigwinch_installed: bool,

    pub fn init() Terminal {
        return .{
            .stdin_fd = std.posix.STDIN_FILENO,
            .original_termios = null,
            .mouse_enabled = false,
            .sigwinch_installed = false,
        };
    }

    /// Install SIGWINCH handler for terminal resize detection
    pub fn installResizeHandler(self: *Terminal) !void {
        if (self.sigwinch_installed) return;

        const act = std.posix.Sigaction{
            .handler = .{ .handler = handleSigwinch },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };

        std.posix.sigaction(std.posix.SIG.WINCH, &act, null);
        self.sigwinch_installed = true;
    }

    /// Check if terminal was resized (clears the flag)
    pub fn checkResize(_: *Terminal) bool {
        return resize_pending.swap(false, .acq_rel);
    }

    /// Check if an interrupt signal was received
    pub fn checkInterrupt(_: *Terminal) bool {
        return interrupt_pending.load(.acquire);
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

        // Save global state for emergency signal cleanup
        global_original_termios = self.original_termios;
        global_stdin_fd = self.stdin_fd;

        // Install emergency cleanup handlers for SIGINT/SIGTERM
        const term_act = std.posix.Sigaction{
            .handler = .{ .handler = handleTermSignal },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &term_act, null);
        std.posix.sigaction(std.posix.SIG.TERM, &term_act, null);

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

    /// Enable Kitty mouse protocol with pixel coordinates
    pub fn enableMouse(self: *Terminal) !void {
        if (self.mouse_enabled) return;

        var stdout_buf: [256]u8 = undefined;
        const stdout_file = std.fs.File.stdout();
        var stdout_writer = stdout_file.writer(&stdout_buf);
        const writer = &stdout_writer.interface;

        // Enable mouse tracking (all events: press, release, move)
        // 1003h = all motion tracking (needed for cursor display)
        try writer.writeAll("\x1b[?1003h");

        // Enable SGR extended mouse mode (for better coordinate parsing)
        try writer.writeAll("\x1b[?1006h");

        // Enable SGR pixel mouse mode (actual pixel coordinates, not cells)
        try writer.writeAll("\x1b[?1016h");

        // Enable Kitty keyboard protocol (flags: 1=disambiguate, 8=report all keys)
        // Flag 8 is needed for Cmd+letter keys to be reported instead of intercepted
        try writer.writeAll("\x1b[>9u");

        // Enable bracketed paste mode (for proper paste handling)
        try writer.writeAll("\x1b[?2004h");

        try writer.flush();
        self.mouse_enabled = true;
    }

    /// Disable mouse protocol
    pub fn disableMouse(self: *Terminal) !void {
        if (!self.mouse_enabled) return;

        var stdout_buf: [256]u8 = undefined;
        const stdout_file = std.fs.File.stdout();
        var stdout_writer = stdout_file.writer(&stdout_buf);
        const writer = &stdout_writer.interface;

        // Disable Kitty keyboard protocol
        try writer.writeAll("\x1b[<u");

        // Disable bracketed paste mode
        try writer.writeAll("\x1b[?2004l");

        // Disable SGR pixel mouse mode
        try writer.writeAll("\x1b[?1016l");

        // Disable mouse tracking
        try writer.writeAll("\x1b[?1003l");

        // Disable SGR mouse mode
        try writer.writeAll("\x1b[?1006l");

        try writer.flush();
        self.mouse_enabled = false;
    }

    /// Restore original terminal settings
    pub fn restore(self: *Terminal) !void {
        // Disable mouse first (while still in raw mode)
        self.disableMouse() catch {};

        // Drain any buffered input (mouse events, etc.)
        self.drainInput();

        // Restore original terminal settings
        if (self.original_termios) |orig| {
            try std.posix.tcsetattr(self.stdin_fd, .FLUSH, orig);
        }

        // Clear global state (prevents signal handler from double-restoring)
        global_original_termios = null;
    }

    /// Drain any pending input from stdin
    fn drainInput(self: *Terminal) void {
        var buf: [256]u8 = undefined;
        // O_NONBLOCK value (0x0004 on macOS, 0x800 on Linux)
        const O_NONBLOCK: usize = if (@import("builtin").os.tag == .macos) 0x0004 else 0x800;

        // Set non-blocking read temporarily
        const flags = std.posix.fcntl(self.stdin_fd, std.posix.F.GETFL, 0) catch return;
        _ = std.posix.fcntl(self.stdin_fd, std.posix.F.SETFL, flags | O_NONBLOCK) catch return;
        defer _ = std.posix.fcntl(self.stdin_fd, std.posix.F.SETFL, flags) catch {};

        // Read and discard all pending input - loop multiple times to catch any stragglers
        var attempts: u32 = 0;
        while (attempts < 10) : (attempts += 1) {
            var drained_any = false;
            while (true) {
                const n = std.posix.read(self.stdin_fd, &buf) catch break;
                if (n == 0) break;
                drained_any = true;
            }
            if (!drained_any) break;
            // Small delay to let more input arrive
            std.Thread.sleep(5 * std.time.ns_per_ms);
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
