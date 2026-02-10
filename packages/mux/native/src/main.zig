//! Terminal multiplexer server for termweb.
//!
//! This is the core server that manages terminal sessions and streams them to web clients.
//! It handles:
//! - Terminal lifecycle management via libghostty (macOS) or PTY (Linux)
//! - Real-time H.264 video encoding of terminal surfaces
//! - WebSocket message routing for input/output
//! - Multi-panel/split management with layout persistence
//! - File transfer operations with compression
//!
//! Architecture:
//! - HTTP server serves embedded web assets and handles WebSocket upgrades
//! - Separate WebSocket endpoints for panel streams, control messages, and file transfers
//! - Platform-specific video encoding (VideoToolbox on macOS, VA-API on Linux)
//!
const std = @import("std");
const builtin = @import("builtin");
const ws = @import("ws_server.zig");
const http = @import("http_server.zig");
const transfer = @import("transfer.zig");
const auth = @import("auth.zig");
const WakeSignal = @import("wake_signal.zig").WakeSignal;
const Channel = @import("async/channel.zig").Channel;
const goroutine_runtime = @import("async/runtime.zig");
const gchannel = @import("async/gchannel.zig");
pub const tunnel_mod = @import("tunnel.zig");


// Debug logging to stderr
fn debugLog(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

// Platform detection
const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;

// Cross-platform video encoder (uses comptime to select implementation)
const video = @import("video.zig");

// Platform-specific C imports + ghostty
const c = if (is_macos) @cImport({
    @cInclude("ghostty.h");
    @cInclude("IOSurface/IOSurfaceRef.h");
}) else @cImport({
    @cInclude("ghostty.h");
    @cInclude("execinfo.h");
});

// IOSurface types/stubs for cross-platform code (actual calls guarded by is_macos)
const IOSurfacePtr = if (is_macos) *c.struct___IOSurface else *anyopaque;

// Objective-C runtime (macOS only, stub on Linux)
const objc = if (is_macos) @cImport({
    @cInclude("objc/runtime.h");
    @cInclude("objc/message.h");
}) else struct {
    pub const id = ?*anyopaque;
    pub const SEL = ?*anyopaque;
    pub const Class = ?*anyopaque;
    pub fn sel_registerName(_: [*:0]const u8) SEL { return null; }
    pub fn objc_getClass(_: [*:0]const u8) Class { return null; }
    pub fn class_getInstanceMethod(_: Class, _: SEL) ?*anyopaque { return null; }
    pub fn method_getImplementation(_: ?*anyopaque) ?*anyopaque { return null; }

    // Stub for objc_msgSend - returns null function pointer
    pub fn objc_msgSend() callconv(.c) ?*anyopaque { return null; }
};


// Frame Protocol (same as termweb)


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
    buffer_stats = 0x14,   // Client reports buffer health for adaptive bitrate
    connect_panel = 0x20,  // Connect to existing panel by ID
    create_panel = 0x21,   // Request new panel creation
    split_panel = 0x22,    // Create panel as split of existing panel
    inspector_subscribe = 0x30,   // Subscribe to inspector updates: [msg_type:u8][tab_len:u8][tab:...]
    inspector_unsubscribe = 0x31, // Unsubscribe from inspector updates: [msg_type:u8]
    inspector_tab = 0x32,         // Change inspector tab: [msg_type:u8][tab_len:u8][tab:...]
};

// Key input message format (from browser)
// [msg_type:u8][key_code:u32][action:u8][mods:u8][text_len:u8][text:...]
const KeyInputMsg = extern struct {
    key_code: u32,    // ghostty_input_key_e
    action: u8,       // 0=release, 1=press, 2=repeat
    mods: u8,         // modifier flags: shift=1, ctrl=2, alt=4, super=8
    text_len: u8,     // length of following text (0 for special keys)
};

// Mouse button message format
// [msg_type:u8][x:f64][y:f64][button:u8][state:u8][mods:u8]
const MouseButtonMsg = packed struct {
    x: f64,
    y: f64,
    button: u8,       // 0=left, 1=right, 2=middle
    state: u8,        // 0=release, 1=press
    mods: u8,
};

// Mouse move message format
// [msg_type:u8][x:f64][y:f64][mods:u8]
const MouseMoveMsg = packed struct {
    x: f64,
    y: f64,
    mods: u8,
};

// Mouse scroll message format
// [msg_type:u8][x:f64][y:f64][dx:f64][dy:f64][mods:u8]
const MouseScrollMsg = packed struct {
    x: f64,
    y: f64,
    scroll_x: f64,
    scroll_y: f64,
    mods: u8,
};


// Control Channel Protocol (Binary)


// Binary control message types (wire protocol)
pub const BinaryCtrlMsg = enum(u8) {
    // Server → Client (0x01-0x0F)
    panel_list = 0x01,
    panel_created = 0x02,
    panel_closed = 0x03,
    panel_title = 0x04,
    panel_pwd = 0x05,
    panel_bell = 0x06,
    layout_update = 0x07,
    clipboard = 0x08,
    inspector_state = 0x09,
    panel_notification = 0x0D,
    overview_state = 0x0E,  // Overview open/closed state
    quick_terminal_state = 0x0F,  // Quick terminal open/closed state
    main_client_state = 0x10,  // Main client election: [type:u8][is_main:u8][client_id:u32] = 6 bytes
    panel_assignment = 0x11,  // Multiplayer: panel assigned/unassigned [type:u8][panel_id:u32][session_id_len:u8][session_id:...]
    client_list = 0x12,  // Multiplayer: connected clients list [type:u8][count:u8][{client_id:u32, role:u8, session_id_len:u8, session_id:...}*]
    session_identity = 0x13,  // Multiplayer: your session identity [type:u8][session_id_len:u8][session_id:...]
    cursor_state = 0x14,  // Cursor position/style for frontend CSS blink [type:u8][panel_id:u32][x:u16][y:u16][w:u16][h:u16][style:u8][visible:u8] = 15 bytes
    surface_dims = 0x15,  // Surface pixel dimensions (sent on resize, not per-frame) [type:u8][panel_id:u32][width:u16][height:u16] = 9 bytes
    inspector_state_open = 0x1E,  // Inspector open/closed state (0x09 is already inspector_state)

    // Auth/Session Server → Client (0x0A-0x0F)
    auth_state = 0x0A,      // Current auth state (role, sessions, tokens)
    session_list = 0x0B,    // List of sessions
    share_links = 0x0C,     // List of active share links

    // Client → Server (0x80-0x8F)
    close_panel = 0x81,
    resize_panel = 0x82,
    focus_panel = 0x83,
    assign_panel = 0x84,    // Multiplayer: admin assigns panel to session [type:u8][panel_id:u32][session_id_len:u8][session_id:...]
    unassign_panel = 0x85,  // Multiplayer: admin unassigns panel [type:u8][panel_id:u32]
    panel_input = 0x86,     // Multiplayer: coworker sends input to assigned panel [type:u8][panel_id:u32][input_msg...]
    panel_msg = 0x87,       // Panel message envelope: [type:u8][panel_id:u32][inner_msg...] — routes panel input through zstd WS
    view_action = 0x88,
    set_overview = 0x89,  // Set overview open/closed state
    set_quick_terminal = 0x8A,  // Set quick terminal open/closed state
    set_inspector = 0x8B,  // Set inspector open/closed state

    // Batch envelope (both directions)
    batch = 0xFE,  // [type:u8][count:u16_le][len1:u16_le][msg1...][len2:u16_le][msg2...]...

    // Auth/Session Client → Server (0x90-0x9F)
    get_auth_state = 0x90,       // Request auth state
    set_password = 0x91,         // Set admin password
    verify_password = 0x92,      // Verify password (login)
    create_session = 0x93,       // Create new session
    delete_session = 0x94,       // Delete session
    regenerate_token = 0x95,     // Regenerate session token
    create_share_link = 0x96,    // Create share link
    revoke_share_link = 0x97,    // Revoke share link
    revoke_all_shares = 0x98,    // Revoke all share links
    add_passkey = 0x99,          // Add passkey credential
    remove_passkey = 0x9A,       // Remove passkey credential
};

// Layout Management (persisted to disk)


pub const SplitDirection = enum {
    horizontal,
    vertical,
};

// A node in the split tree - either a leaf (panel) or a split (two children)
pub const SplitNode = struct {
    // For leaf nodes
    panel_id: ?u32 = null,

    // For split nodes
    direction: ?SplitDirection = null,
    ratio: f32 = 0.5,
    first: ?*SplitNode = null,
    second: ?*SplitNode = null,

    pub fn isLeaf(self: *const SplitNode) bool {
        return self.panel_id != null;
    }

    pub fn deinit(self: *SplitNode, allocator: std.mem.Allocator) void {
        if (self.first) |first| {
            first.deinit(allocator);
            allocator.destroy(first);
        }
        if (self.second) |second| {
            second.deinit(allocator);
            allocator.destroy(second);
        }
    }
};

pub const Tab = struct {
    id: u32,
    root: *SplitNode,
    title: []const u8,

    pub fn deinit(self: *Tab, allocator: std.mem.Allocator) void {
        self.root.deinit(allocator);
        allocator.destroy(self.root);
        if (self.title.len > 0) {
            allocator.free(self.title);
        }
    }

    // Get all panel IDs in this tab
    pub fn getAllPanelIds(self: *const Tab, allocator: std.mem.Allocator) !std.ArrayListUnmanaged(u32) {
        var list: std.ArrayListUnmanaged(u32) = .{};
        try collectPanelIds(allocator, self.root, &list);
        return list;
    }

    /// Collect panel IDs into a fixed-size stack buffer (zero-alloc).
    pub fn collectPanelIdsInto(self: *const Tab, buf: []u32) usize {
        var count: usize = 0;
        collectPanelIdsStack(self.root, buf, &count);
        return count;
    }

    fn collectPanelIds(allocator: std.mem.Allocator, node: *const SplitNode, list: *std.ArrayListUnmanaged(u32)) !void {
        if (node.panel_id) |pid| {
            try list.append(allocator, pid);
        }
        if (node.first) |first| {
            try collectPanelIds(allocator, first, list);
        }
        if (node.second) |second| {
            try collectPanelIds(allocator, second, list);
        }
    }

    fn collectPanelIdsStack(node: *const SplitNode, buf: []u32, count: *usize) void {
        if (node.panel_id) |pid| {
            if (count.* < buf.len) {
                buf[count.*] = pid;
                count.* += 1;
            }
        }
        if (node.first) |first| collectPanelIdsStack(first, buf, count);
        if (node.second) |second| collectPanelIdsStack(second, buf, count);
    }
};

pub const Layout = struct {
    tabs: std.ArrayListUnmanaged(*Tab),
    active_panel_id: ?u32 = null,
    next_tab_id: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Layout {
        return .{
            .tabs = .{},
            .next_tab_id = 1,
            .allocator = allocator,
        };
    }

    /// Derive active tab from active panel
    pub fn getActiveTabId(self: *const Layout) ?u32 {
        const pid = self.active_panel_id orelse return null;
        const tab = self.findTabByPanel(pid) orelse return null;
        return tab.id;
    }

    pub fn deinit(self: *Layout) void {
        for (self.tabs.items) |tab| {
            tab.deinit(self.allocator);
            self.allocator.destroy(tab);
        }
        self.tabs.deinit(self.allocator);
    }

    // Create a new tab with a single panel
    pub fn createTab(self: *Layout, panel_id: u32) !*Tab {
        const tab = try self.allocator.create(Tab);
        const root = try self.allocator.create(SplitNode);
        root.* = .{ .panel_id = panel_id };

        tab.* = .{
            .id = self.next_tab_id,
            .root = root,
            .title = &.{}, // Empty - will show ghost emoji until terminal sets title
        };
        self.next_tab_id += 1;

        try self.tabs.append(self.allocator, tab);
        self.active_panel_id = panel_id;
        return tab;
    }

    // Find the tab containing a panel
    pub fn findTabByPanel(self: *const Layout, panel_id: u32) ?*Tab {
        for (self.tabs.items) |tab| {
            if (containsPanel(tab.root, panel_id)) {
                return tab;
            }
        }
        return null;
    }

    fn containsPanel(node: *const SplitNode, panel_id: u32) bool {
        if (node.panel_id) |pid| {
            if (pid == panel_id) return true;
        }
        if (node.first) |first| {
            if (containsPanel(first, panel_id)) return true;
        }
        if (node.second) |second| {
            if (containsPanel(second, panel_id)) return true;
        }
        return false;
    }

    // Split a panel in a direction, returns the new panel's expected position
    pub fn splitPanel(self: *Layout, panel_id: u32, direction: SplitDirection, new_panel_id: u32) !void {
        const tab = self.findTabByPanel(panel_id) orelse return error.PanelNotFound;
        try splitNode(self.allocator, tab.root, panel_id, direction, new_panel_id);
        self.active_panel_id = new_panel_id;
    }

    fn splitNode(allocator: std.mem.Allocator, node: *SplitNode, panel_id: u32, direction: SplitDirection, new_panel_id: u32) !void {
        if (node.panel_id) |pid| {
            if (pid == panel_id) {
                // This is the node to split
                const first = try allocator.create(SplitNode);
                const second = try allocator.create(SplitNode);

                first.* = .{ .panel_id = panel_id };
                second.* = .{ .panel_id = new_panel_id };

                node.panel_id = null;
                node.direction = direction;
                node.ratio = 0.5;
                node.first = first;
                node.second = second;
                return;
            }
        }

        // Recurse into children
        if (node.first) |first| {
            splitNode(allocator, first, panel_id, direction, new_panel_id) catch {};
        }
        if (node.second) |second| {
            splitNode(allocator, second, panel_id, direction, new_panel_id) catch {};
        }
    }

    // Remove a panel from the layout, collapsing splits as needed
    pub fn removePanel(self: *Layout, panel_id: u32) void {
        for (self.tabs.items, 0..) |tab, i| {
            if (removePanelFromNode(self.allocator, &tab.root, panel_id)) {
                // Clear active_panel_id if this was the active panel
                if (self.active_panel_id == panel_id) {
                    self.active_panel_id = null;
                }
                // If tab is now empty, remove it
                if (tab.root.panel_id == null and tab.root.first == null) {
                    tab.deinit(self.allocator);
                    self.allocator.destroy(tab);
                    _ = self.tabs.orderedRemove(i);
                }
                return;
            }
        }
    }

    fn removePanelFromNode(allocator: std.mem.Allocator, node_ptr: **SplitNode, panel_id: u32) bool {
        const node = node_ptr.*;

        if (node.panel_id) |pid| {
            if (pid == panel_id) {
                // This is a leaf node with the panel - mark as empty
                node.panel_id = null;
                return true;
            }
            return false;
        }

        // Check children
        if (node.first) |first| {
            if (first.panel_id) |pid| {
                if (pid == panel_id) {
                    // Remove first child, promote second
                    if (node.second) |second| {
                        allocator.destroy(first);
                        node.* = second.*;
                        allocator.destroy(second);
                    }
                    return true;
                }
            } else if (removePanelFromNode(allocator, &node.first.?, panel_id)) {
                return true;
            }
        }

        if (node.second) |second| {
            if (second.panel_id) |pid| {
                if (pid == panel_id) {
                    // Remove second child, promote first
                    if (node.first) |first| {
                        allocator.destroy(second);
                        node.* = first.*;
                        allocator.destroy(first);
                    }
                    return true;
                }
            } else if (removePanelFromNode(allocator, &node.second.?, panel_id)) {
                return true;
            }
        }

        return false;
    }

    // Serialize layout to JSON string
    pub fn toJson(self: *const Layout, allocator: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .{};
        const writer = buf.writer(allocator);

        try writer.writeAll("{\"tabs\":[");
        for (self.tabs.items, 0..) |tab, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print("{{\"id\":{},", .{tab.id});
            try writer.writeAll("\"root\":");
            try writeNodeJson(writer, tab.root);
            try writer.writeAll("}");
        }
        if (self.active_panel_id) |apid| {
            try writer.print("],\"activePanelId\":{}}}", .{apid});
        } else {
            try writer.writeAll("]}");
        }

        return buf.toOwnedSlice(allocator);
    }

    fn writeNodeJson(writer: anytype, node: *const SplitNode) !void {
        if (node.panel_id) |pid| {
            try writer.print("{{\"type\":\"leaf\",\"panelId\":{}}}", .{pid});
        } else if (node.direction) |dir| {
            const dir_str = if (dir == .horizontal) "horizontal" else "vertical";
            try writer.print("{{\"type\":\"split\",\"direction\":\"{s}\",\"ratio\":{d:.2},\"first\":", .{ dir_str, node.ratio });
            if (node.first) |first| {
                try writeNodeJson(writer, first);
            } else {
                try writer.writeAll("null");
            }
            try writer.writeAll(",\"second\":");
            if (node.second) |second| {
                try writeNodeJson(writer, second);
            } else {
                try writer.writeAll("null");
            }
            try writer.writeAll("}");
        } else {
            try writer.writeAll("null");
        }
    }
};


// Input Event Queue (for thread-safe input to ghostty)


const InputEvent = union(enum) {
    key: struct {
        input: c.ghostty_input_key_s,
        text_buf: [8]u8, // Buffer to store key text (null-terminated)
        text_len: u8,
    },
    text: struct { data: [256]u8, len: usize },
    mouse_pos: struct { x: f64, y: f64, mods: c.ghostty_input_mods_e },
    mouse_button: struct { state: c.ghostty_input_mouse_state_e, button: c.ghostty_input_mouse_button_e, mods: c.ghostty_input_mods_e },
    mouse_scroll: struct { x: f64, y: f64, dx: f64, dy: f64 },
    resize: struct { width: u32, height: u32 },
};


// Panel - One ghostty surface + streamer + websocket connection


// Import SharedMemory for Linux IPC
const SharedMemory = @import("shared_memory").SharedMemory;

/// Panel kind determines how a panel participates in layout and streaming.
/// All panels are the same underlying struct, but their kind affects:
/// - Whether they appear in the tab layout tree
/// - Whether they stream when not in the active tab
pub const PanelKind = enum(u8) {
    /// Regular panel inside a tab's split tree
    regular = 0,
    /// Quick terminal panel (not in any tab, always streams when open)
    quick_terminal = 1,
};

const Panel = struct {
    id: u32,
    kind: PanelKind,
    surface: c.ghostty_surface_t,
    // Platform-specific fields (comptime selected)
    nsview: if (is_macos) objc.id else void,
    window: if (is_macos) objc.id else void,
    shm: if (is_linux) ?SharedMemory else void, // Linux shared memory
    video_encoder: ?*video.VideoEncoder, // Lazy init on first frame
    bgra_buffer: ?[]u8, // For IOSurface/SharedMemory capture - lazy init
    sequence: u32,
    width: u32,
    height: u32,
    scale: f64,
    streaming: std.atomic.Value(bool),
    force_keyframe: bool,
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    input_queue: std.ArrayList(InputEvent),
    has_pending_input: std.atomic.Value(bool),
    last_input_time: std.atomic.Value(i64),  // Timestamp of last input for latency tracking (truncated ns)
    title: []const u8,  // Last known title
    pwd: []const u8,    // Last known working directory
    inspector_subscribed: bool,
    inspector_tab: [16]u8,
    inspector_tab_len: u8,
    last_iosurface_seed: u32, // For detecting IOSurface/SharedMemory changes
    last_frame_hash: u64, // For detecting unchanged frames on Linux
    last_frame_time: i128, // For per-panel adaptive FPS control
    last_tick_time: i128, // For rate limiting panel.tick()
    ticks_since_connect: u32, // Track frames since connection (for initial render delay)
    consecutive_unchanged: u32, // Consecutive frames with no pixel change (for adaptive frame rate)

    // Cursor state tracking (for frontend CSS blink overlay)
    last_cursor_col: u16 = 0,
    last_cursor_row: u16 = 0,
    last_cursor_style: u8 = 0,
    last_cursor_visible: u8 = 1,
    last_surf_w: u16 = 0,
    last_surf_h: u16 = 0,
    dbg_input_countdown: u32 = 0, // Debug: log N frames after input

    const TARGET_FPS: i64 = 30; // 30 FPS for video
    /// After this many consecutive unchanged frames, reduce tick rate to save CPU/GPU.
    /// At 30 FPS, 30 unchanged frames ≈ 1 second of idle.
    const IDLE_THRESHOLD: u32 = 30;
    /// When idle, only tick every Nth cycle (effectively ~3 FPS for cursor/spinner checks)
    const IDLE_DIVISOR: u32 = 10;
    const FRAME_INTERVAL_MS: i64 = 1000 / TARGET_FPS;

    fn init(allocator: std.mem.Allocator, app: c.ghostty_app_t, id: u32, width: u32, height: u32, scale: f64, working_directory: ?[]const u8, kind: PanelKind) !*Panel {
        const panel = try allocator.create(Panel);
        errdefer allocator.destroy(panel);

        // Frame buffer is at pixel dimensions (width * scale, height * scale)
        const pixel_width: u32 = @intFromFloat(@as(f64, @floatFromInt(width)) * scale);
        const pixel_height: u32 = @intFromFloat(@as(f64, @floatFromInt(height)) * scale);

        var surface_config = c.ghostty_surface_config_new();
        surface_config.scale_factor = scale;
        surface_config.userdata = panel;
        surface_config.command = null;

        // Set working directory for new shell
        const cwd_z: ?[:0]const u8 = if (working_directory) |wd|
            allocator.dupeZ(u8, wd) catch null
        else
            null;
        defer if (cwd_z) |z| allocator.free(z);
        surface_config.working_directory = if (cwd_z) |z| z.ptr else null;

        // Set environment variables for shell integration features
        // GHOSTTY_SHELL_FEATURES enables title updates if user has sourced ghostty shell integration
        var env_vars = [_]c.ghostty_env_var_s{
            .{ .key = "GHOSTTY_SHELL_FEATURES", .value = "cursor,title,sudo" },
        };
        surface_config.env_vars = &env_vars;
        surface_config.env_var_count = env_vars.len;

        // Platform-specific initialization
        var nsview_val: if (is_macos) objc.id else void = if (is_macos) null else {};
        var window_val: if (is_macos) objc.id else void = if (is_macos) null else {};
        var shm_val: if (is_linux) ?SharedMemory else void = if (is_linux) null else {};

        if (comptime is_macos) {
            // macOS: Create hidden window with NSView for Metal rendering
            const window_view = createHiddenWindow(width, height) orelse return error.WindowCreationFailed;
            makeViewLayerBacked(window_view.view, scale);

            surface_config.platform_tag = c.GHOSTTY_PLATFORM_MACOS;
            surface_config.platform.macos.nsview = @ptrCast(window_view.view);

            nsview_val = window_view.view;
            window_val = window_view.window;
        } else if (comptime is_linux) {
            // Linux: Create SharedMemory for pixel output
            const shm_size = @as(usize, pixel_width) * @as(usize, pixel_height) * 4; // BGRA
            var shm = SharedMemory.create("ghostty_panel", shm_size) catch return error.SharedMemoryFailed;
            errdefer shm.deinit();

            surface_config.platform_tag = c.GHOSTTY_PLATFORM_LINUX;
            surface_config.platform.linux_shm.shm_fd = @intCast(shm.fd);
            surface_config.platform.linux_shm.shm_ptr = @ptrCast(shm.mapped.ptr);
            surface_config.platform.linux_shm.shm_size = shm.size;

            shm_val = shm;
        }

        const surface = c.ghostty_surface_new(app, &surface_config);
        if (surface == null) return error.SurfaceCreationFailed;
        errdefer c.ghostty_surface_free(surface);

        // Tell ghostty the surface is visible (not occluded) so it renders properly
        // Note: we skip ghostty_surface_set_focus here — Surface.draw() syncs
        // renderer.focused from core_surface.focused every frame, and the render
        // loop manages focus transitions via set_focus_light.
        c.ghostty_surface_set_occlusion(surface, true);

        // Set size in pixels
        c.ghostty_surface_set_size(surface, pixel_width, pixel_height);

        // Force initial render to populate the FBO
        // This prevents blank/stale frames when the panel is first created
        c.ghostty_surface_draw(surface);

        panel.* = .{
            .id = id,
            .kind = kind,
            .surface = surface,
            .nsview = nsview_val,
            .window = window_val,
            .shm = shm_val,
            .video_encoder = null,
            .bgra_buffer = null,
            .sequence = 0,
            .width = width,
            .height = height,
            .scale = scale,
            .streaming = std.atomic.Value(bool).init(true),
            .force_keyframe = true,
            .allocator = allocator,
            .mutex = .{},
            .input_queue = .{},
            .has_pending_input = std.atomic.Value(bool).init(false),
            .last_input_time = std.atomic.Value(i64).init(0),
            .title = &.{},
            .pwd = &.{},
            .inspector_subscribed = false,
            .inspector_tab = undefined,
            .inspector_tab_len = 0,
            .last_iosurface_seed = 0,
            .last_frame_hash = 0,
            .last_frame_time = 0,
            .last_tick_time = 0,
            .ticks_since_connect = 0,
            .consecutive_unchanged = 0,
        };

        return panel;
    }

    fn deinit(self: *Panel) void {
        c.ghostty_surface_free(self.surface);
        if (self.video_encoder) |encoder| encoder.deinit();
        if (self.bgra_buffer) |buf| self.allocator.free(buf);
        self.input_queue.deinit(self.allocator);
        if (self.title.len > 0) self.allocator.free(self.title);
        if (self.pwd.len > 0) self.allocator.free(self.pwd);
        self.allocator.destroy(self);
    }

    fn startStreaming(self: *Panel) void {
        self.streaming.store(true, .release);
        self.force_keyframe = true;
        self.ticks_since_connect = 0;
        self.consecutive_unchanged = 0;
    }

    // Internal resize - called from main thread only (via processInputQueue)
    // width/height are in CSS pixels (points), scale may have been updated before this call
    fn resizeInternal(self: *Panel, width: u32, height: u32, new_scale: f64) !void {
        // Compute old pixel dims with OLD scale before any update
        const old_pw: u32 = @intFromFloat(@as(f64, @floatFromInt(self.width)) * self.scale);
        const old_ph: u32 = @intFromFloat(@as(f64, @floatFromInt(self.height)) * self.scale);

        // Update scale if provided (> 0)
        if (new_scale > 0) self.scale = new_scale;

        // Compute new pixel dims with (potentially updated) scale
        const pixel_width: u32 = @intFromFloat(@as(f64, @floatFromInt(width)) * self.scale);
        const pixel_height: u32 = @intFromFloat(@as(f64, @floatFromInt(height)) * self.scale);

        // Skip if resulting pixel dimensions haven't changed
        if (pixel_width == old_pw and pixel_height == old_ph and self.width == width) return;

        self.width = width;
        self.height = height;

        // Resize the NSWindow and NSView at point dimensions (macOS only)
        if (comptime is_macos) {
            resizeWindow(self.window, width, height);
        }

        c.ghostty_surface_set_size(self.surface, pixel_width, pixel_height);

        // Don't resize frame_buffer here - let captureFromIOSurface do it
        // when the IOSurface actually updates to the new size (at pixel dimensions)
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

    // Returns true if frame changed, false if identical to previous
    // macOS only - uses IOSurface for pixel capture (guarded at call site)
    const captureFromIOSurface = if (is_macos) captureFromIOSurfaceMacOS else void;

    fn captureFromIOSurfaceMacOS(self: *Panel, iosurface: IOSurfacePtr) !bool {
        // Check IOSurface seed - if unchanged, surface wasn't modified, skip copy entirely
        const seed = c.IOSurfaceGetSeed(iosurface);
        if (seed == self.last_iosurface_seed and !self.force_keyframe) {
            return false; // Surface unchanged, skip copy
        }
        self.last_iosurface_seed = seed;

        _ = c.IOSurfaceLock(iosurface, c.kIOSurfaceLockReadOnly, null);
        defer _ = c.IOSurfaceUnlock(iosurface, c.kIOSurfaceLockReadOnly, null);

        const base_addr: ?[*]u8 = @ptrCast(c.IOSurfaceGetBaseAddress(iosurface));
        if (base_addr == null) return error.NoBaseAddress;

        const src_bytes_per_row = c.IOSurfaceGetBytesPerRow(iosurface);
        const surf_width: u32 = @intCast(c.IOSurfaceGetWidth(iosurface));
        const surf_height: u32 = @intCast(c.IOSurfaceGetHeight(iosurface));
        const new_size = surf_width * surf_height * 4;

        // Lazy init video encoder and BGRA buffer on first frame capture
        if (self.video_encoder == null) {
            self.video_encoder = try video.VideoEncoder.init(self.allocator, surf_width, surf_height);
            self.bgra_buffer = try self.allocator.alloc(u8, new_size);
        } else if (new_size != self.bgra_buffer.?.len) {
            // Resize video encoder and buffer if needed
            try self.video_encoder.?.resize(surf_width, surf_height);
            self.allocator.free(self.bgra_buffer.?);
            self.bgra_buffer = try self.allocator.alloc(u8, new_size);
        }

        // Copy BGRA data
        const dst_bytes_per_row = surf_width * 4;
        if (src_bytes_per_row == dst_bytes_per_row) {
            // Fast path: single memcpy
            const total_bytes = surf_height * dst_bytes_per_row;
            @memcpy(self.bgra_buffer.?[0..total_bytes], base_addr.?[0..total_bytes]);
        } else {
            // Slow path: row by row
            for (0..surf_height) |y| {
                const src_offset = y * src_bytes_per_row;
                const dst_offset = y * dst_bytes_per_row;
                @memcpy(
                    self.bgra_buffer.?[dst_offset..][0..dst_bytes_per_row],
                    base_addr.?[src_offset..][0..dst_bytes_per_row],
                );
            }
        }

        return true;
    }

    fn prepareFrame(self: *Panel) !?struct { data: []const u8, is_keyframe: bool } {
        // FPS throttling is handled by runRenderLoop, no throttling here

        // Video encoder is lazily initialized in captureFromIOSurface
        if (self.video_encoder == null or self.bgra_buffer == null) {
            return null;
        }

        // Check if we need a keyframe
        const need_keyframe = self.force_keyframe or self.sequence == 0;
        if (need_keyframe) {
            self.force_keyframe = false;
        }

        // Encode frame using H.264 VideoToolbox
        const result = try self.video_encoder.?.encode(self.bgra_buffer.?, need_keyframe);
        if (result == null) return null;

        self.sequence +%= 1;

        return .{
            .data = result.?.data,
            .is_keyframe = result.?.is_keyframe,
        };
    }

    // OPTIMIZED: Encode directly from IOSurface when no scaling needed
    // Falls back to BGRA copy path when scaling is required
    fn prepareFrameFromIOSurface(self: *Panel, iosurface: IOSurfacePtr) !?struct { data: []const u8, is_keyframe: bool } {
        // Check IOSurface seed - if unchanged, surface wasn't modified, skip encoding
        const seed = c.IOSurfaceGetSeed(iosurface);
        if (seed == self.last_iosurface_seed and !self.force_keyframe) {
            return null; // Surface unchanged, skip encode
        }
        self.last_iosurface_seed = seed;

        const surf_width: u32 = @intCast(c.IOSurfaceGetWidth(iosurface));
        const surf_height: u32 = @intCast(c.IOSurfaceGetHeight(iosurface));
        const new_size = surf_width * surf_height * 4;

        // Lazy init video encoder on first frame
        if (self.video_encoder == null) {
            self.video_encoder = try video.VideoEncoder.init(self.allocator, surf_width, surf_height);
            // Only allocate BGRA buffer if scaling is needed
            if (!self.video_encoder.?.canEncodeDirectly()) {
                self.bgra_buffer = try self.allocator.alloc(u8, new_size);
            }
        } else if (surf_width != self.video_encoder.?.source_width or surf_height != self.video_encoder.?.source_height) {
            // Resize encoder if needed
            try self.video_encoder.?.resize(surf_width, surf_height);
            if (!self.video_encoder.?.canEncodeDirectly()) {
                if (self.bgra_buffer) |buf| self.allocator.free(buf);
                self.bgra_buffer = try self.allocator.alloc(u8, new_size);
            }
        }

        const need_keyframe = self.force_keyframe or self.sequence == 0;
        if (need_keyframe) {
            self.force_keyframe = false;
        }

        // Try zero-copy path if no scaling needed
        if (self.video_encoder.?.canEncodeDirectly()) {
            const result = self.video_encoder.?.encodeFromIOSurface(@ptrCast(iosurface), need_keyframe) catch |err| {
                // If direct encoding fails, fall back to BGRA path
                if (err == error.ScalingRequired) {
                    // Shouldn't happen since we checked canEncodeDirectly, but handle gracefully
                    return null;
                }
                return err;
            };
            if (result == null) return null;

            self.sequence +%= 1;
            return .{ .data = result.?.data, .is_keyframe = result.?.is_keyframe };
        }

        // Scaling needed - use BGRA copy path
        // Copy from IOSurface to BGRA buffer
        _ = c.IOSurfaceLock(iosurface, c.kIOSurfaceLockReadOnly, null);
        defer _ = c.IOSurfaceUnlock(iosurface, c.kIOSurfaceLockReadOnly, null);

        const base_addr: ?[*]u8 = @ptrCast(c.IOSurfaceGetBaseAddress(iosurface));
        if (base_addr == null) return error.NoBaseAddress;

        const src_bytes_per_row = c.IOSurfaceGetBytesPerRow(iosurface);
        const dst_bytes_per_row = surf_width * 4;

        if (src_bytes_per_row == dst_bytes_per_row) {
            @memcpy(self.bgra_buffer.?[0..new_size], base_addr.?[0..new_size]);
        } else {
            for (0..surf_height) |y| {
                const src_offset = y * src_bytes_per_row;
                const dst_offset = y * dst_bytes_per_row;
                @memcpy(self.bgra_buffer.?[dst_offset..][0..dst_bytes_per_row], base_addr.?[src_offset..][0..dst_bytes_per_row]);
            }
        }

        // Encode with scaling
        const result = try self.video_encoder.?.encode(self.bgra_buffer.?, need_keyframe);
        if (result == null) return null;

        self.sequence +%= 1;
        return .{ .data = result.?.data, .is_keyframe = result.?.is_keyframe };
    }

    /// Check if there's queued input (lock-free atomic check).
    fn hasQueuedInput(self: *Panel) bool {
        return self.has_pending_input.load(.acquire);
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
        self.has_pending_input.store(false, .release);
        // Reset adaptive idle mode so the next frame capture runs immediately.
        // Without this, processInputQueue clears has_pending_input before the
        // frame capture loop checks it, causing the idle skip to stay active.
        self.consecutive_unchanged = 0;
        // Debug: log the next 30 frames after input to see if hash changes
        self.dbg_input_countdown = 30;
        self.mutex.unlock();

        for (events_buf[0..events_count]) |*event| {
            switch (event.*) {
                .key => |*key_event| {
                    // Set text pointer to our stored buffer
                    if (key_event.text_len > 0) {
                        key_event.input.text = @ptrCast(&key_event.text_buf);
                    }
                    _ = c.ghostty_surface_key(self.surface, key_event.input);
                },
                .text => |text| {
                    c.ghostty_surface_text(self.surface, &text.data, text.len);
                },
                .mouse_pos => |pos| {
                    c.ghostty_surface_mouse_pos(self.surface, pos.x, pos.y, pos.mods);
                },
                .mouse_button => |btn| {
                    // Send position first, then button event.
                    // ghostty_surface_mouse_button may trigger selection/clipboard
                    // operations internally.
                    _ = c.ghostty_surface_mouse_button(self.surface, btn.state, btn.button, btn.mods);
                },
                .mouse_scroll => |scroll| {
                    c.ghostty_surface_mouse_pos(self.surface, scroll.x, scroll.y, 0);
                    c.ghostty_surface_mouse_scroll(self.surface, scroll.dx, scroll.dy, 0);
                },
                .resize => |size| {
                    self.resizeInternal(size.width, size.height, 0) catch {};
                },
            }
        }
    }

    fn tick(self: *Panel) void {
        c.ghostty_surface_draw(self.surface);
        // Track ticks for initial render delay (capped to avoid overflow)
        if (self.ticks_since_connect < 100) {
            self.ticks_since_connect += 1;
        }
    }

    fn getPixelWidth(self: *const Panel) u32 {
        return @intFromFloat(@as(f64, @floatFromInt(self.width)) * self.scale);
    }

    fn getPixelHeight(self: *const Panel) u32 {
        return @intFromFloat(@as(f64, @floatFromInt(self.height)) * self.scale);
    }

    // macOS only - get IOSurface from NSView (guarded at call site)
    const getIOSurface = if (is_macos) getIOSurfaceMacOS else void;

    fn getIOSurfaceMacOS(self: *Panel) ?IOSurfacePtr {
        return getIOSurfaceFromView(self.nsview);
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

    // Map JS e.code to native keycode (platform-specific)
    // macOS uses virtual keycodes, Linux uses XKB keycodes
    fn mapKeyCode(code: []const u8) u32 {
        // Use comptime string map for efficient lookup
        // Values from Chromium's dom_code_data.inc via ghostty/src/input/keycodes.zig
        const map = if (comptime is_linux)
            // Linux XKB keycodes
            std.StaticStringMap(u32).initComptime(.{
                // Writing System Keys
                .{ "Backquote", 0x0031 },
                .{ "Backslash", 0x0033 },
                .{ "BracketLeft", 0x0022 },
                .{ "BracketRight", 0x0023 },
                .{ "Comma", 0x003b },
                .{ "Digit0", 0x0013 },
                .{ "Digit1", 0x000a },
                .{ "Digit2", 0x000b },
                .{ "Digit3", 0x000c },
                .{ "Digit4", 0x000d },
                .{ "Digit5", 0x000e },
                .{ "Digit6", 0x000f },
                .{ "Digit7", 0x0010 },
                .{ "Digit8", 0x0011 },
                .{ "Digit9", 0x0012 },
                .{ "Equal", 0x0015 },
                .{ "IntlBackslash", 0x005e },
                .{ "KeyA", 0x0026 },
                .{ "KeyB", 0x0038 },
                .{ "KeyC", 0x0036 },
                .{ "KeyD", 0x0028 },
                .{ "KeyE", 0x001a },
                .{ "KeyF", 0x0029 },
                .{ "KeyG", 0x002a },
                .{ "KeyH", 0x002b },
                .{ "KeyI", 0x001f },
                .{ "KeyJ", 0x002c },
                .{ "KeyK", 0x002d },
                .{ "KeyL", 0x002e },
                .{ "KeyM", 0x003a },
                .{ "KeyN", 0x0039 },
                .{ "KeyO", 0x0020 },
                .{ "KeyP", 0x0021 },
                .{ "KeyQ", 0x0018 },
                .{ "KeyR", 0x001b },
                .{ "KeyS", 0x0027 },
                .{ "KeyT", 0x001c },
                .{ "KeyU", 0x001e },
                .{ "KeyV", 0x0037 },
                .{ "KeyW", 0x0019 },
                .{ "KeyX", 0x0035 },
                .{ "KeyY", 0x001d },
                .{ "KeyZ", 0x0034 },
                .{ "Minus", 0x0014 },
                .{ "Period", 0x003c },
                .{ "Quote", 0x0030 },
                .{ "Semicolon", 0x002f },
                .{ "Slash", 0x003d },
                // Modifier Keys
                .{ "AltLeft", 0x0040 },
                .{ "AltRight", 0x006c },
                .{ "ControlLeft", 0x0025 },
                .{ "ControlRight", 0x0069 },
                .{ "MetaLeft", 0x0085 },
                .{ "MetaRight", 0x0086 },
                .{ "ShiftLeft", 0x0032 },
                .{ "ShiftRight", 0x003e },
                // Functional Keys
                .{ "Backspace", 0x0016 },
                .{ "CapsLock", 0x0042 },
                .{ "ContextMenu", 0x0087 },
                .{ "Enter", 0x0024 },
                .{ "Space", 0x0041 },
                .{ "Tab", 0x0017 },
                // Control Pad
                .{ "Delete", 0x0077 },
                .{ "End", 0x0073 },
                .{ "Home", 0x006e },
                .{ "Insert", 0x0076 },
                .{ "PageDown", 0x0075 },
                .{ "PageUp", 0x0070 },
                // Arrow Keys
                .{ "ArrowDown", 0x0074 },
                .{ "ArrowLeft", 0x0071 },
                .{ "ArrowRight", 0x0072 },
                .{ "ArrowUp", 0x006f },
                // Numpad
                .{ "NumLock", 0x004d },
                .{ "Numpad0", 0x005a },
                .{ "Numpad1", 0x0057 },
                .{ "Numpad2", 0x0058 },
                .{ "Numpad3", 0x0059 },
                .{ "Numpad4", 0x0053 },
                .{ "Numpad5", 0x0054 },
                .{ "Numpad6", 0x0055 },
                .{ "Numpad7", 0x004f },
                .{ "Numpad8", 0x0050 },
                .{ "Numpad9", 0x0051 },
                .{ "NumpadAdd", 0x0056 },
                .{ "NumpadDecimal", 0x005b },
                .{ "NumpadDivide", 0x006a },
                .{ "NumpadEnter", 0x0068 },
                .{ "NumpadEqual", 0x007d },
                .{ "NumpadMultiply", 0x003f },
                .{ "NumpadSubtract", 0x0052 },
                // Function Keys
                .{ "Escape", 0x0009 },
                .{ "F1", 0x0043 },
                .{ "F2", 0x0044 },
                .{ "F3", 0x0045 },
                .{ "F4", 0x0046 },
                .{ "F5", 0x0047 },
                .{ "F6", 0x0048 },
                .{ "F7", 0x0049 },
                .{ "F8", 0x004a },
                .{ "F9", 0x004b },
                .{ "F10", 0x004c },
                .{ "F11", 0x005f },
                .{ "F12", 0x0060 },
                // Media/Browser Keys
                .{ "PrintScreen", 0x006b },
                .{ "ScrollLock", 0x004e },
                .{ "Pause", 0x007f },
            })
        else
            // macOS virtual keycodes
            std.StaticStringMap(u32).initComptime(.{
                // Writing System Keys
                .{ "Backquote", 0x32 },
                .{ "Backslash", 0x2a },
                .{ "BracketLeft", 0x21 },
                .{ "BracketRight", 0x1e },
                .{ "Comma", 0x2b },
                .{ "Digit0", 0x1d },
                .{ "Digit1", 0x12 },
                .{ "Digit2", 0x13 },
                .{ "Digit3", 0x14 },
                .{ "Digit4", 0x15 },
                .{ "Digit5", 0x17 },
                .{ "Digit6", 0x16 },
                .{ "Digit7", 0x1a },
                .{ "Digit8", 0x1c },
                .{ "Digit9", 0x19 },
                .{ "Equal", 0x18 },
                .{ "IntlBackslash", 0x0a },
                .{ "KeyA", 0x00 },
                .{ "KeyB", 0x0b },
                .{ "KeyC", 0x08 },
                .{ "KeyD", 0x02 },
                .{ "KeyE", 0x0e },
                .{ "KeyF", 0x03 },
                .{ "KeyG", 0x05 },
                .{ "KeyH", 0x04 },
                .{ "KeyI", 0x22 },
                .{ "KeyJ", 0x26 },
                .{ "KeyK", 0x28 },
                .{ "KeyL", 0x25 },
                .{ "KeyM", 0x2e },
                .{ "KeyN", 0x2d },
                .{ "KeyO", 0x1f },
                .{ "KeyP", 0x23 },
                .{ "KeyQ", 0x0c },
                .{ "KeyR", 0x0f },
                .{ "KeyS", 0x01 },
                .{ "KeyT", 0x11 },
                .{ "KeyU", 0x20 },
                .{ "KeyV", 0x09 },
                .{ "KeyW", 0x0d },
                .{ "KeyX", 0x07 },
                .{ "KeyY", 0x10 },
                .{ "KeyZ", 0x06 },
                .{ "Minus", 0x1b },
                .{ "Period", 0x2f },
                .{ "Quote", 0x27 },
                .{ "Semicolon", 0x29 },
                .{ "Slash", 0x2c },
                // Modifier Keys
                .{ "AltLeft", 0x3a },
                .{ "AltRight", 0x3d },
                .{ "ControlLeft", 0x3b },
                .{ "ControlRight", 0x3e },
                .{ "MetaLeft", 0x37 },
                .{ "MetaRight", 0x36 },
                .{ "ShiftLeft", 0x38 },
                .{ "ShiftRight", 0x3c },
                // Functional Keys
                .{ "Backspace", 0x33 },
                .{ "CapsLock", 0x39 },
                .{ "ContextMenu", 0x6e },
                .{ "Enter", 0x24 },
                .{ "Space", 0x31 },
                .{ "Tab", 0x30 },
                // Control Pad
                .{ "Delete", 0x75 },
                .{ "End", 0x77 },
                .{ "Home", 0x73 },
                .{ "Insert", 0x72 },
                .{ "PageDown", 0x79 },
                .{ "PageUp", 0x74 },
                // Arrow Keys
                .{ "ArrowDown", 0x7d },
                .{ "ArrowLeft", 0x7b },
                .{ "ArrowRight", 0x7c },
                .{ "ArrowUp", 0x7e },
                // Numpad
                .{ "NumLock", 0x47 },
                .{ "Numpad0", 0x52 },
                .{ "Numpad1", 0x53 },
                .{ "Numpad2", 0x54 },
                .{ "Numpad3", 0x55 },
                .{ "Numpad4", 0x56 },
                .{ "Numpad5", 0x57 },
                .{ "Numpad6", 0x58 },
                .{ "Numpad7", 0x59 },
                .{ "Numpad8", 0x5b },
                .{ "Numpad9", 0x5c },
                .{ "NumpadAdd", 0x45 },
                .{ "NumpadDecimal", 0x41 },
                .{ "NumpadDivide", 0x4b },
                .{ "NumpadEnter", 0x4c },
                .{ "NumpadEqual", 0x51 },
                .{ "NumpadMultiply", 0x43 },
                .{ "NumpadSubtract", 0x4e },
                // Function Keys
                .{ "Escape", 0x35 },
                .{ "F1", 0x7a },
                .{ "F2", 0x78 },
                .{ "F3", 0x63 },
                .{ "F4", 0x76 },
                .{ "F5", 0x60 },
                .{ "F6", 0x61 },
                .{ "F7", 0x62 },
                .{ "F8", 0x64 },
                .{ "F9", 0x65 },
                .{ "F10", 0x6d },
                .{ "F11", 0x67 },
                .{ "F12", 0x6f },
                // Media/Browser Keys
                .{ "PrintScreen", 0x69 },
                .{ "ScrollLock", 0x6b },
                .{ "Pause", 0x71 },
            });
        return map.get(code) orelse 0xFFFF; // Invalid keycode
    }

    // Handle keyboard input from client (queues event for main thread)
    // Format: [action:u8][mods:u8][code_len:u8][code:...][text_len:u8][text:...]
    fn handleKeyInput(self: *Panel, data: []const u8) void {
        if (data.len < 4) return;

        const action = data[0];
        const mods = data[1];
        const code_len = data[2];

        if (data.len < 4 + code_len) return;
        const code = data[3 .. 3 + code_len];

        const text_offset = 3 + code_len;
        if (data.len <= text_offset) return;
        const text_len: u8 = @min(data[text_offset], 7);

        const text_start = text_offset + 1;

        // Map JS code to macOS keycode
        const keycode = mapKeyCode(code);

        // Compute unshifted codepoint
        var unshifted: u32 = 0;
        if (text_len == 1 and data.len > text_start) {
            const ch = data[text_start];
            unshifted = if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
        }

        var event: InputEvent = .{ .key = .{
            .input = c.ghostty_input_key_s{
                .action = switch (action) {
                    0 => c.GHOSTTY_ACTION_RELEASE,
                    1 => c.GHOSTTY_ACTION_PRESS,
                    2 => c.GHOSTTY_ACTION_REPEAT,
                    else => c.GHOSTTY_ACTION_PRESS,
                },
                .keycode = keycode,
                .mods = convertMods(mods),
                .consumed_mods = 0,
                .text = null,
                .unshifted_codepoint = unshifted,
                .composing = false,
            },
            .text_buf = undefined,
            .text_len = text_len,
        } };

        // Copy text to buffer
        if (text_len > 0 and data.len >= text_start + text_len) {
            @memcpy(event.key.text_buf[0..text_len], data[text_start .. text_start + text_len]);
            event.key.text_buf[text_len] = 0;
        }

        self.mutex.lock();
        defer self.mutex.unlock();
        self.input_queue.append(self.allocator, event) catch {};
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
    // Format: [x:f64][y:f64][button:u8][state:u8][mods:u8] = 19 bytes
    fn handleMouseButton(self: *Panel, data: []const u8) void {
        if (data.len < 19) return;

        const x: f64 = @bitCast(std.mem.readInt(u64, data[0..8], .little));
        const y: f64 = @bitCast(std.mem.readInt(u64, data[8..16], .little));
        const button_byte = data[16];
        const state_byte = data[17];
        const mods = convertMods(data[18]);

        const state: c.ghostty_input_mouse_state_e = if (state_byte == 1)
            c.GHOSTTY_MOUSE_PRESS
        else
            c.GHOSTTY_MOUSE_RELEASE;

        const button: c.ghostty_input_mouse_button_e = switch (button_byte) {
            0 => c.GHOSTTY_MOUSE_LEFT,
            1 => c.GHOSTTY_MOUSE_RIGHT,
            2 => c.GHOSTTY_MOUSE_MIDDLE,
            else => c.GHOSTTY_MOUSE_LEFT,
        };

        self.mutex.lock();
        defer self.mutex.unlock();
        // Queue position update first, then button event
        self.input_queue.append(self.allocator, .{ .mouse_pos = .{ .x = x, .y = y, .mods = mods } }) catch {};
        self.input_queue.append(self.allocator, .{ .mouse_button = .{ .state = state, .button = button, .mods = mods } }) catch {};
    }

    // Handle mouse move - queues event for main thread
    // Format: [x:f64][y:f64][mods:u8] = 17 bytes
    fn handleMouseMove(self: *Panel, data: []const u8) void {
        if (data.len < 17) return;

        const x: f64 = @bitCast(std.mem.readInt(u64, data[0..8], .little));
        const y: f64 = @bitCast(std.mem.readInt(u64, data[8..16], .little));
        const mods = convertMods(data[16]);

        self.mutex.lock();
        defer self.mutex.unlock();
        self.input_queue.append(self.allocator, .{ .mouse_pos = .{ .x = x, .y = y, .mods = mods } }) catch {};
    }

    // Handle mouse scroll - queues events for main thread
    // Format: [x:f64][y:f64][dx:f64][dy:f64][mods:u8] = 33 bytes
    fn handleMouseScroll(self: *Panel, data: []const u8) void {
        if (data.len < 33) return;

        const x: f64 = @bitCast(std.mem.readInt(u64, data[0..8], .little));
        const y: f64 = @bitCast(std.mem.readInt(u64, data[8..16], .little));
        const dx: f64 = @bitCast(std.mem.readInt(u64, data[16..24], .little));
        const dy: f64 = @bitCast(std.mem.readInt(u64, data[24..32], .little));
        const mods = convertMods(data[32]);

        self.mutex.lock();
        defer self.mutex.unlock();
        // Queue position update first, then scroll event
        self.input_queue.append(self.allocator, .{ .mouse_pos = .{ .x = x, .y = y, .mods = mods } }) catch {};
        self.input_queue.append(self.allocator, .{ .mouse_scroll = .{ .x = x, .y = y, .dx = dx, .dy = dy } }) catch {};
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
            .buffer_stats => self.handleBufferStats(payload),
            // Inspector messages are handled in Server.onPanelMessage (needs server access)
            .inspector_subscribe, .inspector_unsubscribe, .inspector_tab => {},
            // Connection-level commands - handled in Server.onPanelMessage before reaching panel
            .connect_panel, .create_panel, .split_panel => {},
        }
    }

    // Handle buffer stats from client for adaptive quality (AIMD tiered system).
    // Client sends: [health:u8][fps:u8][buffer_ms:u16] every ~1s.
    fn handleBufferStats(self: *Panel, payload: []const u8) void {
        if (payload.len < 4) return;

        const health = payload[0]; // 0-100: buffer health (100 = all frames consumed)

        if (self.video_encoder) |encoder| {
            encoder.adjustQuality(health);
        }
    }
};


// Server - manages multiple panels and WebSocket connections


// Panel creation request (to be processed on main thread)
const PanelRequest = struct {
    width: u32,
    height: u32,
    scale: f64,
    inherit_cwd_from: u32, // Panel ID to inherit CWD from, 0 = use initial_cwd
    kind: PanelKind,
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
    scale: f64, // 0 = keep existing panel.scale
};

// Panel split request (to be processed on main thread)
const PanelSplitRequest = struct {
    parent_panel_id: u32,
    direction: SplitDirection,
    width: u32,
    height: u32,
    scale: f64,
};

const Server = struct {
    // Ghostty app/config - lazy initialized on first panel, freed when last panel closes
    app: ?c.ghostty_app_t,
    config: ?c.ghostty_config_t,
    panels: std.AutoHashMap(u32, *Panel),
    h264_connections: std.ArrayList(*ws.Connection),
    control_connections: std.ArrayList(*ws.Connection),
    file_connections: std.ArrayList(*ws.Connection),
    connection_roles: std.AutoHashMap(*ws.Connection, auth.Role),  // Track connection roles
    control_client_ids: std.AutoHashMap(*ws.Connection, u32),  // Track client IDs per control connection
    // Multiplayer: pane assignment state
    panel_assignments: std.AutoHashMap(u32, []const u8),  // panel_id → session_id
    connection_sessions: std.AutoHashMap(*ws.Connection, []const u8),  // conn → session_id (cached)
    main_client_id: u32,       // ID of current main client (0 = none)
    next_client_id: u32,       // Counter for assigning client IDs
    layout: Layout,
    pending_panels_ch: *Channel(PanelRequest),
    pending_destroys_ch: *Channel(PanelDestroyRequest),
    pending_resizes_ch: *Channel(PanelResizeRequest),
    pending_splits_ch: *Channel(PanelSplitRequest),
    next_panel_id: u32,
    h264_ws_server: *ws.Server,
    control_ws_server: *ws.Server,
    file_ws_server: *ws.Server,
    http_server: *http.HttpServer,
    auth_state: *auth.AuthState,  // Session and access control
    transfer_manager: transfer.TransferManager,
    running: std.atomic.Value(bool),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    selection_clipboard: ?[]u8,  // Selection clipboard buffer
    standard_clipboard: ?[]u8,  // Standard clipboard buffer (from browser paste)
    initial_cwd: []const u8,  // CWD where termweb was started
    initial_cwd_allocated: bool,  // Whether initial_cwd was allocated (vs static "/")
    overview_open: bool,  // Whether tab overview is currently open
    quick_terminal_open: bool,  // Whether quick terminal is open
    inspector_open: bool,  // Whether inspector is open
    shared_va_ctx: if (is_linux) ?video.SharedVaContext else void,  // Shared VA-API context for fast encoder init
    wake_signal: WakeSignal,  // Event-driven wakeup for render loop (replaces sleep polling)
    goroutine_rt: *goroutine_runtime.Runtime, // M:N goroutine scheduler for file transfer pipeline

    var global_server: std.atomic.Value(?*Server) = std.atomic.Value(?*Server).init(null);

    fn init(allocator: std.mem.Allocator, http_port: u16, control_port: u16, panel_port: u16) !*Server {
        const server = try allocator.create(Server);
        errdefer allocator.destroy(server);

        // Ghostty is lazy-initialized on first panel creation (scale to zero)

        // Create HTTP server for static files (no ghostty config needed initially)
        const http_srv = try http.HttpServer.init(allocator, "0.0.0.0", http_port, null);

        // Create control WebSocket server (zstd-compressed control traffic)
        const control_ws = try ws.Server.init(allocator, "0.0.0.0", control_port);
        control_ws.setCallbacks(onControlConnect, onControlMessage, onControlDisconnect);

        // Create file transfer WebSocket server (zstd-compressed file transfers)
        const file_ws = try ws.Server.init(allocator, "0.0.0.0", 0);
        file_ws.setCallbacks(onFileConnect, onFileMessage, onFileDisconnect);

        // Create H264 WebSocket server (pre-compressed video, no zstd)
        // Short write timeout: video frames are droppable, don't block render loop
        const h264_ws = try ws.Server.initNoCompression(allocator, "0.0.0.0", panel_port);
        h264_ws.send_timeout_ms = 10; // 10ms — drop frame rather than stall
        h264_ws.setCallbacks(onH264Connect, onH264Message, onH264Disconnect);

        // Initialize auth state
        const auth_state = try auth.AuthState.init(allocator);

        // Create inter-thread message channels (replaces mutex-protected ArrayLists)
        const pending_panels_ch = try Channel(PanelRequest).initBuffered(allocator, 64);
        errdefer pending_panels_ch.deinit();
        const pending_destroys_ch = try Channel(PanelDestroyRequest).initBuffered(allocator, 64);
        errdefer pending_destroys_ch.deinit();
        const pending_resizes_ch = try Channel(PanelResizeRequest).initBuffered(allocator, 64);
        errdefer pending_resizes_ch.deinit();
        const pending_splits_ch = try Channel(PanelSplitRequest).initBuffered(allocator, 64);
        errdefer pending_splits_ch.deinit();

        // Initialize goroutine runtime for file transfer pipeline (0 = auto-detect CPU count)
        const gor_rt = try goroutine_runtime.Runtime.init(allocator, 0);
        errdefer gor_rt.deinit();

        server.* = .{
            .app = null, // Lazy init on first panel
            .config = null,
            .panels = std.AutoHashMap(u32, *Panel).init(allocator),
            .h264_connections = .{},
            .control_connections = .{},
            .file_connections = .{},
            .connection_roles = std.AutoHashMap(*ws.Connection, auth.Role).init(allocator),
            .control_client_ids = std.AutoHashMap(*ws.Connection, u32).init(allocator),
            .panel_assignments = std.AutoHashMap(u32, []const u8).init(allocator),
            .connection_sessions = std.AutoHashMap(*ws.Connection, []const u8).init(allocator),
            .main_client_id = 0,
            .next_client_id = 1,
            .layout = Layout.init(allocator),
            .pending_panels_ch = pending_panels_ch,
            .pending_destroys_ch = pending_destroys_ch,
            .pending_resizes_ch = pending_resizes_ch,
            .pending_splits_ch = pending_splits_ch,
            .next_panel_id = 1,
            .http_server = http_srv,
            .h264_ws_server = h264_ws,
            .control_ws_server = control_ws,
            .file_ws_server = file_ws,
            .auth_state = auth_state,
            .transfer_manager = transfer.TransferManager.init(allocator),
            .running = std.atomic.Value(bool).init(false),
            .allocator = allocator,
            .mutex = .{},
            .selection_clipboard = null,
            .standard_clipboard = null,
            .initial_cwd = undefined,
            .initial_cwd_allocated = false,
            .overview_open = false,
            .quick_terminal_open = false,
            .inspector_open = false,
            .shared_va_ctx = if (is_linux) blk: {
                break :blk video.SharedVaContext.init() catch |err| {
                    std.debug.print("VAAPI: SharedVaContext init failed: {}, encoders will be unavailable\n", .{err});
                    break :blk null;
                };
            } else {},
            .wake_signal = WakeSignal.init() catch return error.WakeSignalInit,
            .goroutine_rt = gor_rt,
        };

        // Get current working directory (fallback to "/" if unavailable)
        if (std.fs.cwd().realpathAlloc(allocator, ".")) |cwd| {
            server.initial_cwd = cwd;
            server.initial_cwd_allocated = true;
        } else |_| {
            server.initial_cwd = "/";
            server.initial_cwd_allocated = false;
        }

        global_server.store(server, .release);
        return server;
    }

    // Lazy initialize ghostty when first panel is created
    fn ensureGhosttyInit(self: *Server) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.app != null) return; // Already initialized

        const init_result = c.ghostty_init(0, null);
        if (init_result != c.GHOSTTY_SUCCESS) return error.GhosttyInitFailed;

        // Load ghostty config: termweb defaults first, then user overrides
        const config = c.ghostty_config_new();

        // Write termweb defaults to temp file (user's ghostty config overrides these)
        const defaults_path = "/tmp/termweb-ghostty-defaults.conf";
        if (std.fs.cwd().createFile(defaults_path, .{})) |f| {
            defer f.close();
            f.writeAll("cursor-style = bar\ncursor-style-blink = false\ncursor-opacity = 0\n") catch {};
            c.ghostty_config_load_file(config, defaults_path);
        } else |_| {}

        c.ghostty_config_load_default_files(config);
        c.ghostty_config_finalize(config);

        const runtime_config = c.ghostty_runtime_config_s{
            .userdata = null,
            .supports_selection_clipboard = true,
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

        self.app = app;
        self.config = config;
    }

    // Free ghostty when last panel is closed (scale to zero)
    // Note: caller should NOT hold mutex when calling this (we acquire it internally)
    fn freeGhosttyIfEmpty(self: *Server) void {
        self.mutex.lock();

        if (self.panels.count() > 0) {
            self.mutex.unlock();
            return; // Still have panels
        }
        if (self.app == null) {
            self.mutex.unlock();
            return; // Already freed
        }

        // Take ownership of app/config while holding mutex
        const app = self.app.?;
        const cfg = self.config.?;
        self.app = null;
        self.config = null;
        self.mutex.unlock();

        // Free outside mutex to avoid blocking panel creation
        c.ghostty_app_free(app);
        c.ghostty_config_free(cfg);
    }

    fn deinit(self: *Server) void {
        self.running.store(false, .release);

        // Cancel all active file transfers so goroutines and handler threads exit
        self.transfer_manager.cancelAll();

        // Signal goroutine runtime shutdown early so GChannel operations
        // on OS threads return immediately (unblocks handler threads)
        self.goroutine_rt.signalShutdown();

        // Close channels to unblock any blocked senders before WS server shutdown
        self.pending_panels_ch.close();
        self.pending_destroys_ch.close();
        self.pending_resizes_ch.close();
        self.pending_splits_ch.close();

        // Clear global_server first to prevent callbacks from accessing it during shutdown
        global_server.store(null, .release);

        // Shut down WebSocket servers first and wait for all connection threads to finish
        // This must happen BEFORE destroying panels to avoid use-after-free
        self.http_server.deinit();
        self.h264_ws_server.deinit();
        self.control_ws_server.deinit();
        self.file_ws_server.deinit();

        // Now safe to destroy panels since all connection threads have finished
        var panel_it = self.panels.valueIterator();
        while (panel_it.next()) |panel| {
            panel.*.deinit();
        }
        self.panels.deinit();
        self.h264_connections.deinit(self.allocator);
        self.control_connections.deinit(self.allocator);
        self.file_connections.deinit(self.allocator);
        self.layout.deinit();
        self.pending_panels_ch.deinit();
        self.pending_destroys_ch.deinit();
        self.pending_resizes_ch.deinit();
        self.pending_splits_ch.deinit();

        self.auth_state.deinit();
        self.transfer_manager.deinit();
        self.connection_roles.deinit();
        self.control_client_ids.deinit();
        if (self.selection_clipboard) |clip| self.allocator.free(clip);
        if (self.standard_clipboard) |clip| self.allocator.free(clip);
        if (self.initial_cwd_allocated) self.allocator.free(@constCast(self.initial_cwd));
        // Free shared VA-API context (after all panels/encoders are destroyed)
        self.wake_signal.deinit();
        if (is_linux) {
            if (self.shared_va_ctx) |*ctx| ctx.deinit();
        }
        // Shutdown goroutine runtime (waits for all goroutines to complete)
        self.goroutine_rt.deinit();
        // Only free ghostty if it was initialized
        if (self.app) |app| c.ghostty_app_free(app);
        if (self.config) |cfg| c.ghostty_config_free(cfg);
        self.allocator.destroy(self);
    }

    fn createPanel(self: *Server, width: u32, height: u32, scale: f64) !*Panel {
        return self.createPanelWithOptions(width, height, scale, self.initial_cwd, .regular);
    }

    fn createPanelWithOptions(self: *Server, width: u32, height: u32, scale: f64, working_directory: ?[]const u8, kind: PanelKind) !*Panel {
        // Lazy init ghostty on first panel (scale to zero)
        // ensureGhosttyInit handles its own mutex
        try self.ensureGhosttyInit();

        // Now lock for panel creation - app is guaranteed valid after ensureGhosttyInit
        self.mutex.lock();
        defer self.mutex.unlock();

        // Double-check app is still valid (in case of rapid close/reopen race)
        if (self.app == null) return error.GhosttyNotInitialized;

        const id = self.next_panel_id;
        self.next_panel_id += 1;

        const panel = try Panel.init(self.allocator, self.app.?, id, width, height, scale, working_directory, kind);
        try self.panels.put(id, panel);

        // Only add to layout for regular panels (quick terminal lives outside the tab tree)
        if (kind == .regular) {
            _ = self.layout.createTab(id) catch {};
        }

        return panel;
    }

    // Create a panel as a split of an existing panel (doesn't create a new tab)
    fn createPanelAsSplit(self: *Server, width: u32, height: u32, scale: f64, parent_panel_id: u32, direction: SplitDirection) !*Panel {
        // Lazy init ghostty on first panel (scale to zero)
        // ensureGhosttyInit handles its own mutex
        try self.ensureGhosttyInit();

        // Now lock for panel creation
        self.mutex.lock();
        defer self.mutex.unlock();

        // Double-check app is still valid (in case of rapid close/reopen race)
        if (self.app == null) return error.GhosttyNotInitialized;

        // Get parent panel's pwd for inheritance
        const working_directory: ?[]const u8 = if (self.panels.get(parent_panel_id)) |parent|
            if (parent.pwd.len > 0) parent.pwd else self.initial_cwd
        else
            self.initial_cwd;

        const id = self.next_panel_id;
        self.next_panel_id += 1;

        const panel = try Panel.init(self.allocator, self.app.?, id, width, height, scale, working_directory, .regular);
        try self.panels.put(id, panel);

        // Add to layout as a split of the parent panel
        self.layout.splitPanel(parent_panel_id, direction, id) catch |err| {
            std.debug.print("Failed to split panel in layout: {}\n", .{err});
            // Fall back to creating a new tab
            _ = self.layout.createTab(id) catch {};
        };

        return panel;
    }

    fn destroyPanel(self: *Server, id: u32) void {
        var panel_to_deinit: ?*Panel = null;

        {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.panels.fetchRemove(id)) |entry| {
                panel_to_deinit = entry.value;
            }
        }

        // Deinit panel outside mutex
        if (panel_to_deinit) |panel| {
            panel.deinit();
        }

        // Free ghostty if no panels left (scale to zero)
        self.freeGhosttyIfEmpty();
    }

    fn getPanel(self: *Server, id: u32) ?*Panel {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.panels.get(id);
    }

    fn tick(self: *Server) void {
        // Only tick if ghostty is initialized
        if (self.app) |app| c.ghostty_app_tick(app);
    }

    // --- Control WebSocket callbacks---

    fn onControlConnect(conn: *ws.Connection) void {
        const self = global_server.load(.acquire) orelse return;

        var is_new_main = false;
        var client_id: u32 = 0;

        self.mutex.lock();
        self.control_connections.append(self.allocator, conn) catch {};

        // Assign client ID
        client_id = self.next_client_id;
        self.next_client_id += 1;
        self.control_client_ids.put(conn, client_id) catch {};

        // Elect main client if none exists
        if (self.main_client_id == 0) {
            self.main_client_id = client_id;
            is_new_main = true;
        }
        self.mutex.unlock();

        // Resolve token → session_id and cache for multiplayer
        if (conn.request_uri) |uri| {
            if (auth.extractTokenFromQuery(uri)) |token| {
                if (auth.getSessionIdForToken(self.auth_state, token)) |session_id| {
                    const duped = self.allocator.dupe(u8, session_id) catch null;
                    if (duped) |s| {
                        self.mutex.lock();
                        self.connection_sessions.put(conn, s) catch {};
                        self.mutex.unlock();
                    }
                }
            }
        }

        // Send auth state first (so client knows its role)
        self.sendAuthState(conn);

        // Send main client state before panel list so client knows its role
        // before creating panels (prevents non-main from connecting panel WS)
        self.sendMainClientState(conn, client_id);

        // Send current panel list
        self.sendPanelList(conn);

        // Send UI states (for persistence across page reloads and shared sessions)
        self.sendOverviewState(conn);
        self.sendQuickTerminalState(conn);
        self.sendInspectorOpenState(conn);

        // Send session identity (so client knows its own session_id)
        self.sendSessionIdentity(conn);

        // Send current panel assignments to newly connected client
        self.sendAllPanelAssignments(conn);

        // Send current cursor state for all panels so cursor appears immediately
        self.sendCursorStateToConn(conn);

        // Send client list to admin(s)
        self.sendClientListToAdmins();

        // If new main elected, broadcast so existing clients update
        if (is_new_main) {
            self.broadcastMainClientState();
        }
    }

    fn onControlMessage(conn: *ws.Connection, data: []u8, is_binary: bool) void {
        _ = is_binary;
        const self = global_server.load(.acquire) orelse return;
        if (data.len == 0) return;

        const msg_type = data[0];
        if (msg_type == 0xFE) {
            // Batch envelope: [0xFE][count:u16_le][len1:u16_le][msg1...][len2:u16_le][msg2...]...
            if (data.len < 3) return;
            const count = std.mem.readInt(u16, data[1..3], .little);
            var offset: usize = 3;
            for (0..count) |_| {
                if (offset + 2 > data.len) break;
                const msg_len = std.mem.readInt(u16, data[offset..][0..2], .little);
                offset += 2;
                if (offset + msg_len > data.len) break;
                const inner = data[offset..][0..msg_len];
                if (inner.len > 0) {
                    self.dispatchControlMessage(conn, inner);
                }
                offset += msg_len;
            }
        } else {
            self.dispatchControlMessage(conn, data);
        }
    }

    fn dispatchControlMessage(self: *Server, conn: *ws.Connection, data: []u8) void {
        if (data.len == 0) return;
        const msg_type = data[0];
        if (msg_type >= 0x80 and msg_type <= 0x8F) {
            self.handleBinaryControlMessageFromClient(conn, data);
        } else if (msg_type >= 0x90 and msg_type <= 0x9F) {
            self.handleAuthMessage(conn, data);
        } else if (msg_type >= 0x20 and msg_type <= 0x27) {
            // File transfer messages: deprecated on control WS, use /ws/file instead.
            // Keep fallback for backwards compatibility with older clients.
            self.handleFileTransferMessage(conn, data);
        } else {
            self.handleBinaryControlMessage(conn, data);
        }
    }

    fn onControlDisconnect(conn: *ws.Connection) void {
        const self = global_server.load(.acquire) orelse return;

        var need_broadcast = false;

        self.mutex.lock();
        for (self.control_connections.items, 0..) |ctrl_conn, i| {
            if (ctrl_conn == conn) {
                _ = self.control_connections.swapRemove(i);
                break;
            }
        }

        // Get client ID before removing
        const disconnected_id = self.control_client_ids.get(conn) orelse 0;
        _ = self.control_client_ids.remove(conn);

        // Re-elect if main disconnected
        if (disconnected_id > 0 and disconnected_id == self.main_client_id) {
            if (self.control_connections.items.len > 0) {
                // Promote first remaining connection
                const new_main_conn = self.control_connections.items[0];
                if (self.control_client_ids.get(new_main_conn)) |new_id| {
                    self.main_client_id = new_id;
                } else {
                    self.main_client_id = 0;
                }
            } else {
                self.main_client_id = 0; // No clients
            }
            need_broadcast = true;
        }

        // Remove connection role
        _ = self.connection_roles.remove(conn);

        // Remove cached session for this connection
        if (self.connection_sessions.fetchRemove(conn)) |entry| {
            self.allocator.free(entry.value);
        }
        self.mutex.unlock();

        // Broadcast new main client state outside mutex
        if (need_broadcast) self.broadcastMainClientState();

        // Update admin's client list
        self.sendClientListToAdmins();
    }

    // --- File transfer WebSocket callbacks (dedicated channel for uploads/downloads) ---

    fn onFileConnect(conn: *ws.Connection) void {
        const self = global_server.load(.acquire) orelse return;
        self.mutex.lock();
        self.file_connections.append(self.allocator, conn) catch {};
        self.mutex.unlock();
    }

    fn onFileMessage(conn: *ws.Connection, data: []u8, is_binary: bool) void {
        _ = is_binary;
        const self = global_server.load(.acquire) orelse return;
        if (data.len == 0) return;
        self.handleFileTransferMessage(conn, data);
    }

    fn onFileDisconnect(conn: *ws.Connection) void {
        const self = global_server.load(.acquire) orelse return;

        // Clean up any transfer session associated with this connection
        if (conn.user_data) |user_data| {
            const session: *transfer.TransferSession = @ptrCast(@alignCast(user_data));
            const session_id = session.id;
            session.deleteState();
            self.transfer_manager.removeSession(session_id);
            conn.user_data = null;
            std.debug.print("File WS disconnected — cleaned up transfer session {d}\n", .{session_id});
        }

        self.mutex.lock();
        for (self.file_connections.items, 0..) |file_conn, i| {
            if (file_conn == conn) {
                _ = self.file_connections.swapRemove(i);
                break;
            }
        }
        self.mutex.unlock();
    }

    // --- H264 WebSocket callbacks (video frames only, server→client) ---

    fn onH264Connect(conn: *ws.Connection) void {
        const self = global_server.load(.acquire) orelse return;

        self.mutex.lock();
        self.h264_connections.append(self.allocator, conn) catch {};

        // Force keyframes on all panels so new H264 client gets valid streams
        var panel_it = self.panels.valueIterator();
        while (panel_it.next()) |panel_ptr| {
            const panel = panel_ptr.*;
            panel.force_keyframe = true;
            panel.ticks_since_connect = 100; // Skip initial render delay
        }
        self.mutex.unlock();

        self.wake_signal.notify();
    }

    fn onH264Message(_: *ws.Connection, _: []u8, _: bool) void {
        // H264 WS is one-way server→client, no messages expected
    }

    fn onH264Disconnect(conn: *ws.Connection) void {
        const self = global_server.load(.acquire) orelse return;

        self.mutex.lock();
        for (self.h264_connections.items, 0..) |hc, i| {
            if (hc == conn) {
                _ = self.h264_connections.orderedRemove(i);
                break;
            }
        }
        self.mutex.unlock();
    }

    // Send H264 frame to all H264 clients with [panel_id:u32][frame_data...] prefix.
    // Returns true if sent to at least one client, false if all sends failed.
    fn sendH264Frame(self: *Server, panel_id: u32, frame_data: []const u8) bool {
        var conns_buf: [max_broadcast_conns]*ws.Connection = undefined;
        var conns_count: usize = 0;
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (self.h264_connections.items) |conn| {
                if (conns_count < conns_buf.len) {
                    conns_buf[conns_count] = conn;
                    conns_count += 1;
                }
            }
        }
        if (conns_count == 0) return false;

        var id_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &id_buf, panel_id, .little);

        var any_sent = false;
        for (conns_buf[0..conns_count]) |conn| {
            conn.sendBinaryParts(&id_buf, frame_data) catch continue;
            any_sent = true;
        }
        return any_sent;
    }

    // Handle PANEL_MSG (0x87) — routes panel-level messages through the zstd WS.
    // Format: [0x87][panel_id:u32][inner_msg_type:u8][inner_payload...]
    fn handlePanelMsg(self: *Server, conn: *ws.Connection, data: []const u8) void {
        if (data.len < 6) return; // 1 (type) + 4 (panel_id) + 1 (inner type) minimum
        const panel_id = std.mem.readInt(u32, data[1..5], .little);
        const inner = data[5..];
        const inner_type = inner[0];

        // Handle create_panel and split_panel (no existing panel needed)
        if (inner_type == @intFromEnum(ClientMsg.create_panel)) {
            // Create new panel: [inner_type:u8][width:u16][height:u16][scale:f32][inherit_panel_id:u32][flags:u8]?
            var width: u32 = 800;
            var height: u32 = 600;
            var scale: f64 = 2.0;
            var inherit_cwd_from: u32 = 0;
            var kind: PanelKind = .regular;
            if (inner.len >= 5) {
                width = std.mem.readInt(u16, inner[1..3], .little);
                height = std.mem.readInt(u16, inner[3..5], .little);
            }
            if (inner.len >= 9) {
                const scale_f32: f32 = @bitCast(std.mem.readInt(u32, inner[5..9], .little));
                scale = @floatCast(scale_f32);
            }
            if (inner.len >= 13) {
                inherit_cwd_from = std.mem.readInt(u32, inner[9..13], .little);
            }
            if (inner.len >= 14) {
                kind = if (inner[13] & 1 != 0) .quick_terminal else .regular;
            }
            _ = self.pending_panels_ch.send(.{
                .width = width,
                .height = height,
                .scale = scale,
                .inherit_cwd_from = inherit_cwd_from,
                .kind = kind,
            });
            self.wake_signal.notify();
            return;
        }

        if (inner_type == @intFromEnum(ClientMsg.split_panel)) {
            // Split existing panel: [inner_type:u8][parent_id:u32][dir_byte:u8][width:u16][height:u16][scale_x100:u16]
            if (inner.len < 12) return;
            const parent_id = std.mem.readInt(u32, inner[1..5], .little);
            const dir_byte = inner[5];
            const width = std.mem.readInt(u16, inner[6..8], .little);
            const height = std.mem.readInt(u16, inner[8..10], .little);
            const scale_x100 = std.mem.readInt(u16, inner[10..12], .little);
            const direction: SplitDirection = if (dir_byte == 1) .vertical else .horizontal;
            const scale: f64 = @as(f64, @floatFromInt(scale_x100)) / 100.0;

            _ = self.pending_splits_ch.send(.{
                .parent_panel_id = parent_id,
                .direction = direction,
                .width = width,
                .height = height,
                .scale = scale,
            });
            self.wake_signal.notify();
            return;
        }

        // All other messages target an existing panel
        self.mutex.lock();
        const panel = self.panels.get(panel_id);
        self.mutex.unlock();
        if (panel == null) return;
        const p = panel.?;

        // Handle inspector messages
        if (inner_type == @intFromEnum(ClientMsg.inspector_subscribe)) {
            p.inspector_subscribed = true;
            const payload = inner[1..];
            if (payload.len >= 1) {
                const tab_len = payload[0];
                if (payload.len >= 1 + tab_len) {
                    const tab = payload[1..][0..tab_len];
                    const len = @min(tab.len, p.inspector_tab.len);
                    @memcpy(p.inspector_tab[0..len], tab[0..len]);
                    p.inspector_tab_len = @intCast(len);
                }
            } else {
                const default_tab = "screen";
                @memcpy(p.inspector_tab[0..default_tab.len], default_tab);
                p.inspector_tab_len = default_tab.len;
            }
            self.mutex.lock();
            self.sendInspectorStateToPanel(p, conn);
            self.mutex.unlock();
            return;
        } else if (inner_type == @intFromEnum(ClientMsg.inspector_unsubscribe)) {
            p.inspector_subscribed = false;
            return;
        } else if (inner_type == @intFromEnum(ClientMsg.inspector_tab)) {
            const payload = inner[1..];
            if (payload.len >= 1) {
                const tab_len = payload[0];
                if (payload.len >= 1 + tab_len) {
                    const tab = payload[1..][0..tab_len];
                    const len = @min(tab.len, p.inspector_tab.len);
                    @memcpy(p.inspector_tab[0..len], tab[0..len]);
                    p.inspector_tab_len = @intCast(len);
                    self.mutex.lock();
                    self.sendInspectorStateToPanel(p, conn);
                    self.mutex.unlock();
                }
            }
            return;
        } else if (inner_type == @intFromEnum(ClientMsg.request_keyframe)) {
            p.force_keyframe = true;
            self.wake_signal.notify();
            return;
        }

        // General panel input (key, mouse, text, resize, etc.)
        p.handleMessage(@constCast(inner));
        p.has_pending_input.store(true, .release);
        p.last_input_time.store(@truncate(std.time.nanoTimestamp()), .release);
        self.wake_signal.notify();
    }


    fn sendInspectorStateToPanel(self: *Server, panel: *Panel, conn: *ws.Connection) void {
        // Note: mutex must already be held by caller
        _ = self;
        const size = c.ghostty_surface_size(panel.surface);

        // Binary: [type:u8][panel_id:u32][cols:u16][rows:u16][sw:u16][sh:u16][cw:u8][ch:u8] = 15 bytes
        var buf: [15]u8 = undefined;
        buf[0] = @intFromEnum(BinaryCtrlMsg.inspector_state);
        std.mem.writeInt(u32, buf[1..5], panel.id, .little);
        std.mem.writeInt(u16, buf[5..7], @intCast(size.columns), .little);
        std.mem.writeInt(u16, buf[7..9], @intCast(size.rows), .little);
        std.mem.writeInt(u16, buf[9..11], @intCast(size.width_px), .little);
        std.mem.writeInt(u16, buf[11..13], @intCast(size.height_px), .little);
        buf[13] = @intCast(size.cell_width_px);
        buf[14] = @intCast(size.cell_height_px);

        conn.sendBinary(&buf) catch {};
    }

    // Broadcast inspector state to all control connections (mutex must be held)
    fn broadcastInspectorStateToAll(self: *Server, panel: *Panel) void {
        const size = c.ghostty_surface_size(panel.surface);
        var buf: [15]u8 = undefined;
        buf[0] = @intFromEnum(BinaryCtrlMsg.inspector_state);
        std.mem.writeInt(u32, buf[1..5], panel.id, .little);
        std.mem.writeInt(u16, buf[5..7], @intCast(size.columns), .little);
        std.mem.writeInt(u16, buf[7..9], @intCast(size.rows), .little);
        std.mem.writeInt(u16, buf[9..11], @intCast(size.width_px), .little);
        std.mem.writeInt(u16, buf[11..13], @intCast(size.height_px), .little);
        buf[13] = @intCast(size.cell_width_px);
        buf[14] = @intCast(size.cell_height_px);
        for (self.control_connections.items) |ctrl_conn| {
            ctrl_conn.sendBinary(&buf) catch {};
        }
    }

    // --- Control message handling---


    fn handleBinaryControlMessageFromClient(self: *Server, conn: *ws.Connection, data: []const u8) void {
        if (data.len < 1) return;

        const msg_type = data[0];
        if (msg_type == 0x84) { // assign_panel
            self.handleAssignPanel(conn, data);
            return;
        } else if (msg_type == 0x85) { // unassign_panel
            self.handleUnassignPanel(conn, data);
            return;
        } else if (msg_type == 0x86) { // panel_input
            self.handlePanelInput(conn, data);
            return;
        } else if (msg_type == 0x87) { // panel_msg envelope
            self.handlePanelMsg(conn, data);
            return;
        }

        if (msg_type == 0x81) { // close_panel
            if (data.len < 5) return;
            const panel_id = std.mem.readInt(u32, data[1..5], .little);
            _ = self.pending_destroys_ch.send(.{ .id = panel_id });
            self.wake_signal.notify();
        } else if (msg_type == 0x82) { // resize_panel
            if (data.len < 9) return;
            const panel_id = std.mem.readInt(u32, data[1..5], .little);
            const width = std.mem.readInt(u16, data[5..7], .little);
            const height = std.mem.readInt(u16, data[7..9], .little);
            // Extended: [type:u8][panel_id:u32][w:u16][h:u16][scale:f32] = 13 bytes
            var scale: f64 = 0;
            if (data.len >= 13) {
                const scale_f32: f32 = @bitCast(std.mem.readInt(u32, data[9..13], .little));
                if (scale_f32 > 0) scale = @floatCast(scale_f32);
            }
            _ = self.pending_resizes_ch.send(.{ .id = panel_id, .width = width, .height = height, .scale = scale });
            self.wake_signal.notify();
        } else if (msg_type == 0x83) { // focus_panel
            if (data.len < 5) return;
            const panel_id = std.mem.readInt(u32, data[1..5], .little);
            self.mutex.lock();
            const old_tab_id = self.layout.getActiveTabId();
            self.layout.active_panel_id = panel_id;
            const new_tab_id = self.layout.getActiveTabId();
            // Force keyframes on all panels in the newly active tab
            if (old_tab_id == null or (new_tab_id != null and old_tab_id.? != new_tab_id.?)) {
                if (self.layout.findTabByPanel(panel_id)) |tab| {
                    var panel_ids = tab.getAllPanelIds(self.allocator) catch {
                        self.mutex.unlock();
                        return;
                    };
                    defer panel_ids.deinit(self.allocator);
                    for (panel_ids.items) |pid| {
                        if (self.panels.get(pid)) |panel| {
                            panel.force_keyframe = true;
                        }
                    }
                }
            }
            self.mutex.unlock();

            self.wake_signal.notify();
        } else if (msg_type == 0x88) { // view_action
            if (data.len < 6) return;
            const panel_id = std.mem.readInt(u32, data[1..5], .little);
            const action_len = data[5];
            if (data.len < 6 + action_len) return;
            const action = data[6..][0..action_len];
            self.mutex.lock();
            if (self.panels.get(panel_id)) |panel| {
                self.mutex.unlock();
                _ = c.ghostty_surface_binding_action(panel.surface, action.ptr, action.len);
            } else {
                self.mutex.unlock();
            }
        } else if (msg_type == 0x89) { // set_overview
            if (data.len < 2) return;
            self.mutex.lock();
            const was_open = self.overview_open;
            self.overview_open = data[1] != 0;
            // Force keyframe on all panels when overview opens so idle panels
            // send a fresh frame (otherwise the idle-skip logic prevents encoding)
            if (self.overview_open and !was_open) {
                var it = self.panels.valueIterator();
                while (it.next()) |panel| {
                    panel.*.force_keyframe = true;
                }
            }
            self.mutex.unlock();
            self.wake_signal.notify();
            // Broadcast to all control connections so other clients can sync
            self.broadcastOverviewState();
        } else if (msg_type == 0x8A) { // set_quick_terminal
            if (data.len < 2) return;
            self.mutex.lock();
            self.quick_terminal_open = data[1] != 0;
            self.mutex.unlock();
            self.broadcastQuickTerminalState();
        } else if (msg_type == 0x8B) { // set_inspector
            if (data.len < 2) return;
            self.mutex.lock();
            self.inspector_open = data[1] != 0;
            self.mutex.unlock();
            self.broadcastInspectorOpenState();
        } else if (msg_type == 0x8C) { // set_clipboard
            // [0x8C][panel_id:u32][len:u32][text...]
            if (data.len < 9) return;
            const text_len = std.mem.readInt(u32, data[5..9], .little);
            if (data.len < 9 + text_len) return;
            const text = data[9..][0..text_len];
            self.mutex.lock();
            if (self.standard_clipboard) |old| self.allocator.free(old);
            self.standard_clipboard = self.allocator.dupe(u8, text) catch null;
            self.mutex.unlock();
        } else {
            std.log.warn("Unknown binary control message type: 0x{x:0>2}", .{msg_type});
        }
    }

    // --- Auth/Session Message Handlers---

    fn handleAuthMessage(self: *Server, conn: *ws.Connection, data: []const u8) void {
        if (data.len < 1) return;

        const msg_type = data[0];
        const role = self.getConnectionRole(conn);

        switch (msg_type) {
            0x90 => { // get_auth_state
                self.sendAuthState(conn);
            },
            0x91 => { // set_password
                // Only admin can set password
                if (role != .admin) {
                    self.sendAuthError(conn, "Permission denied");
                    return;
                }
                if (data.len < 3) return;
                const pwd_len = std.mem.readInt(u16, data[1..3], .little);
                if (data.len < 3 + pwd_len) return;
                const password = data[3..][0..pwd_len];
                self.auth_state.setAdminPassword(password) catch {
                    self.sendAuthError(conn, "Failed to set password");
                    return;
                };
                self.sendAuthState(conn);
            },
            0x92 => { // verify_password
                if (data.len < 3) return;
                const pwd_len = std.mem.readInt(u16, data[1..3], .little);
                if (data.len < 3 + pwd_len) return;
                const password = data[3..][0..pwd_len];
                if (self.auth_state.verifyAdminPassword(password)) {
                    // Set connection role to admin
                    self.connection_roles.put(conn, .admin) catch {};
                    self.sendAuthState(conn);
                } else {
                    self.sendAuthError(conn, "Invalid password");
                }
            },
            0x93 => { // create_session
                if (role != .admin) {
                    self.sendAuthError(conn, "Permission denied");
                    return;
                }
                if (data.len < 5) return;
                const id_len = std.mem.readInt(u16, data[1..3], .little);
                const name_len = std.mem.readInt(u16, data[3..5], .little);
                if (data.len < 5 + id_len + name_len) return;
                const session_id = data[5..][0..id_len];
                const session_name = data[5 + id_len ..][0..name_len];
                self.auth_state.createSession(session_id, session_name) catch {
                    self.sendAuthError(conn, "Failed to create session");
                    return;
                };
                self.sendSessionList(conn);
            },
            0x94 => { // delete_session
                if (role != .admin) {
                    self.sendAuthError(conn, "Permission denied");
                    return;
                }
                if (data.len < 3) return;
                const id_len = std.mem.readInt(u16, data[1..3], .little);
                if (data.len < 3 + id_len) return;
                const session_id = data[3..][0..id_len];
                self.auth_state.deleteSession(session_id) catch {};
                self.sendSessionList(conn);
            },
            0x95 => { // regenerate_token
                if (role != .admin) {
                    self.sendAuthError(conn, "Permission denied");
                    return;
                }
                if (data.len < 4) return;
                const id_len = std.mem.readInt(u16, data[1..3], .little);
                const token_type: auth.TokenType = @enumFromInt(data[3]);
                if (data.len < 4 + id_len) return;
                const session_id = data[4..][0..id_len];
                self.auth_state.regenerateSessionToken(session_id, token_type) catch {};
                self.sendSessionList(conn);
            },
            0x96 => { // create_share_link
                if (role != .admin) {
                    self.sendAuthError(conn, "Permission denied");
                    return;
                }
                if (data.len < 2) return;
                const token_type: auth.TokenType = @enumFromInt(data[1]);
                // Optional: expires_in_secs (i64), max_uses (u32), label
                const token = self.auth_state.createShareLink(token_type, null, null, null) catch {
                    self.sendAuthError(conn, "Failed to create share link");
                    return;
                };
                self.sendShareLinks(conn);
                _ = token;
            },
            0x97 => { // revoke_share_link
                if (role != .admin) {
                    self.sendAuthError(conn, "Permission denied");
                    return;
                }
                if (data.len < 45) return; // 1 + 44 (token length)
                const token = data[1..45];
                self.auth_state.revokeShareLink(token) catch {};
                self.sendShareLinks(conn);
            },
            0x98 => { // revoke_all_shares
                if (role != .admin) {
                    self.sendAuthError(conn, "Permission denied");
                    return;
                }
                self.auth_state.revokeAllShareLinks() catch {};
                self.sendShareLinks(conn);
            },
            else => {
                std.log.warn("Unknown auth message type: 0x{x:0>2}", .{msg_type});
            },
        }
    }

    fn getConnectionRole(self: *Server, conn: *ws.Connection) auth.Role {
        // Check if we have a cached role for this connection
        if (self.connection_roles.get(conn)) |role| {
            return role;
        }

        // Check token from connection URI
        if (conn.request_uri) |uri| {
            if (auth.extractTokenFromQuery(uri)) |token| {
                const role = self.auth_state.validateToken(token);
                // Cache the role
                self.connection_roles.put(conn, role) catch {};
                return role;
            }
        }

        // No auth required = admin access
        if (!self.auth_state.auth_required) {
            return .admin;
        }

        return .none;
    }

    fn sendAuthState(self: *Server, conn: *ws.Connection) void {
        const role = self.getConnectionRole(conn);

        // Build auth state message
        // [0x0A][role:u8][auth_required:u8][has_password:u8][passkey_count:u8]
        var msg: [5]u8 = undefined;
        msg[0] = 0x0A; // auth_state
        msg[1] = @intFromEnum(role);
        msg[2] = if (self.auth_state.auth_required) 1 else 0;
        msg[3] = if (self.auth_state.admin_password_hash != null) 1 else 0;
        msg[4] = @intCast(self.auth_state.passkey_credentials.items.len);

        conn.sendBinary(&msg) catch {};
    }

    fn sendSessionList(self: *Server, conn: *ws.Connection) void {
        const role = self.getConnectionRole(conn);
        if (role != .admin) return;

        // Build session list message
        // [0x0B][count:u16][sessions...]
        // session: [id_len:u16][id][name_len:u16][name][editor_token:44][viewer_token:44]
        var buf: std.ArrayListUnmanaged(u8) = .{};
        defer buf.deinit(self.allocator);

        buf.append(self.allocator, 0x0B) catch return; // session_list

        const sessions = self.auth_state.sessions;
        var count: u16 = 0;
        var iter = sessions.valueIterator();
        while (iter.next()) |_| count += 1;

        buf.writer(self.allocator).writeInt(u16, count, .little) catch return;

        iter = sessions.valueIterator();
        while (iter.next()) |session| {
            buf.writer(self.allocator).writeInt(u16, @intCast(session.id.len), .little) catch return;
            buf.appendSlice(self.allocator, session.id) catch return;
            buf.writer(self.allocator).writeInt(u16, @intCast(session.name.len), .little) catch return;
            buf.appendSlice(self.allocator, session.name) catch return;
            buf.appendSlice(self.allocator, &session.editor_token) catch return;
            buf.appendSlice(self.allocator, &session.viewer_token) catch return;
        }

        conn.sendBinary(buf.items) catch {};
    }

    fn sendShareLinks(self: *Server, conn: *ws.Connection) void {
        const role = self.getConnectionRole(conn);
        if (role != .admin) return;

        // Build share links message
        // [0x0C][count:u16][links...]
        // link: [token:44][type:u8][use_count:u32][valid:u8]
        var buf: std.ArrayListUnmanaged(u8) = .{};
        defer buf.deinit(self.allocator);

        buf.append(self.allocator, 0x0C) catch return; // share_links
        buf.writer(self.allocator).writeInt(u16, @intCast(self.auth_state.share_links.items.len), .little) catch return;

        for (self.auth_state.share_links.items) |link| {
            buf.appendSlice(self.allocator, &link.token) catch return;
            buf.append(self.allocator, @intFromEnum(link.token_type)) catch return;
            buf.writer(self.allocator).writeInt(u32, link.use_count, .little) catch return;
            buf.append(self.allocator, if (link.isValid()) 1 else 0) catch return;
        }

        conn.sendBinary(buf.items) catch {};
    }

    fn sendAuthError(self: *Server, conn: *ws.Connection, message: []const u8) void {
        _ = self;
        // [0x35][len:u16][message] - reuse transfer error format
        var buf: [259]u8 = undefined;
        buf[0] = 0x35;
        std.mem.writeInt(u16, buf[1..3], @intCast(message.len), .little);
        @memcpy(buf[3..][0..message.len], message);
        conn.sendBinary(buf[0 .. 3 + message.len]) catch {};
    }


    // Binary control message handler
    // 0x10 = file_upload, 0x11 = file_download, 0x14 = folder_download (zip)
    // 0x81-0x88 = client control messages (close, resize, focus, split, etc.)
    fn handleBinaryControlMessage(self: *Server, conn: *ws.Connection, data: []const u8) void {
        if (data.len < 1) return;

        const msg_type = data[0];
        switch (msg_type) {
            // Client control messages
            0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8A, 0x8B => {
                self.handleBinaryControlMessageFromClient(conn, data);
            },
            else => std.log.warn("Unknown binary control message type: 0x{x:0>2}", .{msg_type}),
        }
    }

    /// Max connections for stack-based snapshot (avoids heap allocation during broadcast).
    const max_broadcast_conns = 16;

    /// Build 15-byte cursor state message in surface-space coordinates.
    /// [type:u8][panel_id:u32][x:u16][y:u16][w:u16][h:u16][style:u8][visible:u8]
    fn buildCursorBuf(panel_id: u32, x: u16, y: u16, w: u16, h: u16, style: u8, visible: u8) [15]u8 {
        var buf: [15]u8 = undefined;
        buf[0] = @intFromEnum(BinaryCtrlMsg.cursor_state);
        std.mem.writeInt(u32, buf[1..5], panel_id, .little);
        std.mem.writeInt(u16, buf[5..7], x, .little);
        std.mem.writeInt(u16, buf[7..9], y, .little);
        std.mem.writeInt(u16, buf[9..11], w, .little);
        std.mem.writeInt(u16, buf[11..13], h, .little);
        buf[13] = style;
        buf[14] = visible;
        return buf;
    }

    /// Build 9-byte surface dimensions message.
    /// [type:u8][panel_id:u32][width:u16][height:u16]
    fn buildSurfaceDimsBuf(panel_id: u32, w: u16, h: u16) [9]u8 {
        var buf: [9]u8 = undefined;
        buf[0] = @intFromEnum(BinaryCtrlMsg.surface_dims);
        std.mem.writeInt(u32, buf[1..5], panel_id, .little);
        std.mem.writeInt(u16, buf[5..7], w, .little);
        std.mem.writeInt(u16, buf[7..9], h, .little);
        return buf;
    }

    /// Send current cursor state for all panels to a single connection.
    /// Called when a new control client connects so it gets immediate cursor/surface state.
    fn sendCursorStateToConn(self: *Server, conn: *ws.Connection) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var pit = self.panels.valueIterator();
        while (pit.next()) |panel_ptr| {
            const panel = panel_ptr.*;
            if (panel.surface == null) continue;
            const size = c.ghostty_surface_size(panel.surface);
            const cell_w: u16 = @intCast(size.cell_width_px);
            const cell_h: u16 = @intCast(size.cell_height_px);
            const padding_x: u16 = @intCast(size.padding_left_px);
            const padding_y: u16 = @intCast(size.padding_top_px);
            const surf_x = padding_x + panel.last_cursor_col * cell_w;
            const surf_y = padding_y + panel.last_cursor_row * cell_h + 2;
            const surf_w: u16 = cell_w -| 1;
            const surf_h: u16 = cell_h -| 2;
            const surf_total_w: u16 = @intCast(size.width_px);
            const surf_total_h: u16 = @intCast(size.height_px);

            // Send surface dims first so client knows coordinate space
            const dims_buf = buildSurfaceDimsBuf(panel.id, surf_total_w, surf_total_h);
            conn.sendBinary(&dims_buf) catch {};

            const cursor_buf = buildCursorBuf(panel.id, surf_x, surf_y, surf_w, surf_h, panel.last_cursor_style, panel.last_cursor_visible);
            conn.sendBinary(&cursor_buf) catch {};
        }
    }

    /// Copy control connection list under mutex so sends can happen without holding it.
    /// Caller provides stack buffer; returned slice points into it.
    fn snapshotControlConns(self: *Server, buf: *[max_broadcast_conns]*ws.Connection) []const *ws.Connection {
        self.mutex.lock();
        const count = @min(self.control_connections.items.len, max_broadcast_conns);
        @memcpy(buf[0..count], self.control_connections.items[0..count]);
        self.mutex.unlock();
        return buf[0..count];
    }

    fn broadcastInspectorUpdates(self: *Server) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Send to panel-based inspector subscriptions via control connections
        var it = self.panels.iterator();
        while (it.next()) |entry| {
            const panel = entry.value_ptr.*;
            if (panel.inspector_subscribed) {
                self.broadcastInspectorStateToAll(panel);
            }
        }
    }


    fn sendPanelList(self: *Server, conn: *ws.Connection) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Get layout JSON
        const layout_json = self.layout.toJson(self.allocator) catch return;
        defer self.allocator.free(layout_json);

        // Binary: [type:u8][count:u8][panel_id:u32, title_len:u8, title...]*[layout_len:u16][layout_json]
        // Calculate total size
        const panel_count = self.panels.count();
        var total_panel_data_size: usize = 0;
        var it = self.panels.iterator();
        while (it.next()) |entry| {
            const panel = entry.value_ptr.*;
            // panel_id:u32 + title_len:u8 + title
            total_panel_data_size += 4 + 1 + @min(panel.title.len, 255);
        }

        const layout_len: u16 = @min(@as(u16, @intCast(@min(layout_json.len, 65535))), 65535);
        const msg_size = 1 + 1 + total_panel_data_size + 2 + layout_len;
        const msg_buf = self.allocator.alloc(u8, msg_size) catch return;
        defer self.allocator.free(msg_buf);

        msg_buf[0] = @intFromEnum(BinaryCtrlMsg.panel_list);
        msg_buf[1] = @intCast(@min(panel_count, 255));

        var offset: usize = 2;
        var it2 = self.panels.iterator();
        while (it2.next()) |entry| {
            const panel = entry.value_ptr.*;
            std.mem.writeInt(u32, msg_buf[offset..][0..4], panel.id, .little);
            offset += 4;
            const title_len: u8 = @intCast(@min(panel.title.len, 255));
            msg_buf[offset] = title_len;
            offset += 1;
            @memcpy(msg_buf[offset..][0..title_len], panel.title[0..title_len]);
            offset += title_len;
        }

        std.mem.writeInt(u16, msg_buf[offset..][0..2], layout_len, .little);
        offset += 2;
        @memcpy(msg_buf[offset..][0..layout_len], layout_json[0..layout_len]);

        conn.sendBinary(msg_buf) catch {};

        // Send pwd for each panel (titles are already in PANEL_LIST message)
        var it3 = self.panels.iterator();
        while (it3.next()) |entry| {
            const panel = entry.value_ptr.*;
            if (panel.pwd.len > 0) {
                // Binary: [type:u8][panel_id:u32][pwd_len:u16][pwd...]
                const pwd_len: u16 = @intCast(@min(panel.pwd.len, 1024));
                var pwd_buf: [1031]u8 = undefined;
                pwd_buf[0] = @intFromEnum(BinaryCtrlMsg.panel_pwd);
                std.mem.writeInt(u32, pwd_buf[1..5], panel.id, .little);
                std.mem.writeInt(u16, pwd_buf[5..7], pwd_len, .little);
                @memcpy(pwd_buf[7..][0..pwd_len], panel.pwd[0..pwd_len]);
                conn.sendBinary(pwd_buf[0 .. 7 + pwd_len]) catch {};
            }
        }
    }

    fn broadcastPanelCreated(self: *Server, panel_id: u32) void {
        // Binary: [type:u8][panel_id:u32] = 5 bytes
        var buf: [5]u8 = undefined;
        buf[0] = @intFromEnum(BinaryCtrlMsg.panel_created);
        std.mem.writeInt(u32, buf[1..5], panel_id, .little);

        var conn_buf: [max_broadcast_conns]*ws.Connection = undefined;
        const conns = self.snapshotControlConns(&conn_buf);
        for (conns) |conn| {
            conn.sendBinary(&buf) catch {};
        }
    }

    fn broadcastPanelClosed(self: *Server, panel_id: u32) void {
        // Binary: [type:u8][panel_id:u32] = 5 bytes
        var buf: [5]u8 = undefined;
        buf[0] = @intFromEnum(BinaryCtrlMsg.panel_closed);
        std.mem.writeInt(u32, buf[1..5], panel_id, .little);

        var conn_buf: [max_broadcast_conns]*ws.Connection = undefined;
        const conns = self.snapshotControlConns(&conn_buf);
        for (conns) |conn| {
            conn.sendBinary(&buf) catch {};
        }
    }

    fn broadcastPanelTitle(self: *Server, panel_id: u32, title: []const u8) void {
        // Binary: [type:u8][panel_id:u32][title_len:u8][title...] = 6 + title.len bytes
        const title_len: u8 = @min(@as(u8, @intCast(@min(title.len, 255))), 255);
        var buf: [262]u8 = undefined; // 1 + 4 + 1 + 256
        buf[0] = @intFromEnum(BinaryCtrlMsg.panel_title);
        std.mem.writeInt(u32, buf[1..5], panel_id, .little);
        buf[5] = title_len;
        @memcpy(buf[6..][0..title_len], title[0..title_len]);

        // Lock once: update panel data + copy connection list, then unlock before sending
        var conn_buf: [max_broadcast_conns]*ws.Connection = undefined;
        self.mutex.lock();
        if (self.panels.get(panel_id)) |panel| {
            if (panel.title.len > 0) self.allocator.free(panel.title);
            panel.title = self.allocator.dupe(u8, title) catch &.{};
        }
        const count = @min(self.control_connections.items.len, max_broadcast_conns);
        @memcpy(conn_buf[0..count], self.control_connections.items[0..count]);
        self.mutex.unlock();

        for (conn_buf[0..count]) |conn| {
            conn.sendBinary(buf[0 .. 6 + title_len]) catch {};
        }
    }

    fn broadcastPanelBell(self: *Server, panel_id: u32) void {
        // Binary: [type:u8][panel_id:u32] = 5 bytes
        var buf: [5]u8 = undefined;
        buf[0] = @intFromEnum(BinaryCtrlMsg.panel_bell);
        std.mem.writeInt(u32, buf[1..5], panel_id, .little);

        var conn_buf: [max_broadcast_conns]*ws.Connection = undefined;
        const conns = self.snapshotControlConns(&conn_buf);
        for (conns) |conn| {
            conn.sendBinary(&buf) catch {};
        }
    }

    fn broadcastPanelPwd(self: *Server, panel_id: u32, pwd: []const u8) void {
        // Binary: [type:u8][panel_id:u32][pwd_len:u16][pwd...] = 7 + pwd.len bytes
        const pwd_len: u16 = @min(@as(u16, @intCast(@min(pwd.len, 1024))), 1024);
        var buf: [1031]u8 = undefined; // 1 + 4 + 2 + 1024
        buf[0] = @intFromEnum(BinaryCtrlMsg.panel_pwd);
        std.mem.writeInt(u32, buf[1..5], panel_id, .little);
        std.mem.writeInt(u16, buf[5..7], pwd_len, .little);
        @memcpy(buf[7..][0..pwd_len], pwd[0..pwd_len]);

        // Lock once: update panel data + copy connection list, then unlock before sending
        var conn_buf: [max_broadcast_conns]*ws.Connection = undefined;
        self.mutex.lock();
        if (self.panels.get(panel_id)) |panel| {
            if (panel.pwd.len > 0) self.allocator.free(panel.pwd);
            panel.pwd = self.allocator.dupe(u8, pwd) catch &.{};
        }
        const count = @min(self.control_connections.items.len, max_broadcast_conns);
        @memcpy(conn_buf[0..count], self.control_connections.items[0..count]);
        self.mutex.unlock();

        for (conn_buf[0..count]) |conn| {
            conn.sendBinary(buf[0 .. 7 + pwd_len]) catch {};
        }
    }

    fn broadcastPanelNotification(self: *Server, panel_id: u32, title: []const u8, body: []const u8) void {
        // Binary: [type:u8][panel_id:u32][title_len:u8][title...][body_len:u16][body...] = 8 + title.len + body.len bytes
        const title_len: u8 = @min(@as(u8, @intCast(@min(title.len, 255))), 255);
        const body_len: u16 = @min(@as(u16, @intCast(@min(body.len, 1024))), 1024);
        const total_len: usize = 1 + 4 + 1 + title_len + 2 + body_len;
        var buf: [1287]u8 = undefined; // 1 + 4 + 1 + 255 + 2 + 1024
        buf[0] = @intFromEnum(BinaryCtrlMsg.panel_notification);
        std.mem.writeInt(u32, buf[1..5], panel_id, .little);
        buf[5] = title_len;
        @memcpy(buf[6..][0..title_len], title[0..title_len]);
        std.mem.writeInt(u16, buf[6 + title_len ..][0..2], body_len, .little);
        @memcpy(buf[8 + title_len ..][0..body_len], body[0..body_len]);

        var conn_buf: [max_broadcast_conns]*ws.Connection = undefined;
        const conns = self.snapshotControlConns(&conn_buf);
        for (conns) |conn| {
            conn.sendBinary(buf[0..total_len]) catch {};
        }
    }

    fn broadcastLayoutUpdate(self: *Server) void {
        var conn_buf: [max_broadcast_conns]*ws.Connection = undefined;

        self.mutex.lock();
        const layout_json = self.layout.toJson(self.allocator) catch {
            self.mutex.unlock();
            return;
        };
        const count = @min(self.control_connections.items.len, max_broadcast_conns);
        @memcpy(conn_buf[0..count], self.control_connections.items[0..count]);
        self.mutex.unlock();

        defer self.allocator.free(layout_json);

        // Binary: [type:u8][layout_len:u16][layout_json...] = 3 + layout.len bytes
        const layout_len: u16 = @min(@as(u16, @intCast(@min(layout_json.len, 65535))), 65535);
        const msg_buf = self.allocator.alloc(u8, 3 + layout_len) catch return;
        defer self.allocator.free(msg_buf);

        msg_buf[0] = @intFromEnum(BinaryCtrlMsg.layout_update);
        std.mem.writeInt(u16, msg_buf[1..3], layout_len, .little);
        @memcpy(msg_buf[3..][0..layout_len], layout_json[0..layout_len]);

        for (conn_buf[0..count]) |conn| {
            conn.sendBinary(msg_buf) catch {};
        }
    }

    fn sendMainClientState(self: *Server, conn: *ws.Connection, client_id: u32) void {
        // Binary: [type:u8][is_main:u8][client_id:u32] = 6 bytes
        var buf: [6]u8 = undefined;
        buf[0] = @intFromEnum(BinaryCtrlMsg.main_client_state);
        self.mutex.lock();
        buf[1] = if (self.main_client_id == client_id) 1 else 0;
        std.mem.writeInt(u32, buf[2..6], client_id, .little);
        self.mutex.unlock();
        conn.sendBinary(&buf) catch {};
    }

    fn broadcastMainClientState(self: *Server) void {
        var conn_buf: [max_broadcast_conns]*ws.Connection = undefined;
        var id_buf: [max_broadcast_conns]u32 = undefined;
        var count: usize = 0;
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (self.control_connections.items) |conn| {
                if (count < max_broadcast_conns) {
                    conn_buf[count] = conn;
                    id_buf[count] = self.control_client_ids.get(conn) orelse 0;
                    count += 1;
                }
            }
        }
        for (conn_buf[0..count], id_buf[0..count]) |conn, cid| {
            self.sendMainClientState(conn, cid);
        }
    }

    fn broadcastOverviewState(self: *Server) void {
        // Binary: [type:u8][open:u8] = 2 bytes
        var buf: [2]u8 = undefined;
        buf[0] = @intFromEnum(BinaryCtrlMsg.overview_state);
        buf[1] = if (self.overview_open) 1 else 0;

        var conn_buf: [max_broadcast_conns]*ws.Connection = undefined;
        const conns = self.snapshotControlConns(&conn_buf);
        for (conns) |conn| {
            conn.sendBinary(&buf) catch {};
        }
    }

    fn sendOverviewState(self: *Server, conn: *ws.Connection) void {
        // Binary: [type:u8][open:u8] = 2 bytes
        var buf: [2]u8 = undefined;
        buf[0] = @intFromEnum(BinaryCtrlMsg.overview_state);
        self.mutex.lock();
        buf[1] = if (self.overview_open) 1 else 0;
        self.mutex.unlock();
        conn.sendBinary(&buf) catch {};
    }

    fn broadcastQuickTerminalState(self: *Server) void {
        // Binary: [type:u8][open:u8] = 2 bytes
        var buf: [2]u8 = undefined;
        buf[0] = @intFromEnum(BinaryCtrlMsg.quick_terminal_state);
        buf[1] = if (self.quick_terminal_open) 1 else 0;

        var conn_buf: [max_broadcast_conns]*ws.Connection = undefined;
        const conns = self.snapshotControlConns(&conn_buf);
        for (conns) |conn| {
            conn.sendBinary(&buf) catch {};
        }
    }

    fn sendQuickTerminalState(self: *Server, conn: *ws.Connection) void {
        // Binary: [type:u8][open:u8] = 2 bytes
        var buf: [2]u8 = undefined;
        buf[0] = @intFromEnum(BinaryCtrlMsg.quick_terminal_state);
        self.mutex.lock();
        buf[1] = if (self.quick_terminal_open) 1 else 0;
        self.mutex.unlock();
        conn.sendBinary(&buf) catch {};
    }

    fn broadcastInspectorOpenState(self: *Server) void {
        // Binary: [type:u8][open:u8] = 2 bytes
        var buf: [2]u8 = undefined;
        buf[0] = @intFromEnum(BinaryCtrlMsg.inspector_state_open);
        buf[1] = if (self.inspector_open) 1 else 0;

        var conn_buf: [max_broadcast_conns]*ws.Connection = undefined;
        const conns = self.snapshotControlConns(&conn_buf);
        for (conns) |conn| {
            conn.sendBinary(&buf) catch {};
        }
    }

    fn sendInspectorOpenState(self: *Server, conn: *ws.Connection) void {
        // Binary: [type:u8][open:u8] = 2 bytes
        var buf: [2]u8 = undefined;
        buf[0] = @intFromEnum(BinaryCtrlMsg.inspector_state_open);
        self.mutex.lock();
        buf[1] = if (self.inspector_open) 1 else 0;
        self.mutex.unlock();
        conn.sendBinary(&buf) catch {};
    }

    fn broadcastClipboard(self: *Server, text: []const u8) void {
        // Binary: [type:u8][data_len:u32][data...] = 5 + text.len bytes (raw UTF-8, no base64)
        const data_len: u32 = @intCast(@min(text.len, 16 * 1024 * 1024)); // Max 16MB
        const msg_buf = self.allocator.alloc(u8, 5 + data_len) catch return;
        defer self.allocator.free(msg_buf);

        msg_buf[0] = @intFromEnum(BinaryCtrlMsg.clipboard);
        std.mem.writeInt(u32, msg_buf[1..5], data_len, .little);
        @memcpy(msg_buf[5..][0..data_len], text[0..data_len]);

        var conn_buf: [max_broadcast_conns]*ws.Connection = undefined;
        const conns = self.snapshotControlConns(&conn_buf);
        for (conns) |conn| {
            // Clipboard is a critical user action — retry once on WouldBlock.
            // Control WS has 1s timeout so WouldBlock is rare, but can happen
            // if the send buffer is momentarily full from other broadcasts.
            conn.sendBinary(msg_buf) catch |err| {
                if (err == error.WouldBlock) {
                    std.Thread.sleep(1 * std.time.ns_per_ms);
                    conn.sendBinary(msg_buf) catch {};
                }
            };
        }
    }

    // --- Multiplayer: Pane Assignment ---

    /// Admin assigns a panel to a session. Only admin role can call this.
    fn handleAssignPanel(self: *Server, conn: *ws.Connection, data: []const u8) void {
        // [0x84][panel_id:u32][session_id_len:u8][session_id:...]
        if (data.len < 6) return;
        const role = self.getConnectionRole(conn);
        if (role != .admin) return;

        const panel_id = std.mem.readInt(u32, data[1..5], .little);
        const sid_len = data[5];
        if (data.len < 6 + sid_len) return;
        const session_id = data[6..][0..sid_len];

        self.mutex.lock();
        // Free old assignment if exists
        if (self.panel_assignments.fetchRemove(panel_id)) |old| {
            self.allocator.free(old.value);
        }
        // Store new assignment
        const duped = self.allocator.dupe(u8, session_id) catch {
            self.mutex.unlock();
            return;
        };
        self.panel_assignments.put(panel_id, duped) catch {
            self.allocator.free(duped);
            self.mutex.unlock();
            return;
        };
        self.mutex.unlock();

        self.broadcastPanelAssignment(panel_id, session_id);
    }

    /// Admin unassigns a panel.
    fn handleUnassignPanel(self: *Server, conn: *ws.Connection, data: []const u8) void {
        // [0x85][panel_id:u32]
        if (data.len < 5) return;
        const role = self.getConnectionRole(conn);
        if (role != .admin) return;

        const panel_id = std.mem.readInt(u32, data[1..5], .little);

        self.mutex.lock();
        if (self.panel_assignments.fetchRemove(panel_id)) |old| {
            self.allocator.free(old.value);
        }
        self.mutex.unlock();

        // Broadcast with empty session_id to indicate unassignment
        self.broadcastPanelAssignment(panel_id, "");
    }

    /// Coworker sends input to their assigned panel via control WS.
    fn handlePanelInput(self: *Server, conn: *ws.Connection, data: []const u8) void {
        // [0x86][panel_id:u32][input_msg...]
        if (data.len < 6) return; // Need at least type + panel_id + 1 byte input

        const role = self.getConnectionRole(conn);
        // Must be at least editor
        if (role != .admin and role != .editor) return;

        const panel_id = std.mem.readInt(u32, data[1..5], .little);
        const input_msg = data[5..];

        // Validate: sender's session must match panel assignment
        self.mutex.lock();
        const sender_session = self.connection_sessions.get(conn);
        const assigned_session = self.panel_assignments.get(panel_id);

        // Admin can always send input; editors must be assigned
        if (role != .admin) {
            if (sender_session == null or assigned_session == null) {
                self.mutex.unlock();
                return;
            }
            if (!std.mem.eql(u8, sender_session.?, assigned_session.?)) {
                self.mutex.unlock();
                return;
            }
        }

        // Route input to the panel
        if (self.panels.get(panel_id)) |panel| {
            self.mutex.unlock();
            panel.handleMessage(input_msg);
            panel.has_pending_input.store(true, .release);
            panel.last_input_time.store(@truncate(std.time.nanoTimestamp()), .release);
            self.wake_signal.notify();
        } else {
            self.mutex.unlock();
        }
    }

    /// Broadcast panel assignment change to all control clients.
    fn broadcastPanelAssignment(self: *Server, panel_id: u32, session_id: []const u8) void {
        // [0x11][panel_id:u32][session_id_len:u8][session_id:...]
        const sid_len: u8 = @intCast(@min(session_id.len, 255));
        var buf: [262]u8 = undefined; // 1 + 4 + 1 + 256
        buf[0] = @intFromEnum(BinaryCtrlMsg.panel_assignment);
        std.mem.writeInt(u32, buf[1..5], panel_id, .little);
        buf[5] = sid_len;
        if (sid_len > 0) {
            @memcpy(buf[6..][0..sid_len], session_id[0..sid_len]);
        }

        var conn_buf: [max_broadcast_conns]*ws.Connection = undefined;
        const conns = self.snapshotControlConns(&conn_buf);
        for (conns) |c_conn| {
            c_conn.sendBinary(buf[0 .. 6 + sid_len]) catch {};
        }
    }

    /// Send all current panel assignments to a specific client.
    fn sendAllPanelAssignments(self: *Server, conn: *ws.Connection) void {
        self.mutex.lock();
        const count = self.panel_assignments.count();
        if (count == 0) {
            self.mutex.unlock();
            return;
        }

        // Send individual PANEL_ASSIGNMENT messages for each assignment
        var it = self.panel_assignments.iterator();
        while (it.next()) |entry| {
            const panel_id = entry.key_ptr.*;
            const session_id = entry.value_ptr.*;
            const sid_len: u8 = @intCast(@min(session_id.len, 255));

            var buf: [262]u8 = undefined;
            buf[0] = @intFromEnum(BinaryCtrlMsg.panel_assignment);
            std.mem.writeInt(u32, buf[1..5], panel_id, .little);
            buf[5] = sid_len;
            if (sid_len > 0) {
                @memcpy(buf[6..][0..sid_len], session_id[0..sid_len]);
            }
            conn.sendBinary(buf[0 .. 6 + sid_len]) catch {};
        }
        self.mutex.unlock();
    }

    /// Send this client's session identity (resolved from token).
    fn sendSessionIdentity(self: *Server, conn: *ws.Connection) void {
        self.mutex.lock();
        const session_id = self.connection_sessions.get(conn) orelse "";
        self.mutex.unlock();

        // [0x13][session_id_len:u8][session_id:...]
        const sid_len: u8 = @intCast(@min(session_id.len, 255));
        var buf: [258]u8 = undefined; // 1 + 1 + 256
        buf[0] = @intFromEnum(BinaryCtrlMsg.session_identity);
        buf[1] = sid_len;
        if (sid_len > 0) {
            @memcpy(buf[2..][0..sid_len], session_id[0..sid_len]);
        }
        conn.sendBinary(buf[0 .. 2 + sid_len]) catch {};
    }

    /// Send connected client list to all admin connections.
    fn sendClientListToAdmins(self: *Server) void {
        var conn_buf: [max_broadcast_conns]*ws.Connection = undefined;
        var role_buf: [max_broadcast_conns]auth.Role = undefined;
        var count: usize = 0;

        self.mutex.lock();

        // First, build the client list message
        // [0x12][count:u8][{client_id:u32, role:u8, session_id_len:u8, session_id:...}*]
        var msg_buf: std.ArrayListUnmanaged(u8) = .{};
        msg_buf.append(self.allocator, @intFromEnum(BinaryCtrlMsg.client_list)) catch {
            self.mutex.unlock();
            return;
        };

        const client_count: u8 = @intCast(@min(self.control_connections.items.len, 255));
        msg_buf.append(self.allocator, client_count) catch {
            msg_buf.deinit(self.allocator);
            self.mutex.unlock();
            return;
        };

        for (self.control_connections.items) |ctrl_conn| {
            const cid = self.control_client_ids.get(ctrl_conn) orelse 0;
            const crole = self.getConnectionRole(ctrl_conn);
            const csession = self.connection_sessions.get(ctrl_conn) orelse "";

            msg_buf.writer(self.allocator).writeInt(u32, cid, .little) catch break;
            msg_buf.append(self.allocator, @intFromEnum(crole)) catch break;
            const sid_len: u8 = @intCast(@min(csession.len, 255));
            msg_buf.append(self.allocator, sid_len) catch break;
            if (sid_len > 0) {
                msg_buf.appendSlice(self.allocator, csession[0..sid_len]) catch break;
            }
        }

        // Snapshot admin connections
        for (self.control_connections.items) |ctrl_conn| {
            if (count >= max_broadcast_conns) break;
            const crole = self.getConnectionRole(ctrl_conn);
            conn_buf[count] = ctrl_conn;
            role_buf[count] = crole;
            count += 1;
        }
        self.mutex.unlock();

        defer msg_buf.deinit(self.allocator);

        // Send only to admins
        for (conn_buf[0..count], role_buf[0..count]) |c_conn, crole| {
            if (crole == .admin) {
                c_conn.sendBinary(msg_buf.items) catch {};
            }
        }
    }

    // Run HTTP server
    fn runHttpServer(self: *Server) void {
        self.http_server.run() catch |err| {
            std.debug.print("HTTP server error: {}\n", .{err});
        };
    }

    // Route file transfer messages (merged from file WS into control WS)
    fn handleFileTransferMessage(self: *Server, conn: *ws.Connection, data: []u8) void {
        if (data.len == 0) return;
        const msg_type = data[0];
        switch (msg_type) {
            @intFromEnum(transfer.ClientMsgType.transfer_init) => self.handleTransferInit(conn, data),
            @intFromEnum(transfer.ClientMsgType.file_list_request) => self.handleFileListRequest(conn, data),
            @intFromEnum(transfer.ClientMsgType.file_data) => self.handleFileData(conn, data),
            @intFromEnum(transfer.ClientMsgType.transfer_resume) => self.handleTransferResume(conn, data),
            @intFromEnum(transfer.ClientMsgType.transfer_cancel) => self.handleTransferCancel(conn, data),
            @intFromEnum(transfer.ClientMsgType.sync_request) => self.handleSyncRequest(conn, data),
            @intFromEnum(transfer.ClientMsgType.block_checksums) => self.handleBlockChecksums(conn, data),
            @intFromEnum(transfer.ClientMsgType.sync_ack) => {}, // Client confirms delta applied — no server action needed
            else => std.debug.print("Unknown file transfer message type: 0x{x:0>2}\n", .{msg_type}),
        }
    }

    // Handle TRANSFER_INIT message
    fn handleTransferInit(self: *Server, conn: *ws.Connection, data: []u8) void {
        var init_data = transfer.parseTransferInit(self.allocator, data) catch |err| {
            std.debug.print("Failed to parse TRANSFER_INIT: {}\n", .{err});
            return;
        };
        defer init_data.deinit(self.allocator);

        std.debug.print("TRANSFER_INIT: dir={s} flags=0x{x:0>2} path='{s}' excludes={d}\n", .{
            @tagName(init_data.direction),
            @as(u8, @bitCast(init_data.flags)),
            init_data.path,
            init_data.excludes.len,
        });

        // Resolve path: expand ~, join relative paths with initial_cwd
        const resolved_path = self.resolvePath(init_data.path);
        defer if (resolved_path.ptr != self.initial_cwd.ptr) self.allocator.free(@constCast(resolved_path));

        std.debug.print("  resolved_path='{s}'\n", .{resolved_path});

        // Create session
        const session = self.transfer_manager.createSession(init_data.direction, init_data.flags, resolved_path) catch |err| {
            std.debug.print("Failed to create transfer session: {}\n", .{err});
            return;
        };

        // Add exclude patterns
        for (init_data.excludes) |pattern| {
            session.addExcludePattern(pattern) catch {};
        }

        // Store connection in session
        conn.user_data = session;

        // Send TRANSFER_READY
        const ready_msg = transfer.buildTransferReady(self.allocator, session.id) catch return;
        defer self.allocator.free(ready_msg);
        conn.sendBinary(ready_msg) catch {};

        // For downloads, build file list and send
        if (init_data.direction == .download) {
            session.buildFileListAsync() catch |err| {
                std.debug.print("Failed to build file list for '{s}': {}\n", .{ resolved_path, err });
                const error_msg = transfer.buildTransferError(self.allocator, session.id, "Path not found or not accessible") catch return;
                defer self.allocator.free(error_msg);
                conn.sendBinary(error_msg) catch |send_err| {
                    std.debug.print("Failed to send TRANSFER_ERROR for session {d}: {}\n", .{ session.id, send_err });
                };
                return;
            };

            std.debug.print("  file list built: {d} files, {d} bytes total\n", .{ session.files.items.len, session.total_bytes });

            // If dry run, send report instead of file list
            if (init_data.flags.dry_run) {
                self.sendDryRunReport(conn, session);
            } else {
                const list_msg = transfer.buildFileList(self.allocator, session) catch return;
                defer self.allocator.free(list_msg);
                conn.sendBinary(list_msg) catch {};

                // Push all file data to the client
                self.pushDownloadFiles(conn, session);
            }
        }
    }

    // Handle FILE_LIST_REQUEST message
    fn handleFileListRequest(self: *Server, conn: *ws.Connection, data: []u8) void {
        if (data.len < 5) return;

        const transfer_id = std.mem.readInt(u32, data[1..5], .little);
        const session = self.transfer_manager.getSession(transfer_id) orelse return;

        // Build file list (async: walk then batch hash)
        session.buildFileListAsync() catch |err| {
            std.debug.print("Failed to build file list: {}\n", .{err});
            return;
        };

        const list_msg = transfer.buildFileList(self.allocator, session) catch return;
        defer self.allocator.free(list_msg);
        conn.sendBinary(list_msg) catch {};
    }

    // Handle FILE_DATA message (upload from browser)
    fn handleFileData(self: *Server, conn: *ws.Connection, data: []u8) void {
        const file_data = transfer.parseFileData(data) catch |err| {
            std.debug.print("Failed to parse FILE_DATA: {}\n", .{err});
            return;
        };

        const session = self.transfer_manager.getSession(file_data.transfer_id) orelse return;

        if (file_data.file_index >= session.files.items.len) return;
        const file_entry = session.files.items[file_data.file_index];

        // Decompress the data (detect zstd by magic bytes, otherwise assume raw)
        const is_zstd = file_data.compressed_data.len >= 4 and
            file_data.compressed_data[0] == 0x28 and file_data.compressed_data[1] == 0xB5 and
            file_data.compressed_data[2] == 0x2F and file_data.compressed_data[3] == 0xFD;

        var uncompressed_owned = false;
        const uncompressed = if (is_zstd)
            session.decompress(file_data.compressed_data, file_data.uncompressed_size) catch |err| {
                std.debug.print("Failed to decompress file data: {}\n", .{err});
                return;
            }
        else blk: {
            // Data sent uncompressed (browser has no zstd compressor yet)
            uncompressed_owned = false;
            break :blk file_data.compressed_data;
        };
        defer if (uncompressed_owned or is_zstd) self.allocator.free(uncompressed);

        // Build full path
        const full_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ session.base_path, file_entry.path }) catch return;
        defer self.allocator.free(full_path);

        // Create parent directories if needed
        if (std.mem.lastIndexOf(u8, full_path, "/")) |last_slash| {
            const dir_path = full_path[0..last_slash];
            std.fs.makeDirAbsolute(dir_path) catch |err| {
                if (err != error.PathAlreadyExists) {
                    // Try to create recursively
                    var iter_path: []const u8 = "";
                    var iter = std.mem.splitScalar(u8, dir_path, '/');
                    while (iter.next()) |component| {
                        if (component.len == 0) continue;
                        iter_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ iter_path, component }) catch break;
                        std.fs.makeDirAbsolute(iter_path) catch {};
                    }
                }
            };
        }

        // Write to file
        if (file_data.chunk_offset == 0) {
            // Create new file
            var file = std.fs.createFileAbsolute(full_path, .{}) catch |err| {
                std.debug.print("Failed to create file {s}: {}\n", .{ full_path, err });
                return;
            };
            defer file.close();
            file.writeAll(uncompressed) catch {};
        } else {
            // Append to existing file
            var file = std.fs.openFileAbsolute(full_path, .{ .mode = .write_only }) catch return;
            defer file.close();
            file.seekTo(file_data.chunk_offset) catch return;
            file.writeAll(uncompressed) catch {};
        }

        // Update progress
        session.bytes_transferred += uncompressed.len;

        // Send ACK
        const ack_msg = transfer.buildFileAck(self.allocator, file_data.transfer_id, file_data.file_index, session.bytes_transferred) catch return;
        defer self.allocator.free(ack_msg);
        conn.sendBinary(ack_msg) catch {};

        // Check if transfer is complete
        if (session.bytes_transferred >= session.total_bytes) {
            const complete_msg = transfer.buildTransferComplete(self.allocator, session.id, session.bytes_transferred) catch return;
            defer self.allocator.free(complete_msg);
            conn.sendBinary(complete_msg) catch {};
            session.deleteState();
        } else {
            // Save state for resume
            session.saveState() catch {};
        }
    }

    // Handle TRANSFER_RESUME message
    fn handleTransferResume(self: *Server, conn: *ws.Connection, data: []u8) void {
        if (data.len < 5) return;

        const transfer_id = std.mem.readInt(u32, data[1..5], .little);

        // Try to load saved state
        const session = self.transfer_manager.resumeSession(transfer_id) catch |err| {
            std.debug.print("Failed to resume transfer {d}: {}\n", .{ transfer_id, err });
            const error_msg = transfer.buildTransferError(self.allocator, transfer_id, "Transfer state not found") catch return;
            defer self.allocator.free(error_msg);
            conn.sendBinary(error_msg) catch {};
            return;
        };

        conn.user_data = session;

        // Send TRANSFER_READY with resume position
        const ready_msg = transfer.buildTransferReadyEx(
            self.allocator,
            session.id,
            session.current_file_index,
            session.current_file_offset,
            session.bytes_transferred,
        ) catch return;
        defer self.allocator.free(ready_msg);
        conn.sendBinary(ready_msg) catch {};

        // For uploads, send file list so client can correlate file indices
        if (session.direction == .upload) {
            const list_msg = transfer.buildFileList(self.allocator, session) catch return;
            defer self.allocator.free(list_msg);
            conn.sendBinary(list_msg) catch {};
        } else {
            // For downloads, resume pushing files from saved position
            const list_msg = transfer.buildFileList(self.allocator, session) catch return;
            defer self.allocator.free(list_msg);
            conn.sendBinary(list_msg) catch {};
            self.pushDownloadFiles(conn, session);
        }

        std.debug.print("Resumed transfer {d} at file {d}, offset {d}, {d}/{d} bytes\n", .{
            session.id,
            session.current_file_index,
            session.current_file_offset,
            session.bytes_transferred,
            session.total_bytes,
        });
    }

    // Handle TRANSFER_CANCEL message
    fn handleTransferCancel(self: *Server, conn: *ws.Connection, data: []u8) void {
        if (data.len < 5) return;

        const transfer_id = std.mem.readInt(u32, data[1..5], .little);

        if (self.transfer_manager.getSession(transfer_id)) |session| {
            session.deleteState();
        }
        self.transfer_manager.removeSession(transfer_id);
        conn.user_data = null;

        std.debug.print("Transfer {d} cancelled\n", .{transfer_id});
    }

    // Handle SYNC_REQUEST message — incremental sync (rsync-style)
    fn handleSyncRequest(self: *Server, conn: *ws.Connection, data: []u8) void {
        var sync_data = transfer.parseSyncRequest(self.allocator, data) catch |err| {
            std.debug.print("Failed to parse SYNC_REQUEST: {}\n", .{err});
            return;
        };
        defer sync_data.deinit(self.allocator);

        // Resolve path: expand ~, join relative paths with initial_cwd
        const resolved_path = self.resolvePath(sync_data.path);
        defer if (resolved_path.ptr != self.initial_cwd.ptr) self.allocator.free(@constCast(resolved_path));

        // Create a download session for the sync
        const session = self.transfer_manager.createSession(.download, .{}, resolved_path) catch |err| {
            std.debug.print("Failed to create sync session: {}\n", .{err});
            return;
        };

        // Add exclude patterns
        for (sync_data.excludes) |pattern| {
            session.addExcludePattern(pattern) catch {};
        }

        conn.user_data = session;

        // Build file list (async: walk then batch hash)
        session.buildFileListAsync() catch |err| {
            std.debug.print("Failed to build sync file list: {}\n", .{err});
            const error_msg = transfer.buildTransferError(self.allocator, session.id, "Failed to read directory") catch return;
            defer self.allocator.free(error_msg);
            conn.sendBinary(error_msg) catch {};
            return;
        };

        // Send SYNC_FILE_LIST (same format as FILE_LIST but different msg type)
        const list_msg = transfer.buildSyncFileList(self.allocator, session) catch return;
        defer self.allocator.free(list_msg);
        conn.sendBinary(list_msg) catch {};

        std.debug.print("Sync session {d} created for {s} ({d} files)\n", .{
            session.id,
            resolved_path,
            session.files.items.len,
        });
    }

    // Handle BLOCK_CHECKSUMS message — client sends checksums of cached copy
    fn handleBlockChecksums(self: *Server, conn: *ws.Connection, data: []u8) void {
        const checksums_msg = transfer.parseBlockChecksums(self.allocator, data) catch |err| {
            std.debug.print("Failed to parse BLOCK_CHECKSUMS: {}\n", .{err});
            return;
        };
        defer self.allocator.free(checksums_msg.checksums);

        const session = self.transfer_manager.getSession(checksums_msg.transfer_id) orelse return;
        if (checksums_msg.file_index >= session.files.items.len) return;

        const file_entry = session.files.items[checksums_msg.file_index];
        if (file_entry.is_dir or file_entry.size == 0) return;

        // Read the server's copy of the file
        const server_data = session.readFileChunk(checksums_msg.file_index, 0, @intCast(file_entry.size)) catch |err| {
            std.debug.print("Failed to read file for delta: {s}: {}\n", .{ file_entry.path, err });
            return;
        };

        // Compute delta between server file and client's cached checksums
        const block_size = if (checksums_msg.block_size > 0)
            checksums_msg.block_size
        else
            transfer.computeBlockSize(file_entry.size);

        const delta_payload = if (checksums_msg.checksums.len > 0)
            transfer.computeDelta(self.allocator, server_data, checksums_msg.checksums, block_size) catch |err| {
                std.debug.print("Failed to compute delta for {s}: {}\n", .{ file_entry.path, err });
                // Fall back to sending full file as literal
                self.sendFullFileAsLiteral(conn, session, checksums_msg.file_index, server_data);
                session.closeCurrentFile();
                return;
            }
        else blk: {
            // No checksums — client has no cached copy, send full file as literal
            self.sendFullFileAsLiteral(conn, session, checksums_msg.file_index, server_data);
            session.closeCurrentFile();
            break :blk null;
        };

        if (delta_payload) |payload| {
            defer self.allocator.free(payload);
            session.closeCurrentFile();

            // Build and send DELTA_DATA message
            const delta_msg = transfer.buildDeltaData(self.allocator, session, checksums_msg.file_index, payload) catch return;
            defer self.allocator.free(delta_msg);
            conn.sendBinary(delta_msg) catch {};
        }
    }

    /// Send full file content as a DELTA_DATA with a single LITERAL command
    fn sendFullFileAsLiteral(self: *Server, conn: *ws.Connection, session: *transfer.TransferSession, file_index: u32, data: []const u8) void {
        // Build literal-only delta: [LITERAL:1][length:4][data...]
        const literal_payload = self.allocator.alloc(u8, 1 + 4 + data.len) catch return;
        defer self.allocator.free(literal_payload);

        literal_payload[0] = @intFromEnum(transfer.DeltaCmd.literal);
        std.mem.writeInt(u32, literal_payload[1..5], @intCast(data.len), .little);
        @memcpy(literal_payload[5..][0..data.len], data);

        const delta_msg = transfer.buildDeltaData(self.allocator, session, file_index, literal_payload) catch return;
        defer self.allocator.free(delta_msg);
        conn.sendBinary(delta_msg) catch {};
    }

    /// Context passed to each file-processing goroutine.
    const FileGoroutineCtx = struct {
        allocator: std.mem.Allocator,
        session_id: u32,
        file_index: u32,
        file_size: u64,
        file_path: []const u8, // Owned copy of relative path
        base_path: []const u8, // Borrowed from session (stable for transfer lifetime)
        is_active: *bool, // Pointer to session.is_active
        send_ch: *gchannel.GChannel(transfer.CompressedMsg),
        done_counter: *std.atomic.Value(usize), // Decremented when goroutine finishes

        fn deinit(self: *FileGoroutineCtx) void {
            self.allocator.free(self.file_path);
            self.allocator.destroy(self);
        }
    };

    /// Goroutine entry point: reads a file, compresses it, sends result to channel.
    /// Must use .c calling convention because the goroutine trampoline passes
    /// arg via rdi (x86_64) / x0 (aarch64) using the C ABI.
    fn processFileGoroutine(arg: *anyopaque) callconv(.c) void {
        const ctx: *FileGoroutineCtx = @ptrCast(@alignCast(arg));
        std.debug.print("[Goroutine] START: file_index={d}, path={s}\n", .{ ctx.file_index, ctx.file_path });
        // Save done_counter before ctx.deinit frees the struct.
        // Defers execute LIFO: deinit runs first, then fetchAdd signals completion.
        const done_counter = ctx.done_counter;
        defer _ = done_counter.fetchAdd(1, .release);
        defer ctx.deinit();

        if (!@atomicLoad(bool, ctx.is_active, .acquire)) {
            std.debug.print("[Goroutine] INACTIVE: file_index={d}\n", .{ctx.file_index});
            return;
        }

        const data = readFileForGoroutine(ctx.allocator, ctx.base_path, ctx.file_path, ctx.file_size) orelse {
            std.debug.print("[Goroutine] READ FAILED: file_index={d}\n", .{ctx.file_index});
            return;
        };
        defer ctx.allocator.free(data);

        if (!@atomicLoad(bool, ctx.is_active, .acquire)) return;

        const chunks = transfer.ParallelCompressor.compressChunksParallel(
            ctx.allocator,
            data,
            3,
        ) catch {
            std.debug.print("[Goroutine] COMPRESS FAILED: file_index={d}\n", .{ctx.file_index});
            return;
        };

        if (!ctx.send_ch.send(.{
            .file_index = ctx.file_index,
            .file_size = ctx.file_size,
            .chunks = chunks,
        })) {
            std.debug.print("[Goroutine] SEND FAILED (channel closed): file_index={d}\n", .{ctx.file_index});
            transfer.ParallelCompressor.freeChunks(ctx.allocator, chunks);
        } else {
            std.debug.print("[Goroutine] SUCCESS: file_index={d}\n", .{ctx.file_index});
        }
    }

    /// Read a file using pread. Safe to call from any goroutine/thread.
    fn readFileForGoroutine(allocator: std.mem.Allocator, base_path: []const u8, rel_path: []const u8, size: u64) ?[]u8 {
        var dir = std.fs.openDirAbsolute(base_path, .{}) catch return null;
        defer dir.close();

        var file = dir.openFile(rel_path, .{}) catch return null;
        defer file.close();

        const buf = allocator.alloc(u8, @intCast(size)) catch return null;
        const bytes_read = file.readAll(buf) catch {
            allocator.free(buf);
            return null;
        };

        if (bytes_read < buf.len) {
            // Short read — return what we got (shrink allocation)
            const trimmed = allocator.realloc(buf, bytes_read) catch return buf;
            return trimmed;
        }
        return buf;
    }

    /// Push all file chunks for a download transfer.
    /// Small files use batch I/O (MultiFileReader). Large files are processed
    /// concurrently via goroutines (read + compress in parallel, send results
    /// through a channel to the WS handler thread).
    fn pushDownloadFiles(self: *Server, conn: *ws.Connection, session: *transfer.TransferSession) void {
        std.debug.print("[pushDownloadFiles] START: transferId={d}, total files={d}\n", .{ session.id, session.files.items.len });
        const chunk_size: usize = 256 * 1024;
        var bytes_sent: u64 = 0;

        // Batch buffer for small files
        var batch_entries: std.ArrayListUnmanaged(transfer.BatchEntry) = .{};
        defer batch_entries.deinit(self.allocator);
        var batch_data_bufs: std.ArrayListUnmanaged([]const u8) = .{};
        defer {
            for (batch_data_bufs.items) |buf| self.allocator.free(buf);
            batch_data_bufs.deinit(self.allocator);
        }
        var batch_bytes: u64 = 0;

        // Accumulator for small file indices (batch-read on flush)
        var small_indices: std.ArrayListUnmanaged(u32) = .{};
        defer small_indices.deinit(self.allocator);
        var small_sizes: std.ArrayListUnmanaged(u64) = .{};
        defer small_sizes.deinit(self.allocator);
        var small_bytes: u64 = 0;

        // Create per-transfer channel for large file results (goroutines → WS thread)
        const GCh = gchannel.GChannel(transfer.CompressedMsg);
        const send_ch = GCh.initBuffered(self.allocator, self.goroutine_rt, 8) catch {
            self.pushDownloadFilesSerial(conn, session);
            return;
        };

        // Track goroutine completion so we can safely deinit the channel.
        // Goroutines hold pointers to send_ch — we must wait for all to finish
        // before freeing it to avoid use-after-free.
        var goroutine_done = std.atomic.Value(usize).init(0);
        var large_file_count: usize = 0;

        // Ensure channel outlives all goroutines: wait for completion then deinit
        defer {
            // Wait for all goroutines to finish before freeing channel
            while (goroutine_done.load(.acquire) < large_file_count) {
                std.Thread.sleep(100 * std.time.ns_per_us);
            }
            // Drain any buffered messages (free their chunks to avoid leaks)
            while (send_ch.recv()) |msg| {
                transfer.ParallelCompressor.freeChunks(self.allocator, msg.chunks);
            }
            send_ch.deinit();
        }

        for (session.files.items, 0..) |entry, i| {
            if (entry.is_dir) continue;
            if (!session.is_active) break;

            const file_index: u32 = @intCast(i);

            if (entry.size == 0) continue;

            if (entry.size <= transfer.batch_threshold) {
                small_indices.append(self.allocator, file_index) catch continue;
                small_sizes.append(self.allocator, entry.size) catch continue;
                small_bytes += entry.size;

                // Accumulate all small files - flush only when hitting a large file or at the end
                // This prevents sending many tiny BATCH_DATA messages
                continue;
            }

            // Flush accumulated small files before processing large file
            if (small_indices.items.len > 0) {
                self.flushSmallBatch(conn, session, &small_indices, &small_sizes, &small_bytes, &batch_entries, &batch_data_bufs, &batch_bytes, &bytes_sent, chunk_size);
            }
            // Don't flush batch_entries here - accumulate all small files into one big batch
            // Only flush at the end to avoid sending many tiny BATCH_DATA messages

            const file_path_copy = self.allocator.dupe(u8, entry.path) catch continue;
            const ctx = self.allocator.create(FileGoroutineCtx) catch {
                self.allocator.free(file_path_copy);
                continue;
            };
            ctx.* = .{
                .allocator = self.allocator,
                .session_id = session.id,
                .file_index = file_index,
                .file_size = entry.size,
                .file_path = file_path_copy,
                .base_path = session.base_path,
                .is_active = &session.is_active,
                .send_ch = send_ch,
                .done_counter = &goroutine_done,
            };
            _ = self.goroutine_rt.go(processFileGoroutine, @ptrCast(ctx)) catch {
                ctx.deinit();
                continue;
            };
            large_file_count += 1;
        }

        // Flush remaining small files
        std.debug.print("[pushDownloadFiles] Flushing remaining: small_indices={d}, batch_entries={d}, large_file_count={d}\n", .{ small_indices.items.len, batch_entries.items.len, large_file_count });
        if (small_indices.items.len > 0) {
            self.flushSmallBatch(conn, session, &small_indices, &small_sizes, &small_bytes, &batch_entries, &batch_data_bufs, &batch_bytes, &bytes_sent, chunk_size);
        }
        if (batch_entries.items.len > 0) {
            self.flushBatch(conn, session, &batch_entries, &batch_data_bufs, &batch_bytes, &bytes_sent);
        }

        // Receive compressed results from goroutines on this (WS handler) thread.
        // GChannel's recv() uses condition variable fallback for OS threads.
        std.debug.print("[pushDownloadFiles] Waiting for {d} large files from goroutines\n", .{large_file_count});
        var files_done: usize = 0;
        while (files_done < large_file_count) {
            if (!session.is_active) {
                send_ch.close();
                break;
            }
            const msg = send_ch.recv() orelse break;
            defer transfer.ParallelCompressor.freeChunks(self.allocator, msg.chunks);

            var chunk_offset: u64 = 0;
            for (msg.chunks) |compressed| {
                if (!session.is_active) break;

                const remaining = msg.file_size - chunk_offset;
                const this_chunk: u32 = @intCast(@min(chunk_size, remaining));

                const ws_msg = transfer.buildFileChunkPrecompressed(
                    self.allocator,
                    session.id,
                    msg.file_index,
                    chunk_offset,
                    this_chunk,
                    compressed,
                ) catch break;
                defer self.allocator.free(ws_msg);

                conn.sendBinary(ws_msg) catch return;

                chunk_offset += this_chunk;
                bytes_sent += this_chunk;
            }
            files_done += 1;
            std.debug.print("[pushDownloadFiles] Received large file from goroutine: {d}/{d}\n", .{ files_done, large_file_count });
        }

        std.debug.print("[pushDownloadFiles] All large files received, sending TRANSFER_COMPLETE\n", .{});
        std.debug.print("[pushDownloadFiles] Summary: transferId={d}, total_entries={d}, large_files={d}, bytes_sent={d}\n", .{ session.id, session.files.items.len, large_file_count, bytes_sent });
        const complete_msg = transfer.buildTransferComplete(self.allocator, session.id, bytes_sent) catch return;
        defer self.allocator.free(complete_msg);
        conn.sendBinary(complete_msg) catch |err| {
            std.debug.print("[pushDownloadFiles] ERROR sending TRANSFER_COMPLETE: {}\n", .{err});
            return;
        };
        std.debug.print("[pushDownloadFiles] TRANSFER_COMPLETE sent successfully (msg_size={d})\n", .{complete_msg.len});

        std.debug.print("Download complete: {d} bytes sent across {d} files ({d} large via goroutines)\n", .{ bytes_sent, session.files.items.len, large_file_count });

        // Clean up session after successful download
        self.transfer_manager.removeSession(session.id);
        conn.user_data = null;
    }

    /// Serial fallback for pushDownloadFiles (used when goroutine channel creation fails).
    fn pushDownloadFilesSerial(self: *Server, conn: *ws.Connection, session: *transfer.TransferSession) void {
        const chunk_size: usize = 256 * 1024;
        var bytes_sent: u64 = 0;

        var batch_entries: std.ArrayListUnmanaged(transfer.BatchEntry) = .{};
        defer batch_entries.deinit(self.allocator);
        var batch_data_bufs: std.ArrayListUnmanaged([]const u8) = .{};
        defer {
            for (batch_data_bufs.items) |buf| self.allocator.free(buf);
            batch_data_bufs.deinit(self.allocator);
        }
        var batch_bytes: u64 = 0;

        var small_indices: std.ArrayListUnmanaged(u32) = .{};
        defer small_indices.deinit(self.allocator);
        var small_sizes: std.ArrayListUnmanaged(u64) = .{};
        defer small_sizes.deinit(self.allocator);
        var small_bytes: u64 = 0;

        for (session.files.items, 0..) |entry, i| {
            if (entry.is_dir) continue;
            if (!session.is_active) break;

            const file_index: u32 = @intCast(i);
            if (entry.size == 0) continue;

            if (entry.size <= transfer.batch_threshold) {
                small_indices.append(self.allocator, file_index) catch continue;
                small_sizes.append(self.allocator, entry.size) catch continue;
                small_bytes += entry.size;
                if (small_bytes >= chunk_size or small_indices.items.len >= 64) {
                    self.flushSmallBatch(conn, session, &small_indices, &small_sizes, &small_bytes, &batch_entries, &batch_data_bufs, &batch_bytes, &bytes_sent, chunk_size);
                }
                continue;
            }

            if (small_indices.items.len > 0) {
                self.flushSmallBatch(conn, session, &small_indices, &small_sizes, &small_bytes, &batch_entries, &batch_data_bufs, &batch_bytes, &bytes_sent, chunk_size);
            }
            if (batch_entries.items.len > 0) {
                self.flushBatch(conn, session, &batch_entries, &batch_data_bufs, &batch_bytes, &bytes_sent);
            }

            // Serial: read via platform I/O, compress, send
            const owned_buf: ?[]u8 = if (comptime is_linux) blk: {
                break :blk session.readFileViaUring(file_index, self.allocator) catch |err| {
                    std.debug.print("io_uring read failed for {s}: {}\n", .{ entry.path, err });
                    break :blk null;
                };
            } else if (comptime is_macos) blk: {
                break :blk session.readFileViaDispatchIO(file_index, self.allocator) catch |err| {
                    std.debug.print("dispatch_io read failed for {s}: {}\n", .{ entry.path, err });
                    break :blk null;
                };
            } else null;

            const file_data: []const u8 = if (owned_buf) |ud| ud else blk: {
                if (i + 1 < session.files.items.len) {
                    const next_entry = session.files.items[i + 1];
                    if (!next_entry.is_dir and next_entry.size > 0) {
                        self.prefetchFile(session, @intCast(i + 1));
                    }
                }
                break :blk session.readFileChunk(file_index, 0, @intCast(entry.size)) catch |err| {
                    std.debug.print("Failed to read file {s}: {}\n", .{ entry.path, err });
                    const error_msg = transfer.buildTransferError(self.allocator, session.id, "Failed to read file") catch return;
                    defer self.allocator.free(error_msg);
                    conn.sendBinary(error_msg) catch {};
                    return;
                };
            };
            defer {
                if (owned_buf) |ud| self.allocator.free(ud) else session.closeCurrentFile();
            }

            const compressed_chunks = transfer.ParallelCompressor.compressChunksParallel(
                self.allocator,
                file_data,
                3,
            ) catch |err| {
                std.debug.print("Parallel compression failed for {s}: {}, falling back\n", .{ entry.path, err });
                self.pushFileSequential(conn, session, file_index, entry.size, chunk_size, &bytes_sent);
                continue;
            };
            defer transfer.ParallelCompressor.freeChunks(self.allocator, compressed_chunks);

            var chunk_offset: u64 = 0;
            for (compressed_chunks, 0..) |compressed, ci| {
                if (!session.is_active) break;
                const remaining = entry.size - chunk_offset;
                const this_chunk: u32 = @intCast(@min(chunk_size, remaining));
                const ws_msg = transfer.buildFileChunkPrecompressed(
                    self.allocator,
                    session.id,
                    file_index,
                    chunk_offset,
                    this_chunk,
                    compressed,
                ) catch |err| {
                    std.debug.print("Failed to build chunk {d} for {s}: {}\n", .{ ci, entry.path, err });
                    break;
                };
                defer self.allocator.free(ws_msg);
                conn.sendBinary(ws_msg) catch return;
                chunk_offset += this_chunk;
                bytes_sent += this_chunk;
            }
        }

        if (small_indices.items.len > 0) {
            self.flushSmallBatch(conn, session, &small_indices, &small_sizes, &small_bytes, &batch_entries, &batch_data_bufs, &batch_bytes, &bytes_sent, chunk_size);
        }
        if (batch_entries.items.len > 0) {
            self.flushBatch(conn, session, &batch_entries, &batch_data_bufs, &batch_bytes, &bytes_sent);
        }

        const complete_msg = transfer.buildTransferComplete(self.allocator, session.id, bytes_sent) catch return;
        defer self.allocator.free(complete_msg);
        conn.sendBinary(complete_msg) catch {};
        std.debug.print("Download complete (serial fallback): {d} bytes sent\n", .{bytes_sent});

        // Clean up session after successful download
        self.transfer_manager.removeSession(session.id);
        conn.user_data = null;
    }

    fn flushBatch(
        self: *Server,
        conn: *ws.Connection,
        session: *transfer.TransferSession,
        batch_entries: *std.ArrayListUnmanaged(transfer.BatchEntry),
        batch_data_bufs: *std.ArrayListUnmanaged([]const u8),
        batch_bytes: *u64,
        bytes_sent: *u64,
    ) void {
        if (batch_entries.items.len == 0) return;

        std.debug.print("[flushBatch] Sending {d} files: indices ", .{batch_entries.items.len});
        for (batch_entries.items, 0..) |entry, i| {
            if (i < 10) std.debug.print("{d} ", .{entry.file_index});
        }
        if (batch_entries.items.len > 10) std.debug.print("... ({d} more)", .{batch_entries.items.len - 10});
        std.debug.print("\n", .{});

        const msg = transfer.buildBatchData(self.allocator, session, batch_entries.items) catch |err| {
            std.debug.print("Failed to build batch: {}\n", .{err});
            // Fallback: send each file individually via FILE_REQUEST
            for (batch_entries.items) |entry| {
                const fallback = transfer.buildFileRequest(self.allocator, session, entry.file_index, 0, entry.data) catch continue;
                defer self.allocator.free(fallback);
                conn.sendBinary(fallback) catch {};
            }
            bytes_sent.* += batch_bytes.*;
            self.clearBatch(batch_entries, batch_data_bufs, batch_bytes);
            return;
        };
        defer self.allocator.free(msg);

        conn.sendBinary(msg) catch |err| {
            std.debug.print("[flushBatch] ERROR sending batch: {}\n", .{err});
        };
        bytes_sent.* += batch_bytes.*;
        self.clearBatch(batch_entries, batch_data_bufs, batch_bytes);
    }

    fn clearBatch(
        self: *Server,
        batch_entries: *std.ArrayListUnmanaged(transfer.BatchEntry),
        batch_data_bufs: *std.ArrayListUnmanaged([]const u8),
        batch_bytes: *u64,
    ) void {
        for (batch_data_bufs.items) |buf| self.allocator.free(buf);
        batch_data_bufs.clearRetainingCapacity();
        batch_entries.clearRetainingCapacity();
        batch_bytes.* = 0;
    }

    /// Batch-read accumulated small files via MultiFileReader
    /// (io_uring on Linux, dispatch_apply on macOS, sequential pread on other).
    /// No fallback — each platform compiles only its optimal path.
    fn flushSmallBatch(
        self: *Server,
        _: *ws.Connection,
        session: *transfer.TransferSession,
        small_indices: *std.ArrayListUnmanaged(u32),
        small_sizes: *std.ArrayListUnmanaged(u64),
        small_bytes: *u64,
        batch_entries: *std.ArrayListUnmanaged(transfer.BatchEntry),
        batch_data_bufs: *std.ArrayListUnmanaged([]const u8),
        batch_bytes: *u64,
        _: *u64,
        _: usize,
    ) void {
        const count = small_indices.items.len;
        if (count == 0) return;

        defer {
            small_indices.clearRetainingCapacity();
            small_sizes.clearRetainingCapacity();
            small_bytes.* = 0;
        }

        // Build null-terminated relative paths for MultiFileReader
        const z_paths = self.allocator.alloc([*:0]const u8, count) catch |err| {
            std.debug.print("flushSmallBatch: alloc z_paths failed: {}\n", .{err});
            return;
        };
        defer self.allocator.free(z_paths);
        var allocated: usize = 0;
        defer for (z_paths[0..allocated]) |p| self.allocator.free(std.mem.span(p));

        for (small_indices.items, 0..) |fi, idx| {
            z_paths[idx] = self.allocator.dupeZ(u8, session.files.items[fi].path) catch |err| {
                std.debug.print("flushSmallBatch: dupeZ path failed: {}\n", .{err});
                return;
            };
            allocated = idx + 1;
        }

        // Open base directory for relative path reads
        var dir = std.fs.openDirAbsolute(session.base_path, .{}) catch |err| {
            std.debug.print("flushSmallBatch: openDir '{s}' failed: {}\n", .{ session.base_path, err });
            return;
        };
        defer dir.close();

        // MultiFileReader: io_uring on Linux, dispatch_apply on macOS, pread on other
        var reader = transfer.MultiFileReader.init(dir.fd, self.allocator) catch |err| {
            std.debug.print("flushSmallBatch: MultiFileReader init failed: {}\n", .{err});
            return;
        };
        defer reader.deinit();

        const results = reader.readFiles(z_paths, small_sizes.items) catch |err| {
            std.debug.print("flushSmallBatch: readFiles failed: {}\n", .{err});
            return;
        };
        defer self.allocator.free(results);

        // Build batch entries from read results
        for (small_indices.items, 0..) |fi, idx| {
            const r = results[idx];
            if (r.size == 0 and r.data.len == 0) {
                std.debug.print("flushSmallBatch: file {d} '{s}' read returned empty\n", .{ fi, session.files.items[fi].path });
                continue;
            }

            const data = if (r.size < r.data.len) blk: {
                const trimmed = self.allocator.dupe(u8, r.data[0..r.size]) catch continue;
                self.allocator.free(r.data);
                break :blk trimmed;
            } else r.data;

            batch_data_bufs.append(self.allocator, data) catch {
                self.allocator.free(data);
                continue;
            };
            batch_entries.append(self.allocator, .{ .file_index = fi, .data = data }) catch continue;
            batch_bytes.* += session.files.items[fi].size;
        }

        // Don't flush here - let caller decide when to flush to avoid sending too many small batches
        // This accumulates files into batch_entries for efficient batching
    }

    /// Prefetch a file into memory using madvise(WILLNEED).
    /// This triggers the kernel to read-ahead the file's pages while we process the current file.
    fn prefetchFile(self: *Server, session: *transfer.TransferSession, file_index: u32) void {
        // Temporarily map the file and advise the kernel
        const entry = session.files.items[file_index];
        const full_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ session.base_path, entry.path }) catch return;
        defer self.allocator.free(full_path);

        var mapped = transfer.MappedFile.init(full_path) catch return;
        mapped.adviseWillNeed();
        mapped.deinit();
    }

    /// Fallback: send a large file chunk-by-chunk with sequential compression.
    /// Used when parallel compression fails.
    fn pushFileSequential(
        self: *Server,
        conn: *ws.Connection,
        session: *transfer.TransferSession,
        file_index: u32,
        file_size: u64,
        chunk_size: usize,
        bytes_sent: *u64,
    ) void {
        var chunk_offset: u64 = 0;
        while (chunk_offset < file_size) {
            if (!session.is_active) break;

            const remaining = file_size - chunk_offset;
            const this_chunk = @min(chunk_size, remaining);

            const msg = transfer.buildFileChunk(self.allocator, session, file_index, chunk_offset, this_chunk) catch |err| {
                std.debug.print("Failed to build file chunk: {}\n", .{err});
                return;
            };
            defer self.allocator.free(msg);

            conn.sendBinary(msg) catch return;

            chunk_offset += this_chunk;
            bytes_sent.* += this_chunk;
        }
        session.closeCurrentFile();
    }

    // Send dry run report
    fn sendDryRunReport(self: *Server, conn: *ws.Connection, session: *transfer.TransferSession) void {
        var entries: std.ArrayListUnmanaged(transfer.DryRunEntry) = .{};
        defer entries.deinit(self.allocator);

        for (session.files.items) |file| {
            entries.append(self.allocator, .{
                .action = .create, // TODO: Compare with destination to determine update/create
                .path = file.path,
                .size = file.size,
            }) catch {};
        }

        const report_msg = transfer.buildDryRunReport(self.allocator, session.id, entries.items) catch |err| {
            std.debug.print("Failed to build dry run report: {}\n", .{err});
            return;
        };
        defer self.allocator.free(report_msg);
        conn.sendBinary(report_msg) catch |err| {
            std.debug.print("Failed to send dry run report: {}\n", .{err});
        };

        // Clean up session after sending dry run report
        self.transfer_manager.removeSession(session.id);
        conn.user_data = null;
    }

    /// Resolve a client-supplied path to an absolute path.
    /// Handles: ~ expansion, relative paths (joined with initial_cwd), empty → initial_cwd.
    fn resolvePath(self: *Server, path: []const u8) []const u8 {
        if (path.len == 0) return self.initial_cwd;

        // Expand ~ to $HOME
        if (path[0] == '~') {
            const home = std.posix.getenv("HOME") orelse return self.initial_cwd;
            if (path.len == 1) {
                return home;
            }
            // ~/foo or ~foo — only expand ~/
            if (path[1] == '/') {
                return std.fmt.allocPrint(self.allocator, "{s}{s}", .{ home, path[1..] }) catch return self.initial_cwd;
            }
            // ~something — not a valid expansion, treat as relative
            return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.initial_cwd, path }) catch return self.initial_cwd;
        }

        // Already absolute
        if (std.fs.path.isAbsolute(path)) {
            return self.allocator.dupe(u8, path) catch return self.initial_cwd;
        }

        // Relative path — join with initial_cwd
        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.initial_cwd, path }) catch return self.initial_cwd;
    }

    // Process pending panel creation requests (must run on main thread)
    fn processPendingPanels(self: *Server) void {
        while (self.pending_panels_ch.tryRecv()) |req| {
            // Determine CWD: inherit from specified panel, or use initial_cwd
            const working_dir: []const u8 = if (req.inherit_cwd_from != 0) blk: {
                if (self.panels.get(req.inherit_cwd_from)) |parent_panel| {
                    if (parent_panel.pwd.len > 0) break :blk parent_panel.pwd;
                }
                break :blk self.initial_cwd;
            } else self.initial_cwd;

            const panel = self.createPanelWithOptions(req.width, req.height, req.scale, working_dir, req.kind) catch {
                continue;
            };

            // Panel starts streaming immediately (H264 frames sent to all h264_connections)
            self.broadcastPanelCreated(panel.id);
            // Only broadcast layout update for regular panels (quick terminal is outside layout)
            if (req.kind == .regular) {
                self.broadcastLayoutUpdate();
            }

            // Broadcast initial pwd so clients have it before shell emits OSC 7
            self.broadcastPanelPwd(panel.id, working_dir);

            // Linux only: Send initial title since shell integration may not be configured
            // macOS works fine without this as ghostty auto-injects shell integration
            if (comptime is_linux) {
                const user = std.posix.getenv("USER") orelse "user";
                var host_buf: [64]u8 = undefined;
                const hostname: []const u8 = if (std.posix.getenv("HOSTNAME")) |h| h else blk: {
                    const result = std.posix.gethostname(&host_buf) catch break :blk "localhost";
                    break :blk if (std.mem.indexOf(u8, result, ".")) |idx| result[0..idx] else result;
                };
                var title_buf: [256]u8 = undefined;
                const initial_title = std.fmt.bufPrint(&title_buf, "{s}@{s}:~", .{ user, hostname }) catch "Terminal";
                self.broadcastPanelTitle(panel.id, initial_title);
            }
        }
    }

    // Process pending panel destruction requests (must run on main thread)
    fn processPendingDestroys(self: *Server) void {
        while (self.pending_destroys_ch.tryRecv()) |req| {
            self.mutex.lock();
            if (self.panels.fetchRemove(req.id)) |entry| {
                const panel = entry.value;

                // Remove from layout
                self.layout.removePanel(req.id);

                // Remove panel assignment if any
                const had_assignment = if (self.panel_assignments.fetchRemove(req.id)) |old| blk: {
                    self.allocator.free(old.value);
                    break :blk true;
                } else false;

                self.mutex.unlock();

                panel.deinit();

                // Notify clients
                self.broadcastPanelClosed(req.id);

                // Broadcast unassignment if panel was assigned
                if (had_assignment) {
                    self.broadcastPanelAssignment(req.id, "");
                }

                // Broadcast updated layout
                self.broadcastLayoutUpdate();
            } else {
                self.mutex.unlock();
            }
        }

        // Free ghostty if no panels left (scale to zero)
        self.freeGhosttyIfEmpty();
    }

    fn processPendingResizes(self: *Server) void {
        while (self.pending_resizes_ch.tryRecv()) |req| {
            self.mutex.lock();
            if (self.panels.get(req.id)) |panel| {
                self.mutex.unlock();
                panel.resizeInternal(req.width, req.height, req.scale) catch {};

                // Send inspector update if subscribed (broadcast to all control connections)
                if (panel.inspector_subscribed) {
                    self.mutex.lock();
                    self.broadcastInspectorStateToAll(panel);
                    self.mutex.unlock();
                }
            } else {
                self.mutex.unlock();
            }
        }
    }

    // Process pending panel split requests (must run on main thread)
    fn processPendingSplits(self: *Server) void {
        while (self.pending_splits_ch.tryRecv()) |req| {
            // Pause parent panel to prevent frame capture race during split
            // The parent will resume when client sends resize after layout update
            self.mutex.lock();
            const parent_panel = self.panels.get(req.parent_panel_id);
            self.mutex.unlock();
            if (parent_panel) |parent| {
                parent.pause();
            }

            const panel = self.createPanelAsSplit(req.width, req.height, req.scale, req.parent_panel_id, req.direction) catch |err| {
                std.debug.print("Failed to create split panel: {}\n", .{err});
                // Resume parent on failure
                if (parent_panel) |parent| {
                    parent.resumeStream();
                }
                continue;
            };

            // Panel starts streaming immediately (H264 frames sent to all h264_connections)
            self.broadcastPanelCreated(panel.id);
            self.broadcastLayoutUpdate();

            // Broadcast initial pwd (inherit from parent or use initial_cwd)
            {
                const inherit_pwd = if (parent_panel) |parent| (if (parent.pwd.len > 0) parent.pwd else self.initial_cwd) else self.initial_cwd;
                self.broadcastPanelPwd(panel.id, inherit_pwd);
            }

            // Resume parent panel streaming (will get keyframe on next frame)
            // Note: If parent will be resized, resizeInternal sets force_keyframe
            if (parent_panel) |parent| {
                parent.resumeStream();
            }
        }
    }

    // Main render loop
    fn runRenderLoop(self: *Server) void {
        // Adaptive frame timing: render immediately on input for snappy response,
        // but keep steady 30fps otherwise. Burst mode not used because H.264
        // encoding at ~15ms/panel/frame can't sustain 60fps with multiple panels.
        const frame_time_ns: u64 = std.time.ns_per_s / 30; // 33.3ms

        var last_frame: i128 = 0;

        // DEBUG: FPS counter
        var fps_counter: u32 = 0;
        var fps_attempts: u32 = 0;
        var fps_dropped: u32 = 0;
        var frame_blocks: u32 = 0;
        var fps_timer: i128 = std.time.nanoTimestamp();

        // Open perf log file (append mode, create if not exists)
        const perf_log = std.fs.cwd().createFile("/tmp/termweb-perf.log", .{ .truncate = true }) catch null;
        defer if (perf_log) |f| f.close();

        // Debug log for tracing new panel frame delivery
        const dbg_log = std.fs.cwd().createFile("/tmp/termweb-panel-debug.log", .{ .truncate = true }) catch null;
        defer if (dbg_log) |f| f.close();

        std.debug.print("Render loop started, running={}\n", .{self.running.load(.acquire)});
        if (perf_log != null) std.debug.print("PERF log: /tmp/termweb-perf.log\n", .{});
        if (dbg_log != null) std.debug.print("DEBUG log: /tmp/termweb-panel-debug.log\n", .{});

        while (self.running.load(.acquire)) {

            // Create autorelease pool for this iteration (macOS only - prevents ObjC object accumulation)
            const pool = if (comptime is_macos) objc_autoreleasePoolPush() else null;
            defer if (comptime is_macos) objc_autoreleasePoolPop(pool);

            // Process pending panel creations/destructions/resizes/splits (NSWindow/ghostty must be on main thread)
            crash_phase.store(1, .monotonic); // processPendingPanels
            self.processPendingPanels();
            crash_phase.store(2, .monotonic); // processPendingDestroys
            self.processPendingDestroys();
            self.processPendingResizes();
            self.processPendingSplits();

            // Process input for all panels (more responsive than frame rate)
            // Collect panels first, then release mutex before calling ghostty
            // (ghostty callbacks may need the mutex)
            var panels_buf: [64]*Panel = undefined;
            var panels_count: usize = 0;
            self.mutex.lock();
            var panel_it = self.panels.valueIterator();
            while (panel_it.next()) |panel_ptr| {
                if (panels_count < panels_buf.len) {
                    panels_buf[panels_count] = panel_ptr.*;
                    panels_count += 1;
                }
            }
            self.mutex.unlock();

            // Process input (fast - no rendering)
            crash_phase.store(3, .monotonic); // processInputQueue
            for (panels_buf[0..panels_count]) |panel| {
                panel.processInputQueue();
            }

            // Capture and send frames at target fps
            const now = std.time.nanoTimestamp();
            const since_last_frame: u64 = @intCast(now - last_frame);
            if (since_last_frame >= frame_time_ns) {
                // Log if frame gap is >100ms (expecting ~33ms) — catches sleep overshoot
                // or pre-frame work (processPending*, input) taking too long
                const gap_threshold_ns: u64 = 100 * std.time.ns_per_ms;
                if (since_last_frame > gap_threshold_ns and last_frame > 0) {
                    if (perf_log) |f| {
                        var gap_buf: [128]u8 = undefined;
                        const gap_line = std.fmt.bufPrint(&gap_buf, "GAP {d}ms between frames\n", .{
                            since_last_frame / std.time.ns_per_ms,
                        }) catch "";
                        _ = f.write(gap_line) catch {};
                    }
                }
                last_frame = now;

                frame_blocks += 1;

                // Check if we have H264 clients and overview mode
                self.mutex.lock();
                const has_h264_clients = self.h264_connections.items.len > 0;
                const is_overview = self.overview_open;
                self.mutex.unlock();

                // Tick ghostty to render content to IOSurface
                crash_phase.store(4, .monotonic); // ghostty_app_tick
                const t_app_tick = std.time.nanoTimestamp();
                self.tick();
                const app_tick_ns: u64 = @intCast(std.time.nanoTimestamp() - t_app_tick);

                var frames_sent: u32 = 0;
                var frames_attempted: u32 = 0;
                var frames_dropped: u32 = 0;

                // Collect panels to process (release mutex before heavy encode work)
                var frame_panels_buf: [64]*Panel = undefined;
                var frame_panels_count: usize = 0;
                self.mutex.lock();

                // Determine which panel is focused and which are in the active tab
                const focused_panel_id = self.layout.active_panel_id;
                const active_tab_id = self.layout.getActiveTabId();
                var active_panel_ids_buf: [64]u32 = undefined;
                var active_panel_count: usize = 0;
                if (active_tab_id) |atid| {
                    for (self.layout.tabs.items) |tab| {
                        if (tab.id == atid) {
                            active_panel_count = tab.collectPanelIdsInto(&active_panel_ids_buf);
                            break;
                        }
                    }
                }

                panel_it = self.panels.valueIterator();
                while (panel_it.next()) |panel_ptr| {
                    const panel = panel_ptr.*;
                    const is_paused = !panel.streaming.load(.acquire);

                    // Skip paused panels (during split operations)
                    if (is_paused) continue;

                    // Check if panel is in the active tab
                    var in_active = false;
                    for (active_panel_ids_buf[0..active_panel_count]) |pid| {
                        if (pid == panel.id) {
                            in_active = true;
                            break;
                        }
                    }
                    // Quick terminal panels are always active
                    if (!in_active and panel.kind == .quick_terminal) {
                        in_active = true;
                    }

                    // Debug: trace new panels (first 10 ticks)
                    if (panel.ticks_since_connect < 10) {
                        if (dbg_log) |f| {
                            var dbg_buf: [256]u8 = undefined;
                            const dbg_line = std.fmt.bufPrint(&dbg_buf, "COLLECT panel={d} tick={d} in_active={} overview={} h264_clients={} force_kf={} consec_unch={d}\n", .{
                                panel.id, panel.ticks_since_connect, in_active, is_overview, has_h264_clients, panel.force_keyframe, panel.consecutive_unchanged,
                            }) catch "";
                            _ = f.write(dbg_line) catch {};
                        }
                    }

                    // Skip panels not in active tab (unless overview is open = need all panels)
                    if (!in_active and !is_overview) continue;
                    // Skip if no H264 clients connected
                    if (!has_h264_clients) continue;

                    if (frame_panels_count < frame_panels_buf.len) {
                        frame_panels_buf[frame_panels_count] = panel;
                        frame_panels_count += 1;
                    }
                }
                self.mutex.unlock();

                // Move focused panel to front so it gets encoded first.
                // Reduces input latency for the active panel by ~15ms per
                // additional panel (avoids waiting for other panels to encode).
                if (focused_panel_id) |fid| {
                    if (frame_panels_count < 2) {} else for (frame_panels_buf[1..frame_panels_count], 1..) |panel, i| {
                        if (panel.id == fid) {
                            frame_panels_buf[i] = frame_panels_buf[0];
                            frame_panels_buf[0] = panel;
                            break;
                        }
                    }
                }

                // Set headless focus flag on each panel — a single bool write
                // with zero ghostty API overhead. Surface.draw() reads this
                // flag and syncs it to core_surface.focused and renderer.focused.
                for (frame_panels_buf[0..frame_panels_count]) |panel| {
                    const should_focus = if (focused_panel_id) |fid| panel.id == fid else false;
                    c.ghostty_surface_set_headless_focus(panel.surface, should_focus);
                }

                // Distribute pixel budget proportionally based on each panel's
                // visible pixel area. The tier's max_pixels is a TOTAL budget
                // for all panels combined. If total visible pixels fit within
                // the budget, every panel encodes at native resolution (no
                // downscale). Only when total exceeds the budget do panels get
                // proportionally scaled down.
                if (frame_panels_count > 0) {
                    // Find the lowest tier budget across encoders (conservative)
                    var tier_budget: u64 = 0;
                    var total_visible: u64 = 0;
                    for (frame_panels_buf[0..frame_panels_count]) |panel| {
                        if (panel.video_encoder) |enc| {
                            const t = enc.tierMaxPixels();
                            if (tier_budget == 0 or t < tier_budget) tier_budget = t;
                        }
                        const pw = panel.getPixelWidth();
                        const ph = panel.getPixelHeight();
                        total_visible += @as(u64, pw) * @as(u64, ph);
                    }
                    if (tier_budget > 0 and total_visible > 0) {
                        if (total_visible <= tier_budget) {
                            // All panels fit at native resolution — no cap needed.
                            // Set each panel's budget to its own visible pixels
                            // (effectively unlimited for this panel's source size).
                            for (frame_panels_buf[0..frame_panels_count]) |panel| {
                                if (panel.video_encoder) |enc| {
                                    const pw = panel.getPixelWidth();
                                    const ph = panel.getPixelHeight();
                                    enc.setPixelBudget(@as(u64, pw) * @as(u64, ph));
                                }
                            }
                        } else {
                            // Total exceeds budget — scale each panel proportionally.
                            // panel_budget = tier_budget * (panel_pixels / total_pixels)
                            for (frame_panels_buf[0..frame_panels_count]) |panel| {
                                if (panel.video_encoder) |enc| {
                                    const pw = panel.getPixelWidth();
                                    const ph = panel.getPixelHeight();
                                    const panel_pixels = @as(u64, pw) * @as(u64, ph);
                                    const budget = @as(u64, @intFromFloat(
                                        @as(f64, @floatFromInt(tier_budget)) *
                                            (@as(f64, @floatFromInt(panel_pixels)) /
                                            @as(f64, @floatFromInt(total_visible))),
                                    ));
                                    enc.setPixelBudget(@max(budget, 640 * 480));
                                }
                            }
                        }
                    }
                }

                // Process each panel WITHOUT holding the server mutex
                // This prevents mutex starvation when encoding takes 100+ms per panel
                var perf_tick_ns: u64 = 0;
                var perf_read_ns: u64 = 0;
                var perf_encode_ns: u64 = 0;
                var perf_input_latency_us: i64 = 0; // Latest input-to-frame-send latency
                for (frame_panels_buf[0..frame_panels_count]) |panel| {

                    frames_attempted += 1;
                    const t_frame_start = std.time.nanoTimestamp();

                    // Per-panel adaptive FPS: when encoder's quality tier has fps < 30,
                    // skip frames to match the tier's target rate. This saves encode
                    // bandwidth on degraded connections. Input and keyframe requests bypass.
                    if (panel.video_encoder) |encoder| {
                        if (encoder.target_fps < 30 and
                            !panel.force_keyframe and
                            !panel.has_pending_input.load(.acquire))
                        {
                            const panel_interval_ns: i64 = @divFloor(std.time.ns_per_s, @as(i64, encoder.target_fps));
                            const elapsed = t_frame_start - panel.last_frame_time;
                            if (elapsed < panel_interval_ns) {
                                continue;
                            }
                        }
                    }

                    // Adaptive idle mode: when terminal content is unchanged for ~1s,
                    // reduce tick rate to save CPU/GPU (cursor/spinner checks only).
                    // Input or force_keyframe (reconnection) resets immediately.
                    // Bypass when overview is open so all panels stream live.
                    if (panel.consecutive_unchanged >= Panel.IDLE_THRESHOLD and
                        !panel.force_keyframe and
                        !panel.has_pending_input.load(.acquire) and
                        !is_overview)
                    {
                        if (panel.consecutive_unchanged % Panel.IDLE_DIVISOR != 0) {
                            panel.consecutive_unchanged += 1;
                            continue;
                        }
                    }

                    // Scoped autorelease pool for ALL ObjC/Metal objects created during this panel's frame (macOS only)
                    const draw_pool = if (comptime is_macos) objc_autoreleasePoolPush() else null;
                    defer if (comptime is_macos) objc_autoreleasePoolPop(draw_pool);

                    // Render panel content to IOSurface
                    crash_phase.store(5, .monotonic); // ghostty_surface_draw
                    const t_tick = std.time.nanoTimestamp();
                    panel.tick();
                    const tick_elapsed: u64 = @intCast(std.time.nanoTimestamp() - t_tick);
                    perf_tick_ns += tick_elapsed;

                    // Platform-specific frame capture
                    var frame_data: ?[]const u8 = null;
                    var read_elapsed: u64 = 0;
                    var enc_elapsed: u64 = 0;
                    var was_keyframe = false;
                    var send_failed = false;

                    if (comptime is_macos) {
                        if (panel.getIOSurface()) |iosurface| {
                            // BGRA copy path - skip encode if surface unchanged
                            const changed = panel.captureFromIOSurface(iosurface) catch continue;
                            if (!changed) {
                                panel.consecutive_unchanged += 1;
                                continue;
                            }
                            panel.consecutive_unchanged = 0;

                            if (panel.prepareFrame() catch null) |result| {
                                frame_data = result.data;
                            }
                        }
                    } else if (comptime is_linux) {
                        // Linux: Capture from OpenGL framebuffer via ghostty
                        const pixel_width = panel.getPixelWidth();
                        const pixel_height = panel.getPixelHeight();
                        const buffer_size = @as(usize, pixel_width) * @as(usize, pixel_height) * 4;

                        // Lazy init video encoder and BGRA buffer for Linux
                        if (panel.video_encoder == null) {
                            panel.video_encoder = if (self.shared_va_ctx) |*ctx|
                                video.VideoEncoder.initWithShared(panel.allocator, ctx, pixel_width, pixel_height) catch null
                            else
                                null;
                            if (panel.video_encoder != null) {
                                panel.bgra_buffer = panel.allocator.alloc(u8, buffer_size) catch {
                                    panel.video_encoder.?.deinit();
                                    panel.video_encoder = null;
                                    continue;
                                };
                            }
                        }

                        if (panel.video_encoder == null or panel.bgra_buffer == null) {
                            if (panel.ticks_since_connect < 10) {
                                if (dbg_log) |f| {
                                    var dbg_buf: [128]u8 = undefined;
                                    const dbg_line = std.fmt.bufPrint(&dbg_buf, "NO_ENCODER panel={d} tick={d} enc={} buf={}\n", .{ panel.id, panel.ticks_since_connect, panel.video_encoder != null, panel.bgra_buffer != null }) catch "";
                                    _ = f.write(dbg_line) catch {};
                                }
                            }
                            continue;
                        }

                        // Resize encoder if dimensions changed
                        if (pixel_width != panel.video_encoder.?.source_width or pixel_height != panel.video_encoder.?.source_height) {
                            panel.video_encoder.?.resize(pixel_width, pixel_height) catch continue;
                            if (panel.bgra_buffer.?.len != buffer_size) {
                                panel.allocator.free(panel.bgra_buffer.?);
                                panel.bgra_buffer = panel.allocator.alloc(u8, buffer_size) catch continue;
                            }
                        }

                        // Wait a few frames for ghostty to render initial content
                        if (panel.ticks_since_connect < 3) {
                            if (dbg_log) |f| {
                                var dbg_buf: [128]u8 = undefined;
                                const dbg_line = std.fmt.bufPrint(&dbg_buf, "SKIP_EARLY panel={d} tick={d}\n", .{ panel.id, panel.ticks_since_connect }) catch "";
                                _ = f.write(dbg_line) catch {};
                            }
                            continue;
                        }

                        was_keyframe = panel.force_keyframe;

                        // Read pixels from OpenGL framebuffer
                        crash_phase.store(6, .monotonic); // ghostty_surface_read_pixels
                        const t_read = std.time.nanoTimestamp();
                        const read_ok = c.ghostty_surface_read_pixels(panel.surface, panel.bgra_buffer.?.ptr, panel.bgra_buffer.?.len);
                        read_elapsed = @intCast(std.time.nanoTimestamp() - t_read);
                        perf_read_ns += read_elapsed;

                        if (read_ok) {
                            // Frame skip: hash the pixel buffer and skip encoding if unchanged
                            const frame_hash = std.hash.XxHash64.hash(0, panel.bgra_buffer.?);

                            // Debug: log frames after input to diagnose stale pixels
                            if (panel.dbg_input_countdown > 0) {
                                panel.dbg_input_countdown -= 1;
                                if (dbg_log) |f| {
                                    // Get cursor info to correlate with pixel content
                                    var cur_col: u16 = 0;
                                    var cur_row: u16 = 0;
                                    var cur_style: u8 = 0;
                                    var cur_visible: u8 = 0;
                                    c.ghostty_surface_cursor_info(panel.surface, &cur_col, &cur_row, &cur_style, &cur_visible);

                                    // Sample a few pixels to see if content changes
                                    // Check pixel at row 0, col 5 (likely near prompt text)
                                    const row_bytes = pixel_width * 4;
                                    const sample_row: usize = @min(@as(usize, cur_row) * @as(usize, @intCast(c.ghostty_surface_size(panel.surface).cell_height_px)), pixel_height - 1);
                                    const sample_offset = sample_row * row_bytes + @min(@as(usize, cur_col) * @as(usize, @intCast(c.ghostty_surface_size(panel.surface).cell_width_px)) * 4, row_bytes - 4);
                                    const px_b = panel.bgra_buffer.?[sample_offset];
                                    const px_g = panel.bgra_buffer.?[sample_offset + 1];
                                    const px_r = panel.bgra_buffer.?[sample_offset + 2];
                                    const px_a = panel.bgra_buffer.?[sample_offset + 3];

                                    // Also check first non-black pixel in row 0
                                    var first_nonblack: usize = 0;
                                    for (0..@min(pixel_width, 200)) |x| {
                                        const off = x * 4;
                                        if (panel.bgra_buffer.?[off] != 0 or panel.bgra_buffer.?[off + 1] != 0 or panel.bgra_buffer.?[off + 2] != 0) {
                                            first_nonblack = x;
                                            break;
                                        }
                                    }

                                    var dbg_buf2: [512]u8 = undefined;
                                    const dbg_line2 = std.fmt.bufPrint(&dbg_buf2, "INPUT_FRAME panel={d} cd={d} hash={x} prev={x} match={} cursor=({d},{d}) px@cursor=({d},{d},{d},{d}) first_nonblack_x={d}\n", .{
                                        panel.id, panel.dbg_input_countdown, frame_hash, panel.last_frame_hash, @intFromBool(frame_hash == panel.last_frame_hash),
                                        cur_col, cur_row, px_r, px_g, px_b, px_a, first_nonblack,
                                    }) catch "";
                                    _ = f.write(dbg_line2) catch {};
                                }
                            }

                            if (frame_hash == panel.last_frame_hash and !panel.force_keyframe) {
                                panel.consecutive_unchanged += 1;
                                if (panel.ticks_since_connect < 10) {
                                    if (dbg_log) |f| {
                                        var dbg_buf: [128]u8 = undefined;
                                        const dbg_line = std.fmt.bufPrint(&dbg_buf, "HASH_SKIP panel={d} tick={d} hash={x}\n", .{ panel.id, panel.ticks_since_connect, frame_hash }) catch "";
                                        _ = f.write(dbg_line) catch {};
                                    }
                                }
                                continue;
                            }
                            panel.consecutive_unchanged = 0;
                            panel.last_frame_hash = frame_hash;

                            // Pass explicit dimensions to ensure encoder matches frame size
                            crash_phase.store(7, .monotonic); // video encoder
                            const t_enc = std.time.nanoTimestamp();
                            if (panel.video_encoder.?.encodeWithDimensions(panel.bgra_buffer.?, panel.force_keyframe, pixel_width, pixel_height) catch null) |result| {
                                frame_data = result.data;
                                panel.force_keyframe = false;
                                {
                                    if (dbg_log) |f| {
                                        var dbg_buf: [256]u8 = undefined;
                                        const dbg_line = std.fmt.bufPrint(&dbg_buf, "ENCODED panel={d} tick={d} kf={} size={d} fc={d}\n", .{ panel.id, panel.ticks_since_connect, was_keyframe, result.data.len, if (panel.video_encoder) |enc| enc.frame_count else -1 }) catch "";
                                        _ = f.write(dbg_line) catch {};
                                    }
                                }
                            } else {
                                if (panel.ticks_since_connect < 10) {
                                    if (dbg_log) |f| {
                                        var dbg_buf: [128]u8 = undefined;
                                        const dbg_line = std.fmt.bufPrint(&dbg_buf, "ENCODE_FAIL panel={d} tick={d}\n", .{ panel.id, panel.ticks_since_connect }) catch "";
                                        _ = f.write(dbg_line) catch {};
                                    }
                                }
                            }
                            enc_elapsed = @intCast(std.time.nanoTimestamp() - t_enc);
                            perf_encode_ns += enc_elapsed;
                        } else {
                            if (panel.ticks_since_connect < 10) {
                                if (dbg_log) |f| {
                                    var dbg_buf: [128]u8 = undefined;
                                    const dbg_line = std.fmt.bufPrint(&dbg_buf, "READ_FAIL panel={d} tick={d}\n", .{ panel.id, panel.ticks_since_connect }) catch "";
                                    _ = f.write(dbg_line) catch {};
                                }
                            }
                        }
                    }

                    // Send frame to all H264 clients (multiplexed by panel_id)
                    if (frame_data) |data| {
                        if (self.sendH264Frame(panel.id, data)) {
                            frames_sent += 1;
                            panel.last_frame_time = t_frame_start; // For per-panel adaptive FPS
                            if (panel.ticks_since_connect < 10) {
                                if (dbg_log) |f| {
                                    var dbg_buf: [128]u8 = undefined;
                                    const dbg_line = std.fmt.bufPrint(&dbg_buf, "SENT panel={d} tick={d} size={d}\n", .{ panel.id, panel.ticks_since_connect, data.len }) catch "";
                                    _ = f.write(dbg_line) catch {};
                                }
                            }
                        } else {
                            // All sends failed — force keyframe for recovery
                            panel.force_keyframe = true;
                            frames_dropped += 1;
                            send_failed = true;
                        }

                        // Track input-to-frame-send latency
                        const input_ts = panel.last_input_time.swap(0, .acq_rel);
                        if (input_ts > 0) {
                            const now_trunc: i64 = @truncate(std.time.nanoTimestamp());
                            const latency = now_trunc - input_ts;
                            if (latency > 0) perf_input_latency_us = @intCast(@divFloor(latency, std.time.ns_per_us));
                        }
                    }

                    // Query cursor state and broadcast if changed (for frontend CSS blink)
                    {
                        var cur_col: u16 = 0;
                        var cur_row: u16 = 0;
                        var cur_style: u8 = 0;
                        var cur_visible: u8 = 0;
                        c.ghostty_surface_cursor_info(panel.surface, &cur_col, &cur_row, &cur_style, &cur_visible);

                        const size = c.ghostty_surface_size(panel.surface);
                        const surf_total_w: u16 = @intCast(size.width_px);
                        const surf_total_h: u16 = @intCast(size.height_px);

                        // Broadcast surface dims only when they change (resize)
                        const surface_changed = surf_total_w != panel.last_surf_w or surf_total_h != panel.last_surf_h;
                        if (surface_changed) {
                            panel.last_surf_w = surf_total_w;
                            panel.last_surf_h = surf_total_h;
                            const dims_buf = buildSurfaceDimsBuf(panel.id, surf_total_w, surf_total_h);
                            var ctrl_buf2: [max_broadcast_conns]*ws.Connection = undefined;
                            const ctrl_conns2 = self.snapshotControlConns(&ctrl_buf2);
                            for (ctrl_conns2) |ctrl_conn| {
                                ctrl_conn.sendBinary(&dims_buf) catch {};
                            }
                        }

                        // Re-send cursor when surface dims change: padding and pixel
                        // coordinates are recalculated against the new surface layout,
                        // even if the cursor's grid col/row haven't moved.
                        if (surface_changed or
                            cur_col != panel.last_cursor_col or
                            cur_row != panel.last_cursor_row or
                            cur_style != panel.last_cursor_style or
                            cur_visible != panel.last_cursor_visible)
                        {
                            panel.last_cursor_col = cur_col;
                            panel.last_cursor_row = cur_row;
                            panel.last_cursor_style = cur_style;
                            panel.last_cursor_visible = cur_visible;

                            // Compute cursor in surface-space pixel coordinates.
                            // Always send cell-sized rectangle; CSS handles bar/underline visuals.
                            // Y offset +2 accounts for visual baseline alignment with text.
                            const cell_w: u16 = @intCast(size.cell_width_px);
                            const cell_h: u16 = @intCast(size.cell_height_px);
                            const padding_x: u16 = @intCast(size.padding_left_px);
                            const padding_y: u16 = @intCast(size.padding_top_px);
                            const surf_x = padding_x + cur_col * cell_w;
                            const surf_y = padding_y + cur_row * cell_h + 2;
                            const surf_w: u16 = cell_w -| 1;
                            const surf_h: u16 = cell_h -| 2;

                            const cursor_buf = buildCursorBuf(panel.id, surf_x, surf_y, surf_w, surf_h, cur_style, cur_visible);

                            // Broadcast to control WS connections
                            var ctrl_buf: [max_broadcast_conns]*ws.Connection = undefined;
                            const ctrl_conns = self.snapshotControlConns(&ctrl_buf);
                            for (ctrl_conns) |ctrl_conn| {
                                ctrl_conn.sendBinary(&cursor_buf) catch {};
                            }
                        }
                    }

                    // Spike detection: log immediately if any single frame exceeds 50ms
                    const frame_total_ns: u64 = @intCast(std.time.nanoTimestamp() - t_frame_start);
                    const spike_threshold_ns: u64 = 50 * std.time.ns_per_ms;
                    if (frame_total_ns > spike_threshold_ns) {
                        if (perf_log) |f| {
                            var spike_buf: [256]u8 = undefined;
                            const spike_line = std.fmt.bufPrint(&spike_buf, "SPIKE panel={d} total={d}ms tick={d}ms read={d}ms enc={d}ms keyframe={} send_fail={}\n", .{
                                panel.id,
                                frame_total_ns / std.time.ns_per_ms,
                                tick_elapsed / std.time.ns_per_ms,
                                read_elapsed / std.time.ns_per_ms,
                                enc_elapsed / std.time.ns_per_ms,
                                was_keyframe,
                                send_failed,
                            }) catch "";
                            _ = f.write(spike_line) catch {};
                        }
                    }

                }

                fps_counter += frames_sent;
                fps_attempts += frames_attempted;
                fps_dropped += frames_dropped;

                // Reset FPS counters every second and log performance
                const fps_elapsed = std.time.nanoTimestamp() - fps_timer;
                if (fps_elapsed >= std.time.ns_per_s) {
                    if (fps_attempts > 0) {
                        if (perf_log) |f| {
                            var buf: [512]u8 = undefined;
                            const latency_str = if (perf_input_latency_us > 0)
                                std.fmt.bufPrint(buf[256..], " input_latency={d}us", .{perf_input_latency_us}) catch ""
                            else
                                "";
                            const dropped_str = if (fps_dropped > 0)
                                std.fmt.bufPrint(buf[384..], " dropped={d}", .{fps_dropped}) catch ""
                            else
                                "";
                            const line = std.fmt.bufPrint(buf[0..256], "{d}fps sent/{d} attempted | app_tick={d}ms tick={d}ms read={d}ms enc={d}ms | panels={d}{s}{s}\n", .{
                                fps_counter,
                                fps_attempts,
                                app_tick_ns / std.time.ns_per_ms,
                                perf_tick_ns / std.time.ns_per_ms,
                                perf_read_ns / std.time.ns_per_ms,
                                perf_encode_ns / std.time.ns_per_ms,
                                frame_panels_count,
                                latency_str,
                                dropped_str,
                            }) catch "";
                            _ = f.write(line) catch {};
                        }
                    }
                    fps_counter = 0;
                    fps_attempts = 0;
                    fps_dropped = 0;
                    frame_blocks = 0;
                    fps_timer = std.time.nanoTimestamp();
                }
            }


            // Process input again after frame work — input that arrived during
            // encoding gets dispatched to ghostty immediately instead of waiting
            // for the next loop iteration (~33ms worst case → ~0ms).
            for (panels_buf[0..panels_count]) |panel| {
                if (panel.hasQueuedInput()) panel.processInputQueue();
            }

            // Wait until next frame is due or input arrives (whichever comes first)
            // Use last_frame as anchor so we wake at the correct time regardless
            // of when we entered this iteration (e.g. woken early by input signal)
            crash_phase.store(0, .monotonic); // idle/sleeping
            const since_last: u64 = @intCast(std.time.nanoTimestamp() - last_frame);
            const remaining = if (since_last < frame_time_ns) frame_time_ns - since_last else 0;
            if (remaining > 0) {
                _ = self.wake_signal.waitTimeout(remaining);
                // Process input immediately after waking from sleep — don't wait
                // for the next full loop iteration to handle the keystroke.
                for (panels_buf[0..panels_count]) |panel| {
                    if (panel.hasQueuedInput()) panel.processInputQueue();
                }
            }
        }
    }

    fn run(self: *Server) !void {
        self.running.store(true, .release);

        // Set running flag for WebSocket servers (they don't call run() but need this for handleConnection)
        self.h264_ws_server.running.store(true, .release);
        self.control_ws_server.running.store(true, .release);
        self.file_ws_server.running.store(true, .release);

        // Start HTTP server in background (handles all WebSocket via path-based routing)
        const http_thread = try std.Thread.spawn(.{}, runHttpServer, .{self});

        // Note: WebSocket servers are NOT started with run() - they only handle
        // upgrades from HTTP server via handleUpgrade(). No separate ports needed.

        // Run render loop in main thread
        self.runRenderLoop();

        // Render loop exited (Ctrl+C or error) — stop all servers to unblock
        // their threads. This is done here instead of the signal handler because
        // .stop() calls allocator/deinit operations that are not signal-safe.
        self.http_server.stop();
        self.h264_ws_server.stop();
        self.control_ws_server.stop();
        self.file_ws_server.stop();

        // Wait for HTTP thread to finish
        http_thread.join();
    }
};


// Objective-C helpers


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
const MsgSendCGFloatFn = *const fn (objc.id, objc.SEL, f64) callconv(.c) void;

fn msgSendBool() MsgSendBoolFn {
    return @ptrCast(&objc.objc_msgSend);
}

fn msgSendCGFloat() MsgSendCGFloatFn {
    return @ptrCast(&objc.objc_msgSend);
}

fn makeViewLayerBacked(view: objc.id, scale: f64) void {
    // [view setWantsLayer:YES]
    msgSendBool()(view, sel("setWantsLayer:"), true);

    // Get the layer and set its contentsScale for retina rendering
    const layer = msgSendId()(view, sel("layer"));
    if (layer != null) {
        // [layer setContentsScale:scale]
        msgSendCGFloat()(layer, sel("setContentsScale:"), scale);
    }
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

fn beginCATransaction() void {
    const CATransaction = getClass("CATransaction");
    if (CATransaction != null) {
        const cls_as_id: objc.id = @ptrCast(@alignCast(CATransaction));
        const MsgSend = *const fn (objc.id, objc.SEL) callconv(.c) void;
        const begin: MsgSend = @ptrCast(&objc.objc_msgSend);
        begin(cls_as_id, sel("begin"));
        // Disable animations for immediate updates
        const MsgSendBool = *const fn (objc.id, objc.SEL, bool) callconv(.c) void;
        const setDisable: MsgSendBool = @ptrCast(&objc.objc_msgSend);
        setDisable(cls_as_id, sel("setDisableActions:"), true);
    }
}

fn commitCATransaction() void {
    const CATransaction = getClass("CATransaction");
    if (CATransaction != null) {
        const cls_as_id: objc.id = @ptrCast(@alignCast(CATransaction));
        const MsgSend = *const fn (objc.id, objc.SEL) callconv(.c) void;
        const commit: MsgSend = @ptrCast(&objc.objc_msgSend);
        commit(cls_as_id, sel("commit"));
    }
}

fn flushCATransaction() void {
    const CATransaction = getClass("CATransaction");
    if (CATransaction != null) {
        const cls_as_id: objc.id = @ptrCast(@alignCast(CATransaction));
        const MsgSendFlush = *const fn (objc.id, objc.SEL) callconv(.c) void;
        const flush: MsgSendFlush = @ptrCast(&objc.objc_msgSend);
        flush(cls_as_id, sel("flush"));
    }
}

// Import CoreFoundation for CFRunLoop
const cf = @cImport({
    @cInclude("CoreFoundation/CoreFoundation.h");
});

fn runLoopRunOnce() void {
    // Run one iteration of the run loop to process pending events
    _ = cf.CFRunLoopRunInMode(cf.kCFRunLoopDefaultMode, 0.0, 1); // 1 = true for Boolean
}

// Use low-level runtime functions for autorelease pool
extern fn objc_autoreleasePoolPush() ?*anyopaque;
extern fn objc_autoreleasePoolPop(?*anyopaque) void;

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

fn getIOSurfaceFromView(nsview: objc.id) ?IOSurfacePtr {
    if (nsview == null) return null;

    const layer = msgSendId()(nsview, sel("layer"));
    if (layer == null) return null;

    // Try to get contents directly from the layer first
    const contents = msgSendId()(layer, sel("contents"));
    if (contents != null) return @ptrCast(contents);

    // Check sublayers
    const sublayers = msgSendId()(layer, sel("sublayers"));
    if (sublayers == null) return null;

    const count_fn: *const fn (objc.id, objc.SEL) callconv(.c) u64 = @ptrCast(&objc.objc_msgSend);
    const count = count_fn(sublayers, sel("count"));
    if (count == 0) return null;

    // Check each sublayer for contents
    var i: u64 = 0;
    while (i < count) : (i += 1) {
        const sublayer = msgSendIndex()(sublayers, sel("objectAtIndex:"), i);
        if (sublayer == null) continue;

        const sublayer_contents = msgSendId()(sublayer, sel("contents"));
        if (sublayer_contents != null) return @ptrCast(sublayer_contents);
    }

    return null;
}


// Ghostty callbacks


fn wakeupCallback(userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;
}

fn actionCallback(app: c.ghostty_app_t, target: c.ghostty_target_s, action: c.ghostty_action_s) callconv(.c) bool {
    _ = app;
    const self = Server.global_server.load(.acquire) orelse return false;

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
        c.GHOSTTY_ACTION_PWD => {
            // Get pwd from action
            const pwd_ptr = action.action.pwd.pwd;
            if (pwd_ptr == null) return false;

            const pwd = std.mem.span(pwd_ptr);

            // Find which panel this surface belongs to
            if (target.tag == c.GHOSTTY_TARGET_SURFACE) {
                const surface = target.target.surface;
                self.mutex.lock();
                var panel_it = self.panels.valueIterator();
                while (panel_it.next()) |panel_ptr| {
                    const panel = panel_ptr.*;
                    if (panel.surface == surface) {
                        self.mutex.unlock();
                        self.broadcastPanelPwd(panel.id, pwd);
                        return true;
                    }
                }
                self.mutex.unlock();
            }
        },
        c.GHOSTTY_ACTION_DESKTOP_NOTIFICATION => {
            // Get notification title and body from action
            const title_ptr = action.action.desktop_notification.title;
            const body_ptr = action.action.desktop_notification.body;

            const title = if (title_ptr != null) std.mem.span(title_ptr) else "";
            const body = if (body_ptr != null) std.mem.span(body_ptr) else "";

            // Find which panel this surface belongs to
            if (target.tag == c.GHOSTTY_TARGET_SURFACE) {
                const surface = target.target.surface;
                self.mutex.lock();
                var panel_it = self.panels.valueIterator();
                while (panel_it.next()) |panel_ptr| {
                    const panel = panel_ptr.*;
                    if (panel.surface == surface) {
                        self.mutex.unlock();
                        self.broadcastPanelNotification(panel.id, title, body);
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
    // userdata is the Panel pointer (set via surface_config.userdata)
    const panel: *Panel = @ptrCast(@alignCast(userdata orelse return));

    const self = Server.global_server.load(.acquire) orelse return;

    if (clipboard == c.GHOSTTY_CLIPBOARD_SELECTION) {
        self.mutex.lock();
        const selection = self.selection_clipboard;
        self.mutex.unlock();

        if (selection) |sel_text| {
            c.ghostty_surface_complete_clipboard_request(panel.surface, sel_text.ptr, context, true);
            return;
        }
    } else if (clipboard == c.GHOSTTY_CLIPBOARD_STANDARD) {
        self.mutex.lock();
        const standard = self.standard_clipboard;
        self.mutex.unlock();

        if (standard) |std_text| {
            c.ghostty_surface_complete_clipboard_request(panel.surface, std_text.ptr, context, true);
            return;
        }
    }

    // Complete with empty string if no clipboard data
    c.ghostty_surface_complete_clipboard_request(panel.surface, "", context, true);
}

fn confirmReadClipboardCallback(userdata: ?*anyopaque, data: [*c]const u8, context: ?*anyopaque, request: c.ghostty_clipboard_request_e) callconv(.c) void {
    _ = request;
    // Complete the clipboard request to prevent ghostty internal state leak.
    const panel: *Panel = @ptrCast(@alignCast(userdata orelse return));
    c.ghostty_surface_complete_clipboard_request(panel.surface, data orelse "", context, true);
}

fn writeClipboardCallback(userdata: ?*anyopaque, clipboard: c.ghostty_clipboard_e, content: [*c]const c.ghostty_clipboard_content_s, count: usize, protected: bool) callconv(.c) void {
    _ = userdata;
    _ = protected;

    const self = Server.global_server.load(.acquire) orelse return;
    if (count == 0 or content == null) return;

    // Get the text/plain content
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const item = content[i];
        if (item.mime != null and item.data != null) {
            const mime = std.mem.span(item.mime);
            if (std.mem.eql(u8, mime, "text/plain")) {
                const data = std.mem.span(item.data);

                if (clipboard == c.GHOSTTY_CLIPBOARD_SELECTION) {
                    // Store selection clipboard locally
                    self.mutex.lock();
                    defer self.mutex.unlock();

                    if (self.selection_clipboard) |old| {
                        self.allocator.free(old);
                    }
                    self.selection_clipboard = self.allocator.dupe(u8, data) catch null;
                } else if (clipboard == c.GHOSTTY_CLIPBOARD_STANDARD) {
                    // Send standard clipboard to all connected clients
                    self.broadcastClipboard(data);
                }
                return;
            }
        }
    }
}

fn closeSurfaceCallback(userdata: ?*anyopaque, needs_confirm: bool) callconv(.c) void {
    _ = needs_confirm;
    // userdata is the Panel pointer (set via surface_config.userdata)
    const panel: *Panel = @ptrCast(@alignCast(userdata orelse return));
    const self = Server.global_server.load(.acquire) orelse return;

    // Queue the panel for destruction on main thread
    _ = self.pending_destroys_ch.send(.{ .id = panel.id });
    self.wake_signal.notify();
}


// Main


const Args = struct {
    http_port: u16 = 8080,
    mode: tunnel_mod.Mode = .interactive,
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
        } else if (std.mem.eql(u8, arg, "--local")) {
            args.mode = .local;
        } else if (std.mem.eql(u8, arg, "--cloudflare")) {
            args.mode = .{ .tunnel = .cloudflare };
        } else if (std.mem.eql(u8, arg, "--ngrok")) {
            args.mode = .{ .tunnel = .ngrok };
        } else if (std.mem.eql(u8, arg, "--tailscale")) {
            args.mode = .{ .tunnel = .tailscale };
        }
    }

    return args;
}


// Crash diagnostics: atomic phase tracker (zero-overhead, read by signal handler)
var crash_phase = std.atomic.Value(u32).init(0);
// Phase values:
// 0 = idle/sleeping
// 1 = processPendingPanels
// 2 = processPendingDestroys
// 3 = processInputQueue
// 4 = ghostty_app_tick
// 5 = ghostty_surface_draw
// 6 = ghostty_surface_read_pixels
// 7 = video encoder
// 8 = sendH264Frame

const phase_names = [_][]const u8{
    "idle/sleeping",
    "processPendingPanels",
    "processPendingDestroys",
    "processInputQueue",
    "ghostty_app_tick",
    "ghostty_surface_draw",
    "ghostty_surface_read_pixels",
    "video encoder",
    "sendH264Frame",
};

fn handleSigabrt(_: c_int) callconv(.c) void {
    // Report which phase was active
    const phase = crash_phase.load(.monotonic);
    _ = std.posix.write(2, "\n=== CRASH: double free or corruption ===\n") catch {};
    _ = std.posix.write(2, "Phase: ") catch {};
    if (phase < phase_names.len) {
        _ = std.posix.write(2, phase_names[phase]) catch {};
    } else {
        _ = std.posix.write(2, "unknown") catch {};
    }
    _ = std.posix.write(2, "\n") catch {};

    // Signal-safe backtrace dump to stderr (fd 2)
    var addrs: [64]?*anyopaque = undefined;
    const n = c.backtrace(&addrs, 64);
    _ = std.posix.write(2, "=== backtrace ===\n") catch {};
    c.backtrace_symbols_fd(&addrs, n, 2);
    _ = std.posix.write(2, "=== end backtrace ===\n") catch {};
    std.posix.exit(134);
}

var sigint_received = std.atomic.Value(bool).init(false);
var tunnel_child_pid = std.atomic.Value(i32).init(0);

fn handleSigint(_: c_int) callconv(.c) void {
    if (sigint_received.swap(true, .acq_rel)) {
        // Second Ctrl+C - force exit immediately
        std.posix.exit(1);
    }
    // First Ctrl+C - graceful shutdown (signal-safe: only atomics + write + syscalls)
    if (Server.global_server.load(.acquire)) |server| {
        server.running.store(false, .release);
        server.wake_signal.notify();
    }
    // Kill tunnel subprocess immediately (signal-safe: kill is a syscall)
    const pid = tunnel_child_pid.load(.acquire);
    if (pid > 0) {
        std.posix.kill(pid, 9) catch {}; // SIGKILL = 9
    }
    // std.debug.print is NOT signal-safe, use raw write instead
    _ = std.posix.write(2, "\nShutting down...\n") catch {};
}

// WebSocket upgrade callbacks for HTTP server
fn onH264WsUpgrade(stream: std.net.Stream, request: []const u8, user_data: ?*anyopaque) void {
    const server: *Server = @ptrCast(@alignCast(user_data orelse return));
    server.h264_ws_server.handleUpgrade(stream, request);
}

fn onControlWsUpgrade(stream: std.net.Stream, request: []const u8, user_data: ?*anyopaque) void {
    const server: *Server = @ptrCast(@alignCast(user_data orelse return));
    server.control_ws_server.handleUpgrade(stream, request);
}

fn onFileWsUpgrade(stream: std.net.Stream, request: []const u8, user_data: ?*anyopaque) void {
    const server: *Server = @ptrCast(@alignCast(user_data orelse return));
    server.file_ws_server.handleUpgrade(stream, request);
}

/// Run mux server - can be called from CLI or standalone
pub fn run(allocator: std.mem.Allocator, http_port: u16, mode: tunnel_mod.Mode) !void {
    // Setup SIGINT handler for graceful shutdown
    const act = std.posix.Sigaction{
        .handler = .{ .handler = handleSigint },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);

    // Setup SIGABRT handler to capture crash backtraces
    const abrt_act = std.posix.Sigaction{
        .handler = .{ .handler = handleSigabrt },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.ABRT, &abrt_act, null);

    std.debug.print("termweb mux server starting...\n", .{});

    // WS ports use 0 to let OS assign random available ports
    const server = try Server.init(allocator, http_port, 0, 0);
    defer server.deinit();

    // Set up WebSocket upgrade callbacks on HTTP server
    // 3 channels: /ws/h264 (video) + /ws/control (zstd) + /ws/file (transfers)
    server.http_server.setWsCallbacks(
        onH264WsUpgrade,
        onControlWsUpgrade,
        onFileWsUpgrade,
        null,
        server,
    );

    // Resolve connection mode: interactive shows a picker, others are direct
    const chosen_provider: ?tunnel_mod.Provider = switch (mode) {
        .interactive => tunnel_mod.promptConnectionMode(),
        .local => null,
        .tunnel => |p| p,
    };

    // Start tunnel if a provider was selected
    var tunnel: ?*tunnel_mod.Tunnel = null;
    if (chosen_provider) |provider| {
        if (!tunnel_mod.binaryExists(provider.binary())) {
            std.debug.print("'{s}' is not installed.\n", .{provider.binary()});
            std.debug.print("Continuing with local-only access.\n", .{});
        } else {
            std.debug.print("Starting {s}...\n", .{provider.label()});
            tunnel = tunnel_mod.Tunnel.start(allocator, provider, http_port) catch |err| blk: {
                std.debug.print("Tunnel failed to start: {}\n", .{err});
                std.debug.print("Continuing with local-only access.\n", .{});
                break :blk null;
            };
            if (tunnel) |t| {
                // Store PID so SIGINT handler can kill it immediately
                tunnel_child_pid.store(t.process.id, .release);
                if (t.waitForUrl(15 * std.time.ns_per_s)) {
                    if (t.getUrl()) |url| {
                        std.debug.print("  Tunnel:  {s}\n", .{url});
                        tunnel_mod.printQrCode(allocator, url);
                    }
                } else {
                    std.debug.print("  Tunnel:  failed (see errors above)\n", .{});
                }
            }
        }
    }

    // Show LAN URL (useful for same-network access)
    const lan_url = tunnel_mod.getLanUrl(allocator, http_port);
    defer if (lan_url) |u| allocator.free(u);
    if (lan_url) |url| {
        std.debug.print("  LAN:     {s}\n", .{url});
        // Show QR for LAN URL if no tunnel QR was shown
        if (tunnel == null) {
            tunnel_mod.printQrCode(allocator, url);
        }
    }

    std.debug.print("  Local:   http://localhost:{}\n", .{http_port});
    std.debug.print("\nServer initialized, waiting for connections...\n", .{});

    try server.run();

    if (tunnel) |t| {
        t.stop();
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) {
            std.debug.print("\n=== GPA LEAK DETECTED ===\n", .{});
        }
    }
    const allocator = gpa.allocator();

    const args = try parseArgs(allocator);
    try run(allocator, args.http_port, args.mode);
}
