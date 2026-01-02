const std = @import("std");
const terminal_mod = @import("terminal/terminal.zig");
const kitty_mod = @import("terminal/kitty_graphics.zig");
const input_mod = @import("terminal/input.zig");
const screen_mod = @import("terminal/screen.zig");
const prompt_mod = @import("terminal/prompt.zig");
const cdp = @import("chrome/cdp_client.zig");
const screenshot_api = @import("chrome/screenshot.zig");
const scroll_api = @import("chrome/scroll.zig");
const dom_mod = @import("chrome/dom.zig");
const interact_mod = @import("chrome/interact.zig");

const Terminal = terminal_mod.Terminal;
const KittyGraphics = kitty_mod.KittyGraphics;
const InputReader = input_mod.InputReader;
const Screen = screen_mod.Screen;
const Key = input_mod.Key;
const PromptBuffer = prompt_mod.PromptBuffer;
const FormContext = dom_mod.FormContext;

pub const ViewerMode = enum {
    normal,       // Scroll, navigate, refresh
    url_prompt,   // Entering URL (g key)
    form_mode,    // Selecting form elements (f key, Tab navigation)
    text_input,   // Typing into form field
};

pub const Viewer = struct {
    allocator: std.mem.Allocator,
    terminal: Terminal,
    kitty: KittyGraphics,
    cdp_client: *cdp.CdpClient,
    input: InputReader,
    current_url: []const u8,
    running: bool,
    mode: ViewerMode,
    prompt_buffer: ?PromptBuffer,
    form_context: ?*FormContext,

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
            .mode = .normal,
            .prompt_buffer = null,
            .form_context = null,
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

    /// Handle key press - dispatches to mode-specific handlers
    fn handleKey(self: *Viewer, key: Key) !void {
        switch (self.mode) {
            .normal => try self.handleNormalMode(key),
            .url_prompt => try self.handleUrlPromptMode(key),
            .form_mode => try self.handleFormMode(key),
            .text_input => try self.handleTextInputMode(key),
        }
    }

    /// Handle key press in normal mode
    fn handleNormalMode(self: *Viewer, key: Key) !void {
        // Get viewport size for scroll calculations
        const size = try self.terminal.getSize();
        const vw = size.width_px;
        const vh = size.height_px;

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
                    // Vim-style scrolling
                    'j' => {
                        try scroll_api.scrollLineDown(self.cdp_client, self.allocator, vw, vh);
                        try self.refresh();
                    },
                    'k' => {
                        try scroll_api.scrollLineUp(self.cdp_client, self.allocator, vw, vh);
                        try self.refresh();
                    },
                    'd' => {
                        try scroll_api.scrollHalfPageDown(self.cdp_client, self.allocator, vw, vh);
                        try self.refresh();
                    },
                    'u' => {
                        try scroll_api.scrollHalfPageUp(self.cdp_client, self.allocator, vw, vh);
                        try self.refresh();
                    },
                    'g', 'G' => {
                        // Enter URL prompt mode
                        self.mode = .url_prompt;
                        self.prompt_buffer = try PromptBuffer.init(self.allocator);
                        try self.drawStatus();
                    },
                    'f' => {
                        // Enter form mode
                        self.mode = .form_mode;

                        // Query elements
                        const ctx = try self.allocator.create(FormContext);
                        ctx.* = FormContext.init(self.allocator);
                        ctx.elements = try dom_mod.queryElements(self.cdp_client, self.allocator);
                        self.form_context = ctx;

                        try self.drawStatus();
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
            // Arrow key scrolling
            .up => {
                try scroll_api.scrollLineUp(self.cdp_client, self.allocator, vw, vh);
                try self.refresh();
            },
            .down => {
                try scroll_api.scrollLineDown(self.cdp_client, self.allocator, vw, vh);
                try self.refresh();
            },
            // Page key scrolling
            .page_up => {
                try scroll_api.scrollPageUp(self.cdp_client, self.allocator, vw, vh);
                try self.refresh();
            },
            .page_down => {
                try scroll_api.scrollPageDown(self.cdp_client, self.allocator, vw, vh);
                try self.refresh();
            },
            else => {},
        }
    }

    /// Handle key press in URL prompt mode
    fn handleUrlPromptMode(self: *Viewer, key: Key) !void {
        var prompt = &self.prompt_buffer.?;

        switch (key) {
            .char => |c| {
                if (c == 8 or c == 127) { // Backspace (ASCII 8 or 127)
                    prompt.backspace();
                } else if (c >= 32 and c <= 126) { // Printable characters
                    try prompt.insertChar(c);
                }
                try self.drawStatus();
            },
            .enter => {
                const url = prompt.getString();
                if (url.len > 0) {
                    // Navigate to the entered URL
                    try screenshot_api.navigateToUrl(self.cdp_client, self.allocator, url);
                    try self.refresh();
                }

                // Exit URL prompt mode
                prompt.deinit();
                self.prompt_buffer = null;
                self.mode = .normal;
                try self.drawStatus();
            },
            .escape => {
                // Cancel URL prompt
                prompt.deinit();
                self.prompt_buffer = null;
                self.mode = .normal;
                try self.drawStatus();
            },
            else => {},
        }
    }

    /// Handle key press in form mode
    fn handleFormMode(self: *Viewer, key: Key) !void {
        var ctx = self.form_context orelse return;

        switch (key) {
            .char => |c| {
                if (c == '\t' or c == 9) { // Tab
                    ctx.next();
                    try self.drawStatus();
                }
            },
            .enter => {
                if (ctx.current()) |elem| {
                    if (std.mem.eql(u8, elem.tag, "a")) {
                        // Click link
                        try interact_mod.clickElement(self.cdp_client, self.allocator, elem);
                        try self.refresh();
                    } else if (std.mem.eql(u8, elem.tag, "input")) {
                        if (elem.type) |t| {
                            if (std.mem.eql(u8, t, "text") or std.mem.eql(u8, t, "password")) {
                                // Enter text input mode
                                try interact_mod.focusElement(self.cdp_client, self.allocator, elem.selector);
                                self.mode = .text_input;
                                self.prompt_buffer = try PromptBuffer.init(self.allocator);
                                try self.drawStatus();
                            } else if (std.mem.eql(u8, t, "checkbox") or std.mem.eql(u8, t, "radio")) {
                                // Toggle checkbox or select radio button
                                try interact_mod.toggleCheckbox(self.cdp_client, self.allocator, elem.selector);
                                try self.refresh();
                            } else if (std.mem.eql(u8, t, "submit")) {
                                // Submit button - click it
                                try interact_mod.clickElement(self.cdp_client, self.allocator, elem);
                                try self.refresh();
                            }
                        }
                    } else if (std.mem.eql(u8, elem.tag, "textarea")) {
                        // Treat textarea like text input
                        try interact_mod.focusElement(self.cdp_client, self.allocator, elem.selector);
                        self.mode = .text_input;
                        self.prompt_buffer = try PromptBuffer.init(self.allocator);
                        try self.drawStatus();
                    } else if (std.mem.eql(u8, elem.tag, "select")) {
                        // Click select to activate dropdown
                        try interact_mod.clickElement(self.cdp_client, self.allocator, elem);
                        try self.refresh();
                    } else if (std.mem.eql(u8, elem.tag, "button")) {
                        // Click button
                        try interact_mod.clickElement(self.cdp_client, self.allocator, elem);
                        try self.refresh();
                    }
                }
            },
            .escape => {
                // Exit form mode
                ctx.deinit();
                self.allocator.destroy(ctx);
                self.form_context = null;
                self.mode = .normal;
                try self.drawStatus();
            },
            else => {},
        }
    }

    /// Handle key press in text input mode
    fn handleTextInputMode(self: *Viewer, key: Key) !void {
        var prompt = &self.prompt_buffer.?;

        switch (key) {
            .char => |c| {
                if (c == 8 or c == 127) { // Backspace
                    prompt.backspace();
                } else if (c >= 32 and c <= 126) { // Printable characters
                    try prompt.insertChar(c);
                }
                try self.drawStatus();
            },
            .enter => {
                const text = prompt.getString();
                if (text.len > 0) {
                    // Type the text into the focused element
                    try interact_mod.typeText(self.cdp_client, self.allocator, text);
                }
                // Press Enter to submit
                try interact_mod.pressEnter(self.cdp_client, self.allocator);

                // Cleanup prompt
                prompt.deinit();
                self.prompt_buffer = null;

                // Return to form mode (not normal mode)
                self.mode = .form_mode;
                try self.refresh();
                try self.drawStatus();
            },
            .escape => {
                // Cancel text input
                prompt.deinit();
                self.prompt_buffer = null;
                self.mode = .form_mode;
                try self.drawStatus();
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

        // Status text based on mode
        switch (self.mode) {
            .normal => {
                try writer.print("URL: {s} | [q]uit [f]orm [g]oto [↑↓jk]scroll [r]efresh [R]eload [b]ack [←→]nav", .{self.current_url});
            },
            .url_prompt => {
                try writer.print("Go to URL: ", .{});
                if (self.prompt_buffer) |*p| {
                    try p.render(writer, "");
                }
                try writer.print(" | [Enter] navigate [Esc] cancel", .{});
            },
            .form_mode => {
                if (self.form_context) |ctx| {
                    if (ctx.current()) |elem| {
                        var desc_buf: [200]u8 = undefined;
                        const desc = try elem.describe(&desc_buf);
                        try writer.print("FORM [{d}/{d}]: {s} | [Tab] next [Enter] activate [Esc] exit", .{ ctx.current_index + 1, ctx.elements.len, desc });
                    } else {
                        try writer.print("FORM: No elements | [Esc] exit", .{});
                    }
                }
            },
            .text_input => {
                try writer.print("Type text: ", .{});
                if (self.prompt_buffer) |*p| {
                    try p.render(writer, "");
                }
                try writer.print(" | [Enter] submit [Esc] cancel", .{});
            },
        }
    }

    pub fn deinit(self: *Viewer) void {
        if (self.prompt_buffer) |*p| p.deinit();
        if (self.form_context) |ctx| {
            ctx.deinit();
            self.allocator.destroy(ctx);
        }
        self.terminal.deinit();
    }
};
