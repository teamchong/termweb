const std = @import("std");
const terminal_mod = @import("terminal/terminal.zig");
const kitty_mod = @import("terminal/kitty_graphics.zig");
const input_mod = @import("terminal/input.zig");
const screen_mod = @import("terminal/screen.zig");
const cdp = @import("chrome/cdp_client.zig");
const screenshot_api = @import("chrome/screenshot.zig");

const Terminal = terminal_mod.Terminal;
const KittyGraphics = kitty_mod.KittyGraphics;
const InputReader = input_mod.InputReader;
const Screen = screen_mod.Screen;
const Key = input_mod.Key;

pub const Viewer = struct {
    allocator: std.mem.Allocator,
    terminal: Terminal,
    kitty: KittyGraphics,
    cdp_client: *cdp.CdpClient,
    input: InputReader,
    current_url: []const u8,
    running: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        cdp_client: *cdp.CdpClient,
        url: []const u8,
    ) !Viewer {
        return Viewer{
            .allocator = allocator,
            .terminal = Terminal.init(),
            .kitty = KittyGraphics.init(allocator),
            .cdp_client = cdp_client,
            .input = InputReader.init(std.posix.STDIN_FILENO),
            .current_url = url,
            .running = true,
        };
    }

    /// Main event loop
    pub fn run(self: *Viewer) !void {
        var stdout_buf: [4096]u8 = undefined;
        const stdout_file = std.fs.File.stdout();
        var stdout_writer = stdout_file.writer(&stdout_buf);
        const writer = &stdout_writer.interface;

        // Setup terminal
        try self.terminal.enterRawMode();
        defer self.terminal.restore() catch {};

        try Screen.hideCursor(writer);
        defer Screen.showCursor(writer) catch {};

        // Initial render
        try self.refresh();

        // Main loop
        while (self.running) {
            // Check for input (non-blocking)
            const key = try self.input.readKey();
            if (key != .none) {
                try self.handleKey(key);
            }

            // Small sleep to avoid busy-waiting
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }

        // Cleanup
        try self.kitty.clearAll(writer);
        try Screen.clear(writer);
    }

    /// Refresh display (re-capture and draw)
    fn refresh(self: *Viewer) !void {
        var stdout_buf: [4096]u8 = undefined;
        const stdout_file = std.fs.File.stdout();
        var stdout_writer = stdout_file.writer(&stdout_buf);
        const writer = &stdout_writer.interface;

        // Clear screen
        try Screen.clear(writer);
        try self.kitty.clearAll(writer);

        // Get terminal size
        const size = try self.terminal.getSize();

        // Capture screenshot
        const base64_png = try screenshot_api.captureScreenshot(
            self.cdp_client,
            self.allocator,
            .{ .format = .png },
        );
        defer self.allocator.free(base64_png);

        // Decode base64
        const decoder = std.base64.standard.Decoder;
        const png_size = try decoder.calcSizeForSlice(base64_png);
        const png_data = try self.allocator.alloc(u8, png_size);
        defer self.allocator.free(png_data);
        try decoder.decode(png_data, base64_png);

        // Display image (leave room for status line)
        try self.kitty.displayPNG(writer, png_data, .{
            .rows = if (size.rows > 1) size.rows - 1 else size.rows,
        });

        // Draw status line
        try self.drawStatus();
    }

    /// Handle key press
    fn handleKey(self: *Viewer, key: Key) !void {
        switch (key) {
            .char => |c| {
                switch (c) {
                    'q', 'Q' => self.running = false,
                    'r' => try self.refresh(), // lowercase = refresh screenshot only
                    'R' => { // uppercase = reload page from server
                        try screenshot_api.reload(self.cdp_client, self.allocator, false);
                        try self.refresh();
                    },
                    'b' => { // back
                        try screenshot_api.goBack(self.cdp_client, self.allocator);
                        try self.refresh();
                    },
                    'f' => { // forward
                        try screenshot_api.goForward(self.cdp_client, self.allocator);
                        try self.refresh();
                    },
                    'g', 'G' => {
                        // TODO M3: Prompt for new URL
                        std.debug.print("Navigate to new URL (not implemented yet)\n", .{});
                    },
                    else => {},
                }
            },
            .ctrl_c, .escape => self.running = false,
            .left => { // Arrow key navigation
                try screenshot_api.goBack(self.cdp_client, self.allocator);
                try self.refresh();
            },
            .right => {
                try screenshot_api.goForward(self.cdp_client, self.allocator);
                try self.refresh();
            },
            else => {},
        }
    }

    /// Draw status line
    fn drawStatus(self: *Viewer) !void {
        var stdout_buf: [4096]u8 = undefined;
        const stdout_file = std.fs.File.stdout();
        var stdout_writer = stdout_file.writer(&stdout_buf);
        const writer = &stdout_writer.interface;

        const size = try self.terminal.getSize();

        // Move to last row
        try Screen.moveCursor(writer, size.rows, 1);
        try Screen.clearLine(writer);

        // Status text
        try writer.print("URL: {s} | [q]uit [r]efresh [R]eload [b]ack [f]wd [←→] [g]oto", .{self.current_url});
    }

    pub fn deinit(self: *Viewer) void {
        self.terminal.deinit();
    }
};
