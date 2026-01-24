/// Main viewer module for termweb.
///
/// Implements the interactive browser session with a mode-based state machine.
/// Handles keyboard input, screenshot rendering, and user interaction modes.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig").Config;
const terminal_mod = @import("terminal/terminal.zig");
const kitty_mod = @import("terminal/kitty_graphics.zig");
const shm_mod = @import("terminal/shm.zig");
const decode_mod = @import("image/decode.zig");
const input_mod = @import("terminal/input.zig");
const screen_mod = @import("terminal/screen.zig");
const prompt_mod = @import("terminal/prompt.zig");
const coordinates_mod = @import("terminal/coordinates.zig");
const cdp = @import("chrome/cdp_client.zig");
const screenshot_api = @import("chrome/screenshot.zig");
const mouse_event_bus = @import("mouse_event_bus.zig");
const dom_mod = @import("chrome/dom.zig");
const interact_mod = @import("chrome/interact.zig");
const download_mod = @import("chrome/download.zig");
const ui_mod = @import("ui/mod.zig");
const json = @import("utils/json.zig");

// Import viewer sub-modules
const viewer_mod = @import("viewer/mod.zig");
const viewer_helpers = viewer_mod.helpers;
const fs_handler = viewer_mod.fs_handler;
const render_mod = viewer_mod.render;
const input_handler_mod = viewer_mod.input_handler;
const mouse_handler_mod = viewer_mod.mouse_handler;

// Import keyboard handling
const key_normalizer = @import("terminal/key_normalizer.zig");
const app_shortcuts = @import("app_shortcuts.zig");
const NormalizedKeyEvent = key_normalizer.NormalizedKeyEvent;
const AppAction = app_shortcuts.AppAction;

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
const UIState = ui_mod.UIState;
const Placement = ui_mod.Placement;
const ImageId = ui_mod.ImageId;
const ZIndex = ui_mod.ZIndex;
const cursor_asset = ui_mod.assets.cursor;
const FilePickerMode = ui_mod.FilePickerMode;
const dialog_mod = ui_mod.dialog;

/// Line ending for raw terminal mode (carriage return + line feed)
const CRLF = "\r\n";

// Use helper functions from viewer module
const envVarTruthy = viewer_helpers.envVarTruthy;
const isGhosttyTerminal = viewer_helpers.isGhosttyTerminal;
const isNaturalScrollEnabled = viewer_helpers.isNaturalScrollEnabled;

/// ViewerMode represents the current interaction mode of the viewer.
///
/// The viewer operates as a state machine with two modes:
/// - normal: Default browsing mode - all input goes to the browser
/// - url_prompt: URL entry mode activated by Ctrl+L
///
/// Mode transitions:
///   Normal → URL Prompt (press Ctrl+L)
///   URL Prompt → Normal (press Esc or complete action)
pub const ViewerMode = enum {
    normal,       // Main browsing mode - all input goes to browser
    url_prompt,   // Entering URL (Ctrl+L)
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
    debug_log: ?std.fs.File,
    pending_new_targets: std.ArrayList([]const u8), // Target IDs waiting for URL

    // Tab management
    tabs: std.ArrayList(ui_mod.Tab),
    active_tab_index: usize,

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
    toolbar_disabled: bool, // --no-toolbar flag

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
    last_content_image_id: ?u32, // Track content image ID for reuse

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

    // Terminal type detection (Ghostty uses cell-based mouse coords, not pixel)
    is_ghostty: bool,

    // Performance profiling
    perf_frame_count: u64,
    perf_total_render_ns: i128,
    perf_max_render_ns: i128,
    perf_last_report_time: i128,

    // Clipboard sync - periodically sync host clipboard to browser
    last_clipboard_sync: i128,
    last_clipboard_hash: u64,

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
        // Set allocator for turbojpeg fast decoding
        decode_mod.setAllocator(allocator);

        // Create debug log file only if TERMWEB_DEBUG=1
        const debug_enabled = viewer_helpers.envVarTruthy(allocator, "TERMWEB_DEBUG");
        const debug_log = if (debug_enabled)
            std.fs.cwd().createFile("termweb_debug.log", .{}) catch null
        else
            null;
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
        const shm_buffer = ShmBuffer.init(shm_size) catch null;
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
            .input = InputReader.init(std.posix.STDIN_FILENO, enable_input_debug, allocator),
            .current_url = try allocator.dupe(u8, url),
            .running = true,
            .mode = .normal,
            .prompt_buffer = null,
            .debug_log = debug_log,
            .pending_new_targets = std.ArrayList([]const u8).initCapacity(allocator, 4) catch unreachable,
            .tabs = std.ArrayList(ui_mod.Tab).initCapacity(allocator, 8) catch unreachable,
            .active_tab_index = 0,
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
            .toolbar_disabled = false,
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
            .is_ghostty = isGhosttyTerminal(allocator),
            .perf_frame_count = 0,
            .perf_total_render_ns = 0,
            .perf_max_render_ns = 0,
            .perf_last_report_time = 0,
            .last_clipboard_sync = 0,
            .last_clipboard_hash = 0,
            .allowed_fs_roots = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            .download_manager = download_mod.DownloadManager.init(allocator, "/tmp/termweb-downloads"),
        };
    }

    /// Disable toolbar (for app/kiosk mode)
    pub fn disableToolbar(self: *Viewer) void {
        self.toolbar_disabled = true;
    }

    /// Calculate max FPS based on viewport resolution
    fn getMaxFpsForResolution(self: *Viewer) u32 {
        return render_mod.getMaxFpsForResolution(self.viewport_width, self.viewport_height);
    }

    /// Get minimum frame interval in nanoseconds based on resolution
    fn getMinFrameInterval(self: *Viewer) i128 {
        return render_mod.getMinFrameInterval(self.viewport_width, self.viewport_height);
    }

    /// Add an allowed filesystem root path for FS IPC
    pub fn addAllowedPath(self: *Viewer, path: []const u8) !void {
        const path_copy = try self.allocator.dupe(u8, path);
        try self.allowed_fs_roots.append(self.allocator, path_copy);
        self.log("[FS] Added allowed root: {s}\n", .{path});
    }

    pub fn log(self: *Viewer, comptime fmt: []const u8, args: anytype) void {
        if (self.debug_log) |file| {
            var buf: [1024]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
            file.writeAll(msg) catch {};
            // Note: removed file.sync() - was causing major performance issues
        }
    }

    /// Main event loop
    pub fn run(self: *Viewer) !void {
        self.log("[DEBUG] Viewer.run() starting\n", .{});
        self.log("[DEBUG] Terminal: is_ghostty={}, natural_scroll={}\n", .{ self.is_ghostty, self.natural_scroll });

        // Initialize mouse debug log
        interact_mod.initDebugLog();

        // Inject mouse debug tracker if TERMWEB_DEBUG_MOUSE=1
        if (viewer_helpers.envVarTruthy(self.allocator, "TERMWEB_DEBUG_MOUSE")) {
            self.log("[DEBUG] Injecting mouse debug tracker\n", .{});
            interact_mod.injectMouseDebugTracker(self.cdp_client, self.allocator) catch |err| {
                self.log("[DEBUG] Failed to inject mouse debug tracker: {}\n", .{err});
            };
        }

        // Inject clipboard interceptor - syncs browser clipboard to system clipboard
        // Clipboard interceptor is now injected globally via clipboard_polyfill.js
        // in Page.addScriptToEvaluateOnNewDocument (see cdp_client.zig)

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

        // Initialize toolbar renderer with terminal pixel width (unless disabled)
        const term_size = try self.terminal.getSize();
        const cell_width = if (term_size.cols > 0) term_size.width_px / term_size.cols else 10;
        if (!self.toolbar_disabled) {
            self.toolbar_renderer = ui_mod.ToolbarRenderer.init(self.allocator, &self.kitty, term_size.width_px, cell_width) catch |err| blk: {
                self.log("[DEBUG] Toolbar init error: {}\n", .{err});
                break :blk null;
            };
            if (self.toolbar_renderer) |*renderer| {
                self.log("[DEBUG] Toolbar initialized, font_renderer={}\n", .{renderer.font_renderer != null});
                renderer.setUrl(self.current_url);
                renderer.setTabCount(1); // Initial tab
            } else {
                self.log("[DEBUG] Toolbar is null\n", .{});
            }
        } else {
            self.log("[DEBUG] Toolbar disabled (--no-toolbar)\n", .{});
        }

        // Add initial tab for current URL
        self.addTab("initial", self.current_url, "") catch |err| {
            self.log("[DEBUG] Failed to add initial tab: {}\n", .{err});
        };

        // Render initial toolbar using Kitty graphics
        try self.renderToolbar(writer);
        try writer.flush();

        // Start screencast streaming with viewport dimensions
        // Note: cli.zig already scales viewport for High-DPI displays
        const total_pixels: u64 = @as(u64, self.viewport_width) * @as(u64, self.viewport_height);
        const adaptive_quality = config.getAdaptiveQuality(total_pixels);
        self.log("[DEBUG] Starting screencast {}x{} ({}px, quality={})...\n", .{ self.viewport_width, self.viewport_height, total_pixels, adaptive_quality });

        try screenshot_api.startScreencast(self.cdp_client, self.allocator, .{
            .format = self.screencast_format,
            .quality = adaptive_quality,
            .width = self.viewport_width,
            .height = self.viewport_height,
        });
        self.screencast_mode = true;
        self.log("[DEBUG] Screencast started\n", .{});

        // Wait for first frame (3 second timeout)
        self.log("[DEBUG] Waiting for first screencast frame...\n", .{});
        var retries: u32 = 0;
        while (retries < 300) : (retries += 1) {
            if (try self.tryRenderScreencast()) {
                self.log("[DEBUG] First frame received after {} retries\n", .{retries});
                break;
            }
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        if (retries >= 300) {
            return error.ScreencastTimeout;
        }

        // Refresh Chrome's actual viewport - critical for coordinate mapping!
        // Chrome may use different dimensions than what we requested (due to DPI, scrollbars, etc.)
        self.refreshChromeViewport();
        self.log("[DEBUG] Chrome actual viewport: {}x{}\n", .{ self.chrome_actual_width, self.chrome_actual_height });

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
                    .mouse => |m| {
                        self.log("[INPUT] Mouse: type={s} x={d} y={d}\n", .{ @tagName(m.type), m.x, m.y });
                    },
                    .paste => |text| self.log("[INPUT] Paste: {d} bytes\n", .{text.len}),
                    .none => {},
                }
                try self.handleInput(input);
            }

            // Tick mouse event bus (dispatch pending events at 30fps)
            self.event_bus.maybeTick();

            // Render new screencast frames (non-blocking) - in all modes
            // Page should continue updating even when typing in address bar
            if (self.screencast_mode) {
                const new_frame = self.tryRenderScreencast() catch |err| blk: {
                    self.log("[RENDER] tryRenderScreencast error: {}\n", .{err});
                    break :blk false;
                };

                // Auto-recovery: if no frame rendered for 1+ seconds, restart screencast
                const now_ns = std.time.nanoTimestamp();
                if (self.last_frame_time > 0 and (now_ns - self.last_frame_time) > 1 * std.time.ns_per_s) {
                    self.log("[STALL] No frame for >1s, restarting screencast (frames={}, gen={})\n", .{
                        self.cdp_client.getFrameCount(), self.last_rendered_generation,
                    });
                    self.resetScreencast();
                }

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

                // Redraw UI overlays if we got a new frame or UI is dirty
                if (new_frame or self.ui_dirty) {
                    var stdout_buf2: [262144]u8 = undefined; // 256KB for toolbar graphics
                    const stdout_file2 = std.fs.File.stdout();
                    var stdout_writer2 = stdout_file2.writer(&stdout_buf2);
                    const writer2 = &stdout_writer2.interface;
                    // Only render cursor in normal mode (not when typing URL)
                    if (self.mode == .normal) {
                        self.renderCursor(writer2) catch {};
                    }
                    self.renderToolbar(writer2) catch {};
                    writer2.flush() catch {};
                    self.ui_dirty = false;
                }
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

            // Minimal sleep to yield CPU (1ms = 1000Hz max loop rate)
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }

        self.log("[DEBUG] Exited main loop (running={}), loop_count={}\n", .{self.running, loop_count});

        // Stop screencast completely (including reader thread) for shutdown
        if (self.screencast_mode) {
            self.cdp_client.stopScreencastFull() catch {};
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

        // Calculate cell dimensions
        const cell_width: u32 = if (size.cols > 0 and size.width_px > 0)
            size.width_px / size.cols
        else
            14;
        const cell_height: u32 = if (size.rows > 0 and size.height_px > 0)
            size.height_px / size.rows
        else
            20;
        const dpr: u32 = if (cell_width > 14) 2 else 1;

        // Get actual toolbar height (accounts for DPR)
        const toolbar = @import("ui/toolbar.zig");
        const toolbar_height: u32 = toolbar.getToolbarHeight(cell_width);

        // Calculate content area height aligned to cell boundaries
        // This MUST match the content_pixel_height calculation in CoordinateMapper
        const available_height: u32 = if (size.height_px > toolbar_height)
            size.height_px - toolbar_height
        else
            size.height_px;
        const content_rows: u32 = available_height / cell_height;
        const content_pixel_height: u32 = content_rows * cell_height;

        // Scale by DPR for browser viewport
        // Use content_pixel_height (cell-aligned) to ensure aspect ratio matches terminal
        var new_width: u32 = @max(MIN_WIDTH, raw_width / dpr);
        var new_height: u32 = @max(MIN_HEIGHT, content_pixel_height / dpr);

        // Cap total pixels to improve performance on large displays
        const MAX_PIXELS = config.MAX_PIXELS;
        const total_pixels: u64 = @as(u64, new_width) * @as(u64, new_height);
        if (total_pixels > MAX_PIXELS) {
            const pixel_scale = @sqrt(@as(f64, @floatFromInt(MAX_PIXELS)) / @as(f64, @floatFromInt(total_pixels)));
            new_width = @max(MIN_WIDTH, @as(u32, @intFromFloat(@as(f64, @floatFromInt(new_width)) * pixel_scale)));
            new_height = @max(MIN_HEIGHT, @as(u32, @intFromFloat(@as(f64, @floatFromInt(new_height)) * pixel_scale)));
            self.log("[RESIZE] Viewport capped to {}x{} (max {} pixels)\n", .{ new_width, new_height, MAX_PIXELS });
        }

        self.log("[RESIZE] New size: {}x{} px, {}x{} cells, toolbar={}px, dpr={} -> viewport {}x{}\n", .{
            size.width_px, size.height_px, size.cols, size.rows, toolbar_height, dpr, new_width, new_height,
        });

        // Update toolbar width to match new terminal width
        if (self.toolbar_renderer) |*renderer| {
            renderer.setWidth(raw_width);
        }

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

        // Reallocate SHM buffer if new size is larger
        const new_shm_size = new_width * new_height * 4;
        if (self.shm_buffer) |*shm| {
            if (new_shm_size > shm.size) {
                self.log("[RESIZE] Reallocating SHM buffer: {} -> {} bytes\n", .{ shm.size, new_shm_size });
                shm.deinit();
                self.shm_buffer = ShmBuffer.init(new_shm_size) catch null;
                self.last_content_image_id = null; // Reset image ID for new buffer
            }
        }

        // Clear screen and all Kitty images first (while Chrome processes stop)
        var stdout_buf: [8192]u8 = undefined;
        const stdout_file = std.fs.File.stdout();
        var stdout_writer = stdout_file.writer(&stdout_buf);
        const writer = &stdout_writer.interface;
        self.kitty.clearAll(writer) catch {};
        Screen.clear(writer) catch {};
        Screen.moveCursor(writer, 1, 1) catch {};
        writer.flush() catch {};

        // Update Chrome viewport
        screenshot_api.setViewport(self.cdp_client, self.allocator, new_width, new_height) catch |err| {
            self.log("[RESIZE] setViewport failed: {}\n", .{err});
            return;
        };

        // Small yield to let Chrome process viewport change before starting screencast
        std.Thread.sleep(20 * std.time.ns_per_ms);

        // Restart screencast with new dimensions and adaptive quality
        const resize_total_pixels: u64 = @as(u64, new_width) * @as(u64, new_height);
        const resize_quality = config.getAdaptiveQuality(resize_total_pixels);
        screenshot_api.startScreencast(self.cdp_client, self.allocator, .{
            .format = self.screencast_format,
            .quality = resize_quality,
            .width = new_width,
            .height = new_height,
        }) catch |err| {
            self.log("[RESIZE] startScreencast failed: {}\n", .{err});
            return;
        };
        self.screencast_mode = true;

        // Reset frame tracking - next frame will render immediately
        self.last_frame_time = 0;
        self.last_content_image_id = null; // Force new image ID after resize
        self.cursor_image_id = null; // Reset cursor image ID as well

        self.log("[RESIZE] Viewport updated to {}x{} (quality={})\n", .{ new_width, new_height, resize_quality });
    }

    /// Try to render latest screencast frame (non-blocking)
    /// Returns true if frame was rendered, false if no new frame
    fn tryRenderScreencast(self: *Viewer) !bool {
        return render_mod.tryRenderScreencast(self);
    }

    /// Update navigation button states from Chrome history (call after navigation events)
    pub fn updateNavigationState(self: *Viewer) void {
        const nav_state = screenshot_api.getNavigationState(self.cdp_client, self.allocator) catch return;
        self.ui_state.can_go_back = nav_state.can_go_back;
        self.ui_state.can_go_forward = nav_state.can_go_forward;
        // Refresh Chrome's actual viewport (may change after navigation/zoom)
        self.refreshChromeViewport();
    }

    /// Reset screencast - stops and restarts to recover from broken state
    /// Call this on reload to ensure clean frame state
    pub fn resetScreencast(self: *Viewer) void {
        self.log("[RESET] Resetting screencast...\n", .{});

        // Stop current screencast
        if (self.screencast_mode) {
            screenshot_api.stopScreencast(self.cdp_client, self.allocator) catch {};
            self.screencast_mode = false;
        }

        // Small yield to let Chrome process stop
        std.Thread.sleep(20 * std.time.ns_per_ms);

        // Restart screencast with adaptive quality
        const reset_total_pixels: u64 = @as(u64, self.viewport_width) * @as(u64, self.viewport_height);
        const reset_quality = config.getAdaptiveQuality(reset_total_pixels);
        screenshot_api.startScreencast(self.cdp_client, self.allocator, .{
            .format = self.screencast_format,
            .quality = reset_quality,
            .width = self.viewport_width,
            .height = self.viewport_height,
        }) catch |err| {
            self.log("[RESET] startScreencast failed: {}\n", .{err});
            return;
        };
        self.screencast_mode = true;

        // Reset frame tracking - next frame will render immediately
        self.last_frame_time = 0;
        self.last_rendered_generation = 0;
        self.frames_skipped = 0;
        // Keep image IDs - new frames overwrite using same ID (no memory leak)

        self.log("[RESET] Screencast reset complete (quality={})\n", .{reset_quality});
    }

    /// Refresh Chrome's actual viewport dimensions (source of truth for coordinate mapping)
    fn refreshChromeViewport(self: *Viewer) void {
        if (screenshot_api.getActualViewport(self.cdp_client, self.allocator)) |actual_vp| {
            self.log("[VIEWPORT] Query returned: {}x{} (current: {}x{})\n", .{
                actual_vp.width, actual_vp.height,
                self.chrome_actual_width, self.chrome_actual_height,
            });
            if (actual_vp.width > 0 and actual_vp.height > 0) {
                // Always update - Chrome's actual viewport is the source of truth
                self.chrome_actual_width = actual_vp.width;
                self.chrome_actual_height = actual_vp.height;
            }
        } else |err| {
            self.log("[VIEWPORT] Query failed: {}\n", .{err});
        }
    }

    /// Display a base64 PNG frame with specific dimensions for coordinate mapping
    fn displayFrameWithDimensions(self: *Viewer, base64_png: []const u8, frame_width: u32, frame_height: u32) !void {
        return render_mod.displayFrameWithDimensions(self, base64_png, frame_width, frame_height);
    }

    /// Display a base64 PNG frame (legacy, uses viewport dimensions)
    fn displayFrame(self: *Viewer, base64_png: []const u8) !void {
        return render_mod.displayFrame(self, base64_png);
    }

    /// Render mouse cursor at current mouse position
    fn renderCursor(self: *Viewer, writer: anytype) !void {
        return render_mod.renderCursor(self, writer);
    }

    /// Render the toolbar using Kitty graphics
    fn renderToolbar(self: *Viewer, writer: anytype) !void {
        return render_mod.renderToolbar(self, writer);
    }

    /// Handle input event - dispatches to key or mouse handlers
    fn handleInput(self: *Viewer, input: Input) !void {
        return input_handler_mod.handleInput(self, input);
    }

    /// Execute an app-level action (shortcuts intercepted by termweb)
    fn executeAppAction(self: *Viewer, action: AppAction, event: NormalizedKeyEvent) !void {
        return input_handler_mod.executeAppAction(self, action, event);
    }

    /// Handle key in normal mode - pass to browser with correct modifiers
    fn handleNormalModeKey(self: *Viewer, event: NormalizedKeyEvent) !void {
        return input_handler_mod.handleNormalModeKey(self, event);
    }

    /// Handle key in URL prompt mode - text editing
    fn handleUrlPromptKey(self: *Viewer, event: NormalizedKeyEvent) !void {
        return input_handler_mod.handleUrlPromptKey(self, event);
    }

    /// Handle mouse event - records to event bus and dispatches to mode-specific handlers
    fn handleMouse(self: *Viewer, mouse: MouseEvent) !void {
        return mouse_handler_mod.handleMouse(self, mouse);
    }

    /// Handle click on tab bar buttons
    fn handleTabBarClick(self: *Viewer, pixel_x: u32, pixel_y: u32, mapper: CoordinateMapper) !void {
        return mouse_handler_mod.handleTabBarClick(self, pixel_x, pixel_y, mapper);
    }

    /// Handle mouse event in normal mode - local UI interactions only
    fn handleMouseNormal(self: *Viewer, mouse: MouseEvent) !void {
        return mouse_handler_mod.handleMouseNormal(self, mouse);
    }

    /// Convert mouse coordinates to pixel coordinates for toolbar hit testing
    fn mouseToPixels(self: *const Viewer) struct { x: u32, y: u32 } {
        return mouse_handler_mod.mouseToPixels(self);
    }

    /// Handle CDP events (JavaScript dialogs, file chooser, console messages)
    fn handleCdpEvent(self: *Viewer, event: *cdp.CdpEvent) !void {
        self.log("[CDP EVENT] method={s}\n", .{event.method});

        if (std.mem.eql(u8, event.method, "Page.javascriptDialogOpening")) {
            // Let Chrome show native dialog in screencast - don't intercept
            self.log("[DIALOG] Native dialog opened, user can click in screencast\n", .{});
        } else if (std.mem.eql(u8, event.method, "Page.fileChooserOpened")) {
            try self.showFileChooser(event.payload);
        } else if (std.mem.eql(u8, event.method, "Runtime.consoleAPICalled")) {
            try self.handleConsoleMessage(event.payload);
        } else if (std.mem.eql(u8, event.method, "Browser.downloadWillBegin")) {
            try self.handleDownloadWillBegin(event.payload);
        } else if (std.mem.eql(u8, event.method, "Browser.downloadProgress")) {
            try self.handleDownloadProgress(event.payload);
        } else if (std.mem.eql(u8, event.method, "Page.frameNavigated")) {
            self.handleFrameNavigated(event.payload);
        } else if (std.mem.eql(u8, event.method, "Page.navigatedWithinDocument")) {
            self.handleNavigatedWithinDocument(event.payload);
        } else if (std.mem.eql(u8, event.method, "Target.targetCreated")) {
            self.handleNewTarget(event.payload);
        } else if (std.mem.eql(u8, event.method, "Target.targetInfoChanged")) {
            self.handleTargetInfoChanged(event.payload);
        }
    }

    /// Handle Page.frameNavigated - actual page load, show loading for main frame
    fn handleFrameNavigated(self: *Viewer, payload: []const u8) void {
        // Extract URL: {"frame":{"url":"https://...", "parentId":"...",...}}
        const url = extractUrlFromNavEvent(payload) orelse return;

        // Check if this is the main frame (no parentId means main document)
        // Iframes have parentId, main frame doesn't
        const is_main_frame = std.mem.indexOf(u8, payload, "\"parentId\"") == null;

        self.log("[FRAME NAV] URL: {s} (main_frame={})\n", .{ url, is_main_frame });

        // Only process main frame navigation
        if (!is_main_frame) return;

        // Set loading state for main frame navigation (show stop button)
        if (!self.ui_state.is_loading) {
            self.ui_state.is_loading = true;
            self.loading_started_at = std.time.nanoTimestamp();
            self.ui_dirty = true;
        }

        // Update current_url if different
        if (!std.mem.eql(u8, self.current_url, url)) {
            const new_url = self.allocator.dupe(u8, url) catch return;
            self.allocator.free(self.current_url);
            self.current_url = new_url;

            if (self.toolbar_renderer) |*renderer| {
                renderer.setUrl(new_url);
                self.ui_dirty = true;
            }
        }

        self.updateNavigationState();
    }

    /// Handle Page.navigatedWithinDocument - SPA navigation (pushState/hash change)
    /// Page already loaded, just URL changed - NO loading indicator
    fn handleNavigatedWithinDocument(self: *Viewer, payload: []const u8) void {
        // Extract URL: {"frameId":"...","url":"https://..."}
        const url = extractUrlFromNavEvent(payload) orelse return;

        self.log("[SPA NAV] URL: {s}\n", .{url});

        // Update current_url if different (no loading state change)
        if (!std.mem.eql(u8, self.current_url, url)) {
            const new_url = self.allocator.dupe(u8, url) catch return;
            self.allocator.free(self.current_url);
            self.current_url = new_url;

            if (self.toolbar_renderer) |*renderer| {
                renderer.setUrl(new_url);
                self.ui_dirty = true;
            }
        }

        self.updateNavigationState();
    }

    /// Handle Target.targetCreated event - launch new terminal tab instead of browser tab
    fn handleNewTarget(self: *Viewer, payload: []const u8) void {
        self.log("[NEW TARGET] Payload: {s}\n", .{payload[0..@min(payload.len, 800)]});

        // Parse targetInfo from payload
        // Format: {"targetInfo":{"targetId":"XXX","type":"page","title":"...","url":"...",...}}

        // Extract targetId
        const target_id_marker = "\"targetId\":\"";
        const target_id_start = std.mem.indexOf(u8, payload, target_id_marker) orelse return;
        const id_start = target_id_start + target_id_marker.len;
        const id_end = std.mem.indexOfPos(u8, payload, id_start, "\"") orelse return;
        const target_id = payload[id_start..id_end];

        // Extract type
        const type_marker = "\"type\":\"";
        const type_start = std.mem.indexOf(u8, payload, type_marker) orelse return;
        const t_start = type_start + type_marker.len;
        const t_end = std.mem.indexOfPos(u8, payload, t_start, "\"") orelse return;
        const target_type = payload[t_start..t_end];

        // Only handle "page" type targets (not iframes, workers, etc.)
        if (!std.mem.eql(u8, target_type, "page")) {
            self.log("[NEW TARGET] Ignoring non-page target type={s}\n", .{target_type});
            return;
        }

        // Skip targets that are already attached (that's our main page)
        if (std.mem.indexOf(u8, payload, "\"attached\":true") != null) {
            self.log("[NEW TARGET] Ignoring attached target (our page)\n", .{});
            return;
        }

        // Extract URL
        const url_marker = "\"url\":\"";
        const url_start = std.mem.indexOf(u8, payload, url_marker) orelse return;
        const u_start = url_start + url_marker.len;
        const u_end = std.mem.indexOfPos(u8, payload, u_start, "\"") orelse return;
        const url = payload[u_start..u_end];

        // Skip about:blank (empty tabs) - but track the target for later
        if (std.mem.eql(u8, url, "about:blank") or url.len == 0) {
            self.log("[NEW TARGET] Empty URL, tracking target id={s}\n", .{target_id});
            // Store target ID to handle when URL arrives via targetInfoChanged
            const id_copy = self.allocator.dupe(u8, target_id) catch return;
            self.pending_new_targets.append(self.allocator, id_copy) catch {
                self.allocator.free(id_copy);
            };
            return;
        }

        self.log("[NEW TARGET] New tab requested: id={s} url={s}\n", .{ target_id, url });

        // Add new tab to our tab list
        self.addTab(target_id, url, "") catch |err| {
            self.log("[NEW TARGET] Failed to add tab: {}\n", .{err});
        };

        // Keep the browser target alive for fast tab switching
        // (Previously we closed it immediately, forcing re-navigation on switch)
    }

    /// Add a new tab to the tabs list
    fn addTab(self: *Viewer, target_id: []const u8, url: []const u8, title: []const u8) !void {
        const tab = try ui_mod.Tab.init(self.allocator, target_id, url, title);
        try self.tabs.append(self.allocator, tab);

        // Update toolbar tab count
        if (self.toolbar_renderer) |*renderer| {
            renderer.setTabCount(@intCast(self.tabs.items.len));
        }
        self.ui_dirty = true;

        self.log("[TABS] Added tab: url={s}, total={}\n", .{ url, self.tabs.items.len });
    }

    /// Handle Target.targetInfoChanged - URL may now be available for pending targets
    /// Also updates URL for existing tabs when they navigate
    fn handleTargetInfoChanged(self: *Viewer, payload: []const u8) void {
        // Extract targetId
        const target_id_marker = "\"targetId\":\"";
        const target_id_start = std.mem.indexOf(u8, payload, target_id_marker) orelse return;
        const id_start = target_id_start + target_id_marker.len;
        const id_end = std.mem.indexOfPos(u8, payload, id_start, "\"") orelse return;
        const target_id = payload[id_start..id_end];

        // Extract URL
        const url_marker = "\"url\":\"";
        const url_start = std.mem.indexOf(u8, payload, url_marker) orelse return;
        const u_start = url_start + url_marker.len;
        const u_end = std.mem.indexOfPos(u8, payload, u_start, "\"") orelse return;
        const url = payload[u_start..u_end];

        // Skip if empty or about:blank
        if (url.len == 0 or std.mem.eql(u8, url, "about:blank")) return;

        // First, check if this target is an existing tab - update its URL
        for (self.tabs.items) |*tab| {
            if (std.mem.eql(u8, tab.target_id, target_id)) {
                if (!std.mem.eql(u8, tab.url, url)) {
                    self.log("[TARGET INFO CHANGED] Updating tab URL: {s} -> {s}\n", .{ tab.url, url });
                    tab.updateUrl(url) catch {};
                }
                return;
            }
        }

        // Check if this is a pending target (new tab waiting for URL)
        var found_index: ?usize = null;
        for (self.pending_new_targets.items, 0..) |pending_id, i| {
            if (std.mem.eql(u8, pending_id, target_id)) {
                found_index = i;
                break;
            }
        }

        if (found_index == null) return; // Not a pending target

        self.log("[TARGET INFO CHANGED] URL ready for new tab: id={s} url={s}\n", .{ target_id, url });

        // Remove from pending list
        const removed_id = self.pending_new_targets.orderedRemove(found_index.?);
        self.allocator.free(removed_id);

        // Add new tab to our tab list (keep target alive for fast switching)
        self.addTab(target_id, url, "") catch |err| {
            self.log("[TARGET INFO CHANGED] Failed to add tab: {}\n", .{err});
        };
    }

    /// Launch termweb in a new terminal window
    fn launchInNewTerminal(self: *Viewer, url: []const u8) void {
        // Get full path to current executable
        var exe_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const exe_path = std.fs.selfExePath(&exe_path_buf) catch {
            self.log("[NEW TAB] Failed to get exe path\n", .{});
            return;
        };

        // Create temp script to launch termweb
        const tmp_dir = std.posix.getenv("TMPDIR") orelse "/tmp";
        var script_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const script_path = std.fmt.bufPrint(&script_path_buf, "{s}/termweb_launch_{d}.command", .{ tmp_dir, std.time.milliTimestamp() }) catch return;

        // Get current working directory
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = std.fs.cwd().realpath(".", &cwd_buf) catch ".";

        // Write script content
        var script_buf: [2048]u8 = undefined;
        const script = std.fmt.bufPrint(&script_buf,
            \\#!/bin/bash
            \\cd "{s}"
            \\exec "{s}" open "{s}"
        , .{ cwd, exe_path, url }) catch return;

        const file = std.fs.createFileAbsolute(script_path, .{}) catch |err| {
            self.log("[NEW TAB] Failed to create script: {}\n", .{err});
            return;
        };
        defer file.close();
        file.writeAll(script) catch return;

        // Make executable
        std.fs.chdirAbsolute(tmp_dir) catch {};
        const chmod_argv = [_][]const u8{ "chmod", "+x", script_path };
        var chmod_child = std.process.Child.init(&chmod_argv, self.allocator);
        _ = chmod_child.spawnAndWait() catch {};

        // Use 'open' which launches in user's default terminal
        self.log("[NEW TAB] Launching via open: {s}\n", .{url});
        const argv = [_][]const u8{ "open", script_path };
        var child = std.process.Child.init(&argv, self.allocator);
        child.spawn() catch |err| {
            self.log("[NEW TAB] Launch failed: {}\n", .{err});
            return;
        };
        self.log("[NEW TAB] Launched: {s}\n", .{url});
    }

    /// Show native tab picker dialog
    pub fn showTabPicker(self: *Viewer) !void {
        if (self.tabs.items.len == 0) {
            self.log("[TABS] No tabs to show\n", .{});
            return;
        }

        // Build list of tab titles
        var tab_titles = try std.ArrayList([]const u8).initCapacity(self.allocator, self.tabs.items.len);
        defer tab_titles.deinit(self.allocator);

        for (self.tabs.items, 0..) |tab, i| {
            // Format as "N. Title - URL"
            var title_buf: [256]u8 = undefined;
            const title = std.fmt.bufPrint(&title_buf, "{d}. {s}", .{
                i + 1,
                if (tab.title.len > 0) tab.title else tab.url,
            }) catch continue;

            // Duplicate the title since we need it to persist
            const title_copy = try self.allocator.dupe(u8, title);
            try tab_titles.append(self.allocator, title_copy);
        }
        defer {
            for (tab_titles.items) |t| self.allocator.free(t);
        }

        self.log("[TABS] Showing picker with {} tabs\n", .{tab_titles.items.len});

        // Show native list picker
        const selected = try dialog_mod.showNativeListPicker(
            self.allocator,
            "Select Tab",
            tab_titles.items,
        );

        if (selected) |index| {
            self.log("[TABS] Selected tab {}\n", .{index});
            try self.switchToTab(index);
        }
    }

    /// Switch to a different tab
    fn switchToTab(self: *Viewer, index: usize) !void {
        if (index >= self.tabs.items.len) return;

        self.active_tab_index = index;
        const tab = self.tabs.items[index];

        self.log("[TABS] Switching to tab {}: {s} (target={s})\n", .{ index, tab.url, tab.target_id });

        // Switch to the target (attaches to existing browser target - fast!)
        self.cdp_client.switchToTarget(tab.target_id) catch |err| {
            self.log("[TABS] switchToTarget failed: {}, falling back to navigation\n", .{err});
            // Fallback to navigation if target switch fails (target may have been closed)
            _ = try screenshot_api.navigateToUrl(self.cdp_client, self.allocator, tab.url);
        };

        // Restart screencast on the new target with adaptive quality
        const tab_total_pixels: u64 = @as(u64, self.viewport_width) * @as(u64, self.viewport_height);
        const tab_quality = config.getAdaptiveQuality(tab_total_pixels);
        screenshot_api.startScreencast(self.cdp_client, self.allocator, .{
            .format = self.screencast_format,
            .quality = tab_quality,
            .width = self.viewport_width,
            .height = self.viewport_height,
        }) catch |err| {
            self.log("[TABS] startScreencast failed after switch: {}\n", .{err});
        };

        // Update URL display (blur first to ensure buffer is updated)
        if (self.toolbar_renderer) |*renderer| {
            renderer.blurUrl();
            renderer.setUrl(tab.url);
        }

        // Update current_url
        self.allocator.free(self.current_url);
        self.current_url = try self.allocator.dupe(u8, tab.url);
        // Keep image IDs - new frames overwrite using same ID (no memory leak)

        self.ui_dirty = true;
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
        // Check for clipboard marker - sync browser clipboard to system clipboard
        const clipboard_marker = "__TERMWEB_CLIPBOARD__:";
        if (std.mem.indexOf(u8, payload, clipboard_marker)) |clip_pos| {
            self.log("[CONSOLE MSG] Found clipboard marker\n", .{});
            try self.handleClipboardSync(payload, clip_pos + clipboard_marker.len);
            return;
        }

        // Check for clipboard read request - browser wants host clipboard
        const clipboard_request = "__TERMWEB_CLIPBOARD_REQUEST__";
        if (std.mem.indexOf(u8, payload, clipboard_request) != null) {
            self.log("[CONSOLE MSG] Clipboard read request - syncing from host\n", .{});
            self.handleClipboardReadRequest();
            return;
        }

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

    /// Handle clipboard sync - copy browser clipboard to system clipboard
    fn handleClipboardSync(self: *Viewer, payload: []const u8, start: usize) !void {
        // Find the end of the clipboard text (look for closing quote in JSON, handling escapes)
        var end = start;
        while (end < payload.len) : (end += 1) {
            if (payload[end] == '\\' and end + 1 < payload.len) {
                end += 1; // Skip escaped character
            } else if (payload[end] == '"') {
                break;
            }
        }

        if (end <= start) {
            self.log("[CLIPBOARD] Empty clipboard text\n", .{});
            return;
        }

        const raw_text = payload[start..end];
        self.log("[CLIPBOARD] Raw text len={d}\n", .{raw_text.len});

        // Unescape JSON string (handles \n, \t, \\, \", \uXXXX)
        const unescaped = self.unescapeJsonString(raw_text) orelse {
            // Fallback to raw text if unescape fails
            const toolbar = @import("ui/toolbar.zig");
            toolbar.copyToClipboard(self.allocator, raw_text);
            return;
        };
        defer self.allocator.free(unescaped);

        self.log("[CLIPBOARD] Unescaped len={d}\n", .{unescaped.len});

        // Copy to system clipboard via pbcopy
        const toolbar = @import("ui/toolbar.zig");
        toolbar.copyToClipboard(self.allocator, unescaped);
        self.log("[CLIPBOARD] Copied to system clipboard\n", .{});
    }

    /// Unescape a JSON string, handling \n, \t, \\, \", and \uXXXX sequences
    fn unescapeJsonString(self: *Viewer, input: []const u8) ?[]u8 {
        // Allocate max possible size (input length, since escapes are longer than output)
        var output = self.allocator.alloc(u8, input.len * 4) catch return null; // *4 for potential UTF-8 expansion
        var i: usize = 0;
        var j: usize = 0;

        while (i < input.len) {
            if (input[i] == '\\' and i + 1 < input.len) {
                switch (input[i + 1]) {
                    'n' => {
                        output[j] = '\n';
                        j += 1;
                        i += 2;
                    },
                    't' => {
                        output[j] = '\t';
                        j += 1;
                        i += 2;
                    },
                    'r' => {
                        output[j] = '\r';
                        j += 1;
                        i += 2;
                    },
                    '\\' => {
                        output[j] = '\\';
                        j += 1;
                        i += 2;
                    },
                    '"' => {
                        output[j] = '"';
                        j += 1;
                        i += 2;
                    },
                    '/' => {
                        output[j] = '/';
                        j += 1;
                        i += 2;
                    },
                    'u' => {
                        // Unicode escape: \uXXXX
                        if (i + 5 < input.len) {
                            const hex = input[i + 2 .. i + 6];
                            const codepoint = std.fmt.parseInt(u21, hex, 16) catch {
                                output[j] = input[i];
                                j += 1;
                                i += 1;
                                continue;
                            };

                            // Check for surrogate pair (emojis etc)
                            if (codepoint >= 0xD800 and codepoint <= 0xDBFF and i + 11 < input.len) {
                                if (input[i + 6] == '\\' and input[i + 7] == 'u') {
                                    const hex2 = input[i + 8 .. i + 12];
                                    const low = std.fmt.parseInt(u21, hex2, 16) catch 0;
                                    if (low >= 0xDC00 and low <= 0xDFFF) {
                                        // Combine surrogate pair
                                        const full_cp: u21 = 0x10000 + ((@as(u21, codepoint) - 0xD800) << 10) + (low - 0xDC00);
                                        const len = std.unicode.utf8Encode(full_cp, output[j..]) catch 0;
                                        j += len;
                                        i += 12;
                                        continue;
                                    }
                                }
                            }

                            // Single codepoint
                            const len = std.unicode.utf8Encode(codepoint, output[j..]) catch 0;
                            j += len;
                            i += 6;
                        } else {
                            output[j] = input[i];
                            j += 1;
                            i += 1;
                        }
                    },
                    else => {
                        output[j] = input[i];
                        j += 1;
                        i += 1;
                    },
                }
            } else {
                output[j] = input[i];
                j += 1;
                i += 1;
            }
        }

        // Shrink to actual size
        return self.allocator.realloc(output, j) catch {
            self.allocator.free(output);
            return null;
        };
    }

    /// Handle clipboard read request - browser wants host clipboard
    /// Called when browser's navigator.clipboard.readText() is invoked
    fn handleClipboardReadRequest(self: *Viewer) void {
        const toolbar = @import("ui/toolbar.zig");

        // Read from system clipboard (pbpaste on macOS, xclip on Linux)
        const clipboard_text = toolbar.pasteFromClipboard(self.allocator) orelse {
            self.log("[CLIPBOARD] No content in system clipboard\n", .{});
            // Still update browser with empty string to unblock the JS polling
            interact_mod.updateBrowserClipboard(self.cdp_client, self.allocator, "") catch {};
            return;
        };
        defer self.allocator.free(clipboard_text);

        self.log("[CLIPBOARD] Sending to browser: len={d}\n", .{clipboard_text.len});

        // Send to browser - this updates window._termwebClipboardData and increments version
        interact_mod.updateBrowserClipboard(self.cdp_client, self.allocator, clipboard_text) catch |err| {
            self.log("[CLIPBOARD] Failed to update browser: {}\n", .{err});
        };
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
        return fs_handler.isPathAllowed(self.allowed_fs_roots.items, path);
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
        // Escape the script for JSON (escapeString includes quotes)
        var escaped_buf: [131072]u8 = undefined;
        const escaped = json.escapeString(script, &escaped_buf) catch return;

        var params_buf: [131072]u8 = undefined;
        const params = std.fmt.bufPrint(&params_buf, "{{\"expression\":{s}}}", .{escaped}) catch return;
        const result = self.cdp_client.sendNavCommand("Runtime.evaluate", params) catch |err| {
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
        var escape_buf: [1024]u8 = undefined;
        while (try iter.next()) |entry| {
            if (!first) try writer.writeAll(",");
            first = false;

            const is_dir = entry.kind == .directory;
            // Escape entry name for JSON (handles quotes, backslashes in filenames)
            const escaped_name = json.escapeContents(entry.name, &escape_buf) catch continue;
            try writer.print("{{\"name\":\"{s}\",\"isDirectory\":{s}}}", .{
                escaped_name,
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
            // Escape file path for JSON (handles quotes, backslashes)
            var escape_buf: [4096]u8 = undefined;
            const escaped_path = json.escapeContents(path, &escape_buf) catch return;
            var params_buf: [8192]u8 = undefined;
            const params = std.fmt.bufPrint(&params_buf, "{{\"action\":\"accept\",\"files\":[\"{s}\"]}}", .{escaped_path}) catch return;
            const result = self.cdp_client.sendNavCommand("Page.handleFileChooser", params) catch return;
            self.allocator.free(result);
        } else {
            const result = self.cdp_client.sendNavCommand("Page.handleFileChooser", "{\"action\":\"cancel\"}") catch return;
            self.allocator.free(result);
        }
    }

    pub fn deinit(self: *Viewer) void {
        self.input.deinit();
        if (self.prompt_buffer) |*p| p.deinit();
        // Free allowed file system roots
        for (self.allowed_fs_roots.items) |root| {
            self.allocator.free(root);
        }
        self.allowed_fs_roots.deinit(self.allocator);
        // Free pending new targets
        for (self.pending_new_targets.items) |target_id| {
            self.allocator.free(target_id);
        }
        self.pending_new_targets.deinit(self.allocator);
        // Free tabs
        for (self.tabs.items) |*tab| {
            tab.deinit();
        }
        self.tabs.deinit(self.allocator);
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
};

// Use helper functions from viewer module
const extractUrlFromNavEvent = viewer_helpers.extractUrlFromNavEvent;
const parseFileChooserMode = viewer_helpers.parseFileChooserMode;
const getMimeType = viewer_helpers.getMimeType;
const base64Decode = viewer_helpers.base64Decode;
