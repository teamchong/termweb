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

/// Pre-rendered hint badge data for background thread -> main thread transfer
const HintBadge = struct {
    rgba: [70 * 24 * 4]u8, // Max badge size: 70x24 pixels, RGBA
    width: u32,
    height: u32,
    term_row: u16,
    term_col: u16,
    valid: bool,
};

const MAX_HINT_BADGES = 500;
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

/// Pending tab add - stored for deferred processing to avoid data races
/// CDP thread sets this, main loop processes it
/// Uses atomic ready flag to ensure safe cross-thread access
const PendingTabAdd = struct {
    target_id: [128]u8,
    target_id_len: u8,
    url: [2048]u8,
    url_len: u16,
    title: [256]u8,
    title_len: u8,
    auto_switch: bool,
    ready: std.atomic.Value(bool), // Set AFTER all other fields are written
};

// Use helper functions from viewer module
const envVarTruthy = viewer_helpers.envVarTruthy;
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
    hint_mode,    // Vimium-style hint navigation (Ctrl+J)
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

    viewport_width: u32,  // Viewport after MAX_PIXELS limit (what we send to Chrome)
    viewport_height: u32,
    original_viewport_width: u32,  // Viewport BEFORE MAX_PIXELS limit (for coord ratio)
    original_viewport_height: u32,
    cell_width: u16,  // Terminal cell width in pixels (for DPR detection: >14 = Retina)
    target_fps: u32,  // Target frame rate (affects screencast and mouse tick)
    chrome_inner_width: u32,  // Chrome's actual window.innerWidth (from ResizeObserver)
    chrome_inner_height: u32, // Chrome's actual window.innerHeight (from ResizeObserver)
    // Note: For coordinate mapping, use last_frame_width/height (the actual rendered frame)
    coord_mapper: ?CoordinateMapper,
    last_click: ?struct { term_x: u16, term_y: u16, browser_x: u32, browser_y: u32 },

    // Screencast streaming
    screencast_mode: bool,
    screenshot_polling_mode: bool, // Fallback when screencast doesn't work (Linux headless)
    screencast_format: screenshot_api.ScreenshotFormat,
    last_frame_time: i128,
    last_frame_width: u32,  // Current frame width from screencast
    last_frame_height: u32, // Current frame height from screencast
    baseline_frame_width: u32,  // Frame size after navigate/resize (for coord scaling)
    baseline_frame_height: u32, // Used to detect and compensate for frame changes (download bar)

    // UI state for layered rendering
    ui_state: UIState,

    // Hint mode grid (Vimium-style navigation)
    hint_grid: ?*ui_mod.HintGrid,

    // Toolbar renderer (Kitty graphics based)
    toolbar_renderer: ?ui_mod.ToolbarRenderer,
    toolbar_disabled: bool, // --no-toolbar flag
    hotkeys_disabled: bool, // --disable-hotkeys flag (legacy, use allowed_hotkeys)
    allowed_hotkeys: ?u32, // Bitmask of allowed actions when set (null = all allowed)
    key_bindings: ?*const [26]?[]const u8, // Map a-z to action strings (null = no bindings)
    keybind_callback: ?*const fn (u8, []const u8) void, // Callback when key binding fires (key, action)
    hints_disabled: bool, // --disable-hints flag
    single_tab_mode: bool, // --single-tab flag - navigate in same tab instead of opening new tabs
    pending_tab_switch: ?usize, // Deferred tab switch (processed in main loop to avoid re-entrancy)
    pending_tab_add: PendingTabAdd, // Deferred tab add (uses atomic ready flag)

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
    showing_blank_placeholder: bool, // True when showing "New Tab" placeholder (skip screencast)

    // Debug flags
    debug_input: bool,
    ui_dirty: bool, // Track if UI needs re-rendering
    needs_nav_state_update: bool, // Deferred nav state update (avoid blocking CDP thread)
    last_toolbar_render: i128, // Throttle toolbar renders (expensive)

    // Background toolbar rendering - composites to single RGBA image
    toolbar_thread: ?std.Thread,
    toolbar_rgba: []u8, // Pre-composited RGBA image
    toolbar_rgba_ready: std.atomic.Value(bool), // New image ready to display
    toolbar_render_requested: std.atomic.Value(bool), // Signal to render thread
    toolbar_thread_running: std.atomic.Value(bool), // Thread control
    toolbar_width: u32,
    toolbar_height: u32,

    // Hint overlay thread - renders badges to buffer (main loop displays)
    hint_thread: ?std.Thread,
    hint_thread_running: std.atomic.Value(bool),
    hint_render_requested: std.atomic.Value(bool), // Signal to render thread
    hint_badges_ready: std.atomic.Value(bool), // Badges ready to display
    hint_badges: []HintBadge, // Pre-rendered badge data
    hint_badge_count: std.atomic.Value(u32), // Number of valid badges
    hint_last_input_time: i128, // For timeout-based auto-selection

    // Input thread - reads stdin independently
    input_thread: ?std.Thread,
    input_thread_running: std.atomic.Value(bool),
    input_pending: std.atomic.Value(bool),
    input_buffer: [64]Input, // Ring buffer for input events
    input_write_idx: std.atomic.Value(u32),
    input_read_idx: u32,

    // CDP thread - reads websocket independently
    cdp_thread: ?std.Thread,
    cdp_thread_running: std.atomic.Value(bool),

    // Shared memory buffer for zero-copy Kitty graphics
    shm_buffer: ?ShmBuffer,

    // Scroll direction (true = natural scrolling inverts delta)
    natural_scroll: bool,

    // Terminal type detection (Ghostty uses cell-based mouse coords, not pixel)
    is_ghostty: bool,

    // Device pixel ratio (1 for standard displays, 2 for HiDPI/Retina)
    dpr: u32,

    // Adaptive quality state (latency-based tier adjustment)
    adaptive_state: viewer_mod.adaptive.AdaptiveState,

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
        original_viewport_width: u32,
        original_viewport_height: u32,
        cell_width: u16,
        target_fps: u32,
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
        // Disable SHM over SSH - remote SHM can't be read by local terminal
        const is_ssh = std.posix.getenv("SSH_CONNECTION") != null or std.posix.getenv("SSH_CLIENT") != null;
        const shm_size = viewport_width * viewport_height * 4;
        const shm_buffer = if (is_ssh) null else ShmBuffer.init(shm_size) catch null;
        // Always use JPEG for screencast - more efficient and works better over SSH
        const screencast_format: screenshot_api.ScreenshotFormat = .jpeg;

        // Frame dimensions from screencast are the source of truth for coordinate mapping
        // (initialized to viewport, updated when frames arrive)

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
            .original_viewport_width = original_viewport_width,
            .original_viewport_height = original_viewport_height,
            .cell_width = cell_width,
            .target_fps = target_fps,
            .chrome_inner_width = viewport_width, // Updated by ResizeObserver polyfill
            .chrome_inner_height = viewport_height,
            .coord_mapper = null,
            .last_click = null,
            .screencast_mode = false,
            .screenshot_polling_mode = false,
            .screencast_format = screencast_format,
            .last_frame_time = 0,
            .last_frame_width = viewport_width,
            .last_frame_height = viewport_height,
            .baseline_frame_width = 0,  // Will be set from first screencast frame
            .baseline_frame_height = 0,
            .ui_state = UIState{},
            .hint_grid = null,
            .toolbar_renderer = null,
            .toolbar_disabled = false,
            .hotkeys_disabled = false,
            .allowed_hotkeys = null,
            .key_bindings = null,
            .keybind_callback = null,
            .hints_disabled = false,
            .single_tab_mode = false,
            .pending_tab_switch = null,
            .pending_tab_add = .{
                .target_id = undefined,
                .target_id_len = 0,
                .url = undefined,
                .url_len = 0,
                .title = undefined,
                .title_len = 0,
                .auto_switch = false,
                .ready = std.atomic.Value(bool).init(false),
            },
            .mouse_x = 0,
            .mouse_y = 0,
            .mouse_visible = false,
            .mouse_buttons = 0,
            .cursor_image_id = null,
            .event_bus = mouse_event_bus.MouseEventBus.initWithFps(cdp_client, allocator, isNaturalScrollEnabled(), target_fps),
            .last_input_time = 0,
            .last_mouse_move_time = 0,
            .last_rendered_generation = 0,
            .last_content_image_id = null,
            .last_nav_state_update = 0,
            .loading_started_at = 0,
            .frames_skipped = 0,
            .showing_blank_placeholder = false,
            .debug_input = enable_input_debug,
            .ui_dirty = true,
            .needs_nav_state_update = false,
            .last_toolbar_render = 0,
            .toolbar_thread = null,
            .toolbar_rgba = try allocator.alloc(u8, 8192 * 100 * 4), // Max 8192px wide, 100px tall, RGBA (supports 8K/HiDPI)
            .toolbar_rgba_ready = std.atomic.Value(bool).init(false),
            .toolbar_render_requested = std.atomic.Value(bool).init(false),
            .toolbar_thread_running = std.atomic.Value(bool).init(false),
            .toolbar_width = 0,
            .toolbar_height = 0,
            .hint_thread = null,
            .hint_thread_running = std.atomic.Value(bool).init(false),
            .hint_render_requested = std.atomic.Value(bool).init(false),
            .hint_badges_ready = std.atomic.Value(bool).init(false),
            .hint_badges = try allocator.alloc(HintBadge, MAX_HINT_BADGES),
            .hint_badge_count = std.atomic.Value(u32).init(0),
            .hint_last_input_time = 0,
            .input_thread = null,
            .input_thread_running = std.atomic.Value(bool).init(false),
            .input_pending = std.atomic.Value(bool).init(false),
            .input_buffer = undefined,
            .input_write_idx = std.atomic.Value(u32).init(0),
            .input_read_idx = 0,
            .cdp_thread = null,
            .cdp_thread_running = std.atomic.Value(bool).init(false),
            .shm_buffer = shm_buffer,
            .natural_scroll = isNaturalScrollEnabled(),
            .is_ghostty = true, // Kitty-compatible terminal required
            .dpr = 2, // Default to HiDPI, will be updated on first resize
            .adaptive_state = .{}, // Default tier 1 (normal)
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

    /// Disable hotkeys (Ctrl+L, Ctrl+R, etc.)
    pub fn disableHotkeys(self: *Viewer) void {
        self.hotkeys_disabled = true;
    }

    /// Set allowed hotkeys (bitmask of AppAction). When set, only these actions are allowed.
    /// Pass null to allow all hotkeys (default).
    pub fn setAllowedHotkeys(self: *Viewer, mask: ?u32) void {
        self.allowed_hotkeys = mask;
    }

    /// Set key bindings (map a-z to action strings)
    pub fn setKeyBindings(self: *Viewer, bindings: ?*const [26]?[]const u8) void {
        self.key_bindings = bindings;
    }

    /// Set keybind callback (called when a key binding fires)
    pub fn setKeybindCallback(self: *Viewer, callback: ?*const fn (u8, []const u8) void) void {
        self.keybind_callback = callback;
    }

    /// Disable hint mode (Ctrl+H)
    pub fn disableHints(self: *Viewer) void {
        self.hints_disabled = true;
    }

    /// Request the viewer to quit (for external control)
    pub fn requestQuit(self: *Viewer) void {
        self.running = false;
    }

    /// Request a deferred tab switch (processed in main loop to avoid re-entrancy)
    pub fn requestTabSwitch(self: *Viewer, index: usize) void {
        self.pending_tab_switch = index;
    }

    /// Request a deferred tab add (processed in main loop to avoid data races)
    /// CDP thread calls this, main loop processes it
    /// Uses release/acquire ordering to ensure data is visible before ready flag
    pub fn requestTabAdd(self: *Viewer, target_id: []const u8, url: []const u8, title: []const u8, auto_switch: bool) void {
        // Write all data fields first
        const tid_len: u8 = @intCast(@min(target_id.len, 128));
        const url_len: u16 = @intCast(@min(url.len, 2048));
        const title_len: u8 = @intCast(@min(title.len, 256));

        @memcpy(self.pending_tab_add.target_id[0..tid_len], target_id[0..tid_len]);
        self.pending_tab_add.target_id_len = tid_len;
        @memcpy(self.pending_tab_add.url[0..url_len], url[0..url_len]);
        self.pending_tab_add.url_len = url_len;
        @memcpy(self.pending_tab_add.title[0..title_len], title[0..title_len]);
        self.pending_tab_add.title_len = title_len;
        self.pending_tab_add.auto_switch = auto_switch;

        // Release fence ensures all writes above are visible before setting ready
        self.pending_tab_add.ready.store(true, .release);
    }

    /// Enable single-tab mode (navigate in same tab instead of opening new tabs)
    pub fn enableSingleTabMode(self: *Viewer) void {
        self.single_tab_mode = true;
    }

    /// Get target FPS
    fn getTargetFps(self: *Viewer) u32 {
        return render_mod.getTargetFps(self);
    }

    /// Get minimum frame interval in nanoseconds based on target FPS
    fn getMinFrameInterval(self: *Viewer) i128 {
        return render_mod.getMinFrameInterval(self);
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

        // Skip mouse/input setup in no-input mode (stdin not a TTY)
        const no_input_mode = self.terminal.isNoInputMode();
        if (!no_input_mode) {
            self.log("[DEBUG] Enabling mouse...\n", .{});
            try self.terminal.enableMouse();
            self.input.mouse_enabled = true;
            self.log("[DEBUG] Mouse enabled, input.mouse_enabled={}\n", .{self.input.mouse_enabled});
        } else {
            self.log("[DEBUG] No-input mode: skipping mouse setup\n", .{});
        }

        self.log("[DEBUG] Hiding cursor...\n", .{});
        try Screen.hideCursor(writer);
        try writer.flush();  // Force flush after hiding cursor
        defer Screen.showCursor(writer) catch {};

        // Initialize toolbar renderer BEFORE clearing screen (to avoid flash)
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
                // Hide buttons in no-input mode (visual indicator of view-only)
                if (no_input_mode) {
                    renderer.hide_buttons = true;
                }
                self.startToolbarThread();
            } else {
                self.log("[DEBUG] Toolbar is null\n", .{});
            }
        } else {
            self.log("[DEBUG] Toolbar disabled (--no-toolbar)\n", .{});
        }

        // Add initial tab for current URL with real target_id
        const initial_target_id = self.cdp_client.getCurrentTargetId() orelse "unknown";
        self.addTab(initial_target_id, self.current_url, "") catch |err| {
            self.log("[DEBUG] Failed to add initial tab: {}\n", .{err});
        };

        // Request initial toolbar render and wait for it to be ready
        self.requestToolbarRender();
        {
            // Wait for toolbar to be ready (max 200ms)
            var wait_count: u32 = 0;
            while (wait_count < 40 and !self.toolbar_rgba_ready.load(.acquire)) : (wait_count += 1) {
                std.Thread.sleep(5 * std.time.ns_per_ms);
            }
            self.log("[DEBUG] Toolbar ready after {} waits\n", .{wait_count});
        }

        // Set black background and clear screen to prevent white flash
        // Must be done BEFORE any content is displayed
        self.log("[DEBUG] Setting black background and clearing screen...\n", .{});
        try writer.writeAll("\x1b[0m\x1b[40m\x1b[2J\x1b[H"); // Reset, black bg, clear screen, home
        try writer.flush();

        // Display toolbar first
        self.log("[DEBUG] Displaying initial toolbar...\n", .{});
        if (self.toolbar_rgba_ready.load(.acquire)) {
            self.displayToolbar(writer);
        }
        try writer.flush();

        // Start screencast streaming with viewport dimensions
        // Note: cli.zig already scales viewport for High-DPI displays
        const total_pixels: u64 = @as(u64, self.viewport_width) * @as(u64, self.viewport_height);
        const adaptive_quality = config.getAdaptiveQuality(total_pixels);
        const every_nth = config.getEveryNthFrame(self.target_fps);
        self.log("[DEBUG] Starting screencast {}x{} ({}px, quality={}, fps={}, everyNth={})...\n", .{ self.viewport_width, self.viewport_height, total_pixels, adaptive_quality, self.target_fps, every_nth });

        try screenshot_api.startScreencast(self.cdp_client, self.allocator, .{
            .format = self.screencast_format,
            .quality = adaptive_quality,
            .width = self.viewport_width,
            .height = self.viewport_height,
            .every_nth_frame = every_nth,
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

        // Get initial navigation state (after page has loaded)
        self.updateNavigationState();
        self.log("[DEBUG] Initial nav state: can_go_back={}, can_go_forward={}\\n", .{
            self.ui_state.can_go_back, self.ui_state.can_go_forward,
        });

        self.log("[DEBUG] About to enter event loop\n", .{});
        self.log("[DEBUG] self.running = {}\n", .{self.running});

        // Start worker threads
        if (!self.terminal.isNoInputMode()) {
            self.startInputThread();
        }
        self.startCdpThread();
        self.log("[DEBUG] Worker threads started\n", .{});

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

            // Timing debug
            const loop_start = std.time.nanoTimestamp();
            var time_after_input: i128 = 0;
            var time_after_bus: i128 = 0;
            var time_after_render: i128 = 0;
            var time_after_events: i128 = 0;

            // Process input from ring buffer (filled by input thread)
            var events_processed: u32 = 0;
            while (events_processed < 100) : (events_processed += 1) {
                const maybe_input = self.pollInput();
                if (maybe_input == null) break;
                const input = maybe_input.?;

                // Log significant events only
                switch (input) {
                    .key => |key| {
                        self.log("[INPUT] Key: {any}\n", .{key});
                    },
                    .mouse => |m| {
                        if (m.type == .press or m.type == .release) {
                            self.log("[INPUT] Mouse: type={s} x={d} y={d}\n", .{ @tagName(m.type), m.x, m.y });
                        }
                    },
                    .paste => |text| self.log("[INPUT] Paste: {d} bytes\n", .{text.len}),
                    .none => {},
                }
                self.handleInput(input) catch {};
            }
            time_after_input = std.time.nanoTimestamp();

            // Tick mouse event bus (dispatch pending events at 30fps)
            self.event_bus.maybeTick();
            time_after_bus = std.time.nanoTimestamp();

            // Render new screencast frames (non-blocking) - in all modes
            // Page should continue updating even when typing in address bar
            if (self.screencast_mode) {
                const t0 = std.time.nanoTimestamp();
                const new_frame = self.tryRenderScreencast() catch |err| blk: {
                    self.log("[RENDER] tryRenderScreencast error: {}\n", .{err});
                    break :blk false;
                };
                const t1 = std.time.nanoTimestamp();

                // Auto-recovery: if no frame rendered for 3+ seconds AND there was recent input
                // Don't reset for static pages with no user activity
                const now_ns = std.time.nanoTimestamp();
                const no_frame_for_3s = self.last_frame_time > 0 and (now_ns - self.last_frame_time) > 3 * std.time.ns_per_s;
                const had_recent_input = self.last_input_time > 0 and (now_ns - self.last_input_time) < 5 * std.time.ns_per_s;
                if (no_frame_for_3s and had_recent_input) {
                    self.log("[STALL] No frame for >3s after input, restarting screencast (frames={}, gen={})\n", .{
                        self.cdp_client.getFrameCount(), self.last_rendered_generation,
                    });
                    self.resetScreencast();
                }
                const t2 = std.time.nanoTimestamp();

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
                const t3 = std.time.nanoTimestamp();

                // Signal toolbar thread when UI state changes
                if (self.ui_dirty) {
                    self.requestToolbarRender();
                    self.ui_dirty = false;
                }

                // Always check for ready toolbar and cursor updates
                {
                    var stdout_buf2: [262144]u8 = undefined; // 256KB for toolbar graphics
                    const stdout_file2 = std.fs.File.stdout();
                    var stdout_writer2 = stdout_file2.writer(&stdout_buf2);
                    const writer2 = &stdout_writer2.interface;

                    // Display toolbar if ready (checks toolbar_rgba_ready flag)
                    self.displayToolbar(writer2);

                    // Only render cursor in normal mode (not when typing URL)
                    if (new_frame and self.mode == .normal) {
                        self.renderCursor(writer2) catch {};
                    }

                    // Display pre-rendered hint badges (rendered by background thread)
                    if (self.mode == .hint_mode and self.hint_badges_ready.swap(false, .acq_rel)) {
                        const toolbar_rows: u16 = if (self.toolbar_renderer != null) 2 else 0;
                        self.displayHintBadges(writer2, toolbar_rows);
                    }

                    // Check for hint timeout auto-selection (300ms)
                    if (self.mode == .hint_mode and self.hint_last_input_time > 0) {
                        const hint_timeout = 300 * std.time.ns_per_ms;
                        if (now_ns - self.hint_last_input_time > hint_timeout) {
                            if (self.hint_grid) |grid| {
                                if (grid.findExactMatch()) |hint| {
                                    self.log("[HINT] Timeout auto-select at ({}, {})\n", .{ hint.browser_x, hint.browser_y });
                                    interact_mod.clickAt(
                                        self.cdp_client,
                                        self.allocator,
                                        hint.browser_x,
                                        hint.browser_y,
                                    ) catch {};
                                    self.exitHintMode();
                                }
                            }
                            self.hint_last_input_time = 0; // Reset to prevent repeated triggers
                        }
                    }

                    writer2.flush() catch {};
                }
                const t4 = std.time.nanoTimestamp();

                // Log detailed timing for first 20 iterations
                if (loop_count <= 20) {
                    self.log("[RENDER TIMING] frame={}ms stall={}ms load={}ms ui={}ms\n", .{
                        @divFloor(t1 - t0, std.time.ns_per_ms),
                        @divFloor(t2 - t1, std.time.ns_per_ms),
                        @divFloor(t3 - t2, std.time.ns_per_ms),
                        @divFloor(t4 - t3, std.time.ns_per_ms),
                    });
                }
            }
            time_after_render = std.time.nanoTimestamp();

            // CDP events handled by CDP thread
            time_after_events = std.time.nanoTimestamp();

            // Process pending tab add (deferred from CDP thread to avoid data races)
            // Acquire fence ensures we see all writes made before the ready flag was set
            if (self.pending_tab_add.ready.load(.acquire)) {
                // Clear ready flag first to allow new requests
                self.pending_tab_add.ready.store(false, .release);

                const tid = self.pending_tab_add.target_id[0..self.pending_tab_add.target_id_len];
                const url = self.pending_tab_add.url[0..self.pending_tab_add.url_len];
                const title = self.pending_tab_add.title[0..self.pending_tab_add.title_len];
                const auto_switch = self.pending_tab_add.auto_switch;

                self.log("[TABS] Processing deferred tab add: url={s}\n", .{url});
                self.addTab(tid, url, title) catch |err| {
                    self.log("[TABS] Deferred addTab failed: {}\n", .{err});
                };
                if (auto_switch) {
                    self.pending_tab_switch = self.tabs.items.len - 1;
                }
            }

            // Process pending tab switch (deferred from event handlers to avoid re-entrancy)
            if (self.pending_tab_switch) |tab_index| {
                self.pending_tab_switch = null;
                self.log("[TABS] Processing deferred tab switch to index {}\n", .{tab_index});
                viewer_mod.switchToTab(self, tab_index) catch |err| {
                    self.log("[TABS] Deferred switchToTab failed: {}\n", .{err});
                };
            }

            // Process deferred nav state update (moved from CDP thread to avoid blocking)
            if (self.needs_nav_state_update) {
                self.needs_nav_state_update = false;
                self.forceUpdateNavigationState();
                // Note: viewport is updated by ResizeObserver polyfill
            }

            // Flush pending ACK (no-op, kept for API compatibility)
            self.cdp_client.flushPendingAck();

            // Yield CPU (1ms = 1000Hz max loop rate)
            std.Thread.sleep(1 * std.time.ns_per_ms);

            // Log loop timing for first 20 iterations
            if (loop_count <= 20) {
                const loop_elapsed = std.time.nanoTimestamp() - loop_start;
                const input_ms = @divFloor(time_after_input - loop_start, std.time.ns_per_ms);
                const bus_ms = @divFloor(time_after_bus - time_after_input, std.time.ns_per_ms);
                const render_ms = @divFloor(time_after_render - time_after_bus, std.time.ns_per_ms);
                const events_ms = @divFloor(time_after_events - time_after_render, std.time.ns_per_ms);
                self.log("[LOOP] iter={} total={}ms (input={}ms bus={}ms render={}ms events={}ms)\n", .{
                    loop_count,
                    @divFloor(loop_elapsed, std.time.ns_per_ms),
                    input_ms,
                    bus_ms,
                    render_ms,
                    events_ms,
                });
            }
        }

        self.log("[DEBUG] Exited main loop (running={}), loop_count={}\n", .{self.running, loop_count});

        // Stop screencast completely (including reader thread) for shutdown
        self.log("[DEBUG] Stopping screencast...\n", .{});
        if (self.screencast_mode) {
            self.cdp_client.stopScreencastFull() catch {};
            self.screencast_mode = false;
        }
        self.log("[DEBUG] Screencast stopped\n", .{});

        // Cleanup - clear images, reset screen, show cursor
        self.log("[DEBUG] Clearing screen...\n", .{});
        self.kitty.clearAll(writer) catch {};
        writer.writeAll("\x1b[0m") catch {}; // Reset all attributes BEFORE clear
        Screen.clear(writer) catch {};
        Screen.showCursor(writer) catch {};
        Screen.moveCursor(writer, 1, 1) catch {};
        writer.flush() catch {};
        self.log("[DEBUG] Cleanup complete\n", .{});
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
        self.dpr = dpr; // Store for use in other functions

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

        // Original viewport (before limits) - for coordinate ratio calculation
        const original_width: u32 = @max(MIN_WIDTH, raw_width / dpr);
        const original_height: u32 = @max(MIN_HEIGHT, content_pixel_height / dpr);

        // Scale by DPR for browser viewport
        var new_width: u32 = original_width;
        var new_height: u32 = original_height;

        // Cap total pixels to improve performance on large displays
        const MAX_PIXELS = config.MAX_PIXELS;
        const total_pixels: u64 = @as(u64, new_width) * @as(u64, new_height);
        if (total_pixels > MAX_PIXELS) {
            const pixel_scale = @sqrt(@as(f64, @floatFromInt(MAX_PIXELS)) / @as(f64, @floatFromInt(total_pixels)));
            new_width = @max(MIN_WIDTH, @as(u32, @intFromFloat(@as(f64, @floatFromInt(new_width)) * pixel_scale)));
            new_height = @max(MIN_HEIGHT, @as(u32, @intFromFloat(@as(f64, @floatFromInt(new_height)) * pixel_scale)));
            self.log("[RESIZE] Viewport capped to {}x{} (max {} pixels)\n", .{ new_width, new_height, MAX_PIXELS });
        }

        // Update original viewport (for coordinate ratio)
        self.original_viewport_width = original_width;
        self.original_viewport_height = original_height;

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

        // Update Chrome viewport with matching DPR
        screenshot_api.setViewport(self.cdp_client, self.allocator, new_width, new_height, dpr) catch |err| {
            self.log("[RESIZE] setViewport failed: {}\n", .{err});
            return;
        };

        // Small yield to let Chrome process viewport change before starting screencast
        std.Thread.sleep(20 * std.time.ns_per_ms);

        // Update viewport to new size - ResizeObserver will confirm
        self.chrome_inner_width = new_width;
        self.chrome_inner_height = new_height;

        // Restart screencast with new dimensions and adaptive quality
        const resize_total_pixels: u64 = @as(u64, new_width) * @as(u64, new_height);
        const resize_quality = config.getAdaptiveQuality(resize_total_pixels);
        const resize_every_nth = config.getEveryNthFrame(self.target_fps);
        screenshot_api.startScreencast(self.cdp_client, self.allocator, .{
            .format = self.screencast_format,
            .quality = resize_quality,
            .width = new_width,
            .height = new_height,
            .every_nth_frame = resize_every_nth,
        }) catch |err| {
            self.log("[RESIZE] startScreencast failed: {}\n", .{err});
            return;
        };
        self.screencast_mode = true;

        // Reset frame tracking - next frame will render immediately
        self.last_frame_time = 0;
        self.last_content_image_id = null; // Force new image ID after resize
        self.cursor_image_id = null; // Reset cursor image ID as well

        // Reset baseline - first frame after resize will set it
        self.baseline_frame_width = 0;
        self.baseline_frame_height = 0;

        self.log("[RESIZE] Viewport updated to {}x{} (quality={})\n", .{ new_width, new_height, resize_quality });
    }

    /// Try to render latest screencast frame (non-blocking)
    /// Returns true if frame was rendered, false if no new frame
    fn tryRenderScreencast(self: *Viewer) !bool {
        return render_mod.tryRenderScreencast(self);
    }

    /// Update navigation button states from Chrome history (call after navigation events)
    /// Update navigation state (back/forward button availability)
    /// Debounced to max once per 3 seconds unless force=true
    pub fn updateNavigationState(self: *Viewer) void {
        self.updateNavigationStateImpl(false);
    }

    /// Force update navigation state, bypassing debounce
    /// Use this after actual navigation events (page load, link click)
    pub fn forceUpdateNavigationState(self: *Viewer) void {
        self.updateNavigationStateImpl(true);
    }

    fn updateNavigationStateImpl(self: *Viewer, force: bool) void {
        const now = std.time.nanoTimestamp();
        // Debounce: skip if called within last 3 seconds (unless forced)
        if (!force and now - self.last_nav_state_update < 3 * std.time.ns_per_s) {
            return;
        }
        self.last_nav_state_update = now;

        self.log("[NAV STATE] Fetching navigation state (blocking CDP call)...\n", .{});
        const nav_state = screenshot_api.getNavigationState(self.cdp_client, self.allocator) catch return;
        self.ui_state.can_go_back = nav_state.can_go_back;
        self.ui_state.can_go_forward = nav_state.can_go_forward;
        self.log("[NAV STATE] Updated: back={} forward={}\n", .{ nav_state.can_go_back, nav_state.can_go_forward });

        // Request toolbar re-render with new state
        self.requestToolbarRender();
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
        const reset_every_nth = config.getEveryNthFrame(self.target_fps);
        screenshot_api.startScreencast(self.cdp_client, self.allocator, .{
            .format = self.screencast_format,
            .quality = reset_quality,
            .width = self.viewport_width,
            .height = self.viewport_height,
            .every_nth_frame = reset_every_nth,
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

    /// Display a base64 PNG frame using stored dimensions (single source of truth)
    fn displayFrameWithDimensions(self: *Viewer, base64_png: []const u8) !void {
        return render_mod.displayFrameWithDimensions(self, base64_png);
    }

    /// Display a base64 PNG frame (legacy wrapper)
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

    /// Start the background toolbar render thread
    fn startToolbarThread(self: *Viewer) void {
        if (self.toolbar_thread != null) return;
        self.toolbar_thread_running.store(true, .release);
        self.toolbar_thread = std.Thread.spawn(.{}, toolbarRenderLoop, .{self}) catch null;
    }

    /// Stop the background toolbar render thread
    fn stopToolbarThread(self: *Viewer) void {
        self.toolbar_thread_running.store(false, .release);
        if (self.toolbar_thread) |thread| {
            thread.join();
            self.toolbar_thread = null;
        }
    }

    /// Background thread that composites toolbar (main loop displays)
    fn toolbarRenderLoop(self: *Viewer) void {
        while (self.toolbar_thread_running.load(.acquire)) {
            // Check if re-render requested
            if (self.toolbar_render_requested.swap(false, .acq_rel)) {
                // Wait if previous buffer not yet consumed (prevents tearing)
                var wait_tries: u32 = 0;
                while (self.toolbar_rgba_ready.load(.acquire) and wait_tries < 10) : (wait_tries += 1) {
                    std.Thread.sleep(2 * std.time.ns_per_ms);
                }
                if (self.toolbar_renderer) |*renderer| {
                    // Update nav state before compositing
                    renderer.setNavState(self.ui_state.can_go_back, self.ui_state.can_go_forward, self.ui_state.is_loading);
                    // Composite to RGBA buffer (main loop will display)
                    const dims = renderer.compositeToRgba(self.toolbar_rgba);
                    self.toolbar_width = dims.width;
                    self.toolbar_height = dims.height;
                    if (dims.width > 0 and dims.height > 0) {
                        self.toolbar_rgba_ready.store(true, .release);
                    }
                }
            }
            std.Thread.sleep(8 * std.time.ns_per_ms);
        }
    }

    /// Request toolbar re-render (non-blocking)
    fn requestToolbarRender(self: *Viewer) void {
        self.toolbar_render_requested.store(true, .release);
    }

    /// Start hint background render thread
    fn startHintThread(self: *Viewer) void {
        if (self.hint_thread != null) return;
        self.hint_thread_running.store(true, .release);
        self.hint_thread = std.Thread.spawn(.{}, hintRenderLoop, .{self}) catch null;
    }

    /// Stop hint background render thread
    fn stopHintThread(self: *Viewer) void {
        self.hint_thread_running.store(false, .release);
        if (self.hint_thread) |thread| {
            thread.join();
            self.hint_thread = null;
        }
    }

    /// Request hint badges to be re-rendered (non-blocking)
    pub fn requestHintRender(self: *Viewer) void {
        self.hint_render_requested.store(true, .release);
    }

    /// Background thread that pre-renders hint badges (main loop displays)
    fn hintRenderLoop(self: *Viewer) void {
        while (self.hint_thread_running.load(.acquire)) {
            // Check if re-render requested
            if (self.hint_render_requested.swap(false, .acq_rel)) {
                if (self.hint_grid) |grid| {
                    const filter = grid.getInput();
                    var badge_idx: u32 = 0;

                    for (grid.hints) |hint| {
                        if (badge_idx >= MAX_HINT_BADGES) break;

                        // Skip hints that don't match filter
                        if (filter.len > 0) {
                            var matches = true;
                            for (filter, 0..) |fc, i| {
                                if (i >= hint.label_len or hint.label[i] != fc) {
                                    matches = false;
                                    break;
                                }
                            }
                            if (!matches) continue;
                        }

                        // Calculate badge dimensions based on terminal DPR
                        // cell_width > 14 = Retina/HiDPI = 2x scale
                        const use_2x = self.cell_width > 14;
                        const char_w: u32 = if (use_2x) 16 else 8;
                        const badge_padding: u32 = if (use_2x) 6 else 4;
                        const badge_w: u32 = @as(u32, hint.label_len) * char_w + badge_padding;
                        const badge_h: u32 = if (use_2x) 24 else 12;
                        const badge_size = badge_w * badge_h * 4;
                        const render_scale: u8 = if (use_2x) 2 else 1;

                        // Render badge to pre-allocated buffer
                        var badge = &self.hint_badges[badge_idx];
                        @memset(&badge.rgba, 0);
                        ui_mod.hints.drawBadgeScaled(&badge.rgba, badge_w, badge_h, &hint.label, hint.label_len, render_scale);

                        badge.width = badge_w;
                        badge.height = badge_h;
                        badge.term_row = hint.term_row;
                        badge.term_col = hint.term_col;
                        badge.valid = true;
                        _ = badge_size;

                        badge_idx += 1;
                    }

                    // Mark remaining badges as invalid
                    var i = badge_idx;
                    while (i < MAX_HINT_BADGES) : (i += 1) {
                        self.hint_badges[i].valid = false;
                    }

                    self.hint_badge_count.store(badge_idx, .release);
                    self.hint_badges_ready.store(true, .release);
                }
            }
            std.Thread.sleep(8 * std.time.ns_per_ms);
        }
    }

    /// Display pre-rendered hint badges (main thread only)
    fn displayHintBadges(self: *Viewer, writer: anytype, toolbar_rows: u16) void {
        const badge_count = self.hint_badge_count.load(.acquire);
        var displayed: u32 = 0;

        for (self.hint_badges[0..badge_count]) |badge| {
            if (!badge.valid) continue;
            if (badge.term_row <= toolbar_rows) continue;

            // Position cursor
            writer.print("\x1b[{d};{d}H", .{ badge.term_row, badge.term_col }) catch continue;

            // Display via Kitty graphics
            const badge_size = badge.width * badge.height * 4;
            const image_id: u32 = 501 + displayed;
            _ = self.kitty.displayRawRGBA(
                writer,
                badge.rgba[0..badge_size],
                badge.width,
                badge.height,
                .{ .image_id = image_id, .z = 100 },
            ) catch {};

            displayed += 1;
        }
    }

    /// Render hint badges using KittyGraphics (DEPRECATED - use displayHintBadges)
    fn renderHintBadges(self: *Viewer, writer: anytype, grid: *ui_mod.HintGrid, size: anytype, cell_w: u16, cell_h: u16, toolbar_rows: u16) !void {
        _ = size;
        _ = cell_w;
        _ = cell_h;
        _ = grid;
        // Now just calls displayHintBadges
        self.displayHintBadges(writer, toolbar_rows);
    }

    /// Display toolbar if ready (called from main loop only)
    /// Throttled to 30fps max to avoid flooding stdout
    fn displayToolbar(self: *Viewer, writer: anytype) void {
        // Check if ready without consuming the flag yet
        if (!self.toolbar_rgba_ready.load(.acquire)) return;
        if (self.toolbar_width == 0 or self.toolbar_height == 0) return;

        // Throttle to 30fps (33ms between displays)
        const now = std.time.nanoTimestamp();
        const min_interval = 33 * std.time.ns_per_ms;
        if (now - self.last_toolbar_render < min_interval) return;

        // Now consume the flag and display
        _ = self.toolbar_rgba_ready.swap(false, .acq_rel);
        self.last_toolbar_render = now;

        const size = self.toolbar_width * self.toolbar_height * 4;
        writer.writeAll("\x1b[1;1H") catch return;

        const cell_width = if (self.toolbar_renderer) |r| r.cell_width else 10;
        const num_cols: u32 = if (cell_width > 0) self.toolbar_width / cell_width else 80;

        _ = self.kitty.displayRawRGBA(
            writer,
            self.toolbar_rgba[0..size],
            self.toolbar_width,
            self.toolbar_height,
            .{ .image_id = 200, .placement_id = 100, .z = 50, .columns = num_cols },
        ) catch {};
    }

    // ========== INPUT THREAD ==========

    fn startInputThread(self: *Viewer) void {
        if (self.input_thread != null) return;
        self.input_thread_running.store(true, .release);
        self.input_thread = std.Thread.spawn(.{}, inputLoop, .{self}) catch null;
    }

    fn stopInputThread(self: *Viewer) void {
        self.input_thread_running.store(false, .release);
        if (self.input_thread) |thread| {
            thread.join();
            self.input_thread = null;
        }
    }

    /// Input thread - reads stdin independently, buffers events for main loop
    fn inputLoop(self: *Viewer) void {
        _ = self.log("[INPUT THREAD] Started\n", .{});
        while (self.input_thread_running.load(.acquire)) {
            // Read input (non-blocking poll inside readInput)
            const input = self.input.readInput() catch {
                std.Thread.sleep(1 * std.time.ns_per_ms);
                continue;
            };

            if (input != .none) {
                // Write to ring buffer
                const write_idx = self.input_write_idx.load(.acquire);
                const next_idx = (write_idx + 1) % 64;
                self.input_buffer[write_idx] = input;
                self.input_write_idx.store(next_idx, .release);
                self.input_pending.store(true, .release);
            } else {
                // No input, yield CPU
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
        }
    }

    /// Poll input from ring buffer (called by main loop)
    fn pollInput(self: *Viewer) ?Input {
        const write_idx = self.input_write_idx.load(.acquire);
        if (self.input_read_idx == write_idx) {
            return null; // Buffer empty
        }
        const input = self.input_buffer[self.input_read_idx];
        self.input_read_idx = (self.input_read_idx + 1) % 64;
        return input;
    }

    // ========== CDP THREAD ==========

    fn startCdpThread(self: *Viewer) void {
        if (self.cdp_thread != null) return;
        self.cdp_thread_running.store(true, .release);
        self.cdp_thread = std.Thread.spawn(.{}, cdpLoop, .{self}) catch null;
    }

    fn stopCdpThread(self: *Viewer) void {
        self.cdp_thread_running.store(false, .release);
        if (self.cdp_thread) |thread| {
            thread.join();
            self.cdp_thread = null;
        }
    }

    /// CDP thread - reads websocket events independently
    fn cdpLoop(self: *Viewer) void {
        const cdp_events_mod = @import("viewer/cdp_events.zig");
        while (self.cdp_thread_running.load(.acquire)) {
            // Poll for CDP events
            if (self.cdp_client.nextEvent(self.allocator)) |maybe_event| {
                if (maybe_event) |*event| {
                    var evt = event.*;
                    defer evt.deinit();
                    cdp_events_mod.handleCdpEvent(self, &evt) catch {};
                }
            } else |_| {}
            std.Thread.sleep(2 * std.time.ns_per_ms);
        }
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

    // ========== TABS ==========

    /// Add a new tab to the tabs list
    pub fn addTab(self: *Viewer, target_id: []const u8, url: []const u8, title: []const u8) !void {
        const tabs_mod = @import("viewer/tabs.zig");
        return tabs_mod.addTab(self, target_id, url, title);
    }

    /// Show native tab picker dialog
    pub fn showTabPicker(self: *Viewer) !void {
        const tabs_mod = @import("viewer/tabs.zig");
        return tabs_mod.showTabPicker(self);
    }

    // ========== HINT MODE ==========

    /// Query clickable elements from the DOM
    fn queryClickableElements(self: *Viewer) ![]ui_mod.ClickableElement {
        // JavaScript to find all clickable elements and get their bounding boxes
        const script =
            \\(function() {
            \\  const clickable = document.querySelectorAll('a, button, input, select, textarea, [onclick], [role="button"], [role="link"], [role="option"], [role="listitem"], [role="menuitem"], [role="menuitemcheckbox"], [role="menuitemradio"], [role="tab"], [role="treeitem"], li[data-ved], [data-ved], [tabindex]:not([tabindex="-1"])');
            \\  const results = [];
            \\  const seen = new Set();
            \\  for (const el of clickable) {
            \\    const rect = el.getBoundingClientRect();
            \\    if (rect.width > 0 && rect.height > 0 && rect.top >= 0 && rect.left >= 0) {
            \\      const key = Math.round(rect.left) + ',' + Math.round(rect.top);
            \\      if (!seen.has(key)) {
            \\        seen.add(key);
            \\        results.push({
            \\          x: Math.round(rect.left + rect.width / 2),
            \\          y: Math.round(rect.top + rect.height / 2),
            \\          w: Math.round(rect.width),
            \\          h: Math.round(rect.height)
            \\        });
            \\      }
            \\    }
            \\  }
            \\  return JSON.stringify(results);
            \\})()
        ;

        // Execute script via CDP
        var escaped_buf: [4096]u8 = undefined;
        const escaped = json.escapeString(script, &escaped_buf) catch return error.EscapeFailed;
        var params_buf: [4096]u8 = undefined;
        const params = std.fmt.bufPrint(&params_buf, "{{\"expression\":{s},\"returnByValue\":true}}", .{escaped}) catch return error.FormatFailed;

        const result = self.cdp_client.sendNavCommand("Runtime.evaluate", params) catch return error.CdpFailed;
        defer self.allocator.free(result);

        // Parse response to get the JSON string result
        // Look for "value":" pattern and extract the JSON array
        const value_marker = "\"value\":\"";
        const value_start = std.mem.indexOf(u8, result, value_marker) orelse return error.NoResult;
        const json_start = value_start + value_marker.len;

        // Find closing quote (handling escapes)
        var json_end = json_start;
        while (json_end < result.len) : (json_end += 1) {
            if (result[json_end] == '\\' and json_end + 1 < result.len) {
                json_end += 1; // Skip escaped char
            } else if (result[json_end] == '"') {
                break;
            }
        }

        // Unescape the JSON string
        const escaped_json = result[json_start..json_end];
        const unescaped = self.unescapeJsonString(escaped_json) orelse return error.UnescapeFailed;
        defer self.allocator.free(unescaped);

        // Parse the JSON array
        var elements = try std.ArrayList(ui_mod.ClickableElement).initCapacity(self.allocator, 64);
        errdefer elements.deinit(self.allocator);

        // Simple JSON array parsing: [{"x":1,"y":2,"w":3,"h":4},...]
        var i: usize = 0;
        while (i < unescaped.len) {
            // Find next object
            const obj_start = std.mem.indexOfPos(u8, unescaped, i, "{") orelse break;
            const obj_end = std.mem.indexOfPos(u8, unescaped, obj_start, "}") orelse break;
            const obj = unescaped[obj_start .. obj_end + 1];

            // Parse x, y, w, h
            const x = parseJsonNumber(obj, "\"x\":") orelse 0;
            const y = parseJsonNumber(obj, "\"y\":") orelse 0;
            const w = parseJsonNumber(obj, "\"w\":") orelse 0;
            const h = parseJsonNumber(obj, "\"h\":") orelse 0;

            if (w > 0 and h > 0) {
                try elements.append(self.allocator, .{ .x = x, .y = y, .width = w, .height = h });
            }

            i = obj_end + 1;
        }

        self.log("[HINT] Found {} clickable elements\n", .{elements.items.len});
        return try elements.toOwnedSlice(self.allocator);
    }

    /// Enter hint mode (Vimium-style navigation)
    pub fn enterHintMode(self: *Viewer) !void {
        if (self.mode == .hint_mode) return;

        // Query clickable elements from DOM
        const elements = self.queryClickableElements() catch |err| {
            self.log("[HINT] Failed to query clickable elements: {}\n", .{err});
            return err;
        };
        defer self.allocator.free(elements);

        if (elements.len == 0) {
            self.log("[HINT] No clickable elements found\n", .{});
            return;
        }

        const size = try self.terminal.getSize();
        const cell_width: u16 = if (size.cols > 0) @intCast(size.width_px / size.cols) else 10;
        const cell_height: u16 = if (size.rows > 0) @intCast(size.height_px / size.rows) else 20;
        const toolbar_rows: u16 = if (self.toolbar_renderer != null) 2 else 0;
        const content_start = toolbar_rows;
        const content_rows = size.rows - toolbar_rows - 1;

        const grid = try self.allocator.create(ui_mod.HintGrid);
        // Use stored frame dimensions (single source of truth) for hint positioning
        // Element coords from DOM are in frame space (what Chrome is actually rendering)
        grid.* = try ui_mod.HintGrid.generateFromElements(
            self.allocator,
            elements,
            content_start,
            size.cols,
            content_rows,
            cell_width,
            cell_height,
            self.last_frame_width,
            self.last_frame_height,
        );

        self.hint_grid = grid;
        self.mode = .hint_mode;
        self.ui_dirty = true;
        self.startHintThread();
        self.requestHintRender(); // Trigger initial render via background thread
        self.log("[HINT] Entered hint mode with {} hints\n", .{grid.hints.len});
    }

    /// Exit hint mode
    pub fn exitHintMode(self: *Viewer) void {
        // Stop hint thread first
        self.stopHintThread();

        // Get hint count before clearing grid
        const hint_count: u32 = if (self.hint_grid) |grid| @intCast(grid.hints.len) else 0;

        if (self.hint_grid) |grid| {
            grid.deinit();
            self.allocator.destroy(grid);
            self.hint_grid = null;
        }
        self.mode = .normal;
        self.ui_dirty = true;

        // Clear all hint images by deleting each one individually
        // Hint images use IDs 501 to 501 + hint_count
        var stdout_buf: [65536]u8 = undefined;
        var stream = std.io.fixedBufferStream(&stdout_buf);
        const writer = stream.writer();

        // Delete all hint images (501 onwards, up to actual hint count + buffer)
        const max_id: u32 = 501 + hint_count + 100; // Extra buffer for safety
        var i: u32 = 501;
        while (i < max_id) : (i += 1) {
            writer.print("\x1b_Ga=d,d=i,i={d}\x1b\\", .{i}) catch break;
        }

        // Write all delete commands at once
        const stdout_file = std.fs.File.stdout();
        stdout_file.writeAll(stream.getWritten()) catch {};

        self.log("[HINT] Exited hint mode, cleared {} hint images\n", .{hint_count});
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
                screenshot_api.setViewport(self.cdp_client, self.allocator, self.viewport_width, self.viewport_height, self.dpr) catch |err| {
                    self.log("[DOWNLOAD] Viewport reset failed: {}\n", .{err});
                };
                // Frame dimensions from screencast will update automatically
            }
        }
    }

    /// Handle picker request from File System Access API polyfill
    pub fn handlePickerRequest(self: *Viewer, payload: []const u8, start: usize) !void {
        // Extract picker type: file, directory, or save
        const type_end = std.mem.indexOfPos(u8, payload, start, ":") orelse
            std.mem.indexOfPos(u8, payload, start, "\"") orelse return;
        const picker_type = payload[start..type_end];

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
            const path_copy = try self.allocator.dupe(u8, trimmed_path);
            try self.allowed_fs_roots.append(self.allocator, path_copy);
            self.log("[PICKER] Added allowed root: {s}\n", .{trimmed_path});

            // Call the JavaScript callback (escape single quotes in path/name)
            var escaped_path_buf: [2048]u8 = undefined;
            var escaped_name_buf: [512]u8 = undefined;
            const escaped_path = escapeSingleQuotes(trimmed_path, &escaped_path_buf);
            const escaped_name = escapeSingleQuotes(name, &escaped_name_buf);

            var script_buf: [4096]u8 = undefined;
            const script = std.fmt.bufPrint(&script_buf,
                "window.__termwebPickerResult(true, '{s}', '{s}', {s})",
                .{ escaped_path, escaped_name, if (is_dir) "true" else "false" },
            ) catch return;

            try self.evalJavaScript(script);
        } else {
            // User cancelled
            try self.evalJavaScript("window.__termwebPickerResult(false)");
        }
    }

    /// Handle clipboard sync - copy browser clipboard to system clipboard
    pub fn handleClipboardSync(self: *Viewer, payload: []const u8, start: usize) !void {
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

    /// Escape single quotes for JavaScript string literals
    fn escapeSingleQuotes(input: []const u8, buf: []u8) []const u8 {
        var j: usize = 0;
        for (input) |c| {
            if (j + 2 > buf.len) break;
            if (c == '\'') {
                buf[j] = '\\';
                buf[j + 1] = '\'';
                j += 2;
            } else if (c == '\\') {
                buf[j] = '\\';
                buf[j + 1] = '\\';
                j += 2;
            } else {
                buf[j] = c;
                j += 1;
            }
        }
        return buf[0..j];
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
    pub fn handleClipboardReadRequest(self: *Viewer) void {
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
    pub fn handleFsRequest(self: *Viewer, payload: []const u8, start: usize) !void {
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
    pub fn evalJavaScript(self: *Viewer, script: []const u8) !void {
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
    pub fn showFileChooser(self: *Viewer, payload: []const u8) !void {
        self.log("[DIALOG] showFileChooser payload={s}\n", .{payload});
        // NOTE: Don't refresh viewport here - Chrome UI changes don't affect screencast

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
        // Stop all threads before freeing resources
        self.log("[DEBUG] deinit: stopping input thread...\n", .{});
        self.stopInputThread();
        self.log("[DEBUG] deinit: stopping CDP thread...\n", .{});
        self.stopCdpThread();
        self.log("[DEBUG] deinit: stopping toolbar thread...\n", .{});
        self.stopToolbarThread();
        self.log("[DEBUG] deinit: threads stopped\n", .{});
        // Free hint grid if active
        if (self.hint_grid) |grid| {
            grid.deinit();
            self.allocator.destroy(grid);
            self.hint_grid = null;
        }
        self.log("[DEBUG] deinit: stopping input...\n", .{});
        self.input.deinit();
        self.log("[DEBUG] deinit: input stopped\n", .{});
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
        // Free hint and toolbar buffers
        self.allocator.free(self.hint_badges);
        self.allocator.free(self.toolbar_rgba);
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

/// Parse a number from JSON object string (e.g., {"x":123} with key "\"x\":")
fn parseJsonNumber(obj: []const u8, key: []const u8) ?u32 {
    const key_pos = std.mem.indexOf(u8, obj, key) orelse return null;
    const num_start = key_pos + key.len;

    // Find end of number
    var num_end = num_start;
    while (num_end < obj.len and (obj[num_end] >= '0' and obj[num_end] <= '9')) : (num_end += 1) {}

    if (num_end == num_start) return null;

    return std.fmt.parseInt(u32, obj[num_start..num_end], 10) catch null;
}
