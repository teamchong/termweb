/// Main viewer module for termweb.
///
/// Implements the interactive browser session with a mode-based state machine.
/// Handles keyboard input, screenshot rendering, and user interaction modes.
const std = @import("std");
const builtin = @import("builtin");
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
const mouse_event_bus = @import("mouse_event_bus.zig");
const dom_mod = @import("chrome/dom.zig");
const interact_mod = @import("chrome/interact.zig");
const download_mod = @import("chrome/download.zig");
const ui_mod = @import("ui/mod.zig");

const Terminal = terminal_mod.Terminal;
const KittyGraphics = kitty_mod.KittyGraphics;
const ShmBuffer = shm_mod.ShmBuffer;
const InputReader = input_mod.InputReader;
const Screen = screen_mod.Screen;
const Key = input_mod.Key;
const KeyInput = input_mod.KeyInput;
const Input = input_mod.Input;
const MouseEvent = input_mod.MouseEvent;
const CoordinateMapper = coordinates_mod.CoordinateMapper;
const PromptBuffer = prompt_mod.PromptBuffer;
const FormContext = dom_mod.FormContext;
const UIState = ui_mod.UIState;
const Placement = ui_mod.Placement;
const ZIndex = ui_mod.ZIndex;
const cursor_asset = ui_mod.assets.cursor;
const DialogType = ui_mod.DialogType;
const DialogState = ui_mod.DialogState;
const FilePickerMode = ui_mod.FilePickerMode;
const dialog_mod = ui_mod.dialog;

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
/// The viewer operates as a state machine with six distinct modes:
/// - normal: Default browsing mode (scroll, navigate, refresh)
/// - url_prompt: URL entry mode activated by Ctrl+L
/// - form_mode: Form element selection mode activated by 'f' key
/// - text_input: Text entry mode for filling form fields
/// - help: Help overlay showing key bindings
/// - dialog: Modal dialog mode for JavaScript alerts/confirms/prompts
///
/// Mode transitions:
///   Normal → URL Prompt (press Ctrl+L)
///   Normal → Form Mode (press 'f')
///   Normal → Help (press '?')
///   Normal → Dialog (JavaScript dialog event)
///   Form Mode → Text Input (press Enter on text field)
///   Any mode → Normal (press Esc or complete action)
pub const ViewerMode = enum {
    normal,       // Scroll, navigate, refresh
    url_prompt,   // Entering URL (Ctrl+L)
    form_mode,    // Selecting form elements (f key, Tab navigation)
    text_input,   // Typing into form field
    help,         // Help overlay (? key)
    dialog,       // JavaScript dialog (alert/confirm/prompt)
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
    viewport_width: u32,  // Requested viewport (for screencast)
    viewport_height: u32,
    chrome_actual_width: u32,  // Chrome's actual window.innerWidth (for coordinate mapping)
    chrome_actual_height: u32, // Chrome's actual window.innerHeight
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

    // Mouse event bus (decouples recording from dispatch)
    event_bus: mouse_event_bus.MouseEventBus,

    // Input throttling (deprecated - event bus handles mouse throttling)
    last_input_time: i128,
    last_mouse_move_time: i128,  // Separate throttle for mouse move events

    // Frame tracking for skip detection
    last_rendered_generation: u64,
    last_content_image_id: ?u32, // Track content image ID for cleanup

    // Navigation state debounce (avoid repeated CDP calls on rapid events)
    last_nav_state_update: i128,
    loading_started_at: i128, // When loading started (for minimum display time)
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

    // Dialog state for JavaScript dialogs (alert/confirm/prompt)
    dialog_state: ?*DialogState,
    dialog_message: ?[]const u8,

    // File System Access API - allowed roots (security: only allow access to user-selected directories)
    allowed_fs_roots: std.ArrayList([]const u8),

    // Download manager for file downloads
    download_manager: download_mod.DownloadManager,

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

        // Query Chrome's ACTUAL viewport (may differ from requested due to DPI scaling)
        // This is the source of truth for coordinate mapping
        var chrome_actual_w = viewport_width;
        var chrome_actual_h = viewport_height;
        if (screenshot_api.getActualViewport(cdp_client, allocator)) |actual_vp| {
            if (actual_vp.width > 0) chrome_actual_w = actual_vp.width;
            if (actual_vp.height > 0) chrome_actual_h = actual_vp.height;
        } else |_| {}

        return Viewer{
            .allocator = allocator,
            .terminal = Terminal.init(),
            .kitty = KittyGraphics.init(allocator),
            .cdp_client = cdp_client,
            .input = InputReader.init(std.posix.STDIN_FILENO, enable_input_debug),
            .current_url = try allocator.dupe(u8, url),
            .running = true,
            .mode = .normal,
            .prompt_buffer = null,
            .form_context = null,
            .debug_log = debug_log,
            .viewport_width = viewport_width,
            .viewport_height = viewport_height,
            .chrome_actual_width = chrome_actual_w,
            .chrome_actual_height = chrome_actual_h,
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
            .event_bus = mouse_event_bus.MouseEventBus.init(cdp_client, allocator, isNaturalScrollEnabled()),
            .last_input_time = 0,
            .last_mouse_move_time = 0,
            .last_rendered_generation = 0,
            .last_content_image_id = null,
            .last_nav_state_update = 0,
            .loading_started_at = 0,
            .frames_skipped = 0,
            .debug_input = enable_input_debug,
            .ui_dirty = true,
            .shm_buffer = shm_buffer,
            .natural_scroll = isNaturalScrollEnabled(),
            .perf_frame_count = 0,
            .perf_total_render_ns = 0,
            .perf_max_render_ns = 0,
            .perf_last_report_time = 0,
            .dialog_state = null,
            .dialog_message = null,
            .allowed_fs_roots = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            .download_manager = download_mod.DownloadManager.init(allocator, "/tmp/termweb-downloads"),
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
                self.handleResize() catch |err| {
                    // Browser may have closed during resize - exit gracefully
                    if (err == error.NotOpenForReading or err == error.BrokenPipe) {
                        self.log("[RESIZE] Browser disconnected, exiting...\n", .{});
                        self.running = false;
                        return;
                    }
                    return err;
                };
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

            // Tick mouse event bus (dispatch pending events at 30fps)
            self.event_bus.maybeTick();

            // Render new screencast frames (non-blocking) - only in normal mode
            if (self.screencast_mode and self.mode == .normal) {
                const new_frame = self.tryRenderScreencast() catch false;

                // Reset loading state when we get a new frame (page has loaded)
                // But only after minimum 300ms to ensure user sees the stop button
                if (new_frame and self.ui_state.is_loading) {
                    const now = std.time.nanoTimestamp();
                    const min_loading_time = 300 * std.time.ns_per_ms;
                    if (now - self.loading_started_at > min_loading_time) {
                        self.ui_state.is_loading = false;
                        self.ui_dirty = true;
                    }
                }

                // Event bus pattern: Check if navigation happened and update state
                // Debounced to avoid repeated CDP calls on rapid events (iframes, redirects)
                if (self.cdp_client.checkNavigationHappened()) {
                    const now = std.time.nanoTimestamp();
                    const debounce_interval = 500 * std.time.ns_per_ms; // 500ms debounce

                    if (now - self.last_nav_state_update > debounce_interval) {
                        self.log("[NAV EVENT] Navigation detected, updating state\n", .{});
                        const old_back = self.ui_state.can_go_back;
                        const old_fwd = self.ui_state.can_go_forward;
                        self.updateNavigationState();
                        self.last_nav_state_update = now;

                        if (old_back != self.ui_state.can_go_back or old_fwd != self.ui_state.can_go_forward) {
                            self.ui_dirty = true;
                        }
                    }
                    // Set loading state on navigation event (show stop button)
                    // Loading will be reset when new frame arrives (after min display time)
                    if (!self.ui_state.is_loading) {
                        self.ui_state.is_loading = true;
                        self.loading_started_at = std.time.nanoTimestamp();
                        self.ui_dirty = true;
                    }
                }

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

            // In dialog mode, render the dialog overlay
            if (self.mode == .dialog and self.ui_dirty) {
                var stdout_buf4: [8192]u8 = undefined;
                const stdout_file4 = std.fs.File.stdout();
                var stdout_writer4 = stdout_file4.writer(&stdout_buf4);
                const writer4 = &stdout_writer4.interface;
                self.renderDialog(writer4) catch {};
                writer4.flush() catch {};
                self.ui_dirty = false;
            }

            // Poll CDP events for JavaScript dialogs and file chooser
            if (self.cdp_client.nextEvent(self.allocator)) |maybe_event| {
                if (maybe_event) |*event| {
                    var evt = event.*;
                    defer evt.deinit();
                    self.handleCdpEvent(&evt) catch |err| {
                        self.log("[CDP EVENT] Error handling event: {}\n", .{err});
                    };
                }
            } else |_| {}

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

        // Update coordinate mapper using Chrome's actual viewport (source of truth)
        const toolbar_h: ?u16 = if (self.toolbar_renderer) |tr| @intCast(tr.toolbar_height) else null;
        self.coord_mapper = CoordinateMapper.initWithToolbar(
            size.width_px,
            size.height_px,
            size.cols,
            size.rows,
            self.chrome_actual_width,
            self.chrome_actual_height,
            toolbar_h,
        );
        self.log("[DEBUG] Coordinate mapper initialized (chrome={}x{})\n", .{ self.chrome_actual_width, self.chrome_actual_height });

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

        // Use screencast frame dimensions for coordinate mapping
        // The frame is what we actually display - Chrome's viewport may be larger
        // (e.g., download shelf takes space from viewport but screencast captures the content area)
        if (frame.device_width > 0 and frame.device_height > 0) {
            if (frame_width != self.chrome_actual_width or frame_height != self.chrome_actual_height) {
                self.log("[FRAME] Coord space changed: {}x{} -> {}x{}\n", .{
                    self.chrome_actual_width, self.chrome_actual_height,
                    frame_width, frame_height,
                });
                self.chrome_actual_width = frame_width;
                self.chrome_actual_height = frame_height;
            }
        }

        // Debug: Log actual frame dimensions from Chrome
        if (self.perf_frame_count < 5) {
            self.log("[FRAME] device={}x{} (raw={}x{}), chrome={}x{}\n", .{
                frame_width, frame_height, frame.device_width, frame.device_height,
                self.chrome_actual_width, self.chrome_actual_height,
            });
        }

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
        // Refresh Chrome's actual viewport (may change after navigation/zoom)
        self.refreshChromeViewport();
    }

    /// Refresh Chrome's actual viewport dimensions (source of truth for coordinate mapping)
    fn refreshChromeViewport(self: *Viewer) void {
        if (screenshot_api.getActualViewport(self.cdp_client, self.allocator)) |actual_vp| {
            self.log("[VIEWPORT] Query returned: {}x{}\n", .{ actual_vp.width, actual_vp.height });
            if (actual_vp.width > 0 and actual_vp.height > 0) {
                if (actual_vp.width != self.chrome_actual_width or actual_vp.height != self.chrome_actual_height) {
                    self.log("[VIEWPORT] Chrome actual changed: {}x{} -> {}x{}\n", .{
                        self.chrome_actual_width, self.chrome_actual_height,
                        actual_vp.width, actual_vp.height,
                    });
                    self.chrome_actual_width = actual_vp.width;
                    self.chrome_actual_height = actual_vp.height;
                }
            }
        } else |err| {
            self.log("[VIEWPORT] Query failed: {}\n", .{err});
        }
    }

    /// Display a base64 PNG frame with specific dimensions for coordinate mapping
    fn displayFrameWithDimensions(self: *Viewer, base64_png: []const u8, frame_width: u32, frame_height: u32) !void {
        // Larger buffer reduces write syscalls (frames can be 300KB+)
        var stdout_buf: [65536]u8 = undefined;  // 64KB buffer
        const stdout_file = std.fs.File.stdout();
        var stdout_writer = stdout_file.writer(&stdout_buf);
        const writer = &stdout_writer.interface;

        // Get terminal size
        const size = try self.terminal.getSize();
        const display_cols: u16 = if (size.cols > 0) size.cols else 80;

        // Calculate cell height and toolbar rows
        const cell_height: u32 = if (size.rows > 0) size.height_px / size.rows else 20;
        const toolbar_h: u32 = if (self.toolbar_renderer) |tr| tr.toolbar_height else cell_height;

        // Content starts at row 2, with y_offset to align with toolbar bottom
        // This avoids gaps between toolbar and content
        const row_start_pixel = cell_height; // Row 2 starts at 1 * cell_height
        const y_offset: u32 = if (toolbar_h > row_start_pixel) toolbar_h - row_start_pixel else 0;

        // Calculate content rows (account for toolbar pixel height, not row count)
        const content_pixel_start = row_start_pixel + y_offset; // = toolbar_h
        const content_pixel_height = if (size.height_px > content_pixel_start)
            size.height_px - content_pixel_start
        else
            size.height_px;
        const content_rows: u32 = content_pixel_height / cell_height;

        // Update coordinate mapper with Chrome's ACTUAL viewport (source of truth)
        // Chrome's window.innerWidth/Height is where mouse events are dispatched
        self.coord_mapper = CoordinateMapper.initWithToolbar(
            size.width_px,
            size.height_px,
            size.cols,
            size.rows,
            self.chrome_actual_width,   // Chrome's actual viewport, not frame size
            self.chrome_actual_height,
            @intCast(toolbar_h),
        );

        self.log("[RENDER] displayFrame: base64={} bytes, term={}x{}, display={}x{}, frame={}x{}, chrome={}x{}, y_off={}\n", .{
            base64_png.len, size.cols, size.rows, display_cols, content_rows, frame_width, frame_height,
            self.chrome_actual_width, self.chrome_actual_height, y_offset,
        });

        // Move cursor to row 2
        try writer.writeAll("\x1b[2;1H");

        // Use placement ID and Z-index to ensure correct layering and replacement
        // y_offset shifts content down to start right after toolbar
        const display_opts = kitty_mod.DisplayOptions{
            .rows = content_rows,
            .columns = display_cols,
            .placement_id = Placement.CONTENT,
            .z = ZIndex.CONTENT,
            .y_offset = @intCast(y_offset),
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
            .key => |key_input| {
                const key = key_input.key;
                const modifiers = key_input.modifiers;
                // Debug log all key presses (if enabled)
                if (self.debug_input) {
                    if (modifiers != 0) {
                        self.log("[KEY] modifiers: {d}\n", .{modifiers});
                    }
                    switch (key) {
                        .char => |c| self.log("[KEY] char: {d} ('{c}')\n", .{ c, if (c >= 32 and c <= 126) c else '.' }),
                        .escape => self.log("[KEY] escape\n", .{}),
                        .tab => self.log("[KEY] tab\n", .{}),
                        .shift_tab => self.log("[KEY] shift_tab\n", .{}),
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

                try self.handleKey(key_input);
            },
            .mouse => |mouse| try self.handleMouse(mouse),
            .none => {},
        }
    }

    /// Handle mouse event - records to event bus and dispatches to mode-specific handlers
    /// Throttling/prioritization is handled by the event bus (30fps tick)
    fn handleMouse(self: *Viewer, mouse: MouseEvent) !void {
        // Normalize mouse coordinates:
        // - SGR 1006 (cell mode): 1-indexed, need to subtract 1
        // - SGR 1016 (pixel mode): 0-indexed, no adjustment needed
        const is_pixel = if (self.coord_mapper) |m| m.is_pixel_mode else false;
        const norm_x = if (is_pixel) mouse.x else if (mouse.x > 0) mouse.x - 1 else 0;
        const norm_y = if (is_pixel) mouse.y else if (mouse.y > 0) mouse.y - 1 else 0;

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

        // Get viewport size for event bus
        const term_size = self.terminal.getSize() catch terminal_mod.TerminalSize{
            .cols = 80,
            .rows = 24,
            .width_px = 800,
            .height_px = 600,
        };

        // Update event bus coord mapper reference and record the event
        // The bus handles all throttling/prioritization and dispatches at 30fps
        if (self.coord_mapper) |*mapper| {
            self.event_bus.setCoordMapper(mapper);
        }
        self.mouse_buttons = self.event_bus.record(mouse, norm_x, norm_y, term_size.width_px, term_size.height_px);

        // Dispatch to mode-specific handlers (for local UI interactions only)
        switch (self.mode) {
            .normal => try self.handleMouseNormal(mouse),
            .url_prompt => {
                // Click outside URL bar cancels prompt and returns to normal mode
                if (mouse.type == .press) {
                    if (self.toolbar_renderer) |*renderer| {
                        const mouse_pixels = self.mouseToPixels();
                        const in_url_bar = mouse_pixels.x >= renderer.url_bar_x and
                            mouse_pixels.x < renderer.url_bar_x + renderer.url_bar_width and
                            mouse_pixels.y <= renderer.toolbar_height;
                        if (!in_url_bar) {
                            renderer.blurUrl();
                            self.mode = .normal;
                            self.ui_dirty = true;
                        }
                    }
                }
            },
            .form_mode => {}, // TODO: Phase 6 - form mode mouse support
            .text_input => {}, // Ignore mouse in text input mode
            .help => {}, // Ignore mouse in help mode
            .dialog => {}, // Ignore mouse in dialog mode (keyboard only)
        }
    }

    /// Handle click on tab bar buttons
    fn handleTabBarClick(self: *Viewer, pixel_x: u32, pixel_y: u32, mapper: CoordinateMapper) !void {
        if (self.toolbar_renderer) |*renderer| {
            self.log("[CLICK] handleTabBarClick x={} y={}\n", .{ pixel_x, pixel_y });
            
            if (renderer.hitTest(pixel_x, pixel_y)) |button| {
                self.log("[CLICK] Button hit: {}\n", .{button});
                
                switch (button) {
                    .back => {
                        self.log("[CLICK] Back button (can_back={})\n", .{self.ui_state.can_go_back});
                        // Always try to go back even if state says no (state might be stale)
                        _ = screenshot_api.goBack(self.cdp_client, self.allocator) catch |err| {
                            self.log("[CLICK] Back failed: {}\n", .{err});
                            return; // Don't update UI state if command failed
                        };
                        // Optimistic update only on success
                        self.ui_state.can_go_forward = true;
                        self.ui_dirty = true;
                    },
                    .forward => {
                        self.log("[CLICK] Forward button\n", .{});
                        if (self.ui_state.can_go_forward) {
                            _ = screenshot_api.goForward(self.cdp_client, self.allocator) catch |err| {
                                self.log("[CLICK] Forward failed: {}\n", .{err});
                                return; // Don't update UI state if command failed
                            };
                            self.ui_state.can_go_back = true;
                            self.ui_dirty = true;
                        }
                    },
                    .refresh => {
                        self.log("[CLICK] Refresh button (loading={})\n", .{self.ui_state.is_loading});
                        // Always reload (like most browsers - clicking refresh during load restarts it)
                        self.log("[CLICK] Sending reload command\n", .{});
                        _ = screenshot_api.reload(self.cdp_client, self.allocator, true) catch |err| {
                            self.log("[CLICK] Reload failed: {}\n", .{err});
                            return;
                        };
                        self.ui_state.is_loading = true;
                        self.loading_started_at = std.time.nanoTimestamp();
                        self.ui_dirty = true;
                    },
                    .close => {
                        self.log("[CLICK] Close button\n", .{});
                        self.running = false;
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

        // Calculate cell width for button positions
        const cell_width: u16 = if (mapper.terminal_cols > 0)
            mapper.terminal_width_px / mapper.terminal_cols
        else
            14;

        // Convert pixel X to column (0-indexed)
        const col: i32 = @intCast(pixel_x / cell_width);

        self.log("[TABBAR] Click at pixel_x={}, pixel_y={}, cell_width={}, col={}\n", .{ pixel_x, pixel_y, cell_width, col });

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

    /// Handle mouse event in normal mode - local UI interactions only
    /// CDP dispatch is handled by the event bus (30fps tick)
    fn handleMouseNormal(self: *Viewer, mouse: MouseEvent) !void {
        const mapper = self.coord_mapper orelse return;

        switch (mouse.type) {
            .press => {
                // Check if click is in browser area or tab bar
                if (mapper.terminalToBrowser(self.mouse_x, self.mouse_y)) |coords| {
                    // Store click info for status line display
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
                    // Click is in tab bar - handle button clicks locally
                    // We handle this on PRESS for immediate feedback (like most UI buttons)
                    const mouse_pixels = self.mouseToPixels();
                    self.log("[CLICK] In tab bar: mouse=({},{}) pixels=({},{}) tabbar_height={} is_pixel_mode={}\n", .{
                        self.mouse_x, self.mouse_y, mouse_pixels.x, mouse_pixels.y, mapper.tabbar_height, mapper.is_pixel_mode,
                    });
                    try self.handleTabBarClick(mouse_pixels.x, mouse_pixels.y, mapper);
                }
            },
            .release => {
                // No local UI handling needed for release
            },
            .move, .drag => {
                // Check if mouse is hovering over toolbar buttons (local UI)
                if (self.toolbar_renderer) |*renderer| {
                    // Track previous hover states
                    const old_close = renderer.close_hover;
                    const old_back = renderer.back_hover;
                    const old_forward = renderer.forward_hover;
                    const old_refresh = renderer.refresh_hover;
                    const old_url = renderer.url_bar_hover;

                    // Reset all hover states
                    renderer.close_hover = false;
                    renderer.back_hover = false;
                    renderer.forward_hover = false;
                    renderer.refresh_hover = false;
                    renderer.url_bar_hover = false;

                    // Set hover for the button under cursor
                    const mouse_pixels = self.mouseToPixels();
                    if (renderer.hitTest(mouse_pixels.x, mouse_pixels.y)) |button| {
                        switch (button) {
                            .close => renderer.close_hover = true,
                            .back => renderer.back_hover = true,
                            .forward => renderer.forward_hover = true,
                            .refresh => renderer.refresh_hover = true,
                        }
                    } else if (mouse_pixels.y < renderer.toolbar_height) {
                        // Check URL bar hover (within toolbar area)
                        if (mouse_pixels.x >= renderer.url_bar_x and
                            mouse_pixels.x < renderer.url_bar_x + renderer.url_bar_width)
                        {
                            renderer.url_bar_hover = true;
                        }
                    }

                    // Re-render toolbar if any hover state changed
                    if (renderer.close_hover != old_close or
                        renderer.back_hover != old_back or
                        renderer.forward_hover != old_forward or
                        renderer.refresh_hover != old_refresh or
                        renderer.url_bar_hover != old_url)
                    {
                        self.ui_dirty = true;
                    }
                }
            },
            .wheel => {
                // Wheel events are fully handled by the event bus
            },
        }
    }

    /// Handle key press - dispatches to mode-specific handlers
    fn handleKey(self: *Viewer, key_input: KeyInput) !void {
        switch (self.mode) {
            .normal => try self.handleNormalMode(key_input),
            .url_prompt => try self.handleUrlPromptMode(key_input),
            .form_mode => try self.handleFormMode(key_input.key),
            .text_input => try self.handleTextInputMode(key_input.key),
            .help => {}, // Help mode only responds to Esc (handled in handleInput)
            .dialog => try self.handleDialogMode(key_input.key),
        }
    }

    /// Handle key press in normal mode
    /// All keys pass to browser except termweb hotkeys:
    /// - Ctrl+Q/W/C: quit (handled globally)
    /// - Ctrl+L: address bar
    /// - Ctrl+R: reload
    fn handleNormalMode(self: *Viewer, key_input: KeyInput) !void {
        const key = key_input.key;
        const mods = key_input.modifiers; // CDP: 1=alt, 2=ctrl, 4=meta, 8=shift
        switch (key) {
            .char => |c| {
                // Pass all characters to browser (with modifiers via sendSpecialKeyWithModifiers)
                // For regular chars, use sendChar which doesn't support modifiers for now
                interact_mod.sendChar(self.cdp_client, self.allocator, c);
            },
            .escape => interact_mod.sendSpecialKeyWithModifiers(self.cdp_client, "Escape", 27, mods),
            // Ctrl+W, Ctrl+Q, Ctrl+C handled globally (see handleInput)
            .ctrl_r => { // Chrome-style reload
                try screenshot_api.reload(self.cdp_client, self.allocator, false);
                try self.refresh();
            },
            .ctrl_l => { // Chrome-style address bar focus
                self.mode = .url_prompt;
                if (self.toolbar_renderer) |*renderer| {
                    renderer.setUrl(self.current_url);
                    renderer.focusUrl();
                } else {
                    self.prompt_buffer = try PromptBuffer.init(self.allocator);
                }
                self.ui_dirty = true;
            },
            // Arrow keys - pass to browser with modifiers
            .left => interact_mod.sendSpecialKeyWithModifiers(self.cdp_client, "ArrowLeft", 37, mods),
            .right => interact_mod.sendSpecialKeyWithModifiers(self.cdp_client, "ArrowRight", 39, mods),
            .up => interact_mod.sendSpecialKeyWithModifiers(self.cdp_client, "ArrowUp", 38, mods),
            .down => interact_mod.sendSpecialKeyWithModifiers(self.cdp_client, "ArrowDown", 40, mods),
            // Special keys - pass to browser with modifiers
            .enter => interact_mod.sendSpecialKeyWithModifiers(self.cdp_client, "Enter", 13, mods),
            .backspace => interact_mod.sendSpecialKeyWithModifiers(self.cdp_client, "Backspace", 8, mods),
            .tab => interact_mod.sendSpecialKeyWithModifiers(self.cdp_client, "Tab", 9, mods),
            .shift_tab => interact_mod.sendSpecialKeyWithModifiers(self.cdp_client, "Tab", 9, mods | 8), // Ensure shift is set
            .delete => interact_mod.sendSpecialKeyWithModifiers(self.cdp_client, "Delete", 46, mods),
            .home => interact_mod.sendSpecialKeyWithModifiers(self.cdp_client, "Home", 36, mods),
            .end => interact_mod.sendSpecialKeyWithModifiers(self.cdp_client, "End", 35, mods),
            .page_up => interact_mod.sendSpecialKeyWithModifiers(self.cdp_client, "PageUp", 33, mods),
            .page_down => interact_mod.sendSpecialKeyWithModifiers(self.cdp_client, "PageDown", 34, mods),
            else => {},
        }
    }

    /// Handle key press in URL prompt mode
    fn handleUrlPromptMode(self: *Viewer, key_input: KeyInput) !void {
        const key = key_input.key;
        const mods = key_input.modifiers; // CDP modifiers: 1=alt, 2=ctrl, 4=meta, 8=shift
        const shift = (mods & 8) != 0;
        const ctrl = (mods & 2) != 0;
        const alt = (mods & 1) != 0; // Option on macOS
        const meta = (mods & 4) != 0; // Cmd on macOS

        // Platform-specific modifier for shortcuts
        const is_macos = comptime builtin.os.tag == .macos;
        const cmd_or_ctrl = if (is_macos) meta else ctrl; // Cmd on macOS, Ctrl on Linux
        const word_nav_mod = if (is_macos) alt else ctrl; // Option on macOS, Ctrl on Linux
        const line_nav_mod = if (is_macos) meta else false; // Cmd+arrow = Home/End on macOS only

        // Use toolbar renderer for URL editing if available
        if (self.toolbar_renderer) |*renderer| {
            switch (key) {
                .char => |c| {
                    // Handle Cmd+key (macOS) or Ctrl+key (Linux) shortcuts
                    if (cmd_or_ctrl) {
                        switch (c) {
                            'a', 'A' => {
                                renderer.handleSelectAll();
                                self.ui_dirty = true;
                                return;
                            },
                            'x', 'X' => {
                                renderer.handleCut(self.allocator);
                                self.ui_dirty = true;
                                return;
                            },
                            'c', 'C' => {
                                renderer.handleCopy(self.allocator);
                                return;
                            },
                            'v', 'V' => {
                                renderer.handlePaste(self.allocator);
                                self.ui_dirty = true;
                                return;
                            },
                            else => {},
                        }
                    }
                    renderer.handleChar(c);
                    self.ui_dirty = true;
                },
                .backspace => {
                    renderer.handleBackspace();
                    self.ui_dirty = true;
                },
                .left => {
                    if (shift) {
                        renderer.handleSelectLeft();
                    } else if (line_nav_mod) {
                        // Cmd+Left on macOS = Home
                        renderer.handleHome();
                    } else if (word_nav_mod) {
                        // Option+Left on macOS, Ctrl+Left on Linux = word left
                        renderer.handleWordLeft();
                    } else {
                        renderer.handleLeft();
                    }
                    self.ui_dirty = true;
                },
                .right => {
                    if (shift) {
                        renderer.handleSelectRight();
                    } else if (line_nav_mod) {
                        // Cmd+Right on macOS = End
                        renderer.handleEnd();
                    } else if (word_nav_mod) {
                        // Option+Right on macOS, Ctrl+Right on Linux = word right
                        renderer.handleWordRight();
                    } else {
                        renderer.handleRight();
                    }
                    self.ui_dirty = true;
                },
                .home => {
                    if (shift) {
                        renderer.handleSelectHome();
                    } else {
                        renderer.handleHome();
                    }
                    self.ui_dirty = true;
                },
                .end => {
                    if (shift) {
                        renderer.handleSelectEnd();
                    } else {
                        renderer.handleEnd();
                    }
                    self.ui_dirty = true;
                },
                .delete => {
                    renderer.handleDelete();
                    self.ui_dirty = true;
                },
                .ctrl_a => {
                    renderer.handleSelectAll();
                    self.ui_dirty = true;
                },
                .ctrl_x => {
                    renderer.handleCut(self.allocator);
                    self.ui_dirty = true;
                },
                .ctrl_c => {
                    renderer.handleCopy(self.allocator);
                    // Don't exit URL mode on Ctrl+C when we have text selected
                },
                .ctrl_v => {
                    renderer.handlePaste(self.allocator);
                    self.ui_dirty = true;
                },
                .enter => {
                    const url = renderer.getUrlText();
                    self.log("[URL] Enter pressed, url_len={}, url='{s}'\n", .{ url.len, url });
                    if (url.len > 0) {
                        self.log("[URL] Navigating to: {s}\n", .{url});
                        screenshot_api.navigateToUrl(self.cdp_client, self.allocator, url) catch |err| {
                            self.log("[URL] Navigation failed: {}\n", .{err});
                        };
                        // Update current_url to match the new URL (only if different)
                        if (!std.mem.eql(u8, self.current_url, url)) {
                            const new_url = self.allocator.dupe(u8, url) catch {
                                self.log("[URL] Failed to allocate new URL\n", .{});
                                self.updateNavigationState();
                                renderer.blurUrl();
                                self.mode = .normal;
                                self.ui_dirty = true;
                                return;
                            };
                            // Free old URL and replace
                            self.allocator.free(self.current_url);
                            self.current_url = new_url;
                        }
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
                interact_mod.pressEnter(self.cdp_client, self.allocator);

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
                try writer.print("HELP | [?] or [q] to close | [Ctrl+Q/W/C] to quit", .{});
            },
            .dialog => {
                // Dialog mode - status shown in dialog overlay
                try writer.print("DIALOG | [Enter] OK [Esc] Cancel", .{});
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

        // Chrome key bindings
        try writer.writeAll("\x1b[1;36mCHROME-STYLE KEYS:\x1b[0m" ++ CRLF);
        try writer.writeAll("  Ctrl+L        Focus address bar" ++ CRLF);
        try writer.writeAll("  Ctrl+R        Reload page from server" ++ CRLF);
        try writer.writeAll("  Ctrl+F        Enter form mode (find/forms)" ++ CRLF);
        try writer.writeAll("  Ctrl+Q/W      Quit termweb" ++ CRLF ++ CRLF);

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
        try writer.writeAll("  ?             Toggle this help" ++ CRLF ++ CRLF);

        try writer.writeAll("\x1b[2m(Press ? or q to close help. Ctrl+Q quits anytime)\x1b[0m" ++ CRLF);

        try writer.flush();
        try self.drawStatus();
    }

    /// Handle CDP events (JavaScript dialogs, file chooser, console messages)
    fn handleCdpEvent(self: *Viewer, event: *cdp.CdpEvent) !void {
        self.log("[CDP EVENT] method={s}\n", .{event.method});

        if (std.mem.eql(u8, event.method, "Page.javascriptDialogOpening")) {
            try self.showJsDialog(event.payload);
        } else if (std.mem.eql(u8, event.method, "Page.fileChooserOpened")) {
            try self.showFileChooser(event.payload);
        } else if (std.mem.eql(u8, event.method, "Runtime.consoleAPICalled")) {
            try self.handleConsoleMessage(event.payload);
        } else if (std.mem.eql(u8, event.method, "Browser.downloadWillBegin")) {
            try self.handleDownloadWillBegin(event.payload);
        } else if (std.mem.eql(u8, event.method, "Browser.downloadProgress")) {
            try self.handleDownloadProgress(event.payload);
        } else if (std.mem.eql(u8, event.method, "Page.frameNavigated") or
                   std.mem.eql(u8, event.method, "Page.navigatedWithinDocument")) {
            self.handleNavigationEvent(event.payload);
        }
    }

    /// Handle navigation events - extract URL and update address bar
    fn handleNavigationEvent(self: *Viewer, payload: []const u8) void {
        // Extract URL from event payload
        // Page.frameNavigated: {"frame":{"url":"https://...",...}}
        // Page.navigatedWithinDocument: {"frameId":"...","url":"https://..."}
        const url = extractUrlFromNavEvent(payload) orelse return;

        self.log("[NAV EVENT] URL: {s}\n", .{url});

        // Update current_url if different
        if (!std.mem.eql(u8, self.current_url, url)) {
            const new_url = self.allocator.dupe(u8, url) catch return;
            // Free old URL and replace
            self.allocator.free(self.current_url);
            self.current_url = new_url;

            // Update toolbar display
            if (self.toolbar_renderer) |*renderer| {
                renderer.setUrl(new_url);
                self.ui_dirty = true;
            }
        }

        // Update back/forward button state
        self.updateNavigationState();
    }

    /// Handle Browser.downloadWillBegin event - prompt user for save location
    fn handleDownloadWillBegin(self: *Viewer, payload: []const u8) !void {
        self.log("[DOWNLOAD] downloadWillBegin: {s}\n", .{payload[0..@min(payload.len, 500)]});

        if (download_mod.parseDownloadWillBegin(payload)) |info| {
            self.log("[DOWNLOAD] guid={s} filename={s}\n", .{ info.guid, info.suggested_filename });
            try self.download_manager.handleDownloadWillBegin(
                info.guid,
                info.url,
                info.suggested_filename,
            );
        }
    }

    /// Handle Browser.downloadProgress event - track progress and move file when complete
    fn handleDownloadProgress(self: *Viewer, payload: []const u8) !void {
        if (download_mod.parseDownloadProgress(payload)) |info| {
            self.log("[DOWNLOAD] progress: guid={s} state={s} {d}/{d} bytes\n", .{
                info.guid, info.state, info.received_bytes, info.total_bytes,
            });
            try self.download_manager.handleDownloadProgress(
                info.guid,
                info.state,
                info.received_bytes,
                info.total_bytes,
            );

            // Reset viewport after download completes to fix Chrome's layout
            if (std.mem.eql(u8, info.state, "completed")) {
                self.log("[DOWNLOAD] Complete - resetting viewport to fix layout\n", .{});
                screenshot_api.setViewport(self.cdp_client, self.allocator, self.viewport_width, self.viewport_height) catch |err| {
                    self.log("[DOWNLOAD] Viewport reset failed: {}\n", .{err});
                };
                // Re-query actual viewport after reset
                self.refreshChromeViewport();
            }
        }
    }

    /// Handle console messages - look for __TERMWEB_PICKER__ or __TERMWEB_FS__ markers
    fn handleConsoleMessage(self: *Viewer, payload: []const u8) !void {
        // Debug: log first 200 chars of payload
        const debug_len = @min(payload.len, 200);
        self.log("[CONSOLE MSG] payload={s}\n", .{payload[0..debug_len]});

        // Check for file system operation marker
        const fs_marker = "__TERMWEB_FS__:";
        if (std.mem.indexOf(u8, payload, fs_marker)) |fs_pos| {
            self.log("[CONSOLE MSG] Found FS marker at {d}\n", .{fs_pos});
            try self.handleFsRequest(payload, fs_pos + fs_marker.len);
            return;
        }

        // Check for picker marker
        const picker_marker = "__TERMWEB_PICKER__:";
        const marker_pos = std.mem.indexOf(u8, payload, picker_marker) orelse {
            self.log("[CONSOLE MSG] No picker marker found\n", .{});
            return;
        };
        self.log("[CONSOLE MSG] Found picker marker at {d}\n", .{marker_pos});

        // Extract picker type: file, directory, or save
        const type_start = marker_pos + picker_marker.len;
        const type_end = std.mem.indexOfPos(u8, payload, type_start, ":") orelse
            std.mem.indexOfPos(u8, payload, type_start, "\"") orelse return;
        const picker_type = payload[type_start..type_end];

        self.log("[PICKER] type={s}\n", .{picker_type});

        // Determine native picker mode
        const mode: FilePickerMode = if (std.mem.eql(u8, picker_type, "directory"))
            .folder
        else if (std.mem.eql(u8, picker_type, "file"))
            .single
        else if (std.mem.eql(u8, picker_type, "save"))
            .single // save uses single file picker
        else
            return;

        // Show native OS file picker
        const file_path = try dialog_mod.showNativeFilePicker(self.allocator, mode);
        defer if (file_path) |p| self.allocator.free(p);

        // Send result back to JavaScript
        if (file_path) |path| {
            // Remove trailing slash if present
            const trimmed_path = if (path.len > 1 and path[path.len - 1] == '/')
                path[0 .. path.len - 1]
            else
                path;

            // Extract just the name from the path
            const name = if (std.mem.lastIndexOfScalar(u8, trimmed_path, '/')) |idx|
                trimmed_path[idx + 1 ..]
            else
                trimmed_path;

            const is_dir = mode == .folder;

            // Add to allowed roots for security (only selected directories/files can be accessed)
            // Use trimmed path (without trailing slash) for consistency
            const path_copy = try self.allocator.dupe(u8, trimmed_path);
            try self.allowed_fs_roots.append(self.allocator, path_copy);
            self.log("[PICKER] Added allowed root: {s}\n", .{trimmed_path});

            // Call the JavaScript callback
            var script_buf: [4096]u8 = undefined;
            const script = std.fmt.bufPrint(&script_buf,
                "window.__termwebPickerResult(true, '{s}', '{s}', {s})",
                .{ trimmed_path, name, if (is_dir) "true" else "false" },
            ) catch return;

            try self.evalJavaScript(script);
        } else {
            // User cancelled
            try self.evalJavaScript("window.__termwebPickerResult(false)");
        }
    }

    /// Handle file system operation request
    fn handleFsRequest(self: *Viewer, payload: []const u8, start: usize) !void {
        // Format: __TERMWEB_FS__:id:type:path[:data]
        // Find the end of the console message string (look for closing quote)
        var end = start;
        while (end < payload.len and payload[end] != '"') : (end += 1) {}

        const request = payload[start..end];
        self.log("[FS] Request: {s}\n", .{request});

        // Parse id:type:path[:data]
        var iter = std.mem.splitScalar(u8, request, ':');
        const id_str = iter.next() orelse return;
        const op_type = iter.next() orelse return;
        const path = iter.next() orelse return;
        const data = iter.next(); // optional

        const id = std.fmt.parseInt(u32, id_str, 10) catch return;

        // Security check: path must be within allowed roots
        if (!self.isPathAllowed(path)) {
            self.log("[FS] Path not allowed: {s}\n", .{path});
            try self.sendFsResponse(id, false, "Path not allowed");
            return;
        }

        // Dispatch to operation handler
        if (std.mem.eql(u8, op_type, "readdir")) {
            try self.handleFsReadDir(id, path);
        } else if (std.mem.eql(u8, op_type, "readfile")) {
            try self.handleFsReadFile(id, path);
        } else if (std.mem.eql(u8, op_type, "writefile")) {
            try self.handleFsWriteFile(id, path, data orelse "");
        } else if (std.mem.eql(u8, op_type, "stat")) {
            try self.handleFsStat(id, path);
        } else if (std.mem.eql(u8, op_type, "mkdir")) {
            try self.handleFsMkDir(id, path);
        } else if (std.mem.eql(u8, op_type, "remove")) {
            try self.handleFsRemove(id, path, data);
        } else if (std.mem.eql(u8, op_type, "createfile")) {
            try self.handleFsCreateFile(id, path);
        } else {
            try self.sendFsResponse(id, false, "Unknown operation");
        }
    }

    /// Check if path is within allowed roots
    fn isPathAllowed(self: *Viewer, path: []const u8) bool {
        for (self.allowed_fs_roots.items) |root| {
            if (std.mem.startsWith(u8, path, root)) {
                // Path is within or equal to allowed root
                // Make sure it's not escaping via ..
                if (std.mem.indexOf(u8, path, "..") == null) {
                    return true;
                }
            }
        }
        return false;
    }

    /// Send file system response back to JavaScript
    fn sendFsResponse(self: *Viewer, id: u32, success: bool, data: []const u8) !void {
        var script_buf: [65536]u8 = undefined;
        const script = std.fmt.bufPrint(&script_buf,
            "window.__termwebFSResponse({d}, {s}, {s})",
            .{ id, if (success) "true" else "false", data },
        ) catch return;

        try self.evalJavaScript(script);
    }

    /// Execute JavaScript in the browser
    fn evalJavaScript(self: *Viewer, script: []const u8) !void {
        // Escape the script for JSON
        var escaped_buf: [131072]u8 = undefined;
        const escaped = escapeJsonString(script, &escaped_buf) catch return;

        var params_buf: [131072]u8 = undefined;
        const params = std.fmt.bufPrint(&params_buf, "{{\"expression\":{s}}}", .{escaped}) catch return;
        const result = self.cdp_client.sendCommand("Runtime.evaluate", params) catch |err| {
            self.log("[FS] evalJavaScript error: {}\n", .{err});
            return;
        };
        self.allocator.free(result);
    }

    /// Handle readdir operation
    fn handleFsReadDir(self: *Viewer, id: u32, path: []const u8) !void {
        var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch {
            try self.sendFsResponse(id, false, "\"Cannot open directory\"");
            return;
        };
        defer dir.close();

        // Build JSON array of entries
        var result_buf: [65536]u8 = undefined;
        var stream = std.io.fixedBufferStream(&result_buf);
        const writer = stream.writer();

        try writer.writeAll("[");
        var first = true;
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (!first) try writer.writeAll(",");
            first = false;

            const is_dir = entry.kind == .directory;
            try writer.print("{{\"name\":\"{s}\",\"isDirectory\":{s}}}", .{
                entry.name,
                if (is_dir) "true" else "false",
            });
        }
        try writer.writeAll("]");

        try self.sendFsResponse(id, true, stream.getWritten());
    }

    /// Handle readfile operation
    fn handleFsReadFile(self: *Viewer, id: u32, path: []const u8) !void {
        const file = std.fs.openFileAbsolute(path, .{}) catch {
            try self.sendFsResponse(id, false, "\"Cannot open file\"");
            return;
        };
        defer file.close();

        const stat = file.stat() catch {
            try self.sendFsResponse(id, false, "\"Cannot stat file\"");
            return;
        };

        // Read file content
        const content = file.readToEndAlloc(self.allocator, 100 * 1024 * 1024) catch {
            try self.sendFsResponse(id, false, "\"File too large or read error\"");
            return;
        };
        defer self.allocator.free(content);

        // Base64 encode
        const base64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        const base64_len = ((content.len + 2) / 3) * 4;
        const base64 = self.allocator.alloc(u8, base64_len) catch {
            try self.sendFsResponse(id, false, "\"Out of memory\"");
            return;
        };
        defer self.allocator.free(base64);

        var i: usize = 0;
        var j: usize = 0;
        while (i < content.len) {
            const b0 = content[i];
            const b1: u8 = if (i + 1 < content.len) content[i + 1] else 0;
            const b2: u8 = if (i + 2 < content.len) content[i + 2] else 0;

            base64[j] = base64_alphabet[b0 >> 2];
            base64[j + 1] = base64_alphabet[((b0 & 0x03) << 4) | (b1 >> 4)];
            base64[j + 2] = if (i + 1 < content.len) base64_alphabet[((b1 & 0x0f) << 2) | (b2 >> 6)] else '=';
            base64[j + 3] = if (i + 2 < content.len) base64_alphabet[b2 & 0x3f] else '=';

            i += 3;
            j += 4;
        }

        // Get MIME type from extension
        const ext = if (std.mem.lastIndexOfScalar(u8, path, '.')) |dot|
            path[dot..]
        else
            "";
        const mime_type = getMimeType(ext);

        // Build response
        var response_buf: [131072]u8 = undefined;
        const last_modified = @divTrunc(stat.mtime, std.time.ns_per_ms);
        const response = std.fmt.bufPrint(&response_buf,
            "{{\"content\":\"{s}\",\"size\":{d},\"type\":\"{s}\",\"lastModified\":{d}}}",
            .{ base64, stat.size, mime_type, last_modified },
        ) catch {
            try self.sendFsResponse(id, false, "\"Response too large\"");
            return;
        };

        try self.sendFsResponse(id, true, response);
    }

    /// Handle writefile operation
    fn handleFsWriteFile(self: *Viewer, id: u32, path: []const u8, base64_data: []const u8) !void {
        // Base64 decode
        const decoded_len = (base64_data.len / 4) * 3;
        const decoded = self.allocator.alloc(u8, decoded_len) catch {
            try self.sendFsResponse(id, false, "\"Out of memory\"");
            return;
        };
        defer self.allocator.free(decoded);

        var actual_len: usize = 0;
        var i: usize = 0;
        while (i + 4 <= base64_data.len) {
            const c0 = base64Decode(base64_data[i]);
            const c1 = base64Decode(base64_data[i + 1]);
            const c2 = base64Decode(base64_data[i + 2]);
            const c3 = base64Decode(base64_data[i + 3]);

            if (c0 == 255 or c1 == 255) break;

            decoded[actual_len] = (c0 << 2) | (c1 >> 4);
            actual_len += 1;

            if (c2 != 255) {
                decoded[actual_len] = ((c1 & 0x0f) << 4) | (c2 >> 2);
                actual_len += 1;
            }
            if (c3 != 255) {
                decoded[actual_len] = ((c2 & 0x03) << 6) | c3;
                actual_len += 1;
            }

            i += 4;
        }

        // Write to file
        const file = std.fs.createFileAbsolute(path, .{}) catch {
            try self.sendFsResponse(id, false, "\"Cannot create file\"");
            return;
        };
        defer file.close();

        file.writeAll(decoded[0..actual_len]) catch {
            try self.sendFsResponse(id, false, "\"Write error\"");
            return;
        };

        try self.sendFsResponse(id, true, "true");
    }

    /// Handle stat operation
    fn handleFsStat(self: *Viewer, id: u32, path: []const u8) !void {
        // Try as directory first
        if (std.fs.openDirAbsolute(path, .{})) |dir| {
            var d = dir;
            d.close();
            try self.sendFsResponse(id, true, "{\"isDirectory\":true}");
            return;
        } else |_| {}

        // Try as file
        const file = std.fs.openFileAbsolute(path, .{}) catch {
            try self.sendFsResponse(id, false, "\"Path not found\"");
            return;
        };
        defer file.close();

        const stat = file.stat() catch {
            try self.sendFsResponse(id, false, "\"Cannot stat\"");
            return;
        };

        var response_buf: [256]u8 = undefined;
        const response = std.fmt.bufPrint(&response_buf,
            "{{\"isDirectory\":false,\"size\":{d}}}",
            .{stat.size},
        ) catch return;

        try self.sendFsResponse(id, true, response);
    }

    /// Handle mkdir operation
    fn handleFsMkDir(self: *Viewer, id: u32, path: []const u8) !void {
        std.fs.makeDirAbsolute(path) catch |err| {
            if (err != error.PathAlreadyExists) {
                try self.sendFsResponse(id, false, "\"Cannot create directory\"");
                return;
            }
        };
        try self.sendFsResponse(id, true, "true");
    }

    /// Handle remove operation
    fn handleFsRemove(self: *Viewer, id: u32, path: []const u8, recursive: ?[]const u8) !void {
        const is_recursive = if (recursive) |r| std.mem.eql(u8, r, "1") else false;

        // Try as directory first
        if (is_recursive) {
            std.fs.deleteTreeAbsolute(path) catch {
                try self.sendFsResponse(id, false, "\"Cannot remove\"");
                return;
            };
        } else {
            std.fs.deleteDirAbsolute(path) catch {
                // Try as file
                std.fs.deleteFileAbsolute(path) catch {
                    try self.sendFsResponse(id, false, "\"Cannot remove\"");
                    return;
                };
            };
        }
        try self.sendFsResponse(id, true, "true");
    }

    /// Handle createfile operation
    fn handleFsCreateFile(self: *Viewer, id: u32, path: []const u8) !void {
        const file = std.fs.createFileAbsolute(path, .{ .exclusive = false }) catch {
            try self.sendFsResponse(id, false, "\"Cannot create file\"");
            return;
        };
        file.close();
        try self.sendFsResponse(id, true, "true");
    }

    /// Show JavaScript dialog (alert/confirm/prompt)
    fn showJsDialog(self: *Viewer, payload: []const u8) !void {
        self.log("[DIALOG] showJsDialog payload={s}\n", .{payload});

        // Parse dialog type from payload
        const dtype = parseDialogType(payload);
        const message = parseDialogMessage(self.allocator, payload) catch "Dialog";
        const default_text = parseDefaultPrompt(self.allocator, payload) catch "";

        // Store message for later cleanup
        if (self.dialog_message) |old_msg| {
            self.allocator.free(old_msg);
        }
        self.dialog_message = message;

        // Create dialog state
        const state = try self.allocator.create(DialogState);
        state.* = try DialogState.init(self.allocator, dtype, message, default_text);
        self.dialog_state = state;

        self.mode = .dialog;
        self.ui_dirty = true;
    }

    /// Show file chooser (native OS picker)
    fn showFileChooser(self: *Viewer, payload: []const u8) !void {
        self.log("[DIALOG] showFileChooser payload={s}\n", .{payload});

        // Parse file chooser mode
        const mode = parseFileChooserMode(payload);

        // Show native OS file picker (this blocks until user selects or cancels)
        const file_path = try dialog_mod.showNativeFilePicker(self.allocator, mode);
        defer if (file_path) |p| self.allocator.free(p);

        // Send response to Chrome
        if (file_path) |path| {
            var params_buf: [2048]u8 = undefined;
            const params = std.fmt.bufPrint(&params_buf, "{{\"action\":\"accept\",\"files\":[\"{s}\"]}}", .{path}) catch return;
            const result = self.cdp_client.sendCommand("Page.handleFileChooser", params) catch return;
            self.allocator.free(result);
        } else {
            const result = self.cdp_client.sendCommand("Page.handleFileChooser", "{\"action\":\"cancel\"}") catch return;
            self.allocator.free(result);
        }
    }

    /// Handle key press in dialog mode
    fn handleDialogMode(self: *Viewer, key: Key) !void {
        const state = self.dialog_state orelse return;

        switch (key) {
            .char => |c| {
                if (state.dialog_type == .prompt) {
                    state.handleChar(c);
                    self.ui_dirty = true;
                }
            },
            .backspace => {
                if (state.dialog_type == .prompt) {
                    state.handleBackspace();
                    self.ui_dirty = true;
                }
            },
            .left => {
                if (state.dialog_type == .prompt) {
                    state.handleLeft();
                    self.ui_dirty = true;
                }
            },
            .right => {
                if (state.dialog_type == .prompt) {
                    state.handleRight();
                    self.ui_dirty = true;
                }
            },
            .enter => {
                // Accept dialog
                try self.closeDialog(true);
            },
            .escape => {
                // Cancel dialog (for confirm/prompt only)
                const can_cancel = state.dialog_type != .alert;
                try self.closeDialog(!can_cancel);
            },
            else => {},
        }
    }

    /// Close dialog and send response to Chrome
    fn closeDialog(self: *Viewer, accepted: bool) !void {
        const state = self.dialog_state orelse return;

        // Build response JSON
        var params_buf: [1024]u8 = undefined;
        const params = if (state.dialog_type == .prompt)
            std.fmt.bufPrint(&params_buf, "{{\"accept\":{},\"promptText\":\"{s}\"}}", .{ accepted, state.getText() }) catch return
        else
            std.fmt.bufPrint(&params_buf, "{{\"accept\":{}}}", .{accepted}) catch return;

        const result = self.cdp_client.sendCommand("Page.handleJavaScriptDialog", params) catch |err| {
            self.log("[DIALOG] closeDialog error: {}\n", .{err});
            return;
        };
        self.allocator.free(result);

        // Cleanup
        var s = state;
        s.deinit();
        self.allocator.destroy(state);
        self.dialog_state = null;

        if (self.dialog_message) |msg| {
            self.allocator.free(msg);
            self.dialog_message = null;
        }

        self.mode = .normal;
        self.ui_dirty = true;

        // Force re-render the page
        self.last_frame_time = 0;
    }

    /// Render dialog overlay
    fn renderDialog(self: *Viewer, writer: anytype) !void {
        const state = self.dialog_state orelse return;
        const size = try self.terminal.getSize();
        try dialog_mod.renderDialog(writer, state, size.cols, size.rows);
    }

    pub fn deinit(self: *Viewer) void {
        if (self.prompt_buffer) |*p| p.deinit();
        if (self.form_context) |ctx| {
            ctx.deinit();
            self.allocator.destroy(ctx);
        }
        if (self.dialog_state) |state| {
            var s = state;
            s.deinit();
            self.allocator.destroy(state);
        }
        if (self.dialog_message) |msg| {
            self.allocator.free(msg);
        }
        // Free allowed file system roots
        for (self.allowed_fs_roots.items) |root| {
            self.allocator.free(root);
        }
        self.allowed_fs_roots.deinit(self.allocator);
        self.download_manager.deinit();
        if (self.debug_log) |file| {
            file.close();
        }
        if (self.shm_buffer) |*shm| {
            shm.deinit();
        }
        if (self.toolbar_renderer) |*renderer| {
            renderer.deinit();
        }
        // Free the URL we own
        self.allocator.free(self.current_url);
        self.terminal.deinit();
    }

    /// Convert mouse coordinates to pixel coordinates for toolbar hit testing.
    /// When terminal is in cell mode (not pixel mode), converts cell coordinates to pixels.
    fn mouseToPixels(self: *const Viewer) struct { x: u32, y: u32 } {
        const mapper = self.coord_mapper orelse return .{ .x = self.mouse_x, .y = self.mouse_y };

        if (mapper.is_pixel_mode) {
            // Already in pixel coordinates
            return .{ .x = self.mouse_x, .y = self.mouse_y };
        }

        // Convert cell coordinates to pixel coordinates
        const cell_width: u32 = if (mapper.terminal_cols > 0)
            mapper.terminal_width_px / mapper.terminal_cols
        else
            14;
        const cell_height: u32 = mapper.cell_height;

        // Convert cell to pixel (top-left of cell)
        const pixel_x: u32 = @as(u32, self.mouse_x) * cell_width;
        const pixel_y: u32 = @as(u32, self.mouse_y) * cell_height;

        return .{ .x = pixel_x, .y = pixel_y };
    }
};

/// Extract URL from navigation event payload
/// Page.frameNavigated: {"frame":{"id":"...","url":"https://example.com",...}}
/// Page.navigatedWithinDocument: {"frameId":"...","url":"https://example.com"}
fn extractUrlFromNavEvent(payload: []const u8) ?[]const u8 {
    // Try to find "url":" pattern
    const url_marker = "\"url\":\"";
    const url_start_idx = std.mem.indexOf(u8, payload, url_marker) orelse return null;
    const url_value_start = url_start_idx + url_marker.len;

    // Find the closing quote
    const url_end_idx = std.mem.indexOfPos(u8, payload, url_value_start, "\"") orelse return null;

    const url = payload[url_value_start..url_end_idx];

    // Skip about:blank and empty URLs
    if (url.len == 0 or std.mem.eql(u8, url, "about:blank")) return null;

    return url;
}

/// Parse dialog type from CDP event payload
fn parseDialogType(payload: []const u8) DialogType {
    // Look for "type":"alert"|"confirm"|"prompt"|"beforeunload"
    if (std.mem.indexOf(u8, payload, "\"type\":\"alert\"") != null) return .alert;
    if (std.mem.indexOf(u8, payload, "\"type\":\"confirm\"") != null) return .confirm;
    if (std.mem.indexOf(u8, payload, "\"type\":\"prompt\"") != null) return .prompt;
    if (std.mem.indexOf(u8, payload, "\"type\":\"beforeunload\"") != null) return .beforeunload;
    return .alert; // Default
}

/// Parse dialog message from CDP event payload
fn parseDialogMessage(allocator: std.mem.Allocator, payload: []const u8) ![]const u8 {
    // Look for "message":"..."
    const marker = "\"message\":\"";
    const start = std.mem.indexOf(u8, payload, marker) orelse return error.NotFound;
    const msg_start = start + marker.len;

    // Find closing quote (handle escaped quotes)
    var end = msg_start;
    while (end < payload.len) : (end += 1) {
        if (payload[end] == '"' and (end == msg_start or payload[end - 1] != '\\')) {
            break;
        }
    }

    if (end <= msg_start) return error.NotFound;

    return try allocator.dupe(u8, payload[msg_start..end]);
}

/// Parse default prompt text from CDP event payload
fn parseDefaultPrompt(allocator: std.mem.Allocator, payload: []const u8) ![]const u8 {
    // Look for "defaultPrompt":"..."
    const marker = "\"defaultPrompt\":\"";
    const start = std.mem.indexOf(u8, payload, marker) orelse return try allocator.dupe(u8, "");
    const text_start = start + marker.len;

    // Find closing quote
    var end = text_start;
    while (end < payload.len) : (end += 1) {
        if (payload[end] == '"' and (end == text_start or payload[end - 1] != '\\')) {
            break;
        }
    }

    if (end <= text_start) return try allocator.dupe(u8, "");

    return try allocator.dupe(u8, payload[text_start..end]);
}

/// Parse file chooser mode from CDP event payload
fn parseFileChooserMode(payload: []const u8) FilePickerMode {
    // Look for "mode":"selectSingle"|"selectMultiple"|"uploadFolder"
    if (std.mem.indexOf(u8, payload, "\"mode\":\"selectMultiple\"") != null) return .multiple;
    if (std.mem.indexOf(u8, payload, "\"mode\":\"uploadFolder\"") != null) return .folder;
    return .single; // Default
}

/// Get MIME type from file extension
fn getMimeType(ext: []const u8) []const u8 {
    const extensions = [_]struct { ext: []const u8, mime: []const u8 }{
        .{ .ext = ".html", .mime = "text/html" },
        .{ .ext = ".htm", .mime = "text/html" },
        .{ .ext = ".css", .mime = "text/css" },
        .{ .ext = ".js", .mime = "application/javascript" },
        .{ .ext = ".mjs", .mime = "application/javascript" },
        .{ .ext = ".json", .mime = "application/json" },
        .{ .ext = ".xml", .mime = "application/xml" },
        .{ .ext = ".txt", .mime = "text/plain" },
        .{ .ext = ".md", .mime = "text/markdown" },
        .{ .ext = ".png", .mime = "image/png" },
        .{ .ext = ".jpg", .mime = "image/jpeg" },
        .{ .ext = ".jpeg", .mime = "image/jpeg" },
        .{ .ext = ".gif", .mime = "image/gif" },
        .{ .ext = ".svg", .mime = "image/svg+xml" },
        .{ .ext = ".ico", .mime = "image/x-icon" },
        .{ .ext = ".webp", .mime = "image/webp" },
        .{ .ext = ".pdf", .mime = "application/pdf" },
        .{ .ext = ".zip", .mime = "application/zip" },
        .{ .ext = ".tar", .mime = "application/x-tar" },
        .{ .ext = ".gz", .mime = "application/gzip" },
        .{ .ext = ".wasm", .mime = "application/wasm" },
        .{ .ext = ".ts", .mime = "application/typescript" },
        .{ .ext = ".tsx", .mime = "application/typescript" },
        .{ .ext = ".jsx", .mime = "application/javascript" },
        .{ .ext = ".py", .mime = "text/x-python" },
        .{ .ext = ".rs", .mime = "text/x-rust" },
        .{ .ext = ".go", .mime = "text/x-go" },
        .{ .ext = ".zig", .mime = "text/x-zig" },
        .{ .ext = ".c", .mime = "text/x-c" },
        .{ .ext = ".cpp", .mime = "text/x-c++" },
        .{ .ext = ".h", .mime = "text/x-c" },
        .{ .ext = ".hpp", .mime = "text/x-c++" },
    };

    for (extensions) |e| {
        if (std.mem.eql(u8, ext, e.ext)) {
            return e.mime;
        }
    }
    return "application/octet-stream";
}

/// Decode a single base64 character
fn base64Decode(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c - 'A';
    if (c >= 'a' and c <= 'z') return c - 'a' + 26;
    if (c >= '0' and c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return 255; // Invalid or padding ('=')
}

/// Escape a string for JSON embedding (adds surrounding quotes)
fn escapeJsonString(input: []const u8, buf: []u8) ![]const u8 {
    var i: usize = 0;
    if (i >= buf.len) return error.OutOfMemory;
    buf[i] = '"';
    i += 1;

    for (input) |c| {
        switch (c) {
            '"' => {
                if (i + 2 > buf.len) return error.OutOfMemory;
                buf[i] = '\\';
                buf[i + 1] = '"';
                i += 2;
            },
            '\\' => {
                if (i + 2 > buf.len) return error.OutOfMemory;
                buf[i] = '\\';
                buf[i + 1] = '\\';
                i += 2;
            },
            '\n' => {
                if (i + 2 > buf.len) return error.OutOfMemory;
                buf[i] = '\\';
                buf[i + 1] = 'n';
                i += 2;
            },
            '\r' => {
                if (i + 2 > buf.len) return error.OutOfMemory;
                buf[i] = '\\';
                buf[i + 1] = 'r';
                i += 2;
            },
            '\t' => {
                if (i + 2 > buf.len) return error.OutOfMemory;
                buf[i] = '\\';
                buf[i + 1] = 't';
                i += 2;
            },
            else => {
                if (c < 0x20) {
                    // Control character - escape as \uXXXX
                    if (i + 6 > buf.len) return error.OutOfMemory;
                    buf[i] = '\\';
                    buf[i + 1] = 'u';
                    buf[i + 2] = '0';
                    buf[i + 3] = '0';
                    buf[i + 4] = hexDigit(@truncate(c >> 4));
                    buf[i + 5] = hexDigit(@truncate(c & 0xf));
                    i += 6;
                } else {
                    if (i >= buf.len) return error.OutOfMemory;
                    buf[i] = c;
                    i += 1;
                }
            },
        }
    }

    if (i >= buf.len) return error.OutOfMemory;
    buf[i] = '"';
    i += 1;

    return buf[0..i];
}

fn hexDigit(n: u4) u8 {
    const v: u8 = n;
    return if (v < 10) '0' + v else 'a' + v - 10;
}
