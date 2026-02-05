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


// Debug logging to stderr
fn debugLog(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

// Platform detection
const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;

// Cross-platform video encoder (uses comptime to select implementation)
const video = @import("video.zig");

// Ghostty stub for Linux (comptime selected)
const ghostty_stub = @import("ghostty_stub.zig");

// Platform-specific C imports + ghostty
const c = if (is_macos) @cImport({
    @cInclude("ghostty.h");
    @cInclude("IOSurface/IOSurfaceRef.h");
}) else @cImport({
    @cInclude("ghostty.h");
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
    inspector_state_open = 0x1E,  // Inspector open/closed state (0x09 is already inspector_state)

    // Auth/Session Server → Client (0x0A-0x0F)
    auth_state = 0x0A,      // Current auth state (role, sessions, tokens)
    session_list = 0x0B,    // List of sessions
    share_links = 0x0C,     // List of active share links

    // Client → Server (0x80-0x8F)
    close_panel = 0x81,
    resize_panel = 0x82,
    focus_panel = 0x83,
    view_action = 0x88,
    set_overview = 0x89,  // Set overview open/closed state
    set_quick_terminal = 0x8A,  // Set quick terminal open/closed state
    set_inspector = 0x8B,  // Set inspector open/closed state

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
    connection: ?*ws.Connection,
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    input_queue: std.ArrayList(InputEvent),
    has_pending_input: std.atomic.Value(bool),
    title: []const u8,  // Last known title
    pwd: []const u8,    // Last known working directory
    inspector_subscribed: bool,
    inspector_tab: [16]u8,
    inspector_tab_len: u8,
    last_iosurface_seed: u32, // For detecting IOSurface/SharedMemory changes
    last_frame_time: i64, // For FPS control
    last_tick_time: i128, // For rate limiting panel.tick()
    ticks_since_connect: u32, // Track frames since connection (for initial render delay)

    const TARGET_FPS: i64 = 30; // 30 FPS for video
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

        // Focus the surface so it accepts input
        c.ghostty_surface_set_focus(surface, true);
        // Tell ghostty the surface is visible (not occluded) so it renders properly
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
            .streaming = std.atomic.Value(bool).init(false),
            .force_keyframe = true,
            .connection = null,
            .allocator = allocator,
            .mutex = .{},
            .input_queue = .{},
            .has_pending_input = std.atomic.Value(bool).init(false),
            .title = &.{},
            .pwd = &.{},
            .inspector_subscribed = false,
            .inspector_tab = undefined,
            .inspector_tab_len = 0,
            .last_iosurface_seed = 0,
            .last_frame_time = 0,
            .last_tick_time = 0,
            .ticks_since_connect = 0,
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

    fn setConnection(self: *Panel, conn: ?*ws.Connection) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.connection = conn;
        if (conn != null) {
            self.streaming.store(true, .release);
            self.force_keyframe = true;
            self.ticks_since_connect = 0; // Reset so ghostty can render before we read pixels
        } else {
            self.streaming.store(false, .release);
        }
    }

    // Internal resize - called from main thread only (via processInputQueue)
    // width/height are in CSS pixels (points)
    fn resizeInternal(self: *Panel, width: u32, height: u32) !void {
        // Skip resize if size hasn't changed to avoid unnecessary terminal reflow
        if (self.width == width and self.height == height) return;

        self.width = width;
        self.height = height;

        // Resize the NSWindow and NSView at point dimensions (macOS only)
        if (comptime is_macos) {
            resizeWindow(self.window, width, height);
        }

        // Set ghostty size in pixels
        const pixel_width: u32 = @intFromFloat(@as(f64, @floatFromInt(width)) * self.scale);
        const pixel_height: u32 = @intFromFloat(@as(f64, @floatFromInt(height)) * self.scale);
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
            std.debug.print("ENCODER: Creating encoder for {}x{} ({} MB)\n", .{ surf_width, surf_height, new_size / 1024 / 1024 });
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
                std.debug.print("ENCODER: {}x{} -> {}x{} (scaling, BGRA path)\n", .{
                    surf_width, surf_height, self.video_encoder.?.width, self.video_encoder.?.height,
                });
                self.bgra_buffer = try self.allocator.alloc(u8, new_size);
            } else {
                std.debug.print("ENCODER: {}x{} (zero-copy path)\n", .{ surf_width, surf_height });
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

    // Send frame over WebSocket if connected
    fn sendFrame(self: *Panel, data: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.connection) |conn| {
            if (conn.is_open) {
                try conn.sendBinary(data);
            } else {
            }
        } else {
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

    // Handle buffer stats from client for adaptive bitrate
    fn handleBufferStats(self: *Panel, payload: []const u8) void {
        if (payload.len < 4) return;

        const health = payload[0];  // 0-100: buffer health
        const fps = payload[1];     // Received FPS
        const buffer_ms = std.mem.readInt(u16, payload[2..4], .little);

        _ = fps;
        _ = buffer_ms;

        // Adjust quality based on buffer health
        // health < 30: buffer starving, reduce quality
        // health > 70: buffer growing, can increase quality
        if (self.video_encoder) |encoder| {
            encoder.adjustQuality(health);
        }
    }
};


// Server - manages multiple panels and WebSocket connections


// Panel creation request (to be processed on main thread)
const PanelRequest = struct {
    conn: *ws.Connection,
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
};

// Panel split request (to be processed on main thread)
const PanelSplitRequest = struct {
    conn: *ws.Connection,
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
    panel_connections: std.AutoHashMap(*ws.Connection, *Panel),
    control_connections: std.ArrayList(*ws.Connection),
    connection_roles: std.AutoHashMap(*ws.Connection, auth.Role),  // Track connection roles
    layout: Layout,
    pending_panels: std.ArrayList(PanelRequest),
    pending_destroys: std.ArrayList(PanelDestroyRequest),
    pending_resizes: std.ArrayList(PanelResizeRequest),
    pending_splits: std.ArrayList(PanelSplitRequest),
    next_panel_id: u32,
    panel_ws_server: *ws.Server,
    control_ws_server: *ws.Server,
    file_ws_server: *ws.Server,
    preview_ws_server: *ws.Server,
    preview_connections: std.ArrayList(*ws.Connection),
    preview_needs_immediate_frame: bool, // Send preview frames immediately after connect
    http_server: *http.HttpServer,
    auth_state: *auth.AuthState,  // Session and access control
    transfer_manager: transfer.TransferManager,
    file_connections: std.ArrayList(*ws.Connection),
    running: std.atomic.Value(bool),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    selection_clipboard: ?[]u8,  // Selection clipboard buffer
    initial_cwd: []const u8,  // CWD where termweb was started
    initial_cwd_allocated: bool,  // Whether initial_cwd was allocated (vs static "/")
    overview_open: bool,  // Whether tab overview is currently open
    quick_terminal_open: bool,  // Whether quick terminal is open
    inspector_open: bool,  // Whether inspector is open
    shared_va_ctx: if (is_linux) ?video.SharedVaContext else void,  // Shared VA-API context for fast encoder init
    wake_signal: WakeSignal,  // Event-driven wakeup for render loop (replaces sleep polling)

    var global_server: std.atomic.Value(?*Server) = std.atomic.Value(?*Server).init(null);

    fn init(allocator: std.mem.Allocator, http_port: u16, control_port: u16, panel_port: u16) !*Server {
        const server = try allocator.create(Server);
        errdefer allocator.destroy(server);

        // Ghostty is lazy-initialized on first panel creation (scale to zero)

        // Create HTTP server for static files (no ghostty config needed initially)
        const http_srv = try http.HttpServer.init(allocator, "0.0.0.0", http_port, null);

        // Create control WebSocket server (for tab list, layout, etc.)
        const control_ws = try ws.Server.init(allocator, "0.0.0.0", control_port);
        control_ws.setCallbacks(onControlConnect, onControlMessage, onControlDisconnect);

        // Create panel WebSocket server (for pixel streams - no deflate, video is pre-compressed)
        const panel_ws = try ws.Server.initNoDeflate(allocator, "0.0.0.0", panel_port);
        panel_ws.setCallbacks(onPanelConnect, onPanelMessage, onPanelDisconnect);

        // Create file WebSocket server (for file transfers - uses zstd compression)
        const file_ws = try ws.Server.init(allocator, "0.0.0.0", 0);
        file_ws.setCallbacks(onFileConnect, onFileMessage, onFileDisconnect);

        // Create preview WebSocket server (for tab overview thumbnails - no deflate, video is pre-compressed)
        const preview_ws = try ws.Server.initNoDeflate(allocator, "0.0.0.0", 0);
        preview_ws.setCallbacks(onPreviewConnect, onPreviewMessage, onPreviewDisconnect);

        // Initialize auth state
        const auth_state = try auth.AuthState.init(allocator);

        server.* = .{
            .app = null, // Lazy init on first panel
            .config = null,
            .panels = std.AutoHashMap(u32, *Panel).init(allocator),
            .panel_connections = std.AutoHashMap(*ws.Connection, *Panel).init(allocator),
            .control_connections = .{},
            .connection_roles = std.AutoHashMap(*ws.Connection, auth.Role).init(allocator),
            .layout = Layout.init(allocator),
            .pending_panels = .{},
            .pending_destroys = .{},
            .pending_resizes = .{},
            .pending_splits = .{},
            .next_panel_id = 1,
            .http_server = http_srv,
            .panel_ws_server = panel_ws,
            .control_ws_server = control_ws,
            .file_ws_server = file_ws,
            .preview_ws_server = preview_ws,
            .preview_connections = .{},
            .preview_needs_immediate_frame = false,
            .auth_state = auth_state,
            .transfer_manager = transfer.TransferManager.init(allocator),
            .file_connections = .{},
            .running = std.atomic.Value(bool).init(false),
            .allocator = allocator,
            .mutex = .{},
            .selection_clipboard = null,
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

        // Load user's ghostty config (~/.config/ghostty/config)
        const config = c.ghostty_config_new();
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
        std.debug.print("Ghostty initialized (first panel created)\n", .{});
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
        std.debug.print("Ghostty freed (all panels closed)\n", .{});
    }

    fn deinit(self: *Server) void {
        self.running.store(false, .release);

        // Clear global_server first to prevent callbacks from accessing it during shutdown
        global_server.store(null, .release);

        // Shut down WebSocket servers first and wait for all connection threads to finish
        // This must happen BEFORE destroying panels to avoid use-after-free
        self.http_server.deinit();
        self.panel_ws_server.deinit();
        self.control_ws_server.deinit();
        self.file_ws_server.deinit();
        self.preview_ws_server.deinit();

        // Now safe to destroy panels since all connection threads have finished
        var panel_it = self.panels.valueIterator();
        while (panel_it.next()) |panel| {
            panel.*.deinit();
        }
        self.panels.deinit();
        self.panel_connections.deinit();
        self.control_connections.deinit(self.allocator);
        self.layout.deinit();
        self.pending_panels.deinit(self.allocator);
        self.pending_destroys.deinit(self.allocator);
        self.pending_resizes.deinit(self.allocator);
        self.pending_splits.deinit(self.allocator);

        self.auth_state.deinit();
        self.transfer_manager.deinit();
        self.file_connections.deinit(self.allocator);
        self.preview_connections.deinit(self.allocator);
        self.connection_roles.deinit();
        if (self.selection_clipboard) |clip| self.allocator.free(clip);
        if (self.initial_cwd_allocated) self.allocator.free(@constCast(self.initial_cwd));
        // Free shared VA-API context (after all panels/encoders are destroyed)
        self.wake_signal.deinit();
        if (is_linux) {
            if (self.shared_va_ctx) |*ctx| ctx.deinit();
        }
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

        self.mutex.lock();
        self.control_connections.append(self.allocator, conn) catch {};
        self.mutex.unlock();

        // Send auth state first (so client knows its role)
        self.sendAuthState(conn);

        // Send current panel list
        self.sendPanelList(conn);

        // Send UI states (for persistence across page reloads and shared sessions)
        self.sendOverviewState(conn);
        self.sendQuickTerminalState(conn);
        self.sendInspectorOpenState(conn);
    }

    fn onControlMessage(conn: *ws.Connection, data: []u8, is_binary: bool) void {
        _ = is_binary;
        const self = global_server.load(.acquire) orelse return;
        if (data.len == 0) return;

        const msg_type = data[0];
        if (msg_type >= 0x80 and msg_type <= 0x8F) {
            self.handleBinaryControlMessageFromClient(conn, data);
        } else if (msg_type >= 0x90 and msg_type <= 0x9F) {
            self.handleAuthMessage(conn, data);
        } else {
            self.handleBinaryControlMessage(conn, data);
        }
    }

    fn onControlDisconnect(conn: *ws.Connection) void {
        const self = global_server.load(.acquire) orelse return;

        self.mutex.lock();
        for (self.control_connections.items, 0..) |ctrl_conn, i| {
            if (ctrl_conn == conn) {
                _ = self.control_connections.swapRemove(i);
                break;
            }
        }

        // Remove connection role
        _ = self.connection_roles.remove(conn);
        self.mutex.unlock();
    }

    // --- Panel WebSocket callbacks---

    fn onPanelConnect(conn: *ws.Connection) void {
        _ = conn;
    }

    fn onPanelMessage(conn: *ws.Connection, data: []u8, is_binary: bool) void {
        const self = global_server.load(.acquire) orelse return;
        _ = is_binary;

        if (conn.user_data) |ud| {
            const panel: *Panel = @ptrCast(@alignCast(ud));

            // Handle inspector messages (need server access for sendInspectorStateToPanel)
            if (data.len > 0) {
                const msg_type = data[0];
                if (msg_type == @intFromEnum(ClientMsg.inspector_subscribe)) {
                    panel.inspector_subscribed = true;
                    const payload = data[1..];
                    if (payload.len >= 1) {
                        const tab_len = payload[0];
                        if (payload.len >= 1 + tab_len) {
                            const tab = payload[1..][0..tab_len];
                            const len = @min(tab.len, panel.inspector_tab.len);
                            @memcpy(panel.inspector_tab[0..len], tab[0..len]);
                            panel.inspector_tab_len = @intCast(len);
                        }
                    } else {
                        const default_tab = "screen";
                        @memcpy(panel.inspector_tab[0..default_tab.len], default_tab);
                        panel.inspector_tab_len = default_tab.len;
                    }
                    self.mutex.lock();
                    self.sendInspectorStateToPanel(panel, conn);
                    self.mutex.unlock();
                    return;
                } else if (msg_type == @intFromEnum(ClientMsg.inspector_unsubscribe)) {
                    panel.inspector_subscribed = false;
                    return;
                } else if (msg_type == @intFromEnum(ClientMsg.inspector_tab)) {
                    const payload = data[1..];
                    if (payload.len >= 1) {
                        const tab_len = payload[0];
                        if (payload.len >= 1 + tab_len) {
                            const tab = payload[1..][0..tab_len];
                            const len = @min(tab.len, panel.inspector_tab.len);
                            @memcpy(panel.inspector_tab[0..len], tab[0..len]);
                            panel.inspector_tab_len = @intCast(len);
                            self.mutex.lock();
                            self.sendInspectorStateToPanel(panel, conn);
                            self.mutex.unlock();
                        }
                    }
                    return;
                }
            }

            panel.handleMessage(data);
            panel.has_pending_input.store(true, .release);
            self.wake_signal.notify();
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
                        }
                        self.mutex.unlock();
                    }
                },
                .create_panel => {
                    // Create new panel: [msg_type:u8][width:u16][height:u16][scale:f32][inherit_panel_id:u32][flags:u8]?
                    // flags: bit 0 = quick_terminal (don't add to layout)
                    var width: u32 = 800;
                    var height: u32 = 600;
                    var scale: f64 = 2.0;
                    var inherit_cwd_from: u32 = 0;
                    var kind: PanelKind = .regular;
                    if (data.len >= 5) {
                        width = std.mem.readInt(u16, data[1..3], .little);
                        height = std.mem.readInt(u16, data[3..5], .little);
                    }
                    if (data.len >= 9) {
                        const scale_f32: f32 = @bitCast(std.mem.readInt(u32, data[5..9], .little));
                        scale = @floatCast(scale_f32);
                    }
                    if (data.len >= 13) {
                        inherit_cwd_from = std.mem.readInt(u32, data[9..13], .little);
                    }
                    if (data.len >= 14) {
                        kind = if (data[13] & 1 != 0) .quick_terminal else .regular;
                    }
                    self.mutex.lock();
                    self.pending_panels.append(self.allocator, .{
                        .conn = conn,
                        .width = width,
                        .height = height,
                        .scale = scale,
                        .inherit_cwd_from = inherit_cwd_from,
                        .kind = kind,
                    }) catch {};
                    self.mutex.unlock();
                    self.wake_signal.notify();
                },
                .split_panel => {
                    // Split existing panel: [msg_type:u8][parent_id:u32][dir_byte:u8][width:u16][height:u16][scale_x100:u16]
                    if (data.len < 12) return;
                    const parent_id = std.mem.readInt(u32, data[1..5], .little);
                    const dir_byte = data[5];
                    const width = std.mem.readInt(u16, data[6..8], .little);
                    const height = std.mem.readInt(u16, data[8..10], .little);
                    const scale_x100 = std.mem.readInt(u16, data[10..12], .little);
                    const direction: SplitDirection = if (dir_byte == 1) .vertical else .horizontal;
                    const scale: f64 = @as(f64, @floatFromInt(scale_x100)) / 100.0;

                    self.mutex.lock();
                    self.pending_splits.append(self.allocator, .{
                        .conn = conn,
                        .parent_panel_id = parent_id,
                        .direction = direction,
                        .width = width,
                        .height = height,
                        .scale = scale,
                    }) catch {};
                    self.mutex.unlock();
                    self.wake_signal.notify();
                },
                else => {},
            }
        }
    }

    fn onPanelDisconnect(conn: *ws.Connection) void {
        const self = global_server.load(.acquire) orelse return;

        self.mutex.lock();
        if (self.panel_connections.fetchRemove(conn)) |entry| {
            const panel = entry.value;
            panel.setConnection(null);
        }
        self.mutex.unlock();
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

    // --- Control message handling---


    fn handleBinaryControlMessageFromClient(self: *Server, _: *ws.Connection, data: []const u8) void {
        if (data.len < 1) return;

        const msg_type = data[0];
        if (msg_type == 0x81) { // close_panel
            if (data.len < 5) return;
            const panel_id = std.mem.readInt(u32, data[1..5], .little);
            self.mutex.lock();
            self.pending_destroys.append(self.allocator, .{ .id = panel_id }) catch {};
            self.mutex.unlock();
            self.wake_signal.notify();
        } else if (msg_type == 0x82) { // resize_panel
            if (data.len < 9) return;
            const panel_id = std.mem.readInt(u32, data[1..5], .little);
            const width = std.mem.readInt(u16, data[5..7], .little);
            const height = std.mem.readInt(u16, data[7..9], .little);
            self.mutex.lock();
            self.pending_resizes.append(self.allocator, .{ .id = panel_id, .width = width, .height = height }) catch {};
            self.mutex.unlock();
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
            self.overview_open = data[1] != 0;
            self.mutex.unlock();
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
            0x81, 0x82, 0x83, 0x88, 0x89, 0x8A, 0x8B => {
                self.handleBinaryControlMessageFromClient(conn, data);
            },
            else => std.log.warn("Unknown binary control message type: 0x{x:0>2}", .{msg_type}),
        }
    }

    /// Max connections for stack-based snapshot (avoids heap allocation during broadcast).
    const max_broadcast_conns = 16;

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

        // Send to panel-based inspector subscriptions
        var it = self.panels.iterator();
        while (it.next()) |entry| {
            const panel = entry.value_ptr.*;
            if (panel.inspector_subscribed) {
                if (panel.connection) |conn| {
                    self.sendInspectorStateToPanel(panel, conn);
                }
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

        // Send title/pwd for each panel so client can update UI
        var it3 = self.panels.iterator();
        while (it3.next()) |entry| {
            const panel = entry.value_ptr.*;
            if (panel.title.len > 0) {
                // Binary: [type:u8][panel_id:u32][title_len:u8][title...]
                const title_len: u8 = @intCast(@min(panel.title.len, 255));
                var title_buf: [262]u8 = undefined;
                title_buf[0] = @intFromEnum(BinaryCtrlMsg.panel_title);
                std.mem.writeInt(u32, title_buf[1..5], panel.id, .little);
                title_buf[5] = title_len;
                @memcpy(title_buf[6..][0..title_len], panel.title[0..title_len]);
                conn.sendBinary(title_buf[0 .. 6 + title_len]) catch {};
            }
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
            conn.sendBinary(msg_buf) catch {};
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

    // Run file WebSocket server
    fn runFileWebSocket(self: *Server) void {
        self.file_ws_server.run() catch |err| {
            std.debug.print("File WebSocket server error: {}\n", .{err});
        };
    }

    // --- File WebSocket callbacks---

    fn onFileConnect(conn: *ws.Connection) void {
        const self = global_server.load(.acquire) orelse return;

        self.mutex.lock();
        self.file_connections.append(self.allocator, conn) catch {};
        self.mutex.unlock();

        std.debug.print("File transfer client connected\n", .{});
    }

    fn onFileMessage(conn: *ws.Connection, data: []u8, is_binary: bool) void {
        const self = global_server.load(.acquire) orelse return;
        if (!is_binary or data.len == 0) return;

        const msg_type = data[0];

        switch (msg_type) {
            @intFromEnum(transfer.ClientMsgType.transfer_init) => self.handleTransferInit(conn, data),
            @intFromEnum(transfer.ClientMsgType.file_list_request) => self.handleFileListRequest(conn, data),
            @intFromEnum(transfer.ClientMsgType.file_data) => self.handleFileData(conn, data),
            @intFromEnum(transfer.ClientMsgType.transfer_resume) => self.handleTransferResume(conn, data),
            @intFromEnum(transfer.ClientMsgType.transfer_cancel) => self.handleTransferCancel(conn, data),
            else => std.debug.print("Unknown file message type: 0x{x:0>2}\n", .{msg_type}),
        }
    }

    fn onFileDisconnect(conn: *ws.Connection) void {
        const self = global_server.load(.acquire) orelse return;

        self.mutex.lock();
        // Remove from file connections
        for (self.file_connections.items, 0..) |fc, i| {
            if (fc == conn) {
                _ = self.file_connections.orderedRemove(i);
                break;
            }
        }
        self.mutex.unlock();

        std.debug.print("File transfer client disconnected\n", .{});
    }

    // --- Preview WebSocket callbacks---

    fn onPreviewConnect(conn: *ws.Connection) void {
        const self = global_server.load(.acquire) orelse return;

        self.mutex.lock();
        defer self.mutex.unlock();

        self.preview_connections.append(self.allocator, conn) catch {};

        // Force keyframes for all panels for preview
        // Don't pause panels - let them continue streaming (render loop handles both)
        var panel_it = self.panels.valueIterator();
        while (panel_it.next()) |panel_ptr| {
            const panel = panel_ptr.*;
            panel.force_keyframe = true; // Ensure first preview frame has SPS/PPS
            // Skip the initial render delay for panels that have already been running
            panel.ticks_since_connect = 100;
        }

        // Request immediate preview frames
        self.preview_needs_immediate_frame = true;

        std.debug.print("Preview client connected\n", .{});
    }

    fn onPreviewMessage(_: *ws.Connection, _: []u8, _: bool) void {
        // Preview is one-way server->client, no messages expected
    }

    fn onPreviewDisconnect(conn: *ws.Connection) void {
        const self = global_server.load(.acquire) orelse return;

        self.mutex.lock();
        defer self.mutex.unlock();

        // Remove from preview connections
        for (self.preview_connections.items, 0..) |pc, i| {
            if (pc == conn) {
                _ = self.preview_connections.orderedRemove(i);
                break;
            }
        }

        std.debug.print("Preview client disconnected\n", .{});
    }

    // Send frame to all preview clients with panel_id prefix
    fn sendPreviewFrame(self: *Server, panel_id: u32, frame_data: []const u8) void {
        if (self.preview_connections.items.len == 0) return;

        // Send [panel_id:u32 LE][frame_data...] via writev (zero-alloc)
        var id_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &id_buf, panel_id, .little);

        for (self.preview_connections.items) |conn| {
            conn.writeFrameRawParts(.binary, &id_buf, frame_data) catch {};
        }
    }

    // Handle TRANSFER_INIT message
    fn handleTransferInit(self: *Server, conn: *ws.Connection, data: []u8) void {
        var init_data = transfer.parseTransferInit(self.allocator, data) catch |err| {
            std.debug.print("Failed to parse TRANSFER_INIT: {}\n", .{err});
            return;
        };
        defer init_data.deinit(self.allocator);

        // Expand ~ in path
        const expanded_path = self.expandPath(init_data.path) catch init_data.path;
        defer if (expanded_path.ptr != init_data.path.ptr) self.allocator.free(expanded_path);

        // Create session
        const session = self.transfer_manager.createSession(init_data.direction, init_data.flags, expanded_path) catch |err| {
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

        std.debug.print("Transfer session {d} created: {s} -> {s}\n", .{
            session.id,
            if (init_data.direction == .upload) "browser" else "server",
            if (init_data.direction == .upload) "server" else "browser",
        });

        // For downloads, build file list and send
        if (init_data.direction == .download) {
            session.buildFileList() catch |err| {
                std.debug.print("Failed to build file list: {}\n", .{err});
                const error_msg = transfer.buildTransferError(self.allocator, session.id, "Failed to read directory") catch return;
                defer self.allocator.free(error_msg);
                conn.sendBinary(error_msg) catch {};
                return;
            };

            // If dry run, send report instead of file list
            if (init_data.flags.dry_run) {
                self.sendDryRunReport(conn, session);
            } else {
                const list_msg = transfer.buildFileList(self.allocator, session) catch return;
                defer self.allocator.free(list_msg);
                conn.sendBinary(list_msg) catch {};
            }
        }
    }

    // Handle FILE_LIST_REQUEST message
    fn handleFileListRequest(self: *Server, conn: *ws.Connection, data: []u8) void {
        if (data.len < 5) return;

        const transfer_id = std.mem.readInt(u32, data[1..5], .little);
        const session = self.transfer_manager.getSession(transfer_id) orelse return;

        // Build file list
        session.buildFileList() catch |err| {
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

        // Send TRANSFER_READY
        const ready_msg = transfer.buildTransferReady(self.allocator, session.id) catch return;
        defer self.allocator.free(ready_msg);
        conn.sendBinary(ready_msg) catch {};

        // Send file list with current progress
        const list_msg = transfer.buildFileList(self.allocator, session) catch return;
        defer self.allocator.free(list_msg);
        conn.sendBinary(list_msg) catch {};

        std.debug.print("Resumed transfer {d} at {d}/{d} bytes\n", .{ session.id, session.bytes_transferred, session.total_bytes });
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

        const report_msg = transfer.buildDryRunReport(self.allocator, session.id, entries.items) catch return;
        defer self.allocator.free(report_msg);
        conn.sendBinary(report_msg) catch {};
    }

    // Expand ~ in path to home directory
    fn expandPath(self: *Server, path: []const u8) ![]u8 {
        if (path.len > 0 and path[0] == '~') {
            const home = std.posix.getenv("HOME") orelse return error.NoHome;
            return std.fmt.allocPrint(self.allocator, "{s}{s}", .{ home, path[1..] });
        }
        return self.allocator.dupe(u8, path);
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

            panel.setConnection(req.conn);
            req.conn.user_data = panel;

            self.mutex.lock();
            self.panel_connections.put(req.conn, panel) catch {};
            self.mutex.unlock();

            self.broadcastPanelCreated(panel.id);
            // Only broadcast layout update for regular panels (quick terminal is outside layout)
            if (req.kind == .regular) {
                self.broadcastLayoutUpdate();
            }

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

                // Remove from layout
                self.layout.removePanel(req.id);

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

                panel.deinit();

                // Notify clients
                self.broadcastPanelClosed(req.id);

                // Broadcast updated layout
                self.broadcastLayoutUpdate();
            } else {
                self.mutex.unlock();
            }
        }

        self.allocator.free(pending);

        // Free ghostty if no panels left (scale to zero)
        self.freeGhosttyIfEmpty();
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
                panel.resizeInternal(req.width, req.height) catch {};

                // Send inspector update if subscribed
                if (panel.inspector_subscribed) {
                    if (panel.connection) |conn| {
                        self.mutex.lock();
                        self.sendInspectorStateToPanel(panel, conn);
                        self.mutex.unlock();
                    }
                }
            } else {
                self.mutex.unlock();
            }
        }

        self.allocator.free(pending);
    }

    // Process pending panel split requests (must run on main thread)
    fn processPendingSplits(self: *Server) void {
        self.mutex.lock();
        const pending = self.pending_splits.toOwnedSlice(self.allocator) catch {
            self.mutex.unlock();
            return;
        };
        self.mutex.unlock();

        for (pending) |req| {
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

            // Associate the WebSocket connection with the new panel (same as processPendingPanels)
            panel.setConnection(req.conn);
            req.conn.user_data = panel;

            self.mutex.lock();
            self.panel_connections.put(req.conn, panel) catch {};
            self.mutex.unlock();

            self.broadcastPanelCreated(panel.id);
            self.broadcastLayoutUpdate();

            // Resume parent panel streaming (will get keyframe on next frame)
            // Note: If parent will be resized, resizeInternal sets force_keyframe
            if (parent_panel) |parent| {
                parent.resumeStream();
            }
        }

        self.allocator.free(pending);
    }

    // Main render loop
    fn runRenderLoop(self: *Server) void {
        const target_fps: u64 = 30;
        const frame_time_ns: u64 = std.time.ns_per_s / target_fps;

        var last_frame: i128 = 0;

        // DEBUG: FPS counter
        var fps_counter: u32 = 0;
        var fps_attempts: u32 = 0;
        var frame_blocks: u32 = 0;
        var fps_timer: i128 = std.time.nanoTimestamp();

        std.debug.print("Render loop started, running={}\n", .{self.running.load(.acquire)});

        while (self.running.load(.acquire)) {

            // Create autorelease pool for this iteration (macOS only - prevents ObjC object accumulation)
            const pool = if (comptime is_macos) objc_autoreleasePoolPush() else null;
            defer if (comptime is_macos) objc_autoreleasePoolPop(pool);

            // Process pending panel creations/destructions/resizes/splits (NSWindow/ghostty must be on main thread)
            self.processPendingPanels();
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
            for (panels_buf[0..panels_count]) |panel| {
                panel.processInputQueue();
            }

            // Only capture and send frames at target fps
            const now = std.time.nanoTimestamp();
            const since_last_frame: u64 = @intCast(now - last_frame);
            if (since_last_frame >= frame_time_ns) {
                last_frame = now;

                frame_blocks += 1;

                // Check if we have preview clients (overview mode)
                self.mutex.lock();
                const has_preview_clients = self.preview_connections.items.len > 0;
                const needs_immediate = self.preview_needs_immediate_frame;
                if (needs_immediate) {
                    self.preview_needs_immediate_frame = false;
                }
                self.mutex.unlock();

                // Send preview every 6th frame (5fps at 30fps base), or immediately after connect
                const send_preview = has_preview_clients and (needs_immediate or frame_blocks % 6 == 0);

                // Tick ghostty to render content to IOSurface
                self.tick();

                var frames_sent: u32 = 0;
                var frames_attempted: u32 = 0;

                // Collect panels to process (release mutex before heavy encode work)
                var frame_panels_buf: [64]*Panel = undefined;
                var frame_panels_streaming: [64]bool = undefined;
                var frame_panels_count: usize = 0;
                self.mutex.lock();

                // Determine which panels are in the active tab
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
                    const is_streaming = panel.streaming.load(.acquire);

                    // Check if panel is in the active tab
                    var in_active = false;
                    for (active_panel_ids_buf[0..active_panel_count]) |pid| {
                        if (pid == panel.id) {
                            in_active = true;
                            break;
                        }
                    }
                    // Quick terminal panels are always active when streaming
                    if (!in_active and is_streaming and panel.kind == .quick_terminal) {
                        in_active = true;
                    }

                    // Skip panels not in active tab (unless preview needs them)
                    if (!in_active and !send_preview) continue;
                    if (!is_streaming and !send_preview) continue;

                    if (frame_panels_count < frame_panels_buf.len) {
                        frame_panels_buf[frame_panels_count] = panel;
                        frame_panels_streaming[frame_panels_count] = is_streaming and in_active;
                        frame_panels_count += 1;
                    }
                }
                self.mutex.unlock();

                // Process each panel WITHOUT holding the server mutex
                // This prevents mutex starvation when encoding takes 100+ms per panel
                for (frame_panels_buf[0..frame_panels_count], frame_panels_streaming[0..frame_panels_count]) |panel, is_streaming| {

                    frames_attempted += 1;

                    // Scoped autorelease pool for ALL ObjC/Metal objects created during this panel's frame (macOS only)
                    const draw_pool = if (comptime is_macos) objc_autoreleasePoolPush() else null;
                    defer if (comptime is_macos) objc_autoreleasePoolPop(draw_pool);

                    // Render panel content to IOSurface
                    panel.tick();

                    // Platform-specific frame capture
                    var frame_data: ?[]const u8 = null;

                    if (comptime is_macos) {
                        if (panel.getIOSurface()) |iosurface| {
                            // BGRA copy path - faster than direct IOSurface encoding
                            _ = panel.captureFromIOSurface(iosurface) catch continue;

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

                        if (panel.video_encoder == null or panel.bgra_buffer == null) continue;

                        // Resize encoder if dimensions changed
                        if (pixel_width != panel.video_encoder.?.source_width or pixel_height != panel.video_encoder.?.source_height) {
                            panel.video_encoder.?.resize(pixel_width, pixel_height) catch continue;
                            if (panel.bgra_buffer.?.len != buffer_size) {
                                panel.allocator.free(panel.bgra_buffer.?);
                                panel.bgra_buffer = panel.allocator.alloc(u8, buffer_size) catch continue;
                            }
                        }

                        // Wait a few frames for ghostty to render initial content
                        if (panel.ticks_since_connect < 3) continue;

                        // Read pixels from OpenGL framebuffer
                        const read_ok = c.ghostty_surface_read_pixels(panel.surface, panel.bgra_buffer.?.ptr, panel.bgra_buffer.?.len);
                        if (read_ok) {
                            // Pass explicit dimensions to ensure encoder matches frame size
                            if (panel.video_encoder.?.encodeWithDimensions(panel.bgra_buffer.?, panel.force_keyframe, pixel_width, pixel_height) catch null) |result| {
                                frame_data = result.data;
                                panel.force_keyframe = false;
                            }
                        }
                    }

                    // Send frame to panel connection (if streaming)
                    if (frame_data) |data| {
                        if (is_streaming) {
                            panel.sendFrame(data) catch {};
                            frames_sent += 1;
                        }

                        // Send to preview clients (if any)
                        if (send_preview) {
                            self.sendPreviewFrame(panel.id, data);
                        }
                    }
                }

                fps_counter += frames_sent;
                fps_attempts += frames_attempted;

                // Reset FPS counters every second (no spam)
                const fps_elapsed = std.time.nanoTimestamp() - fps_timer;
                if (fps_elapsed >= std.time.ns_per_s) {
                    fps_counter = 0;
                    fps_attempts = 0;
                    frame_blocks = 0;
                    fps_timer = std.time.nanoTimestamp();
                }
            }


            // Wait until next frame or input event (whichever comes first)
            const elapsed: u64 = @intCast(std.time.nanoTimestamp() - now);
            const remaining = if (elapsed < frame_time_ns) frame_time_ns - elapsed else 0;
            if (remaining > 0) {
                // Block until input arrives or frame timer expires
                _ = self.wake_signal.waitTimeout(remaining);
            }
        }
    }

    fn run(self: *Server) !void {
        self.running.store(true, .release);

        // Set running flag for WebSocket servers (they don't call run() but need this for handleConnection)
        self.panel_ws_server.running.store(true, .release);
        self.control_ws_server.running.store(true, .release);
        self.file_ws_server.running.store(true, .release);

        // Start HTTP server in background (handles all WebSocket via path-based routing)
        const http_thread = try std.Thread.spawn(.{}, runHttpServer, .{self});

        // Note: WebSocket servers are NOT started with run() - they only handle
        // upgrades from HTTP server via handleUpgrade(). No separate ports needed.

        // Run render loop in main thread
        self.runRenderLoop();

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

    // Only handle selection clipboard
    if (clipboard == c.GHOSTTY_CLIPBOARD_SELECTION) {
        self.mutex.lock();
        const selection = self.selection_clipboard;
        self.mutex.unlock();

        if (selection) |sel_text| {
            c.ghostty_surface_complete_clipboard_request(panel.surface, sel_text.ptr, context, true);
            return;
        }
    }

    // Complete with empty string if no selection
    c.ghostty_surface_complete_clipboard_request(panel.surface, "", context, true);
}

fn confirmReadClipboardCallback(userdata: ?*anyopaque, data: [*c]const u8, context: ?*anyopaque, request: c.ghostty_clipboard_request_e) callconv(.c) void {
    _ = userdata;
    _ = data;
    _ = context;
    _ = request;
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
    self.mutex.lock();
    self.pending_destroys.append(self.allocator, .{ .id = panel.id }) catch {};
    self.mutex.unlock();
    self.wake_signal.notify();
}


// Main


const Args = struct {
    http_port: u16 = 8080,
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
        }
    }

    return args;
}


var sigint_received = std.atomic.Value(bool).init(false);

fn handleSigint(_: c_int) callconv(.c) void {
    if (sigint_received.swap(true, .acq_rel)) {
        // Second Ctrl+C - force exit immediately
        std.posix.exit(1);
    }
    // First Ctrl+C - graceful shutdown
    if (Server.global_server.load(.acquire)) |server| {
        server.running.store(false, .release);
        // Also stop child servers so their connection handlers exit
        server.http_server.stop();
        server.panel_ws_server.stop();
        server.control_ws_server.stop();
        server.file_ws_server.stop();
        server.preview_ws_server.stop();
    }
    std.debug.print("\nShutting down...\n", .{});
}

// WebSocket upgrade callbacks for HTTP server
fn onPanelWsUpgrade(stream: std.net.Stream, request: []const u8, user_data: ?*anyopaque) void {
    const server: *Server = @ptrCast(@alignCast(user_data orelse return));
    server.panel_ws_server.handleUpgrade(stream, request);
}

fn onControlWsUpgrade(stream: std.net.Stream, request: []const u8, user_data: ?*anyopaque) void {
    const server: *Server = @ptrCast(@alignCast(user_data orelse return));
    server.control_ws_server.handleUpgrade(stream, request);
}

fn onFileWsUpgrade(stream: std.net.Stream, request: []const u8, user_data: ?*anyopaque) void {
    const server: *Server = @ptrCast(@alignCast(user_data orelse return));
    server.file_ws_server.handleUpgrade(stream, request);
}

fn onPreviewWsUpgrade(stream: std.net.Stream, request: []const u8, user_data: ?*anyopaque) void {
    const server: *Server = @ptrCast(@alignCast(user_data orelse return));
    server.preview_ws_server.handleUpgrade(stream, request);
}

/// Run mux server - can be called from CLI or standalone
pub fn run(allocator: std.mem.Allocator, http_port: u16) !void {
    // Setup SIGINT handler for graceful shutdown
    const act = std.posix.Sigaction{
        .handler = .{ .handler = handleSigint },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);

    std.debug.print("termweb mux server starting...\n", .{});

    // WS ports use 0 to let OS assign random available ports
    const server = try Server.init(allocator, http_port, 0, 0);
    defer server.deinit();

    // Set up WebSocket upgrade callbacks on HTTP server
    // All WebSocket connections go through the HTTP port via path-based routing
    server.http_server.setWsCallbacks(
        onPanelWsUpgrade,
        onControlWsUpgrade,
        onFileWsUpgrade,
        onPreviewWsUpgrade,
        server,
    );

    std.debug.print("  HTTP + WebSocket:  http://localhost:{}\n", .{http_port});
    std.debug.print("  Web assets:        embedded (~140KB)\n", .{});
    std.debug.print("\nServer initialized, waiting for connections...\n", .{});

    try server.run();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try parseArgs(allocator);
    try run(allocator, args.http_port);
}
