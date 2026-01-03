/// Main viewer module for termweb.
///
/// Implements the interactive browser session with a mode-based state machine.
/// Handles keyboard input, screenshot rendering, and user interaction modes.
const std = @import("std");
const terminal_mod = @import("terminal/terminal.zig");
const kitty_mod = @import("terminal/kitty_graphics.zig");
const input_mod = @import("terminal/input.zig");
const screen_mod = @import("terminal/screen.zig");
const prompt_mod = @import("terminal/prompt.zig");
const coordinates_mod = @import("terminal/coordinates.zig");
const cdp = @import("chrome/cdp_client.zig");
const screenshot_api = @import("chrome/screenshot.zig");
const scroll_api = @import("chrome/scroll.zig");
const dom_mod = @import("chrome/dom.zig");
const interact_mod = @import("chrome/interact.zig");
const ui_mod = @import("ui/mod.zig");

const Terminal = terminal_mod.Terminal;
const KittyGraphics = kitty_mod.KittyGraphics;
const InputReader = input_mod.InputReader;
const Screen = screen_mod.Screen;
const Key = input_mod.Key;
const Input = input_mod.Input;
const MouseEvent = input_mod.MouseEvent;
const CoordinateMapper = coordinates_mod.CoordinateMapper;
const PromptBuffer = prompt_mod.PromptBuffer;
const FormContext = dom_mod.FormContext;
const UIState = ui_mod.UIState;
const Placement = ui_mod.Placement;
const ZIndex = ui_mod.ZIndex;
const cursor_asset = ui_mod.assets.cursor;

/// Line ending for raw terminal mode (carriage return + line feed)
const CRLF = "\r\n";

/// ViewerMode represents the current interaction mode of the viewer.
///
/// The viewer operates as a state machine with five distinct modes:
/// - normal: Default browsing mode (scroll, navigate, refresh)
/// - url_prompt: URL entry mode activated by 'g' key
/// - form_mode: Form element selection mode activated by 'f' key
/// - text_input: Text entry mode for filling form fields
/// - help: Help overlay showing key bindings
///
/// Mode transitions:
///   Normal → URL Prompt (press 'g')
///   Normal → Form Mode (press 'f')
///   Normal → Help (press '?')
///   Form Mode → Text Input (press Enter on text field)
///   Any mode → Normal (press Esc or complete action)
pub const ViewerMode = enum {
    normal,       // Scroll, navigate, refresh
    url_prompt,   // Entering URL (g key)
    form_mode,    // Selecting form elements (f key, Tab navigation)
    text_input,   // Typing into form field
    help,         // Help overlay (? key)
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
    debug_log: ?std.fs.File,
    viewport_width: u32,
    viewport_height: u32,
    coord_mapper: ?CoordinateMapper,
    last_click: ?struct { term_x: u16, term_y: u16, browser_x: u32, browser_y: u32 },

    // Screencast streaming
    screencast_mode: bool,
    last_frame_time: i128,

    // UI state for layered rendering
    ui_state: UIState,

    // Mouse cursor tracking (pixel coordinates)
    mouse_x: u16,
    mouse_y: u16,
    mouse_visible: bool,
    cursor_image_id: ?u32,  // Track cursor image ID for cleanup

    // Debug flags
    debug_input: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        cdp_client: *cdp.CdpClient,
        url: []const u8,
        viewport_width: u32,
        viewport_height: u32,
    ) !Viewer {
        // Create debug log file
        const debug_log = std.fs.cwd().createFile("termweb_debug.log", .{}) catch null;
        if (debug_log) |file| {
            file.writeAll("=== termweb debug log ===\n") catch {};
        }

        // Check environment variable for input debug logging
        const enable_input_debug = blk: {
            const debug_input = std.process.getEnvVarOwned(allocator, "TERMWEB_DEBUG_INPUT") catch {
                break :blk false;
            };
            defer allocator.free(debug_input);
            break :blk std.mem.eql(u8, debug_input, "1");
        };

        return Viewer{
            .allocator = allocator,
            .terminal = Terminal.init(),
            .kitty = KittyGraphics.init(allocator),
            .cdp_client = cdp_client,
            .input = InputReader.init(std.posix.STDIN_FILENO, enable_input_debug),
            .current_url = url,
            .running = true,
            .mode = .normal,
            .prompt_buffer = null,
            .form_context = null,
            .debug_log = debug_log,
            .viewport_width = viewport_width,
            .viewport_height = viewport_height,
            .coord_mapper = null,
            .last_click = null,
            .screencast_mode = false,
            .last_frame_time = 0,
            .ui_state = UIState{},
            .mouse_x = 0,
            .mouse_y = 0,
            .mouse_visible = false,
            .cursor_image_id = null,
            .debug_input = enable_input_debug,
        };
    }

    fn log(self: *Viewer, comptime fmt: []const u8, args: anytype) void {
        if (self.debug_log) |file| {
            var buf: [1024]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
            file.writeAll(msg) catch {};
            file.sync() catch {}; // Flush to disk immediately
        }
    }

    /// Main event loop
    pub fn run(self: *Viewer) !void {
        self.log("[DEBUG] Viewer.run() starting\n", .{});

        var stdout_buf: [8192]u8 = undefined;
        const stdout_file = std.fs.File.stdout();
        var stdout_writer = stdout_file.writer(&stdout_buf);
        const writer = &stdout_writer.interface;

        // Setup terminal
        self.log("[DEBUG] Entering raw mode...\n", .{});
        try self.terminal.enterRawMode();
        self.log("[DEBUG] Raw mode enabled successfully\n", .{});
        defer self.terminal.restore() catch {};

        self.log("[DEBUG] Enabling mouse...\n", .{});
        try self.terminal.enableMouse();
        self.input.mouse_enabled = true;
        self.log("[DEBUG] Mouse enabled, input.mouse_enabled={}\n", .{self.input.mouse_enabled});

        self.log("[DEBUG] Hiding cursor...\n", .{});
        try Screen.hideCursor(writer);
        try writer.flush();  // Force flush after hiding cursor
        defer Screen.showCursor(writer) catch {};

        // Clear screen once at startup
        self.log("[DEBUG] Initial screen clear...\n", .{});
        try Screen.clear(writer);
        try self.kitty.clearAll(writer);
        try writer.flush();

        // Start screencast streaming with exact viewport dimensions for 1:1 coordinate mapping
        self.log("[DEBUG] Starting screencast {}x{}...\n", .{ self.viewport_width, self.viewport_height });
        try screenshot_api.startScreencast(self.cdp_client, self.allocator, .{
            .format = .png,
            .width = self.viewport_width,
            .height = self.viewport_height,
        });
        self.screencast_mode = true;
        self.log("[DEBUG] Screencast started\n", .{});

        // Wait for first frame
        self.log("[DEBUG] Waiting for first screencast frame...\n", .{});
        var retries: u32 = 0;
        while (retries < 100) : (retries += 1) {
            if (try self.tryRenderScreencast()) {
                self.log("[DEBUG] First frame received\n", .{});
                break;
            }
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        if (retries >= 100) {
            return error.ScreencastTimeout;
        }

        self.log("[DEBUG] About to enter event loop\n", .{});
        self.log("[DEBUG] self.running = {}\n", .{self.running});

        // Main loop
        var loop_count: u32 = 0;
        self.log("[DEBUG] Starting while loop\n", .{});
        while (self.running) {
            loop_count += 1;
            if (loop_count == 1) {
                self.log("[DEBUG] First iteration of event loop\n", .{});
            }
            if (loop_count % 500 == 0) {
                self.log("[DEBUG] Loop iteration {d}, mode={s}, frames_received={d}\n", .{
                    loop_count,
                    @tagName(self.mode),
                    self.cdp_client.getFrameCount(),
                });
            }

            // Check for input (non-blocking)
            const input = self.input.readInput() catch |err| {
                self.log("[ERROR] readInput() failed: {}\n", .{err});
                return err;
            };

            if (input != .none) {
                // Always log input events for debugging
                switch (input) {
                    .key => |key| self.log("[INPUT] Key: {any}\n", .{key}),
                    .mouse => |m| self.log("[INPUT] Mouse: type={s} x={d} y={d}\n", .{ @tagName(m.type), m.x, m.y }),
                    .none => {},
                }
                try self.handleInput(input);
            }

            // Render new screencast frames (non-blocking) - only in normal mode
            if (self.screencast_mode and self.mode == .normal) {
                _ = self.tryRenderScreencast() catch {};

                // Always render UI chrome on top
                var stdout_buf2: [8192]u8 = undefined;
                const stdout_file2 = std.fs.File.stdout();
                var stdout_writer2 = stdout_file2.writer(&stdout_buf2);
                const writer2 = &stdout_writer2.interface;
                self.renderCursor(writer2) catch {};
                self.renderUIChrome(writer2) catch {};
                self.drawStatus() catch {};
            }

            // Small sleep to avoid busy-waiting
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }

        self.log("[DEBUG] Exited main loop (running={}), loop_count={}\n", .{self.running, loop_count});

        // Stop screencast
        if (self.screencast_mode) {
            screenshot_api.stopScreencast(self.cdp_client, self.allocator) catch {};
        }

        // Cleanup
        try self.kitty.clearAll(writer);
        try Screen.clear(writer);
        try writer.flush();
    }

    /// Refresh display - no-op in screencast mode (frames arrive automatically)
    fn refresh(self: *Viewer) !void {
        // Screencast mode: frames arrive automatically, nothing to do
        self.log("[DEBUG] refresh() - screencast handles updates\n", .{});
    }

    /// Legacy refresh for non-screencast mode (kept for reference)
    fn refreshLegacy(self: *Viewer) !void {
        self.log("[DEBUG] refreshLegacy() starting\n", .{});

        var stdout_buf: [8192]u8 = undefined;
        const stdout_file = std.fs.File.stdout();
        var stdout_writer = stdout_file.writer(&stdout_buf);
        const writer = &stdout_writer.interface;

        // Get terminal size
        self.log("[DEBUG] Getting terminal size...\n", .{});
        const size = try self.terminal.getSize();
        self.log("[DEBUG] Terminal size: {}x{} ({}x{} px)\n", .{
            size.cols,
            size.rows,
            size.width_px,
            size.height_px,
        });

        // Update coordinate mapper (for handling terminal resize)
        self.coord_mapper = CoordinateMapper.init(
            size.width_px,
            size.height_px,
            size.cols,
            size.rows,
            self.viewport_width,
            self.viewport_height,
        );
        self.log("[DEBUG] Coordinate mapper initialized\n", .{});

        // Capture screenshot
        self.log("[DEBUG] Capturing screenshot...\n", .{});
        const base64_png = try screenshot_api.captureScreenshot(
            self.cdp_client,
            self.allocator,
            .{ .format = .png },
        );
        defer self.allocator.free(base64_png);
        self.log("[DEBUG] Screenshot captured ({} bytes base64)\n", .{base64_png.len});

        // Decode base64
        self.log("[DEBUG] Decoding base64...\n", .{});
        const decoder = std.base64.standard.Decoder;
        const png_size = try decoder.calcSizeForSlice(base64_png);
        const png_data = try self.allocator.alloc(u8, png_size);
        defer self.allocator.free(png_data);
        try decoder.decode(png_data, base64_png);
        self.log("[DEBUG] Decoded to {} bytes PNG\n", .{png_data.len});

        // Display image (leave room for status line)
        self.log("[DEBUG] Displaying PNG via Kitty graphics...\n", .{});

        // Ensure we have valid dimensions - if terminal size is 0, use reasonable defaults
        const display_rows = if (size.rows > 1) size.rows - 1 else if (size.rows > 0) size.rows else 24;
        const display_cols = if (size.cols > 0) size.cols else 80;

        self.log("[DEBUG] Display dimensions: rows={}, cols={}\n", .{display_rows, display_cols});

        _ = try self.kitty.displayPNG(writer, png_data, .{
            .rows = display_rows,
            .columns = display_cols,
            .placement_id = 1,
        });
        try writer.flush();  // CRITICAL: Flush after Kitty graphics
        self.log("[DEBUG] PNG displayed and flushed\n", .{});

        // Draw status line
        self.log("[DEBUG] Drawing status line...\n", .{});
        try self.drawStatus();
        self.log("[DEBUG] drawStatus() returned\n", .{});
        self.log("[DEBUG] refresh() about to return\n", .{});
    }

    /// Try to render latest screencast frame (non-blocking)
    /// Returns true if frame was rendered, false if no new frame
    fn tryRenderScreencast(self: *Viewer) !bool {
        // Frame rate limiting: Don't render faster than 30fps (~33ms per frame)
        const now = std.time.nanoTimestamp();
        const min_frame_interval = 33 * std.time.ns_per_ms;
        if (self.last_frame_time > 0 and (now - self.last_frame_time) < min_frame_interval) {
            return false; // Too soon since last frame
        }

        // Get frame with proper ownership - MUST call deinit when done
        var frame = screenshot_api.getLatestScreencastFrame(self.cdp_client) orelse return false;
        defer frame.deinit(); // Proper cleanup!

        // Use ACTUAL frame dimensions from CDP metadata for coordinate mapping
        // Chrome may send different size than requested viewport
        const frame_width = if (frame.device_width > 0) frame.device_width else self.viewport_width;
        const frame_height = if (frame.device_height > 0) frame.device_height else self.viewport_height;

        self.log("[RENDER] Frame {}x{} (viewport {}x{}), {} bytes\n", .{
            frame_width, frame_height,
            self.viewport_width, self.viewport_height,
            frame.data.len,
        });
        try self.displayFrameWithDimensions(frame.data, frame_width, frame_height);
        self.last_frame_time = now;
        return true;
    }

    /// Display a base64 PNG frame with specific dimensions for coordinate mapping
    fn displayFrameWithDimensions(self: *Viewer, base64_png: []const u8, frame_width: u32, frame_height: u32) !void {
        var stdout_buf: [8192]u8 = undefined;
        const stdout_file = std.fs.File.stdout();
        var stdout_writer = stdout_file.writer(&stdout_buf);
        const writer = &stdout_writer.interface;

        // Decode base64
        const decoder = std.base64.standard.Decoder;
        const png_size = try decoder.calcSizeForSlice(base64_png);
        const png_data = try self.allocator.alloc(u8, png_size);
        defer self.allocator.free(png_data);
        try decoder.decode(png_data, base64_png);

        // Get terminal size
        const size = try self.terminal.getSize();
        // Reserve 1 row for tab bar at top, 1 row for status bar at bottom
        const tabbar_rows: u32 = 1;
        const statusbar_rows: u32 = 1;
        const content_rows = if (size.rows > tabbar_rows + statusbar_rows)
            size.rows - tabbar_rows - statusbar_rows
        else
            1;
        const display_cols = if (size.cols > 0) size.cols else 80;

        // Update coordinate mapper with ACTUAL frame dimensions from CDP
        // This ensures click coordinates match what Chrome is rendering
        self.coord_mapper = CoordinateMapper.init(
            size.width_px,
            size.height_px,
            size.cols,
            size.rows,
            frame_width,   // Use actual frame width, not viewport
            frame_height,  // Use actual frame height, not viewport
        );

        self.log("[RENDER] displayFrame: png={} bytes, term={}x{}, display={}x{}, frame={}x{}\n", .{
            png_data.len, size.cols, size.rows, display_cols, content_rows, frame_width, frame_height,
        });

        // Move cursor to row 2 (after tab bar) before displaying content
        try writer.print("\x1b[{d};1H", .{tabbar_rows + 1});

        // Display via Kitty graphics protocol with z-index layering
        // Web content is at z=0, UI chrome will be at z=5-10
        _ = try self.kitty.displayPNG(writer, png_data, .{
            .rows = content_rows,
            .columns = display_cols,
            .placement_id = Placement.CONTENT,
            .z = ZIndex.CONTENT,
        });
        try writer.flush();
        self.log("[RENDER] displayFrame complete\n", .{});
    }

    /// Display a base64 PNG frame (legacy, uses viewport dimensions)
    fn displayFrame(self: *Viewer, base64_png: []const u8) !void {
        try self.displayFrameWithDimensions(base64_png, self.viewport_width, self.viewport_height);
    }

    /// Render mouse cursor at current mouse position
    fn renderCursor(self: *Viewer, writer: anytype) !void {
        if (!self.mouse_visible) return;

        // Delete old cursor image to prevent trailing
        if (self.cursor_image_id) |old_id| {
            try self.kitty.deleteImage(writer, old_id);
        }

        // With SGR pixel mode (1016h), mouse_x/y are pixel coordinates
        // Convert to cell coordinates for ANSI cursor positioning
        const mapper = self.coord_mapper orelse return;
        const cell_width = if (mapper.terminal_cols > 0)
            mapper.terminal_width_px / mapper.terminal_cols
        else
            14;
        const cell_height = mapper.cell_height;

        // Calculate cell position (1-indexed for ANSI)
        const cell_col = if (cell_width > 0) (self.mouse_x / cell_width) + 1 else 1;
        const cell_row = if (cell_height > 0) (self.mouse_y / cell_height) + 1 else 1;

        // Calculate pixel offset within cell for precise positioning
        const x_offset = if (cell_width > 0) self.mouse_x % cell_width else 0;
        const raw_y_offset = if (cell_height > 0) self.mouse_y % cell_height else 0;
        const y_offset = if (raw_y_offset > 0) raw_y_offset - 1 else 0; // Adjust for cursor tip alignment

        // Move cursor to cell position
        try writer.print("\x1b[{d};{d}H", .{ cell_row, cell_col });

        // Display cursor PNG with pixel offset for precision
        self.cursor_image_id = try self.kitty.displayPNG(writer, cursor_asset, .{
            .placement_id = Placement.CURSOR,
            .z = ZIndex.CURSOR,
            .x_offset = x_offset,
            .y_offset = y_offset,
        });
    }

    /// Render UI chrome layers (tab bar with text-based buttons)
    fn renderUIChrome(self: *Viewer, writer: anytype) !void {
        // Move cursor to row 1, column 1
        try writer.writeAll("\x1b[1;1H");

        // Clear the tab bar row
        try writer.writeAll("\x1b[2K");

        // Dark background for tab bar
        try writer.writeAll("\x1b[48;2;30;30;30m"); // Dark grey background

        // Back button
        if (self.ui_state.can_go_back) {
            try writer.writeAll("\x1b[38;2;200;200;200m"); // Light text
        } else {
            try writer.writeAll("\x1b[38;2;80;80;80m"); // Dim text
        }
        try writer.writeAll(" \xe2\x97\x80 "); // ◀

        // Forward button
        if (self.ui_state.can_go_forward) {
            try writer.writeAll("\x1b[38;2;200;200;200m");
        } else {
            try writer.writeAll("\x1b[38;2;80;80;80m");
        }
        try writer.writeAll(" \xe2\x96\xb6 "); // ▶

        // Refresh button
        if (self.ui_state.is_loading) {
            try writer.writeAll("\x1b[38;2;74;158;255m"); // Blue when loading
        } else {
            try writer.writeAll("\x1b[38;2;200;200;200m");
        }
        try writer.writeAll(" \xe2\x86\xbb "); // ↻

        // Separator
        try writer.writeAll("\x1b[38;2;60;60;60m\xe2\x94\x82"); // │

        // URL display
        try writer.writeAll("\x1b[38;2;150;150;150m ");
        const max_url = 50;
        if (self.current_url.len > max_url) {
            try writer.writeAll(self.current_url[0..max_url]);
            try writer.writeAll("...");
        } else {
            try writer.writeAll(self.current_url);
        }

        // Fill rest of line with background
        try writer.writeAll("\x1b[0K");

        // Reset colors
        try writer.writeAll("\x1b[0m");

        try writer.flush();
    }

    /// Handle input event - dispatches to key or mouse handlers
    fn handleInput(self: *Viewer, input: Input) !void {
        switch (input) {
            .key => |key| {
                // Debug log all key presses (if enabled)
                if (self.debug_input) {
                    switch (key) {
                        .char => |c| self.log("[KEY] char: {d} ('{c}')\n", .{ c, if (c >= 32 and c <= 126) c else '.' }),
                        .escape => self.log("[KEY] escape\n", .{}),
                        .tab => self.log("[KEY] tab\n", .{}),
                        .backspace => self.log("[KEY] backspace\n", .{}),
                        .enter => self.log("[KEY] enter\n", .{}),
                        .ctrl_a => self.log("[KEY] ctrl_a\n", .{}),
                        .ctrl_b => self.log("[KEY] ctrl_b\n", .{}),
                        .ctrl_c => self.log("[KEY] ctrl_c\n", .{}),
                        .ctrl_d => self.log("[KEY] ctrl_d\n", .{}),
                        .ctrl_e => self.log("[KEY] ctrl_e\n", .{}),
                        .ctrl_f => self.log("[KEY] ctrl_f\n", .{}),
                        .ctrl_g => self.log("[KEY] ctrl_g\n", .{}),
                        .ctrl_h => self.log("[KEY] ctrl_h\n", .{}),
                        .ctrl_i => self.log("[KEY] ctrl_i\n", .{}),
                        .ctrl_j => self.log("[KEY] ctrl_j\n", .{}),
                        .ctrl_k => self.log("[KEY] ctrl_k\n", .{}),
                        .ctrl_l => self.log("[KEY] ctrl_l\n", .{}),
                        .ctrl_m => self.log("[KEY] ctrl_m\n", .{}),
                        .ctrl_n => self.log("[KEY] ctrl_n\n", .{}),
                        .ctrl_o => self.log("[KEY] ctrl_o\n", .{}),
                        .ctrl_p => self.log("[KEY] ctrl_p\n", .{}),
                        .ctrl_q => self.log("[KEY] ctrl_q\n", .{}),
                        .ctrl_r => self.log("[KEY] ctrl_r\n", .{}),
                        .ctrl_s => self.log("[KEY] ctrl_s\n", .{}),
                        .ctrl_t => self.log("[KEY] ctrl_t\n", .{}),
                        .ctrl_u => self.log("[KEY] ctrl_u\n", .{}),
                        .ctrl_v => self.log("[KEY] ctrl_v\n", .{}),
                        .ctrl_w => self.log("[KEY] ctrl_w\n", .{}),
                        .ctrl_x => self.log("[KEY] ctrl_x\n", .{}),
                        .ctrl_y => self.log("[KEY] ctrl_y\n", .{}),
                        .ctrl_z => self.log("[KEY] ctrl_z\n", .{}),
                        .alt_char => |c| self.log("[KEY] alt+{c}\n", .{c}),
                        .up => self.log("[KEY] up\n", .{}),
                        .down => self.log("[KEY] down\n", .{}),
                        .left => self.log("[KEY] left\n", .{}),
                        .right => self.log("[KEY] right\n", .{}),
                        .home => self.log("[KEY] home\n", .{}),
                        .end => self.log("[KEY] end\n", .{}),
                        .insert => self.log("[KEY] insert\n", .{}),
                        .delete => self.log("[KEY] delete\n", .{}),
                        .page_up => self.log("[KEY] page_up\n", .{}),
                        .page_down => self.log("[KEY] page_down\n", .{}),
                        .f1 => self.log("[KEY] f1\n", .{}),
                        .f2 => self.log("[KEY] f2\n", .{}),
                        .f3 => self.log("[KEY] f3\n", .{}),
                        .f4 => self.log("[KEY] f4\n", .{}),
                        .f5 => self.log("[KEY] f5\n", .{}),
                        .f6 => self.log("[KEY] f6\n", .{}),
                        .f7 => self.log("[KEY] f7\n", .{}),
                        .f8 => self.log("[KEY] f8\n", .{}),
                        .f9 => self.log("[KEY] f9\n", .{}),
                        .f10 => self.log("[KEY] f10\n", .{}),
                        .f11 => self.log("[KEY] f11\n", .{}),
                        .f12 => self.log("[KEY] f12\n", .{}),
                        .none => {},
                    }
                }

                // GLOBAL quit keys - Ctrl+Q/W/C only (work from ANY mode)
                const is_global_quit = switch (key) {
                    .ctrl_q, .ctrl_w, .ctrl_c => true,
                    else => false,
                };

                if (is_global_quit) {
                    self.running = false;
                    return;
                }

                // Help mode: ESC, ?, q close help (NOT quit app)
                if (self.mode == .help) {
                    const should_close = switch (key) {
                        .escape => true,  // ESC closes help
                        .char => |c| c == '?' or c == 'q' or c == 'Q',
                        else => false,
                    };

                    if (should_close) {
                        self.mode = .normal;
                        // Clear screen and force re-render after help overlay
                        var stdout_buf: [8192]u8 = undefined;
                        const stdout_file = std.fs.File.stdout();
                        var stdout_writer = stdout_file.writer(&stdout_buf);
                        const writer = &stdout_writer.interface;
                        try Screen.clear(writer);
                        try self.kitty.clearAll(writer);
                        try writer.flush();
                        // Reset frame time to force immediate render
                        self.last_frame_time = 0;
                        return;
                    }
                    // Ignore other keys in help mode
                    return;
                }

                // Normal mode: ESC quits the app
                if (self.mode == .normal) {
                    const should_quit = switch (key) {
                        .escape => true,
                        else => false,
                    };

                    if (should_quit) {
                        self.running = false;
                        return;
                    }
                }

                try self.handleKey(key);
            },
            .mouse => |mouse| try self.handleMouse(mouse),
            .none => {},
        }
    }

    /// Handle mouse event - dispatches to mode-specific handlers
    fn handleMouse(self: *Viewer, mouse: MouseEvent) !void {
        // Track mouse position for all events (for cursor rendering)
        self.mouse_x = mouse.x;
        self.mouse_y = mouse.y;
        self.mouse_visible = true;

        // Log parsed mouse events (if enabled)
        if (self.debug_input) {
            self.log("[MOUSE] type={s} button={s} x={} y={} delta_y={}\n", .{
                @tagName(mouse.type),
                @tagName(mouse.button),
                mouse.x,
                mouse.y,
                mouse.delta_y,
            });
        }

        // Dispatch to mode-specific handlers
        switch (self.mode) {
            .normal => try self.handleMouseNormal(mouse),
            .url_prompt => {}, // Ignore mouse in URL prompt mode
            .form_mode => {}, // TODO: Phase 6 - form mode mouse support
            .text_input => {}, // Ignore mouse in text input mode
            .help => {}, // Ignore mouse in help mode
        }
    }

    /// Handle mouse event in normal mode
    fn handleMouseNormal(self: *Viewer, mouse: MouseEvent) !void {
        const mapper = self.coord_mapper orelse return;

        switch (mouse.type) {
            .press => {
                if (mouse.button == .left) {
                    // Log mapper details for debugging (if enabled)
                    if (self.debug_input) {
                        self.log("[MOUSE] Terminal: {}x{} px, Viewport: {}x{}, Cell height: {} px\n", .{
                            mapper.terminal_width_px,
                            mapper.terminal_height_px,
                            mapper.viewport_width,
                            mapper.viewport_height,
                            mapper.cell_height,
                        });
                    }

                    // Map terminal coordinates to browser viewport
                    self.log("[COORD] term={}x{} term_px=({},{}) tab_h={} viewport={}x{}\n", .{
                        mapper.terminal_width_px, mapper.terminal_height_px,
                        mouse.x, mouse.y,
                        mapper.tabbar_height,
                        mapper.viewport_width, mapper.viewport_height,
                    });
                    if (mapper.terminalToBrowser(mouse.x, mouse.y)) |coords| {
                        self.log("[COORD] -> browser=({},{})\n", .{ coords.x, coords.y });
                        if (self.debug_input) {
                            self.log("[MOUSE] Terminal coords ({},{}) -> Browser coords ({},{})\n", .{
                                mouse.x,
                                mouse.y,
                                coords.x,
                                coords.y,
                            });
                        }

                        try interact_mod.clickAt(self.cdp_client, self.allocator, coords.x, coords.y);

                        // Store click info for status line display (after click, before refresh)
                        self.last_click = .{
                            .term_x = mouse.x,
                            .term_y = mouse.y,
                            .browser_x = coords.x,
                            .browser_y = coords.y,
                        };

                        try self.refresh();
                    } else {
                        if (self.debug_input) {
                            self.log("[MOUSE] Click in status line, ignoring\n", .{});
                        }
                    }
                }
            },
            .wheel => {
                // Get viewport size for scroll calculations
                const size = try self.terminal.getSize();
                const vw = size.width_px;
                const vh = size.height_px;

                // Scroll based on delta_y direction
                if (mouse.delta_y > 0) {
                    // Positive delta = scroll down
                    if (self.debug_input) {
                        self.log("[MOUSE] Wheel scroll down\n", .{});
                    }
                    try scroll_api.scrollLineDown(self.cdp_client, self.allocator, vw, vh);
                } else if (mouse.delta_y < 0) {
                    // Negative delta = scroll up
                    if (self.debug_input) {
                        self.log("[MOUSE] Wheel scroll up\n", .{});
                    }
                    try scroll_api.scrollLineUp(self.cdp_client, self.allocator, vw, vh);
                }
                try self.refresh();
            },
            else => {}, // Ignore release, move, drag events
        }
    }

    /// Handle key press - dispatches to mode-specific handlers
    fn handleKey(self: *Viewer, key: Key) !void {
        switch (self.mode) {
            .normal => try self.handleNormalMode(key),
            .url_prompt => try self.handleUrlPromptMode(key),
            .form_mode => try self.handleFormMode(key),
            .text_input => try self.handleTextInputMode(key),
            .help => {}, // Help mode only responds to Esc (handled in handleInput)
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
                    'r' => try self.refresh(), // lowercase = refresh screenshot only (also Ctrl+R)
                    'b' => { // back
                        const navigated = try screenshot_api.goBack(self.cdp_client, self.allocator);
                        if (navigated) {
                            try self.refresh();
                        }
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
                    '?' => {
                        // Enter help mode
                        self.mode = .help;
                        try self.drawHelp();
                    },
                    else => {},
                }
            },
            .escape => self.running = false,
            // Ctrl+W, Ctrl+Q, Ctrl+C handled globally (see handleInput)
            .ctrl_r => { // Chrome-style reload
                try screenshot_api.reload(self.cdp_client, self.allocator, false);
                try self.refresh();
            },
            .ctrl_l => {}, // Reserved for future use
            .ctrl_f => { // Chrome-style find (use for forms)
                self.mode = .form_mode;
                const ctx = try self.allocator.create(FormContext);
                ctx.* = FormContext.init(self.allocator);
                ctx.elements = try dom_mod.queryElements(self.cdp_client, self.allocator);
                self.form_context = ctx;
                try self.drawStatus();
            },
            .left => { // Arrow key navigation
                const navigated = try screenshot_api.goBack(self.cdp_client, self.allocator);
                if (navigated) {
                    try self.refresh();
                }
            },
            .right => {
                const navigated = try screenshot_api.goForward(self.cdp_client, self.allocator);
                if (navigated) {
                    try self.refresh();
                }
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
                if (c >= 32 and c <= 126) { // Printable characters
                    try prompt.insertChar(c);
                }
                try self.drawStatus();
            },
            .backspace => {
                prompt.backspace();
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
            .tab => {
                ctx.next();
                try self.drawStatus();
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
                if (c >= 32 and c <= 126) { // Printable characters
                    try prompt.insertChar(c);
                }
                try self.drawStatus();
            },
            .backspace => {
                prompt.backspace();
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
        var stdout_buf: [8192]u8 = undefined;
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
                // Truncate URL if needed
                const max_url_len = 40;
                var url_display: [64]u8 = undefined;
                const url_str = if (self.current_url.len > max_url_len) blk: {
                    const truncated = std.fmt.bufPrint(&url_display, "{s}...", .{self.current_url[0..@min(max_url_len - 3, self.current_url.len)]}) catch self.current_url;
                    break :blk truncated;
                } else self.current_url;

                if (self.last_click) |click| {
                    // Show click coordinates for debugging
                    if (self.coord_mapper) |mapper| {
                        try writer.print("{s} | T({d},{d}) B({d},{d}) [{d}x{d}px / {d}x{d}cells]", .{
                            url_str,
                            click.term_x,
                            click.term_y,
                            click.browser_x,
                            click.browser_y,
                            mapper.terminal_width_px,
                            mapper.terminal_height_px,
                            mapper.terminal_cols,
                            mapper.terminal_rows,
                        });
                    } else {
                        try writer.print("{s} | Click:({d},{d}) | [?]help", .{
                            url_str,
                            click.term_x,
                            click.term_y,
                        });
                    }
                } else {
                    try writer.print("{s} | [?]help [Ctrl+Q]uit [f]orm [g]oto [jk]scroll [r]efresh [b]ack", .{url_str});
                }
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
            .help => {
                try writer.print("HELP | [?] or [q] to close | [Ctrl+Q/W/C] or [ESC] to quit", .{});
            },
        }
        try writer.flush();  // Flush status line
    }

    /// Draw help overlay
    fn drawHelp(self: *Viewer) !void {
        var stdout_buf: [8192]u8 = undefined;
        const stdout_file = std.fs.File.stdout();
        var stdout_writer = stdout_file.writer(&stdout_buf);
        const writer = &stdout_writer.interface;

        try Screen.clear(writer);
        try Screen.moveCursor(writer, 1, 1);

        // Title
        try writer.writeAll("\x1b[1;37m"); // Bold white
        try writer.writeAll("┌─────────────────────────────────────────────────────────────┐" ++ CRLF);
        try writer.writeAll("│              TERMWEB - KEYBOARD & MOUSE HELP                │" ++ CRLF);
        try writer.writeAll("└─────────────────────────────────────────────────────────────┘\x1b[0m" ++ CRLF ++ CRLF);

        // Chrome shortcuts
        try writer.writeAll("\x1b[1;36mCHROME-STYLE SHORTCUTS:\x1b[0m" ++ CRLF);
        try writer.writeAll("  Ctrl+R        Reload page from server" ++ CRLF);
        try writer.writeAll("  Ctrl+F        Enter form mode (find/forms)" ++ CRLF);
        try writer.writeAll("  Ctrl+W/Q      Quit termweb" ++ CRLF ++ CRLF);

        // Navigation
        try writer.writeAll("\x1b[1;36mNAVIGATION:\x1b[0m" ++ CRLF);
        try writer.writeAll("  j, ↓          Scroll down one line" ++ CRLF);
        try writer.writeAll("  k, ↑          Scroll up one line" ++ CRLF);
        try writer.writeAll("  d             Scroll down half page" ++ CRLF);
        try writer.writeAll("  u             Scroll up half page" ++ CRLF);
        try writer.writeAll("  b, ←          Navigate back in history" ++ CRLF);
        try writer.writeAll("  →             Navigate forward in history" ++ CRLF);
        try writer.writeAll("  r             Refresh screenshot" ++ CRLF ++ CRLF);

        // Mouse
        try writer.writeAll("\x1b[1;36mMOUSE:\x1b[0m" ++ CRLF);
        try writer.writeAll("  Left Click    Click links and buttons" ++ CRLF);
        try writer.writeAll("  Wheel Up/Down Scroll page up/down" ++ CRLF ++ CRLF);

        // Other
        try writer.writeAll("\x1b[1;36mOTHER:\x1b[0m" ++ CRLF);
        try writer.writeAll("  ?             Toggle this help" ++ CRLF);
        try writer.writeAll("  g, G          Go to URL (address prompt)" ++ CRLF ++ CRLF);

        try writer.writeAll("\x1b[2m(Press ? or q to close help. Ctrl+Q quits anytime)\x1b[0m" ++ CRLF);

        try writer.flush();
        try self.drawStatus();
    }

    pub fn deinit(self: *Viewer) void {
        if (self.prompt_buffer) |*p| p.deinit();
        if (self.form_context) |ctx| {
            ctx.deinit();
            self.allocator.destroy(ctx);
        }
        if (self.debug_log) |file| {
            file.close();
        }
        self.terminal.deinit();
    }
};
