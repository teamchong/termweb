const std = @import("std");
const ws = @import("ws_server.zig");
const http = @import("http_server.zig");

const c = @cImport({
    @cInclude("libdeflate.h");
    @cInclude("ghostty.h");
    @cInclude("IOSurface/IOSurfaceRef.h");
});

const objc = @cImport({
    @cInclude("objc/runtime.h");
    @cInclude("objc/message.h");
});

// ============================================================================
// Frame Protocol (same as termweb)
// ============================================================================

pub const FrameType = enum(u8) {
    keyframe = 0x01,
    delta = 0x02,
    request_keyframe = 0x03,
};

pub const FrameHeader = packed struct {
    frame_type: u8,
    sequence: u32,
    width: u16,
    height: u16,
    compressed_size: u32,
};

// Message types from client (same as termweb)
pub const ClientMsg = enum(u8) {
    key_input = 0x01,
    mouse_input = 0x02,
    mouse_move = 0x03,
    mouse_scroll = 0x04,
    text_input = 0x05,
    resize = 0x10,
    request_keyframe = 0x11,
    pause_stream = 0x12,
    resume_stream = 0x13,
    connect_panel = 0x20,  // Connect to existing panel by ID
    create_panel = 0x21,   // Request new panel creation
};

// Key input message format (from browser)
// [msg_type:u8][key_code:u32][action:u8][mods:u8]
const KeyInputMsg = extern struct {
    key_code: u32,    // ghostty_input_key_e
    action: u8,       // 0=release, 1=press, 2=repeat
    mods: u8,         // modifier flags: shift=1, ctrl=2, alt=4, super=8
};

// Mouse button message format
// [msg_type:u8][x:f64][y:f64][button:u8][state:u8][mods:u8]
const MouseButtonMsg = extern struct {
    x: f64,
    y: f64,
    button: u8,       // 0=left, 1=right, 2=middle
    state: u8,        // 0=release, 1=press
    mods: u8,
};

// Mouse move message format
// [msg_type:u8][x:f64][y:f64][mods:u8]
const MouseMoveMsg = extern struct {
    x: f64,
    y: f64,
    mods: u8,
};

// Mouse scroll message format
// [msg_type:u8][x:f64][y:f64][dx:f64][dy:f64][mods:u8]
const MouseScrollMsg = extern struct {
    x: f64,
    y: f64,
    scroll_x: f64,
    scroll_y: f64,
    mods: u8,
};

// ============================================================================
// Control Channel Protocol (JSON over text WebSocket frames)
// ============================================================================

// Control message types (text/JSON)
pub const ControlMsgType = enum {
    // Server → Client
    panel_list,      // List of all panels
    panel_created,   // New panel created
    panel_closed,    // Panel was closed
    panel_title,     // Panel title changed
    panel_bell,      // Bell notification
    layout_update,   // Split layout changed

    // Client → Server
    create_panel,    // Request new panel
    close_panel,     // Close a panel
    focus_panel,     // Set active panel
    split_panel,     // Split current panel
};

const IOSurfacePtr = *c.struct___IOSurface;

// ============================================================================
// Frame Buffer for XOR diff
// ============================================================================

const FrameBuffer = struct {
    rgba_current: []u8,    // Raw BGRA from IOSurface
    rgb_current: []u8,     // Converted RGB (3 bytes per pixel)
    rgb_previous: []u8,    // Previous frame RGB
    diff: []u8,            // XOR diff
    compressed: []u8,      // Compressed output
    width: u32,
    height: u32,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, width: u32, height: u32) !FrameBuffer {
        const rgba_size = width * height * 4;
        const rgb_size = width * height * 3;
        const compressed_max = rgb_size + 1024;

        return .{
            .rgba_current = try allocator.alloc(u8, rgba_size),
            .rgb_current = try allocator.alloc(u8, rgb_size),
            .rgb_previous = try allocator.alloc(u8, rgb_size),
            .diff = try allocator.alloc(u8, rgb_size),
            .compressed = try allocator.alloc(u8, compressed_max),
            .width = width,
            .height = height,
            .allocator = allocator,
        };
    }

    fn deinit(self: *FrameBuffer) void {
        self.allocator.free(self.rgba_current);
        self.allocator.free(self.rgb_current);
        self.allocator.free(self.rgb_previous);
        self.allocator.free(self.diff);
        self.allocator.free(self.compressed);
    }

    fn resize(self: *FrameBuffer, width: u32, height: u32) !void {
        if (self.width == width and self.height == height) return;
        self.deinit();
        self.* = try FrameBuffer.init(self.allocator, width, height);
    }

    // Convert BGRA to RGB (drop alpha, swap B/R)
    fn convertBgraToRgb(self: *FrameBuffer) void {
        const pixel_count = self.width * self.height;
        var i: usize = 0;
        while (i < pixel_count) : (i += 1) {
            const src = i * 4;
            const dst = i * 3;
            // BGRA -> RGB
            self.rgb_current[dst + 0] = self.rgba_current[src + 2]; // R
            self.rgb_current[dst + 1] = self.rgba_current[src + 1]; // G
            self.rgb_current[dst + 2] = self.rgba_current[src + 0]; // B
        }
    }

    fn computeDiff(self: *FrameBuffer) void {
        const len = self.rgb_current.len;
        var i: usize = 0;
        // SIMD-friendly loop
        while (i + 32 <= len) : (i += 32) {
            inline for (0..32) |j| {
                self.diff[i + j] = self.rgb_current[i + j] ^ self.rgb_previous[i + j];
            }
        }
        while (i < len) : (i += 1) {
            self.diff[i] = self.rgb_current[i] ^ self.rgb_previous[i];
        }
    }

    fn swapBuffers(self: *FrameBuffer) void {
        const tmp = self.rgb_previous;
        self.rgb_previous = self.rgb_current;
        self.rgb_current = tmp;
    }
};

// ============================================================================
// Compressor
// ============================================================================

const Compressor = struct {
    compressor: *c.libdeflate_compressor,

    fn init() !Compressor {
        const comp = c.libdeflate_alloc_compressor(6) orelse return error.CompressorInitFailed;
        return .{ .compressor = comp };
    }

    fn deinit(self: *Compressor) void {
        c.libdeflate_free_compressor(self.compressor);
    }

    fn compress(self: *Compressor, input: []const u8, output: []u8) !usize {
        // Use raw deflate (no zlib header) for native browser DecompressionStream
        const result = c.libdeflate_deflate_compress(
            self.compressor,
            input.ptr,
            input.len,
            output.ptr,
            output.len,
        );
        if (result == 0) return error.CompressionFailed;
        return result;
    }
};

// ============================================================================
// Input Event Queue (for thread-safe input to ghostty)
// ============================================================================

const InputEvent = union(enum) {
    key: c.ghostty_input_key_s,
    text: struct { data: [256]u8, len: usize },
    mouse_pos: struct { x: f64, y: f64, mods: c.ghostty_input_mods_e },
    mouse_button: struct { state: c.ghostty_input_mouse_state_e, button: c.ghostty_input_mouse_button_e, mods: c.ghostty_input_mods_e },
    mouse_scroll: struct { x: f64, y: f64, dx: f64, dy: f64 },
    resize: struct { width: u32, height: u32 },
};

// ============================================================================
// Panel - One ghostty surface + streamer + websocket connection
// ============================================================================

const Panel = struct {
    id: u32,
    surface: c.ghostty_surface_t,
    nsview: objc.id,
    window: objc.id,
    frame_buffer: FrameBuffer,
    compressor: Compressor,
    sequence: u32,
    last_keyframe: i64,
    width: u32,
    height: u32,
    scale: f64,
    streaming: std.atomic.Value(bool),
    force_keyframe: bool,
    connection: ?*ws.Connection,
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    input_queue: std.ArrayList(InputEvent),

    const KEYFRAME_INTERVAL_MS = 2000;

    fn init(allocator: std.mem.Allocator, app: c.ghostty_app_t, id: u32, width: u32, height: u32, scale: f64) !*Panel {
        const panel = try allocator.create(Panel);
        errdefer allocator.destroy(panel);

        const window_view = createHiddenWindow(width, height) orelse return error.WindowCreationFailed;

        // Make view layer-backed for Metal rendering
        makeViewLayerBacked(window_view.view);

        var surface_config = c.ghostty_surface_config_new();
        surface_config.platform_tag = c.GHOSTTY_PLATFORM_MACOS;
        surface_config.platform.macos.nsview = @ptrCast(window_view.view);
        surface_config.scale_factor = scale;
        // Use default shell (null = user's shell from /etc/passwd)
        surface_config.command = null;
        surface_config.working_directory = null;

        const surface = c.ghostty_surface_new(app, &surface_config);
        if (surface == null) return error.SurfaceCreationFailed;
        errdefer c.ghostty_surface_free(surface);

        // Focus the surface so it accepts input
        c.ghostty_surface_set_focus(surface, true);

        c.ghostty_surface_set_size(surface, width, height);

        const pixel_width: u32 = @intFromFloat(@as(f64, @floatFromInt(width)) * scale);
        const pixel_height: u32 = @intFromFloat(@as(f64, @floatFromInt(height)) * scale);

        panel.* = .{
            .id = id,
            .surface = surface,
            .nsview = window_view.view,
            .window = window_view.window,
            .frame_buffer = try FrameBuffer.init(allocator, pixel_width, pixel_height),
            .compressor = try Compressor.init(),
            .sequence = 0,
            .last_keyframe = 0,
            .width = width,
            .height = height,
            .scale = scale,
            .streaming = std.atomic.Value(bool).init(false), // Start paused until connected
            .force_keyframe = true,
            .connection = null,
            .allocator = allocator,
            .mutex = .{},
            .input_queue = .{},
        };

        return panel;
    }

    fn deinit(self: *Panel) void {
        c.ghostty_surface_free(self.surface);
        self.frame_buffer.deinit();
        self.compressor.deinit();
        self.input_queue.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn setConnection(self: *Panel, conn: ?*ws.Connection) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.connection = conn;
        if (conn != null) {
            self.streaming.store(true, .release);
            self.force_keyframe = true;
        } else {
            self.streaming.store(false, .release);
        }
    }

    // Internal resize - called from main thread only (via processInputQueue)
    fn resizeInternal(self: *Panel, width: u32, height: u32) !void {
        self.width = width;
        self.height = height;

        // Resize the NSWindow and NSView
        resizeWindow(self.window, width, height);

        // Tell ghostty about the new size
        c.ghostty_surface_set_size(self.surface, width, height);

        // Don't resize frame_buffer here - let captureFromIOSurface do it
        // when the IOSurface actually updates to the new size
        self.force_keyframe = true;
    }

    fn pause(self: *Panel) void {
        self.streaming.store(false, .release);
    }

    fn resumeStream(self: *Panel) void {
        self.streaming.store(true, .release);
        self.force_keyframe = true;
    }

    fn requestKeyframe(self: *Panel) void {
        self.force_keyframe = true;
    }

    fn captureFromIOSurface(self: *Panel, iosurface: IOSurfacePtr) !void {
        _ = c.IOSurfaceLock(iosurface, c.kIOSurfaceLockReadOnly, null);
        defer _ = c.IOSurfaceUnlock(iosurface, c.kIOSurfaceLockReadOnly, null);

        const base_addr: ?[*]u8 = @ptrCast(c.IOSurfaceGetBaseAddress(iosurface));
        if (base_addr == null) return error.NoBaseAddress;

        const src_bytes_per_row = c.IOSurfaceGetBytesPerRow(iosurface);
        const surf_width = c.IOSurfaceGetWidth(iosurface);
        const surf_height = c.IOSurfaceGetHeight(iosurface);

        try self.frame_buffer.resize(@intCast(surf_width), @intCast(surf_height));

        // Copy BGRA data row by row
        const dst_bytes_per_row = self.frame_buffer.width * 4;
        for (0..surf_height) |y| {
            const src_offset = y * src_bytes_per_row;
            const dst_offset = y * dst_bytes_per_row;
            const copy_len = @min(dst_bytes_per_row, src_bytes_per_row);
            @memcpy(
                self.frame_buffer.rgba_current[dst_offset..][0..copy_len],
                base_addr.?[src_offset..][0..copy_len],
            );
        }

        // Convert BGRA to RGB
        self.frame_buffer.convertBgraToRgb();
    }

    fn prepareFrame(self: *Panel) !struct { data: []u8, is_keyframe: bool } {
        const now = std.time.milliTimestamp();
        const need_keyframe = self.force_keyframe or
            (now - self.last_keyframe >= KEYFRAME_INTERVAL_MS) or
            self.sequence == 0;

        var data_to_compress: []u8 = undefined;
        var is_keyframe: bool = undefined;

        if (need_keyframe) {
            // Send full RGB frame
            data_to_compress = self.frame_buffer.rgb_current;
            is_keyframe = true;
            self.last_keyframe = now;
            self.force_keyframe = false;
        } else {
            // Send XOR diff
            self.frame_buffer.computeDiff();
            data_to_compress = self.frame_buffer.diff;
            is_keyframe = false;
        }

        const header_size: usize = 13; // frame_type(1) + sequence(4) + width(2) + height(2) + compressed_size(4)
        const compressed_size = try self.compressor.compress(
            data_to_compress,
            self.frame_buffer.compressed[header_size..],
        );

        // Write header manually to avoid alignment issues with packed struct
        const buf = self.frame_buffer.compressed;
        buf[0] = if (is_keyframe) @intFromEnum(FrameType.keyframe) else @intFromEnum(FrameType.delta);
        std.mem.writeInt(u32, buf[1..5], self.sequence, .little);
        std.mem.writeInt(u16, buf[5..7], @intCast(self.frame_buffer.width), .little);
        std.mem.writeInt(u16, buf[7..9], @intCast(self.frame_buffer.height), .little);
        std.mem.writeInt(u32, buf[9..13], @intCast(compressed_size), .little);

        self.sequence +%= 1;
        self.frame_buffer.swapBuffers();

        return .{
            .data = self.frame_buffer.compressed[0 .. header_size + compressed_size],
            .is_keyframe = is_keyframe,
        };
    }

    // Process queued input events (must be called from main thread)
    fn processInputQueue(self: *Panel) void {
        self.mutex.lock();
        // Process events directly from items slice, then clear
        const items = self.input_queue.items;
        const count = items.len;
        if (count == 0) {
            self.mutex.unlock();
            return;
        }
        // Copy events locally to release mutex quickly
        var events_buf: [256]InputEvent = undefined;
        const events_count = @min(count, events_buf.len);
        @memcpy(events_buf[0..events_count], items[0..events_count]);
        self.input_queue.clearRetainingCapacity();
        self.mutex.unlock();

        for (events_buf[0..events_count]) |event| {
            switch (event) {
                .key => |key_input| {
                    _ = c.ghostty_surface_key(self.surface, key_input);
                },
                .text => |text| {
                    c.ghostty_surface_text(self.surface, &text.data, text.len);
                },
                .mouse_pos => |pos| {
                    c.ghostty_surface_mouse_pos(self.surface, pos.x, pos.y, pos.mods);
                },
                .mouse_button => |btn| {
                    _ = c.ghostty_surface_mouse_button(self.surface, btn.state, btn.button, btn.mods);
                },
                .mouse_scroll => |scroll| {
                    c.ghostty_surface_mouse_pos(self.surface, scroll.x, scroll.y, 0);
                    c.ghostty_surface_mouse_scroll(self.surface, scroll.dx, scroll.dy, 0);
                },
                .resize => |size| {
                    self.resizeInternal(size.width, size.height) catch {};
                },
            }
        }
    }

    fn tick(self: *Panel) void {
        c.ghostty_surface_draw(self.surface);
    }

    fn getIOSurface(self: *Panel) ?IOSurfacePtr {
        return getIOSurfaceFromView(self.nsview);
    }

    // Send frame over WebSocket if connected
    fn sendFrame(self: *Panel, data: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.connection) |conn| {
            if (conn.is_open) {
                try conn.sendBinary(data);
            }
        }
    }

    // Convert browser mods to ghostty mods
    fn convertMods(browser_mods: u8) c.ghostty_input_mods_e {
        var mods: c_uint = 0;
        if (browser_mods & 0x01 != 0) mods |= c.GHOSTTY_MODS_SHIFT;
        if (browser_mods & 0x02 != 0) mods |= c.GHOSTTY_MODS_CTRL;
        if (browser_mods & 0x04 != 0) mods |= c.GHOSTTY_MODS_ALT;
        if (browser_mods & 0x08 != 0) mods |= c.GHOSTTY_MODS_SUPER;
        return @intCast(mods);
    }

    // Handle keyboard input from client (queues event for main thread)
    fn handleKeyInput(self: *Panel, data: []const u8) void {
        if (data.len < @sizeOf(KeyInputMsg)) return;

        const msg: *const KeyInputMsg = @ptrCast(@alignCast(data.ptr));

        const key_input = c.ghostty_input_key_s{
            .action = switch (msg.action) {
                0 => c.GHOSTTY_ACTION_RELEASE,
                1 => c.GHOSTTY_ACTION_PRESS,
                2 => c.GHOSTTY_ACTION_REPEAT,
                else => c.GHOSTTY_ACTION_PRESS,
            },
            .keycode = msg.key_code,
            .mods = convertMods(msg.mods),
            .consumed_mods = 0,
            .text = null,
            .unshifted_codepoint = 0,
            .composing = false,
        };

        self.mutex.lock();
        defer self.mutex.unlock();
        self.input_queue.append(self.allocator, .{ .key = key_input }) catch {};
    }

    // Handle text input (for IME, paste, etc.) - queues event for main thread
    fn handleTextInput(self: *Panel, data: []const u8) void {
        if (data.len == 0) return;

        var text_event: InputEvent = .{ .text = .{ .data = undefined, .len = @min(data.len, 256) } };
        @memcpy(text_event.text.data[0..text_event.text.len], data[0..text_event.text.len]);

        self.mutex.lock();
        defer self.mutex.unlock();
        self.input_queue.append(self.allocator, text_event) catch {};
    }

    // Handle mouse button input from client - queues events for main thread
    fn handleMouseButton(self: *Panel, data: []const u8) void {
        if (data.len < @sizeOf(MouseButtonMsg)) return;

        const msg: *const MouseButtonMsg = @ptrCast(@alignCast(data.ptr));

        const state: c.ghostty_input_mouse_state_e = if (msg.state == 1)
            c.GHOSTTY_MOUSE_PRESS
        else
            c.GHOSTTY_MOUSE_RELEASE;

        const button: c.ghostty_input_mouse_button_e = switch (msg.button) {
            0 => c.GHOSTTY_MOUSE_LEFT,
            1 => c.GHOSTTY_MOUSE_RIGHT,
            2 => c.GHOSTTY_MOUSE_MIDDLE,
            else => c.GHOSTTY_MOUSE_LEFT,
        };

        const mods = convertMods(msg.mods);

        self.mutex.lock();
        defer self.mutex.unlock();
        // Queue position update first, then button event
        self.input_queue.append(self.allocator, .{ .mouse_pos = .{ .x = msg.x, .y = msg.y, .mods = mods } }) catch {};
        self.input_queue.append(self.allocator, .{ .mouse_button = .{ .state = state, .button = button, .mods = mods } }) catch {};
    }

    // Handle mouse move - queues event for main thread
    fn handleMouseMove(self: *Panel, data: []const u8) void {
        if (data.len < @sizeOf(MouseMoveMsg)) return;

        const msg: *const MouseMoveMsg = @ptrCast(@alignCast(data.ptr));

        self.mutex.lock();
        defer self.mutex.unlock();
        self.input_queue.append(self.allocator, .{ .mouse_pos = .{ .x = msg.x, .y = msg.y, .mods = convertMods(msg.mods) } }) catch {};
    }

    // Handle mouse scroll - queues events for main thread
    fn handleMouseScroll(self: *Panel, data: []const u8) void {
        if (data.len < @sizeOf(MouseScrollMsg)) return;

        const msg: *const MouseScrollMsg = @ptrCast(@alignCast(data.ptr));

        self.mutex.lock();
        defer self.mutex.unlock();
        // Queue position update first, then scroll event
        self.input_queue.append(self.allocator, .{ .mouse_pos = .{ .x = msg.x, .y = msg.y, .mods = convertMods(msg.mods) } }) catch {};
        self.input_queue.append(self.allocator, .{ .mouse_scroll = .{ .x = msg.x, .y = msg.y, .dx = msg.scroll_x, .dy = msg.scroll_y } }) catch {};
    }

    // Handle client message
    fn handleMessage(self: *Panel, data: []const u8) void {
        if (data.len == 0) return;

        const msg_type: ClientMsg = @enumFromInt(data[0]);
        const payload = data[1..];

        switch (msg_type) {
            .key_input => self.handleKeyInput(payload),
            .mouse_input => self.handleMouseButton(payload),
            .mouse_move => self.handleMouseMove(payload),
            .mouse_scroll => self.handleMouseScroll(payload),
            .text_input => self.handleTextInput(payload),
            .resize => {
                if (payload.len >= 4) {
                    const w = std.mem.readInt(u16, payload[0..2], .little);
                    const h = std.mem.readInt(u16, payload[2..4], .little);
                    self.mutex.lock();
                    defer self.mutex.unlock();
                    self.input_queue.append(self.allocator, .{ .resize = .{ .width = w, .height = h } }) catch {};
                }
            },
            .request_keyframe => self.requestKeyframe(),
            .pause_stream => self.pause(),
            .resume_stream => self.resumeStream(),
            // Connection-level commands - handled in Server.onPanelMessage before reaching panel
            .connect_panel, .create_panel => {},
        }
    }
};

// ============================================================================
// Server - manages multiple panels and WebSocket connections
// ============================================================================

// Panel creation request (to be processed on main thread)
const PanelRequest = struct {
    conn: *ws.Connection,
    width: u32,
    height: u32,
    scale: f64,
};

// Panel destruction request (to be processed on main thread)
const PanelDestroyRequest = struct {
    id: u32,
};

// Panel resize request (to be processed on main thread)
const PanelResizeRequest = struct {
    id: u32,
    width: u32,
    height: u32,
};

const Server = struct {
    app: c.ghostty_app_t,
    config: c.ghostty_config_t,
    panels: std.AutoHashMap(u32, *Panel),
    panel_connections: std.AutoHashMap(*ws.Connection, *Panel),
    control_connections: std.ArrayList(*ws.Connection),
    pending_panels: std.ArrayList(PanelRequest),
    pending_destroys: std.ArrayList(PanelDestroyRequest),
    pending_resizes: std.ArrayList(PanelResizeRequest),
    next_panel_id: u32,
    panel_ws_server: *ws.Server,
    control_ws_server: *ws.Server,
    http_server: *http.HttpServer,
    running: std.atomic.Value(bool),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    var global_server: ?*Server = null;

    fn init(allocator: std.mem.Allocator, http_port: u16, control_port: u16, panel_port: u16, web_root: []const u8) !*Server {
        const server = try allocator.create(Server);
        errdefer allocator.destroy(server);

        // Initialize ghostty
        const init_result = c.ghostty_init(0, null);
        if (init_result != c.GHOSTTY_SUCCESS) return error.GhosttyInitFailed;

        // Load user's ghostty config (~/.config/ghostty/config)
        const config = c.ghostty_config_new();
        c.ghostty_config_load_default_files(config);
        c.ghostty_config_finalize(config);

        const runtime_config = c.ghostty_runtime_config_s{
            .userdata = null,
            .supports_selection_clipboard = false,
            .wakeup_cb = wakeupCallback,
            .action_cb = actionCallback,
            .read_clipboard_cb = readClipboardCallback,
            .confirm_read_clipboard_cb = confirmReadClipboardCallback,
            .write_clipboard_cb = writeClipboardCallback,
            .close_surface_cb = closeSurfaceCallback,
        };

        const app = c.ghostty_app_new(&runtime_config, config);
        if (app == null) {
            c.ghostty_config_free(config);
            return error.AppCreationFailed;
        }

        // Create HTTP server for static files
        const http_srv = try http.HttpServer.init(allocator, "0.0.0.0", http_port, web_root, config);

        // Create control WebSocket server (for tab list, layout, etc.)
        const control_ws = try ws.Server.init(allocator, "0.0.0.0", control_port);
        control_ws.setCallbacks(onControlConnect, onControlMessage, onControlDisconnect);

        // Create panel WebSocket server (for pixel streams)
        const panel_ws = try ws.Server.init(allocator, "0.0.0.0", panel_port);
        panel_ws.setCallbacks(onPanelConnect, onPanelMessage, onPanelDisconnect);

        server.* = .{
            .app = app,
            .config = config,
            .panels = std.AutoHashMap(u32, *Panel).init(allocator),
            .panel_connections = std.AutoHashMap(*ws.Connection, *Panel).init(allocator),
            .control_connections = .{},
            .pending_panels = .{},
            .pending_destroys = .{},
            .pending_resizes = .{},
            .next_panel_id = 1,
            .http_server = http_srv,
            .panel_ws_server = panel_ws,
            .control_ws_server = control_ws,
            .running = std.atomic.Value(bool).init(false),
            .allocator = allocator,
            .mutex = .{},
        };

        global_server = server;
        return server;
    }

    fn deinit(self: *Server) void {
        self.running.store(false, .release);

        var panel_it = self.panels.valueIterator();
        while (panel_it.next()) |panel| {
            panel.*.deinit();
        }
        self.panels.deinit();
        self.panel_connections.deinit();
        self.control_connections.deinit(self.allocator);
        self.pending_panels.deinit(self.allocator);
        self.pending_destroys.deinit(self.allocator);
        self.pending_resizes.deinit(self.allocator);

        self.http_server.deinit();
        self.panel_ws_server.deinit();
        self.control_ws_server.deinit();
        c.ghostty_app_free(self.app);
        c.ghostty_config_free(self.config);
        global_server = null;
        self.allocator.destroy(self);
    }

    fn createPanel(self: *Server, width: u32, height: u32, scale: f64) !*Panel {
        self.mutex.lock();
        defer self.mutex.unlock();

        const id = self.next_panel_id;
        self.next_panel_id += 1;

        const panel = try Panel.init(self.allocator, self.app, id, width, height, scale);
        try self.panels.put(id, panel);

        std.debug.print("Created panel {} ({}x{})\n", .{ id, width, height });
        return panel;
    }

    fn destroyPanel(self: *Server, id: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.panels.fetchRemove(id)) |entry| {
            entry.value.deinit();
            std.debug.print("Destroyed panel {}\n", .{id});
        }
    }

    fn getPanel(self: *Server, id: u32) ?*Panel {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.panels.get(id);
    }

    fn tick(self: *Server) void {
        c.ghostty_app_tick(self.app);
    }

    // ========== Control WebSocket callbacks ==========

    fn onControlConnect(conn: *ws.Connection) void {
        const self = global_server orelse return;

        self.mutex.lock();
        self.control_connections.append(self.allocator, conn) catch {};
        self.mutex.unlock();

        std.debug.print("Control client connected\n", .{});

        // Send current panel list
        self.sendPanelList(conn);
    }

    fn onControlMessage(conn: *ws.Connection, data: []u8, is_binary: bool) void {
        _ = is_binary;
        const self = global_server orelse return;

        // Parse JSON control message
        self.handleControlMessage(conn, data);
    }

    fn onControlDisconnect(conn: *ws.Connection) void {
        const self = global_server orelse return;

        self.mutex.lock();
        for (self.control_connections.items, 0..) |ctrl_conn, i| {
            if (ctrl_conn == conn) {
                _ = self.control_connections.swapRemove(i);
                break;
            }
        }
        self.mutex.unlock();

        std.debug.print("Control client disconnected\n", .{});
    }

    // ========== Panel WebSocket callbacks ==========

    fn onPanelConnect(conn: *ws.Connection) void {
        _ = conn;
        // Don't auto-create panel - wait for connect_panel or create_panel message
        std.debug.print("Panel client connected, waiting for panel command\n", .{});
    }

    fn onPanelMessage(conn: *ws.Connection, data: []u8, is_binary: bool) void {
        _ = is_binary;
        const self = global_server orelse return;

        if (conn.user_data) |ud| {
            // Already connected to a panel - forward message
            const panel: *Panel = @ptrCast(@alignCast(ud));
            panel.handleMessage(data);
        } else {
            // Not connected to panel yet - handle connect/create commands
            if (data.len == 0) return;
            const msg_type: ClientMsg = @enumFromInt(data[0]);

            switch (msg_type) {
                .connect_panel => {
                    // Connect to existing panel: [msg_type:u8][panel_id:u32]
                    if (data.len >= 5) {
                        const panel_id = std.mem.readInt(u32, data[1..5], .little);
                        self.mutex.lock();
                        if (self.panels.get(panel_id)) |panel| {
                            panel.setConnection(conn);
                            conn.user_data = panel;
                            self.panel_connections.put(conn, panel) catch {};
                            std.debug.print("Client connected to existing panel {}\n", .{panel_id});
                        }
                        self.mutex.unlock();
                    }
                },
                .create_panel => {
                    // Create new panel: [msg_type:u8][width:u16][height:u16][scale:f32]
                    var width: u32 = 800;
                    var height: u32 = 600;
                    var scale: f64 = 2.0;
                    if (data.len >= 5) {
                        width = std.mem.readInt(u16, data[1..3], .little);
                        height = std.mem.readInt(u16, data[3..5], .little);
                    }
                    if (data.len >= 9) {
                        const scale_f32: f32 = @bitCast(std.mem.readInt(u32, data[5..9], .little));
                        scale = @floatCast(scale_f32);
                    }
                    self.mutex.lock();
                    self.pending_panels.append(self.allocator, .{
                        .conn = conn,
                        .width = width,
                        .height = height,
                        .scale = scale,
                    }) catch {};
                    self.mutex.unlock();
                    std.debug.print("Panel creation queued ({}x{} @{d:.1}x)\n", .{ width, height, scale });
                },
                else => {},
            }
        }
    }

    fn onPanelDisconnect(conn: *ws.Connection) void {
        const self = global_server orelse return;

        self.mutex.lock();
        if (self.panel_connections.fetchRemove(conn)) |entry| {
            const panel = entry.value;
            const panel_id = panel.id;
            panel.setConnection(null);
            std.debug.print("Panel client disconnected from panel {} (panel persists)\n", .{panel_id});
        }
        self.mutex.unlock();
    }

    // ========== Control message handling ==========

    fn handleControlMessage(self: *Server, conn: *ws.Connection, data: []const u8) void {
        _ = conn;
        // Simple JSON parsing (look for "type" field)
        // In production, use proper JSON parser

        if (std.mem.indexOf(u8, data, "\"create_panel\"")) |_| {
            // Queue panel creation for main thread (don't create ghostty surface here!)
            // For now, panels are auto-created when panel WS connects
            // This message type could be used for creating additional panels
            std.debug.print("create_panel request received (panels auto-create on connect)\n", .{});
        } else if (std.mem.indexOf(u8, data, "\"close_panel\"")) |_| {
            // Queue panel destruction for main thread
            if (self.parseJsonInt(data, "panel_id")) |id| {
                std.debug.print("Queueing destruction of panel {}\n", .{id});
                self.mutex.lock();
                self.pending_destroys.append(self.allocator, .{ .id = id }) catch {};
                self.mutex.unlock();
            }
        } else if (std.mem.indexOf(u8, data, "\"resize_panel\"")) |_| {
            // Queue panel resize for main thread
            const id = self.parseJsonInt(data, "panel_id") orelse return;
            const width = self.parseJsonInt(data, "width") orelse return;
            const height = self.parseJsonInt(data, "height") orelse return;
            std.debug.print("Queueing resize of panel {} to {}x{}\n", .{ id, width, height });
            self.mutex.lock();
            self.pending_resizes.append(self.allocator, .{ .id = id, .width = width, .height = height }) catch {};
            self.mutex.unlock();
        } else if (std.mem.indexOf(u8, data, "\"view_action\"")) |_| {
            // Execute view action on panel
            const id = self.parseJsonInt(data, "panel_id") orelse return;
            const action = self.parseJsonString(data, "action") orelse return;
            std.debug.print("View action on panel {}: {s} (len={})\n", .{ id, action, action.len });
            self.mutex.lock();
            if (self.panels.get(id)) |panel| {
                self.mutex.unlock();
                const result = c.ghostty_surface_binding_action(panel.surface, action.ptr, action.len);
                std.debug.print("View action result: {}\n", .{result});
            } else {
                self.mutex.unlock();
                std.debug.print("Panel {} not found\n", .{id});
            }
        }
    }

    fn parseJsonString(self: *Server, data: []const u8, key: []const u8) ?[]const u8 {
        _ = self;
        // Build search pattern: "key":"
        var pattern_buf: [64]u8 = undefined;
        const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\":\"", .{key}) catch return null;

        const idx = std.mem.indexOf(u8, data, pattern) orelse return null;
        const start = idx + pattern.len;

        // Find closing quote
        const end = std.mem.indexOfPos(u8, data, start, "\"") orelse return null;

        return data[start..end];
    }

    fn parseJsonInt(self: *Server, data: []const u8, key: []const u8) ?u32 {
        _ = self;
        // Build search pattern: "key":
        var pattern_buf: [64]u8 = undefined;
        const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\":", .{key}) catch return null;

        const idx = std.mem.indexOf(u8, data, pattern) orelse return null;
        var start = idx + pattern.len;

        // Skip whitespace
        while (start < data.len and (data[start] == ' ' or data[start] == '\t')) : (start += 1) {}

        var end = start;
        while (end < data.len and data[end] >= '0' and data[end] <= '9') : (end += 1) {}

        if (end > start) {
            return std.fmt.parseInt(u32, data[start..end], 10) catch null;
        }
        return null;
    }

    fn sendPanelList(self: *Server, conn: *ws.Connection) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        std.debug.print("Sending panel list, {} panels exist\n", .{self.panels.count()});

        // Build JSON panel list
        var buf: [4096]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        const writer = stream.writer();

        writer.writeAll("{\"type\":\"panel_list\",\"panels\":[") catch return;

        var first = true;
        var it = self.panels.iterator();
        while (it.next()) |entry| {
            if (!first) writer.writeAll(",") catch return;
            first = false;
            writer.print("{{\"id\":{},\"width\":{},\"height\":{}}}", .{
                entry.value_ptr.*.id,
                entry.value_ptr.*.width,
                entry.value_ptr.*.height,
            }) catch return;
        }

        writer.writeAll("]}") catch return;

        conn.sendText(stream.getWritten()) catch {};
    }

    fn broadcastPanelCreated(self: *Server, panel_id: u32) void {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{{\"type\":\"panel_created\",\"panel_id\":{}}}", .{panel_id}) catch return;

        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.control_connections.items) |conn| {
            conn.sendText(msg) catch {};
        }
    }

    fn broadcastPanelClosed(self: *Server, panel_id: u32) void {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{{\"type\":\"panel_closed\",\"panel_id\":{}}}", .{panel_id}) catch return;

        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.control_connections.items) |conn| {
            conn.sendText(msg) catch {};
        }
    }

    fn broadcastPanelTitle(self: *Server, panel_id: u32, title: []const u8) void {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{{\"type\":\"panel_title\",\"panel_id\":{},\"title\":\"{s}\"}}", .{ panel_id, title }) catch return;

        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.control_connections.items) |conn| {
            conn.sendText(msg) catch {};
        }
    }

    fn broadcastPanelBell(self: *Server, panel_id: u32) void {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{{\"type\":\"panel_bell\",\"panel_id\":{}}}", .{panel_id}) catch return;

        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.control_connections.items) |conn| {
            conn.sendText(msg) catch {};
        }
    }

    // Run HTTP server
    fn runHttpServer(self: *Server) void {
        self.http_server.run() catch |err| {
            std.debug.print("HTTP server error: {}\n", .{err});
        };
    }

    // Run control WebSocket server
    fn runControlWebSocket(self: *Server) void {
        self.control_ws_server.run() catch |err| {
            std.debug.print("Control WebSocket server error: {}\n", .{err});
        };
    }

    // Run panel WebSocket server
    fn runPanelWebSocket(self: *Server) void {
        self.panel_ws_server.run() catch |err| {
            std.debug.print("Panel WebSocket server error: {}\n", .{err});
        };
    }

    // Process pending panel creation requests (must run on main thread)
    fn processPendingPanels(self: *Server) void {
        self.mutex.lock();
        const pending = self.pending_panels.toOwnedSlice(self.allocator) catch {
            self.mutex.unlock();
            return;
        };
        self.mutex.unlock();

        for (pending) |req| {
            const panel = self.createPanel(req.width, req.height, req.scale) catch |err| {
                std.debug.print("Failed to create panel: {}\n", .{err});
                continue;
            };

            panel.setConnection(req.conn);
            req.conn.user_data = panel;

            self.mutex.lock();
            self.panel_connections.put(req.conn, panel) catch {};
            self.mutex.unlock();

            std.debug.print("Panel {} created for connection\n", .{panel.id});
            self.broadcastPanelCreated(panel.id);
        }

        self.allocator.free(pending);
    }

    // Process pending panel destruction requests (must run on main thread)
    fn processPendingDestroys(self: *Server) void {
        self.mutex.lock();
        const pending = self.pending_destroys.toOwnedSlice(self.allocator) catch {
            self.mutex.unlock();
            return;
        };
        self.mutex.unlock();

        for (pending) |req| {
            self.mutex.lock();
            if (self.panels.fetchRemove(req.id)) |entry| {
                const panel = entry.value;

                // Find and close the panel's WebSocket connection
                var conn_to_remove: ?*ws.Connection = null;
                var it = self.panel_connections.iterator();
                while (it.next()) |conn_entry| {
                    if (conn_entry.value_ptr.* == panel) {
                        conn_to_remove = conn_entry.key_ptr.*;
                        break;
                    }
                }
                if (conn_to_remove) |conn| {
                    _ = self.panel_connections.remove(conn);
                    conn.sendClose() catch {};
                }

                self.mutex.unlock();

                // Destroy ghostty surface and panel
                panel.deinit();
                std.debug.print("Destroyed panel {} (ghostty surface freed)\n", .{req.id});

                // Notify clients
                self.broadcastPanelClosed(req.id);
            } else {
                self.mutex.unlock();
            }
        }

        self.allocator.free(pending);
    }

    fn processPendingResizes(self: *Server) void {
        self.mutex.lock();
        const pending = self.pending_resizes.toOwnedSlice(self.allocator) catch {
            self.mutex.unlock();
            return;
        };
        self.mutex.unlock();

        for (pending) |req| {
            self.mutex.lock();
            if (self.panels.get(req.id)) |panel| {
                self.mutex.unlock();
                panel.resizeInternal(req.width, req.height) catch |err| {
                    std.debug.print("Resize error for panel {}: {}\n", .{ req.id, err });
                };
                std.debug.print("Resized panel {} to {}x{}\n", .{ req.id, req.width, req.height });
            } else {
                self.mutex.unlock();
            }
        }

        self.allocator.free(pending);
    }

    // Main render loop
    fn runRenderLoop(self: *Server) void {
        const target_fps: u64 = 30;
        const frame_time_ns: u64 = std.time.ns_per_s / target_fps;

        while (self.running.load(.acquire)) {
            const start = std.time.nanoTimestamp();

            // Process pending panel creations/destructions/resizes (NSWindow/ghostty must be on main thread)
            self.processPendingPanels();
            self.processPendingDestroys();
            self.processPendingResizes();

            // Tick ghostty
            self.tick();

            // Process input and render all streaming panels
            self.mutex.lock();
            var panel_it = self.panels.valueIterator();
            while (panel_it.next()) |panel_ptr| {
                const panel = panel_ptr.*;
                // Process input queue for all panels (not just streaming ones)
                panel.processInputQueue();
                if (!panel.streaming.load(.acquire)) continue;
                panel.tick();
            }
            self.mutex.unlock();

            // Small delay for Metal render
            std.Thread.sleep(1 * std.time.ns_per_ms);

            // Capture and send frames
            self.mutex.lock();
            panel_it = self.panels.valueIterator();
            while (panel_it.next()) |panel_ptr| {
                const panel = panel_ptr.*;
                if (!panel.streaming.load(.acquire)) continue;

                if (panel.getIOSurface()) |iosurface| {
                    // Debug IOSurface info
                    if (panel.sequence % 100 == 0) {
                        const w = c.IOSurfaceGetWidth(iosurface);
                        const h = c.IOSurfaceGetHeight(iosurface);
                        const bpr = c.IOSurfaceGetBytesPerRow(iosurface);
                        const fmt = c.IOSurfaceGetPixelFormat(iosurface);
                        std.debug.print("[DEBUG] IOSurface: {}x{}, bpr={}, fmt=0x{X}\n", .{ w, h, bpr, fmt });
                    }

                    panel.captureFromIOSurface(iosurface) catch |err| {
                        std.debug.print("Capture error: {}\n", .{err});
                        continue;
                    };
                    const result = panel.prepareFrame() catch |err| {
                        std.debug.print("PrepareFrame error: {}\n", .{err});
                        continue;
                    };

                    if (panel.sequence % 100 == 1 or panel.force_keyframe) {
                        std.debug.print("[DEBUG] Frame {}: {}x{}, {} bytes, keyframe={}\n", .{ panel.sequence, panel.frame_buffer.width, panel.frame_buffer.height, result.data.len, result.is_keyframe });
                    }

                    panel.sendFrame(result.data) catch |err| {
                        std.debug.print("SendFrame error: {}\n", .{err});
                    };
                } else {
                    if (panel.sequence == 0) {
                        std.debug.print("Panel {}: No IOSurface yet\n", .{panel.id});
                    }
                }
            }
            self.mutex.unlock();

            // Frame rate limiting
            const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start);
            if (elapsed < frame_time_ns) {
                std.Thread.sleep(frame_time_ns - elapsed);
            }
        }
    }

    fn run(self: *Server) !void {
        self.running.store(true, .release);

        // Start HTTP server in background
        const http_thread = try std.Thread.spawn(.{}, runHttpServer, .{self});
        defer http_thread.join();

        // Start control WebSocket server in background
        const control_thread = try std.Thread.spawn(.{}, runControlWebSocket, .{self});
        defer control_thread.join();

        // Start panel WebSocket server in background
        const panel_thread = try std.Thread.spawn(.{}, runPanelWebSocket, .{self});
        defer panel_thread.join();

        // Run render loop in main thread
        self.runRenderLoop();
    }
};

// ============================================================================
// Objective-C helpers
// ============================================================================

fn getClass(name: [*:0]const u8) objc.Class {
    return objc.objc_getClass(name);
}

fn sel(name: [*:0]const u8) objc.SEL {
    return objc.sel_registerName(name);
}

const NSRect = extern struct { x: f64, y: f64, w: f64, h: f64 };

const MsgSendFn = *const fn (objc.id, objc.SEL) callconv(.c) objc.id;
const MsgSendRectFn = *const fn (objc.id, objc.SEL, NSRect, u64, u64, bool) callconv(.c) objc.id;
const MsgSendIndexFn = *const fn (objc.id, objc.SEL, u64) callconv(.c) objc.id;

fn msgSendId() MsgSendFn {
    return @ptrCast(&objc.objc_msgSend);
}

fn msgSendRect() MsgSendRectFn {
    return @ptrCast(&objc.objc_msgSend);
}

fn msgSendIndex() MsgSendIndexFn {
    return @ptrCast(&objc.objc_msgSend);
}

const WindowView = struct {
    window: objc.id,
    view: objc.id,
};

const MsgSendBoolFn = *const fn (objc.id, objc.SEL, bool) callconv(.c) void;

fn msgSendBool() MsgSendBoolFn {
    return @ptrCast(&objc.objc_msgSend);
}

fn makeViewLayerBacked(view: objc.id) void {
    // [view setWantsLayer:YES]
    msgSendBool()(view, sel("setWantsLayer:"), true);
}

fn createHiddenWindow(width: u32, height: u32) ?WindowView {
    const NSWindow = getClass("NSWindow");
    if (NSWindow == null) return null;

    const cls_as_id: objc.id = @ptrCast(@alignCast(NSWindow));
    const window = msgSendId()(cls_as_id, sel("alloc")) orelse return null;

    const rect = NSRect{
        .x = 0.0,
        .y = 0.0,
        .w = @floatFromInt(width),
        .h = @floatFromInt(height),
    };
    const initialized = msgSendRect()(window, sel("initWithContentRect:styleMask:backing:defer:"), rect, 0, 2, false) orelse return null;
    const view = msgSendId()(initialized, sel("contentView")) orelse return null;

    return .{ .window = initialized, .view = view };
}

fn resizeWindow(window: objc.id, width: u32, height: u32) void {
    if (window == null) return;

    const rect = NSRect{
        .x = 0.0,
        .y = 0.0,
        .w = @floatFromInt(width),
        .h = @floatFromInt(height),
    };

    // [window setFrame:display:]
    const MsgSendSetFrame = *const fn (objc.id, objc.SEL, NSRect, bool) callconv(.c) void;
    const setFrame: MsgSendSetFrame = @ptrCast(&objc.objc_msgSend);
    setFrame(window, sel("setFrame:display:"), rect, true);
}

var debug_frame_count: u32 = 0;

fn getIOSurfaceFromView(nsview: objc.id) ?IOSurfacePtr {
    debug_frame_count += 1;
    const should_log = (debug_frame_count % 100 == 1); // Log every 100 frames

    if (nsview == null) {
        if (should_log) std.debug.print("[DEBUG] nsview is null\n", .{});
        return null;
    }

    const layer = msgSendId()(nsview, sel("layer"));
    if (layer == null) {
        if (should_log) std.debug.print("[DEBUG] view has no layer\n", .{});
        return null;
    }

    // Get layer class name for debugging
    if (should_log) {
        const class_fn: *const fn (objc.id, objc.SEL) callconv(.c) objc.id = @ptrCast(&objc.objc_msgSend);
        const cls = class_fn(layer, sel("class"));
        if (cls != null) {
            const name_fn: *const fn (objc.id, objc.SEL) callconv(.c) [*:0]const u8 = @ptrCast(&objc.objc_msgSend);
            const class_name = name_fn(cls, sel("description"));
            std.debug.print("[DEBUG] layer class: {s}\n", .{class_name});
        }
    }

    // Try to get contents directly from the layer first
    const contents = msgSendId()(layer, sel("contents"));
    if (contents != null) {
        if (should_log) std.debug.print("[DEBUG] found contents on main layer\n", .{});
        return @ptrCast(contents);
    }

    // Check sublayers
    const sublayers = msgSendId()(layer, sel("sublayers"));
    if (sublayers == null) {
        if (should_log) std.debug.print("[DEBUG] no sublayers\n", .{});
        return null;
    }

    const count_fn: *const fn (objc.id, objc.SEL) callconv(.c) u64 = @ptrCast(&objc.objc_msgSend);
    const count = count_fn(sublayers, sel("count"));
    if (should_log) std.debug.print("[DEBUG] sublayer count: {}\n", .{count});

    if (count == 0) return null;

    // Check each sublayer
    var i: u64 = 0;
    while (i < count) : (i += 1) {
        const sublayer = msgSendIndex()(sublayers, sel("objectAtIndex:"), i);
        if (sublayer == null) continue;

        if (should_log) {
            const class_fn: *const fn (objc.id, objc.SEL) callconv(.c) objc.id = @ptrCast(&objc.objc_msgSend);
            const cls = class_fn(sublayer, sel("class"));
            if (cls != null) {
                const name_fn: *const fn (objc.id, objc.SEL) callconv(.c) [*:0]const u8 = @ptrCast(&objc.objc_msgSend);
                const class_name = name_fn(cls, sel("description"));
                std.debug.print("[DEBUG] sublayer[{}] class: {s}\n", .{ i, class_name });
            }
        }

        const sublayer_contents = msgSendId()(sublayer, sel("contents"));
        if (sublayer_contents != null) {
            if (should_log) std.debug.print("[DEBUG] found contents on sublayer[{}]\n", .{i});
            return @ptrCast(sublayer_contents);
        }
    }

    if (should_log) std.debug.print("[DEBUG] no contents found in any layer\n", .{});
    return null;
}

// ============================================================================
// Ghostty callbacks
// ============================================================================

fn wakeupCallback(userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;
}

fn actionCallback(app: c.ghostty_app_t, target: c.ghostty_target_s, action: c.ghostty_action_s) callconv(.c) bool {
    _ = app;
    const self = Server.global_server orelse return false;

    switch (action.tag) {
        c.GHOSTTY_ACTION_SET_TITLE => {
            // Get title from action
            const title_ptr = action.action.set_title.title;
            if (title_ptr == null) return false;

            const title = std.mem.span(title_ptr);

            // Find which panel this surface belongs to
            if (target.tag == c.GHOSTTY_TARGET_SURFACE) {
                const surface = target.target.surface;
                self.mutex.lock();
                var panel_it = self.panels.valueIterator();
                while (panel_it.next()) |panel_ptr| {
                    const panel = panel_ptr.*;
                    if (panel.surface == surface) {
                        self.mutex.unlock();
                        self.broadcastPanelTitle(panel.id, title);
                        return true;
                    }
                }
                self.mutex.unlock();
            }
        },
        c.GHOSTTY_ACTION_RING_BELL => {
            // Could send bell notification to browser
            if (target.tag == c.GHOSTTY_TARGET_SURFACE) {
                const surface = target.target.surface;
                self.mutex.lock();
                var panel_it = self.panels.valueIterator();
                while (panel_it.next()) |panel_ptr| {
                    const panel = panel_ptr.*;
                    if (panel.surface == surface) {
                        self.mutex.unlock();
                        self.broadcastPanelBell(panel.id);
                        return true;
                    }
                }
                self.mutex.unlock();
            }
        },
        else => {},
    }
    return false;
}

fn readClipboardCallback(userdata: ?*anyopaque, clipboard: c.ghostty_clipboard_e, context: ?*anyopaque) callconv(.c) void {
    _ = userdata;
    _ = clipboard;
    _ = context;
}

fn confirmReadClipboardCallback(userdata: ?*anyopaque, data: [*c]const u8, context: ?*anyopaque, request: c.ghostty_clipboard_request_e) callconv(.c) void {
    _ = userdata;
    _ = data;
    _ = context;
    _ = request;
}

fn writeClipboardCallback(userdata: ?*anyopaque, clipboard: c.ghostty_clipboard_e, content: [*c]const c.ghostty_clipboard_content_s, count: usize, protected: bool) callconv(.c) void {
    _ = userdata;
    _ = clipboard;
    _ = content;
    _ = count;
    _ = protected;
}

fn closeSurfaceCallback(userdata: ?*anyopaque, needs_confirm: bool) callconv(.c) void {
    _ = userdata;
    _ = needs_confirm;
}

// ============================================================================
// Main
// ============================================================================

const Args = struct {
    http_port: u16 = 8080,
    web_root: []const u8 = "../web",
};

fn parseArgs(allocator: std.mem.Allocator) !Args {
    var args = Args{};
    var arg_it = try std.process.argsWithAllocator(allocator);
    defer arg_it.deinit();

    // Skip program name
    _ = arg_it.skip();

    while (arg_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--http-port") or std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            if (arg_it.next()) |val| {
                args.http_port = std.fmt.parseInt(u16, val, 10) catch 8080;
            }
        } else if (std.mem.eql(u8, arg, "--web-root")) {
            if (arg_it.next()) |val| {
                args.web_root = val;
            }
        }
    }

    return args;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try parseArgs(allocator);

    std.debug.print("termweb-mux server starting...\n", .{});

    // WS ports use 0 to let OS assign random available ports
    const server = try Server.init(allocator, args.http_port, 0, 0, args.web_root);
    defer server.deinit();

    const panel_port = server.panel_ws_server.listener.listen_address.getPort();
    const control_port = server.control_ws_server.listener.listen_address.getPort();

    // Tell HTTP server about the WS ports so it can serve /config
    server.http_server.setWsPorts(panel_port, control_port);

    std.debug.print("  HTTP:              http://localhost:{}\n", .{args.http_port});
    std.debug.print("  Panel WebSocket:   ws://localhost:{}\n", .{panel_port});
    std.debug.print("  Control WebSocket: ws://localhost:{}\n", .{control_port});
    std.debug.print("  Web root:          {s}\n", .{args.web_root});
    std.debug.print("\nServer initialized, waiting for connections...\n", .{});

    try server.run();
}
