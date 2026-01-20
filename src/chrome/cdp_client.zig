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
const json = @import("json");

fn logToFile(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, fmt, args) catch return;

    const file = std.fs.cwd().openFile("cdp_debug.log", .{ .mode = .read_write }) catch |err| blk: {
        if (err == error.FileNotFound) {
             break :blk std.fs.cwd().createFile("cdp_debug.log", .{ .read = true }) catch return;
        }
        return;
    };
    defer file.close();
    file.seekFromEnd(0) catch return;
    file.writeAll(slice) catch return;
}

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
    debug_port: u16, // Chrome's debugging port for WebSocket connections

    // WebSocket clients for input (separate from screencast pipe)
    mouse_ws: ?*websocket_cdp.WebSocketCdpClient,
    keyboard_ws: ?*websocket_cdp.WebSocketCdpClient,
    nav_ws: ?*websocket_cdp.WebSocketCdpClient,

    /// Initialize CDP client from pipe file descriptors
    /// read_fd: FD to read from Chrome (Chrome's FD 4)
    /// write_fd: FD to write to Chrome (Chrome's FD 3)
    /// debug_port: Chrome's debugging port for WebSocket connections
    pub fn initFromPipe(allocator: std.mem.Allocator, read_fd: std.posix.fd_t, write_fd: std.posix.fd_t, debug_port: u16) !*CdpClient {
        const client = try allocator.create(CdpClient);
        client.* = .{
            .allocator = allocator,
            .pipe_client = try cdp_pipe.PipeCdpClient.init(allocator, read_fd, write_fd),
            .session_id = null,
            .debug_port = debug_port,
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

        // Inject File System Access API polyfill with full file system bridge
        // Security: Only allows access to directories user explicitly selected via picker
        const polyfill_script = @embedFile("fs_polyfill.js");
        var polyfill_json_buf: [65536]u8 = undefined;
        const polyfill_json = escapeJsonString(polyfill_script, &polyfill_json_buf) catch return error.OutOfMemory;

        var polyfill_params_buf: [65536]u8 = undefined;
        const polyfill_params = std.fmt.bufPrint(&polyfill_params_buf, "{{\"source\":{s}}}", .{polyfill_json}) catch return error.OutOfMemory;
        const polyfill_result = try client.sendCommand("Page.addScriptToEvaluateOnNewDocument", polyfill_params);
        allocator.free(polyfill_result);

        // Enable Runtime domain to receive console messages
        const runtime_enable = try client.sendCommand("Runtime.enable", null);
        allocator.free(runtime_enable);

        // Connect 3 WebSockets for input (mouse, keyboard, navigation)
        // Wait for Chrome to be ready on the discovered port with retries
        std.debug.print("Connecting WebSockets to port {}...\n", .{client.debug_port});
        var ws_url: ?[]const u8 = null;
        var retry: u32 = 0;
        // Increase timeout to 10s (50 * 200ms) as Chrome can be slow to start listening
        while (retry < 50) : (retry += 1) {
            std.Thread.sleep(200 * std.time.ns_per_ms);
            ws_url = client.discoverPageWebSocketUrl(allocator) catch blk: {
                if (retry % 5 == 0) logToFile("[CDP] Retry {}/50: Failed to get WS URL\n", .{retry});
                break :blk null;
            };
            if (ws_url != null) break;
        } else {
            // Failed to discover WebSocket URL
            std.debug.print("[CDP] Failed to discover page WebSocket URL after 50 retries\n", .{});
            return CdpError.WebSocketConnectionFailed;
        }
        std.debug.print("Got WebSocket URL\n", .{});

        if (ws_url) |url| {
            defer allocator.free(url);

            // Connect strictly - failure is fatal
            std.debug.print("Connecting mouse_ws...\n", .{});
            client.mouse_ws = try websocket_cdp.WebSocketCdpClient.connect(allocator, url);
            std.debug.print("Connecting keyboard_ws...\n", .{});
            client.keyboard_ws = try websocket_cdp.WebSocketCdpClient.connect(allocator, url);
            std.debug.print("Connecting nav_ws...\n", .{});
            client.nav_ws = try websocket_cdp.WebSocketCdpClient.connect(allocator, url);

            // Start reader threads strictly - failure is fatal
            std.debug.print("Starting reader threads...\n", .{});
            try client.mouse_ws.?.startReaderThread();
            try client.keyboard_ws.?.startReaderThread();
            try client.nav_ws.?.startReaderThread();
        }

        std.debug.print("CDP client ready\n", .{});
        return client;
    }

    /// Discover page WebSocket URL from Chrome's HTTP endpoint
    fn discoverPageWebSocketUrl(self: *CdpClient, allocator: std.mem.Allocator) ![]const u8 {
        // Connect to Chrome's /json/list endpoint to get the page's WebSocket URL
        const stream = std.net.tcpConnectToHost(allocator, "127.0.0.1", self.debug_port) catch |err| {
            // std.debug.print("[CDP] TCP connect to {} failed: {}\n", .{self.debug_port, err});
            return err;
        };
        defer stream.close();

        // Send HTTP request
        var request_buf: [128]u8 = undefined;
        const request = std.fmt.bufPrint(&request_buf, "GET /json/list HTTP/1.1\r\nHost: 127.0.0.1:{}\r\n\r\n", .{self.debug_port}) catch return CdpError.OutOfMemory;
        _ = stream.write(request) catch return CdpError.WebSocketConnectionFailed;

        // Read response
        var buf: [8192]u8 = undefined;
        const n = stream.read(&buf) catch return CdpError.WebSocketConnectionFailed;
        const response = buf[0..n];

        // Find end of HTTP headers
        const header_end_marker = "\r\n\r\n";
        const body_start = std.mem.indexOf(u8, response, header_end_marker) orelse return CdpError.InvalidResponse;
        const body = response[body_start + header_end_marker.len ..];

        // Parse JSON response using SIMD parser
        var parsed = json.parse(allocator, body) catch return CdpError.InvalidResponse;
        defer parsed.deinit(allocator);

        // Iterate over targets to find one with type="page"
        if (parsed != .array) return CdpError.InvalidResponse;

        for (parsed.array.items) |target| {
            if (target != .object) continue;
            
            const type_val = target.object.get("type") orelse continue;
            if (type_val != .string or !std.mem.eql(u8, type_val.string, "page")) continue;

            const url_val = target.object.get("webSocketDebuggerUrl") orelse continue;
            if (url_val == .string) {
                return try allocator.dupe(u8, url_val.string);
            }
        }
        
        // Return first target if no page found (fallback)
        if (parsed.array.items.len > 0) {
            const target = parsed.array.items[0];
             if (target == .object) {
                 if (target.object.get("webSocketDebuggerUrl")) |url_val| {
                     if (url_val == .string) return try allocator.dupe(u8, url_val.string);
                 }
             }
        }

        return CdpError.NoPageTarget;
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
    /// Silently ignores errors - safe during shutdown
    pub fn sendMouseCommandAsync(
        self: *CdpClient,
        method: []const u8,
        params: ?[]const u8,
    ) void {
        if (self.mouse_ws) |ws| {
            ws.sendCommandAsync(method, params);
            return;
        }
        // Fallback to pipe if websocket not connected
        if (self.session_id != null) {
            self.pipe_client.sendSessionCommandAsync(self.session_id.?, method, params) catch {};
            return;
        }
        self.pipe_client.sendCommandAsync(method, params) catch {};
    }

    /// Send keyboard command (fire-and-forget) - uses dedicated keyboard WebSocket
    /// Silently ignores errors - safe during shutdown
    pub fn sendKeyboardCommandAsync(
        self: *CdpClient,
        method: []const u8,
        params: ?[]const u8,
    ) void {
        if (self.keyboard_ws) |ws| {
            ws.sendCommandAsync(method, params);
            return;
        }
        // Fallback to pipe if websocket not connected
        if (self.session_id != null) {
            self.pipe_client.sendSessionCommandAsync(self.session_id.?, method, params) catch {};
            return;
        }
        self.pipe_client.sendCommandAsync(method, params) catch {};
    }

    /// Send navigation command and wait for response - uses dedicated nav WebSocket
    pub fn sendNavCommand(
        self: *CdpClient,
        method: []const u8,
        params: ?[]const u8,
    ) ![]u8 {
        if (self.nav_ws) |ws| {
            return ws.sendCommand(method, params);
        }
        return CdpError.WebSocketConnectionFailed;
    }

    /// Send navigation command (fire-and-forget) - uses dedicated nav WebSocket
    pub fn sendNavCommandAsync(
        self: *CdpClient,
        method: []const u8,
        params: ?[]const u8,
    ) void {
        if (self.nav_ws) |ws| {
            ws.sendCommandAsync(method, params);
        }
    }

    /// Reconnect all 3 WebSockets to current page target
    /// Cross-origin navigation creates new page target, invalidating all connections
    fn reconnectAllWebSockets(self: *CdpClient) !void {
        logToFile("[CDP] Reconnecting all WebSockets...\n", .{});

        // Close old connections
        if (self.mouse_ws) |ws| {
            ws.deinit();
            self.mouse_ws = null;
        }
        if (self.keyboard_ws) |ws| {
            ws.deinit();
            self.keyboard_ws = null;
        }
        if (self.nav_ws) |ws| {
            ws.deinit();
            self.nav_ws = null;
        }

        // Discover new page WebSocket URL
        const ws_url = try self.discoverPageWebSocketUrl(self.allocator);
        defer self.allocator.free(ws_url);

        // Connect all 3 WebSockets
        self.mouse_ws = try websocket_cdp.WebSocketCdpClient.connect(self.allocator, ws_url);
        self.keyboard_ws = try websocket_cdp.WebSocketCdpClient.connect(self.allocator, ws_url);
        self.nav_ws = try websocket_cdp.WebSocketCdpClient.connect(self.allocator, ws_url);

        // Start reader threads
        try self.mouse_ws.?.startReaderThread();
        try self.keyboard_ws.?.startReaderThread();
        try self.nav_ws.?.startReaderThread();

        logToFile("[CDP] All WebSockets reconnected successfully\n", .{});
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

    /// Check if navigation happened (event bus pattern)
    /// Returns true if a navigation event occurred since last check, and clears the flag
    pub fn checkNavigationHappened(self: *CdpClient) bool {
        return self.pipe_client.checkNavigationHappened();
    }
};

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
