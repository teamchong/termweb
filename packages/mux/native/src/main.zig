const std = @import("std");
const ws = @import("ws_server.zig");
const http = @import("http_server.zig");
const transfer = @import("transfer.zig");
const auth = @import("auth.zig");
const zip = @import("zip.zig");

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
    partial_delta = 0x04, // Uncompressed partial diff with offset
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

// ============================================================================
// Control Channel Protocol (Binary + JSON fallback)
// ============================================================================

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

    // Auth/Session Server → Client (0x0A-0x0F)
    auth_state = 0x0A,      // Current auth state (role, sessions, tokens)
    session_list = 0x0B,    // List of sessions
    share_links = 0x0C,     // List of active share links

    // Client → Server (0x80-0x8F)
    close_panel = 0x81,
    resize_panel = 0x82,
    focus_panel = 0x83,
    split_panel = 0x84,
    inspector_subscribe = 0x85,
    inspector_unsubscribe = 0x86,
    inspector_tab = 0x87,
    view_action = 0x88,

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

// Control message types (text/JSON - legacy)
pub const ControlMsgType = enum {
    // Server → Client
    panel_list,      // List of all panels
    panel_created,   // New panel created
    panel_closed,    // Panel was closed
    panel_title,     // Panel title changed
    panel_pwd,       // Panel working directory changed
    panel_bell,      // Bell notification
    layout_update,   // Split layout changed

    // Client → Server
    create_panel,    // Request new panel
    close_panel,     // Close a panel
    focus_panel,     // Set active panel
    split_panel,     // Split current panel
    create_tab,      // Create new tab
    close_tab,       // Close a tab
};

// ============================================================================
// Layout Management (persisted to disk)
// ============================================================================

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
};

pub const Layout = struct {
    tabs: std.ArrayListUnmanaged(*Tab),
    active_tab_id: u32,
    next_tab_id: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Layout {
        return .{
            .tabs = .{},
            .active_tab_id = 0,
            .next_tab_id = 1,
            .allocator = allocator,
        };
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
        self.active_tab_id = tab.id;
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
            try writer.print("{{\"id\":{},\"root\":", .{tab.id});
            try writeNodeJson(writer, tab.root);
            try writer.writeAll("}");
        }
        try writer.print("],\"activeTabId\":{}}}", .{self.active_tab_id});

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

const IOSurfacePtr = *c.struct___IOSurface;

// ============================================================================
// Frame Buffer for XOR diff
// ============================================================================

const FrameStats = struct {
    changed_bytes: usize,
};

const FrameBuffer = struct {
    rgba_current: []u8,    // Raw BGRA from IOSurface
    rgba_previous: []u8,   // Previous BGRA for fast comparison
    rgb_current: []u8,     // Converted RGB (3 bytes per pixel) - used for keyframes
    rgb_previous: []u8,    // Previous frame RGB - updated in-place
    diff: []u8,            // XOR diff
    compressed: []u8,      // Compressed output
    width: u32,
    height: u32,
    allocator: std.mem.Allocator,
    // Background color for alpha blending (RGB)
    bg_r: u8,
    bg_g: u8,
    bg_b: u8,
    // Zero-copy optimization: track dirty region from last frame
    last_dirty_start: usize,
    last_dirty_end: usize,

    fn init(allocator: std.mem.Allocator, width: u32, height: u32) !FrameBuffer {
        const rgba_size = width * height * 4;
        const rgb_size = width * height * 3;
        const compressed_max = rgb_size + 1024;

        const diff = try allocator.alloc(u8, rgb_size);
        @memset(diff, 0); // Zero-initialize diff buffer

        return .{
            .rgba_current = try allocator.alloc(u8, rgba_size),
            .rgba_previous = try allocator.alloc(u8, rgba_size),
            .rgb_current = try allocator.alloc(u8, rgb_size),
            .rgb_previous = try allocator.alloc(u8, rgb_size),
            .diff = diff,
            .compressed = try allocator.alloc(u8, compressed_max),
            .width = width,
            .height = height,
            .allocator = allocator,
            .bg_r = 0x28,  // Default background (from ghostty config)
            .bg_g = 0x2c,
            .bg_b = 0x34,
            .last_dirty_start = 0,
            .last_dirty_end = rgb_size, // Force full clear on first delta
        };
    }

    fn deinit(self: *FrameBuffer) void {
        self.allocator.free(self.rgba_current);
        self.allocator.free(self.rgba_previous);
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

    // Convert BGRA to RGB with alpha blending
    fn convertBgraToRgb(self: *FrameBuffer) void {
        const pixel_count = self.width * self.height;
        const bgra = self.rgba_current;
        const rgb = self.rgb_current;
        const bg_r = self.bg_r;
        const bg_g = self.bg_g;
        const bg_b = self.bg_b;

        // Process 8 pixels at a time for SIMD
        const Vec8 = @Vector(8, u16);
        const vec_bg_r: Vec8 = @splat(@as(u16, bg_r));
        const vec_bg_g: Vec8 = @splat(@as(u16, bg_g));
        const vec_bg_b: Vec8 = @splat(@as(u16, bg_b));
        const vec_255: Vec8 = @splat(@as(u16, 255));

        var i: usize = 0;
        while (i + 8 <= pixel_count) : (i += 8) {
            // Check if all 8 pixels are fully opaque (fast path)
            var all_opaque = true;
            inline for (0..8) |j| {
                if (bgra[(i + j) * 4 + 3] != 255) {
                    all_opaque = false;
                    break;
                }
            }

            if (all_opaque) {
                // Fast path: no alpha blending needed
                inline for (0..8) |j| {
                    const src = (i + j) * 4;
                    const dst = (i + j) * 3;
                    rgb[dst + 0] = bgra[src + 2]; // R
                    rgb[dst + 1] = bgra[src + 1]; // G
                    rgb[dst + 2] = bgra[src + 0]; // B
                }
            } else {
                // Slow path: alpha blend with SIMD
                var r: Vec8 = undefined;
                var g: Vec8 = undefined;
                var b: Vec8 = undefined;
                var a: Vec8 = undefined;

                inline for (0..8) |j| {
                    const src = (i + j) * 4;
                    b[j] = bgra[src + 0];
                    g[j] = bgra[src + 1];
                    r[j] = bgra[src + 2];
                    a[j] = bgra[src + 3];
                }

                // Alpha blend: result = (fg * a + bg * (255 - a)) / 255
                const inv_a = vec_255 - a;
                const blended_r = (r * a + vec_bg_r * inv_a) / vec_255;
                const blended_g = (g * a + vec_bg_g * inv_a) / vec_255;
                const blended_b = (b * a + vec_bg_b * inv_a) / vec_255;

                inline for (0..8) |j| {
                    const dst = (i + j) * 3;
                    rgb[dst + 0] = @truncate(blended_r[j]);
                    rgb[dst + 1] = @truncate(blended_g[j]);
                    rgb[dst + 2] = @truncate(blended_b[j]);
                }
            }
        }

        // Handle remaining pixels
        while (i < pixel_count) : (i += 1) {
            const src = i * 4;
            const dst = i * 3;
            const a = bgra[src + 3];

            if (a == 255) {
                rgb[dst + 0] = bgra[src + 2];
                rgb[dst + 1] = bgra[src + 1];
                rgb[dst + 2] = bgra[src + 0];
            } else {
                const inv_a = 255 - @as(u16, a);
                const aa = @as(u16, a);
                rgb[dst + 0] = @truncate((@as(u16, bgra[src + 2]) * aa + @as(u16, bg_r) * inv_a) / 255);
                rgb[dst + 1] = @truncate((@as(u16, bgra[src + 1]) * aa + @as(u16, bg_g) * inv_a) / 255);
                rgb[dst + 2] = @truncate((@as(u16, bgra[src + 0]) * aa + @as(u16, bg_b) * inv_a) / 255);
            }
        }
    }

    fn computeDiff(self: *FrameBuffer) FrameStats {
        const VecSize = 32; // 256-bit vectors (AVX2/NEON friendly)
        const Vec = @Vector(VecSize, u8);

        const current = self.rgb_current;
        const prev = self.rgb_previous;
        const diff_buf = self.diff;
        const len = current.len;

        var changed_chunks: usize = 0;
        var i: usize = 0;

        // Vectorized loop - XOR 32 bytes at a time in CPU registers
        while (i + VecSize <= len) : (i += VecSize) {
            const v_curr: Vec = current[i..][0..VecSize].*;
            const v_prev: Vec = prev[i..][0..VecSize].*;

            // XOR in one instruction
            const v_diff = v_curr ^ v_prev;

            // Store result
            diff_buf[i..][0..VecSize].* = v_diff;

            // Fast check: count chunks with any changes (for threshold logic)
            // @reduce(.Or) collapses vector to check if ANY byte differs
            if (@reduce(.Or, v_diff) != 0) {
                changed_chunks += 1;
            }
        }

        // Handle remaining bytes
        while (i < len) : (i += 1) {
            const diff_val = current[i] ^ prev[i];
            diff_buf[i] = diff_val;
            if (diff_val != 0) changed_chunks += 1;
        }

        // Convert chunk count to approximate byte count for threshold logic
        // (each chunk represents up to VecSize changed bytes)
        return FrameStats{ .changed_bytes = changed_chunks * VecSize };
    }

    /// Fast diff computation - only scans around previous dirty region
    fn computeDiffZeroCopy(self: *FrameBuffer) FrameStats {
        const bgra_curr = self.rgba_current;
        const bgra_prev = self.rgba_previous;

        // Fast check: if nothing changed, exit immediately
        if (std.mem.eql(u8, bgra_curr, bgra_prev)) {
            return FrameStats{ .changed_bytes = 0 };
        }

        const rgb_prev = self.rgb_previous;
        const diff_buf = self.diff;
        const pixel_count = self.width * self.height;
        const bg_r = self.bg_r;
        const bg_g = self.bg_g;
        const bg_b = self.bg_b;

        // Clear only the region we dirtied last frame
        if (self.last_dirty_end > self.last_dirty_start) {
            @memset(diff_buf[self.last_dirty_start..self.last_dirty_end], 0);
        }

        var dirty_start: usize = pixel_count * 3;
        var dirty_end: usize = 0;
        var changed_bytes: usize = 0;

        const BlockSize = 4096;
        const pixels_per_block = BlockSize / 4;
        const num_blocks = (pixel_count * 4) / BlockSize;

        // Process ALL blocks (SIMD eql is fast for unchanged blocks)
        var block: usize = 0;
        while (block < num_blocks) : (block += 1) {
            const block_start = block * BlockSize;
            const block_end = block_start + BlockSize;

            if (std.mem.eql(u8, bgra_curr[block_start..block_end], bgra_prev[block_start..block_end])) {
                continue;
            }

            // Block changed - process its 16 pixels
            const pixel_start = block * pixels_per_block;
            const pixel_end = pixel_start + pixels_per_block;

            for (pixel_start..pixel_end) |i| {
                const bgra_idx = i * 4;
                const rgb_idx = i * 3;

                const curr_b = bgra_curr[bgra_idx + 0];
                const curr_g = bgra_curr[bgra_idx + 1];
                const curr_r = bgra_curr[bgra_idx + 2];
                const curr_a = bgra_curr[bgra_idx + 3];

                const prev_b = bgra_prev[bgra_idx + 0];
                const prev_g = bgra_prev[bgra_idx + 1];
                const prev_r = bgra_prev[bgra_idx + 2];
                const prev_a = bgra_prev[bgra_idx + 3];

                // Skip unchanged pixels within the block
                if (curr_b == prev_b and curr_g == prev_g and curr_r == prev_r and curr_a == prev_a) {
                    continue;
                }

                // Convert current BGRA to RGB
                var new_r: u8 = undefined;
                var new_g: u8 = undefined;
                var new_b: u8 = undefined;
                if (curr_a == 255) {
                    new_r = curr_r;
                    new_g = curr_g;
                    new_b = curr_b;
                } else {
                    const a16 = @as(u16, curr_a);
                    const inv_a = 255 - a16;
                    new_r = @truncate(((@as(u16, curr_r) * a16) + (@as(u16, bg_r) * inv_a)) / 255);
                    new_g = @truncate(((@as(u16, curr_g) * a16) + (@as(u16, bg_g) * inv_a)) / 255);
                    new_b = @truncate(((@as(u16, curr_b) * a16) + (@as(u16, bg_b) * inv_a)) / 255);
                }

                // Convert previous BGRA to RGB
                var old_r: u8 = undefined;
                var old_g: u8 = undefined;
                var old_b: u8 = undefined;
                if (prev_a == 255) {
                    old_r = prev_r;
                    old_g = prev_g;
                    old_b = prev_b;
                } else {
                    const a16 = @as(u16, prev_a);
                    const inv_a = 255 - a16;
                    old_r = @truncate(((@as(u16, prev_r) * a16) + (@as(u16, bg_r) * inv_a)) / 255);
                    old_g = @truncate(((@as(u16, prev_g) * a16) + (@as(u16, bg_g) * inv_a)) / 255);
                    old_b = @truncate(((@as(u16, prev_b) * a16) + (@as(u16, bg_b) * inv_a)) / 255);
                }

                // Compute XOR diff
                diff_buf[rgb_idx + 0] = new_r ^ old_r;
                diff_buf[rgb_idx + 1] = new_g ^ old_g;
                diff_buf[rgb_idx + 2] = new_b ^ old_b;

                // Update rgb_previous in-place
                rgb_prev[rgb_idx + 0] = new_r;
                rgb_prev[rgb_idx + 1] = new_g;
                rgb_prev[rgb_idx + 2] = new_b;

                // Track dirty region
                if (rgb_idx < dirty_start) dirty_start = rgb_idx;
                if (rgb_idx + 3 > dirty_end) dirty_end = rgb_idx + 3;
                changed_bytes += 3;
            }
        }

        // Handle remaining pixels (if frame size not divisible by 16)
        const remaining_start = num_blocks * pixels_per_block;
        for (remaining_start..pixel_count) |i| {
            const bgra_idx = i * 4;
            const rgb_idx = i * 3;

            const curr_b = bgra_curr[bgra_idx + 0];
            const curr_g = bgra_curr[bgra_idx + 1];
            const curr_r = bgra_curr[bgra_idx + 2];
            const curr_a = bgra_curr[bgra_idx + 3];

            const prev_b = bgra_prev[bgra_idx + 0];
            const prev_g = bgra_prev[bgra_idx + 1];
            const prev_r = bgra_prev[bgra_idx + 2];
            const prev_a = bgra_prev[bgra_idx + 3];

            if (curr_b == prev_b and curr_g == prev_g and curr_r == prev_r and curr_a == prev_a) {
                continue;
            }

            var new_r: u8 = undefined;
            var new_g: u8 = undefined;
            var new_b: u8 = undefined;
            if (curr_a == 255) {
                new_r = curr_r;
                new_g = curr_g;
                new_b = curr_b;
            } else {
                const a16 = @as(u16, curr_a);
                const inv_a = 255 - a16;
                new_r = @truncate(((@as(u16, curr_r) * a16) + (@as(u16, bg_r) * inv_a)) / 255);
                new_g = @truncate(((@as(u16, curr_g) * a16) + (@as(u16, bg_g) * inv_a)) / 255);
                new_b = @truncate(((@as(u16, curr_b) * a16) + (@as(u16, bg_b) * inv_a)) / 255);
            }

            var old_r: u8 = undefined;
            var old_g: u8 = undefined;
            var old_b: u8 = undefined;
            if (prev_a == 255) {
                old_r = prev_r;
                old_g = prev_g;
                old_b = prev_b;
            } else {
                const a16 = @as(u16, prev_a);
                const inv_a = 255 - a16;
                old_r = @truncate(((@as(u16, prev_r) * a16) + (@as(u16, bg_r) * inv_a)) / 255);
                old_g = @truncate(((@as(u16, prev_g) * a16) + (@as(u16, bg_g) * inv_a)) / 255);
                old_b = @truncate(((@as(u16, prev_b) * a16) + (@as(u16, bg_b) * inv_a)) / 255);
            }

            diff_buf[rgb_idx + 0] = new_r ^ old_r;
            diff_buf[rgb_idx + 1] = new_g ^ old_g;
            diff_buf[rgb_idx + 2] = new_b ^ old_b;

            rgb_prev[rgb_idx + 0] = new_r;
            rgb_prev[rgb_idx + 1] = new_g;
            rgb_prev[rgb_idx + 2] = new_b;

            if (rgb_idx < dirty_start) dirty_start = rgb_idx;
            if (rgb_idx + 3 > dirty_end) dirty_end = rgb_idx + 3;
            changed_bytes += 3;
        }

        self.last_dirty_start = dirty_start;
        self.last_dirty_end = dirty_end;

        return FrameStats{ .changed_bytes = changed_bytes };
    }

    fn swapBuffers(self: *FrameBuffer) void {
        const tmp = self.rgb_previous;
        self.rgb_previous = self.rgb_current;
        self.rgb_current = tmp;
    }

    fn swapRgbaBuffers(self: *FrameBuffer) void {
        const tmp = self.rgba_previous;
        self.rgba_previous = self.rgba_current;
        self.rgba_current = tmp;
    }

    // Fast check if RGBA buffer changed (runs at memory-read speed, stops at first difference)
    fn rgbaChanged(self: *FrameBuffer) bool {
        return !std.mem.eql(u8, self.rgba_current, self.rgba_previous);
    }
};

// ============================================================================
// Compressor
// ============================================================================

const Compressor = struct {
    compressor: *c.libdeflate_compressor,

    fn init(level: c_int) !Compressor {
        const comp = c.libdeflate_alloc_compressor(level) orelse return error.CompressorInitFailed;
        return .{ .compressor = comp };
    }

    fn deinit(self: *Compressor) void {
        c.libdeflate_free_compressor(self.compressor);
    }

    fn compress(self: *const Compressor, input: []const u8, output: []u8) !usize {
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

// ============================================================================
// Panel - One ghostty surface + streamer + websocket connection
// ============================================================================

const Panel = struct {
    id: u32,
    surface: c.ghostty_surface_t,
    nsview: objc.id,
    window: objc.id,
    frame_buffer: FrameBuffer,
    compressor_fast: Compressor, // Level 1 for video/scrolling
    compressor_best: Compressor, // Level 6 for text/idle
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
    title: []const u8,  // Last known title
    pwd: []const u8,    // Last known working directory
    inspector_subscribed: bool,
    inspector_tab: [16]u8,
    inspector_tab_len: u8,
    last_iosurface_seed: u32, // For detecting IOSurface changes without copying
    last_delta_time: i64, // For adaptive FPS
    last_input_time: i64, // Track input for responsive typing

    const KEYFRAME_INTERVAL_MS = 60000; // 60 seconds
    const CURSOR_FPS: i64 = 15;
    const ACTIVE_FPS: i64 = 60;

    fn init(allocator: std.mem.Allocator, app: c.ghostty_app_t, id: u32, width: u32, height: u32, scale: f64) !*Panel {
        const panel = try allocator.create(Panel);
        errdefer allocator.destroy(panel);

        // Create window at point dimensions (CSS pixels from browser)
        // The layer's contentsScale handles retina rendering
        const window_view = createHiddenWindow(width, height) orelse return error.WindowCreationFailed;

        // Make view layer-backed for Metal rendering and set contentsScale for retina
        makeViewLayerBacked(window_view.view, scale);

        var surface_config = c.ghostty_surface_config_new();
        surface_config.platform_tag = c.GHOSTTY_PLATFORM_MACOS;
        surface_config.platform.macos.nsview = @ptrCast(window_view.view);
        // Use actual scale factor - ghostty will render at retina resolution
        surface_config.scale_factor = scale;
        // Set userdata to panel pointer for clipboard callbacks
        surface_config.userdata = panel;
        // Use default shell (null = user's shell from /etc/passwd)
        surface_config.command = null;
        surface_config.working_directory = null;

        const surface = c.ghostty_surface_new(app, &surface_config);
        if (surface == null) return error.SurfaceCreationFailed;
        errdefer c.ghostty_surface_free(surface);

        // Focus the surface so it accepts input
        c.ghostty_surface_set_focus(surface, true);

        // Frame buffer is at pixel dimensions (width * scale, height * scale)
        const pixel_width: u32 = @intFromFloat(@as(f64, @floatFromInt(width)) * scale);
        const pixel_height: u32 = @intFromFloat(@as(f64, @floatFromInt(height)) * scale);

        // Set size in pixels - ghostty creates IOSurface at this size
        c.ghostty_surface_set_size(surface, pixel_width, pixel_height);

        panel.* = .{
            .id = id,
            .surface = surface,
            .nsview = window_view.view,
            .window = window_view.window,
            .frame_buffer = try FrameBuffer.init(allocator, pixel_width, pixel_height),
            .compressor_fast = try Compressor.init(1), // Level 1 for video/scrolling
            .compressor_best = try Compressor.init(6), // Level 6 for text/idle
            .sequence = 0,
            .last_keyframe = 0,
            .width = width,       // Store point dimensions
            .height = height,     // Store point dimensions
            .scale = scale,
            .streaming = std.atomic.Value(bool).init(false), // Start paused until connected
            .force_keyframe = true,
            .connection = null,
            .allocator = allocator,
            .mutex = .{},
            .input_queue = .{},
            .title = &.{},
            .pwd = &.{},
            .inspector_subscribed = false,
            .inspector_tab = undefined,
            .inspector_tab_len = 0,
            .last_iosurface_seed = 0,
            .last_delta_time = 0,
            .last_input_time = 0,
        };

        return panel;
    }

    fn deinit(self: *Panel) void {
        c.ghostty_surface_free(self.surface);
        self.frame_buffer.deinit();
        self.compressor_fast.deinit();
        self.compressor_best.deinit();
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
        } else {
            self.streaming.store(false, .release);
        }
    }

    // Internal resize - called from main thread only (via processInputQueue)
    // width/height are in CSS pixels (points)
    fn resizeInternal(self: *Panel, width: u32, height: u32) !void {
        // Skip if size hasn't changed to avoid unnecessary terminal reflow
        if (self.width == width and self.height == height) return;

        self.width = width;
        self.height = height;

        // Resize the NSWindow and NSView at point dimensions
        resizeWindow(self.window, width, height);

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
    fn captureFromIOSurface(self: *Panel, iosurface: IOSurfacePtr) !bool {
        // Check IOSurface seed - if unchanged, surface wasn't modified, skip copy entirely
        const seed = c.IOSurfaceGetSeed(iosurface);
        if (seed == self.last_iosurface_seed and !self.force_keyframe) {
            return false; // Surface unchanged, skip 14MB copy
        }
        self.last_iosurface_seed = seed;

        _ = c.IOSurfaceLock(iosurface, c.kIOSurfaceLockReadOnly, null);
        defer _ = c.IOSurfaceUnlock(iosurface, c.kIOSurfaceLockReadOnly, null);

        const base_addr: ?[*]u8 = @ptrCast(c.IOSurfaceGetBaseAddress(iosurface));
        if (base_addr == null) return error.NoBaseAddress;

        const src_bytes_per_row = c.IOSurfaceGetBytesPerRow(iosurface);
        const surf_width = c.IOSurfaceGetWidth(iosurface);
        const surf_height = c.IOSurfaceGetHeight(iosurface);

        try self.frame_buffer.resize(@intCast(surf_width), @intCast(surf_height));

        // Copy BGRA data - single memcpy if strides match, row-by-row otherwise
        const dst_bytes_per_row = self.frame_buffer.width * 4;
        if (src_bytes_per_row == dst_bytes_per_row) {
            // Fast path: single memcpy for the entire surface
            const total_bytes = surf_height * dst_bytes_per_row;
            @memcpy(
                self.frame_buffer.rgba_current[0..total_bytes],
                base_addr.?[0..total_bytes],
            );
        } else {
            // Slow path: row by row (different stride)
            for (0..surf_height) |y| {
                const src_offset = y * src_bytes_per_row;
                const dst_offset = y * dst_bytes_per_row;
                const copy_len = @min(dst_bytes_per_row, src_bytes_per_row);
                @memcpy(
                    self.frame_buffer.rgba_current[dst_offset..][0..copy_len],
                    base_addr.?[src_offset..][0..copy_len],
                );
            }
        }

        return true;
    }

    fn prepareFrame(self: *Panel) !?struct { data: []u8, is_keyframe: bool } {
        const now = std.time.milliTimestamp();
        const need_keyframe = self.force_keyframe or
            (now - self.last_keyframe >= KEYFRAME_INTERVAL_MS) or
            self.sequence == 0;

        var data_to_compress: []u8 = undefined;
        var is_keyframe: bool = undefined;
        var compressor: *const Compressor = undefined;

        if (need_keyframe) {
            // Keyframe: Convert full BGRA to RGB (unavoidable for keyframes)
            self.frame_buffer.convertBgraToRgb();
            data_to_compress = self.frame_buffer.rgb_current;
            is_keyframe = true;
            compressor = &self.compressor_best;
            self.last_keyframe = now;
            self.force_keyframe = false;
        } else {
            // Adaptive FPS: Use lower FPS when idle (cursor blink), higher when active
            const time_since_input = now - self.last_input_time;
            const target_fps: i64 = if (time_since_input < 100) ACTIVE_FPS else CURSOR_FPS;
            const frame_interval_ms: i64 = @divFloor(1000, target_fps);
            const time_since_delta = now - self.last_delta_time;

            if (time_since_delta < frame_interval_ms) {
                // Not time for next frame yet, skip
                return null;
            }
            self.last_delta_time = now;

            // Delta frame: Use zero-copy diff (fused compare + convert + diff)
            // This only writes to memory where pixels actually changed
            const stats = self.frame_buffer.computeDiffZeroCopy();

            // Early exit if no changes
            if (stats.changed_bytes == 0) {
                // Swap RGBA buffers for next frame comparison
                self.frame_buffer.swapRgbaBuffers();
                return null;
            }

            // Check if dirty region is small enough for uncompressed partial delta
            const dirty_start = self.frame_buffer.last_dirty_start;
            const dirty_end = self.frame_buffer.last_dirty_end;
            const dirty_size = dirty_end - dirty_start;

            // Use partial_delta (uncompressed) for small changes (<500KB)
            // Avoids 37ms compression overhead
            if (dirty_size < 500_000) {
                // Header: frame_type(1) + sequence(4) + width(2) + height(2) + offset(4) + length(4) = 17 bytes
                const header_size: usize = 17;
                const buf = self.frame_buffer.compressed;
                buf[0] = @intFromEnum(FrameType.partial_delta);
                std.mem.writeInt(u32, buf[1..5], self.sequence, .little);
                std.mem.writeInt(u16, buf[5..7], @intCast(self.frame_buffer.width), .little);
                std.mem.writeInt(u16, buf[7..9], @intCast(self.frame_buffer.height), .little);
                std.mem.writeInt(u32, buf[9..13], @intCast(dirty_start), .little);
                std.mem.writeInt(u32, buf[13..17], @intCast(dirty_size), .little);

                // Copy uncompressed dirty region
                @memcpy(buf[header_size..][0..dirty_size], self.frame_buffer.diff[dirty_start..dirty_end]);

                self.sequence +%= 1;
                self.frame_buffer.swapRgbaBuffers();

                return .{
                    .data = buf[0 .. header_size + dirty_size],
                    .is_keyframe = false,
                };
            }

            data_to_compress = self.frame_buffer.diff;
            is_keyframe = false;
            compressor = &self.compressor_fast;
        }

        const header_size: usize = 13;
        const compressed_size = try compressor.compress(
            data_to_compress,
            self.frame_buffer.compressed[header_size..],
        );
        // Write header
        const buf = self.frame_buffer.compressed;
        buf[0] = if (is_keyframe) @intFromEnum(FrameType.keyframe) else @intFromEnum(FrameType.delta);
        std.mem.writeInt(u32, buf[1..5], self.sequence, .little);
        std.mem.writeInt(u16, buf[5..7], @intCast(self.frame_buffer.width), .little);
        std.mem.writeInt(u16, buf[7..9], @intCast(self.frame_buffer.height), .little);
        std.mem.writeInt(u32, buf[9..13], @intCast(compressed_size), .little);

        self.sequence +%= 1;

        // Buffer management after frame:
        // - Keyframe: swap RGB buffers (rgb_current becomes rgb_previous for next diff)
        // - Delta: rgb_previous already updated in-place by computeDiffZeroCopy
        if (is_keyframe) {
            self.frame_buffer.swapBuffers();
            // Reset dirty tracking: next delta must clear entire diff buffer
            self.frame_buffer.last_dirty_start = 0;
            self.frame_buffer.last_dirty_end = self.frame_buffer.diff.len;
        }
        // Always swap RGBA buffers for next frame comparison
        self.frame_buffer.swapRgbaBuffers();

        return .{
            .data = self.frame_buffer.compressed[0 .. header_size + compressed_size],
            .is_keyframe = is_keyframe,
        };
    }

    // Check if there's queued input (non-locking for quick check)
    fn hasQueuedInput(self: *Panel) bool {
        return self.input_queue.items.len > 0;
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
        // Track input time for adaptive FPS
        self.last_input_time = std.time.milliTimestamp();
        // Copy events locally to release mutex quickly
        var events_buf: [256]InputEvent = undefined;
        const events_count = @min(count, events_buf.len);
        @memcpy(events_buf[0..events_count], items[0..events_count]);
        self.input_queue.clearRetainingCapacity();
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

    // Map JS e.code to macOS virtual keycode (ghostty expects macOS keycodes, not its own enum)
    fn mapKeyCode(code: []const u8) u32 {
        // Use comptime string map for efficient lookup - values are macOS virtual keycodes
        const map = std.StaticStringMap(u32).initComptime(.{
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

// Panel split request (to be processed on main thread)
const PanelSplitRequest = struct {
    parent_panel_id: u32,
    direction: SplitDirection,
    width: u32,
    height: u32,
    scale: f64,
};

const Server = struct {
    app: c.ghostty_app_t,
    config: c.ghostty_config_t,
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
    http_server: *http.HttpServer,
    auth_state: *auth.AuthState,  // Session and access control
    transfer_manager: transfer.TransferManager,
    file_connections: std.ArrayList(*ws.Connection),
    running: std.atomic.Value(bool),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    selection_clipboard: ?[]u8,  // Selection clipboard buffer
    inspector_subscriptions: std.ArrayList(InspectorSubscription),

    const InspectorSubscription = struct {
        conn: *ws.Connection,
        panel_id: u32,
        tab: [16]u8 = undefined,
        tab_len: u8 = 0,
    };

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

        // Create HTTP server for static files
        const http_srv = try http.HttpServer.init(allocator, "0.0.0.0", http_port, web_root, config);

        // Create control WebSocket server (for tab list, layout, etc.)
        const control_ws = try ws.Server.init(allocator, "0.0.0.0", control_port);
        control_ws.setCallbacks(onControlConnect, onControlMessage, onControlDisconnect);

        // Create panel WebSocket server (for pixel streams - no deflate, video is pre-compressed)
        const panel_ws = try ws.Server.initNoDeflate(allocator, "0.0.0.0", panel_port);
        panel_ws.setCallbacks(onPanelConnect, onPanelMessage, onPanelDisconnect);

        // Create file WebSocket server (for file transfers - no deflate, we compress manually)
        const file_ws = try ws.Server.initNoDeflate(allocator, "0.0.0.0", 0);
        file_ws.setCallbacks(onFileConnect, onFileMessage, onFileDisconnect);

        // Initialize auth state
        const auth_state = try auth.AuthState.init(allocator);

        server.* = .{
            .app = app,
            .config = config,
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
            .auth_state = auth_state,
            .transfer_manager = transfer.TransferManager.init(allocator),
            .file_connections = .{},
            .running = std.atomic.Value(bool).init(false),
            .allocator = allocator,
            .mutex = .{},
            .selection_clipboard = null,
            .inspector_subscriptions = .{},
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
        self.layout.deinit();
        self.pending_panels.deinit(self.allocator);
        self.pending_destroys.deinit(self.allocator);
        self.pending_resizes.deinit(self.allocator);
        self.pending_splits.deinit(self.allocator);

        self.http_server.deinit();
        self.panel_ws_server.deinit();
        self.control_ws_server.deinit();
        self.file_ws_server.deinit();
        self.auth_state.deinit();
        self.transfer_manager.deinit();
        self.file_connections.deinit(self.allocator);
        self.connection_roles.deinit();
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

        // Add to layout as a new tab (default behavior for new panels)
        _ = self.layout.createTab(id) catch {};

        return panel;
    }

    // Create a panel as a split of an existing panel (doesn't create a new tab)
    fn createPanelAsSplit(self: *Server, width: u32, height: u32, scale: f64, parent_panel_id: u32, direction: SplitDirection) !*Panel {
        self.mutex.lock();
        defer self.mutex.unlock();

        const id = self.next_panel_id;
        self.next_panel_id += 1;

        const panel = try Panel.init(self.allocator, self.app, id, width, height, scale);
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
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.panels.fetchRemove(id)) |entry| {
            entry.value.deinit();
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

        // Send auth state first (so client knows its role)
        self.sendAuthState(conn);

        // Send current panel list
        self.sendPanelList(conn);
    }

    fn onControlMessage(conn: *ws.Connection, data: []u8, is_binary: bool) void {
        const self = global_server orelse return;

        if (is_binary and data.len > 0) {
            const msg_type = data[0];
            if (msg_type >= 0x80 and msg_type <= 0x8F) {
                // Binary control message (client -> server)
                self.handleBinaryControlMessageFromClient(conn, data);
            } else if (msg_type >= 0x90 and msg_type <= 0x9F) {
                // Binary auth message (client -> server)
                self.handleAuthMessage(conn, data);
            } else {
                // Binary file transfer message
                self.handleBinaryControlMessage(conn, data);
            }
        } else {
            // Text message - JSON control message
            self.handleControlMessage(conn, data);
        }
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

        // Remove connection role
        _ = self.connection_roles.remove(conn);

        // Remove any inspector subscriptions for this connection
        var i: usize = 0;
        while (i < self.inspector_subscriptions.items.len) {
            if (self.inspector_subscriptions.items[i].conn == conn) {
                _ = self.inspector_subscriptions.swapRemove(i);
            } else {
                i += 1;
            }
        }
        self.mutex.unlock();
    }

    // ========== Panel WebSocket callbacks ==========

    fn onPanelConnect(conn: *ws.Connection) void {
        _ = conn;
    }

    fn onPanelMessage(conn: *ws.Connection, data: []u8, is_binary: bool) void {
        const self = global_server orelse return;

        // Handle JSON text messages (inspector commands)
        if (!is_binary and data.len > 0 and data[0] == '{') {
            if (conn.user_data) |ud| {
                const panel: *Panel = @ptrCast(@alignCast(ud));
                self.handlePanelInspectorMessage(panel, conn, data);
            }
            return;
        }

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
            panel.setConnection(null);
        }
        self.mutex.unlock();
    }

    fn handlePanelInspectorMessage(self: *Server, panel: *Panel, conn: *ws.Connection, data: []const u8) void {
        if (std.mem.indexOf(u8, data, "\"inspector_subscribe\"")) |_| {
            // Subscribe to inspector updates
            panel.inspector_subscribed = true;

            // Parse tab from message
            if (self.parseJsonString(data, "tab")) |tab| {
                const len = @min(tab.len, panel.inspector_tab.len);
                @memcpy(panel.inspector_tab[0..len], tab[0..len]);
                panel.inspector_tab_len = @intCast(len);
            } else {
                // Default to "screen" tab
                const default_tab = "screen";
                @memcpy(panel.inspector_tab[0..default_tab.len], default_tab);
                panel.inspector_tab_len = default_tab.len;
            }

            // Send initial state
            self.mutex.lock();
            self.sendInspectorStateToPanel(panel, conn);
            self.mutex.unlock();
        } else if (std.mem.indexOf(u8, data, "\"inspector_unsubscribe\"")) |_| {
            panel.inspector_subscribed = false;
        } else if (std.mem.indexOf(u8, data, "\"inspector_tab\"")) |_| {
            // Tab change
            if (self.parseJsonString(data, "tab")) |tab| {
                const len = @min(tab.len, panel.inspector_tab.len);
                @memcpy(panel.inspector_tab[0..len], tab[0..len]);
                panel.inspector_tab_len = @intCast(len);

                // Send state for new tab immediately
                self.mutex.lock();
                self.sendInspectorStateToPanel(panel, conn);
                self.mutex.unlock();
            }
        }
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

    // ========== Control message handling ==========

    fn handleControlMessage(self: *Server, conn: *ws.Connection, data: []const u8) void {
        if (data.len == 0) return;

        // Binary message detection: first byte >= 0x80 indicates client->server binary message
        // JSON always starts with '{' (0x7B) or other printable ASCII
        if (data[0] >= 0x80) {
            self.handleBinaryControlMessageFromClient(conn, data);
            return;
        }

        // JSON fallback - Simple JSON parsing (look for "type" field)
        if (std.mem.indexOf(u8, data, "\"create_panel\"")) |_| {
            // Panels are auto-created when panel WS connects
        } else if (std.mem.indexOf(u8, data, "\"close_panel\"")) |_| {
            if (self.parseJsonInt(data, "panel_id")) |id| {
                self.mutex.lock();
                self.pending_destroys.append(self.allocator, .{ .id = id }) catch {};
                self.mutex.unlock();
            }
        } else if (std.mem.indexOf(u8, data, "\"resize_panel\"")) |_| {
            const id = self.parseJsonInt(data, "panel_id") orelse return;
            const width = self.parseJsonInt(data, "width") orelse return;
            const height = self.parseJsonInt(data, "height") orelse return;
            self.mutex.lock();
            self.pending_resizes.append(self.allocator, .{ .id = id, .width = width, .height = height }) catch {};
            self.mutex.unlock();
        } else if (std.mem.indexOf(u8, data, "\"split_panel\"")) |_| {
            // Split an existing panel
            // {"type":"split_panel","panel_id":1,"direction":"horizontal","width":800,"height":600,"scale":2.0}
            const parent_id = self.parseJsonInt(data, "panel_id") orelse return;
            const width = self.parseJsonInt(data, "width") orelse 800;
            const height = self.parseJsonInt(data, "height") orelse 600;
            const scale = self.parseJsonFloat(data, "scale") orelse 2.0;

            const dir_str = self.parseJsonString(data, "direction") orelse "horizontal";
            const direction: SplitDirection = if (std.mem.eql(u8, dir_str, "vertical")) .vertical else .horizontal;

            self.mutex.lock();
            self.pending_splits.append(self.allocator, .{
                .parent_panel_id = parent_id,
                .direction = direction,
                .width = width,
                .height = height,
                .scale = scale,
            }) catch {};
            self.mutex.unlock();
        } else if (std.mem.indexOf(u8, data, "\"focus_panel\"")) |_| {
            // Client focused a panel - update active tab
            // {"type":"focus_panel","panel_id":1}
            const panel_id = self.parseJsonInt(data, "panel_id") orelse return;
            self.mutex.lock();
            if (self.layout.findTabByPanel(panel_id)) |tab| {
                self.layout.active_tab_id = tab.id;
            }
            self.mutex.unlock();
        } else if (std.mem.indexOf(u8, data, "\"view_action\"")) |_| {
            const id = self.parseJsonInt(data, "panel_id") orelse return;
            const action = self.parseJsonString(data, "action") orelse return;
            self.mutex.lock();
            if (self.panels.get(id)) |panel| {
                self.mutex.unlock();
                _ = c.ghostty_surface_binding_action(panel.surface, action.ptr, action.len);
            } else {
                self.mutex.unlock();
            }
        } else if (std.mem.indexOf(u8, data, "\"inspector_subscribe\"")) |_| {
            const panel_id = self.parseJsonInt(data, "panel_id") orelse return;
            self.subscribeInspector(conn, panel_id, data);
        } else if (std.mem.indexOf(u8, data, "\"inspector_unsubscribe\"")) |_| {
            const panel_id = self.parseJsonInt(data, "panel_id") orelse return;
            self.unsubscribeInspector(conn, panel_id);
        } else if (std.mem.indexOf(u8, data, "\"inspector_tab\"")) |_| {
            const panel_id = self.parseJsonInt(data, "panel_id") orelse return;
            const tab = self.parseJsonString(data, "tab") orelse return;
            self.setInspectorTab(conn, panel_id, tab);
        } else if (std.mem.indexOf(u8, data, "\"file_upload\"")) |_| {
            self.handleFileUpload(conn, data);
        } else if (std.mem.indexOf(u8, data, "\"file_download\"")) |_| {
            self.handleFileDownload(conn, data);
        }
    }

    fn handleBinaryControlMessageFromClient(self: *Server, conn: *ws.Connection, data: []const u8) void {
        if (data.len < 1) return;
        _ = conn;

        const msg_type = data[0];
        if (msg_type == 0x81) { // close_panel
            if (data.len < 5) return;
            const panel_id = std.mem.readInt(u32, data[1..5], .little);
            self.mutex.lock();
            self.pending_destroys.append(self.allocator, .{ .id = panel_id }) catch {};
            self.mutex.unlock();
        } else if (msg_type == 0x82) { // resize_panel
            if (data.len < 9) return;
            const panel_id = std.mem.readInt(u32, data[1..5], .little);
            const width = std.mem.readInt(u16, data[5..7], .little);
            const height = std.mem.readInt(u16, data[7..9], .little);
            self.mutex.lock();
            self.pending_resizes.append(self.allocator, .{ .id = panel_id, .width = width, .height = height }) catch {};
            self.mutex.unlock();
        } else if (msg_type == 0x83) { // focus_panel
            if (data.len < 5) return;
            const panel_id = std.mem.readInt(u32, data[1..5], .little);
            self.mutex.lock();
            if (self.layout.findTabByPanel(panel_id)) |tab| {
                self.layout.active_tab_id = tab.id;
            }
            self.mutex.unlock();
        } else if (msg_type == 0x84) { // split_panel
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
                .parent_panel_id = parent_id,
                .direction = direction,
                .width = width,
                .height = height,
                .scale = scale,
            }) catch {};
            self.mutex.unlock();
        } else if (msg_type == 0x85) { // inspector_subscribe
            if (data.len < 6) return;
            const panel_id = std.mem.readInt(u32, data[1..5], .little);
            const tab_len = data[5];
            if (data.len < 6 + tab_len) return;
            const tab = data[6..][0..tab_len];
            self.subscribeInspectorBinary(panel_id, tab);
        } else if (msg_type == 0x86) { // inspector_unsubscribe
            if (data.len < 5) return;
            const panel_id = std.mem.readInt(u32, data[1..5], .little);
            self.unsubscribeInspectorBinary(panel_id);
        } else if (msg_type == 0x87) { // inspector_tab
            if (data.len < 6) return;
            const panel_id = std.mem.readInt(u32, data[1..5], .little);
            const tab_len = data[5];
            if (data.len < 6 + tab_len) return;
            const tab = data[6..][0..tab_len];
            self.setInspectorTabBinary(panel_id, tab);
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
        } else {
            std.log.warn("Unknown binary control message type: 0x{x:0>2}", .{msg_type});
        }
    }

    // ========== Auth/Session Message Handlers ==========

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

    fn subscribeInspectorBinary(self: *Server, panel_id: u32, tab: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.panels.get(panel_id)) |panel| {
            panel.inspector_subscribed = true;
            const len = @min(tab.len, panel.inspector_tab.len);
            @memcpy(panel.inspector_tab[0..len], tab[0..len]);
            panel.inspector_tab_len = @intCast(len);
        }
    }

    fn unsubscribeInspectorBinary(self: *Server, panel_id: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.panels.get(panel_id)) |panel| {
            panel.inspector_subscribed = false;
        }
    }

    fn setInspectorTabBinary(self: *Server, panel_id: u32, tab: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.panels.get(panel_id)) |panel| {
            const len = @min(tab.len, panel.inspector_tab.len);
            @memcpy(panel.inspector_tab[0..len], tab[0..len]);
            panel.inspector_tab_len = @intCast(len);
        }
    }

    fn subscribeInspector(self: *Server, conn: *ws.Connection, panel_id: u32, data: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if already subscribed
        for (self.inspector_subscriptions.items) |sub| {
            if (sub.conn == conn and sub.panel_id == panel_id) return;
        }

        var sub = InspectorSubscription{ .conn = conn, .panel_id = panel_id };

        // Parse tab from data
        if (self.parseJsonString(data, "tab")) |tab| {
            const len = @min(tab.len, sub.tab.len);
            @memcpy(sub.tab[0..len], tab[0..len]);
            sub.tab_len = @intCast(len);
        }

        self.inspector_subscriptions.append(self.allocator, sub) catch return;

        // Send initial state immediately
        self.sendInspectorStateUnlocked(conn, panel_id, sub.tab[0..sub.tab_len]);
    }

    fn unsubscribeInspector(self: *Server, conn: *ws.Connection, panel_id: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = 0;
        while (i < self.inspector_subscriptions.items.len) {
            const sub = self.inspector_subscriptions.items[i];
            if (sub.conn == conn and sub.panel_id == panel_id) {
                _ = self.inspector_subscriptions.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    fn setInspectorTab(self: *Server, conn: *ws.Connection, panel_id: u32, tab: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.inspector_subscriptions.items) |*sub| {
            if (sub.conn == conn and sub.panel_id == panel_id) {
                const len = @min(tab.len, sub.tab.len);
                @memcpy(sub.tab[0..len], tab[0..len]);
                sub.tab_len = @intCast(len);

                // Send state for new tab immediately
                self.sendInspectorStateUnlocked(conn, panel_id, tab);
                return;
            }
        }
    }

    // Binary control message handler
    // 0x10 = file_upload, 0x11 = file_download, 0x14 = folder_download (zip)
    // 0x81-0x88 = client control messages (close, resize, focus, split, etc.)
    fn handleBinaryControlMessage(self: *Server, conn: *ws.Connection, data: []const u8) void {
        if (data.len < 1) return;

        const msg_type = data[0];
        switch (msg_type) {
            // File transfer
            0x10 => self.handleBinaryFileUpload(conn, data[1..]),
            0x11 => self.handleBinaryFileDownload(conn, data[1..]),
            0x14 => self.handleBinaryFolderDownload(conn, data[1..]),
            // Client control messages
            0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88 => {
                self.handleBinaryControlMessageFromClient(conn, data);
            },
            else => std.log.warn("Unknown binary control message type: 0x{x:0>2}", .{msg_type}),
        }
    }

    // Binary file upload: [panel_id:u32][name_len:u16][name][compressed_data]
    fn handleBinaryFileUpload(self: *Server, conn: *ws.Connection, data: []const u8) void {
        if (data.len < 6) {
            self.sendBinaryFileError(conn, "Invalid message");
            return;
        }

        const panel_id = std.mem.readInt(u32, data[0..4], .little);
        const name_len = std.mem.readInt(u16, data[4..6], .little);

        if (data.len < 6 + name_len) {
            self.sendBinaryFileError(conn, "Invalid message");
            return;
        }

        const filename = data[6 .. 6 + name_len];
        const compressed_data = data[6 + name_len ..];

        // Get panel's cwd
        self.mutex.lock();
        const panel = self.panels.get(panel_id);
        self.mutex.unlock();

        if (panel == null) {
            self.sendBinaryFileError(conn, "Panel not found");
            return;
        }

        const cwd = panel.?.pwd;
        if (cwd.len == 0) {
            self.sendBinaryFileError(conn, "No working directory");
            return;
        }

        // Build full path
        var path_buf: [4096]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ cwd, filename }) catch {
            self.sendBinaryFileError(conn, "Path too long");
            return;
        };

        // Decompress with libdeflate
        const decompressor = c.libdeflate_alloc_decompressor() orelse {
            self.sendBinaryFileError(conn, "Decompressor init failed");
            return;
        };
        defer c.libdeflate_free_decompressor(decompressor);

        // Allocate buffer for decompressed data (use 100x ratio for text files)
        const max_decompressed = @max(compressed_data.len * 100, 1024 * 1024);
        const capped = @min(max_decompressed, 100 * 1024 * 1024);
        const decompressed = self.allocator.alloc(u8, capped) catch {
            self.sendBinaryFileError(conn, "Out of memory");
            return;
        };
        defer self.allocator.free(decompressed);

        var actual_size: usize = 0;
        const result = c.libdeflate_deflate_decompress(
            decompressor,
            compressed_data.ptr,
            compressed_data.len,
            decompressed.ptr,
            decompressed.len,
            &actual_size,
        );

        // 0=SUCCESS, 1=BAD_DATA, 2=SHORT_OUTPUT, 3=INSUFFICIENT_SPACE
        if (result != 0) {
            std.log.err("Upload decompression failed: result={d}, compressed_size={d}", .{ result, compressed_data.len });
            const err_msg = switch (result) {
                1 => "Upload failed: corrupted data",
                2 => "Upload failed: incomplete data",
                3 => "Upload failed: file too large",
                else => "Upload failed: decompression error",
            };
            self.sendBinaryFileError(conn, err_msg);
            return;
        }

        // Create parent directories if needed (for folder uploads)
        if (std.mem.lastIndexOfScalar(u8, full_path, '/')) |last_slash| {
            const dir_path = full_path[0..last_slash];
            std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
                error.PathAlreadyExists => {}, // Directory exists, that's fine
                else => {
                    // Try recursive mkdir
                    var i: usize = 0;
                    while (i < dir_path.len) {
                        if (std.mem.indexOfScalarPos(u8, dir_path, i + 1, '/')) |next_slash| {
                            std.fs.makeDirAbsolute(dir_path[0..next_slash]) catch |e| switch (e) {
                                error.PathAlreadyExists => {},
                                else => {},
                            };
                            i = next_slash;
                        } else {
                            std.fs.makeDirAbsolute(dir_path) catch |e| switch (e) {
                                error.PathAlreadyExists => {},
                                else => {
                                    self.sendBinaryFileError(conn, "Cannot create directory");
                                    return;
                                },
                            };
                            break;
                        }
                    }
                },
            };
        }

        // Write file
        const file = std.fs.createFileAbsolute(full_path, .{}) catch {
            self.sendBinaryFileError(conn, "Cannot create file");
            return;
        };
        defer file.close();

        file.writeAll(decompressed[0..actual_size]) catch {
            self.sendBinaryFileError(conn, "Write failed");
            return;
        };

        // Send success (use simple JSON for success since it's small)
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{{\"type\":\"file_upload_result\",\"filename\":\"{s}\",\"success\":true}}", .{filename}) catch return;
        conn.sendText(msg) catch {};
        std.log.info("File uploaded: {s} ({d} bytes compressed -> {d} bytes)", .{ full_path, compressed_data.len, actual_size });
    }

    // Binary file download: [panel_id:u32][path_len:u16][path]
    // Response: [0x12][name_len:u16][name][compressed_data]
    // Error: [0x13][error_len:u16][error]
    fn handleBinaryFileDownload(self: *Server, conn: *ws.Connection, data: []const u8) void {
        if (data.len < 6) {
            self.sendBinaryFileError(conn, "Invalid message");
            return;
        }

        const panel_id = std.mem.readInt(u32, data[0..4], .little);
        const path_len = std.mem.readInt(u16, data[4..6], .little);

        if (data.len < 6 + path_len) {
            self.sendBinaryFileError(conn, "Invalid message");
            return;
        }

        var path = data[6 .. 6 + path_len];

        // Get panel for cwd resolution
        self.mutex.lock();
        const panel = self.panels.get(panel_id);
        self.mutex.unlock();

        // Expand ~ or relative paths
        var resolved_path_buf: [4096]u8 = undefined;
        var resolved_path: []const u8 = path;

        if (path.len > 0 and path[0] == '~') {
            const home = std.posix.getenv("HOME") orelse "/tmp";
            if (path.len > 1 and path[1] == '/') {
                resolved_path = std.fmt.bufPrint(&resolved_path_buf, "{s}{s}", .{ home, path[1..] }) catch path;
            } else {
                resolved_path = std.fmt.bufPrint(&resolved_path_buf, "{s}", .{home}) catch path;
            }
        } else if (path.len > 0 and path[0] != '/') {
            if (panel) |p| {
                if (p.pwd.len > 0) {
                    resolved_path = std.fmt.bufPrint(&resolved_path_buf, "{s}/{s}", .{ p.pwd, path }) catch path;
                }
            }
        }

        const filename = std.fs.path.basename(resolved_path);

        // Read file
        const file = std.fs.openFileAbsolute(resolved_path, .{}) catch {
            self.sendBinaryFileError(conn, "Cannot open file");
            return;
        };
        defer file.close();

        const stat = file.stat() catch {
            self.sendBinaryFileError(conn, "Cannot stat file");
            return;
        };

        if (stat.size > 100 * 1024 * 1024) {
            self.sendBinaryFileError(conn, "File too large (max 100MB)");
            return;
        }

        const file_data = file.readToEndAlloc(self.allocator, 100 * 1024 * 1024) catch {
            self.sendBinaryFileError(conn, "Read failed");
            return;
        };
        defer self.allocator.free(file_data);

        // Send uncompressed - WebSocket permessage-deflate handles compression
        // Format: [0x12][name_len:u16][name][file_data]
        const msg_len = 1 + 2 + filename.len + file_data.len;
        const msg = self.allocator.alloc(u8, msg_len) catch {
            self.sendBinaryFileError(conn, "Out of memory");
            return;
        };
        defer self.allocator.free(msg);

        msg[0] = 0x12; // file_data type
        std.mem.writeInt(u16, msg[1..3], @intCast(filename.len), .little);
        @memcpy(msg[3 .. 3 + filename.len], filename);
        @memcpy(msg[3 + filename.len ..], file_data);

        conn.sendBinary(msg) catch {
            std.log.err("Failed to send file data", .{});
            return;
        };
        std.log.info("File downloaded: {s} ({d} bytes)", .{ resolved_path, file_data.len });
    }

    fn sendBinaryFileError(self: *Server, conn: *ws.Connection, err: []const u8) void {
        _ = self;
        // Error format: [0x13][error_len:u16][error]
        var buf: [256]u8 = undefined;
        buf[0] = 0x13;
        std.mem.writeInt(u16, buf[1..3], @intCast(err.len), .little);
        @memcpy(buf[3..][0..err.len], err);
        conn.sendBinary(buf[0 .. 3 + err.len]) catch {};
    }

    // Binary folder download: [panel_id:u32][path_len:u16][path]
    // Response: [0x15][name_len:u16][name.zip][zip_data]
    fn handleBinaryFolderDownload(self: *Server, conn: *ws.Connection, data: []const u8) void {
        if (data.len < 6) {
            self.sendBinaryFileError(conn, "Invalid message");
            return;
        }

        const panel_id = std.mem.readInt(u32, data[0..4], .little);
        const path_len = std.mem.readInt(u16, data[4..6], .little);

        if (data.len < 6 + path_len) {
            self.sendBinaryFileError(conn, "Invalid message");
            return;
        }

        const path = data[6 .. 6 + path_len];

        // Get panel for cwd resolution
        self.mutex.lock();
        const panel = self.panels.get(panel_id);
        self.mutex.unlock();

        // Expand ~ or relative paths
        var resolved_path_buf: [4096]u8 = undefined;
        var resolved_path: []const u8 = path;

        if (path.len > 0 and path[0] == '~') {
            const home = std.posix.getenv("HOME") orelse "/tmp";
            if (path.len > 1 and path[1] == '/') {
                resolved_path = std.fmt.bufPrint(&resolved_path_buf, "{s}{s}", .{ home, path[1..] }) catch path;
            } else {
                resolved_path = std.fmt.bufPrint(&resolved_path_buf, "{s}", .{home}) catch path;
            }
        } else if (path.len > 0 and path[0] != '/') {
            if (panel) |p| {
                if (p.pwd.len > 0) {
                    resolved_path = std.fmt.bufPrint(&resolved_path_buf, "{s}/{s}", .{ p.pwd, path }) catch path;
                }
            }
        }

        // Check if it's a directory
        var dir = std.fs.openDirAbsolute(resolved_path, .{}) catch {
            self.sendBinaryFileError(conn, "Cannot open directory");
            return;
        };
        dir.close();

        // Get folder name for zip filename
        const folder_name = std.fs.path.basename(resolved_path);
        var zip_name_buf: [256]u8 = undefined;
        const zip_name = std.fmt.bufPrint(&zip_name_buf, "{s}.zip", .{folder_name}) catch {
            self.sendBinaryFileError(conn, "Path too long");
            return;
        };

        // Create zip
        const zip_data = zip.zipDirectory(self.allocator, resolved_path, folder_name) catch {
            self.sendBinaryFileError(conn, "Failed to create zip");
            return;
        };
        defer self.allocator.free(zip_data);

        // Build response: [0x15][name_len:u16][name.zip][zip_data]
        const msg_len = 1 + 2 + zip_name.len + zip_data.len;
        const msg = self.allocator.alloc(u8, msg_len) catch {
            self.sendBinaryFileError(conn, "Out of memory");
            return;
        };
        defer self.allocator.free(msg);

        msg[0] = 0x15; // folder_data type (zip)
        std.mem.writeInt(u16, msg[1..3], @intCast(zip_name.len), .little);
        @memcpy(msg[3 .. 3 + zip_name.len], zip_name);
        @memcpy(msg[3 + zip_name.len ..], zip_data);

        conn.sendBinary(msg) catch {
            std.log.err("Failed to send folder zip", .{});
            return;
        };
        std.log.info("Folder downloaded: {s} -> {s} ({d} bytes)", .{ resolved_path, zip_name, zip_data.len });
    }

    // Keep old JSON handlers for backwards compatibility (will be removed later)
    fn handleFileUpload(self: *Server, conn: *ws.Connection, data: []const u8) void {
        _ = self;
        _ = conn;
        _ = data;
        // Deprecated - use binary upload (0x10)
    }

    fn handleFileDownload(self: *Server, conn: *ws.Connection, data: []const u8) void {
        _ = self;
        _ = conn;
        _ = data;
        // Deprecated - use binary download (0x11)
    }

    fn sendFileError(_: *Server, conn: *ws.Connection, _: []const u8, err: []const u8) void {
        // Error format: [0x13][error_len:u16][error]
        var buf: [256]u8 = undefined;
        buf[0] = 0x13;
        std.mem.writeInt(u16, buf[1..3], @intCast(err.len), .little);
        @memcpy(buf[3..][0..err.len], err);
        conn.sendBinary(buf[0 .. 3 + err.len]) catch {};
    }

    fn broadcastInspectorUpdates(self: *Server) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Send to control connection subscriptions (legacy)
        for (self.inspector_subscriptions.items) |sub| {
            self.sendInspectorStateUnlocked(sub.conn, sub.panel_id, sub.tab[0..sub.tab_len]);
        }

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

    fn parseJsonFloat(self: *Server, data: []const u8, key: []const u8) ?f64 {
        _ = self;
        // Build search pattern: "key":
        var pattern_buf: [64]u8 = undefined;
        const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\":", .{key}) catch return null;

        const idx = std.mem.indexOf(u8, data, pattern) orelse return null;
        var start = idx + pattern.len;

        // Skip whitespace
        while (start < data.len and (data[start] == ' ' or data[start] == '\t')) : (start += 1) {}

        var end = start;
        while (end < data.len and (data[end] == '.' or data[end] == '-' or (data[end] >= '0' and data[end] <= '9'))) : (end += 1) {}

        if (end > start) {
            return std.fmt.parseFloat(f64, data[start..end]) catch null;
        }
        return null;
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

        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.control_connections.items) |conn| {
            conn.sendBinary(&buf) catch {};
        }
    }

    fn broadcastPanelClosed(self: *Server, panel_id: u32) void {
        // Binary: [type:u8][panel_id:u32] = 5 bytes
        var buf: [5]u8 = undefined;
        buf[0] = @intFromEnum(BinaryCtrlMsg.panel_closed);
        std.mem.writeInt(u32, buf[1..5], panel_id, .little);

        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.control_connections.items) |conn| {
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

        self.mutex.lock();
        defer self.mutex.unlock();

        // Store title in panel for reconnects
        if (self.panels.get(panel_id)) |panel| {
            if (panel.title.len > 0) self.allocator.free(panel.title);
            panel.title = self.allocator.dupe(u8, title) catch &.{};
        }

        for (self.control_connections.items) |conn| {
            conn.sendBinary(buf[0 .. 6 + title_len]) catch {};
        }
    }

    fn broadcastPanelBell(self: *Server, panel_id: u32) void {
        // Binary: [type:u8][panel_id:u32] = 5 bytes
        var buf: [5]u8 = undefined;
        buf[0] = @intFromEnum(BinaryCtrlMsg.panel_bell);
        std.mem.writeInt(u32, buf[1..5], panel_id, .little);

        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.control_connections.items) |conn| {
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

        self.mutex.lock();
        defer self.mutex.unlock();

        // Store pwd in panel for reconnects
        if (self.panels.get(panel_id)) |panel| {
            if (panel.pwd.len > 0) self.allocator.free(panel.pwd);
            panel.pwd = self.allocator.dupe(u8, pwd) catch &.{};
        }

        for (self.control_connections.items) |conn| {
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

        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.control_connections.items) |conn| {
            conn.sendBinary(buf[0..total_len]) catch {};
        }
    }

    fn broadcastLayoutUpdate(self: *Server) void {
        self.mutex.lock();
        const layout_json = self.layout.toJson(self.allocator) catch {
            self.mutex.unlock();
            return;
        };
        defer self.allocator.free(layout_json);

        // Binary: [type:u8][layout_len:u16][layout_json...] = 3 + layout.len bytes
        const layout_len: u16 = @min(@as(u16, @intCast(@min(layout_json.len, 65535))), 65535);
        const msg_buf = self.allocator.alloc(u8, 3 + layout_len) catch {
            self.mutex.unlock();
            return;
        };
        defer self.allocator.free(msg_buf);

        msg_buf[0] = @intFromEnum(BinaryCtrlMsg.layout_update);
        std.mem.writeInt(u16, msg_buf[1..3], layout_len, .little);
        @memcpy(msg_buf[3..][0..layout_len], layout_json[0..layout_len]);

        for (self.control_connections.items) |conn| {
            conn.sendBinary(msg_buf) catch {};
        }
        self.mutex.unlock();
    }

    fn broadcastClipboard(self: *Server, text: []const u8) void {
        // Binary: [type:u8][data_len:u32][data...] = 5 + text.len bytes (raw UTF-8, no base64)
        const data_len: u32 = @intCast(@min(text.len, 16 * 1024 * 1024)); // Max 16MB
        const msg_buf = self.allocator.alloc(u8, 5 + data_len) catch return;
        defer self.allocator.free(msg_buf);

        msg_buf[0] = @intFromEnum(BinaryCtrlMsg.clipboard);
        std.mem.writeInt(u32, msg_buf[1..5], data_len, .little);
        @memcpy(msg_buf[5..][0..data_len], text[0..data_len]);

        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.control_connections.items) |conn| {
            conn.sendBinary(msg_buf) catch {};
        }
    }

    fn sendInspectorStateUnlocked(self: *Server, conn: *ws.Connection, panel_id: u32, tab: []const u8) void {
        _ = tab; // Tab parameter for future use when more data is available
        _ = self;
        // Note: mutex must already be held by caller
        // Binary: [type:u8][panel_id:u32][cols:u16][rows:u16][sw:u16][sh:u16][cw:u8][ch:u8] = 15 bytes
        // TODO: Re-enable when ghostty surface is available
        _ = conn;
        _ = panel_id;
        // const panel = self.panels.get(panel_id) orelse return;
        // const size = c.ghostty_surface_size(panel.surface);

        // var buf: [15]u8 = undefined;
        // buf[0] = @intFromEnum(BinaryCtrlMsg.inspector_state);
        // std.mem.writeInt(u32, buf[1..5], panel_id, .little);
        // std.mem.writeInt(u16, buf[5..7], @intCast(size.columns), .little);
        // std.mem.writeInt(u16, buf[7..9], @intCast(size.rows), .little);
        // std.mem.writeInt(u16, buf[9..11], @intCast(size.width_px), .little);
        // std.mem.writeInt(u16, buf[11..13], @intCast(size.height_px), .little);
        // buf[13] = @intCast(size.cell_width_px);
        // buf[14] = @intCast(size.cell_height_px);

        // conn.sendBinary(&buf) catch {};
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

    // ========== File WebSocket callbacks ==========

    fn onFileConnect(conn: *ws.Connection) void {
        const self = global_server orelse return;

        self.mutex.lock();
        self.file_connections.append(self.allocator, conn) catch {};
        self.mutex.unlock();

        std.debug.print("File transfer client connected\n", .{});
    }

    fn onFileMessage(conn: *ws.Connection, data: []u8, is_binary: bool) void {
        const self = global_server orelse return;
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
        const self = global_server orelse return;

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

        // Decompress the data
        const uncompressed = session.decompress(file_data.compressed_data, file_data.uncompressed_size) catch |err| {
            std.debug.print("Failed to decompress file data: {}\n", .{err});
            return;
        };
        defer self.allocator.free(uncompressed);

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
            const panel = self.createPanel(req.width, req.height, req.scale) catch |err| {
                std.debug.print("Failed to create panel: {}\n", .{err});
                continue;
            };

            panel.setConnection(req.conn);
            req.conn.user_data = panel;

            self.mutex.lock();
            self.panel_connections.put(req.conn, panel) catch {};
            self.mutex.unlock();

            self.broadcastPanelCreated(panel.id);
            self.broadcastLayoutUpdate();
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
            const panel = self.createPanelAsSplit(req.width, req.height, req.scale, req.parent_panel_id, req.direction) catch |err| {
                std.debug.print("Failed to create split panel: {}\n", .{err});
                continue;
            };

            // Panel connection will be established when client connects via panel WS with CONNECT_PANEL
            self.broadcastPanelCreated(panel.id);
            self.broadcastLayoutUpdate();
        }

        self.allocator.free(pending);
    }

    // Main render loop
    fn runRenderLoop(self: *Server) void {
        const target_fps: u64 = 30;
        const frame_time_ns: u64 = std.time.ns_per_s / target_fps;
        const input_interval_ns: u64 = 8 * std.time.ns_per_ms; // Process input every 8ms

        var last_frame: i128 = 0;

        while (self.running.load(.acquire)) {
            const now = std.time.nanoTimestamp();

            // Process pending panel creations/destructions/resizes/splits (NSWindow/ghostty must be on main thread)
            self.processPendingPanels();
            self.processPendingDestroys();
            self.processPendingResizes();
            self.processPendingSplits();

            // Tick ghostty
            self.tick();

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

            // Now process input without holding the mutex
            for (panels_buf[0..panels_count]) |panel| {
                panel.processInputQueue();
                panel.tick();
            }

            // Only capture and send frames at target fps
            const since_last_frame: u64 = @intCast(now - last_frame);
            if (since_last_frame >= frame_time_ns) {
                last_frame = now;

                // Small delay for Metal render
                std.Thread.sleep(1 * std.time.ns_per_ms);

                // Capture and send frames
                self.mutex.lock();
                panel_it = self.panels.valueIterator();
                while (panel_it.next()) |panel_ptr| {
                    const panel = panel_ptr.*;
                    if (!panel.streaming.load(.acquire)) continue;

                    if (panel.getIOSurface()) |iosurface| {
                        const changed = panel.captureFromIOSurface(iosurface) catch continue;
                        if (!changed) continue;

                        if (panel.prepareFrame() catch null) |result| {
                            panel.sendFrame(result.data) catch {};
                        }
                    }
                }
                self.mutex.unlock();
            }


            // Sleep until next frame/input interval
            const elapsed: u64 = @intCast(std.time.nanoTimestamp() - now);
            // Use frame_time_ns for lower CPU when no panels are streaming
            var sleep_time = frame_time_ns;

            // Check if any panel needs frequent updates (has input queued or is streaming)
            var needs_fast_poll = false;
            for (panels_buf[0..panels_count]) |panel| {
                if (panel.streaming.load(.acquire) or panel.hasQueuedInput()) {
                    needs_fast_poll = true;
                    break;
                }
            }

            if (needs_fast_poll) {
                sleep_time = input_interval_ns;
            }

            if (elapsed < sleep_time) {
                std.Thread.sleep(sleep_time - elapsed);
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

        // Start file WebSocket server in background
        const file_thread = try std.Thread.spawn(.{}, runFileWebSocket, .{self});
        defer file_thread.join();

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

    const self = Server.global_server orelse return;

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

    const self = Server.global_server orelse return;
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
    const self = Server.global_server orelse return;

    // Queue the panel for destruction on main thread
    self.mutex.lock();
    self.pending_destroys.append(self.allocator, .{ .id = panel.id }) catch {};
    self.mutex.unlock();
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


var sigint_received = std.atomic.Value(bool).init(false);

fn handleSigint(_: c_int) callconv(.c) void {
    if (sigint_received.swap(true, .acq_rel)) {
        // Second Ctrl+C - force exit immediately
        std.posix.exit(1);
    }
    // First Ctrl+C - graceful shutdown
    if (Server.global_server) |server| {
        server.running.store(false, .release);
    }
    std.debug.print("\nShutting down...\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try parseArgs(allocator);

    // Setup SIGINT handler for graceful shutdown
    const act = std.posix.Sigaction{
        .handler = .{ .handler = handleSigint },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);

    std.debug.print("termweb-mux server starting...\n", .{});

    // WS ports use 0 to let OS assign random available ports
    const server = try Server.init(allocator, args.http_port, 0, 0, args.web_root);
    defer server.deinit();

    const panel_port = server.panel_ws_server.listener.listen_address.getPort();
    const control_port = server.control_ws_server.listener.listen_address.getPort();
    const file_port = server.file_ws_server.listener.listen_address.getPort();

    // Tell HTTP server about the WS ports so it can serve /config
    server.http_server.setWsPorts(panel_port, control_port, file_port);

    std.debug.print("  HTTP:              http://localhost:{}\n", .{args.http_port});
    std.debug.print("  Panel WebSocket:   ws://localhost:{}\n", .{panel_port});
    std.debug.print("  Control WebSocket: ws://localhost:{}\n", .{control_port});
    std.debug.print("  File WebSocket:    ws://localhost:{}\n", .{file_port});
    std.debug.print("  Web root:          {s}\n", .{args.web_root});
    std.debug.print("\nServer initialized, waiting for connections...\n", .{});

    try server.run();
}
