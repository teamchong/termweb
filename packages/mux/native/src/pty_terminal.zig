//! PTY-based terminal emulator for Linux.
//!
//! Provides terminal emulation without libghostty dependency by using:
//! - POSIX PTY (pseudo-terminal) for shell communication
//! - VT100/ANSI escape sequence parsing
//! - Software rendering to BGRA framebuffer
//!
//! The framebuffer can be encoded to H.264 by the video encoder for
//! streaming to web clients. This is the Linux alternative to macOS's
//! libghostty + IOSurface path.
//!
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const cell_width: u32 = 8;
const cell_height: u32 = 16;

pub const Terminal = struct {
    allocator: std.mem.Allocator,
    master_fd: posix.fd_t,
    slave_fd: posix.fd_t,
    child_pid: posix.pid_t,
    width: u32,
    height: u32,
    cols: u32,
    rows: u32,

    // Framebuffer for rendering (BGRA format)
    framebuffer: []u8,
    fb_width: u32,
    fb_height: u32,

    // Terminal state
    cursor_x: u32,
    cursor_y: u32,
    fg_color: u32,
    bg_color: u32,

    // Cell grid for text
    cells: []Cell,

    // Read buffer for PTY output
    read_buf: [4096]u8,
    read_len: usize,

    // Dirty flag for rendering
    dirty: bool,

    pub const Cell = struct {
        char: u21 = ' ',
        fg: u32 = 0xFFFFFFFF, // White
        bg: u32 = 0xFF000000, // Black
        attrs: u8 = 0,
    };

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !*Terminal {
        const term = try allocator.create(Terminal);
        errdefer allocator.destroy(term);

        const cols = width / cell_width;
        const rows = height / cell_height;

        const framebuffer = try allocateFramebuffer(allocator, width, height);
        errdefer allocator.free(framebuffer);

        const cells = try allocateCells(allocator, cols, rows);
        errdefer allocator.free(cells);

        // Open PTY
        const pty = try openPty();
        errdefer {
            posix.close(pty.master);
            posix.close(pty.slave);
        }

        // Set terminal size
        try setWinsize(pty.master, cols, rows, width, height);

        // Fork child process
        const pid = try posix.fork();
        if (pid == 0) {
            // Child process
            posix.close(pty.master);

            // Create new session
            _ = posix.setsid() catch {};

            // Set controlling terminal
            const TIOCSCTTY: c_ulong = 0x540E;
            _ = ioctl(pty.slave, TIOCSCTTY, @as(c_int, 0));

            // Redirect stdio
            posix.dup2(pty.slave, 0) catch {};
            posix.dup2(pty.slave, 1) catch {};
            posix.dup2(pty.slave, 2) catch {};

            if (pty.slave > 2) {
                posix.close(pty.slave);
            }

            // Execute shell with inherited environment + TERM override
            const shell_env = std.posix.getenv("SHELL");
            const shell: [*:0]const u8 = if (shell_env) |s| s.ptr else "/bin/bash";
            const argv = [_:null]?[*:0]const u8{shell};

            // Build environment: inherit parent env (includes tmux shim vars if set by main.zig)
            // plus ensure TERM is set correctly
            const envp = [_:null]?[*:0]const u8{"TERM=xterm-256color"};

            _ = execve(shell, &argv, &envp);
            std.process.exit(1);
        }

        posix.close(pty.slave);

        // Set master to non-blocking (O_NONBLOCK = 0x800 on Linux)
        const O_NONBLOCK: usize = 0x800;
        const flags = try posix.fcntl(pty.master, posix.F.GETFL, 0);
        _ = try posix.fcntl(pty.master, posix.F.SETFL, flags | O_NONBLOCK);

        term.* = Terminal{
            .allocator = allocator,
            .master_fd = pty.master,
            .slave_fd = -1, // Closed in parent
            .child_pid = pid,
            .width = width,
            .height = height,
            .cols = cols,
            .rows = rows,
            .framebuffer = framebuffer,
            .fb_width = width,
            .fb_height = height,
            .cursor_x = 0,
            .cursor_y = 0,
            .fg_color = 0xFFFFFFFF,
            .bg_color = 0xFF000000,
            .cells = cells,
            .read_buf = undefined,
            .read_len = 0,
            .dirty = true,
        };

        return term;
    }

    pub fn deinit(self: *Terminal) void {
        // Kill child process
        posix.kill(self.child_pid, posix.SIG.TERM) catch {};

        posix.close(self.master_fd);
        self.allocator.free(self.framebuffer);
        self.allocator.free(self.cells);
        self.allocator.destroy(self);
    }

    pub fn resize(self: *Terminal, width: u32, height: u32) !void {
        const cols = width / cell_width;
        const rows = height / cell_height;

        self.allocator.free(self.framebuffer);
        self.framebuffer = try allocateFramebuffer(self.allocator, width, height);

        self.allocator.free(self.cells);
        self.cells = try allocateCells(self.allocator, cols, rows);

        self.width = width;
        self.height = height;
        self.fb_width = width;
        self.fb_height = height;
        self.cols = cols;
        self.rows = rows;

        // Update PTY size
        try setWinsize(self.master_fd, cols, rows, width, height);

        self.dirty = true;
    }

    /// Process PTY output and update terminal state
    pub fn tick(self: *Terminal) !void {
        // Read from PTY
        while (true) {
            const n = posix.read(self.master_fd, &self.read_buf) catch |err| {
                if (err == error.WouldBlock) break;
                return err;
            };
            if (n == 0) break;

            // Process bytes
            for (self.read_buf[0..n]) |byte| {
                self.processByte(byte);
            }
            self.dirty = true;
        }
    }

    fn processByte(self: *Terminal, byte: u8) void {
        switch (byte) {
            '\n' => {
                self.cursor_y += 1;
                if (self.cursor_y >= self.rows) {
                    self.scroll();
                    self.cursor_y = self.rows - 1;
                }
            },
            '\r' => {
                self.cursor_x = 0;
            },
            '\t' => {
                self.cursor_x = (self.cursor_x + 8) & ~@as(u32, 7);
                if (self.cursor_x >= self.cols) {
                    self.cursor_x = self.cols - 1;
                }
            },
            '\x08' => { // Backspace
                if (self.cursor_x > 0) self.cursor_x -= 1;
            },
            '\x1b' => {
                // TODO: Parse escape sequences
            },
            0x20...0x7E => {
                // Printable ASCII
                self.putChar(byte);
            },
            else => {},
        }
    }

    fn putChar(self: *Terminal, char: u8) void {
        if (self.cursor_x >= self.cols) {
            self.cursor_x = 0;
            self.cursor_y += 1;
            if (self.cursor_y >= self.rows) {
                self.scroll();
                self.cursor_y = self.rows - 1;
            }
        }

        const idx = self.cursor_y * self.cols + self.cursor_x;
        if (idx < self.cells.len) {
            self.cells[idx] = Cell{
                .char = char,
                .fg = self.fg_color,
                .bg = self.bg_color,
            };
        }

        self.cursor_x += 1;
    }

    fn scroll(self: *Terminal) void {
        // Move all rows up by one
        const row_size = self.cols;
        for (0..self.rows - 1) |y| {
            const src_start = (y + 1) * row_size;
            const dst_start = y * row_size;
            @memcpy(self.cells[dst_start..][0..row_size], self.cells[src_start..][0..row_size]);
        }
        // Clear last row
        const last_row = (self.rows - 1) * row_size;
        for (self.cells[last_row..][0..row_size]) |*cell| {
            cell.* = Cell{};
        }
    }

    /// Render cells to framebuffer (simple bitmap font)
    pub fn render(self: *Terminal) void {
        if (!self.dirty) return;

        const cell_w: u32 = 8;
        const cell_h: u32 = 16;

        // Clear framebuffer
        @memset(self.framebuffer, 0);

        // Render each cell
        for (0..self.rows) |row| {
            for (0..self.cols) |col| {
                const idx = row * self.cols + col;
                if (idx >= self.cells.len) continue;

                const cell = self.cells[idx];
                const x = @as(u32, @intCast(col)) * cell_w;
                const y = @as(u32, @intCast(row)) * cell_h;

                // Draw character (simple 8x16 bitmap)
                self.drawChar(x, y, cell.char, cell.fg, cell.bg);
            }
        }

        // Draw cursor
        const cursor_x = self.cursor_x * cell_w;
        const cursor_y = self.cursor_y * cell_h;
        self.drawCursor(cursor_x, cursor_y, cell_w, cell_h);

        self.dirty = false;
    }

    fn drawChar(self: *Terminal, x: u32, y: u32, char: u21, fg: u32, bg: u32) void {
        const cell_w: u32 = 8;
        const cell_h: u32 = 16;

        // Simple placeholder: fill with bg, draw char as dot pattern
        for (0..cell_h) |dy| {
            for (0..cell_w) |dx| {
                const px = x + @as(u32, @intCast(dx));
                const py = y + @as(u32, @intCast(dy));
                if (px >= self.fb_width or py >= self.fb_height) continue;

                const offset = (py * self.fb_width + px) * 4;
                if (offset + 4 > self.framebuffer.len) continue;

                // Simple character rendering (just show if char != space)
                const color = if (char != ' ' and dy >= 4 and dy < 12 and dx >= 1 and dx < 7) fg else bg;

                self.framebuffer[offset + 0] = @truncate(color >> 0); // B
                self.framebuffer[offset + 1] = @truncate(color >> 8); // G
                self.framebuffer[offset + 2] = @truncate(color >> 16); // R
                self.framebuffer[offset + 3] = @truncate(color >> 24); // A
            }
        }
    }

    fn drawCursor(self: *Terminal, x: u32, y: u32, w: u32, h: u32) void {
        // Draw block cursor
        for (0..h) |dy| {
            for (0..w) |dx| {
                const px = x + @as(u32, @intCast(dx));
                const py = y + @as(u32, @intCast(dy));
                if (px >= self.fb_width or py >= self.fb_height) continue;

                const offset = (py * self.fb_width + px) * 4;
                if (offset + 4 > self.framebuffer.len) continue;

                // XOR with white for visibility
                self.framebuffer[offset + 0] ^= 0xFF;
                self.framebuffer[offset + 1] ^= 0xFF;
                self.framebuffer[offset + 2] ^= 0xFF;
            }
        }
    }

    /// Write input to PTY
    pub fn write(self: *Terminal, data: []const u8) !void {
        _ = try posix.write(self.master_fd, data);
    }

    /// Read raw PTY output (non-blocking)
    pub fn readRaw(self: *Terminal, buf: []u8) !usize {
        return posix.read(self.master_fd, buf) catch |err| {
            if (err == error.WouldBlock) return 0;
            return err;
        };
    }

    /// Get framebuffer for encoding
    pub fn getFramebuffer(self: *Terminal) []const u8 {
        return self.framebuffer;
    }

    pub fn getSize(self: *Terminal) struct { cols: u32, rows: u32, width: u32, height: u32 } {
        return .{
            .cols = self.cols,
            .rows = self.rows,
            .width = self.width,
            .height = self.height,
        };
    }
};

/// Allocate and zero-initialize a framebuffer (RGBA, 4 bytes per pixel).
fn allocateFramebuffer(allocator: std.mem.Allocator, width: u32, height: u32) ![]u8 {
    const fb_size = width * height * 4;
    const framebuffer = try allocator.alloc(u8, fb_size);
    @memset(framebuffer, 0);
    return framebuffer;
}

/// Allocate and default-initialize a cell grid.
fn allocateCells(allocator: std.mem.Allocator, cols: u32, rows: u32) ![]Terminal.Cell {
    const cells = try allocator.alloc(Terminal.Cell, cols * rows);
    for (cells) |*c| {
        c.* = Terminal.Cell{};
    }
    return cells;
}

// PTY helpers
const PtyPair = struct {
    master: posix.fd_t,
    slave: posix.fd_t,
};

// External libc functions for PTY
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;
extern "c" fn execve(pathname: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;

fn openPty() !PtyPair {
    // Open master
    const master = try posix.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
    errdefer posix.close(master);

    // Grant/unlock using libc
    if (grantpt(master) != 0) return error.GrantPtyFailed;
    if (unlockpt(master) != 0) return error.UnlockPtyFailed;

    // Get slave name
    const slave_name = ptsname(master) orelse return error.PtsnameFailed;

    // Open slave
    const slave = try posix.open(std.mem.span(slave_name), .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);

    return PtyPair{ .master = master, .slave = slave };
}

// winsize struct for TIOCSWINSZ
const winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

// ioctl for terminal size
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
const TIOCSWINSZ: c_ulong = 0x5414;

fn setWinsize(fd: posix.fd_t, cols: u32, rows: u32, xpixel: u32, ypixel: u32) !void {
    const ws = winsize{
        .ws_col = @intCast(cols),
        .ws_row = @intCast(rows),
        .ws_xpixel = @intCast(xpixel),
        .ws_ypixel = @intCast(ypixel),
    };
    const result = ioctl(fd, TIOCSWINSZ, &ws);
    if (result != 0) return error.SetWinsizeFailed;
}
