/// Main viewer module for termweb.
///
/// Implements the interactive browser session with a mode-based state machine.
/// Handles keyboard input, screenshot rendering, and user interaction modes.
const std = @import("std");
const terminal_mod = @import("terminal/terminal.zig");
const kitty_mod = @import("terminal/kitty_graphics.zig");
const shm_mod = @import("terminal/shm.zig");
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
const ShmBuffer = shm_mod.ShmBuffer;
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

fn envVarTruthy(allocator: std.mem.Allocator, name: []const u8) bool {
    const value = std.process.getEnvVarOwned(allocator, name) catch return false;
    defer allocator.free(value);

    return std.mem.eql(u8, value, "1") or
        std.mem.eql(u8, value, "true") or
        std.mem.eql(u8, value, "yes");
}

fn isGhosttyTerminal(allocator: std.mem.Allocator) bool {
    const term_program = std.process.getEnvVarOwned(allocator, "TERM_PROGRAM") catch null;
    if (term_program) |tp| {
        defer allocator.free(tp);
        if (std.mem.eql(u8, tp, "ghostty")) return true;
    }

    const term = std.process.getEnvVarOwned(allocator, "TERM") catch null;
    if (term) |t| {
        defer allocator.free(t);
        if (std.mem.indexOf(u8, t, "ghostty") != null) return true;
    }

    return false;
}

/// Detect if macOS natural scrolling is enabled
/// Returns true if natural scrolling is ON (default on macOS)
fn isNaturalScrollEnabled() bool {
    // Check override env var first
    const override = std.process.getEnvVarOwned(std.heap.page_allocator, "TERMWEB_NATURAL_SCROLL") catch null;
    if (override) |val| {
        defer std.heap.page_allocator.free(val);
        if (std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false")) return false;
        if (std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true")) return true;
    }

    // On macOS, read system preference
    // `defaults read NSGlobalDomain com.apple.swipescrolldirection` returns 1 for natural
    const result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &[_][]const u8{
            "defaults", "read", "NSGlobalDomain", "com.apple.swipescrolldirection",
        },
    }) catch return true; // Default to natural scroll if can't detect
    defer std.heap.page_allocator.free(result.stdout);
    defer std.heap.page_allocator.free(result.stderr);

    // Trim whitespace and check value
    const trimmed = std.mem.trim(u8, result.stdout, " \t\n\r");
    return !std.mem.eql(u8, trimmed, "0"); // 1 or missing = natural scroll
}

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
    screencast_format: screenshot_api.ScreenshotFormat,
    last_frame_time: i128,

    // UI state for layered rendering
    ui_state: UIState,

    // Toolbar renderer (Kitty graphics based)
    toolbar_renderer: ?ui_mod.ToolbarRenderer,

    // Mouse cursor tracking (pixel coordinates)
    mouse_x: u16,
    mouse_y: u16,
    mouse_visible: bool,
    mouse_buttons: u32, // Bitmask of currently pressed buttons
    cursor_image_id: ?u32,  // Track cursor image ID for cleanup

    // Input throttling
    last_input_time: i128,
    last_mouse_move_time: i128,  // Separate throttle for mouse move events

    // Frame tracking for skip detection and throttling
    last_rendered_generation: u64,
    last_content_image_id: ?u32, // Track content image ID for cleanup
    frames_skipped: u32,  // Counter for monitoring

    // Debug flags
    debug_input: bool,
    ui_dirty: bool, // Track if UI needs re-rendering

    // Shared memory buffer for zero-copy Kitty graphics
    shm_buffer: ?ShmBuffer,

    // Scroll direction (true = natural scrolling inverts delta)
    natural_scroll: bool,

    // Performance profiling
    perf_frame_count: u64,
    perf_total_render_ns: i128,
    perf_max_render_ns: i128,
    perf_last_report_time: i128,

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

        // Initialize SHM buffer for zero-copy Kitty rendering
        // Size: max viewport * 4 bytes (RGBA)
        const shm_size = viewport_width * viewport_height * 4;
        const force_shm = envVarTruthy(allocator, "TERMWEB_FORCE_SHM");
        const disable_shm = envVarTruthy(allocator, "TERMWEB_DISABLE_SHM") or
            (!force_shm and isGhosttyTerminal(allocator));
        const shm_buffer = if (disable_shm) null else ShmBuffer.init(shm_size) catch null;
        const screencast_format: screenshot_api.ScreenshotFormat = if (shm_buffer == null) .png else .jpeg;

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
            .screencast_format = screencast_format,
            .last_frame_time = 0,
            .ui_state = UIState{},
            .toolbar_renderer = null,
            .mouse_x = 0,
            .mouse_y = 0,
            .mouse_visible = false,
            .mouse_buttons = 0,
            .cursor_image_id = null,
            .last_input_time = 0,
            .last_mouse_move_time = 0,
            .last_rendered_generation = 0,
            .last_content_image_id = null,
            .frames_skipped = 0,
            .debug_input = enable_input_debug,
            .ui_dirty = true,
            .shm_buffer = shm_buffer,
            .natural_scroll = isNaturalScrollEnabled(),
            .perf_frame_count = 0,
            .perf_total_render_ns = 0,
            .perf_max_render_ns = 0,
            .perf_last_report_time = 0,
        };
    }

    /// Calculate max FPS based on viewport resolution
    /// Larger resolutions get lower FPS to maintain responsiveness
    fn getMaxFpsForResolution(self: *Viewer) u32 {
        const pixels = @as(u64, self.viewport_width) * @as(u64, self.viewport_height);

        // Thresholds based on total pixels
        if (pixels <= 800 * 600) return 60;           // Small: 60fps
        if (pixels <= 1280 * 720) return 45;          // 720p: 45fps
        if (pixels <= 1920 * 1080) return 30;         // 1080p: 30fps
        if (pixels <= 2560 * 1440) return 24;         // 1440p: 24fps
        return 15;                                     // 4K+: 15fps
    }

    /// Get minimum frame interval in nanoseconds based on resolution
    fn getMinFrameInterval(self: *Viewer) i128 {
        const max_fps = self.getMaxFpsForResolution();
        return @divFloor(std.time.ns_per_s, max_fps);
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

        var stdout_buf: [262144]u8 = undefined; // 256KB for toolbar graphics
        const stdout_file = std.fs.File.stdout();
        var stdout_writer = stdout_file.writer(&stdout_buf);
        const writer = &stdout_writer.interface;

        // Setup terminal
        self.log("[DEBUG] Entering raw mode...\n", .{});
        try self.terminal.enterRawMode();
        self.log("[DEBUG] Raw mode enabled successfully\n", .{});
        defer self.terminal.restore() catch {};

        // Install resize handler for SIGWINCH
        try self.terminal.installResizeHandler();
        self.log("[DEBUG] Resize handler installed\n", .{});

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

        // Initialize toolbar renderer with terminal pixel width
        const term_size = try self.terminal.getSize();
        const cell_width = if (term_size.cols > 0) term_size.width_px / term_size.cols else 10;
        self.toolbar_renderer = ui_mod.ToolbarRenderer.init(self.allocator, &self.kitty, term_size.width_px, cell_width) catch |err| blk: {
            self.log("[DEBUG] Toolbar init error: {}\n", .{err});
            break :blk null;
        };
        if (self.toolbar_renderer) |*renderer| {
            self.log("[DEBUG] Toolbar initialized, font_renderer={}\n", .{renderer.font_renderer != null});
            renderer.setUrl(self.current_url);
        } else {
            self.log("[DEBUG] Toolbar is null\n", .{});
        }

        // Render initial toolbar using Kitty graphics
        try self.renderToolbar(writer);
        try writer.flush();

        // Start screencast streaming with viewport dimensions
        // Note: cli.zig already scales viewport for High-DPI displays
        self.log("[DEBUG] Starting screencast {}x{}...\n", .{ self.viewport_width, self.viewport_height });
            
        try screenshot_api.startScreencast(self.cdp_client, self.allocator, .{
            .format = self.screencast_format,
            .quality = 80,
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

        // Get initial navigation state (after page has loaded)
        self.updateNavigationState();
        self.log("[DEBUG] Initial nav state: can_go_back={}, can_go_forward={}\\n", .{
            self.ui_state.can_go_back, self.ui_state.can_go_forward,
        });

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

            // Check for terminal resize (SIGWINCH)
            if (self.terminal.checkResize()) {
                self.log("[RESIZE] Terminal resized, updating viewport...\n", .{});
                try self.handleResize();
            }

            // Drain ALL pending input to avoid backlog (process up to 100 events per iteration)
            var events_processed: u32 = 0;
            while (events_processed < 100) : (events_processed += 1) {
                const input = self.input.readInput() catch |err| {
                    self.log("[ERROR] readInput() failed: {}\n", .{err});
                    return err;
                };

                if (input == .none) break; // No more pending input

                // Log and process (throttling happens inside handleMouse)
                switch (input) {
                    .key => |key| {
                        self.log("[INPUT] Key: {any}\n", .{key});
                        self.ui_dirty = true;
                    },
                    .mouse => |m| self.log("[INPUT] Mouse: type={s} x={d} y={d}\n", .{ @tagName(m.type), m.x, m.y }),
                    .none => {},
                }
                try self.handleInput(input);
            }

            // Render new screencast frames (non-blocking) - only in normal mode
            if (self.screencast_mode and self.mode == .normal) {
                const new_frame = self.tryRenderScreencast() catch false;

                // Redraw UI overlays ONLY if we got a new frame or UI is dirty (e.g. mouse moved)
                if (new_frame or self.ui_dirty) {
                    var stdout_buf2: [262144]u8 = undefined; // 256KB for toolbar graphics
                    const stdout_file2 = std.fs.File.stdout();
                    var stdout_writer2 = stdout_file2.writer(&stdout_buf2);
                    const writer2 = &stdout_writer2.interface;
                    self.renderCursor(writer2) catch {};
                    self.renderToolbar(writer2) catch {};
                    writer2.flush() catch {};
                    self.ui_dirty = false;
                }
            }

            // In URL prompt mode, re-render toolbar when dirty (for cursor updates)
            if (self.mode == .url_prompt and self.ui_dirty) {
                self.log("[URL_PROMPT] Rendering toolbar...\n", .{});
                var stdout_buf3: [262144]u8 = undefined; // 256KB for toolbar graphics
                const stdout_file3 = std.fs.File.stdout();
                var stdout_writer3 = stdout_file3.writer(&stdout_buf3);
                const writer3 = &stdout_writer3.interface;
                self.renderToolbar(writer3) catch |err| {
                    self.log("[URL_PROMPT] Toolbar render error: {}\n", .{err});
                };
                writer3.flush() catch |err| {
                    self.log("[URL_PROMPT] Flush error: {}\n", .{err});
                };
                self.log("[URL_PROMPT] Toolbar rendered\n", .{});
                self.ui_dirty = false;
            }

            // Throttle inner loop slightly to prevent flooding input/output
            std.Thread.sleep(5 * std.time.ns_per_ms);
        }

        self.log("[DEBUG] Exited main loop (running={}), loop_count={}\n", .{self.running, loop_count});

        // Stop screencast - don't wait for response (non-blocking)
        if (self.screencast_mode) {
            // Stop reader thread via client
            self.cdp_client.stopScreencast() catch {};
            self.screencast_mode = false;
        }

        // Cleanup - clear images, reset screen, show cursor
        self.kitty.clearAll(writer) catch {};
        Screen.clear(writer) catch {};
        Screen.showCursor(writer) catch {};
        Screen.moveCursor(writer, 1, 1) catch {};
        writer.writeAll("\x1b[0m") catch {}; // Reset all attributes
        writer.flush() catch {};
    }

    /// Handle terminal resize (SIGWINCH)
    fn handleResize(self: *Viewer) !void {
        // Get new terminal size
        const size = try self.terminal.getSize();

        // Calculate new viewport dimensions (same logic as cli.zig)
        const MIN_WIDTH: u32 = 800;
        const MIN_HEIGHT: u32 = 600;

        const raw_width: u32 = if (size.width_px > 0) size.width_px else @as(u32, size.cols) * 10;

        // Reserve 1 row for tab bar at top (no status bar)
        const row_height: u32 = if (size.height_px > 0 and size.rows > 0)
            @as(u32, size.height_px) / size.rows
        else
            20;
        const content_rows: u32 = if (size.rows > 1) size.rows - 1 else 1;
        const available_height = content_rows * row_height;

        const new_width: u32 = @max(MIN_WIDTH, raw_width);
        const new_height: u32 = @max(MIN_HEIGHT, available_height);

        self.log("[RESIZE] New size: {}x{} px, {}x{} cells -> viewport {}x{}\n", .{
            size.width_px, size.height_px, size.cols, size.rows, new_width, new_height,
        });

        // Skip if dimensions haven't changed significantly
        if (new_width == self.viewport_width and new_height == self.viewport_height) {
            self.log("[RESIZE] Dimensions unchanged, skipping\n", .{});
            return;
        }

        // Update stored viewport dimensions
        self.viewport_width = new_width;
        self.viewport_height = new_height;

        // Stop current screencast
        if (self.screencast_mode) {
            screenshot_api.stopScreencast(self.cdp_client, self.allocator) catch {};
            self.screencast_mode = false;
        }

        self.ui_dirty = true;

        // Update Chrome viewport
        try screenshot_api.setViewport(self.cdp_client, self.allocator, new_width, new_height);

        // Clear screen and all Kitty images
        var stdout_buf: [8192]u8 = undefined;
        const stdout_file = std.fs.File.stdout();
        var stdout_writer = stdout_file.writer(&stdout_buf);
        const writer = &stdout_writer.interface;
        try self.kitty.clearAll(writer);
        try Screen.clear(writer);
        try Screen.moveCursor(writer, 1, 1); // Reset cursor to top-left
        try writer.flush();

        // Restart screencast with new dimensions
        try screenshot_api.startScreencast(self.cdp_client, self.allocator, .{
            .format = self.screencast_format,
            .quality = 80,
            .width = new_width,
            .height = new_height,
        });
        self.screencast_mode = true;

        // Reset frame time and wait for first frame before rendering UI
        self.last_frame_time = 0;

        // Wait for first frame after resize (blocking, with timeout)
        var retries: u32 = 0;
        while (retries < 50) : (retries += 1) {
            if (try self.tryRenderScreencast()) {
                self.log("[RESIZE] First frame after resize received\n", .{});
                break;
            }
            std.Thread.sleep(20 * std.time.ns_per_ms);
        }

        self.log("[RESIZE] Viewport updated to {}x{}\n", .{ new_width, new_height });
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

        // Display image (leave room for status line)
        self.log("[DEBUG] Displaying PNG via Kitty graphics...\n", .{});

        // Ensure we have valid dimensions - if terminal size is 0, use reasonable defaults
        const display_rows = if (size.rows > 1) size.rows - 1 else if (size.rows > 0) size.rows else 24;
        const display_cols = if (size.cols > 0) size.cols else 80;

        self.log("[DEBUG] Display dimensions: rows={}, cols={}\n", .{display_rows, display_cols});

        // Pass base64 directly (no decode/encode roundtrip)
        _ = try self.kitty.displayBase64PNG(writer, base64_png, .{
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
        const now = std.time.nanoTimestamp();

        // Resolution-based FPS limiting
        const min_interval = self.getMinFrameInterval();
        if (self.last_frame_time > 0 and (now - self.last_frame_time) < min_interval) {
            return false; // Too soon, skip to maintain target FPS
        }

        // Get frame with proper ownership - MUST call deinit when done
        var frame = screenshot_api.getLatestScreencastFrame(self.cdp_client) orelse return false;
        defer frame.deinit(); // Proper cleanup!

        // Throttle: Don't re-render the same frame multiple times
        if (self.last_rendered_generation > 0 and frame.generation <= self.last_rendered_generation) {
            return false;
        }

        // Frame skip detection: Check if we skipped frames
        if (self.last_rendered_generation > 0 and frame.generation > self.last_rendered_generation + 1) {
            const skipped = frame.generation - self.last_rendered_generation - 1;
            self.frames_skipped += @intCast(skipped);
            self.log("[RENDER] Skipped {} frames (gen {} -> {})\n", .{
                skipped,
                self.last_rendered_generation,
                frame.generation,
            });
        }
        self.last_rendered_generation = frame.generation;

        // Use ACTUAL frame dimensions from CDP metadata for coordinate mapping
        // Chrome may send different size than requested viewport
        const frame_width = if (frame.device_width > 0) frame.device_width else self.viewport_width;
        const frame_height = if (frame.device_height > 0) frame.device_height else self.viewport_height;

        // Profile render time
        const render_start = std.time.nanoTimestamp();

        try self.displayFrameWithDimensions(frame.data, frame_width, frame_height);

        const render_elapsed = std.time.nanoTimestamp() - render_start;
        self.perf_frame_count += 1;
        self.perf_total_render_ns += render_elapsed;
        if (render_elapsed > self.perf_max_render_ns) {
            self.perf_max_render_ns = render_elapsed;
        }

        // Log performance stats every 5 seconds
        if (now - self.perf_last_report_time > 5 * std.time.ns_per_s) {
            const avg_ms = if (self.perf_frame_count > 0)
                @divFloor(@divFloor(self.perf_total_render_ns, @as(i128, self.perf_frame_count)), @as(i128, std.time.ns_per_ms))
            else
                0;
            const max_ms = @divFloor(self.perf_max_render_ns, @as(i128, std.time.ns_per_ms));
            const target_fps = self.getMaxFpsForResolution();

            self.log("[PERF] {} frames, avg={}ms, max={}ms, target={}fps, skipped={}\n", .{
                self.perf_frame_count, avg_ms, max_ms, target_fps, self.frames_skipped,
            });

            // Reset counters
            self.perf_frame_count = 0;
            self.perf_total_render_ns = 0;
            self.perf_max_render_ns = 0;
            self.perf_last_report_time = now;
        }

        self.last_frame_time = now;
        return true;
    }

    /// Update navigation button states from Chrome history (call after navigation events)
    fn updateNavigationState(self: *Viewer) void {
        const nav_state = screenshot_api.getNavigationState(self.cdp_client, self.allocator) catch return;
        self.ui_state.can_go_back = nav_state.can_go_back;
        self.ui_state.can_go_forward = nav_state.can_go_forward;
    }

    /// Display a base64 PNG frame with specific dimensions for coordinate mapping
    fn displayFrameWithDimensions(self: *Viewer, base64_png: []const u8, frame_width: u32, frame_height: u32) !void {
        // Larger buffer reduces write syscalls (frames can be 300KB+)
        var stdout_buf: [65536]u8 = undefined;  // 64KB buffer
        const stdout_file = std.fs.File.stdout();
        var stdout_writer = stdout_file.writer(&stdout_buf);
        const writer = &stdout_writer.interface;

        // Get terminal size - reserve 1 row for tab bar at top
        const size = try self.terminal.getSize();
        const tabbar_rows: u32 = 1;
        const content_rows = if (size.rows > tabbar_rows) size.rows - tabbar_rows else 1;
        const display_cols: u16 = if (size.cols > 0) size.cols else 80;

        // Note: We use the full column count from ioctl
        // The image will be scaled to fill all columns (2x scaling on Retina)
        // This is correct because cli.zig already halved the viewport width

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

        self.log("[RENDER] displayFrame: base64={} bytes, term={}x{}, display={}x{}, frame={}x{}\n", .{
            base64_png.len, size.cols, size.rows, display_cols, content_rows, frame_width, frame_height,
        });

        // Move cursor to row 2 (after tab bar)
        try writer.writeAll("\x1b[2;1H");

        // Use placement ID and Z-index to ensure correct layering and replacement
        const display_opts = kitty_mod.DisplayOptions{
            .rows = content_rows,
            .columns = display_cols,
            .placement_id = Placement.CONTENT,
            .z = ZIndex.CONTENT,
        };

        // Track old image ID for cleanup
        const old_image_id = self.last_content_image_id;
        var new_image_id: ?u32 = null;

        // Try SHM path first (decode image, write to SHM, zero-copy transfer to Kitty)
        if (self.shm_buffer) |*shm| {
            if (self.kitty.displayBase64ImageViaSHM(writer, base64_png, shm, display_opts) catch null) |id| {
                new_image_id = id;
                self.log("[RENDER] displayFrame via SHM complete (id={d})\n", .{id});
            } else {
                self.log("[RENDER] SHM path failed, falling back to base64\n", .{});
            }
        }

        // Fallback: Display via base64
        if (new_image_id == null) {
            if (self.screencast_format == .png) {
                new_image_id = try self.kitty.displayBase64PNG(writer, base64_png, display_opts);
            } else {
                new_image_id = try self.kitty.displayBase64Image(writer, base64_png, display_opts);
            }
            self.log("[RENDER] displayFrame via base64 complete (id={d})\n", .{new_image_id.?});
        }

        // Update tracking
        self.last_content_image_id = new_image_id;
        
        // IMPORTANT: Flush the new image to screen immediately
        try writer.flush();

        // Delete previous image resource to prevent terminal memory bloat
        if (old_image_id) |id| {
            try self.kitty.deleteImage(writer, id);
            try writer.flush();
        }
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

    /// Render the toolbar using Kitty graphics
    fn renderToolbar(self: *Viewer, writer: anytype) !void {
        if (self.toolbar_renderer) |*renderer| {
            renderer.setNavState(self.ui_state.can_go_back, self.ui_state.can_go_forward, self.ui_state.is_loading);
            renderer.setUrl(self.current_url);
            try renderer.render(writer);
        }
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
        const now = std.time.nanoTimestamp();

        // Throttle mouse MOVE events to ~60fps (16ms) to avoid flooding
        // Clicks, releases, and wheel events are always processed immediately
        if (mouse.type == .move or mouse.type == .drag) {
            const min_interval = 16 * std.time.ns_per_ms; // ~60fps
            if (now - self.last_mouse_move_time < min_interval) {
                return; // Skip this move event, too soon
            }
            self.last_mouse_move_time = now;
        }

        // ANSI mouse coordinates are 1-indexed. Normalize to 0-indexed for internal use.
        const norm_x = if (mouse.x > 0) mouse.x - 1 else 0;
        const norm_y = if (mouse.y > 0) mouse.y - 1 else 0;

        // Track mouse position for cursor rendering
        self.mouse_x = norm_x;
        self.mouse_y = norm_y;
        self.mouse_visible = true;
        self.ui_dirty = true;

        // Log parsed mouse events (if enabled)
        if (self.debug_input) {
            self.log("[MOUSE] type={s} button={s} x={} y={} (raw={},{}) delta_y={}\n", .{
                @tagName(mouse.type),
                @tagName(mouse.button),
                norm_x,
                norm_y,
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

    /// Handle click on tab bar buttons
    fn handleTabBarClick(self: *Viewer, pixel_x: u16, pixel_y: u16, mapper: CoordinateMapper) !void {
        // Calculate cell width for button positions
        const cell_width: u16 = if (mapper.terminal_cols > 0)
            mapper.terminal_width_px / mapper.terminal_cols
        else
            14;

        // Convert pixel X to column (0-indexed)
        const col: i32 = @intCast(pixel_x / cell_width);

        self.log("[TABBAR] Click at pixel_x={}, pixel_y={}, cell_width={}, col={}\n", .{ pixel_x, pixel_y, cell_width, col });

        // Use toolbar hit test if available
        if (self.toolbar_renderer) |*renderer| {
            if (renderer.hitTest(pixel_x, pixel_y)) |button| {
                switch (button) {
                    .close => {
                        self.log("[TABBAR] Close button clicked\n", .{});
                        self.running = false;
                    },
                    .back => {
                        self.log("[TABBAR] Back button clicked, can_go_back={}\\n", .{self.ui_state.can_go_back});
                        if (self.ui_state.can_go_back) {
                            _ = try screenshot_api.goBack(self.cdp_client, self.allocator);
                            self.updateNavigationState();
                        }
                    },
                    .forward => {
                        self.log("[TABBAR] Forward button clicked\n", .{});
                        if (self.ui_state.can_go_forward) {
                            _ = try screenshot_api.goForward(self.cdp_client, self.allocator);
                            self.updateNavigationState();
                        }
                    },
                    .refresh => {
                        self.log("[TABBAR] Refresh button clicked\n", .{});
                        try screenshot_api.reload(self.cdp_client, self.allocator, false);
                    },
                }
                return;
            }

            // Check if click is in URL bar area
            if (pixel_x >= renderer.url_bar_x and pixel_x < renderer.url_bar_x + renderer.url_bar_width) {
                self.log("[TABBAR] URL bar clicked\n", .{});
                renderer.focusUrl();
                self.mode = .url_prompt;
                self.ui_dirty = true;
                return;
            }
        }

        // Fallback: column-based detection
        if (col <= 2) {
            self.running = false;
        } else if (col >= 4 and col <= 6 and self.ui_state.can_go_back) {
            _ = try screenshot_api.goBack(self.cdp_client, self.allocator);
            self.updateNavigationState();
        } else if (col >= 8 and col <= 10 and self.ui_state.can_go_forward) {
            _ = try screenshot_api.goForward(self.cdp_client, self.allocator);
            self.updateNavigationState();
        } else if (col >= 12 and col <= 14) {
            try screenshot_api.reload(self.cdp_client, self.allocator, false);
        } else if (col >= 18) {
            self.mode = .url_prompt;
            if (self.toolbar_renderer) |*renderer| {
                renderer.focusUrl();
            }
            self.ui_dirty = true;
        }
    }

    /// Handle mouse event in normal mode
    fn handleMouseNormal(self: *Viewer, mouse: MouseEvent) !void {
        const mapper = self.coord_mapper orelse return;

        // Determine button mask and name
        var button_mask: u32 = 0;
        var button_name: []const u8 = "none";
        
        switch (mouse.button) {
            .left => { button_mask = 1; button_name = "left"; },
            .right => { button_mask = 2; button_name = "right"; },
            .middle => { button_mask = 4; button_name = "middle"; },
            else => {},
        }

        switch (mouse.type) {
            .press => {
                // Update button state (add pressed button)
                self.mouse_buttons |= button_mask;

                // Log mapper details for debugging (if enabled)
                if (self.debug_input) {
                    self.log("[MOUSE] Press: {} ({s}) mask={} total={}\n", .{
                        mouse.button, button_name, button_mask, self.mouse_buttons
                    });
                }

                if (mapper.terminalToBrowser(self.mouse_x, self.mouse_y)) |coords| {
                    self.log("[COORD] -> browser=({},{})\n", .{ coords.x, coords.y });

                    self.log("[INPUT] Sending mousePressed: ({},{}) button={s} buttons={} clickCount=1\n", .{
                        coords.x, coords.y, button_name, self.mouse_buttons
                    });

                    // WORKAROUND: Try both mousePressed and click
                    try interact_mod.sendMouseEvent(
                        self.cdp_client,
                        self.allocator,
                        "mousePressed",
                        coords.x,
                        coords.y,
                        button_name,
                        self.mouse_buttons,
                        1
                    );

                    // Store click info for status line display
                    // Note: This is now just "last interaction position" effectively
                    if (mouse.button == .left) {
                        self.last_click = .{
                            .term_x = self.mouse_x,
                            .term_y = self.mouse_y,
                            .browser_x = coords.x,
                            .browser_y = coords.y,
                        };
                        // Update navigation state (click may have navigated)
                        self.updateNavigationState();
                    }
                } else {
                    // Click is in tab bar - handle button clicks
                    // We handle this on PRESS for immediate feedback (like most UI buttons)
                    self.log("[CLICK] In tab bar: mouse=({},{}) tabbar_height={}\n", .{
                        self.mouse_x, self.mouse_y, mapper.tabbar_height,
                    });
                    try self.handleTabBarClick(self.mouse_x, self.mouse_y, mapper);
                }
            },
            .release => {
                // Update button state (remove released button)
                self.mouse_buttons &= ~button_mask;

                if (mapper.terminalToBrowser(self.mouse_x, self.mouse_y)) |coords| {
                    self.log("[INPUT] Sending mouseReleased: ({},{}) button={s} buttons={} clickCount=1\n", .{
                        coords.x, coords.y, button_name, self.mouse_buttons
                    });
                    try interact_mod.sendMouseEvent(
                        self.cdp_client,
                        self.allocator,
                        "mouseReleased",
                        coords.x,
                        coords.y,
                        button_name, // Release event needs the button that changed state
                        self.mouse_buttons,
                        1
                    );
                }
            },
            .move, .drag => {
                // Check if mouse is hovering over toolbar buttons
                if (self.toolbar_renderer) |*renderer| {
                    const old_hover = renderer.close_hover;
                    if (renderer.hitTest(self.mouse_x, self.mouse_y)) |button| {
                        renderer.close_hover = (button == .close);
                    } else {
                        renderer.close_hover = false;
                    }
                    // Re-render toolbar if hover state changed
                    if (renderer.close_hover != old_hover) {
                        self.ui_dirty = true;
                    }
                }

                // Forward mouse move to Chrome for hover and drag effects
                if (mapper.terminalToBrowser(self.mouse_x, self.mouse_y)) |coords| {
                    try interact_mod.sendMouseEvent(
                        self.cdp_client, 
                        self.allocator, 
                        "mouseMoved", 
                        coords.x, 
                        coords.y, 
                        "none", // Move events don't have a "changed" button
                        self.mouse_buttons, 
                        0
                    );
                }
            },
            .wheel => {
                // Throttle scroll events to avoid flooding CDP (max ~30 events/sec)
                const now = std.time.nanoTimestamp();
                const min_interval = 33 * std.time.ns_per_ms; // ~30fps
                if (now - self.last_input_time < min_interval) {
                    return; // Skip this event, too soon
                }
                self.last_input_time = now;

                // Get viewport size for scroll calculations
                const size = try self.terminal.getSize();
                const vw = size.width_px;
                const vh = size.height_px;

                // Scroll based on delta_y direction
                // Natural scroll: swipe up = scroll down (content moves up)
                // Traditional: swipe up = scroll up (content moves down)
                const scroll_down = if (self.natural_scroll)
                    mouse.delta_y < 0  // Natural: negative delta = scroll down
                else
                    mouse.delta_y > 0; // Traditional: positive delta = scroll down

                if (mouse.delta_y != 0) {
                    if (scroll_down) {
                        if (self.debug_input) {
                            self.log("[MOUSE] Wheel scroll down (natural={})\n", .{self.natural_scroll});
                        }
                        try scroll_api.scrollLineDown(self.cdp_client, self.allocator, vw, vh);
                    } else {
                        if (self.debug_input) {
                            self.log("[MOUSE] Wheel scroll up (natural={})\n", .{self.natural_scroll});
                        }
                        try scroll_api.scrollLineUp(self.cdp_client, self.allocator, vw, vh);
                    }
                }
            },

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
        // Use toolbar renderer for URL editing if available
        if (self.toolbar_renderer) |*renderer| {
            switch (key) {
                .char => |c| {
                    renderer.handleChar(c);
                    self.ui_dirty = true;
                },
                .backspace => {
                    renderer.handleBackspace();
                    self.ui_dirty = true;
                },
                .left => {
                    renderer.handleLeft();
                    self.ui_dirty = true;
                },
                .right => {
                    renderer.handleRight();
                    self.ui_dirty = true;
                },
                .home => {
                    renderer.handleHome();
                    self.ui_dirty = true;
                },
                .end => {
                    renderer.handleEnd();
                    self.ui_dirty = true;
                },
                .enter => {
                    const url = renderer.getUrlText();
                    if (url.len > 0) {
                        try screenshot_api.navigateToUrl(self.cdp_client, self.allocator, url);
                        self.updateNavigationState();
                    }
                    renderer.blurUrl();
                    self.mode = .normal;
                    self.ui_dirty = true;
                },
                .escape => {
                    renderer.blurUrl();
                    self.mode = .normal;
                    self.ui_dirty = true;
                },
                else => {},
            }
            return;
        }

        // Fallback to old prompt buffer
        if (self.prompt_buffer) |*prompt| {
            switch (key) {
                .char => |c| {
                    if (c >= 32 and c <= 126) {
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
                        try screenshot_api.navigateToUrl(self.cdp_client, self.allocator, url);
                        try self.refresh();
                    }
                    prompt.deinit();
                    self.prompt_buffer = null;
                    self.mode = .normal;
                    try self.drawStatus();
                },
                .escape => {
                    prompt.deinit();
                    self.prompt_buffer = null;
                    self.mode = .normal;
                    try self.drawStatus();
                },
                else => {},
            }
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

    /// Draw status line (only for non-normal modes that need user input)
    fn drawStatus(self: *Viewer) !void {
        // Don't show status bar in normal mode - use tab bar instead
        if (self.mode == .normal) return;

        var stdout_buf: [8192]u8 = undefined;
        const stdout_file = std.fs.File.stdout();
        var stdout_writer = stdout_file.writer(&stdout_buf);
        const writer = &stdout_writer.interface;

        const size = try self.terminal.getSize();

        // Move to last row and show dark background
        try Screen.moveCursor(writer, size.rows, 1);
        try Screen.clearLine(writer);
        try writer.writeAll("\x1b[48;2;40;40;40m\x1b[38;2;220;220;220m"); // Dark bg, light text

        // Status text based on mode
        switch (self.mode) {
            .normal => unreachable, // Already returned above
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
        try writer.writeAll("\x1b[0m"); // Reset colors
        try writer.flush();
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
        if (self.shm_buffer) |*shm| {
            shm.deinit();
        }
        if (self.toolbar_renderer) |*renderer| {
            renderer.deinit();
        }
        self.terminal.deinit();
    }
};
