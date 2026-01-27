/// WebRTC Frame Server
/// Uses libdatachannel for WebRTC DataChannel transport of frames from Chrome extension.
/// Signaling happens via CDP (console messages), frame data flows over WebRTC DataChannel.
const std = @import("std");
const rtc = @import("rtc.zig");
const FramePool = @import("../simd/frame_pool.zig").FramePool;
const FrameSlot = @import("../simd/frame_pool.zig").FrameSlot;
const FpsController = @import("fps_controller.zig").FpsController;

/// Debug log file handle (kept open for performance)
var debug_log_file: ?std.fs.File = null;

fn initDebugLog() void {
    if (debug_log_file == null) {
        debug_log_file = std.fs.cwd().createFile("rtc_debug.log", .{ .truncate = false }) catch null;
        if (debug_log_file) |f| {
            f.seekFromEnd(0) catch {};
        }
    }
}

fn logToFile(comptime fmt: []const u8, args: anytype) void {
    initDebugLog();
    if (debug_log_file) |f| {
        var buf: [4096]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
        _ = f.write(msg) catch {};
    }
}

/// Track when offer handling started (for stall detection coordination)
/// Module-level so it can be accessed from viewer.zig
/// ATOMIC because it's accessed from multiple threads (main loop + CDP thread)
pub var offer_handling_time: std.atomic.Value(i128) = std.atomic.Value(i128).init(0);

/// Track when the current peer connection was created (to avoid closing too soon)
var peer_connection_created_at: i128 = 0;

/// Our own PC generation counter (libdatachannel reuses PC IDs after deletion)
var pc_generation: u32 = 0;

pub const RtcFrameServerError = error{
    InvalidFrame,
    OutOfMemory,
    RtcError,
};

/// Screencast frame structure with zero-copy reference to pool slot
pub const ScreencastFrame = struct {
    data: []const u8,
    slot: *FrameSlot,
    session_id: u32,
    device_width: u32,
    device_height: u32,
    generation: u64,

    pub fn deinit(self: *ScreencastFrame) void {
        self.slot.release();
    }
};

/// RTC Frame Server - receives frames via WebRTC DataChannel
/// Signaling is handled externally via CDP, not by this server.
pub const RtcFrameServer = struct {
    allocator: std.mem.Allocator,

    // Frame pool for zero-copy frame storage
    frame_pool: *FramePool,
    frame_count: std.atomic.Value(u32),

    // FPS controller
    fps_controller: FpsController,

    // WebRTC peer connection
    peer_connection: ?rtc.PeerConnection,
    current_pc_id: c_int, // Track current PC ID to ignore stale callbacks
    data_channel: ?rtc.DataChannel,
    rtc_connected: std.atomic.Value(bool),

    // Pending ICE candidates (before remote description is set)
    pending_candidates: std.ArrayList(struct { candidate: []const u8, mid: []const u8 }),
    remote_description_set: bool,

    // Callback for sending signaling messages (set by caller)
    // Context pointer is passed to allow access to CDP client or viewer
    send_callback: ?*const fn ([]const u8, ?*anyopaque) void,
    send_callback_ctx: ?*anyopaque,

    // Self pointer for static callbacks
    self_ptr: *RtcFrameServer,

    pub fn init(allocator: std.mem.Allocator) !*RtcFrameServer {
        const server = try allocator.create(RtcFrameServer);
        errdefer allocator.destroy(server);

        const frame_pool = try FramePool.init(allocator);
        errdefer frame_pool.deinit();

        // Initialize libdatachannel
        rtc.preload();
        rtc.initLogger(.none, null);  // Disable libdatachannel logging (was corrupting terminal)

        server.* = .{
            .allocator = allocator,
            .frame_pool = frame_pool,
            .frame_count = std.atomic.Value(u32).init(0),
            .fps_controller = FpsController.initWithRange(5, 120, 30),
            .peer_connection = null,
            .current_pc_id = -1,
            .data_channel = null,
            .rtc_connected = std.atomic.Value(bool).init(false),
            .pending_candidates = .{},
            .remote_description_set = false,
            .send_callback = null,
            .send_callback_ctx = null,
            .self_ptr = undefined,
        };
        server.self_ptr = server;

        return server;
    }

    pub fn deinit(self: *RtcFrameServer) void {
        // Cleanup WebRTC
        if (self.data_channel) |dc| {
            dc.close();
            dc.delete();
        }
        if (self.peer_connection) |pc| {
            pc.close();
            pc.delete();
        }

        // Cleanup pending candidates
        for (self.pending_candidates.items) |item| {
            self.allocator.free(item.candidate);
            self.allocator.free(item.mid);
        }
        self.pending_candidates.deinit(self.allocator);

        rtc.cleanup();

        self.frame_pool.deinit();
        self.allocator.destroy(self);
    }

    /// Set callback for sending signaling messages via CDP
    pub fn setSendCallback(self: *RtcFrameServer, callback: *const fn ([]const u8, ?*anyopaque) void, ctx: ?*anyopaque) void {
        self.send_callback = callback;
        self.send_callback_ctx = ctx;
    }

    /// Check if WebRTC DataChannel is connected
    pub fn isConnected(self: *RtcFrameServer) bool {
        return self.rtc_connected.load(.acquire);
    }

    /// Get latest frame (zero-copy)
    pub fn getLatestFrame(self: *RtcFrameServer) ?ScreencastFrame {
        const slot = self.frame_pool.acquireLatestFrame() orelse {
            // Log periodically to avoid spam
            const count = self.frame_count.load(.acquire);
            if (count % 100 == 0) {
                logToFile("[RTC] getLatestFrame: null, frame_count={}\n", .{count});
            }
            return null;
        };
        // Log successful frame retrieval periodically
        if (slot.generation % 30 == 1) {
            logToFile("[RTC] getLatestFrame: OK, gen={}, dim={}x{}\n", .{ slot.generation, slot.device_width, slot.device_height });
        }
        return ScreencastFrame{
            .data = slot.data(),
            .slot = slot,
            .session_id = slot.session_id,
            .device_width = slot.device_width,
            .device_height = slot.device_height,
            .generation = slot.generation,
        };
    }

    /// Get frame count
    pub fn getFrameCount(self: *RtcFrameServer) u32 {
        return self.frame_count.load(.acquire);
    }

    /// Record render time for FPS adaptation
    pub fn recordRenderTime(self: *RtcFrameServer, render_time_ns: u64) void {
        self.fps_controller.recordRenderTime(render_time_ns);

        // Try to adjust FPS
        if (self.fps_controller.adjustFps()) {
            // FPS changed, notify extension via signaling
            const new_fps = self.fps_controller.getTargetFps();
            logToFile("[FPS] adjusted to {}\n", .{new_fps});
            self.sendFpsCommand(new_fps);
        }
    }

    /// Send FPS adjustment command
    fn sendFpsCommand(self: *RtcFrameServer, fps: u32) void {
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{{\"type\":\"set_fps\",\"fps\":{d}}}", .{fps}) catch return;
        self.sendSignaling(msg);
    }

    /// Send signaling message via callback
    fn sendSignaling(self: *RtcFrameServer, msg: []const u8) void {
        if (self.send_callback) |cb| {
            cb(msg, self.send_callback_ctx);
        }
    }

    /// Handle incoming signaling message (from CDP console events)
    pub fn handleSignalingMessage(self: *RtcFrameServer, message: []const u8) void {
        // Parse JSON-like message
        const type_start = std.mem.indexOf(u8, message, "\"type\":\"") orelse {
            logToFile("[RTC] handleSignalingMessage: no type field found\n", .{});
            return;
        };
        const type_begin = type_start + 8;
        const type_end = std.mem.indexOfPos(u8, message, type_begin, "\"") orelse {
            logToFile("[RTC] handleSignalingMessage: no type end found\n", .{});
            return;
        };
        const msg_type = message[type_begin..type_end];

        logToFile("[RTC] handleSignalingMessage: type={s}\n", .{msg_type});

        if (std.mem.eql(u8, msg_type, "offer")) {
            logToFile("[RTC] Calling handleOffer...\n", .{});
            self.handleOffer(message) catch |err| {
                logToFile("[RTC] handleOffer failed: {}\n", .{err});
            };
        } else if (std.mem.eql(u8, msg_type, "candidate")) {
            logToFile("[RTC] Calling handleCandidate...\n", .{});
            self.handleCandidate(message) catch |err| {
                logToFile("[RTC] handleCandidate failed: {}\n", .{err});
            };
        }
    }

    /// Handle SDP offer from browser
    fn handleOffer(self: *RtcFrameServer, message: []const u8) !void {
        const now = std.time.nanoTimestamp();
        const pc_age_ms = if (peer_connection_created_at > 0) @divFloor(now - peer_connection_created_at, std.time.ns_per_ms) else 0;

        logToFile("[RTC] handleOffer: starting, pc_is_null={}, remote_desc_set={}, pc_age_ms={}, rtc_connected={}\n", .{
            self.peer_connection == null,
            self.remote_description_set,
            pc_age_ms,
            self.rtc_connected.load(.acquire),
        });

        // If we have a recent connection (< 3 seconds old), ignore new offers
        // This prevents rapid connection destruction from multiple script injections
        if (self.peer_connection != null and pc_age_ms < 3000) {
            logToFile("[RTC] handleOffer: IGNORING - connection is only {}ms old, waiting for it to establish\n", .{pc_age_ms});
            // Still update offer_handling_time to prevent stall detection
            offer_handling_time.store(now, .release);
            return;
        }

        // Record when we started handling this offer - stall detection should wait
        offer_handling_time.store(now, .release);

        // If we already have a connection, just let it be replaced
        // Old connection will die naturally when page unloads
        if (self.peer_connection != null) {
            logToFile("[RTC] handleOffer: replacing old connection (age={}ms) with new offer\n", .{pc_age_ms});
            // Invalidate old PC ID so stale callbacks are ignored
            self.current_pc_id = -1;
        }

        // Create new peer connection
        logToFile("[RTC] handleOffer: creating peer connection...\n", .{});
        try self.createPeerConnection();
        peer_connection_created_at = std.time.nanoTimestamp();
        logToFile("[RTC] handleOffer: peer connection created, pc_is_null={}\n", .{self.peer_connection == null});

        const pc = self.peer_connection orelse {
            logToFile("[RTC] handleOffer: peer connection is still null!\n", .{});
            return;
        };

        // Parse SDP from offer
        const sdp_start = std.mem.indexOf(u8, message, "\"sdp\":\"") orelse return;
        const sdp_begin = sdp_start + 7;
        const sdp_end = findEndOfString(message, sdp_begin) orelse return;
        const escaped_sdp = message[sdp_begin..sdp_end];

        // Unescape SDP
        const sdp = try self.allocator.alloc(u8, escaped_sdp.len + 1);
        defer self.allocator.free(sdp);

        var j: usize = 0;
        var i: usize = 0;
        while (i < escaped_sdp.len) {
            if (escaped_sdp[i] == '\\' and i + 1 < escaped_sdp.len) {
                if (escaped_sdp[i + 1] == 'n') {
                    sdp[j] = '\n';
                    i += 2;
                } else if (escaped_sdp[i + 1] == 'r') {
                    sdp[j] = '\r';
                    i += 2;
                } else if (escaped_sdp[i + 1] == '"') {
                    sdp[j] = '"';
                    i += 2;
                } else if (escaped_sdp[i + 1] == '\\') {
                    sdp[j] = '\\';
                    i += 2;
                } else {
                    sdp[j] = escaped_sdp[i];
                    i += 1;
                }
            } else {
                sdp[j] = escaped_sdp[i];
                i += 1;
            }
            j += 1;
        }
        sdp[j] = 0;

        logToFile("[RTC] handleOffer: parsed SDP, len={}\n", .{j});

        // Set remote description
        logToFile("[RTC] handleOffer: calling setRemoteDescription...\n", .{});
        pc.setRemoteDescription(sdp[0..j :0], "offer") catch |err| {
            logToFile("[RTC] handleOffer: setRemoteDescription failed: {}\n", .{err});
            return;
        };
        self.remote_description_set = true;
        logToFile("[RTC] handleOffer: remote description set successfully\n", .{});

        // Add pending candidates
        logToFile("[RTC] handleOffer: adding {} pending candidates\n", .{self.pending_candidates.items.len});
        for (self.pending_candidates.items) |item| {
            const cand_z = self.allocator.dupeZ(u8, item.candidate) catch continue;
            defer self.allocator.free(cand_z);
            const mid_z = self.allocator.dupeZ(u8, item.mid) catch continue;
            defer self.allocator.free(mid_z);
            pc.addRemoteCandidate(cand_z, mid_z) catch {};
            self.allocator.free(item.candidate);
            self.allocator.free(item.mid);
        }
        self.pending_candidates.clearRetainingCapacity();

        // Create answer (triggers onLocalDescription callback)
        logToFile("[RTC] handleOffer: calling setLocalDescription to create answer...\n", .{});
        pc.setLocalDescription(null) catch |err| {
            logToFile("[RTC] handleOffer: setLocalDescription failed: {}\n", .{err});
        };
        logToFile("[RTC] handleOffer: setLocalDescription returned (answer should be sent via callback)\n", .{});
    }

    /// Handle ICE candidate from browser
    fn handleCandidate(self: *RtcFrameServer, message: []const u8) !void {
        const cand_start = std.mem.indexOf(u8, message, "\"candidate\":\"") orelse return;
        const cand_begin = cand_start + 13;
        const cand_end = findEndOfString(message, cand_begin) orelse return;
        const candidate = message[cand_begin..cand_end];

        const mid_start = std.mem.indexOf(u8, message, "\"mid\":\"") orelse return;
        const mid_begin = mid_start + 7;
        const mid_end = findEndOfString(message, mid_begin) orelse return;
        const mid = message[mid_begin..mid_end];

        if (self.remote_description_set) {
            const pc = self.peer_connection orelse return;
            const cand_z = try self.allocator.dupeZ(u8, candidate);
            defer self.allocator.free(cand_z);
            const mid_z = try self.allocator.dupeZ(u8, mid);
            defer self.allocator.free(mid_z);
            pc.addRemoteCandidate(cand_z, mid_z) catch {};
        } else {
            // Queue candidate
            try self.pending_candidates.append(self.allocator, .{
                .candidate = try self.allocator.dupe(u8, candidate),
                .mid = try self.allocator.dupe(u8, mid),
            });
        }
    }

    /// Create WebRTC peer connection
    fn createPeerConnection(self: *RtcFrameServer) !void {
        // Don't close old connection - just replace it
        // Old connection will be ignored via dc_id check
        self.peer_connection = null;
        self.data_channel = null;
        self.remote_description_set = false;

        // Create peer connection
        const pc = rtc.PeerConnection.create(.{}) catch return RtcFrameServerError.RtcError;
        self.peer_connection = pc;
        self.current_pc_id = pc.id;
        logToFile("[RTC] createPeerConnection: new PC created with id={}\n", .{pc.id});

        // Set user pointer for callbacks
        pc.setUserPointer(self.self_ptr);

        // Set callbacks
        pc.setLocalDescriptionCallback(onLocalDescription) catch {};
        pc.setLocalCandidateCallback(onLocalCandidate) catch {};
        pc.setStateChangeCallback(onStateChange) catch {};
        pc.setDataChannelCallback(onDataChannel) catch {};
    }

    /// Track if we've already sent an answer to prevent duplicates
    var answer_sent: bool = false;

    /// Close existing WebRTC connection (called when new offer arrives)
    fn closeConnection(self: *RtcFrameServer) void {
        logToFile("[RTC] closeConnection called, old pc_id={}\n", .{self.current_pc_id});
        answer_sent = false;
        peer_connection_created_at = 0;
        self.current_pc_id = -1; // Invalidate so stale callbacks are ignored
        self.remote_description_set = false;
        self.rtc_connected.store(false, .release);
        if (self.data_channel) |dc| {
            dc.close();
            dc.delete();
            self.data_channel = null;
        }
        if (self.peer_connection) |pc| {
            pc.close();
            pc.delete();
            self.peer_connection = null;
        }
        logToFile("[RTC] closeConnection done\n", .{});
    }

    /// Reset connection state for reconnection (public, called from viewer)
    pub fn resetConnection(self: *RtcFrameServer) void {
        self.closeConnection();
    }

    /// Callback: Local description generated (answer)
    fn onLocalDescription(pc_id: c_int, sdp: [*:0]const u8, desc_type: [*:0]const u8, ptr: ?*anyopaque) callconv(.c) void {
        const self: *RtcFrameServer = @ptrCast(@alignCast(ptr));
        logToFile("[RTC] onLocalDescription callback triggered! pc_id={}, current_pc_id={}, answer_sent={}\n", .{ pc_id, self.current_pc_id, answer_sent });

        // Ignore callbacks from old/closed peer connections
        if (pc_id != self.current_pc_id) {
            logToFile("[RTC] onLocalDescription: IGNORING stale callback (pc_id {} != current {})\n", .{ pc_id, self.current_pc_id });
            return;
        }

        // Prevent sending duplicate answers
        if (answer_sent) {
            logToFile("[RTC] onLocalDescription: SKIPPING - answer already sent\n", .{});
            return;
        }
        answer_sent = true;

        const sdp_slice = std.mem.span(sdp);
        const type_slice = std.mem.span(desc_type);
        logToFile("[RTC] onLocalDescription: type={s}, sdp_len={}\n", .{ type_slice, sdp_slice.len });

        // Escape SDP for JSON
        var escaped_buf: [16384]u8 = undefined;
        var escaped_len: usize = 0;
        for (sdp_slice) |ch| {
            if (ch == '\n') {
                escaped_buf[escaped_len] = '\\';
                escaped_buf[escaped_len + 1] = 'n';
                escaped_len += 2;
            } else if (ch == '\r') {
                escaped_buf[escaped_len] = '\\';
                escaped_buf[escaped_len + 1] = 'r';
                escaped_len += 2;
            } else if (ch == '"') {
                escaped_buf[escaped_len] = '\\';
                escaped_buf[escaped_len + 1] = '"';
                escaped_len += 2;
            } else if (ch == '\\') {
                escaped_buf[escaped_len] = '\\';
                escaped_buf[escaped_len + 1] = '\\';
                escaped_len += 2;
            } else {
                escaped_buf[escaped_len] = ch;
                escaped_len += 1;
            }
        }

        var buf: [20000]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{{\"type\":\"answer\",\"sdp\":\"{s}\",\"sdpType\":\"{s}\"}}", .{
            escaped_buf[0..escaped_len],
            type_slice,
        }) catch return;

        logToFile("[RTC] onLocalDescription: calling sendSignaling with answer, len={}\n", .{msg.len});
        self.sendSignaling(msg);
        logToFile("[RTC] onLocalDescription: sendSignaling returned\n", .{});
    }

    /// Callback: Local ICE candidate
    fn onLocalCandidate(pc_id: c_int, candidate: [*:0]const u8, mid: [*:0]const u8, ptr: ?*anyopaque) callconv(.c) void {
        _ = pc_id;
        const self: *RtcFrameServer = @ptrCast(@alignCast(ptr));

        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{{\"type\":\"candidate\",\"candidate\":\"{s}\",\"mid\":\"{s}\"}}", .{
            std.mem.span(candidate),
            std.mem.span(mid),
        }) catch return;

        self.sendSignaling(msg);
    }

    /// Callback: Connection state change
    fn onStateChange(pc_id: c_int, state: c_int, ptr: ?*anyopaque) callconv(.c) void {
        const self: *RtcFrameServer = @ptrCast(@alignCast(ptr));
        const rtc_state: rtc.State = @enumFromInt(state);
        logToFile("[RTC] onStateChange callback! pc_id={}, state={} ({s}), current_pc_id={}\n", .{ pc_id, state, @tagName(rtc_state), self.current_pc_id });

        // DON'T trust disconnect/closed state changes - libdatachannel reuses PC IDs
        // so stale callbacks from deleted PCs can have the same ID as the current PC.
        // We only set rtc_connected=false in closeConnection() when WE close it.
        // The DataChannelOpen callback will set rtc_connected=true.
        if (rtc_state == .connected) {
            logToFile("[RTC] onStateChange: state=connected (informational only)\n", .{});
        } else if (rtc_state == .disconnected or rtc_state == .failed or rtc_state == .closed) {
            logToFile("[RTC] onStateChange: state={s} - IGNORING (may be stale)\n", .{@tagName(rtc_state)});
            // Don't set rtc_connected=false here - could be stale callback
        }
    }

    /// Callback: Incoming data channel
    fn onDataChannel(pc_id: c_int, dc_id: c_int, ptr: ?*anyopaque) callconv(.c) void {
        const self: *RtcFrameServer = @ptrCast(@alignCast(ptr));
        logToFile("[RTC] onDataChannel callback! pc_id={}, dc_id={}, current_pc_id={}\n", .{ pc_id, dc_id, self.current_pc_id });

        // Ignore callbacks from old/closed peer connections
        if (pc_id != self.current_pc_id) {
            logToFile("[RTC] onDataChannel: IGNORING stale callback (pc_id {} != current {})\n", .{ pc_id, self.current_pc_id });
            return;
        }

        const dc = rtc.DataChannel{ .id = dc_id };
        self.data_channel = dc;

        dc.setUserPointer(self.self_ptr);
        dc.setMessageCallback(onDataChannelMessage) catch {};
        dc.setOpenCallback(onDataChannelOpen) catch {};
        logToFile("[RTC] onDataChannel: callbacks set, waiting for open\n", .{});
    }

    /// Callback: Data channel open
    fn onDataChannelOpen(dc_id: c_int, ptr: ?*anyopaque) callconv(.c) void {
        logToFile("[RTC] onDataChannelOpen callback! dc_id={}\n", .{dc_id});
        const self: *RtcFrameServer = @ptrCast(@alignCast(ptr));

        // CRITICAL: Reset frame pool for new session
        // This clears any stale slots from the previous connection
        self.frame_pool.reset();
        self.frame_count.store(0, .release);
        logToFile("[RTC] onDataChannelOpen: frame pool reset for new session\n", .{});

        // Clear offer_handling_time - connection succeeded, stall detection can resume normally
        // This allows quick recovery if connection closes shortly after
        offer_handling_time.store(0, .release);

        self.rtc_connected.store(true, .release);
        logToFile("[RTC] onDataChannelOpen: rtc_connected set to true\n", .{});
    }

    /// Callback: Data channel message (frame data)
    fn onDataChannelMessage(dc_id: c_int, data: [*]const u8, size: c_int, ptr: ?*anyopaque) callconv(.c) void {
        _ = dc_id;
        const self: *RtcFrameServer = @ptrCast(@alignCast(ptr));

        logToFile("[RTC] onDataChannelMessage: received {} bytes\n", .{size});

        if (size < 12) {
            logToFile("[RTC] onDataChannelMessage: size too small ({}), ignoring\n", .{size});
            return;
        }
        const frame_data = data[0..@intCast(size)];

        // Frame format: [width: u32 LE][height: u32 LE][session_id: u32 LE][jpeg data...]
        const width = std.mem.readInt(u32, frame_data[0..4], .little);
        const height = std.mem.readInt(u32, frame_data[4..8], .little);
        const session_id = std.mem.readInt(u32, frame_data[8..12], .little);
        const jpeg_data = frame_data[12..];

        // Write to frame pool with session_id
        const write_result = self.frame_pool.writeFrame(jpeg_data, session_id, width, height) catch |err| {
            logToFile("[RTC] writeFrame error: {}, size={}, dim={}x{}, sid={}\n", .{ err, jpeg_data.len, width, height, session_id });
            return;
        };
        if (write_result) |gen| {
            const count = self.frame_count.fetchAdd(1, .monotonic);
            if (count % 30 == 0) {
                logToFile("[RTC] writeFrame OK: gen={}, count={}, dim={}x{}\n", .{ gen, count + 1, width, height });
            }
        } else {
            logToFile("[RTC] writeFrame returned null (slots busy), dim={}x{}\n", .{ width, height });
        }
    }

    /// Find end of JSON string (handles escapes)
    fn findEndOfString(data: []const u8, offset: usize) ?usize {
        var i = offset;
        while (i < data.len) {
            if (data[i] == '"') return i;
            if (data[i] == '\\' and i + 1 < data.len) {
                i += 2;
            } else {
                i += 1;
            }
        }
        return null;
    }
};
