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
const build_options = @import("build_options");
const enable_benchmark = build_options.enable_benchmark;
const ws = @import("ws_server.zig");
const http = @import("http_server.zig");
const transfer = @import("transfer.zig");
pub const auth = @import("auth.zig");
const WakeSignal = @import("wake_signal.zig").WakeSignal;
const Channel = @import("async/channel.zig").Channel;
const goroutine_runtime = @import("async/runtime.zig");
const gchannel = @import("async/gchannel.zig");
pub const tunnel_mod = @import("tunnel.zig");

/// Default HTTP port for the mux server.
/// Port 7681 is the conventional port for terminal-over-web tools (e.g. ttyd).
pub const default_http_port: u16 = 7681;


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
    cursor_state = 0x14,  // Cursor position/style/color for frontend CSS blink [type:u8][panel_id:u32][x:u16][y:u16][w:u16][h:u16][style:u8][visible:u8][r:u8][g:u8][b:u8] = 18 bytes
    surface_dims = 0x15,  // Surface pixel dimensions (sent on resize, not per-frame) [type:u8][panel_id:u32][width:u16][height:u16] = 9 bytes
    screen_dump = 0x16,   // Screen/selection content for browser download [type:u8][filename_len:u8][filename...][content_len:u32_le][content...]
    config_content = 0x20, // Config file content: [type:u8][path_len:u16_le][path...][content_len:u32_le][content...]
    inspector_state_open = 0x1E,  // Inspector open/closed state (0x09 is already inspector_state)
    config_updated = 0x1F,  // Config reloaded: clients should refetch /config

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
    save_config = 0x8D,    // Save config file: [type:u8][content_len:u32_le][content...]

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
    get_session_list = 0x9B,     // Request session list (admin only)
    get_share_links = 0x9C,      // Request share links (admin only)
    get_oauth_config = 0x9D,     // Request OAuth provider status (admin only)
    set_oauth_config = 0x9E,     // Set OAuth provider config (admin only)
    remove_oauth_config = 0x9F,  // Remove OAuth provider config (admin only)
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
        // Set render focus hint if none exists (first panel must render)
        if (self.active_panel_id == null) {
            self.active_panel_id = panel_id;
        }
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
        // active_panel_id set by client via 0x83 focus_panel (per-session)
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

    /// Apply even layout to a tab containing the given panel.
    /// Sets split ratios so all leaf panes get equal space, using the formula:
    /// ratio = left_leaf_count / total_leaf_count at each split node.
    pub fn applyEvenLayout(self: *Layout, panel_id: u32) void {
        const tab = self.findTabByPanel(panel_id) orelse return;
        applyEvenRatios(tab.root);
    }

    fn countLeaves(node: *const SplitNode) u32 {
        if (node.panel_id != null) return 1;
        var count: u32 = 0;
        if (node.first) |first| count += countLeaves(first);
        if (node.second) |second| count += countLeaves(second);
        return count;
    }

    fn applyEvenRatios(node: *SplitNode) void {
        if (node.panel_id != null) return; // leaf
        const left_count = if (node.first) |f| countLeaves(f) else 0;
        const right_count = if (node.second) |s| countLeaves(s) else 0;
        const total = left_count + right_count;
        if (total > 0) {
            node.ratio = @as(f32, @floatFromInt(left_count)) / @as(f32, @floatFromInt(total));
        }
        if (node.first) |first| applyEvenRatios(first);
        if (node.second) |second| applyEvenRatios(second);
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

    /// Move a tab by delta positions (-1 = left, +1 = right). Returns true if moved.
    pub fn moveTab(self: *Layout, tab_id: u32, delta: i32) bool {
        const idx: usize = for (self.tabs.items, 0..) |tab, i| {
            if (tab.id == tab_id) break i;
        } else return false;

        const new_idx_i64 = @as(i64, @intCast(idx)) + delta;
        if (new_idx_i64 < 0 or new_idx_i64 >= @as(i64, @intCast(self.tabs.items.len))) return false;
        const new_idx: usize = @intCast(new_idx_i64);

        const tmp = self.tabs.items[idx];
        self.tabs.items[idx] = self.tabs.items[new_idx];
        self.tabs.items[new_idx] = tmp;
        return true;
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
        // activePanelId is per-session (managed client-side), not part of shared layout
        try writer.writeAll("]}");

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
    mouse_scroll: struct { x: f64, y: f64, dx: f64, dy: f64, precision: bool = false },
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
    idle_keyframe_sent: bool, // One-shot: sent a quality keyframe during this idle period
    had_input: bool, // Set by processInputQueue on key/scroll events, cleared by render loop

    // Cursor state tracking (for frontend CSS blink overlay)
    last_cursor_col: u16 = 0,
    last_cursor_row: u16 = 0,
    last_cursor_style: u8 = 0,
    last_cursor_visible: u8 = 1,
    last_cursor_color_r: u8 = 0xc8,
    last_cursor_color_g: u8 = 0xc8,
    last_cursor_color_b: u8 = 0xc8,
    last_surf_w: u16 = 0,
    last_surf_h: u16 = 0,
    last_cell_w: u16 = 0,
    last_cell_h: u16 = 0,
    dbg_input_countdown: u32 = 0, // Debug: log N frames after input

    const TARGET_FPS: i64 = 30; // 30 FPS for video
    /// After this many consecutive unchanged frames, reduce tick rate to save CPU/GPU.
    /// At 30 FPS, 30 unchanged frames ≈ 1 second of idle.
    const IDLE_THRESHOLD: u32 = 30;
    /// When idle, only tick every Nth cycle (effectively ~3 FPS for cursor/spinner checks)
    const IDLE_DIVISOR: u32 = 10;
    /// After this many consecutive unchanged frames, send a quality keyframe.
    /// At 30 FPS, 15 frames ≈ 0.5 seconds of idle after activity stops.
    const IDLE_KEYFRAME_THRESHOLD: u32 = 15;
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

        // Set environment variables for shell integration and tmux shim
        // Build PATH with tmux shim directory prepended so mock tmux is found first
        const server = Server.global_server.load(.acquire) orelse return error.NoServer;
        const orig_path = std.posix.getenv("PATH") orelse "/usr/local/bin:/usr/bin:/bin";

        var path_buf: [4096]u8 = undefined;
        const path_val = std.fmt.bufPrint(&path_buf, "{s}:{s}", .{ server.tmux_shim_dir, orig_path }) catch orig_path;
        // Null-terminate for C interop
        var path_z_buf: [4097]u8 = undefined;
        @memcpy(path_z_buf[0..path_val.len], path_val);
        path_z_buf[path_val.len] = 0;

        // Unix socket path for tmux shim (null-terminated)
        var sock_z_buf: [256]u8 = undefined;
        const sock_val = server.tmux_sock_path;
        const sock_len = @min(sock_val.len, sock_z_buf.len - 1);
        @memcpy(sock_z_buf[0..sock_len], sock_val[0..sock_len]);
        sock_z_buf[sock_len] = 0;

        var pane_id_buf: [12]u8 = undefined;
        const pane_id_val = std.fmt.bufPrint(&pane_id_buf, "{d}", .{id}) catch "1";
        var pane_id_z_buf: [13]u8 = undefined;
        @memcpy(pane_id_z_buf[0..pane_id_val.len], pane_id_val);
        pane_id_z_buf[pane_id_val.len] = 0;

        var tmux_pane_buf: [14]u8 = undefined;
        const tmux_pane_val = std.fmt.bufPrint(&tmux_pane_buf, "%{d}", .{id}) catch "%1";
        var tmux_pane_z_buf: [15]u8 = undefined;
        @memcpy(tmux_pane_z_buf[0..tmux_pane_val.len], tmux_pane_val);
        tmux_pane_z_buf[tmux_pane_val.len] = 0;

        var env_vars = [_]c.ghostty_env_var_s{
            .{ .key = "GHOSTTY_SHELL_FEATURES", .value = "cursor,title,sudo" },
            .{ .key = "PATH", .value = @ptrCast(&path_z_buf) },
            .{ .key = "TERMWEB_SOCK", .value = @ptrCast(&sock_z_buf) },
            .{ .key = "TERMWEB_PANE_ID", .value = @ptrCast(&pane_id_z_buf) },
            .{ .key = "TMUX", .value = "/tmp/termweb-shim,0,0" },
            .{ .key = "TMUX_PANE", .value = @ptrCast(&tmux_pane_z_buf) },
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
            .idle_keyframe_sent = false,
            .had_input = false,
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
        // Take ownership of the queue's backing storage to release mutex quickly.
        // Swap with an empty list so new events can be queued immediately.
        var local_queue = self.input_queue;
        self.input_queue = .{};
        self.has_pending_input.store(false, .release);
        // Reset adaptive idle mode so the next frame capture runs immediately.
        // Without this, processInputQueue clears has_pending_input before the
        // frame capture loop checks it, causing the idle skip to stay active.
        self.consecutive_unchanged = 0;
        // Debug: log the next 30 frames after input to see if hash changes
        self.dbg_input_countdown = 30;
        self.mutex.unlock();
        defer local_queue.deinit(self.allocator);

        for (local_queue.items) |*event| {
            switch (event.*) {
                .key => |*key_event| {
                    // Set text pointer to our stored buffer
                    if (key_event.text_len > 0) {
                        key_event.input.text = @ptrCast(&key_event.text_buf);
                    }
                    _ = c.ghostty_surface_key(self.surface, key_event.input);
                    self.had_input = true;
                },
                .text => |text| {
                    c.ghostty_surface_text(self.surface, &text.data, text.len);
                },
                .mouse_pos => |pos| {
                    c.ghostty_surface_mouse_pos(self.surface, pos.x, pos.y, pos.mods);
                    self.had_input = true;
                },
                .mouse_button => |btn| {
                    // Send position first, then button event.
                    // ghostty_surface_mouse_button may trigger selection/clipboard
                    // operations internally.
                    _ = c.ghostty_surface_mouse_button(self.surface, btn.state, btn.button, btn.mods);
                    self.had_input = true;
                },
                .mouse_scroll => |scroll| {
                    c.ghostty_surface_mouse_pos(self.surface, scroll.x, scroll.y, 0);
                    // ScrollMods packed struct: bit 0 = precision (trackpad pixel scroll)
                    const scroll_mods: c_int = if (scroll.precision) 1 else 0;
                    c.ghostty_surface_mouse_scroll(self.surface, scroll.dx, scroll.dy, scroll_mods);
                    self.had_input = true;
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
                // When text is produced, Shift was "consumed" by the input method
                // to generate the uppercase/shifted character (e.g., Shift+c → "C").
                // Without this, ghostty's effectiveMods() still sees Shift as active,
                // causing escape sequence encoding instead of plain text output.
                .consumed_mods = if (text_len > 0 and (mods & 0x01) != 0)
                    @intCast(c.GHOSTTY_MODS_SHIFT)
                else
                    0,
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

    /// Queue a key press+release event (used by tmux send-keys for special keys).
    /// This bypasses bracketed paste mode — Enter actually executes commands.
    fn queueKeyEvent(self: *Panel, keycode: u32, mods: u32, text: ?[]const u8) void {
        // Press event
        var press: InputEvent = .{ .key = .{
            .input = c.ghostty_input_key_s{
                .action = c.GHOSTTY_ACTION_PRESS,
                .keycode = keycode,
                .mods = @intCast(mods),
                .consumed_mods = 0,
                .text = null,
                .unshifted_codepoint = 0,
                .composing = false,
            },
            .text_buf = undefined,
            .text_len = 0,
        } };
        if (text) |t| {
            const len: u8 = @min(@as(u8, @intCast(t.len)), 7);
            @memcpy(press.key.text_buf[0..len], t[0..len]);
            press.key.text_buf[len] = 0;
            press.key.text_len = len;
        }

        // Release event (same keycode, no text)
        var release = press;
        release.key.input.action = c.GHOSTTY_ACTION_RELEASE;
        release.key.input.text = null;
        release.key.text_len = 0;

        self.mutex.lock();
        defer self.mutex.unlock();
        self.input_queue.append(self.allocator, press) catch {};
        self.input_queue.append(self.allocator, release) catch {};
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
    // Format: [x:f64][y:f64][dx:f64][dy:f64][mods:u8][precision:u8] = 34 bytes
    fn handleMouseScroll(self: *Panel, data: []const u8) void {
        if (data.len < 33) return;

        const x: f64 = @bitCast(std.mem.readInt(u64, data[0..8], .little));
        const y: f64 = @bitCast(std.mem.readInt(u64, data[8..16], .little));
        const dx: f64 = @bitCast(std.mem.readInt(u64, data[16..24], .little));
        const dy: f64 = @bitCast(std.mem.readInt(u64, data[24..32], .little));
        const mods = convertMods(data[32]);
        // Precision flag from browser: 1 = pixel-precise (trackpad), 0 = discrete wheel
        const precision: bool = if (data.len > 33) data[33] != 0 else false;

        self.mutex.lock();
        defer self.mutex.unlock();
        // Queue position update first, then scroll event
        self.input_queue.append(self.allocator, .{ .mouse_pos = .{ .x = x, .y = y, .mods = mods } }) catch {};
        self.input_queue.append(self.allocator, .{ .mouse_scroll = .{ .x = x, .y = y, .dx = dx, .dy = dy, .precision = precision } }) catch {};
    }

    // Handle client message
    fn handleMessage(self: *Panel, data: []const u8) void {
        if (data.len == 0) return;

        const msg_type: ClientMsg = std.meta.intToEnum(ClientMsg, data[0]) catch return;
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
    from_api: bool = false, // If true, send new panel ID to tmux_api_response_ch
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
    from_api: bool = false, // If true, send new panel ID to tmux_api_response_ch
    apply_even_layout: bool = false, // If true, apply even layout after split
};

/// JWT renewal tracking per connection
const JwtExpiry = struct {
    session_id: []const u8, // Heap-allocated, owned by this struct
    expiry: i64,
};

/// Per-session viewport dimensions, tracked so the server knows each client's
/// screen size for split creation and PTY sizing decisions.
const SessionViewport = struct {
    width: u32,
    height: u32,
    scale: f64,
};

const Server = struct {
    // Ghostty app/config - lazy initialized on first panel, freed when last panel closes
    app: ?c.ghostty_app_t,
    config: ?c.ghostty_config_t,
    config_json: ?[]const u8,  // Pre-built JSON for config (colors + keybindings)
    ghostty_initialized: bool,  // Whether ghostty_init() has been called
    panels: std.AutoHashMap(u32, *Panel),
    h264_connections: std.ArrayList(*ws.Connection),
    control_connections: std.ArrayList(*ws.Connection),
    file_connections: std.ArrayList(*ws.Connection),
    connection_roles: std.AutoHashMap(*ws.Connection, auth.Role),  // Track connection roles
    control_client_ids: std.AutoHashMap(*ws.Connection, u32),  // Track client IDs per control connection
    connection_jwt_info: std.AutoHashMap(*ws.Connection, JwtExpiry),  // JWT renewal tracking
    last_jwt_check: i64,  // Timestamp of last JWT renewal check (throttle)
    // Multiplayer: pane assignment state
    panel_assignments: std.AutoHashMap(u32, []const u8),  // panel_id → session_id
    connection_sessions: std.AutoHashMap(*ws.Connection, []const u8),  // conn → session_id (cached)
    session_active_panels: std.StringHashMap(u32),  // session_id → focused panel_id (per-session focus)
    session_viewports: std.StringHashMap(SessionViewport),  // session_id → last known viewport
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
    rate_limiter: auth.RateLimiter,  // Per-IP rate limiting for failed auth attempts
    transfer_manager: transfer.TransferManager,
    push_threads: std.ArrayList(std.Thread),  // Tracked push threads for clean shutdown
    push_threads_mutex: std.Thread.Mutex,
    running: std.atomic.Value(bool),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    selection_clipboard: ?[]u8,  // Selection clipboard buffer
    standard_clipboard: ?[]u8,  // Standard clipboard buffer (from browser paste)
    screen_dump_pending: std.atomic.Value(bool),  // Flag: next clipboard write is a screen dump file path
    initial_cwd: []const u8,  // CWD where termweb was started
    initial_cwd_allocated: bool,  // Whether initial_cwd was allocated (vs static "/")
    tmux_shim_dir: []const u8,  // Temp directory containing mock tmux script (prepended to PATH)
    tmux_sock_path: []const u8,  // Unix domain socket path for tmux shim API
    tmux_sock_fd: ?std.posix.socket_t,  // Listening Unix socket fd (null if not started)
    tmux_sock_thread: ?std.Thread,  // Listener thread for Unix socket
    tmux_api_response_ch: *Channel(u32),  // One-shot channel for sync API responses (panel ID)
    overview_open: bool,  // Whether tab overview is currently open
    quick_terminal_open: bool,  // Whether quick terminal is open
    inspector_open: bool,  // Whether inspector is open
    shared_va_ctx: if (is_linux) ?video.SharedVaContext else void,  // Shared VA-API context for fast encoder init
    wake_signal: WakeSignal,  // Event-driven wakeup for render loop (replaces sleep polling)
    goroutine_rt: *goroutine_runtime.Runtime, // M:N goroutine scheduler for file transfer pipeline

    // Bandwidth benchmark counters (atomic — updated from multiple threads)
    // Enabled with: zig build -Dbenchmark
    bw_h264_bytes: if (enable_benchmark) std.atomic.Value(u64) else void,
    bw_h264_frames: if (enable_benchmark) std.atomic.Value(u64) else void,
    bw_control_bytes_sent: if (enable_benchmark) std.atomic.Value(u64) else void,
    bw_control_bytes_recv: if (enable_benchmark) std.atomic.Value(u64) else void,
    bw_raw_pixels_bytes: if (enable_benchmark) std.atomic.Value(u64) else void,
    bw_vt_bytes: if (enable_benchmark) std.atomic.Value(u64) else void,     // VT output bytes from child processes (via /proc wchar)
    bw_commands: if (enable_benchmark) [32][17:0]u8 else void,              // Recent unique command names (null-terminated)
    bw_commands_len: if (enable_benchmark) std.atomic.Value(u32) else void, // Number of unique commands seen
    bw_start_time: if (enable_benchmark) std.atomic.Value(i64) else void,

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

        // Channel for synchronous tmux API responses (panel creation returns new ID)
        const tmux_api_response_ch = try Channel(u32).initBuffered(allocator, 1);
        errdefer tmux_api_response_ch.deinit();

        // Create tmux shim directory with mock tmux script and Unix socket
        const shim_result = try createTmuxShimDir(allocator);
        errdefer {
            std.fs.cwd().deleteTree(shim_result.bin_dir) catch {};
            allocator.free(shim_result.bin_dir);
            allocator.free(shim_result.sock_path);
        }

        // Initialize goroutine runtime for file transfer pipeline (0 = auto-detect CPU count)
        const gor_rt = try goroutine_runtime.Runtime.init(allocator, 0);
        errdefer gor_rt.deinit();

        server.* = .{
            .app = null, // Lazy init on first panel
            .config = null,
            .config_json = null,
            .ghostty_initialized = false,
            .panels = std.AutoHashMap(u32, *Panel).init(allocator),
            .h264_connections = .{},
            .control_connections = .{},
            .file_connections = .{},
            .connection_roles = std.AutoHashMap(*ws.Connection, auth.Role).init(allocator),
            .control_client_ids = std.AutoHashMap(*ws.Connection, u32).init(allocator),
            .connection_jwt_info = std.AutoHashMap(*ws.Connection, JwtExpiry).init(allocator),
            .last_jwt_check = 0,
            .panel_assignments = std.AutoHashMap(u32, []const u8).init(allocator),
            .connection_sessions = std.AutoHashMap(*ws.Connection, []const u8).init(allocator),
            .session_active_panels = std.StringHashMap(u32).init(allocator),
            .session_viewports = std.StringHashMap(SessionViewport).init(allocator),
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
            .rate_limiter = auth.RateLimiter.init(allocator),
            .transfer_manager = transfer.TransferManager.init(allocator),
            .push_threads = .{},
            .push_threads_mutex = .{},
            .running = std.atomic.Value(bool).init(false),
            .allocator = allocator,
            .mutex = .{},
            .selection_clipboard = null,
            .standard_clipboard = null,
            .screen_dump_pending = std.atomic.Value(bool).init(false),
            .initial_cwd = undefined,
            .initial_cwd_allocated = false,
            .tmux_shim_dir = shim_result.bin_dir,
            .tmux_sock_path = shim_result.sock_path,
            .tmux_sock_fd = null,
            .tmux_sock_thread = null,
            .tmux_api_response_ch = tmux_api_response_ch,
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
            .bw_h264_bytes = if (enable_benchmark) std.atomic.Value(u64).init(0) else {},
            .bw_h264_frames = if (enable_benchmark) std.atomic.Value(u64).init(0) else {},
            .bw_control_bytes_sent = if (enable_benchmark) std.atomic.Value(u64).init(0) else {},
            .bw_control_bytes_recv = if (enable_benchmark) std.atomic.Value(u64).init(0) else {},
            .bw_raw_pixels_bytes = if (enable_benchmark) std.atomic.Value(u64).init(0) else {},
            .bw_vt_bytes = if (enable_benchmark) std.atomic.Value(u64).init(0) else {},
            .bw_commands = if (enable_benchmark) [_][17:0]u8{[_:0]u8{0} ** 17} ** 32 else {},
            .bw_commands_len = if (enable_benchmark) std.atomic.Value(u32).init(0) else {},
            .bw_start_time = if (enable_benchmark) std.atomic.Value(i64).init(@truncate(std.time.nanoTimestamp())) else {},
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

        if (!self.ghostty_initialized) {
            const init_result = c.ghostty_init(0, null);
            if (init_result != c.GHOSTTY_SUCCESS) return error.GhosttyInitFailed;
            self.ghostty_initialized = true;
        }

        // Load ghostty config: termweb defaults first, then user overrides
        const config = c.ghostty_config_new();

        // Write termweb defaults to temp file (user's ghostty config overrides these)
        const defaults_path = "/tmp/termweb-ghostty-defaults.conf";
        if (std.fs.cwd().createFile(defaults_path, .{})) |f| {
            defer f.close();
            f.writeAll("keybind = clear\ncursor-style = bar\ncursor-style-blink = false\ncursor-opacity = 0\n") catch {};
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

        // Build config JSON (colors + keybindings) for HTTP endpoint
        if (self.config_json) |old| self.allocator.free(old);
        self.config_json = self.buildConfigJson(config) catch null;
        self.http_server.config_json = self.config_json;
    }

    /// Color struct matching ghostty_config_color_s
    const Color = extern struct { r: u8, g: u8, b: u8 };

    /// Keybinding entry: maps termweb action → ghostty action + default key/mods
    const KeybindEntry = struct {
        termweb_action: []const u8,
        ghostty_action: ?[]const u8, // null = no ghostty equivalent
        default_key: []const u8,
        default_mods: []const u8, // JSON array string e.g. "[\"super\",\"shift\"]"
    };

    const keybind_table = [_]KeybindEntry{
        .{ .termweb_action = "_command_palette", .ghostty_action = "toggle_command_palette", .default_key = "k", .default_mods = "[\"super\",\"shift\"]" },
        .{ .termweb_action = "_new_tab", .ghostty_action = "new_tab", .default_key = "/", .default_mods = "[\"super\"]" },
        .{ .termweb_action = "_close", .ghostty_action = "close_surface", .default_key = ".", .default_mods = "[\"super\"]" },
        .{ .termweb_action = "_close_tab", .ghostty_action = "close_tab", .default_key = ".", .default_mods = "[\"super\",\"alt\"]" },
        .{ .termweb_action = "_close_window", .ghostty_action = "close_window", .default_key = ".", .default_mods = "[\"super\",\"shift\"]" },
        .{ .termweb_action = "_split_right", .ghostty_action = "new_split:right", .default_key = "d", .default_mods = "[\"super\"]" },
        .{ .termweb_action = "_split_down", .ghostty_action = "new_split:down", .default_key = "d", .default_mods = "[\"super\",\"shift\"]" },
        .{ .termweb_action = "_show_all_tabs", .ghostty_action = "toggle_tab_overview", .default_key = "a", .default_mods = "[\"super\",\"shift\"]" },
        .{ .termweb_action = "_toggle_fullscreen", .ghostty_action = "toggle_fullscreen", .default_key = "f", .default_mods = "[\"super\",\"shift\"]" },
        .{ .termweb_action = "_quick_terminal", .ghostty_action = "toggle_quick_terminal", .default_key = "\\", .default_mods = "[\"super\",\"alt\"]" },
        .{ .termweb_action = "_toggle_inspector", .ghostty_action = "inspector:toggle", .default_key = "i", .default_mods = "[\"super\",\"alt\"]" },
        .{ .termweb_action = "_zoom_split", .ghostty_action = "toggle_split_zoom", .default_key = "enter", .default_mods = "[\"super\",\"shift\"]" },
        .{ .termweb_action = "copy_to_clipboard", .ghostty_action = "copy_to_clipboard", .default_key = "c", .default_mods = "[\"super\"]" },
        .{ .termweb_action = "paste_from_clipboard", .ghostty_action = "paste_from_clipboard", .default_key = "v", .default_mods = "[\"super\"]" },
        .{ .termweb_action = "paste_from_selection", .ghostty_action = "paste_from_selection", .default_key = "v", .default_mods = "[\"super\",\"shift\"]" },
        .{ .termweb_action = "select_all", .ghostty_action = "select_all", .default_key = "a", .default_mods = "[\"super\"]" },
        .{ .termweb_action = "increase_font_size:1", .ghostty_action = "increase_font_size:1", .default_key = "=", .default_mods = "[\"super\"]" },
        .{ .termweb_action = "decrease_font_size:1", .ghostty_action = "decrease_font_size:1", .default_key = "-", .default_mods = "[\"super\"]" },
        .{ .termweb_action = "reset_font_size", .ghostty_action = "reset_font_size", .default_key = "0", .default_mods = "[\"super\"]" },
        .{ .termweb_action = "reload_config", .ghostty_action = "reload_config", .default_key = ",", .default_mods = "[\"super\",\"shift\"]" },
        .{ .termweb_action = "_previous_split", .ghostty_action = "goto_split:previous", .default_key = "[", .default_mods = "[\"super\"]" },
        .{ .termweb_action = "_next_split", .ghostty_action = "goto_split:next", .default_key = "]", .default_mods = "[\"super\"]" },
        .{ .termweb_action = "_previous_tab", .ghostty_action = "previous_tab", .default_key = "[", .default_mods = "[\"super\",\"shift\"]" },
        .{ .termweb_action = "_next_tab", .ghostty_action = "next_tab", .default_key = "]", .default_mods = "[\"super\",\"shift\"]" },
        .{ .termweb_action = "_upload", .ghostty_action = null, .default_key = "u", .default_mods = "[\"super\"]" },
        .{ .termweb_action = "_download", .ghostty_action = null, .default_key = "s", .default_mods = "[\"super\",\"shift\"]" },
        .{ .termweb_action = "_select_split_up", .ghostty_action = null, .default_key = "arrowup", .default_mods = "[\"super\",\"shift\"]" },
        .{ .termweb_action = "_select_split_down", .ghostty_action = null, .default_key = "arrowdown", .default_mods = "[\"super\",\"shift\"]" },
        .{ .termweb_action = "_select_split_left", .ghostty_action = null, .default_key = "arrowleft", .default_mods = "[\"super\",\"shift\"]" },
        .{ .termweb_action = "_select_split_right", .ghostty_action = null, .default_key = "arrowright", .default_mods = "[\"super\",\"shift\"]" },
    };

    /// Convert ghostty key enum to JS key string
    fn ghosttyKeyToJs(key: c_uint) ?[]const u8 {
        return switch (key) {
            c.GHOSTTY_KEY_A => "a", c.GHOSTTY_KEY_B => "b", c.GHOSTTY_KEY_C => "c",
            c.GHOSTTY_KEY_D => "d", c.GHOSTTY_KEY_E => "e", c.GHOSTTY_KEY_F => "f",
            c.GHOSTTY_KEY_G => "g", c.GHOSTTY_KEY_H => "h", c.GHOSTTY_KEY_I => "i",
            c.GHOSTTY_KEY_J => "j", c.GHOSTTY_KEY_K => "k", c.GHOSTTY_KEY_L => "l",
            c.GHOSTTY_KEY_M => "m", c.GHOSTTY_KEY_N => "n", c.GHOSTTY_KEY_O => "o",
            c.GHOSTTY_KEY_P => "p", c.GHOSTTY_KEY_Q => "q", c.GHOSTTY_KEY_R => "r",
            c.GHOSTTY_KEY_S => "s", c.GHOSTTY_KEY_T => "t", c.GHOSTTY_KEY_U => "u",
            c.GHOSTTY_KEY_V => "v", c.GHOSTTY_KEY_W => "w", c.GHOSTTY_KEY_X => "x",
            c.GHOSTTY_KEY_Y => "y", c.GHOSTTY_KEY_Z => "z",
            c.GHOSTTY_KEY_DIGIT_0 => "0", c.GHOSTTY_KEY_DIGIT_1 => "1",
            c.GHOSTTY_KEY_DIGIT_2 => "2", c.GHOSTTY_KEY_DIGIT_3 => "3",
            c.GHOSTTY_KEY_DIGIT_4 => "4", c.GHOSTTY_KEY_DIGIT_5 => "5",
            c.GHOSTTY_KEY_DIGIT_6 => "6", c.GHOSTTY_KEY_DIGIT_7 => "7",
            c.GHOSTTY_KEY_DIGIT_8 => "8", c.GHOSTTY_KEY_DIGIT_9 => "9",
            c.GHOSTTY_KEY_MINUS => "-", c.GHOSTTY_KEY_EQUAL => "=",
            c.GHOSTTY_KEY_BRACKET_LEFT => "[", c.GHOSTTY_KEY_BRACKET_RIGHT => "]",
            c.GHOSTTY_KEY_BACKSLASH => "\\", c.GHOSTTY_KEY_SEMICOLON => ";",
            c.GHOSTTY_KEY_QUOTE => "'", c.GHOSTTY_KEY_BACKQUOTE => "`",
            c.GHOSTTY_KEY_COMMA => ",", c.GHOSTTY_KEY_PERIOD => ".",
            c.GHOSTTY_KEY_SLASH => "/", c.GHOSTTY_KEY_SPACE => " ",
            c.GHOSTTY_KEY_ENTER => "enter", c.GHOSTTY_KEY_TAB => "tab",
            c.GHOSTTY_KEY_BACKSPACE => "backspace", c.GHOSTTY_KEY_ESCAPE => "escape",
            c.GHOSTTY_KEY_ARROW_UP => "arrowup", c.GHOSTTY_KEY_ARROW_DOWN => "arrowdown",
            c.GHOSTTY_KEY_ARROW_LEFT => "arrowleft", c.GHOSTTY_KEY_ARROW_RIGHT => "arrowright",
            c.GHOSTTY_KEY_HOME => "home", c.GHOSTTY_KEY_END => "end",
            c.GHOSTTY_KEY_PAGE_UP => "pageup", c.GHOSTTY_KEY_PAGE_DOWN => "pagedown",
            c.GHOSTTY_KEY_DELETE => "delete", c.GHOSTTY_KEY_INSERT => "insert",
            c.GHOSTTY_KEY_F1 => "f1", c.GHOSTTY_KEY_F2 => "f2", c.GHOSTTY_KEY_F3 => "f3",
            c.GHOSTTY_KEY_F4 => "f4", c.GHOSTTY_KEY_F5 => "f5", c.GHOSTTY_KEY_F6 => "f6",
            c.GHOSTTY_KEY_F7 => "f7", c.GHOSTTY_KEY_F8 => "f8", c.GHOSTTY_KEY_F9 => "f9",
            c.GHOSTTY_KEY_F10 => "f10", c.GHOSTTY_KEY_F11 => "f11", c.GHOSTTY_KEY_F12 => "f12",
            else => null,
        };
    }

    const ModsList = struct { items: [4][]const u8, len: usize };

    /// Convert ghostty mod bitmask to a bounded list of modifier name strings.
    fn ghosttyModsToList(mods: c_uint) ModsList {
        var result: ModsList = .{ .items = undefined, .len = 0 };
        if (mods & c.GHOSTTY_MODS_CTRL != 0) { result.items[result.len] = "ctrl"; result.len += 1; }
        if (mods & c.GHOSTTY_MODS_ALT != 0) { result.items[result.len] = "alt"; result.len += 1; }
        if (mods & c.GHOSTTY_MODS_SHIFT != 0) { result.items[result.len] = "shift"; result.len += 1; }
        if (mods & c.GHOSTTY_MODS_SUPER != 0) { result.items[result.len] = "super"; result.len += 1; }
        return result;
    }

    /// Parse a default_mods string like `["super","shift"]` into a bounded list.
    fn parseDefaultMods(mods_str: []const u8) ModsList {
        var result: ModsList = .{ .items = undefined, .len = 0 };
        // Simple parser: find quoted strings between [ and ]
        var i: usize = 0;
        while (i < mods_str.len) : (i += 1) {
            if (mods_str[i] == '"') {
                const start = i + 1;
                i += 1;
                while (i < mods_str.len and mods_str[i] != '"') : (i += 1) {}
                if (i < mods_str.len and result.len < 4) {
                    result.items[result.len] = mods_str[start..i];
                    result.len += 1;
                }
            }
        }
        return result;
    }

    /// Build the config JSON using std.json.Stringify for correct encoding.
    /// Caller owns the returned slice and must free with allocator.
    fn buildConfigJson(self: *Server, config: c.ghostty_config_t) ![]const u8 {
        const json = std.json;

        var aw: std.io.Writer.Allocating = .init(self.allocator);
        errdefer aw.deinit();
        var jw: json.Stringify = .{ .writer = &aw.writer };

        // Get colors
        var bg: Color = .{ .r = 0x28, .g = 0x2C, .b = 0x34 };
        var fg: Color = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF };
        _ = c.ghostty_config_get(config, &bg, "background", 10);
        _ = c.ghostty_config_get(config, &fg, "foreground", 10);

        var bg_hex: [7]u8 = undefined;
        _ = std.fmt.bufPrint(&bg_hex, "#{x:0>2}{x:0>2}{x:0>2}", .{ bg.r, bg.g, bg.b }) catch unreachable;
        var fg_hex: [7]u8 = undefined;
        _ = std.fmt.bufPrint(&fg_hex, "#{x:0>2}{x:0>2}{x:0>2}", .{ fg.r, fg.g, fg.b }) catch unreachable;

        // Root object
        jw.beginObject() catch return error.OutOfMemory;

        // "wsPath": true
        jw.objectField("wsPath") catch return error.OutOfMemory;
        jw.write(true) catch return error.OutOfMemory;

        // "colors": { "background": "#rrggbb", "foreground": "#rrggbb" }
        jw.objectField("colors") catch return error.OutOfMemory;
        jw.beginObject() catch return error.OutOfMemory;
        jw.objectField("background") catch return error.OutOfMemory;
        jw.write(&bg_hex) catch return error.OutOfMemory;
        jw.objectField("foreground") catch return error.OutOfMemory;
        jw.write(&fg_hex) catch return error.OutOfMemory;
        jw.endObject() catch return error.OutOfMemory;

        // "keybindings": { ... }
        jw.objectField("keybindings") catch return error.OutOfMemory;
        jw.beginObject() catch return error.OutOfMemory;

        for (keybind_table) |entry| {
            var key_str: []const u8 = entry.default_key;
            var mods_list = parseDefaultMods(entry.default_mods);

            // Query ghostty config for user override
            if (entry.ghostty_action) |ga| {
                const trigger = c.ghostty_config_trigger(config, ga.ptr, ga.len);
                if (trigger.tag != c.GHOSTTY_TRIGGER_CATCH_ALL) {
                    const ghost_key: c_uint = if (trigger.tag == c.GHOSTTY_TRIGGER_UNICODE)
                        c.GHOSTTY_KEY_UNIDENTIFIED
                    else
                        trigger.key.physical;

                    if (ghost_key != c.GHOSTTY_KEY_UNIDENTIFIED) {
                        if (ghosttyKeyToJs(ghost_key)) |js_key| {
                            key_str = js_key;
                            mods_list = ghosttyModsToList(trigger.mods);
                        }
                    }
                }
            }

            // "action_name": { "key": "k", "mods": ["super", "shift"] }
            jw.objectField(entry.termweb_action) catch return error.OutOfMemory;
            jw.beginObject() catch return error.OutOfMemory;
            jw.objectField("key") catch return error.OutOfMemory;
            jw.write(key_str) catch return error.OutOfMemory;
            jw.objectField("mods") catch return error.OutOfMemory;
            jw.beginArray() catch return error.OutOfMemory;
            for (mods_list.items[0..mods_list.len]) |mod| {
                jw.write(mod) catch return error.OutOfMemory;
            }
            jw.endArray() catch return error.OutOfMemory;
            jw.endObject() catch return error.OutOfMemory;
        }

        jw.endObject() catch return error.OutOfMemory; // end keybindings
        jw.endObject() catch return error.OutOfMemory; // end root

        return aw.toOwnedSlice();
    }

    /// Broadcast config_updated with the latest config JSON payload.
    /// Message format: [opcode 0x1F][config_json_bytes...]
    fn broadcastConfigUpdated(self: *Server) void {
        const json = self.config_json orelse {
            // No config available — send opcode-only as fallback
            var buf: [1]u8 = .{@intFromEnum(BinaryCtrlMsg.config_updated)};
            self.broadcastControlData(&buf);
            return;
        };
        // Allocate opcode + json payload
        const msg = self.allocator.alloc(u8, 1 + json.len) catch {
            var buf: [1]u8 = .{@intFromEnum(BinaryCtrlMsg.config_updated)};
            self.broadcastControlData(&buf);
            return;
        };
        defer self.allocator.free(msg);
        msg[0] = @intFromEnum(BinaryCtrlMsg.config_updated);
        @memcpy(msg[1..], json);
        self.broadcastControlData(msg);
    }

    /// Load ghostty config and build config JSON without creating app/surfaces.
    /// Called at server startup so the first page load has config embedded in HTML.
    fn loadConfigOnly(self: *Server) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Skip if config already loaded (ensureGhosttyInit already ran)
        if (self.config_json != null) return;

        // Initialize ghostty runtime (safe to call before app creation)
        if (!self.ghostty_initialized) {
            const init_result = c.ghostty_init(0, null);
            if (init_result != c.GHOSTTY_SUCCESS) {
                std.debug.print("Warning: ghostty_init failed, config unavailable\n", .{});
                return;
            }
            self.ghostty_initialized = true;
        }

        const config = c.ghostty_config_new();

        // Write termweb defaults to temp file (user's ghostty config overrides these)
        const defaults_path = "/tmp/termweb-ghostty-defaults.conf";
        if (std.fs.cwd().createFile(defaults_path, .{})) |f| {
            defer f.close();
            f.writeAll("keybind = clear\ncursor-style = bar\ncursor-style-blink = false\ncursor-opacity = 0\n") catch {};
            c.ghostty_config_load_file(config, defaults_path);
        } else |_| {}

        c.ghostty_config_load_default_files(config);
        c.ghostty_config_finalize(config);

        self.config_json = self.buildConfigJson(config) catch null;
        self.http_server.config_json = self.config_json;

        // Free the config — we only needed it to extract JSON.
        // ensureGhosttyInit will load its own config when the first panel is created.
        c.ghostty_config_free(config);
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

        // Take ownership of app/config while holding mutex.
        // Keep config_json alive — it's needed for new page loads even with no panels.
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
        std.debug.print("[deinit] starting...\n", .{});
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
        self.tmux_api_response_ch.close();

        // Clear global_server first to prevent callbacks from accessing it during shutdown
        global_server.store(null, .release);

        // Shut down WebSocket servers first and wait for all connection threads to finish
        // This must happen BEFORE destroying panels to avoid use-after-free
        std.debug.print("[deinit] stopping servers...\n", .{});
        self.http_server.deinit();
        std.debug.print("[deinit] http done, stopping h264...\n", .{});
        self.h264_ws_server.deinit();
        std.debug.print("[deinit] h264 done, stopping control...\n", .{});
        self.control_ws_server.deinit();
        std.debug.print("[deinit] control done, stopping file...\n", .{});
        self.file_ws_server.deinit();
        std.debug.print("[deinit] all servers stopped\n", .{});

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

        // Join all push threads before freeing sessions
        // (they access session.is_active which would be use-after-free)
        {
            self.push_threads_mutex.lock();
            const threads = self.push_threads.toOwnedSlice(self.allocator) catch &.{};
            self.push_threads_mutex.unlock();
            std.debug.print("[deinit] joining {d} push threads...\n", .{threads.len});
            for (threads, 0..) |t, i| {
                std.debug.print("[deinit] joining push thread {d}...\n", .{i});
                t.join();
                std.debug.print("[deinit] push thread {d} joined\n", .{i});
            }
            self.allocator.free(threads);
        }
        self.push_threads.deinit(self.allocator);
        std.debug.print("[deinit] push threads done\n", .{});

        self.auth_state.deinit();
        self.rate_limiter.deinit();
        self.transfer_manager.deinit();
        self.connection_roles.deinit();
        // Free heap-allocated session IDs in connection_jwt_info
        {
            var it = self.connection_jwt_info.valueIterator();
            while (it.next()) |v| self.allocator.free(v.session_id);
        }
        self.connection_jwt_info.deinit();
        // Free heap-allocated session IDs in connection_sessions
        {
            var it = self.connection_sessions.valueIterator();
            while (it.next()) |v| self.allocator.free(v.*);
        }
        self.connection_sessions.deinit();
        // Free heap-allocated session IDs in panel_assignments
        {
            var it = self.panel_assignments.valueIterator();
            while (it.next()) |v| self.allocator.free(v.*);
        }
        self.panel_assignments.deinit();
        self.control_client_ids.deinit();
        // Free heap-allocated keys in session_active_panels
        {
            var it = self.session_active_panels.keyIterator();
            while (it.next()) |k| self.allocator.free(k.*);
        }
        self.session_active_panels.deinit();
        // Free heap-allocated keys in session_viewports
        {
            var it = self.session_viewports.keyIterator();
            while (it.next()) |k| self.allocator.free(k.*);
        }
        self.session_viewports.deinit();
        if (self.selection_clipboard) |clip| self.allocator.free(clip);
        if (self.standard_clipboard) |clip| self.allocator.free(clip);
        if (self.initial_cwd_allocated) self.allocator.free(@constCast(self.initial_cwd));
        // Shut down tmux Unix socket listener
        if (self.tmux_sock_fd) |fd| {
            std.posix.shutdown(fd, .both) catch {};
            std.posix.close(fd);
        }
        if (self.tmux_sock_thread) |t| t.join();
        // Clean up tmux shim temp directory (includes socket file)
        {
            // Remove the parent dir (e.g. /tmp/termweb-{pid}/) not just the bin/ subdir
            const parent_dir = std.fs.path.dirname(self.tmux_shim_dir) orelse self.tmux_shim_dir;
            std.fs.cwd().deleteTree(parent_dir) catch {};
            self.allocator.free(self.tmux_shim_dir);
            self.allocator.free(self.tmux_sock_path);
        }
        self.tmux_api_response_ch.deinit();
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
        if (self.config_json) |json| self.allocator.free(json);
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

        // Check auth — deny remote connections without valid token
        const role = self.getConnectionRole(conn);
        if (role == .none) {
            // Send auth state so client knows it's denied, then close
            self.sendAuthState(conn);
            conn.sendClose() catch {};
            return;
        }

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
            if (auth.extractTokenFromQuery(uri)) |raw_token| {
                var token_buf: [256]u8 = undefined;
                const token = auth.decodeToken(&token_buf, raw_token);
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

        // Initialize per-session active panel if this session is new
        {
            self.mutex.lock();
            if (self.connection_sessions.get(conn)) |session_id| {
                if (self.session_active_panels.get(session_id) == null) {
                    // Default to first panel in first tab
                    if (self.layout.tabs.items.len > 0) {
                        var pid_buf: [1]u32 = undefined;
                        const count = self.layout.tabs.items[0].collectPanelIdsInto(&pid_buf);
                        if (count > 0) {
                            self.putSessionActivePanel(session_id, pid_buf[0]);
                        }
                    }
                }
            }
            self.mutex.unlock();
        }

        // Send current panel assignments to newly connected client
        self.sendAllPanelAssignments(conn);

        // Send current cursor state for all panels so cursor appears immediately
        self.sendCursorStateToConn(conn);

        // Send client list to admin(s)
        self.sendClientListToAdmins();

        // Send session list to admin on connect so admin UI has data immediately
        if (role == .admin) {
            self.sendSessionList(conn);
        }

        // If new main elected, broadcast so existing clients update
        if (is_new_main) {
            self.broadcastMainClientState();
        }
    }

    fn onControlMessage(conn: *ws.Connection, data: []u8, is_binary: bool) void {
        _ = is_binary;
        const self = global_server.load(.acquire) orelse return;
        if (data.len == 0) return;

        if (comptime enable_benchmark) {
            _ = self.bw_control_bytes_recv.fetchAdd(data.len, .monotonic);
        }

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

        // Remove JWT renewal tracking (mutex already held)
        self.untrackJwtInfo(conn);

        // Remove cached session for this connection and clean up per-session state
        if (self.connection_sessions.fetchRemove(conn)) |entry| {
            const disconnected_session_id = entry.value;

            // Check if any other connection shares this session_id
            var still_connected = false;
            var sit = self.connection_sessions.valueIterator();
            while (sit.next()) |other_sid| {
                if (std.mem.eql(u8, other_sid.*, disconnected_session_id)) {
                    still_connected = true;
                    break;
                }
            }

            // Clean up per-session state if this was the last connection for the session
            if (!still_connected) {
                if (self.session_active_panels.fetchRemove(disconnected_session_id)) |kv| {
                    self.allocator.free(kv.key);
                }
                if (self.session_viewports.fetchRemove(disconnected_session_id)) |kv| {
                    self.allocator.free(kv.key);
                }
            }

            self.allocator.free(disconnected_session_id);
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

        // Auth check — deny unauthenticated remote connections
        const role = self.getConnectionRole(conn);
        if (role == .none) {
            conn.sendClose() catch {};
            return;
        }

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

        // Signal the transfer session to stop, but do NOT free it here.
        // The push thread (pushDownloadFiles/Serial) holds a direct pointer and
        // will clean up via defer when it notices is_active=false or send fails.
        // For uploads (no push thread), removeSession is safe since nothing else
        // references the session after disconnect.
        self.mutex.lock();
        if (conn.user_data) |user_data| {
            const session: *transfer.TransferSession = @ptrCast(@alignCast(user_data));
            const session_id = session.id;
            @atomicStore(bool, &session.is_active, false, .release);
            conn.user_data = null;

            if (session.direction == .upload) {
                // Upload: no push thread, safe to remove immediately
                self.mutex.unlock();
                self.transfer_manager.removeSession(session_id);
            } else {
                // Download: push thread will clean up — don't free here
                self.mutex.unlock();
            }
            std.debug.print("File WS disconnected — session {d} signaled to stop\n", .{session_id});
        } else {
            self.mutex.unlock();
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

        // Auth check — deny unauthenticated remote connections
        const role = self.getConnectionRole(conn);
        if (role == .none) {
            conn.sendClose() catch {};
            return;
        }

        // Resolve token → session_id and cache (same as onControlConnect)
        if (conn.request_uri) |uri| {
            if (auth.extractTokenFromQuery(uri)) |raw_token| {
                var token_buf: [256]u8 = undefined;
                const token = auth.decodeToken(&token_buf, raw_token);
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

        // Clean up role and session caches
        _ = self.connection_roles.remove(conn);
        if (self.connection_sessions.fetchRemove(conn)) |entry| {
            self.allocator.free(entry.value);
        }
        self.mutex.unlock();
    }

    // Send H264 frame to authorized H264 clients with [panel_id:u32][frame_data...] prefix.
    // Non-admin connections only receive frames for panels assigned to their session.
    // Returns true if sent to at least one client, false if all sends failed.
    fn sendH264Frame(self: *Server, panel_id: u32, frame_data: []const u8) bool {
        var conns_buf: [max_broadcast_conns]*ws.Connection = undefined;
        var conns_count: usize = 0;
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            const assigned_session = self.panel_assignments.get(panel_id);
            for (self.h264_connections.items) |conn| {
                if (conns_count >= conns_buf.len) break;
                const role = self.connection_roles.get(conn) orelse .none;
                if (role == .admin) {
                    // Admins always receive all frames
                    conns_buf[conns_count] = conn;
                    conns_count += 1;
                } else if (assigned_session) |target_sid| {
                    // Non-admin: only send if connection's session matches assignment
                    if (self.connection_sessions.get(conn)) |conn_sid| {
                        if (std.mem.eql(u8, conn_sid, target_sid)) {
                            conns_buf[conns_count] = conn;
                            conns_count += 1;
                        }
                    }
                }
                // Unassigned panels: skip for non-admins (no else branch)
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
        if (comptime enable_benchmark) {
            if (any_sent) {
                _ = self.bw_h264_bytes.fetchAdd(4 + frame_data.len, .monotonic);
                _ = self.bw_h264_frames.fetchAdd(1, .monotonic);
            }
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
        // Only admins and editors can create new panels/splits
        if (inner_type == @intFromEnum(ClientMsg.create_panel)) {
            const role = self.connection_roles.get(conn) orelse .none;
            if (role != .admin and role != .editor) return;

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
            const role = self.connection_roles.get(conn) orelse .none;
            if (role != .admin and role != .editor) return;

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

        // Auth-check all panel messages (key, mouse, text, resize, etc.)
        // Non-admins can only interact with panels assigned to their session.
        {
            self.mutex.lock();
            const authorized = self.isPanelAuthorized(conn, panel_id);

            // Always record per-session viewport from resize dimensions (even if not authorized to resize)
            if (inner_type == @intFromEnum(ClientMsg.resize)) {
                if (self.connection_sessions.get(conn)) |session_id| {
                    if (inner.len >= 5) {
                        const w: u32 = std.mem.readInt(u16, inner[1..3], .little);
                        const h: u32 = std.mem.readInt(u16, inner[3..5], .little);
                        const current_scale = if (self.panels.get(panel_id)) |pp| pp.scale else 2.0;
                        self.putSessionViewport(session_id, .{
                            .width = w,
                            .height = h,
                            .scale = current_scale,
                        });
                    }
                }
            }
            self.mutex.unlock();
            if (!authorized) return;
        }

        // General panel input (key, mouse, text, resize, etc.)
        p.handleMessage(@constCast(inner));
        p.has_pending_input.store(true, .release);
        p.last_input_time.store(@truncate(std.time.nanoTimestamp()), .release);
        self.wake_signal.notify();
    }


    /// Build the 15-byte inspector state message for a panel.
    fn buildInspectorStateBuf(panel: *Panel) [15]u8 {
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
        return buf;
    }

    fn sendInspectorStateToPanel(_: *Server, panel: *Panel, conn: *ws.Connection) void {
        const buf = buildInspectorStateBuf(panel);
        conn.sendBinary(&buf) catch {};
    }

    fn broadcastInspectorStateToAll(self: *Server, panel: *Panel) void {
        const buf = buildInspectorStateBuf(panel);
        for (self.control_connections.items) |ctrl_conn| {
            ctrl_conn.sendBinary(&buf) catch {};
        }
    }

    // --- Control message handling---


    fn handleBinaryControlMessageFromClient(self: *Server, conn: *ws.Connection, data: []const u8) void {
        if (data.len < 1) return;

        switch (data[0]) {
            0x84 => return self.handleAssignPanel(conn, data),
            0x85 => return self.handleUnassignPanel(conn, data),
            0x86 => return self.handlePanelInput(conn, data),
            0x87 => return self.handlePanelMsg(conn, data),
            0x81 => { // close_panel
                if (data.len < 5) return;
                const panel_id = std.mem.readInt(u32, data[1..5], .little);
                _ = self.pending_destroys_ch.send(.{ .id = panel_id });
                self.wake_signal.notify();
            },
            0x82 => { // resize_panel
            if (data.len < 9) return;
            const panel_id = std.mem.readInt(u32, data[1..5], .little);
            const width: u32 = std.mem.readInt(u16, data[5..7], .little);
            const height: u32 = std.mem.readInt(u16, data[7..9], .little);
            // Extended: [type:u8][panel_id:u32][w:u16][h:u16][scale:f32] = 13 bytes
            var scale: f64 = 0;
            if (data.len >= 13) {
                const scale_f32: f32 = @bitCast(std.mem.readInt(u32, data[9..13], .little));
                if (scale_f32 > 0) scale = @floatCast(scale_f32);
            }

            self.mutex.lock();
            // Always record per-session viewport
            if (self.connection_sessions.get(conn)) |session_id| {
                const effective_scale = if (scale > 0) scale else blk: {
                    if (self.panels.get(panel_id)) |p| break :blk p.scale;
                    break :blk 2.0;
                };
                self.putSessionViewport(session_id, .{
                    .width = width,
                    .height = height,
                    .scale = effective_scale,
                });
            }
            // Only apply PTY resize if authorized
            const should_apply = self.isPanelAuthorized(conn, panel_id);
            self.mutex.unlock();

            if (should_apply) {
                _ = self.pending_resizes_ch.send(.{ .id = panel_id, .width = @intCast(width), .height = @intCast(height), .scale = scale });
                self.wake_signal.notify();
            }
            },
            0x83 => { // focus_panel
            if (data.len < 5) return;
            const panel_id = std.mem.readInt(u32, data[1..5], .little);
            self.mutex.lock();

            // Track per-session active panel (for input routing)
            if (self.connection_sessions.get(conn)) |session_id| {
                self.putSessionActivePanel(session_id, panel_id);
            }

            // Update global render focus hint (last-writer-wins for tab encoding priority)
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
            },
            0x88 => { // view_action
            if (data.len < 6) return;
            const panel_id = std.mem.readInt(u32, data[1..5], .little);
            const action_len = data[5];
            if (data.len < 6 + action_len) return;
            const action = data[6..][0..action_len];

            // Handle reload_config: reload ghostty config and broadcast updated keybindings
            if (std.mem.eql(u8, action, "reload_config")) {
                if (self.config) |_| {
                    const new_config = c.ghostty_config_new();
                    c.ghostty_config_load_default_files(new_config);
                    c.ghostty_config_finalize(new_config);
                    if (self.config_json) |old| self.allocator.free(old);
                    self.config_json = self.buildConfigJson(new_config) catch null;
                    self.http_server.config_json = self.config_json;
                    self.broadcastConfigUpdated();
                    // Also update the app config so terminal settings reload
                    if (self.app) |app| c.ghostty_app_update_config(app, new_config);
                    // Free old config, keep new one
                    const old_cfg = self.config.?;
                    self.config = new_config;
                    c.ghostty_config_free(old_cfg);
                }
            }

            // Handle open_config: read config file and send content to requesting client
            if (std.mem.eql(u8, action, "open_config")) {
                self.sendConfigContent(conn);
                return; // Don't pass to ghostty
            }

            // Handle save_config via view_action (alternative path)
            if (std.mem.startsWith(u8, action, "save_config:")) {
                // Content is too large for view_action; use dedicated 0x8D message instead
                return;
            }

            // Handle move_tab: reorder tabs
            if (std.mem.startsWith(u8, action, "move_tab:")) {
                const delta_str = action["move_tab:".len..];
                const delta = std.fmt.parseInt(i32, delta_str, 10) catch return;
                self.mutex.lock();
                const tab = self.layout.findTabByPanel(panel_id);
                if (tab) |t| {
                    if (self.layout.moveTab(t.id, delta)) {
                        self.mutex.unlock();
                        self.broadcastLayoutUpdate();
                    } else {
                        self.mutex.unlock();
                    }
                } else {
                    self.mutex.unlock();
                }
                return; // Handled client-side via layout update
            }

            // Handle write_screen_file / write_selection_file: capture and send to client
            if (std.mem.startsWith(u8, action, "write_screen_file:") or
                std.mem.startsWith(u8, action, "write_selection_file:"))
            {
                // Set flag so writeClipboardCallback knows to intercept the file path
                self.screen_dump_pending.store(true, .release);

                // Rewrite action to use :copy variant (ghostty writes file + sets clipboard to path)
                var rewritten_buf: [64]u8 = undefined;
                const prefix = if (std.mem.startsWith(u8, action, "write_screen_file:"))
                    "write_screen_file:copy"
                else
                    "write_selection_file:copy";
                @memcpy(rewritten_buf[0..prefix.len], prefix);

                self.mutex.lock();
                if (self.panels.get(panel_id)) |panel| {
                    self.mutex.unlock();
                    _ = c.ghostty_surface_binding_action(panel.surface, &rewritten_buf, prefix.len);
                } else {
                    self.mutex.unlock();
                    self.screen_dump_pending.store(false, .release);
                }
                return; // Don't pass original action to ghostty
            }

            self.mutex.lock();
            if (self.panels.get(panel_id)) |panel| {
                self.mutex.unlock();
                _ = c.ghostty_surface_binding_action(panel.surface, action.ptr, action.len);
            } else {
                self.mutex.unlock();
            }
            },
            0x89 => { // set_overview
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
            },
            0x8A => { // set_quick_terminal
            if (data.len < 2) return;
            self.mutex.lock();
            self.quick_terminal_open = data[1] != 0;
            self.mutex.unlock();
            self.broadcastQuickTerminalState();
            },
            0x8B => { // set_inspector
            if (data.len < 2) return;
            self.mutex.lock();
            self.inspector_open = data[1] != 0;
            self.mutex.unlock();
            self.broadcastInspectorOpenState();
            },
            0x8C => { // set_clipboard
            // [0x8C][panel_id:u32][len:u32][text...]
            if (data.len < 9) return;
            const text_len = std.mem.readInt(u32, data[5..9], .little);
            if (data.len < 9 + text_len) return;
            const text = data[9..][0..text_len];
            self.mutex.lock();
            if (self.standard_clipboard) |old| self.allocator.free(old);
            self.standard_clipboard = self.allocator.dupe(u8, text) catch null;
            self.mutex.unlock();
            },
            0x8D => { // save_config
            // [0x8D][content_len:u32_le][content...]
            if (data.len < 5) return;
            const content_len = std.mem.readInt(u32, data[1..5], .little);
            if (data.len < 5 + content_len) return;
            const content = data[5..][0..content_len];
            self.handleSaveConfig(conn, content);
            },
            else => std.log.warn("Unknown binary control message type: 0x{x:0>2}", .{data[0]}),
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
            0x93 => { // create_session: [0x93][id_len:u16][name_len:u16][role:u8][id][name]
                if (role != .admin) {
                    self.sendAuthError(conn, "Permission denied");
                    return;
                }
                if (data.len < 6) return;
                const id_len = std.mem.readInt(u16, data[1..3], .little);
                const name_len = std.mem.readInt(u16, data[3..5], .little);
                const session_role: auth.Role = std.meta.intToEnum(auth.Role, data[5]) catch return;
                if (data.len < 6 + id_len + name_len) return;
                const session_id = data[6..][0..id_len];
                const session_name = data[6 + id_len ..][0..name_len];
                self.auth_state.createSession(session_id, session_name, session_role) catch {
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
            0x95 => { // regenerate_token: [0x95][id_len:u16][id]
                if (role != .admin) {
                    self.sendAuthError(conn, "Permission denied");
                    return;
                }
                if (data.len < 3) return;
                const id_len = std.mem.readInt(u16, data[1..3], .little);
                if (data.len < 3 + id_len) return;
                const session_id = data[3..][0..id_len];
                self.auth_state.regenerateSessionToken(session_id) catch {};
                self.sendSessionList(conn);
            },
            0x96 => { // create_share_link: [0x96][role:u8]
                if (role != .admin) {
                    self.sendAuthError(conn, "Permission denied");
                    return;
                }
                if (data.len < 2) return;
                const link_role: auth.Role = std.meta.intToEnum(auth.Role, data[1]) catch return;
                _ = self.auth_state.createShareLink(link_role, null, null, null) catch {
                    self.sendAuthError(conn, "Failed to create share link");
                    return;
                };
                self.sendShareLinks(conn);
            },
            0x97 => { // revoke_share_link: [0x97][token_hex:64]
                if (role != .admin) {
                    self.sendAuthError(conn, "Permission denied");
                    return;
                }
                if (data.len < 1 + auth.token_hex_len) return;
                const token_hex = data[1..][0..auth.token_hex_len];
                self.auth_state.revokeShareLink(token_hex) catch {};
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
            0x9B => { // get_session_list
                self.sendSessionList(conn);
            },
            0x9C => { // get_share_links
                if (role != .admin) return;
                self.sendShareLinks(conn);
            },
            0x9D => { // get_oauth_config
                if (role != .admin) return;
                self.sendOAuthConfig(conn);
            },
            0x9E => { // set_oauth_config: [0x9E][provider_len:u8][provider][id_len:u16][id][secret_len:u16][secret]
                if (role != .admin) {
                    self.sendAuthError(conn, "Permission denied");
                    return;
                }
                if (data.len < 2) return;
                const prov_len = data[1];
                if (data.len < 2 + prov_len + 4) return;
                const provider_name = data[2..][0..prov_len];
                var off: usize = 2 + prov_len;
                const id_len = std.mem.readInt(u16, data[off..][0..2], .little);
                off += 2;
                if (data.len < off + id_len + 2) return;
                const client_id = data[off..][0..id_len];
                off += id_len;
                const secret_len = std.mem.readInt(u16, data[off..][0..2], .little);
                off += 2;
                if (data.len < off + secret_len) return;
                const client_secret = data[off..][0..secret_len];

                self.auth_state.setOAuthProvider(provider_name, client_id, client_secret) catch {
                    self.sendAuthError(conn, "Failed to save OAuth config");
                    return;
                };
                self.sendOAuthConfig(conn);
            },
            0x9F => { // remove_oauth_config: [0x9F][provider_len:u8][provider]
                if (role != .admin) {
                    self.sendAuthError(conn, "Permission denied");
                    return;
                }
                if (data.len < 2) return;
                const prov_len = data[1];
                if (data.len < 2 + prov_len) return;
                const provider_name = data[2..][0..prov_len];
                self.auth_state.removeOAuthProvider(provider_name) catch {};
                self.sendOAuthConfig(conn);
            },
            else => {
                std.log.warn("Unknown auth message type: 0x{x:0>2}", .{msg_type});
            },
        }
    }

    /// Check if a connection is authorized to interact with a panel.
    /// Admins always have access. Non-admins can only access panels explicitly
    /// assigned to their session. Unassigned panels are denied for non-admins.
    /// Must be called with self.mutex held.
    fn isPanelAuthorized(self: *Server, conn: *ws.Connection, panel_id: u32) bool {
        const role = self.connection_roles.get(conn) orelse .none;
        if (role == .admin) return true;
        const assigned_session = self.panel_assignments.get(panel_id) orelse return false;
        const sender_session = self.connection_sessions.get(conn) orelse return false;
        return std.mem.eql(u8, sender_session, assigned_session);
    }

    /// Record a session's viewport dimensions. Creates owned key if new entry.
    /// Must be called with self.mutex held.
    fn putSessionViewport(self: *Server, session_id: []const u8, viewport: SessionViewport) void {
        if (self.session_viewports.getPtr(session_id)) |vp_ptr| {
            vp_ptr.* = viewport;
        } else {
            const key = self.allocator.dupe(u8, session_id) catch return;
            self.session_viewports.put(key, viewport) catch {
                self.allocator.free(key);
            };
        }
    }

    /// Update per-session active panel. Creates owned key if new entry.
    /// Must be called with self.mutex held.
    fn putSessionActivePanel(self: *Server, session_id: []const u8, panel_id: u32) void {
        if (self.session_active_panels.getPtr(session_id)) |val_ptr| {
            val_ptr.* = panel_id;
        } else {
            const key = self.allocator.dupe(u8, session_id) catch return;
            self.session_active_panels.put(key, panel_id) catch {
                self.allocator.free(key);
            };
        }
    }

    /// Remove references to a destroyed panel from per-session tracking.
    /// Must be called with self.mutex held.
    fn cleanupDestroyedPanelSessions(self: *Server, panel_id: u32) void {
        var to_remove: [16][]const u8 = undefined;
        var remove_count: usize = 0;
        var it = self.session_active_panels.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == panel_id) {
                if (remove_count < to_remove.len) {
                    to_remove[remove_count] = entry.key_ptr.*;
                    remove_count += 1;
                }
            }
        }
        for (to_remove[0..remove_count]) |key| {
            if (self.session_active_panels.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
            }
        }
    }

    fn getConnectionRole(self: *Server, conn: *ws.Connection) auth.Role {
        // Check if we have a cached role for this connection
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.connection_roles.get(conn)) |role| return role;
        }

        // Get peer IP for rate limiting
        var ip_buf: [45]u8 = undefined;
        const ip = conn.getPeerIpStr(&ip_buf);

        // Check rate limit before attempting auth
        if (ip) |ip_str| {
            if (self.rate_limiter.isBlocked(ip_str)) {
                return .none;
            }
        }

        // Check token from connection URI query param (percent-decode for URL-encoded tokens)
        if (conn.request_uri) |uri| {
            if (auth.extractTokenFromQuery(uri)) |raw_token| {
                var token_buf: [256]u8 = undefined;
                const token = auth.decodeToken(&token_buf, raw_token);
                const result = self.auth_state.validateToken(token);
                if (result.role == .none) {
                    if (ip) |ip_str| self.rate_limiter.recordFailure(ip_str);
                } else {
                    if (ip) |ip_str| self.rate_limiter.recordSuccess(ip_str);

                    // Track JWT expiry for auto-renewal (thread-safe helper)
                    self.trackJwtInfo(conn, token);
                }
                self.mutex.lock();
                self.connection_roles.put(conn, result.role) catch {};
                self.mutex.unlock();
                return result.role;
            }
        }

        // No valid token = no access — record as failure
        if (ip) |ip_str| self.rate_limiter.recordFailure(ip_str);
        return .none;
    }

    /// Store JWT tracking info for a connection (thread-safe).
    /// Extracts JWT claims and stores session_id/expiry for auto-renewal.
    /// Handles overwrite by freeing the previous session_id.
    fn trackJwtInfo(self: *Server, conn: *ws.Connection, token: []const u8) void {
        if (token.len <= 10 or !std.mem.startsWith(u8, token, "eyJ")) return;
        var sid_buf: [64]u8 = undefined;
        const claims = auth.getJwtClaims(token, &sid_buf) orelse return;
        const duped_sid = self.allocator.dupe(u8, claims.session_id) catch return;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.connection_jwt_info.fetchPut(conn, .{
            .session_id = duped_sid,
            .expiry = claims.exp,
        }) catch null) |old| {
            self.allocator.free(old.value.session_id);
        }
    }

    /// Remove JWT tracking info for a connection (caller must hold self.mutex).
    fn untrackJwtInfo(self: *Server, conn: *ws.Connection) void {
        if (self.connection_jwt_info.fetchRemove(conn)) |entry| {
            self.allocator.free(entry.value.session_id);
        }
    }

    /// Check all tracked JWT connections and send renewal if expiry is within 5 minutes.
    /// Self-throttles to run at most once every 10 seconds.
    fn renewExpiredJwts(self: *Server) void {
        const now = std.time.timestamp();

        // Throttle: only check every 10 seconds
        if (now - self.last_jwt_check < 10) return;
        self.last_jwt_check = now;

        // Collect connections that need renewal under mutex
        var renew_buf: [64]*ws.Connection = undefined;
        var renew_count: usize = 0;

        self.mutex.lock();
        var it = self.connection_jwt_info.iterator();
        while (it.next()) |entry| {
            // Renew 5 minutes before expiry (jwt_expiry_secs = 900, renew at 600)
            if (now > entry.value_ptr.expiry - 300 and renew_count < renew_buf.len) {
                renew_buf[renew_count] = entry.key_ptr.*;
                renew_count += 1;
            }
        }
        self.mutex.unlock();

        // Send fresh JWTs (outside mutex — sendBinary does its own I/O)
        for (renew_buf[0..renew_count]) |conn| {
            var jwt_buf: [256]u8 = undefined;
            var session_id: []const u8 = "";

            // Read info under mutex
            self.mutex.lock();
            if (self.connection_jwt_info.getPtr(conn)) |info| {
                session_id = info.session_id;
            }
            self.mutex.unlock();

            if (session_id.len == 0) continue;

            // Look up session to get signing key
            const session = self.auth_state.getSession(session_id) orelse continue;
            const jwt = self.auth_state.createJwt(session, &jwt_buf);
            if (jwt.len > 0) {
                // Send JWT_RENEWAL message: [0x0D][jwt_len:u16_le][jwt...]
                var msg: [3 + 256]u8 = undefined;
                msg[0] = 0x0D; // JWT_RENEWAL
                std.mem.writeInt(u16, msg[1..3], @intCast(jwt.len), .little);
                @memcpy(msg[3..][0..jwt.len], jwt);
                conn.sendBinary(msg[0 .. 3 + jwt.len]) catch {};

                // Update expiry under mutex
                self.mutex.lock();
                if (self.connection_jwt_info.getPtr(conn)) |info| {
                    info.expiry = now + 900; // jwt_expiry_secs
                }
                self.mutex.unlock();
            }
        }
    }

    fn sendAuthState(self: *Server, conn: *ws.Connection) void {
        const role = self.getConnectionRole(conn);

        // Build auth state message
        // [0x0A][role:u8][auth_required:u8][has_password:u8][passkey_count:u8][github_configured:u8][google_configured:u8]
        var msg: [7]u8 = undefined;
        msg[0] = 0x0A; // auth_state
        msg[1] = @intFromEnum(role);
        msg[2] = if (self.auth_state.auth_required) 1 else 0;
        msg[3] = if (self.auth_state.admin_password_hash != null) 1 else 0;
        msg[4] = @intCast(self.auth_state.passkey_credentials.items.len);
        msg[5] = if (self.auth_state.github_oauth != null) 1 else 0;
        msg[6] = if (self.auth_state.google_oauth != null) 1 else 0;

        conn.sendBinary(&msg) catch {};
    }

    /// Send OAuth provider configuration status to admin client.
    /// [0x1A][github_configured:u8][google_configured:u8][default_role:u8]
    fn sendOAuthConfig(self: *Server, conn: *ws.Connection) void {
        const role = self.getConnectionRole(conn);
        if (role != .admin) return;

        var msg: [4]u8 = undefined;
        msg[0] = 0x1A; // oauth_config
        msg[1] = if (self.auth_state.github_oauth != null) 1 else 0;
        msg[2] = if (self.auth_state.google_oauth != null) 1 else 0;
        msg[3] = @intFromEnum(self.auth_state.oauth_default_role);

        conn.sendBinary(&msg) catch {};
    }

    fn sendSessionList(self: *Server, conn: *ws.Connection) void {
        const role = self.getConnectionRole(conn);
        if (role == .none) return;

        // Non-admins only see their own session
        const is_admin = role == .admin;
        const own_session_id: ?[]const u8 = if (!is_admin) blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            break :blk self.connection_sessions.get(conn);
        } else null;

        // Non-admin with no tracked session — nothing to return
        if (!is_admin and own_session_id == null) return;

        // Build session list message
        // [0x0B][count:u16][sessions...]
        // session: [id_len:u16][id][name_len:u16][name][token_hex:64][role:u8]
        var buf: std.ArrayListUnmanaged(u8) = .{};
        defer buf.deinit(self.allocator);

        buf.append(self.allocator, 0x0B) catch return; // session_list

        const sessions = self.auth_state.sessions;

        // Count sessions to include (admins skip the "default" internal session)
        var count: u16 = 0;
        if (is_admin) {
            var count_iter = sessions.valueIterator();
            while (count_iter.next()) |s| {
                if (!std.mem.eql(u8, s.id, "default")) count += 1;
            }
        } else if (own_session_id) |sid| {
            count = if (sessions.get(sid) != null) 1 else 0;
        }

        buf.writer(self.allocator).writeInt(u16, count, .little) catch return;

        var iter = sessions.valueIterator();
        while (iter.next()) |session| {
            // Admins: skip the "default" internal session (it's the admin's own, not a share)
            if (is_admin and std.mem.eql(u8, session.id, "default")) continue;
            // Non-admins: only include their own session
            if (own_session_id) |sid| {
                if (!std.mem.eql(u8, session.id, sid)) continue;
            }

            buf.writer(self.allocator).writeInt(u16, @intCast(session.id.len), .little) catch return;
            buf.appendSlice(self.allocator, session.id) catch return;
            buf.writer(self.allocator).writeInt(u16, @intCast(session.name.len), .little) catch return;
            buf.appendSlice(self.allocator, session.name) catch return;
            // Token as hex (64 chars)
            var hex_buf: [auth.token_hex_len]u8 = undefined;
            auth.hexEncodeToken(&hex_buf, &session.token);
            buf.appendSlice(self.allocator, &hex_buf) catch return;
            // Role as u8
            buf.append(self.allocator, @intFromEnum(session.role)) catch return;
        }

        conn.sendBinary(buf.items) catch {};
    }

    fn sendShareLinks(self: *Server, conn: *ws.Connection) void {
        const role = self.getConnectionRole(conn);
        if (role != .admin) return;

        // Build share links message
        // [0x0C][count:u16][links...]
        // link: [token_hex:64][role:u8][use_count:u32][valid:u8]
        var buf: std.ArrayListUnmanaged(u8) = .{};
        defer buf.deinit(self.allocator);

        buf.append(self.allocator, 0x0C) catch return; // share_links
        buf.writer(self.allocator).writeInt(u16, @intCast(self.auth_state.share_links.items.len), .little) catch return;

        for (self.auth_state.share_links.items) |link| {
            var hex_buf: [auth.token_hex_len]u8 = undefined;
            auth.hexEncodeToken(&hex_buf, &link.token);
            buf.appendSlice(self.allocator, &hex_buf) catch return;
            buf.append(self.allocator, @intFromEnum(link.role)) catch return;
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


    /// Get the ghostty config file path.
    fn getConfigPath(buf: *[512]u8) ?[]const u8 {
        if (std.posix.getenv("XDG_CONFIG_HOME")) |xdg| {
            return std.fmt.bufPrint(buf, "{s}/ghostty/config", .{xdg}) catch null;
        }
        const home = std.posix.getenv("HOME") orelse return null;
        return std.fmt.bufPrint(buf, "{s}/.config/ghostty/config", .{home}) catch null;
    }

    /// Read the ghostty config file and send its content to a single connection.
    fn sendConfigContent(self: *Server, conn: *ws.Connection) void {
        var path_buf: [512]u8 = undefined;
        const config_path = getConfigPath(&path_buf) orelse return;

        // Read config file
        const file = std.fs.openFileAbsolute(config_path, .{}) catch |err| {
            // File doesn't exist yet — send empty content so client can create it
            if (err == error.FileNotFound) {
                self.sendConfigContentMsg(conn, config_path, "");
                return;
            }
            std.log.warn("Failed to open config file: {}", .{err});
            return;
        };
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 1024 * 1024) catch |err| {
            std.log.warn("Failed to read config file: {}", .{err});
            return;
        };
        defer self.allocator.free(content);

        self.sendConfigContentMsg(conn, config_path, content);
    }

    /// Build and send config_content message to a single connection.
    fn sendConfigContentMsg(self: *Server, conn: *ws.Connection, path: []const u8, content: []const u8) void {
        // [0x20][path_len:u16_le][path...][content_len:u32_le][content...]
        const msg_len = 1 + 2 + path.len + 4 + content.len;
        const msg = self.allocator.alloc(u8, msg_len) catch return;
        defer self.allocator.free(msg);
        msg[0] = @intFromEnum(BinaryCtrlMsg.config_content);
        std.mem.writeInt(u16, msg[1..3], @intCast(path.len), .little);
        @memcpy(msg[3..][0..path.len], path);
        const content_offset = 3 + path.len;
        std.mem.writeInt(u32, msg[content_offset..][0..4], @intCast(content.len), .little);
        @memcpy(msg[content_offset + 4 ..][0..content.len], content);
        conn.sendBinary(msg) catch {};
    }

    /// Handle save_config: write content to config file and trigger reload.
    fn handleSaveConfig(self: *Server, conn: *ws.Connection, content: []const u8) void {
        _ = conn;
        var path_buf: [512]u8 = undefined;
        const config_path = getConfigPath(&path_buf) orelse return;

        // Ensure parent directory exists
        if (std.fs.path.dirname(config_path)) |dir| {
            std.fs.makeDirAbsolute(dir) catch |err| {
                if (err != error.PathAlreadyExists) {
                    std.log.warn("Failed to create config dir: {}", .{err});
                    return;
                }
            };
        }

        // Write config file
        const file = std.fs.createFileAbsolute(config_path, .{}) catch |err| {
            std.log.warn("Failed to create config file: {}", .{err});
            return;
        };
        defer file.close();
        file.writeAll(content) catch |err| {
            std.log.warn("Failed to write config file: {}", .{err});
            return;
        };

        // Trigger config reload (same as reload_config view action)
        if (self.config) |_| {
            const new_config = c.ghostty_config_new();
            c.ghostty_config_load_default_files(new_config);
            c.ghostty_config_finalize(new_config);
            if (self.config_json) |old| self.allocator.free(old);
            self.config_json = self.buildConfigJson(new_config) catch null;
            self.http_server.config_json = self.config_json;
            self.broadcastConfigUpdated();
            if (self.app) |app| c.ghostty_app_update_config(app, new_config);
            const old_cfg = self.config.?;
            self.config = new_config;
            c.ghostty_config_free(old_cfg);
        }
    }

    // Binary control message handler
    // 0x10 = file_upload, 0x11 = file_download, 0x14 = folder_download (zip)
    // 0x81-0x8D = client control messages (close, resize, focus, split, config, etc.)
    fn handleBinaryControlMessage(self: *Server, conn: *ws.Connection, data: []const u8) void {
        if (data.len < 1) return;

        const msg_type = data[0];
        switch (msg_type) {
            // Client control messages
            0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8A, 0x8B, 0x8C, 0x8D => {
                self.handleBinaryControlMessageFromClient(conn, data);
            },
            else => std.log.warn("Unknown binary control message type: 0x{x:0>2}", .{msg_type}),
        }
    }

    /// Max connections for stack-based snapshot (avoids heap allocation during broadcast).
    const max_broadcast_conns = 16;

    /// Build 18-byte cursor state message in surface-space coordinates.
    /// [type:u8][panel_id:u32][x:u16][y:u16][w:u16][h:u16][style:u8][visible:u8][r:u8][g:u8][b:u8]
    fn buildCursorBuf(panel_id: u32, x: u16, y: u16, w: u16, h: u16, style: u8, visible: u8, r: u8, g: u8, b: u8) [18]u8 {
        var buf: [18]u8 = undefined;
        buf[0] = @intFromEnum(BinaryCtrlMsg.cursor_state);
        std.mem.writeInt(u32, buf[1..5], panel_id, .little);
        std.mem.writeInt(u16, buf[5..7], x, .little);
        std.mem.writeInt(u16, buf[7..9], y, .little);
        std.mem.writeInt(u16, buf[9..11], w, .little);
        std.mem.writeInt(u16, buf[11..13], h, .little);
        buf[13] = style;
        buf[14] = visible;
        buf[15] = r;
        buf[16] = g;
        buf[17] = b;
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

    /// Compute cursor pixel coordinates from grid position and surface metrics.
    /// Y offset +2 accounts for visual baseline alignment with text.
    const CursorPixelCoords = struct { x: u16, y: u16, w: u16, h: u16, surf_w: u16, surf_h: u16, cell_w: u16, cell_h: u16 };
    fn computeCursorPixelCoords(surface: ?*anyopaque, col: u16, row: u16) CursorPixelCoords {
        const size = c.ghostty_surface_size(surface);
        const cell_w: u16 = @intCast(size.cell_width_px);
        const cell_h: u16 = @intCast(size.cell_height_px);
        const padding_x: u16 = @intCast(size.padding_left_px);
        const padding_y: u16 = @intCast(size.padding_top_px);
        return .{
            .x = padding_x + col * cell_w,
            .y = padding_y + row * cell_h + 2,
            .w = cell_w -| 1,
            .h = cell_h -| 2,
            .surf_w = @intCast(size.width_px),
            .surf_h = @intCast(size.height_px),
            .cell_w = cell_w,
            .cell_h = cell_h,
        };
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
            const cp = computeCursorPixelCoords(panel.surface, panel.last_cursor_col, panel.last_cursor_row);

            const dims_buf = buildSurfaceDimsBuf(panel.id, cp.surf_w, cp.surf_h);
            conn.sendBinary(&dims_buf) catch {};

            const cursor_buf = buildCursorBuf(panel.id, cp.x, cp.y, cp.w, cp.h, panel.last_cursor_style, panel.last_cursor_visible, panel.last_cursor_color_r, panel.last_cursor_color_g, panel.last_cursor_color_b);
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

    /// Broadcast binary data to all control connections, tracking bytes when benchmark is enabled.
    fn broadcastControlData(self: *Server, data: []const u8) void {
        var conn_buf: [max_broadcast_conns]*ws.Connection = undefined;
        const conns = self.snapshotControlConns(&conn_buf);
        if (comptime enable_benchmark) {
            var sent: u64 = 0;
            for (conns) |ctrl_conn| {
                ctrl_conn.sendBinary(data) catch continue;
                sent += data.len;
            }
            if (sent > 0) _ = self.bw_control_bytes_sent.fetchAdd(sent, .monotonic);
        } else {
            for (conns) |ctrl_conn| {
                ctrl_conn.sendBinary(data) catch {};
            }
        }
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

        const layout_json = self.layout.toJson(self.allocator) catch return;
        defer self.allocator.free(layout_json);

        // Binary: [type:u8][count:u8][panel_id:u32, title_len:u8, title...]*[layout_len:u16][layout_json]
        // Upper bound: each panel ≤ 260 bytes (4 + 1 + 255)
        const panel_count = self.panels.count();
        const layout_len: u16 = @intCast(@min(layout_json.len, 65535));
        const msg_buf = self.allocator.alloc(u8, 2 + panel_count * 260 + 2 + layout_len) catch return;
        defer self.allocator.free(msg_buf);

        msg_buf[0] = @intFromEnum(BinaryCtrlMsg.panel_list);
        msg_buf[1] = @intCast(@min(panel_count, 255));

        // Single pass: write panel data and send pwd messages
        var offset: usize = 2;
        var it = self.panels.iterator();
        while (it.next()) |entry| {
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

        conn.sendBinary(msg_buf[0..offset + layout_len]) catch {};

        // Send pwd for each panel separately (pwd messages use their own format)
        var it2 = self.panels.iterator();
        while (it2.next()) |entry| {
            const panel = entry.value_ptr.*;
            if (panel.pwd.len > 0) {
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

    /// Broadcast a [type:u8][panel_id:u32] message (5 bytes).
    fn broadcastPanelMsg(self: *Server, msg_type: BinaryCtrlMsg, panel_id: u32) void {
        var buf: [5]u8 = undefined;
        buf[0] = @intFromEnum(msg_type);
        std.mem.writeInt(u32, buf[1..5], panel_id, .little);
        self.broadcastControlData(&buf);
    }

    fn broadcastPanelTitle(self: *Server, panel_id: u32, title: []const u8) void {
        const title_len: u8 = @intCast(@min(title.len, 255));
        var buf: [262]u8 = undefined;
        buf[0] = @intFromEnum(BinaryCtrlMsg.panel_title);
        std.mem.writeInt(u32, buf[1..5], panel_id, .little);
        buf[5] = title_len;
        @memcpy(buf[6..][0..title_len], title[0..title_len]);

        self.mutex.lock();
        if (self.panels.get(panel_id)) |panel| {
            if (panel.title.len > 0) self.allocator.free(panel.title);
            panel.title = self.allocator.dupe(u8, title) catch &.{};
        }
        self.mutex.unlock();

        self.broadcastControlData(buf[0 .. 6 + title_len]);
    }

    fn broadcastPanelPwd(self: *Server, panel_id: u32, pwd: []const u8) void {
        const pwd_len: u16 = @intCast(@min(pwd.len, 1024));
        var buf: [1031]u8 = undefined;
        buf[0] = @intFromEnum(BinaryCtrlMsg.panel_pwd);
        std.mem.writeInt(u32, buf[1..5], panel_id, .little);
        std.mem.writeInt(u16, buf[5..7], pwd_len, .little);
        @memcpy(buf[7..][0..pwd_len], pwd[0..pwd_len]);

        self.mutex.lock();
        if (self.panels.get(panel_id)) |panel| {
            if (panel.pwd.len > 0) self.allocator.free(panel.pwd);
            panel.pwd = self.allocator.dupe(u8, pwd) catch &.{};
        }
        self.mutex.unlock();

        self.broadcastControlData(buf[0 .. 7 + pwd_len]);
    }

    fn broadcastPanelNotification(self: *Server, panel_id: u32, title: []const u8, body: []const u8) void {
        const title_len: u8 = @intCast(@min(title.len, 255));
        const body_len: u16 = @intCast(@min(body.len, 1024));
        const total_len: usize = 1 + 4 + 1 + title_len + 2 + body_len;
        var buf: [1287]u8 = undefined;
        buf[0] = @intFromEnum(BinaryCtrlMsg.panel_notification);
        std.mem.writeInt(u32, buf[1..5], panel_id, .little);
        buf[5] = title_len;
        @memcpy(buf[6..][0..title_len], title[0..title_len]);
        std.mem.writeInt(u16, buf[6 + title_len ..][0..2], body_len, .little);
        @memcpy(buf[8 + title_len ..][0..body_len], body[0..body_len]);

        self.broadcastControlData(buf[0..total_len]);
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
        const layout_len: u16 = @intCast(@min(layout_json.len, 65535));
        const msg_buf = self.allocator.alloc(u8, 3 + layout_len) catch return;
        defer self.allocator.free(msg_buf);

        msg_buf[0] = @intFromEnum(BinaryCtrlMsg.layout_update);
        std.mem.writeInt(u16, msg_buf[1..3], layout_len, .little);
        @memcpy(msg_buf[3..][0..layout_len], layout_json[0..layout_len]);

        if (comptime enable_benchmark) {
            var sent: u64 = 0;
            for (conn_buf[0..count]) |conn| {
                conn.sendBinary(msg_buf) catch continue;
                sent += msg_buf.len;
            }
            if (sent > 0) _ = self.bw_control_bytes_sent.fetchAdd(sent, .monotonic);
        } else {
            for (conn_buf[0..count]) |conn| {
                conn.sendBinary(msg_buf) catch {};
            }
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

    /// Broadcast a [type:u8][bool:u8] message to all control connections.
    fn broadcastBoolState(self: *Server, msg_type: BinaryCtrlMsg, value: bool) void {
        const buf = [2]u8{ @intFromEnum(msg_type), @intFromBool(value) };
        self.broadcastControlData(&buf);
    }

    /// Send a [type:u8][bool:u8] message to a single connection.
    fn sendBoolState(_: *Server, msg_type: BinaryCtrlMsg, value: bool, conn: *ws.Connection) void {
        const buf = [2]u8{ @intFromEnum(msg_type), @intFromBool(value) };
        conn.sendBinary(&buf) catch {};
    }

    fn broadcastOverviewState(self: *Server) void {
        self.broadcastBoolState(.overview_state, self.overview_open);
    }

    fn sendOverviewState(self: *Server, conn: *ws.Connection) void {
        self.mutex.lock();
        const open = self.overview_open;
        self.mutex.unlock();
        self.sendBoolState(.overview_state, open, conn);
    }

    fn broadcastQuickTerminalState(self: *Server) void {
        self.broadcastBoolState(.quick_terminal_state, self.quick_terminal_open);
    }

    fn sendQuickTerminalState(self: *Server, conn: *ws.Connection) void {
        self.mutex.lock();
        const open = self.quick_terminal_open;
        self.mutex.unlock();
        self.sendBoolState(.quick_terminal_state, open, conn);
    }

    fn broadcastInspectorOpenState(self: *Server) void {
        self.broadcastBoolState(.inspector_state_open, self.inspector_open);
    }

    fn sendInspectorOpenState(self: *Server, conn: *ws.Connection) void {
        self.mutex.lock();
        const open = self.inspector_open;
        self.mutex.unlock();
        self.sendBoolState(.inspector_state_open, open, conn);
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

    /// Read a screen dump temp file and broadcast its content to all clients.
    /// Called from writeClipboardCallback when screen_dump_pending is set.
    fn handleScreenDumpFile(self: *Server, file_path: []const u8) void {
        // Read the temp file content
        const file_content = std.fs.cwd().readFileAlloc(self.allocator, file_path, 4 * 1024 * 1024) catch |err| {
            std.debug.print("Failed to read screen dump file '{s}': {}\n", .{ file_path, err });
            return;
        };
        defer self.allocator.free(file_content);

        // Extract filename from path (e.g., "/tmp/ghostty-abc/screen.txt" → "screen.txt")
        const filename = if (std.mem.lastIndexOfScalar(u8, file_path, '/')) |idx|
            file_path[idx + 1 ..]
        else
            file_path;

        self.broadcastScreenDump(filename, file_content);

        // Clean up: delete the temp file and try to remove the temp directory
        std.fs.cwd().deleteFile(file_path) catch {};
        if (std.mem.lastIndexOfScalar(u8, file_path, '/')) |idx| {
            std.fs.cwd().deleteDir(file_path[0..idx]) catch {};
        }
    }

    /// Broadcast screen/selection content to all clients for browser download.
    /// Format: [type:u8][filename_len:u8][filename...][content_len:u32_le][content...]
    fn broadcastScreenDump(self: *Server, filename: []const u8, content: []const u8) void {
        const fname_len: u8 = @intCast(@min(filename.len, 255));
        const content_len: u32 = @intCast(@min(content.len, 4 * 1024 * 1024));
        const total_len = 1 + 1 + fname_len + 4 + content_len;

        const msg_buf = self.allocator.alloc(u8, total_len) catch return;
        defer self.allocator.free(msg_buf);

        msg_buf[0] = @intFromEnum(BinaryCtrlMsg.screen_dump);
        msg_buf[1] = fname_len;
        @memcpy(msg_buf[2..][0..fname_len], filename[0..fname_len]);
        std.mem.writeInt(u32, msg_buf[2 + fname_len ..][0..4], content_len, .little);
        @memcpy(msg_buf[6 + fname_len ..][0..content_len], content[0..content_len]);

        var conn_buf: [max_broadcast_conns]*ws.Connection = undefined;
        const conns = self.snapshotControlConns(&conn_buf);
        for (conns) |conn| {
            conn.sendBinary(msg_buf) catch {};
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

        self.broadcastControlData(buf[0 .. 6 + sid_len]);
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
            // Use cached role directly — mutex is already held, calling getConnectionRole would deadlock
            const crole = self.connection_roles.get(ctrl_conn) orelse .none;
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
            // Use cached role directly — mutex is already held
            const crole = self.connection_roles.get(ctrl_conn) orelse .none;
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
            @intFromEnum(transfer.ClientMsgType.upload_file_list) => self.handleUploadFileList(conn, data),
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

        // For downloads, build file list and send (threaded to avoid blocking WS receive loop)
        if (init_data.direction == .download) {
            const build_thread = std.Thread.spawn(.{}, buildFileListAndSendThread, .{ self, conn, session, init_data.flags.dry_run }) catch |err| {
                std.debug.print("Failed to spawn buildFileList thread: {}\n", .{err});
                const error_msg = transfer.buildTransferError(self.allocator, session.id, "Failed to start transfer") catch return;
                defer self.allocator.free(error_msg);
                conn.sendBinary(error_msg) catch {};
                return;
            };
            self.trackPushThread(build_thread);
        }
    }

    // Handle FILE_LIST_REQUEST message
    fn handleFileListRequest(self: *Server, conn: *ws.Connection, data: []u8) void {
        if (data.len < 5) return;

        const transfer_id = std.mem.readInt(u32, data[1..5], .little);
        const session = self.transfer_manager.getSession(transfer_id) orelse return;

        // Build file list in thread to avoid blocking (upload file list can be large)
        const build_thread = std.Thread.spawn(.{}, buildFileListForUploadThread, .{ self, conn, session }) catch |err| {
            std.debug.print("Failed to spawn buildFileList thread for upload: {}\n", .{err});
            return;
        };
        build_thread.detach();
    }

    /// Thread wrapper for upload file list building
    fn buildFileListForUploadThread(self: *Server, conn: *ws.Connection, session: *transfer.TransferSession) void {
        session.buildFileListAsync() catch |err| {
            std.debug.print("Failed to build file list for upload: {}\n", .{err});
            const error_msg = transfer.buildTransferError(self.allocator, session.id, "Failed to read directory") catch return;
            defer self.allocator.free(error_msg);
            conn.sendBinary(error_msg) catch {};
            return;
        };

        const list_msg = transfer.buildFileList(self.allocator, session) catch return;
        defer self.allocator.free(list_msg);
        conn.sendBinary(list_msg) catch {};
    }

    /// Handle UPLOAD_FILE_LIST — client sends its file list before uploading data.
    /// Populates session.files so handleFileData can map file_index to paths.
    fn handleUploadFileList(self: *Server, _: *ws.Connection, data: []u8) void {
        const parsed = transfer.parseUploadFileList(self.allocator, data) catch |err| {
            std.debug.print("Failed to parse UPLOAD_FILE_LIST: {}\n", .{err});
            return;
        };

        const session = self.transfer_manager.getSession(parsed.transfer_id) orelse {
            // No session — free the parsed files
            for (parsed.files) |*f| {
                var entry = f.*;
                entry.deinit(self.allocator);
            }
            self.allocator.free(parsed.files);
            return;
        };

        // Load gitignore patterns from the target directory if requested
        if (session.flags.use_gitignore) session.loadGitignore();

        // Populate session file list from client data
        session.files.clearAndFree(self.allocator);
        for (parsed.files) |entry| {
            session.files.append(self.allocator, entry) catch {};
        }
        self.allocator.free(parsed.files);
        session.total_bytes = parsed.total_bytes;
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

        // Skip excluded files (gitignore, manual excludes) — still ACK so client continues
        const excluded = file_entry.is_dir or session.isExcluded(file_entry.path) or blk: {
            // Check each directory component (so "node_modules" excludes "pkg/node_modules/file.js")
            var iter = std.mem.splitScalar(u8, file_entry.path, '/');
            while (iter.next()) |segment| {
                if (iter.peek() == null) break; // skip filename (last segment)
                if (session.isExcluded(segment)) break :blk true;
            }
            break :blk false;
        };
        if (excluded) {
            session.bytes_transferred += file_data.uncompressed_size;
            const ack_msg = transfer.buildFileAck(self.allocator, file_data.transfer_id, file_data.file_index, session.bytes_transferred) catch return;
            defer self.allocator.free(ack_msg);
            conn.sendBinary(ack_msg) catch {};
            return;
        }

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
        // Parse TRANSFER_RESUME message with completed files list
        var resume_data = transfer.parseTransferResume(self.allocator, data) catch |err| {
            std.debug.print("Failed to parse TRANSFER_RESUME: {}\n", .{err});
            return;
        };
        defer resume_data.deinit(self.allocator);

        const use_gitignore = (resume_data.flags & 0x02) != 0;
        std.debug.print("Resuming download {d} for path: {s}, {d} completed files, use_gitignore={}\n", .{ resume_data.transfer_id, resume_data.path, resume_data.completed_files.len, use_gitignore });

        // Resolve path
        const resolved_path = self.resolvePath(resume_data.path);
        defer if (resolved_path.ptr != self.initial_cwd.ptr) self.allocator.free(@constCast(resolved_path));

        // Create transfer session with restored options from client
        const session = self.transfer_manager.createSessionWithId(resume_data.transfer_id, .download, .{
            .dry_run = false,
            .use_gitignore = use_gitignore,
        }, resolved_path) catch |err| {
            std.debug.print("Failed to create resume session: {}\n", .{err});
            return;
        };

        // Add exclude patterns from resume data
        for (resume_data.excludes) |pattern| {
            session.addExcludePattern(pattern) catch {};
        }

        conn.user_data = session;

        // Track whether push thread takes over cleanup
        var push_spawned = false;
        defer if (!push_spawned) {
            self.mutex.lock();
            conn.user_data = null;
            self.mutex.unlock();
            self.transfer_manager.removeSession(session.id);
        };

        // Build file list
        session.buildFileListAsync() catch |err| {
            std.debug.print("Failed to build file list for resume: {}\n", .{err});
            const error_msg = transfer.buildTransferError(self.allocator, session.id, "Path not found or not accessible") catch return;
            defer self.allocator.free(error_msg);
            conn.sendBinary(error_msg) catch {};
            return;
        };

        // Filter out completed files - collect remaining into new list
        const total_files = session.files.items.len;
        var write_idx: usize = 0;
        for (session.files.items) |*file_entry| {
            var is_completed = false;
            for (resume_data.completed_files) |completed_path| {
                if (std.mem.eql(u8, file_entry.path, completed_path)) {
                    is_completed = true;
                    break;
                }
            }
            if (!is_completed) {
                session.files.items[write_idx] = file_entry.*;
                write_idx += 1;
            } else {
                // Free the path of completed entries being removed
                file_entry.deinit(self.allocator);
            }
        }

        // Trim session.files to only remaining files
        session.files.shrinkRetainingCapacity(write_idx);

        std.debug.print("Resume: {d} total files, {d} remaining\n", .{ total_files, write_idx });

        // Send TRANSFER_READY
        const ready_msg = transfer.buildTransferReady(self.allocator, session.id) catch return;
        defer self.allocator.free(ready_msg);
        conn.sendBinary(ready_msg) catch {};

        // Send FILE_LIST with remaining files
        const list_msg = transfer.buildFileList(self.allocator, session) catch return;
        defer self.allocator.free(list_msg);
        conn.sendBinary(list_msg) catch {};

        // Start pushing remaining files in a separate thread (it takes over session cleanup)
        std.debug.print("Resumed download {d}, pushing {d} remaining files\n", .{ session.id, session.files.items.len });
        const push_thread = std.Thread.spawn(.{}, pushDownloadFilesThread, .{ self, conn, session }) catch |err| {
            std.debug.print("Failed to spawn pushDownloadFiles thread for resume: {}\n", .{err});
            return;
        };
        push_spawned = true;
        self.trackPushThread(push_thread);
    }

    // Handle TRANSFER_CANCEL message
    fn handleTransferCancel(self: *Server, conn: *ws.Connection, data: []u8) void {
        if (data.len < 5) return;

        const transfer_id = std.mem.readInt(u32, data[1..5], .little);

        if (self.transfer_manager.getSession(transfer_id)) |session| {
            // Signal goroutines/push thread to stop
            @atomicStore(bool, &session.is_active, false, .release);

            if (session.direction == .upload) {
                // Upload: no push thread, safe to remove immediately
                self.transfer_manager.removeSession(transfer_id);
            }
            // Download: push thread's defer handles removeSession
        }
        conn.user_data = null;

        std.debug.print("Transfer {d} cancelled by client\n", .{transfer_id});
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
        base_path: []const u8, // Owned copy of base path (must be absolute)
        is_active: *bool, // Pointer to session.is_active
        send_ch: *gchannel.GChannel(transfer.CompressedMsg),
        done_counter: *std.atomic.Value(usize), // Decremented when goroutine finishes
        token_ch: *gchannel.GChannel(u8), // Goroutine-safe semaphore (recv=acquire, send=release)

        fn deinit(self: *FileGoroutineCtx) void {
            self.allocator.free(self.file_path);
            self.allocator.free(self.base_path);
            self.allocator.destroy(self);
        }
    };

    /// Goroutine entry point: reads a file, compresses it, sends result to channel.
    /// Must use .c calling convention because the goroutine trampoline passes
    /// arg via rdi (x86_64) / x0 (aarch64) using the C ABI.
    fn processFileGoroutine(arg: *anyopaque) callconv(.c) void {
        const ctx: *FileGoroutineCtx = @ptrCast(@alignCast(arg));
        const done_counter = ctx.done_counter;
        const token_ch = ctx.token_ch;
        defer _ = done_counter.fetchAdd(1, .release);

        // Early exit before acquiring token — cancelled goroutines skip entirely
        // so new transfers aren't starved by queued goroutines.
        if (!@atomicLoad(bool, ctx.is_active, .acquire)) {
            ctx.deinit();
            return;
        }

        // Acquire token to limit concurrent large file processing (prevents OOM).
        // Uses GChannel which parks the goroutine instead of blocking the OS thread.
        _ = token_ch.recv() orelse {
            ctx.deinit();
            return;
        };
        defer _ = token_ch.send(0);
        defer ctx.deinit();

        if (!@atomicLoad(bool, ctx.is_active, .acquire)) return;

        const data = readFileForGoroutine(ctx.allocator, ctx.base_path, ctx.file_path, ctx.file_size) orelse return;
        defer ctx.allocator.free(data);

        if (!@atomicLoad(bool, ctx.is_active, .acquire)) return;

        const chunks = transfer.ParallelCompressor.compressChunksParallel(
            ctx.allocator,
            data,
            3,
        ) catch return;

        if (!ctx.send_ch.send(.{
            .file_index = ctx.file_index,
            .file_size = ctx.file_size,
            .chunks = chunks,
        })) {
            transfer.ParallelCompressor.freeChunks(ctx.allocator, chunks);
        }
    }

    /// Read a file using pread. Safe to call from any goroutine/thread.
    fn readFileForGoroutine(allocator: std.mem.Allocator, base_path: []const u8, rel_path: []const u8, size: u64) ?[]u8 {
        // Validate base_path is absolute to prevent panic in openDirAbsolute
        if (!std.fs.path.isAbsolute(base_path)) {
            std.debug.print("[Goroutine] ERROR: base_path is not absolute: '{s}'\n", .{base_path});
            return null;
        }

        // Skip files that are too large to prevent OOM
        if (size > transfer.max_file_size) {
            std.debug.print("[Goroutine] SKIPPED: file too large ({d} MB > {d} MB limit): {s}\n", .{
                size / (1024 * 1024),
                transfer.max_file_size / (1024 * 1024),
                rel_path,
            });
            return null;
        }

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

    /// Track a push thread handle for joining during shutdown.
    fn trackPushThread(self: *Server, thread: std.Thread) void {
        self.push_threads_mutex.lock();
        defer self.push_threads_mutex.unlock();
        self.push_threads.append(self.allocator, thread) catch {
            // If allocation fails, detach as fallback (won't crash, just unclean exit)
            thread.detach();
        };
    }

    /// Thread wrapper for pushDownloadFiles — spawned to avoid blocking the WebSocket receive loop
    fn pushDownloadFilesThread(self: *Server, conn: *ws.Connection, session: *transfer.TransferSession) void {
        self.pushDownloadFiles(conn, session);
    }

    /// Thread wrapper for buildFileListAndSend — spawned to avoid blocking during directory scan/hash
    fn buildFileListAndSendThread(self: *Server, conn: *ws.Connection, session: *transfer.TransferSession, is_dry_run: bool) void {
        // Track whether push thread was spawned (it takes over session cleanup)
        var push_spawned = false;
        defer if (!push_spawned) {
            self.mutex.lock();
            conn.user_data = null;
            self.mutex.unlock();
            self.transfer_manager.removeSession(session.id);
        };

        session.buildFileListAsync() catch |err| {
            std.debug.print("Failed to build file list: {}\n", .{err});
            const error_msg = transfer.buildTransferError(self.allocator, session.id, "Path not found or not accessible") catch return;
            defer self.allocator.free(error_msg);
            conn.sendBinary(error_msg) catch {};
            return;
        };

        std.debug.print("  file list built: {d} files, {d} bytes total\n", .{ session.files.items.len, session.total_bytes });

        if (is_dry_run) {
            self.sendDryRunReport(conn, session);
        } else {
            const list_msg = transfer.buildFileList(self.allocator, session) catch return;
            defer self.allocator.free(list_msg);
            conn.sendBinary(list_msg) catch {};

            // Now spawn another thread for pushDownloadFiles (it takes over session cleanup)
            const push_thread = std.Thread.spawn(.{}, pushDownloadFilesThread, .{ self, conn, session }) catch |err| {
                std.debug.print("Failed to spawn pushDownloadFiles thread: {}\n", .{err});
                return;
            };
            push_spawned = true;
            self.trackPushThread(push_thread);
        }
    }

    /// Push all file chunks for a download transfer.
    /// Small files use batch I/O (MultiFileReader). Large files are processed
    /// concurrently via goroutines (read + compress in parallel, send results
    /// through a channel to the WS handler thread).
    fn pushDownloadFiles(self: *Server, conn: *ws.Connection, session: *transfer.TransferSession) void {
        // Always clean up session when this function returns (normal, error, or cancel).
        // This pairs with onFileDisconnect which only signals is_active=false for downloads.
        defer {
            self.mutex.lock();
            conn.user_data = null;
            self.mutex.unlock();
            self.transfer_manager.removeSession(session.id);
        }

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

        // Goroutine-safe token channel to limit concurrent large file processing (prevent OOM).
        // Uses GChannel instead of std.Thread.Semaphore because semaphore.wait() blocks the
        // OS thread (via futex), while GChannel.recv() parks the goroutine — allowing other
        // goroutines to continue running on the same OS thread.
        const TokenCh = gchannel.GChannel(u8);
        const token_ch = TokenCh.initBuffered(self.allocator, self.goroutine_rt, 32) catch {
            self.pushDownloadFilesSerial(conn, session);
            return;
        };

        // Pre-fill token channel with 32 tokens
        for (0..32) |_| {
            _ = token_ch.send(0);
        }

        // Ensure channels outlive all goroutines: wait for completion then deinit
        defer {
            // Close channels to unblock any goroutines waiting for tokens or send slots.
            // This is idempotent and safe to call even if channels are already closed.
            token_ch.close();
            send_ch.close();

            // Wait for ALL goroutines to finish before freeing channels.
            // After closing, goroutines unblock quickly (recv/send return null/false).
            // We MUST wait — deiniting while goroutines hold channel pointers is use-after-free.
            while (goroutine_done.load(.acquire) < large_file_count) {
                std.Thread.sleep(100 * std.time.ns_per_us);
            }

            // All goroutines done — safe to free
            while (send_ch.recv()) |msg| {
                transfer.ParallelCompressor.freeChunks(self.allocator, msg.chunks);
            }
            token_ch.deinit();
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
            const base_path_copy = self.allocator.dupe(u8, session.base_path) catch {
                self.allocator.free(file_path_copy);
                continue;
            };
            const ctx = self.allocator.create(FileGoroutineCtx) catch {
                self.allocator.free(file_path_copy);
                self.allocator.free(base_path_copy);
                continue;
            };
            ctx.* = .{
                .allocator = self.allocator,
                .session_id = session.id,
                .file_index = file_index,
                .file_size = entry.size,
                .file_path = file_path_copy,
                .base_path = base_path_copy,
                .is_active = &session.is_active,
                .send_ch = send_ch,
                .done_counter = &goroutine_done,
                .token_ch = token_ch,
            };
            _ = self.goroutine_rt.go(processFileGoroutine, @ptrCast(ctx)) catch {
                ctx.deinit();
                continue;
            };
            large_file_count += 1;
        }

        // Flush remaining small files
        std.debug.print("[pushDownloadFiles] Flushing remaining: small_indices={d}, batch_entries={d}, large_file_count={d}\n", .{ small_indices.items.len, batch_entries.items.len, large_file_count });
        self.flushRemaining(conn, session, &small_indices, &small_sizes, &small_bytes, &batch_entries, &batch_data_bufs, &batch_bytes, &bytes_sent, chunk_size);

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

        // Only send TRANSFER_COMPLETE if session is still active (not canceled/disconnected)
        if (!session.is_active) {
            std.debug.print("[pushDownloadFiles] Transfer {d} was cancelled/disconnected, skipping TRANSFER_COMPLETE\n", .{session.id});
            return;
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
        // Session cleanup handled by defer at function start
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

            self.flushRemaining(conn, session, &small_indices, &small_sizes, &small_bytes, &batch_entries, &batch_data_bufs, &batch_bytes, &bytes_sent, chunk_size);

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

        self.flushRemaining(conn, session, &small_indices, &small_sizes, &small_bytes, &batch_entries, &batch_data_bufs, &batch_bytes, &bytes_sent, chunk_size);

        const complete_msg = transfer.buildTransferComplete(self.allocator, session.id, bytes_sent) catch return;
        defer self.allocator.free(complete_msg);
        conn.sendBinary(complete_msg) catch {};
        std.debug.print("Download complete (serial fallback): {d} bytes sent\n", .{bytes_sent});
        // Session cleanup handled by caller's defer (pushDownloadFiles)
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

    /// Flush any pending small-file and batch buffers.
    fn flushRemaining(
        self: *Server,
        conn: *ws.Connection,
        session: *transfer.TransferSession,
        small_indices: *std.ArrayListUnmanaged(u32),
        small_sizes: *std.ArrayListUnmanaged(u64),
        small_bytes: *u64,
        batch_entries: *std.ArrayListUnmanaged(transfer.BatchEntry),
        batch_data_bufs: *std.ArrayListUnmanaged([]const u8),
        batch_bytes: *u64,
        bytes_sent: *u64,
        chunk_size: usize,
    ) void {
        if (small_indices.items.len > 0)
            self.flushSmallBatch(conn, session, small_indices, small_sizes, small_bytes, batch_entries, batch_data_bufs, batch_bytes, bytes_sent, chunk_size);
        if (batch_entries.items.len > 0)
            self.flushBatch(conn, session, batch_entries, batch_data_bufs, batch_bytes, bytes_sent);
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

        // Session cleanup is handled by buildFileListAndSendThread's defer
        // (push_spawned stays false for dry runs, so defer runs removeSession).
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
                if (req.from_api) _ = self.tmux_api_response_ch.send(0);
                continue;
            };

            // Notify tmux API caller if this was an API-originated request
            if (req.from_api) _ = self.tmux_api_response_ch.send(panel.id);

            // Switch encoding focus to the new panel so the server immediately
            // starts encoding its tab. The client sends FOCUS_PANEL later to confirm,
            // but this avoids the gap where the new panel gets no frames.
            if (req.kind == .regular) {
                self.mutex.lock();
                self.layout.active_panel_id = panel.id;
                self.mutex.unlock();
            }

            // Panel starts streaming immediately. Initial dimensions are approximate;
            // each client's ResizeObserver sends the correct viewport-based resize
            // within one animation frame (~16ms).
            self.broadcastPanelMsg(.panel_created, panel.id);
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

                // Clean up per-session references to this panel
                self.cleanupDestroyedPanelSessions(req.id);

                // Remove panel assignment if any
                const had_assignment = if (self.panel_assignments.fetchRemove(req.id)) |old| blk: {
                    self.allocator.free(old.value);
                    break :blk true;
                } else false;

                self.mutex.unlock();

                panel.deinit();

                // Notify clients
                self.broadcastPanelMsg(.panel_closed, req.id);

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
                if (req.from_api) _ = self.tmux_api_response_ch.send(0);
                // Resume parent on failure
                if (parent_panel) |parent| {
                    parent.resumeStream();
                }
                continue;
            };

            // Apply even layout before broadcasting if requested (tmux API splits)
            if (req.apply_even_layout) {
                self.mutex.lock();
                self.layout.applyEvenLayout(panel.id);
                self.mutex.unlock();
            }

            // Notify tmux API caller if this was an API-originated request
            if (req.from_api) _ = self.tmux_api_response_ch.send(panel.id);

            // Panel starts streaming immediately (H264 frames sent to all h264_connections)
            // Initial dimensions come from the parent panel's viewport. Each client's
            // ResizeObserver will send the correct viewport-based resize within
            // one animation frame (~16ms), which triggers a keyframe at the right size.
            self.broadcastPanelMsg(.panel_created, panel.id);
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

    /// Write a formatted debug message to a log file (no-op when log is null).
    fn logToFile(file: ?std.fs.File, comptime fmt: []const u8, args: anytype) void {
        const f = file orelse return;
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, fmt, args) catch return;
        _ = f.write(line) catch {};
    }

    /// Snapshot panel pointers from the map into a stack buffer so callers
    /// can iterate without holding the mutex.
    fn collectPanels(self: *Server, buf: *[64]*Panel) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var count: usize = 0;
        var it = self.panels.valueIterator();
        while (it.next()) |pp| {
            if (count < buf.len) {
                buf[count] = pp.*;
                count += 1;
            }
        }
        return count;
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

            // Periodic cleanup of expired rate limit entries (self-throttles to once per minute)
            self.rate_limiter.cleanup();

            // Periodic JWT renewal — check every ~10 seconds (300 frames at 30fps)
            self.renewExpiredJwts();

            // Process input for all panels (more responsive than frame rate)
            // Collect panels first, then release mutex before calling ghostty
            // (ghostty callbacks may need the mutex)
            var panels_buf: [64]*Panel = undefined;
            const panels_count = self.collectPanels(&panels_buf);

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
                    logToFile(perf_log, "GAP {d}ms between frames\n", .{since_last_frame / std.time.ns_per_ms});
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

                var panel_it = self.panels.valueIterator();
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
                        logToFile(dbg_log, "COLLECT panel={d} tick={d} in_active={} overview={} h264_clients={} force_kf={} consec_unch={d}\n", .{
                            panel.id, panel.ticks_since_connect, in_active, is_overview, has_h264_clients, panel.force_keyframe, panel.consecutive_unchanged,
                        });
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

                    // Idle quality keyframe: after ~0.5s of unchanged content,
                    // send one high-quality keyframe so the user sees a crisp screen
                    // after heavy activity (where AIMD may have degraded quality).
                    if (panel.consecutive_unchanged == Panel.IDLE_KEYFRAME_THRESHOLD and
                        !panel.idle_keyframe_sent)
                    {
                        panel.force_keyframe = true;
                        panel.idle_keyframe_sent = true;
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
                            panel.idle_keyframe_sent = false;

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
                                logToFile(dbg_log, "NO_ENCODER panel={d} tick={d} enc={} buf={}\n", .{ panel.id, panel.ticks_since_connect, panel.video_encoder != null, panel.bgra_buffer != null });
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
                            logToFile(dbg_log, "SKIP_EARLY panel={d} tick={d}\n", .{ panel.id, panel.ticks_since_connect });
                            continue;
                        }

                        was_keyframe = panel.force_keyframe;

                        // Read pixels from OpenGL framebuffer
                        crash_phase.store(6, .monotonic); // ghostty_surface_read_pixels
                        const t_read = std.time.nanoTimestamp();
                        const read_ok = c.ghostty_surface_read_pixels(panel.surface, panel.bgra_buffer.?.ptr, panel.bgra_buffer.?.len);
                        read_elapsed = @intCast(std.time.nanoTimestamp() - t_read);
                        perf_read_ns += read_elapsed;

                        // Query cursor state and broadcast if changed (for frontend CSS overlay).
                        // Must run BEFORE the hash-skip `continue` below, because invisible
                        // characters (spaces) don't change the framebuffer and would otherwise
                        // cause the cursor position update to be skipped entirely.
                        {
                            var cur_col: u16 = 0;
                            var cur_row: u16 = 0;
                            var cur_style: u8 = 0;
                            var cur_visible: u8 = 0;
                            var cur_color_r: u8 = 0xc8;
                            var cur_color_g: u8 = 0xc8;
                            var cur_color_b: u8 = 0xc8;
                            c.ghostty_surface_cursor_info(panel.surface, &cur_col, &cur_row, &cur_style, &cur_visible, &cur_color_r, &cur_color_g, &cur_color_b);

                            const cp = computeCursorPixelCoords(panel.surface, cur_col, cur_row);

                            // Broadcast surface dims only when they change (resize)
                            const surface_changed = cp.surf_w != panel.last_surf_w or cp.surf_h != panel.last_surf_h;
                            if (surface_changed) {
                                panel.last_surf_w = cp.surf_w;
                                panel.last_surf_h = cp.surf_h;
                                const dims_buf = buildSurfaceDimsBuf(panel.id, cp.surf_w, cp.surf_h);
                                self.broadcastControlData(&dims_buf);
                            }

                            // Cell dimensions change on zoom in/out/reset even when
                            // the surface pixel size stays the same. Track them so the
                            // cursor pixel position is recalculated and re-sent.
                            const cell_dims_changed = cp.cell_w != panel.last_cell_w or cp.cell_h != panel.last_cell_h;

                            // Re-send cursor when surface/cell dims change, position/style/color changes
                            if (surface_changed or cell_dims_changed or
                                cur_col != panel.last_cursor_col or
                                cur_row != panel.last_cursor_row or
                                cur_style != panel.last_cursor_style or
                                cur_visible != panel.last_cursor_visible or
                                cur_color_r != panel.last_cursor_color_r or
                                cur_color_g != panel.last_cursor_color_g or
                                cur_color_b != panel.last_cursor_color_b)
                            {
                                panel.last_cursor_col = cur_col;
                                panel.last_cursor_row = cur_row;
                                panel.last_cursor_style = cur_style;
                                panel.last_cursor_visible = cur_visible;
                                panel.last_cursor_color_r = cur_color_r;
                                panel.last_cursor_color_g = cur_color_g;
                                panel.last_cursor_color_b = cur_color_b;
                                panel.last_cell_w = cp.cell_w;
                                panel.last_cell_h = cp.cell_h;

                                const cursor_buf = buildCursorBuf(panel.id, cp.x, cp.y, cp.w, cp.h, cur_style, cur_visible, cur_color_r, cur_color_g, cur_color_b);
                                self.broadcastControlData(&cursor_buf);
                            }
                        }

                        if (read_ok) {
                            if (comptime enable_benchmark) {
                                _ = self.bw_raw_pixels_bytes.fetchAdd(panel.bgra_buffer.?.len, .monotonic);
                            }

                            // Frame skip: hash the pixel buffer and skip encoding if unchanged
                            const frame_hash = std.hash.XxHash64.hash(0, panel.bgra_buffer.?);

                            // Debug: log frames after input to diagnose stale pixels
                            if (panel.dbg_input_countdown > 0) {
                                panel.dbg_input_countdown -= 1;
                                if (dbg_log != null) {
                                    // Get cursor info to correlate with pixel content
                                    var cur_col: u16 = 0;
                                    var cur_row: u16 = 0;
                                    var cur_style: u8 = 0;
                                    var cur_visible: u8 = 0;
                                    var dbg_cr: u8 = 0;
                                    var dbg_cg: u8 = 0;
                                    var dbg_cb: u8 = 0;
                                    c.ghostty_surface_cursor_info(panel.surface, &cur_col, &cur_row, &cur_style, &cur_visible, &dbg_cr, &dbg_cg, &dbg_cb);

                                    // Sample pixel at cursor position
                                    const row_bytes = pixel_width * 4;
                                    const sample_row: usize = @min(@as(usize, cur_row) * @as(usize, @intCast(c.ghostty_surface_size(panel.surface).cell_height_px)), pixel_height - 1);
                                    const sample_offset = sample_row * row_bytes + @min(@as(usize, cur_col) * @as(usize, @intCast(c.ghostty_surface_size(panel.surface).cell_width_px)) * 4, row_bytes - 4);
                                    const px_b = panel.bgra_buffer.?[sample_offset];
                                    const px_g = panel.bgra_buffer.?[sample_offset + 1];
                                    const px_r = panel.bgra_buffer.?[sample_offset + 2];
                                    const px_a = panel.bgra_buffer.?[sample_offset + 3];

                                    // First non-black pixel in row 0
                                    var first_nonblack: usize = 0;
                                    for (0..@min(pixel_width, 200)) |x| {
                                        const off = x * 4;
                                        if (panel.bgra_buffer.?[off] != 0 or panel.bgra_buffer.?[off + 1] != 0 or panel.bgra_buffer.?[off + 2] != 0) {
                                            first_nonblack = x;
                                            break;
                                        }
                                    }

                                    logToFile(dbg_log, "INPUT_FRAME panel={d} cd={d} hash={x} prev={x} match={} cursor=({d},{d}) px@cursor=({d},{d},{d},{d}) first_nonblack_x={d}\n", .{
                                        panel.id, panel.dbg_input_countdown, frame_hash, panel.last_frame_hash, @intFromBool(frame_hash == panel.last_frame_hash),
                                        cur_col, cur_row, px_r, px_g, px_b, px_a, first_nonblack,
                                    });
                                }
                            }

                            if (frame_hash == panel.last_frame_hash and !panel.force_keyframe) {
                                panel.consecutive_unchanged += 1;
                                if (panel.ticks_since_connect < 10)
                                    logToFile(dbg_log, "HASH_SKIP panel={d} tick={d} hash={x}\n", .{ panel.id, panel.ticks_since_connect, frame_hash });
                                continue;
                            }
                            panel.consecutive_unchanged = 0;
                            panel.idle_keyframe_sent = false;
                            panel.last_frame_hash = frame_hash;

                            // Pass explicit dimensions to ensure encoder matches frame size
                            crash_phase.store(7, .monotonic); // video encoder
                            const t_enc = std.time.nanoTimestamp();
                            if (panel.video_encoder.?.encodeWithDimensions(panel.bgra_buffer.?, panel.force_keyframe, pixel_width, pixel_height) catch null) |result| {
                                frame_data = result.data;
                                panel.force_keyframe = false;
                                logToFile(dbg_log, "ENCODED panel={d} tick={d} kf={} size={d} fc={d}\n", .{ panel.id, panel.ticks_since_connect, was_keyframe, result.data.len, if (panel.video_encoder) |enc| enc.frame_count else -1 });
                            } else {
                                if (panel.ticks_since_connect < 10)
                                    logToFile(dbg_log, "ENCODE_FAIL panel={d} tick={d}\n", .{ panel.id, panel.ticks_since_connect });
                            }
                            enc_elapsed = @intCast(std.time.nanoTimestamp() - t_enc);
                            perf_encode_ns += enc_elapsed;
                        } else {
                            if (panel.ticks_since_connect < 10)
                                logToFile(dbg_log, "READ_FAIL panel={d} tick={d}\n", .{ panel.id, panel.ticks_since_connect });
                        }
                    }

                    // Send frame to all H264 clients (multiplexed by panel_id)
                    if (frame_data) |data| {
                        if (self.sendH264Frame(panel.id, data)) {
                            frames_sent += 1;
                            panel.last_frame_time = t_frame_start; // For per-panel adaptive FPS
                            if (panel.ticks_since_connect < 10)
                                logToFile(dbg_log, "SENT panel={d} tick={d} size={d}\n", .{ panel.id, panel.ticks_since_connect, data.len });
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

                    // Cursor state polling moved before hash-skip `continue` (above)

                    // Spike detection: log immediately if any single frame exceeds 50ms
                    const frame_total_ns: u64 = @intCast(std.time.nanoTimestamp() - t_frame_start);
                    const spike_threshold_ns: u64 = 50 * std.time.ns_per_ms;
                    if (frame_total_ns > spike_threshold_ns) {
                        logToFile(perf_log, "SPIKE panel={d} total={d}ms tick={d}ms read={d}ms enc={d}ms keyframe={} send_fail={}\n", .{
                            panel.id,
                            frame_total_ns / std.time.ns_per_ms,
                            tick_elapsed / std.time.ns_per_ms,
                            read_elapsed / std.time.ns_per_ms,
                            enc_elapsed / std.time.ns_per_ms,
                            was_keyframe,
                            send_failed,
                        });
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

                            if (comptime enable_benchmark) {
                                scanChildVtBytes(self);
                                const bw_h264 = self.bw_h264_bytes.load(.monotonic);
                                const bw_h264_frames = self.bw_h264_frames.load(.monotonic);
                                const bw_ctrl_sent = self.bw_control_bytes_sent.load(.monotonic);
                                const bw_ctrl_recv = self.bw_control_bytes_recv.load(.monotonic);
                                const bw_raw_px = self.bw_raw_pixels_bytes.load(.monotonic);
                                const bw_vt = self.bw_vt_bytes.load(.monotonic);
                                const bw_now2: i64 = @truncate(std.time.nanoTimestamp());
                                const elapsed_s: u64 = @intCast(@divFloor(bw_now2 - self.bw_start_time.load(.monotonic), std.time.ns_per_s));
                                logToFile(perf_log, "BW t={d}s h264={d}KB/{d}frames ctrl_out={d}KB ctrl_in={d}KB raw_px={d}MB vt={d}KB total_ws={d}KB\n", .{
                                    elapsed_s, bw_h264 / 1024, bw_h264_frames, bw_ctrl_sent / 1024,
                                    bw_ctrl_recv / 1024, bw_raw_px / (1024 * 1024), bw_vt / 1024, (bw_h264 + bw_ctrl_sent) / 1024,
                                });
                            }
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
                var input_woke = false;
                for (panels_buf[0..panels_count]) |panel| {
                    if (panel.hasQueuedInput()) {
                        panel.processInputQueue();
                        if (panel.had_input) {
                            input_woke = true;
                            panel.had_input = false;
                        }
                    }
                }
                // After key/scroll input, pull last_frame backward so the next
                // frame boundary arrives within ~2ms instead of up to 33ms. This
                // reduces input-to-display latency without extra encoder calls.
                if (input_woke) {
                    const max_input_delay_ns: i128 = 2 * std.time.ns_per_ms;
                    const now_ts = std.time.nanoTimestamp();
                    const since = now_ts - last_frame;
                    const remaining_to_frame = @as(i128, frame_time_ns) - since;
                    if (remaining_to_frame > max_input_delay_ns) {
                        // Too long until next frame — advance last_frame so
                        // only max_input_delay_ns remains
                        last_frame = now_ts - (@as(i128, frame_time_ns) - max_input_delay_ns);
                    }
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

        // Start tmux shim Unix socket listener (private channel, no auth needed)
        startTmuxSocketListener(self) catch |err| {
            std.debug.print("Warning: tmux shim socket failed to start: {}\n", .{err});
        };

        // Load ghostty config at startup so the first page has keybindings/colors in HTML.
        // This avoids blank shortcut labels until the first panel triggers ensureGhosttyInit.
        self.loadConfigOnly();

        // Start HTTP server in background (handles all WebSocket via path-based routing)
        const http_thread = try std.Thread.spawn(.{}, runHttpServer, .{self});

        // Note: WebSocket servers are NOT started with run() - they only handle
        // upgrades from HTTP server via handleUpgrade(). No separate ports needed.

        // Run render loop in main thread
        self.runRenderLoop();

        // Render loop exited (Ctrl+C or error) — cancel all transfers first
        // so goroutines and handler threads can exit quickly
        std.debug.print("[shutdown] cancelling transfers...\n", .{});
        self.transfer_manager.cancelAll();

        // Signal goroutine runtime shutdown so GChannel.recv() on OS threads
        // returns null (unblocks push threads stuck waiting for goroutine results)
        std.debug.print("[shutdown] signalling goroutine shutdown...\n", .{});
        self.goroutine_rt.signalShutdown();

        // Stop all servers to unblock their threads. This is done here instead
        // of the signal handler because .stop() calls allocator/deinit operations
        // that are not signal-safe.
        std.debug.print("[shutdown] stopping servers...\n", .{});
        self.http_server.stop();
        self.h264_ws_server.stop();
        self.control_ws_server.stop();
        self.file_ws_server.stop();

        // Wait for HTTP thread to finish (transfer threads should exit quickly now)
        std.debug.print("[shutdown] joining HTTP thread...\n", .{});
        http_thread.join();
        std.debug.print("[shutdown] HTTP thread joined\n", .{});
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
                        self.broadcastPanelMsg(.panel_bell, panel.id);
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
                    // Check if this is a screen dump response (write_screen_file/write_selection_file)
                    if (self.screen_dump_pending.swap(false, .acq_rel)) {
                        // The clipboard content is a temp file path — read and broadcast
                        if (std.mem.startsWith(u8, data, "/tmp/ghostty-")) {
                            self.handleScreenDumpFile(data);
                            return;
                        }
                    }
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


// Tmux shim support — generates a mock tmux script in a temp directory
// so that tools like Claude Code agent teams can create panes via termweb.

const TmuxShimResult = struct {
    bin_dir: []const u8,
    sock_path: []const u8,
};

/// Create temp directory with mock tmux shell script. Returns bin/ dir path and socket path.
fn createTmuxShimDir(allocator: std.mem.Allocator) !TmuxShimResult {
    const pid = std.Thread.getCurrentId();
    const base_dir = try std.fmt.allocPrint(allocator, "/tmp/termweb-{d}", .{pid});
    defer allocator.free(base_dir);

    const bin_dir = try std.fmt.allocPrint(allocator, "{s}/bin", .{base_dir});
    errdefer allocator.free(bin_dir);

    const sock_path = try std.fmt.allocPrint(allocator, "{s}/tmux.sock", .{base_dir});
    errdefer allocator.free(sock_path);

    // Create directory tree
    std.fs.cwd().makePath(bin_dir) catch |err| {
        std.debug.print("Failed to create tmux shim dir {s}: {}\n", .{ bin_dir, err });
        return err;
    };

    // Write mock tmux script
    const script_path = try std.fmt.allocPrint(allocator, "{s}/tmux", .{bin_dir});
    defer allocator.free(script_path);

    const file = try std.fs.cwd().createFile(script_path, .{ .mode = 0o755 });
    defer file.close();
    try file.writeAll(tmux_shim_script);

    std.debug.print("Tmux shim created at {s} (socket: {s})\n", .{ bin_dir, sock_path });
    return .{ .bin_dir = bin_dir, .sock_path = sock_path };
}

const tmux_shim_script =
    \\#!/bin/sh
    \\# Termweb tmux shim — intercepts tmux commands and forwards to termweb API
    \\# via Unix domain socket. No auth needed — socket file permissions control access.
    \\SOCK="${TERMWEB_SOCK:-/tmp/termweb-0/tmux.sock}"
    \\PANE="${TERMWEB_PANE_ID:-1}"
    \\API="http://localhost"
    \\
    \\cmd="$1"; shift 2>/dev/null
    \\
    \\case "$cmd" in
    \\  split-window)
    \\    dir="v"; cwd=""; run=""
    \\    while [ $# -gt 0 ]; do
    \\      case "$1" in
    \\        -h) dir="h"; shift ;;
    \\        -v) dir="v"; shift ;;
    \\        -c) cwd="$2"; shift 2 ;;
    \\        -t) shift 2 ;;
    \\        -b|-d|-f|-Z|-P|-I) shift ;;
    \\        -l|-e|-F|-n) shift 2 ;;
    \\        -*) shift ;;
    \\        *) run="$*"; break ;;
    \\      esac
    \\    done
    \\    curl -sf --max-time 10 --unix-socket "$SOCK" -X POST "$API/api/tmux" \
    \\      -H "Content-Type: application/json" \
    \\      -d "{\"cmd\":\"split-window\",\"pane\":$PANE,\"dir\":\"$dir\",\"cwd\":\"$cwd\",\"command\":\"$run\"}"
    \\    ;;
    \\
    \\  new-window)
    \\    name=""; cwd=""; run=""
    \\    while [ $# -gt 0 ]; do
    \\      case "$1" in
    \\        -n) name="$2"; shift 2 ;;
    \\        -c) cwd="$2"; shift 2 ;;
    \\        -t) shift 2 ;;
    \\        -*) shift ;;
    \\        *) run="$*"; break ;;
    \\      esac
    \\    done
    \\    curl -sf --max-time 10 --unix-socket "$SOCK" -X POST "$API/api/tmux" \
    \\      -H "Content-Type: application/json" \
    \\      -d "{\"cmd\":\"new-window\",\"cwd\":\"$cwd\",\"name\":\"$name\",\"command\":\"$run\"}"
    \\    ;;
    \\
    \\  send-keys)
    \\    target="$PANE"; literal=0
    \\    while [ $# -gt 0 ]; do
    \\      case "$1" in
    \\        -t) target=$(echo "$2" | sed 's/^%//'); shift 2 ;;
    \\        -l) literal=1; shift ;;
    \\        -*) shift ;;
    \\        *) break ;;
    \\      esac
    \\    done
    \\    # Build JSON array of arguments to preserve boundaries
    \\    args="["; sep=""
    \\    for arg in "$@"; do
    \\      escaped=$(printf '%s' "$arg" | sed 's/\\/\\\\/g;s/"/\\"/g')
    \\      args="$args${sep}\"$escaped\""
    \\      sep=","
    \\    done
    \\    args="$args]"
    \\    curl -sf --max-time 5 --unix-socket "$SOCK" -X POST "$API/api/tmux" \
    \\      -H "Content-Type: application/json" \
    \\      -d "{\"cmd\":\"send-keys\",\"target\":$target,\"args\":$args}"
    \\    ;;
    \\
    \\  list-panes)
    \\    fmt=""; flags=""
    \\    while [ $# -gt 0 ]; do
    \\      case "$1" in
    \\        -a) flags="a"; shift ;;
    \\        -s) flags="s"; shift ;;
    \\        -F) fmt="$2"; shift 2 ;;
    \\        -*) shift ;;
    \\        *) break ;;
    \\      esac
    \\    done
    \\    curl -sf --max-time 5 --unix-socket "$SOCK" "$API/api/tmux?cmd=list-panes&format=$(printf '%s' "$fmt" | sed 's/ /%20/g')"
    \\    ;;
    \\
    \\  display-message)
    \\    fmt=""; print=0
    \\    while [ $# -gt 0 ]; do
    \\      case "$1" in
    \\        -p) print=1; shift ;;
    \\        -t) shift 2 ;;
    \\        *) fmt="$1"; shift ;;
    \\      esac
    \\    done
    \\    if [ "$print" = "1" ]; then
    \\      curl -sf --max-time 5 --unix-socket "$SOCK" "$API/api/tmux?cmd=display-message&pane=$PANE&format=$(printf '%s' "$fmt" | sed 's/ /%20/g')"
    \\    fi
    \\    ;;
    \\
    \\  select-layout)
    \\    layout="tiled"
    \\    while [ $# -gt 0 ]; do
    \\      case "$1" in
    \\        -t) shift 2 ;;
    \\        -*) shift ;;
    \\        *) layout="$1"; shift ;;
    \\      esac
    \\    done
    \\    curl -sf --max-time 5 --unix-socket "$SOCK" -X POST "$API/api/tmux" \
    \\      -H "Content-Type: application/json" \
    \\      -d "{\"cmd\":\"select-layout\",\"pane\":$PANE,\"layout\":\"$layout\"}"
    \\    ;;
    \\
    \\  select-pane) exit 0 ;;
    \\  has-session|-has-session) exit 0 ;;
    \\  -V|--version) echo "tmux termweb-shim" ;;
    \\  *) echo "tmux shim: unsupported: $cmd" >&2; exit 0 ;;
    \\esac
;

/// Start a Unix domain socket listener for tmux shim API.
/// Spawns a thread that accepts connections and handles HTTP-over-UDS requests.
fn startTmuxSocketListener(server: *Server) !void {
    const sock_path = server.tmux_sock_path;

    // Create null-terminated path for bind
    var sun_path: [108]u8 = undefined;
    if (sock_path.len >= sun_path.len) return error.PathTooLong;
    @memcpy(sun_path[0..sock_path.len], sock_path);
    sun_path[sock_path.len] = 0;

    // Remove stale socket file if it exists
    std.fs.cwd().deleteFile(sock_path) catch {};

    // Create Unix domain socket
    const fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    errdefer std.posix.close(fd);

    // Bind to socket path
    var addr: std.posix.sockaddr.un = .{ .family = std.posix.AF.UNIX, .path = @bitCast(sun_path) };
    try std.posix.bind(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un));

    // Set socket permissions (owner only — private channel)
    std.posix.fchmodat(std.posix.AT.FDCWD, sock_path, 0o700, 0) catch {};

    // Listen
    try std.posix.listen(fd, 8);

    server.tmux_sock_fd = fd;

    // Spawn listener thread
    server.tmux_sock_thread = try std.Thread.spawn(.{}, tmuxSocketListenerThread, .{server});
}

/// Thread function: accepts connections on Unix socket, handles HTTP requests.
fn tmuxSocketListenerThread(server: *Server) void {
    const fd = server.tmux_sock_fd orelse return;

    while (server.running.load(.acquire)) {
        // Accept connection (blocking)
        const conn_fd = std.posix.accept(fd, null, null, 0) catch |err| {
            if (!server.running.load(.acquire)) break; // Shutting down
            if (err == error.ConnectionAborted or err == error.SocketNotBound) break;
            continue;
        };

        // Handle in a detached thread to avoid blocking the listener
        const thread = std.Thread.spawn(.{}, handleTmuxSocketConnection, .{ server, conn_fd }) catch {
            std.posix.close(conn_fd);
            continue;
        };
        thread.detach();
    }
}

/// Handle a single connection on the tmux Unix socket.
/// Reads HTTP request, dispatches to API handler, sends HTTP response.
fn handleTmuxSocketConnection(server: *Server, conn_fd: std.posix.socket_t) void {
    defer std.posix.close(conn_fd);

    // Read HTTP request
    var buf: [8192]u8 = undefined;
    const n = std.posix.read(conn_fd, &buf) catch return;
    if (n == 0) return;
    const request = buf[0..n];

    // Parse request line (e.g. "GET /api/tmux?cmd=list-panes HTTP/1.1\r\n...")
    const line_end = std.mem.indexOf(u8, request, "\r\n") orelse return;
    const request_line = request[0..line_end];

    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method = parts.next() orelse return;
    const full_path = parts.next() orelse return;

    // Extract POST body
    var body: []const u8 = "";
    if (std.mem.eql(u8, method, "POST")) {
        if (std.mem.indexOf(u8, request, "\r\n\r\n")) |hdr_end| {
            body = request[hdr_end + 4 ..];
        }
    }

    // Dispatch to API handler
    if (handleTmuxApiRequest(server, method, full_path, body)) |response| {
        defer server.allocator.free(response);
        // Send HTTP response
        var hdr_buf: [256]u8 = undefined;
        const header = std.fmt.bufPrint(&hdr_buf, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{response.len}) catch return;
        _ = std.posix.write(conn_fd, header) catch {};
        _ = std.posix.write(conn_fd, response) catch {};
    } else {
        const err_resp = "HTTP/1.1 400 Bad Request\r\nContent-Length: 11\r\nConnection: close\r\n\r\nBad Request";
        _ = std.posix.write(conn_fd, err_resp) catch {};
    }
}

/// Handle tmux API HTTP request. Called from Unix socket handler thread.
/// Returns allocated response body string (caller must free), or null on error.
fn handleTmuxApiRequest(server: *Server, method: []const u8, full_path: []const u8, body: []const u8) ?[]const u8 {
    const allocator = server.allocator;

    if (std.mem.eql(u8, method, "GET")) {
        // Parse query string
        const query = if (std.mem.indexOf(u8, full_path, "?")) |idx| full_path[idx + 1 ..] else "";
        return handleTmuxQuery(server, query);
    }

    if (std.mem.eql(u8, method, "POST")) {
        return handleTmuxPost(server, body, allocator);
    }

    return null;
}

fn handleTmuxQuery(server: *Server, query: []const u8) ?[]const u8 {
    const allocator = server.allocator;

    // Parse cmd= from query
    var cmd: []const u8 = "";
    var format: []const u8 = "";
    var pane_str: []const u8 = "";

    var params = std.mem.splitScalar(u8, query, '&');
    while (params.next()) |param| {
        if (std.mem.startsWith(u8, param, "cmd=")) {
            cmd = param[4..];
        } else if (std.mem.startsWith(u8, param, "format=")) {
            format = param[7..];
        } else if (std.mem.startsWith(u8, param, "pane=")) {
            pane_str = param[5..];
        }
    }

    // Percent-decode the format string (shim sends literal #{}, raw curl sends %23%7B%7D)
    const decoded_format = if (format.len > 0) (percentDecode(format, allocator) orelse format) else format;
    defer if (decoded_format.ptr != format.ptr) allocator.free(decoded_format);

    if (std.mem.eql(u8, cmd, "list-panes")) {
        return handleTmuxListPanes(server, decoded_format, allocator);
    }

    if (std.mem.eql(u8, cmd, "display-message")) {
        const pane_id = std.fmt.parseInt(u32, pane_str, 10) catch 1;
        return handleTmuxDisplayMessage(server, pane_id, decoded_format, allocator);
    }

    return null;
}

/// Decode percent-encoded URL strings (e.g., %23 → #, %7B → {).
fn percentDecode(input: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hi = hexDigit(input[i + 1]);
            const lo = hexDigit(input[i + 2]);
            if (hi != null and lo != null) {
                buf.append(allocator, (hi.? << 4) | lo.?) catch {
                    buf.deinit(allocator);
                    return null;
                };
                i += 3;
                continue;
            }
        }
        buf.append(allocator, input[i]) catch {
            buf.deinit(allocator);
            return null;
        };
        i += 1;
    }
    return buf.toOwnedSlice(allocator) catch {
        buf.deinit(allocator);
        return null;
    };
}

fn hexDigit(char: u8) ?u8 {
    if (char >= '0' and char <= '9') return char - '0';
    if (char >= 'a' and char <= 'f') return char - 'a' + 10;
    if (char >= 'A' and char <= 'F') return char - 'A' + 10;
    return null;
}

/// Tmux format variable types for interpolation dispatch.
const FmtVar = enum { pane_id, pane_index, pane_active, pane_width, pane_height, pane_current_path, pane_title };

/// Comptime map from variable name to FmtVar for O(1) lookup.
const fmt_var_map = std.StaticStringMap(FmtVar).initComptime(.{
    .{ "pane_id", .pane_id },
    .{ "pane_index", .pane_index },
    .{ "pane_active", .pane_active },
    .{ "pane_width", .pane_width },
    .{ "pane_height", .pane_height },
    .{ "pane_current_path", .pane_current_path },
    .{ "pane_title", .pane_title },
    .{ "pane_current_command", .pane_title },
});

/// Interpolate tmux format variables (e.g., #{pane_id} → %1) into buf.
fn interpolateTmuxFormat(
    buf: *std.ArrayListUnmanaged(u8),
    format: []const u8,
    panel_id: u32,
    width: u32,
    height: u32,
    active: u8,
    pwd: []const u8,
    title: []const u8,
    allocator: std.mem.Allocator,
) void {
    const writer = buf.writer(allocator);
    var i: usize = 0;
    while (i < format.len) {
        if (i + 1 < format.len and format[i] == '#' and format[i + 1] == '{') {
            const close = std.mem.indexOfPos(u8, format, i + 2, "}") orelse {
                buf.append(allocator, format[i]) catch break;
                i += 1;
                continue;
            };
            if (fmt_var_map.get(format[i + 2 .. close])) |v| switch (v) {
                .pane_id => std.fmt.format(writer, "%{d}", .{panel_id}) catch {},
                .pane_index => std.fmt.format(writer, "{d}", .{panel_id}) catch {},
                .pane_active => std.fmt.format(writer, "{d}", .{active}) catch {},
                .pane_width => std.fmt.format(writer, "{d}", .{width}) catch {},
                .pane_height => std.fmt.format(writer, "{d}", .{height}) catch {},
                .pane_current_path => buf.appendSlice(allocator, pwd) catch {},
                .pane_title => buf.appendSlice(allocator, title) catch {},
            };
            i = close + 1;
        } else {
            buf.append(allocator, format[i]) catch break;
            i += 1;
        }
    }
}

fn handleTmuxListPanes(server: *Server, format: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};

    server.mutex.lock();
    defer server.mutex.unlock();

    var it = server.panels.iterator();
    while (it.next()) |entry| {
        const panel = entry.value_ptr.*;
        const active: u8 = if (server.layout.active_panel_id) |aid| (if (aid == panel.id) @as(u8, 1) else @as(u8, 0)) else 0;

        if (format.len > 0) {
            interpolateTmuxFormat(
                &buf,
                format,
                panel.id,
                panel.width,
                panel.height,
                active,
                if (panel.pwd.len > 0) panel.pwd else server.initial_cwd,
                if (panel.title.len > 0) panel.title else "shell",
                allocator,
            );
            buf.append(allocator, '\n') catch {};
        } else {
            // Default format: %N: [WxH] [active]
            std.fmt.format(buf.writer(allocator), "%{d}: [{d}x{d}] [{s}]\n", .{
                panel.id, panel.width, panel.height,
                if (active == 1) "active" else "",
            }) catch {};
        }
    }

    // Return empty string for empty pane list (not null, which would cause 400)
    if (buf.items.len > 0) {
        return buf.toOwnedSlice(allocator) catch {
            buf.deinit(allocator);
            return null;
        };
    }
    buf.deinit(allocator);
    return allocator.dupe(u8, "") catch null;
}

fn handleTmuxDisplayMessage(server: *Server, pane_id: u32, format: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    server.mutex.lock();
    defer server.mutex.unlock();

    const p = server.panels.get(pane_id) orelse {
        return std.fmt.allocPrint(allocator, "%{d}", .{pane_id}) catch null;
    };

    if (format.len == 0) return std.fmt.allocPrint(allocator, "%{d}", .{pane_id}) catch null;

    const active: u8 = if (server.layout.active_panel_id) |aid| (if (aid == pane_id) @as(u8, 1) else @as(u8, 0)) else 0;
    var buf: std.ArrayListUnmanaged(u8) = .{};
    interpolateTmuxFormat(&buf, format, p.id, p.width, p.height, active, if (p.pwd.len > 0) p.pwd else server.initial_cwd, if (p.title.len > 0) p.title else "shell", allocator);
    buf.append(allocator, '\n') catch {};
    return buf.toOwnedSlice(allocator) catch {
        buf.deinit(allocator);
        return null;
    };
}

fn handleTmuxPost(server: *Server, body: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    // Simple JSON parsing — extract "cmd" field
    const cmd = jsonGetString(body, "cmd") orelse return null;

    if (std.mem.eql(u8, cmd, "split-window")) {
        const pane_id = jsonGetInt(body, "pane") orelse 1;
        const dir_str = jsonGetString(body, "dir") orelse "v";
        const direction: SplitDirection = if (std.mem.eql(u8, dir_str, "h")) .horizontal else .vertical;

        // Derive new panel dimensions: prefer panel owner's viewport, fall back to parent panel.
        // Copy all values while holding the lock to avoid reading freed Panel memory.
        var width: u32 = 800;
        var height: u32 = 600;
        var scale: f64 = 2.0;
        {
            server.mutex.lock();
            defer server.mutex.unlock();
            const owner_viewport: ?SessionViewport = blk: {
                if (server.panel_assignments.get(pane_id)) |owner_sid| {
                    if (server.session_viewports.get(owner_sid)) |vp| break :blk vp;
                }
                break :blk null;
            };
            if (owner_viewport) |vp| {
                width = vp.width;
                height = vp.height;
                scale = vp.scale;
            } else if (server.panels.get(pane_id)) |parent| {
                width = parent.width;
                height = parent.height;
                scale = parent.scale;
            }
        }
        // Don't halve dimensions — the layout tree ratio (0.5) and CSS flex handle
        // the visual split. ResizeObserver will report actual sizes back to the server.

        // Record next_panel_id before sending request
        const expected_id = @atomicLoad(u32, &server.next_panel_id, .acquire);

        _ = server.pending_splits_ch.send(.{
            .parent_panel_id = pane_id,
            .direction = direction,
            .width = width,
            .height = height,
            .scale = scale,
            .from_api = true,
            .apply_even_layout = true, // Redistribute all panes evenly
        });
        server.wake_signal.notify();

        const new_id = server.tmux_api_response_ch.recv() orelse expected_id;
        return finishNewPanel(server, new_id, body, allocator);
    }

    if (std.mem.eql(u8, cmd, "select-layout")) {
        const pane_id = jsonGetInt(body, "pane") orelse 1;
        const layout_name = jsonGetString(body, "layout") orelse "tiled";
        // Support even-horizontal, even-vertical, and tiled (all use even distribution)
        if (std.mem.eql(u8, layout_name, "even-horizontal") or
            std.mem.eql(u8, layout_name, "even-vertical") or
            std.mem.eql(u8, layout_name, "tiled"))
        {
            server.mutex.lock();
            server.layout.applyEvenLayout(pane_id);
            server.mutex.unlock();
            server.broadcastLayoutUpdate();
        }
        return null;
    }

    if (std.mem.eql(u8, cmd, "new-window")) {
        // Derive dimensions: prefer first available session viewport, fall back to first panel
        var width: u32 = 800;
        var height: u32 = 600;
        var scale: f64 = 2.0;
        {
            server.mutex.lock();
            if (blk: {
                var vp_it = server.session_viewports.valueIterator();
                break :blk vp_it.next();
            }) |vp| {
                width = vp.width;
                height = vp.height;
                scale = vp.scale;
            } else {
                var it = server.panels.iterator();
                if (it.next()) |entry| {
                    const p = entry.value_ptr.*;
                    width = p.width;
                    height = p.height;
                    scale = p.scale;
                }
            }
            server.mutex.unlock();
        }

        const expected_id = @atomicLoad(u32, &server.next_panel_id, .acquire);

        _ = server.pending_panels_ch.send(.{
            .width = width,
            .height = height,
            .scale = scale,
            .inherit_cwd_from = 0,
            .kind = .regular,
            .from_api = true,
        });
        server.wake_signal.notify();

        const new_id = server.tmux_api_response_ch.recv() orelse expected_id;
        return finishNewPanel(server, new_id, body, allocator);
    }

    if (std.mem.eql(u8, cmd, "send-keys")) {
        const target_id = jsonGetInt(body, "target") orelse 1;

        server.mutex.lock();
        const panel = server.panels.get(target_id);
        server.mutex.unlock();

        if (panel) |p| {
            if (jsonGetArray(body, "args")) |args_slice| {
                var iter = JsonArrayIterator.init(args_slice);
                while (iter.next()) |arg| sendKeyArg(p, arg);
            } else if (jsonGetString(body, "keys")) |keys| {
                var tok = std.mem.tokenizeScalar(u8, keys, ' ');
                while (tok.next()) |arg| sendKeyArg(p, arg);
            }
            p.has_pending_input.store(true, .release);
            server.wake_signal.notify();
        }

        return allocator.dupe(u8, "{\"ok\":true}\n") catch null;
    }

    return null;
}

/// Dispatch a single key argument: named keys → key events, literal text → text input.
fn sendKeyArg(p: anytype, arg: []const u8) void {
    if (tmuxKeyLookup(arg)) |key| {
        p.queueKeyEvent(key.keycode, key.mods, key.text);
    } else if (arg.len > 0) {
        p.handleTextInput(arg);
    }
}

/// Send optional command to a newly created panel and return the JSON response.
fn finishNewPanel(server: *Server, new_id: u32, body: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    if (jsonGetString(body, "command")) |cmd_str| {
        if (cmd_str.len > 0) sendCommandToPanel(server, new_id, cmd_str);
    }
    return std.fmt.allocPrint(allocator, "{{\"pane_id\":\"%{d}\"}}\n", .{new_id}) catch null;
}

/// Send a command string to a panel as text input followed by Enter.
/// Waits briefly for the shell to initialize before sending.
fn sendCommandToPanel(server: *Server, panel_id: u32, command: []const u8) void {
    // Brief delay to let the shell initialize in the new panel.
    std.Thread.sleep(100 * std.time.ns_per_ms);

    server.mutex.lock();
    const p = server.panels.get(panel_id) orelse {
        server.mutex.unlock();
        return;
    };
    server.mutex.unlock();

    const enter_key = tmux_key_map.get("Enter").?;
    p.handleTextInput(command);
    p.queueKeyEvent(enter_key.keycode, enter_key.mods, enter_key.text);
    p.has_pending_input.store(true, .release);
    server.wake_signal.notify();
}

/// Find the byte position of the value for "key" in JSON. Returns index of first
/// non-whitespace character after the colon, or null if key not found.
fn jsonFindValue(json: []const u8, key: []const u8) ?usize {
    var i: usize = 0;
    while (i + key.len + 4 < json.len) : (i += 1) {
        if (json[i] == '"' and i + 1 + key.len < json.len and
            std.mem.eql(u8, json[i + 1 .. i + 1 + key.len], key) and
            json[i + 1 + key.len] == '"')
        {
            // Skip whitespace/colon after closing quote, but require a colon
            // to distinguish keys from string values that happen to match.
            var j = i + 1 + key.len + 1;
            var found_colon = false;
            while (j < json.len and (json[j] == ':' or json[j] == ' ')) : (j += 1) {
                if (json[j] == ':') found_colon = true;
            }
            if (!found_colon) continue;
            return j;
        }
    }
    return null;
}

fn jsonGetString(json: []const u8, key: []const u8) ?[]const u8 {
    const pos = jsonFindValue(json, key) orelse return null;
    if (pos >= json.len or json[pos] != '"') return null;
    const start = pos + 1;
    const end = std.mem.indexOfScalarPos(u8, json, start, '"') orelse return null;
    return json[start..end];
}

fn jsonGetInt(json: []const u8, key: []const u8) ?u32 {
    const pos = jsonFindValue(json, key) orelse return null;
    var end = pos;
    while (end < json.len and json[end] >= '0' and json[end] <= '9') : (end += 1) {}
    if (end == pos) return null;
    return std.fmt.parseInt(u32, json[pos..end], 10) catch null;
}

/// Tmux key name → XKB keycode + mods + text. Single lookup replaces two functions.
const TmuxKey = struct { keycode: u32, mods: u32 = 0, text: ?[]const u8 = null };

/// Named key map using comptime StaticStringMap for O(1) lookup.
const tmux_key_map = std.StaticStringMap(TmuxKey).initComptime(.{
    .{ "Enter", TmuxKey{ .keycode = 0x0024, .text = "\r" } },
    .{ "Space", TmuxKey{ .keycode = 0x0041, .text = " " } },
    .{ "Tab", TmuxKey{ .keycode = 0x0017, .text = "\t" } },
    .{ "Escape", TmuxKey{ .keycode = 0x0009 } },
    .{ "BSpace", TmuxKey{ .keycode = 0x0016, .text = "\x7f" } },
    .{ "DC", TmuxKey{ .keycode = 0x0077 } },
    .{ "Up", TmuxKey{ .keycode = 0x006f } },
    .{ "Down", TmuxKey{ .keycode = 0x0074 } },
    .{ "Left", TmuxKey{ .keycode = 0x0071 } },
    .{ "Right", TmuxKey{ .keycode = 0x0072 } },
    .{ "Home", TmuxKey{ .keycode = 0x006e } },
    .{ "End", TmuxKey{ .keycode = 0x0073 } },
    .{ "PageUp", TmuxKey{ .keycode = 0x0070 } },
    .{ "PageDown", TmuxKey{ .keycode = 0x0075 } },
});

/// Static table for C-a (0x01) through C-z (0x1a) text bytes.
const ctrl_text_table: [26][1]u8 = blk: {
    var t: [26][1]u8 = undefined;
    for (0..26) |i| t[i] = .{@intCast(i + 1)};
    break :blk t;
};

/// Resolve a tmux key name to keycode/mods/text. Handles named keys and C-<letter>.
fn tmuxKeyLookup(name: []const u8) ?TmuxKey {
    if (tmux_key_map.get(name)) |k| return k;
    // C-<letter>: derive keycode from mapKeyCode("Key" + upper(letter))
    if (name.len == 3 and name[0] == 'C' and name[1] == '-') {
        const letter = name[2];
        if (letter >= 'a' and letter <= 'z') {
            var code_buf = [_]u8{ 'K', 'e', 'y', letter - 32 }; // "KeyA" etc.
            const keycode = Panel.mapKeyCode(&code_buf);
            if (keycode != 0) {
                return .{ .keycode = keycode, .mods = c.GHOSTTY_MODS_CTRL, .text = &ctrl_text_table[letter - 'a'] };
            }
        }
    }
    return null;
}

/// Find a JSON array value for a given key. Returns the inner content (without brackets).
fn jsonGetArray(json: []const u8, key: []const u8) ?[]const u8 {
    const pos = jsonFindValue(json, key) orelse return null;
    if (pos >= json.len or json[pos] != '[') return null;
    var j = pos + 1;
    const start = j;
    var depth: usize = 1;
    var in_str = false;
    var escaped = false;
    while (j < json.len and depth > 0) : (j += 1) {
        if (escaped) { escaped = false; continue; }
        if (json[j] == '\\' and in_str) { escaped = true; continue; }
        if (json[j] == '"') in_str = !in_str;
        if (!in_str) {
            if (json[j] == '[') depth += 1;
            if (json[j] == ']') depth -= 1;
        }
    }
    return if (depth == 0) json[start .. j - 1] else null;
}

/// Iterator over JSON array string elements: "a","b","c"
const JsonArrayIterator = struct {
    data: []const u8,
    pos: usize,

    fn init(data: []const u8) JsonArrayIterator {
        return .{ .data = data, .pos = 0 };
    }

    fn next(self: *JsonArrayIterator) ?[]const u8 {
        // Skip whitespace and commas
        while (self.pos < self.data.len and (self.data[self.pos] == ' ' or self.data[self.pos] == ',' or self.data[self.pos] == '\n')) {
            self.pos += 1;
        }
        if (self.pos >= self.data.len) return null;
        if (self.data[self.pos] != '"') return null;
        self.pos += 1; // skip opening quote
        const start = self.pos;
        // Find closing quote (handle backslash escapes)
        while (self.pos < self.data.len) {
            if (self.data[self.pos] == '\\' and self.pos + 1 < self.data.len) {
                self.pos += 2; // skip escaped char
                continue;
            }
            if (self.data[self.pos] == '"') {
                const result = self.data[start..self.pos];
                self.pos += 1; // skip closing quote
                return result;
            }
            self.pos += 1;
        }
        return null;
    }
};


// Main


const Args = struct {
    http_port: u16 = default_http_port,
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
                args.http_port = std.fmt.parseInt(u16, val, 10) catch default_http_port;
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

/// Scan /proc for descendant processes and sum their wchar (VT bytes written to PTY).
/// Also collects command names from /proc/[pid]/comm.
/// Only compiled when benchmark is enabled.
fn scanChildVtBytes(self: *Server) void {
    if (comptime !enable_benchmark) return;

    const our_pid = std.os.linux.getpid();

    // Read all (pid, ppid) pairs from /proc
    const Entry = struct { pid: i32, ppid: i32 };
    var entries: [2048]Entry = undefined;
    var entry_count: usize = 0;

    var proc_dir = std.fs.openDirAbsolute("/proc", .{ .iterate = true }) catch return;
    defer proc_dir.close();

    var iter = proc_dir.iterate();
    while (iter.next() catch null) |dent| {
        if (dent.kind != .directory) continue;
        const pid = std.fmt.parseInt(i32, dent.name, 10) catch continue;

        // Read /proc/[pid]/stat to get ppid
        var stat_path_buf: [64]u8 = undefined;
        const stat_path = std.fmt.bufPrint(&stat_path_buf, "/proc/{d}/stat", .{pid}) catch continue;
        const stat_file = std.fs.openFileAbsolute(stat_path, .{}) catch continue;
        defer stat_file.close();
        var stat_buf: [512]u8 = undefined;
        const stat_len = stat_file.read(&stat_buf) catch continue;
        if (stat_len == 0) continue;
        const stat_str = stat_buf[0..stat_len];

        // Parse ppid: format is "pid (comm) state ppid ..."
        // Find last ')' to handle comm with spaces/parens
        const last_paren = std.mem.lastIndexOfScalar(u8, stat_str, ')') orelse continue;
        if (last_paren + 4 >= stat_len) continue;
        var rest = stat_str[last_paren + 2 ..]; // skip ") "
        // Skip state field
        const sp1 = std.mem.indexOfScalar(u8, rest, ' ') orelse continue;
        rest = rest[sp1 + 1 ..]; // now at ppid
        const sp2 = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        const ppid = std.fmt.parseInt(i32, rest[0..sp2], 10) catch continue;

        if (entry_count < entries.len) {
            entries[entry_count] = .{ .pid = pid, .ppid = ppid };
            entry_count += 1;
        }
    }

    // Build descendant set: start from our_pid, expand via ppid links
    var desc_pids: [256]i32 = undefined;
    var desc_count: usize = 0;
    desc_pids[0] = our_pid;
    desc_count = 1;

    var changed = true;
    while (changed) {
        changed = false;
        for (entries[0..entry_count]) |e| {
            // Is e.ppid in our descendant set?
            var ppid_match = false;
            for (desc_pids[0..desc_count]) |d| {
                if (d == e.ppid) { ppid_match = true; break; }
            }
            if (!ppid_match) continue;
            // Is e.pid already in set?
            var already = false;
            for (desc_pids[0..desc_count]) |d| {
                if (d == e.pid) { already = true; break; }
            }
            if (already) continue;
            if (desc_count < desc_pids.len) {
                desc_pids[desc_count] = e.pid;
                desc_count += 1;
                changed = true;
            }
        }
    }

    // Sum wchar (output) for all descendants (excluding ourselves)
    var total_wchar: u64 = 0;
    for (desc_pids[0..desc_count]) |pid| {
        if (pid == our_pid) continue;

        // Read /proc/[pid]/io for wchar
        var io_path_buf: [64]u8 = undefined;
        const io_path = std.fmt.bufPrint(&io_path_buf, "/proc/{d}/io", .{pid}) catch continue;
        const io_file = std.fs.openFileAbsolute(io_path, .{}) catch continue;
        defer io_file.close();
        var io_buf: [256]u8 = undefined;
        const io_len = io_file.read(&io_buf) catch continue;
        const io_str = io_buf[0..io_len];

        // Find "wchar: <number>" (output bytes written by child)
        if (std.mem.indexOf(u8, io_str, "wchar: ")) |pos| {
            const num_start = pos + 7;
            var num_end = num_start;
            while (num_end < io_str.len and io_str[num_end] >= '0' and io_str[num_end] <= '9') : (num_end += 1) {}
            total_wchar += std.fmt.parseInt(u64, io_str[num_start..num_end], 10) catch 0;
        }

        // Read /proc/[pid]/comm for command name
        var comm_path_buf: [64]u8 = undefined;
        const comm_path = std.fmt.bufPrint(&comm_path_buf, "/proc/{d}/comm", .{pid}) catch continue;
        const comm_file = std.fs.openFileAbsolute(comm_path, .{}) catch continue;
        defer comm_file.close();
        var comm_buf: [17]u8 = undefined;
        const comm_len = comm_file.read(&comm_buf) catch continue;
        if (comm_len == 0) continue;
        // Strip trailing newline
        const name_len = if (comm_len > 0 and comm_buf[comm_len - 1] == '\n') comm_len - 1 else comm_len;
        if (name_len == 0) continue;
        const name = comm_buf[0..name_len];

        // Add to unique commands list if not already present
        const cmd_count = self.bw_commands_len.load(.monotonic);
        var found = false;
        for (self.bw_commands[0..cmd_count]) |*existing| {
            const existing_len = std.mem.indexOfScalar(u8, existing, 0) orelse existing.len;
            if (existing_len == name_len and std.mem.eql(u8, existing[0..existing_len], name)) {
                found = true;
                break;
            }
        }
        if (!found and cmd_count < 32) {
            @memcpy(self.bw_commands[cmd_count][0..name_len], name);
            self.bw_commands[cmd_count][name_len] = 0;
            _ = self.bw_commands_len.fetchAdd(1, .monotonic);
        }
    }

    self.bw_vt_bytes.store(total_wchar, .monotonic);
}

/// Handle API requests (e.g., /api/benchmark/stats).
/// Only reachable when -Dbenchmark is set (callback gated at setup).
fn handleApiRequest(path: []const u8, user_data: ?*anyopaque) ?[]const u8 {
    if (comptime !enable_benchmark) return null;
    const server: *Server = @ptrCast(@alignCast(user_data orelse return null));

    if (std.mem.eql(u8, path, "/api/benchmark/stats")) {
        const h264_bytes = server.bw_h264_bytes.load(.monotonic);
        const h264_frames = server.bw_h264_frames.load(.monotonic);
        const ctrl_sent = server.bw_control_bytes_sent.load(.monotonic);
        const ctrl_recv = server.bw_control_bytes_recv.load(.monotonic);
        const raw_px = server.bw_raw_pixels_bytes.load(.monotonic);
        const vt_bytes = server.bw_vt_bytes.load(.monotonic);
        const bw_now: i64 = @truncate(std.time.nanoTimestamp());
        const elapsed_ns: u64 = @intCast(bw_now - server.bw_start_time.load(.monotonic));
        const elapsed_ms = elapsed_ns / std.time.ns_per_ms;

        // Build commands JSON array
        const cmd_count = server.bw_commands_len.load(.monotonic);
        var cmd_json_buf: [1024]u8 = undefined;
        var cmd_json_len: usize = 0;
        cmd_json_buf[0] = '[';
        cmd_json_len = 1;
        for (0..cmd_count) |i| {
            const cmd = &server.bw_commands[i];
            const cmd_len = std.mem.indexOfScalar(u8, cmd, 0) orelse cmd.len;
            if (cmd_len == 0) continue;
            if (cmd_json_len > 1) {
                cmd_json_buf[cmd_json_len] = ',';
                cmd_json_len += 1;
            }
            cmd_json_buf[cmd_json_len] = '"';
            cmd_json_len += 1;
            @memcpy(cmd_json_buf[cmd_json_len..][0..cmd_len], cmd[0..cmd_len]);
            cmd_json_len += cmd_len;
            cmd_json_buf[cmd_json_len] = '"';
            cmd_json_len += 1;
        }
        cmd_json_buf[cmd_json_len] = ']';
        cmd_json_len += 1;
        const cmd_json = cmd_json_buf[0..cmd_json_len];

        const S = struct {
            threadlocal var json_buf: [2048]u8 = undefined;
        };
        const json = std.fmt.bufPrint(&S.json_buf,
            \\{{"elapsed_ms":{d},"h264_bytes":{d},"h264_frames":{d},"control_bytes_sent":{d},"control_bytes_recv":{d},"raw_pixels_bytes":{d},"vt_bytes":{d},"total_ws_bytes":{d},"commands":{s}}}
        , .{
            elapsed_ms,
            h264_bytes,
            h264_frames,
            ctrl_sent,
            ctrl_recv,
            raw_px,
            vt_bytes,
            h264_bytes + ctrl_sent,
            cmd_json,
        }) catch return null;
        return json;
    }

    if (std.mem.eql(u8, path, "/api/benchmark/reset")) {
        server.bw_h264_bytes.store(0, .monotonic);
        server.bw_h264_frames.store(0, .monotonic);
        server.bw_control_bytes_sent.store(0, .monotonic);
        server.bw_control_bytes_recv.store(0, .monotonic);
        server.bw_raw_pixels_bytes.store(0, .monotonic);
        server.bw_vt_bytes.store(0, .monotonic);
        server.bw_commands_len.store(0, .monotonic);
        for (&server.bw_commands) |*cmd| cmd.* = std.mem.zeroes([17:0]u8);
        server.bw_start_time.store(@truncate(std.time.nanoTimestamp()), .monotonic);
        const S = struct {
            threadlocal var buf: [64]u8 = undefined;
        };
        const json = std.fmt.bufPrint(&S.buf, "{{}}", .{}) catch return null;
        return json;
    }

    return null;
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
    server.http_server.auth_state = server.auth_state;
    server.http_server.rate_limiter = &server.rate_limiter;
    if (comptime enable_benchmark) {
        server.http_server.api_callback = handleApiRequest;
        server.http_server.api_user_data = server;
    }

    // Resolve connection mode: interactive shows a picker, others are direct
    const chosen_provider: ?tunnel_mod.Provider = switch (mode) {
        .interactive => tunnel_mod.promptConnectionMode(),
        .local => null,
        .tunnel => |p| p,
    };

    // Generate auth tokens for URLs
    // Admin session: ensure one exists for the person running the server (full access)
    if (server.auth_state.getSession("admin") == null) {
        server.auth_state.createSession("admin", "Admin", .admin) catch {};
    }
    var admin_hex: [auth.token_hex_len]u8 = undefined;
    const admin_token: ?[]const u8 = if (server.auth_state.getSession("admin")) |session| blk: {
        auth.hexEncodeToken(&admin_hex, &session.token);
        break :blk &admin_hex;
    } else null;

    // Editor token: hex-encoded from default session (for sharing with coworkers)
    var editor_hex: [auth.token_hex_len]u8 = undefined;
    const editor_token: ?[]const u8 = if (server.auth_state.getSession("default")) |session| blk: {
        auth.hexEncodeToken(&editor_hex, &session.token);
        break :blk &editor_hex;
    } else null;

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
                if (t.process) |proc| tunnel_child_pid.store(proc.id, .release);
                if (t.waitForUrl(15 * std.time.ns_per_s)) {
                    if (t.getUrl()) |url| {
                        if (editor_token) |token| {
                            var enc_buf: [192]u8 = undefined;
                            const enc_token = auth.percentEncodeToken(&enc_buf, token);
                            const share_url = std.fmt.allocPrint(allocator, "{s}?token={s}", .{ url, enc_token }) catch url;
                            defer if (share_url.ptr != url.ptr) allocator.free(share_url);
                            std.debug.print("  Tunnel:  {s}\n", .{share_url});
                            tunnel_mod.printQrCode(allocator, share_url);
                        } else {
                            std.debug.print("  Tunnel:  {s}\n", .{url});
                            tunnel_mod.printQrCode(allocator, url);
                        }
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
        if (editor_token) |token| {
            var enc_buf2: [192]u8 = undefined;
            const enc_token2 = auth.percentEncodeToken(&enc_buf2, token);
            const share_url = std.fmt.allocPrint(allocator, "{s}?token={s}", .{ url, enc_token2 }) catch url;
            defer if (share_url.ptr != url.ptr) allocator.free(share_url);
            std.debug.print("  LAN:     {s}\n", .{share_url});
            if (tunnel == null) {
                tunnel_mod.printQrCode(allocator, share_url);
            }
        } else {
            std.debug.print("  LAN:     {s}\n", .{url});
            if (tunnel == null) {
                tunnel_mod.printQrCode(allocator, url);
            }
        }
    }

    // Local URL includes admin token (full access for the person running the server)
    if (admin_token) |token| {
        var enc_buf3: [192]u8 = undefined;
        const enc_token3 = auth.percentEncodeToken(&enc_buf3, token);
        std.debug.print("  Local:   http://localhost:{}?token={s}\n", .{ http_port, enc_token3 });
    } else {
        std.debug.print("  Local:   http://localhost:{}\n", .{http_port});
    }
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

test "jsonFindValue" {
    const json = "{\"cmd\":\"send-keys\",\"target\":3}";
    try std.testing.expectEqual(@as(?usize, 7), jsonFindValue(json, "cmd"));
    try std.testing.expectEqual(@as(?usize, 28), jsonFindValue(json, "target"));
    try std.testing.expectEqual(@as(?usize, null), jsonFindValue(json, "missing"));
    // Duplicate keys: returns first occurrence
    const dup = "{\"k\":\"first\",\"k\":\"second\"}";
    try std.testing.expect(jsonFindValue(dup, "k").? < 20);
}

test "jsonGetString" {
    const json = "{\"cmd\":\"send-keys\",\"name\":\"hello world\"}";
    try std.testing.expectEqualStrings("send-keys", jsonGetString(json, "cmd").?);
    try std.testing.expectEqualStrings("hello world", jsonGetString(json, "name").?);
    try std.testing.expect(jsonGetString(json, "missing") == null);
    try std.testing.expect(jsonGetString("{\"n\":42}", "n") == null); // int not string
    try std.testing.expectEqualStrings("", jsonGetString("{\"cmd\":\"\"}", "cmd").?); // empty
    try std.testing.expectEqualStrings("echo hello world", jsonGetString("{\"command\":\"echo hello world\"}", "command").?);
    try std.testing.expectEqualStrings("日本語", jsonGetString("{\"k\":\"日本語\"}", "k").?); // unicode
    // Exact key match, not substring
    try std.testing.expectEqualStrings("y", jsonGetString("{\"cmd_extra\":\"x\",\"cmd\":\"y\"}", "cmd").?);
    try std.testing.expectEqualStrings("first", jsonGetString("{\"k\":\"first\",\"k\":\"second\"}", "k").?); // first wins
    // Key name appearing as a value must not shadow the real key
    try std.testing.expectEqualStrings("real", jsonGetString("{\"val\":\"cmd\",\"cmd\":\"real\"}", "cmd").?);
}

test "jsonGetInt" {
    try std.testing.expectEqual(@as(?u32, 3), jsonGetInt("{\"target\":3}", "target"));
    try std.testing.expectEqual(@as(?u32, 12345), jsonGetInt("{\"id\":12345,\"x\":1}", "id"));
    try std.testing.expect(jsonGetInt("{\"target\":\"str\"}", "target") == null);
    try std.testing.expect(jsonGetInt("{\"x\":1}", "missing") == null);
    try std.testing.expectEqual(@as(?u32, 0), jsonGetInt("{\"pane\":0}", "pane"));
    try std.testing.expectEqual(@as(?u32, 42), jsonGetInt("{\"id\":42}", "id")); // at end of object
    try std.testing.expectEqual(@as(?u32, 7), jsonGetInt("{\"n\":007}", "n")); // leading zeros
}

test "jsonGetArray" {
    const json = "{\"args\":[\"ls\",\"Enter\"],\"x\":1}";
    try std.testing.expectEqualStrings("\"ls\",\"Enter\"", jsonGetArray(json, "args").?);
    try std.testing.expect(jsonGetArray(json, "x") == null);
    try std.testing.expect(jsonGetArray(json, "missing") == null);
    try std.testing.expectEqualStrings("[1],2", jsonGetArray("{\"a\":[[1],2]}", "a").?); // nested
    try std.testing.expectEqualStrings("\"echo \\\"hi\\\"\"", jsonGetArray("{\"args\":[\"echo \\\"hi\\\"\"]}", "args").?); // escaped quotes
    try std.testing.expectEqualStrings("", jsonGetArray("{\"args\":[]}", "args").?); // empty
    try std.testing.expectEqualStrings("\"ls\"", jsonGetArray("{\"args\":[\"ls\"]}", "args").?); // single
    try std.testing.expectEqualStrings("{\"x\":1}", jsonGetArray("{\"a\":[{\"x\":1}]}", "a").?); // nested objects
}

test "JsonArrayIterator" {
    var iter = JsonArrayIterator.init("\"ls -la\",\"Enter\",\"C-c\"");
    try std.testing.expectEqualStrings("ls -la", iter.next().?);
    try std.testing.expectEqualStrings("Enter", iter.next().?);
    try std.testing.expectEqualStrings("C-c", iter.next().?);
    try std.testing.expect(iter.next() == null);

    var empty = JsonArrayIterator.init("");
    try std.testing.expect(empty.next() == null);

    var escaped = JsonArrayIterator.init("\"echo \\\"hi\\\"\"");
    try std.testing.expectEqualStrings("echo \\\"hi\\\"", escaped.next().?);
    try std.testing.expect(escaped.next() == null);
}

test "tmuxKeyLookup" {
    // Named keys
    const enter = tmuxKeyLookup("Enter").?;
    try std.testing.expectEqual(@as(u32, 0x0024), enter.keycode);
    try std.testing.expectEqual(@as(u32, 0), enter.mods);
    try std.testing.expectEqualStrings("\r", enter.text.?);
    const esc = tmuxKeyLookup("Escape").?;
    try std.testing.expectEqual(@as(u32, 0x0009), esc.keycode);
    try std.testing.expect(esc.text == null);
    // All navigation keys resolve
    const nav_keys = [_][]const u8{ "Up", "Down", "Left", "Right", "Home", "End", "PageUp", "PageDown", "BSpace", "DC", "Tab", "Space" };
    for (nav_keys) |name| try std.testing.expect(tmuxKeyLookup(name) != null);
    // Invalid keys
    try std.testing.expect(tmuxKeyLookup("NotAKey") == null);
    try std.testing.expect(tmuxKeyLookup("") == null);
    // C-<letter>: all 26 keys with correct control byte and modifier
    var letter: u8 = 'a';
    while (letter <= 'z') : (letter += 1) {
        const name = [_]u8{ 'C', '-', letter };
        const k = tmuxKeyLookup(&name).?;
        try std.testing.expectEqual(letter - 'a' + 1, k.text.?[0]);
        try std.testing.expectEqual(c.GHOSTTY_MODS_CTRL, k.mods);
    }
    // Invalid C- patterns
    try std.testing.expect(tmuxKeyLookup("C-A") == null);
    try std.testing.expect(tmuxKeyLookup("C-1") == null);
    try std.testing.expect(tmuxKeyLookup("C-") == null);
}

fn expectDecode(input: []const u8, expected: []const u8) !void {
    const result = percentDecode(input, std.testing.allocator).?;
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(expected, result);
}

test "percentDecode" {
    try expectDecode("%23%7Bpane_id%7D", "#{pane_id}");
    try expectDecode("hello", "hello");
    try expectDecode("hello%20world", "hello world");
    try expectDecode("%23{pane_id}", "#{pane_id}");
    try expectDecode("abc%ZZdef", "abc%ZZdef"); // invalid hex passthrough
    try expectDecode("abc%2", "abc%2"); // truncated percent
    try expectDecode("", "");
    try expectDecode("%23%7Bpane_id%7D%20%23%7Bpane_width%7D", "#{pane_id} #{pane_width}");
    try expectDecode("%41%42%43", "ABC"); // consecutive
    try expectDecode("a+b", "a+b"); // plus not decoded
    try expectDecode("%25", "%"); // encoded percent
}

test "hexDigit" {
    try std.testing.expectEqual(@as(?u8, 0), hexDigit('0'));
    try std.testing.expectEqual(@as(?u8, 9), hexDigit('9'));
    try std.testing.expectEqual(@as(?u8, 5), hexDigit('5'));
    try std.testing.expectEqual(@as(?u8, 10), hexDigit('a'));
    try std.testing.expectEqual(@as(?u8, 15), hexDigit('f'));
    try std.testing.expectEqual(@as(?u8, 10), hexDigit('A'));
    try std.testing.expectEqual(@as(?u8, 15), hexDigit('F'));
    try std.testing.expect(hexDigit('g') == null);
    try std.testing.expect(hexDigit('G') == null);
    try std.testing.expect(hexDigit(' ') == null);
    try std.testing.expect(hexDigit('%') == null);
}

/// Test helper: run interpolateTmuxFormat and return result for comparison.
fn testFmt(format: []const u8, id: u32, w: u32, h: u32, active: u8, pwd: []const u8, title: []const u8) std.ArrayListUnmanaged(u8) {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    interpolateTmuxFormat(&buf, format, id, w, h, active, pwd, title, std.testing.allocator);
    return buf;
}

test "interpolateTmuxFormat" {
    const cases = .{
        // All variable types
        .{ "#{pane_id}", 5, 800, 600, @as(u8, 1), "/home", "shell", "%5" },
        .{ "#{pane_index}", 5, 80, 24, @as(u8, 0), "/", "sh", "5" },
        .{ "#{pane_active}", 1, 80, 24, @as(u8, 1), "/", "sh", "1" },
        .{ "#{pane_active}", 1, 80, 24, @as(u8, 0), "/", "sh", "0" },
        .{ "#{pane_width}x#{pane_height}", 1, 800, 600, @as(u8, 0), "/home", "shell", "800x600" },
        .{ "#{pane_current_path}", 1, 80, 24, @as(u8, 0), "/home/user", "sh", "/home/user" },
        .{ "#{pane_title}", 1, 80, 24, @as(u8, 0), "/", "vim", "vim" },
        .{ "#{pane_current_command}", 1, 80, 24, @as(u8, 0), "/", "vim", "vim" },
        // Edge cases
        .{ "a#{foo}b", 1, 80, 24, @as(u8, 0), "/", "sh", "ab" },
        .{ "#{pane_id", 5, 80, 24, @as(u8, 0), "/", "sh", "#{pane_id" },
        .{ "id=#{pane_id} w=#{pane_width}", 5, 800, 600, @as(u8, 1), "/", "sh", "id=%5 w=800" },
        .{ "", 1, 80, 24, @as(u8, 0), "/", "sh", "" },
        .{ "hello world", 1, 80, 24, @as(u8, 0), "/", "sh", "hello world" },
    };
    inline for (cases) |tc| {
        var buf = testFmt(tc[0], tc[1], tc[2], tc[3], tc[4], tc[5], tc[6]);
        defer buf.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(tc[7], buf.items);
    }
}
