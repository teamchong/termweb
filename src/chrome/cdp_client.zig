/// Chrome DevTools Protocol (CDP) client implementation.
///
/// Hybrid architecture:
/// - Pipe transport for screencast (high bandwidth, low latency)
/// - 3 WebSocket connections for input (mouse, keyboard, navigation)
///
/// This separates high-bandwidth video from interactive input to prevent
/// input lag when screencast frames are being transmitted.
const std = @import("std");
const cdp_pipe = @import("cdp_pipe.zig");
const websocket_cdp = @import("websocket_cdp.zig");

pub const CdpError = error{
    ConnectionFailed,
    SendFailed,
    ReceiveFailed,
    InvalidResponse,
    CommandFailed,
    TimeoutWaitingForResponse,
    OutOfMemory,
    NoPageTarget,
    WebSocketConnectionFailed,
};

/// Screencast frame structure with zero-copy reference to pool slot
pub const ScreencastFrame = cdp_pipe.ScreencastFrame;

pub const CdpEvent = struct {
    method: []const u8,
    payload: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CdpEvent) void {
        self.allocator.free(self.method);
        self.allocator.free(self.payload);
    }
};

/// CDP Client - Hybrid Pipe + WebSocket architecture
/// - pipe_client: screencast frames (high bandwidth)
/// - mouse_ws: mouse input (low latency)
/// - keyboard_ws: keyboard input (low latency)
/// - nav_ws: navigation commands (low latency)
pub const CdpClient = struct {
    allocator: std.mem.Allocator,
    pipe_client: *cdp_pipe.PipeCdpClient,
    session_id: ?[]const u8, // Session ID for page-level commands

    // WebSocket clients for input (separate from screencast pipe)
    mouse_ws: ?*websocket_cdp.WebSocketCdpClient,
    keyboard_ws: ?*websocket_cdp.WebSocketCdpClient,
    nav_ws: ?*websocket_cdp.WebSocketCdpClient,

    /// Initialize CDP client from pipe file descriptors
    /// read_fd: FD to read from Chrome (Chrome's FD 4)
    /// write_fd: FD to write to Chrome (Chrome's FD 3)
    pub fn initFromPipe(allocator: std.mem.Allocator, read_fd: std.posix.fd_t, write_fd: std.posix.fd_t) !*CdpClient {
        const client = try allocator.create(CdpClient);
        client.* = .{
            .allocator = allocator,
            .pipe_client = try cdp_pipe.PipeCdpClient.init(allocator, read_fd, write_fd),
            .session_id = null,
            .mouse_ws = null,
            .keyboard_ws = null,
            .nav_ws = null,
        };

        // Attach to page target to enable page-level commands
        try client.attachToPageTarget();

        // Enable domains for consistent event delivery
        const page_enable = try client.sendCommand("Page.enable", null);
        allocator.free(page_enable);
        const network_enable = try client.sendCommand("Network.enable", null);
        allocator.free(network_enable);

        // Intercept file chooser dialogs
        const intercept_file = try client.sendCommand("Page.setInterceptFileChooserDialog", "{\"enabled\":true}");
        allocator.free(intercept_file);

        // Connect 3 WebSockets for input (mouse, keyboard, navigation)
        // Wait for Chrome to be ready on port 9222 with retries
        var ws_url: ?[]const u8 = null;
        var retry: u32 = 0;
        while (retry < 10) : (retry += 1) {
            std.Thread.sleep(200 * std.time.ns_per_ms);
            ws_url = client.discoverPageWebSocketUrl(allocator) catch null;
            if (ws_url != null) break;
        }

        if (ws_url) |url| {
            defer allocator.free(url);
            client.mouse_ws = websocket_cdp.WebSocketCdpClient.connect(allocator, url) catch null;
            client.keyboard_ws = websocket_cdp.WebSocketCdpClient.connect(allocator, url) catch null;
            client.nav_ws = websocket_cdp.WebSocketCdpClient.connect(allocator, url) catch null;
        }

        return client;
    }

    /// Discover page WebSocket URL from Chrome's HTTP endpoint
    fn discoverPageWebSocketUrl(self: *CdpClient, allocator: std.mem.Allocator) ![]const u8 {
        _ = self;
        // Connect to Chrome's /json/list endpoint to get the page's WebSocket URL
        const stream = std.net.tcpConnectToHost(allocator, "127.0.0.1", 9222) catch {
            return CdpError.WebSocketConnectionFailed;
        };
        defer stream.close();

        // Send HTTP request
        const request = "GET /json/list HTTP/1.1\r\nHost: 127.0.0.1:9222\r\n\r\n";
        _ = stream.write(request) catch return CdpError.WebSocketConnectionFailed;

        // Read response
        var buf: [8192]u8 = undefined;
        const n = stream.read(&buf) catch return CdpError.WebSocketConnectionFailed;
        const response = buf[0..n];

        // Find webSocketDebuggerUrl in response
        const marker = "\"webSocketDebuggerUrl\":\"";
        const start_pos = std.mem.indexOf(u8, response, marker) orelse return CdpError.InvalidResponse;
        const url_start = start_pos + marker.len;
        const url_end = std.mem.indexOfPos(u8, response, url_start, "\"") orelse return CdpError.InvalidResponse;

        return try allocator.dupe(u8, response[url_start..url_end]);
    }

    /// Attach to a page target to enable page-level commands
    fn attachToPageTarget(self: *CdpClient) !void {
        // Step 1: Get list of targets
        const targets_response = try self.pipe_client.sendCommand("Target.getTargets", null);
        defer self.allocator.free(targets_response);

        // Parse targetId from response - look for type "page"
        // Format: {"id":N,"result":{"targetInfos":[{"targetId":"XXX","type":"page",...}]}}
        const target_id = try self.extractPageTargetId(targets_response);
        defer self.allocator.free(target_id);

        // Step 2: Attach to the page target with flatten mode
        const params = try std.fmt.allocPrint(
            self.allocator,
            "{{\"targetId\":\"{s}\",\"flatten\":true}}",
            .{target_id},
        );
        defer self.allocator.free(params);

        const attach_response = try self.pipe_client.sendCommand("Target.attachToTarget", params);
        defer self.allocator.free(attach_response);

        // Extract sessionId from response
        // Format: {"id":N,"result":{"sessionId":"XXX"}}
        self.session_id = try self.extractSessionId(attach_response);
    }

    /// Extract page targetId from Target.getTargets response
    fn extractPageTargetId(self: *CdpClient, response: []const u8) ![]const u8 {
        // Find "type":"page" first
        const type_pos = std.mem.indexOf(u8, response, "\"type\":\"page\"") orelse
            return CdpError.NoPageTarget;

        // Search backwards for targetId
        const search_start = if (type_pos > 200) type_pos - 200 else 0;
        const search_slice = response[search_start..type_pos];

        const target_id_marker = "\"targetId\":\"";
        const target_id_pos = std.mem.lastIndexOf(u8, search_slice, target_id_marker) orelse
            return CdpError.NoPageTarget;

        const id_start = search_start + target_id_pos + target_id_marker.len;
        const id_end_marker = std.mem.indexOfPos(u8, response, id_start, "\"") orelse
            return CdpError.NoPageTarget;

        return try self.allocator.dupe(u8, response[id_start..id_end_marker]);
    }

    /// Extract sessionId from Target.attachToTarget response
    fn extractSessionId(self: *CdpClient, response: []const u8) ![]const u8 {
        const session_marker = "\"sessionId\":\"";
        const session_pos = std.mem.indexOf(u8, response, session_marker) orelse
            return CdpError.InvalidResponse;

        const id_start = session_pos + session_marker.len;
        const id_end = std.mem.indexOfPos(u8, response, id_start, "\"") orelse
            return CdpError.InvalidResponse;

        return try self.allocator.dupe(u8, response[id_start..id_end]);
    }

    pub fn deinit(self: *CdpClient) void {
        if (self.mouse_ws) |ws| ws.deinit();
        if (self.keyboard_ws) |ws| ws.deinit();
        if (self.nav_ws) |ws| ws.deinit();
        if (self.session_id) |sid| self.allocator.free(sid);
        self.pipe_client.deinit();
        self.allocator.destroy(self);
    }

    /// Format a command with sessionId for page-level commands
    fn formatSessionCommand(self: *CdpClient, method: []const u8, params: ?[]const u8) ![]const u8 {
        if (self.session_id) |sid| {
            if (params) |p| {
                return try std.fmt.allocPrint(
                    self.allocator,
                    "{{\"sessionId\":\"{s}\",\"method\":\"{s}\",\"params\":{s}}}",
                    .{ sid, method, p },
                );
            } else {
                return try std.fmt.allocPrint(
                    self.allocator,
                    "{{\"sessionId\":\"{s}\",\"method\":\"{s}\"}}",
                    .{ sid, method },
                );
            }
        } else {
            // No session - shouldn't happen after init
            return CdpError.InvalidResponse;
        }
    }

    /// Send mouse command (fire-and-forget) - uses dedicated mouse WebSocket
    pub fn sendMouseCommandAsync(
        self: *CdpClient,
        method: []const u8,
        params: ?[]const u8,
    ) !void {
        if (self.mouse_ws) |ws| {
            return ws.sendCommandAsync(method, params);
        }
        // Fallback to pipe if websocket not connected
        if (self.session_id != null) {
            return self.pipe_client.sendSessionCommandAsync(self.session_id.?, method, params);
        }
        return self.pipe_client.sendCommandAsync(method, params);
    }

    /// Send keyboard command (fire-and-forget) - uses dedicated keyboard WebSocket
    pub fn sendKeyboardCommandAsync(
        self: *CdpClient,
        method: []const u8,
        params: ?[]const u8,
    ) !void {
        if (self.keyboard_ws) |ws| {
            return ws.sendCommandAsync(method, params);
        }
        // Fallback to pipe if websocket not connected
        if (self.session_id != null) {
            return self.pipe_client.sendSessionCommandAsync(self.session_id.?, method, params);
        }
        return self.pipe_client.sendCommandAsync(method, params);
    }

    /// Send navigation command and wait for response - uses pipe with session
    /// Note: We use pipe instead of WebSocket because nav_ws doesn't have a reader thread
    pub fn sendNavCommand(
        self: *CdpClient,
        method: []const u8,
        params: ?[]const u8,
    ) ![]u8 {
        // Always use pipe with session for navigation - WebSocket blocks without reader thread
        if (self.session_id != null) {
            return self.pipe_client.sendSessionCommand(self.session_id.?, method, params);
        }
        return self.pipe_client.sendCommand(method, params);
    }

    /// Send navigation command (fire-and-forget) - uses dedicated nav WebSocket
    pub fn sendNavCommandAsync(
        self: *CdpClient,
        method: []const u8,
        params: ?[]const u8,
    ) !void {
        if (self.nav_ws) |ws| {
            return ws.sendCommandAsync(method, params);
        }
        // Fallback to pipe if websocket not connected
        if (self.session_id != null) {
            return self.pipe_client.sendSessionCommandAsync(self.session_id.?, method, params);
        }
        return self.pipe_client.sendCommandAsync(method, params);
    }

    /// Send CDP command and wait for response - uses session
    pub fn sendCommand(
        self: *CdpClient,
        method: []const u8,
        params: ?[]const u8,
    ) ![]u8 {
        if (self.session_id != null) {
            return self.pipe_client.sendSessionCommand(self.session_id.?, method, params);
        }
        return self.pipe_client.sendCommand(method, params);
    }

    /// Send CDP command without waiting for response - uses session
    pub fn sendCommandAsync(
        self: *CdpClient,
        method: []const u8,
        params: ?[]const u8,
    ) !void {
        if (self.session_id != null) {
            return self.pipe_client.sendSessionCommandAsync(self.session_id.?, method, params);
        }
        return self.pipe_client.sendCommandAsync(method, params);
    }

    /// Start screencast streaming
    pub fn startScreencast(
        self: *CdpClient,
        format: []const u8,
        quality: u8,
        width: u32,
        height: u32,
    ) !void {
        // Start reader thread first
        try self.pipe_client.startReaderThread();

        // Send startScreencast command with session
        const params = try std.fmt.allocPrint(
            self.allocator,
            "{{\"format\":\"{s}\",\"quality\":{d},\"maxWidth\":{d},\"maxHeight\":{d},\"everyNthFrame\":1}}",
            .{ format, quality, width, height },
        );
        defer self.allocator.free(params);

        const result = try self.sendCommand("Page.startScreencast", params);
        defer self.allocator.free(result);
    }

    /// Stop screencast streaming
    pub fn stopScreencast(self: *CdpClient) !void {
        self.pipe_client.stopReaderThread();
    }

    /// Get latest screencast frame (non-blocking)
    pub fn getLatestFrame(self: *CdpClient) ?ScreencastFrame {
        return self.pipe_client.getLatestFrame();
    }

    /// Get count of frames received
    pub fn getFrameCount(self: *CdpClient) u32 {
        return self.pipe_client.getFrameCount();
    }

    pub fn nextEvent(self: *CdpClient, allocator: std.mem.Allocator) !?CdpEvent {
        const raw = try self.pipe_client.nextEvent(allocator) orelse return null;
        return CdpEvent{
            .method = raw.method,
            .payload = raw.payload,
            .allocator = allocator,
        };
    }
};
