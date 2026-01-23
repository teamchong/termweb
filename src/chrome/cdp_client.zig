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
const json_utils = @import("../utils/json.zig");

/// Debug logging - disabled by default for performance
/// Set TERMWEB_CDP_DEBUG=1 to enable (truncates log on startup)
var cdp_debug_enabled: ?bool = null;
var cdp_debug_file: ?std.fs.File = null;
var cdp_debug_bytes: usize = 0;
const CDP_DEBUG_MAX_SIZE: usize = 10 * 1024 * 1024; // 10MB max, then truncate

fn logToFile(comptime fmt: []const u8, args: anytype) void {
    // Check if debug is enabled (cached after first check)
    if (cdp_debug_enabled == null) {
        cdp_debug_enabled = if (std.posix.getenv("TERMWEB_CDP_DEBUG")) |v|
            std.mem.eql(u8, v, "1")
        else
            false;

        // Truncate on startup for fresh log each run
        if (cdp_debug_enabled.?) {
            cdp_debug_file = std.fs.cwd().createFile("cdp_debug.log", .{ .truncate = true }) catch null;
        }
    }

    if (!cdp_debug_enabled.?) return;

    const file = cdp_debug_file orelse return;

    // Auto-truncate if log gets too large
    if (cdp_debug_bytes > CDP_DEBUG_MAX_SIZE) {
        file.seekTo(0) catch {};
        file.setEndPos(0) catch {};
        cdp_debug_bytes = 0;
        _ = file.write("--- LOG TRUNCATED (exceeded 10MB) ---\n") catch {};
    }

    var buf: [4096]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, fmt, args) catch return;
    cdp_debug_bytes += file.write(slice) catch 0;
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
/// - pipe_client: screencast frames (high bandwidth) - optional for WebSocket-only mode
/// - mouse_ws: mouse input (low latency)
/// - keyboard_ws: keyboard input (low latency)
/// - nav_ws: navigation commands (low latency)
pub const CdpClient = struct {
    allocator: std.mem.Allocator,
    pipe_client: ?*cdp_pipe.PipeCdpClient, // null for WebSocket-only mode
    session_id: ?[]const u8, // Session ID for page-level commands
    debug_port: u16, // Chrome's debugging port for WebSocket connections
    websocket_only: bool, // true if using WebSocket for everything (no pipe)

    // WebSocket clients (pipe is ONLY for screencast frames)
    mouse_ws: ?*websocket_cdp.WebSocketCdpClient,
    keyboard_ws: ?*websocket_cdp.WebSocketCdpClient,
    nav_ws: ?*websocket_cdp.WebSocketCdpClient,
    browser_ws: ?*websocket_cdp.WebSocketCdpClient, // Browser-level for downloads
    screencast_ws: ?*websocket_cdp.WebSocketCdpClient, // For WebSocket-only screencast

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
            .websocket_only = false,
            .mouse_ws = null,
            .keyboard_ws = null,
            .nav_ws = null,
            .browser_ws = null,
            .screencast_ws = null,
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

        // Create downloads directory (actual download setup happens on nav_ws later)
        std.fs.makeDirAbsolute("/tmp/termweb-downloads") catch |err| {
            if (err != error.PathAlreadyExists) {
                logToFile("[CDP] Failed to create download dir: {}\n", .{err});
            }
        };

        // Inject File System Access API polyfill with full file system bridge
        // Security: Only allows access to directories user explicitly selected via picker
        const polyfill_script = @embedFile("fs_polyfill.js");
        var polyfill_json_buf: [65536]u8 = undefined;
        const polyfill_json = json_utils.escapeString(polyfill_script, &polyfill_json_buf) catch return error.OutOfMemory;

        var polyfill_params_buf: [65536]u8 = undefined;
        const polyfill_params = std.fmt.bufPrint(&polyfill_params_buf, "{{\"source\":{s}}}", .{polyfill_json}) catch return error.OutOfMemory;
        const polyfill_result = try client.sendCommand("Page.addScriptToEvaluateOnNewDocument", polyfill_params);
        allocator.free(polyfill_result);

        // Grant clipboard permissions for read/write access
        // This allows navigator.clipboard.readText() to work without user gesture
        const perm_result = client.sendCommand("Browser.grantPermissions", "{\"permissions\":[\"clipboardReadWrite\",\"clipboardSanitizedWrite\"]}") catch null;
        if (perm_result) |r| allocator.free(r);

        // Inject Clipboard interceptor polyfill - runs in all frames (including iframes)
        // This enables bidirectional clipboard sync between browser and host
        const clipboard_script = @embedFile("clipboard_polyfill.js");
        var clipboard_json_buf: [16384]u8 = undefined;
        const clipboard_json = json_utils.escapeString(clipboard_script, &clipboard_json_buf) catch return error.OutOfMemory;

        var clipboard_params_buf: [32768]u8 = undefined;
        const clipboard_params = std.fmt.bufPrint(&clipboard_params_buf, "{{\"source\":{s}}}", .{clipboard_json}) catch return error.OutOfMemory;
        const clipboard_result = try client.sendCommand("Page.addScriptToEvaluateOnNewDocument", clipboard_params);
        allocator.free(clipboard_result);

        // NOTE: Runtime.enable is called on nav_ws after WebSocket connect (not on pipe)
        // Pipe is ONLY for screencast frames - events come from nav_ws

        // Connect 3 WebSockets for input (mouse, keyboard, navigation)
        // Wait for Chrome to be ready on the discovered port with retries
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
            return CdpError.WebSocketConnectionFailed;
        }

        if (ws_url) |url| {
            defer allocator.free(url);

            // Connect strictly - failure is fatal
            client.mouse_ws = try websocket_cdp.WebSocketCdpClient.connect(allocator, url);
            client.keyboard_ws = try websocket_cdp.WebSocketCdpClient.connect(allocator, url);
            client.nav_ws = try websocket_cdp.WebSocketCdpClient.connect(allocator, url);

            // Start reader threads strictly - failure is fatal
            try client.mouse_ws.?.startReaderThread();
            try client.keyboard_ws.?.startReaderThread();
            try client.nav_ws.?.startReaderThread();

            // Enable Runtime domain on nav_ws to receive console events
            // This MUST be on nav_ws, not pipe - pipe is only for screencast
            const runtime_result = try client.nav_ws.?.sendCommand("Runtime.enable", null);
            allocator.free(runtime_result);

            // Enable Page domain on nav_ws to receive navigation events
            // This duplicates pipe's Page.enable but ensures events come through nav_ws
            const page_result = try client.nav_ws.?.sendCommand("Page.enable", null);
            allocator.free(page_result);

        }

        // Connect browser_ws for Browser domain events (downloads)
        if (client.discoverBrowserWebSocketUrl(allocator)) |browser_url| {
            defer allocator.free(browser_url);
            client.browser_ws = websocket_cdp.WebSocketCdpClient.connect(allocator, browser_url) catch null;
            if (client.browser_ws) |bws| {
                try bws.startReaderThread();
                const download_params = try std.fmt.allocPrint(allocator, "{{\"behavior\":\"allow\",\"downloadPath\":\"/tmp/termweb-downloads\",\"eventsEnabled\":true}}", .{});
                defer allocator.free(download_params);
                const download_result = try bws.sendCommand("Browser.setDownloadBehavior", download_params);
                allocator.free(download_result);

                // Enable target discovery to detect new tabs/popups
                const target_result = try bws.sendCommand("Target.setDiscoverTargets", "{\"discover\":true}");
                allocator.free(target_result);
            }
        } else |_| {}
        return client;
    }

    /// Initialize CDP client from WebSocket only (no pipe)
    /// Use this when pipe transport doesn't work (e.g., some Linux environments)
    pub fn initFromPort(allocator: std.mem.Allocator, debug_port: u16) !*CdpClient {
        const client = try allocator.create(CdpClient);
        client.* = .{
            .allocator = allocator,
            .pipe_client = null, // No pipe in WebSocket-only mode
            .session_id = null,
            .debug_port = debug_port,
            .websocket_only = true,
            .mouse_ws = null,
            .keyboard_ws = null,
            .nav_ws = null,
            .browser_ws = null,
            .screencast_ws = null,
        };

        // Connect WebSockets first (no pipe to initialize)
        var ws_url: ?[]const u8 = null;
        var retry: u32 = 0;
        while (retry < 50) : (retry += 1) {
            std.Thread.sleep(200 * std.time.ns_per_ms);
            ws_url = client.discoverPageWebSocketUrl(allocator) catch continue;
            break;
        }

        if (ws_url == null) {
            allocator.destroy(client);
            return CdpError.WebSocketConnectionFailed;
        }

        {
            const url = ws_url.?;
            defer allocator.free(url);

            // Connect all WebSockets including screencast_ws
            client.mouse_ws = try websocket_cdp.WebSocketCdpClient.connect(allocator, url);
            client.keyboard_ws = try websocket_cdp.WebSocketCdpClient.connect(allocator, url);
            client.nav_ws = try websocket_cdp.WebSocketCdpClient.connect(allocator, url);
            client.screencast_ws = try websocket_cdp.WebSocketCdpClient.connect(allocator, url);

            // Start reader thread on nav_ws and screencast_ws
            try client.nav_ws.?.startReaderThread();
            try client.screencast_ws.?.startReaderThread();

            // Enable domains via nav_ws
            const runtime_result = try client.nav_ws.?.sendCommand("Runtime.enable", null);
            allocator.free(runtime_result);

            const page_result = try client.nav_ws.?.sendCommand("Page.enable", null);
            allocator.free(page_result);

            const network_result = try client.nav_ws.?.sendCommand("Network.enable", null);
            allocator.free(network_result);

            // Intercept file chooser
            const intercept_result = try client.nav_ws.?.sendCommand("Page.setInterceptFileChooserDialog", "{\"enabled\":true}");
            allocator.free(intercept_result);
        }

        // Inject polyfills via nav_ws
        const polyfill_script = @embedFile("fs_polyfill.js");
        var polyfill_json_buf: [65536]u8 = undefined;
        const polyfill_json = json_utils.escapeString(polyfill_script, &polyfill_json_buf) catch return error.OutOfMemory;

        var polyfill_params_buf: [65536]u8 = undefined;
        const polyfill_params = std.fmt.bufPrint(&polyfill_params_buf, "{{\"source\":{s}}}", .{polyfill_json}) catch return error.OutOfMemory;
        const polyfill_result = try client.nav_ws.?.sendCommand("Page.addScriptToEvaluateOnNewDocument", polyfill_params);
        allocator.free(polyfill_result);

        // Clipboard polyfill
        const clipboard_script = @embedFile("clipboard_polyfill.js");
        var clipboard_json_buf: [16384]u8 = undefined;
        const clipboard_json = json_utils.escapeString(clipboard_script, &clipboard_json_buf) catch return error.OutOfMemory;

        var clipboard_params_buf: [32768]u8 = undefined;
        const clipboard_params = std.fmt.bufPrint(&clipboard_params_buf, "{{\"source\":{s}}}", .{clipboard_json}) catch return error.OutOfMemory;
        const clipboard_result = try client.nav_ws.?.sendCommand("Page.addScriptToEvaluateOnNewDocument", clipboard_params);
        allocator.free(clipboard_result);

        // Connect browser_ws
        if (client.discoverBrowserWebSocketUrl(allocator)) |browser_url| {
            defer allocator.free(browser_url);
            client.browser_ws = websocket_cdp.WebSocketCdpClient.connect(allocator, browser_url) catch null;
            if (client.browser_ws) |bws| {
                try bws.startReaderThread();
                const download_params = try std.fmt.allocPrint(allocator, "{{\"behavior\":\"allow\",\"downloadPath\":\"/tmp/termweb-downloads\",\"eventsEnabled\":true}}", .{});
                defer allocator.free(download_params);
                const download_result = try bws.sendCommand("Browser.setDownloadBehavior", download_params);
                allocator.free(download_result);
            }
        } else |_| {}

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

    /// Discover browser WebSocket URL from /json/version
    fn discoverBrowserWebSocketUrl(self: *CdpClient, allocator: std.mem.Allocator) ![]const u8 {
        const stream = std.net.tcpConnectToHost(allocator, "127.0.0.1", self.debug_port) catch |err| {
            return err;
        };
        defer stream.close();

        var request_buf: [128]u8 = undefined;
        const request = std.fmt.bufPrint(&request_buf, "GET /json/version HTTP/1.1\r\nHost: 127.0.0.1:{}\r\n\r\n", .{self.debug_port}) catch return CdpError.OutOfMemory;
        _ = stream.write(request) catch return CdpError.WebSocketConnectionFailed;

        var buf: [4096]u8 = undefined;
        const n = stream.read(&buf) catch return CdpError.WebSocketConnectionFailed;
        const response = buf[0..n];

        const header_end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return CdpError.InvalidResponse;
        const body = response[header_end + 4 ..];

        var parsed = json.parse(allocator, body) catch return CdpError.InvalidResponse;
        defer parsed.deinit(allocator);

        if (parsed != .object) return CdpError.InvalidResponse;
        const url_val = parsed.object.get("webSocketDebuggerUrl") orelse return CdpError.InvalidResponse;
        if (url_val == .string) {
            return try allocator.dupe(u8, url_val.string);
        }
        return CdpError.InvalidResponse;
    }

    /// Attach to a page target to enable page-level commands
    /// Only used in pipe mode - WebSocket mode connects directly to page
    fn attachToPageTarget(self: *CdpClient) !void {
        // Step 1: Get list of targets
        const targets_response = try self.pipe_client.?.sendCommand("Target.getTargets", null);
        defer self.allocator.free(targets_response);

        // Parse targetId from response - look for type "page"
        // Format: {"id":N,"result":{"targetInfos":[{"targetId":"XXX","type":"page",...}]}}
        const target_id = try self.extractPageTargetId(targets_response);
        defer self.allocator.free(target_id);

        // Step 2: Attach to the page target with flatten mode
        // Escape target_id for JSON (handles any special chars)
        var escape_buf: [512]u8 = undefined;
        const escaped_id = json_utils.escapeContents(target_id, &escape_buf) catch return error.OutOfMemory;
        const params = try std.fmt.allocPrint(
            self.allocator,
            "{{\"targetId\":\"{s}\",\"flatten\":true}}",
            .{escaped_id},
        );
        defer self.allocator.free(params);

        const attach_response = try self.pipe_client.?.sendCommand("Target.attachToTarget", params);
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
        if (self.browser_ws) |ws| ws.deinit();
        if (self.screencast_ws) |ws| ws.deinit();
        if (self.session_id) |sid| self.allocator.free(sid);
        if (self.pipe_client) |pc| pc.deinit();
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
        // Fallback to pipe if websocket not connected (pipe mode only)
        if (self.pipe_client) |pc| {
            if (self.session_id != null) {
                pc.sendSessionCommandAsync(self.session_id.?, method, params) catch {};
                return;
            }
            pc.sendCommandAsync(method, params) catch {};
        }
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
        // Fallback to pipe if websocket not connected (pipe mode only)
        if (self.pipe_client) |pc| {
            if (self.session_id != null) {
                pc.sendSessionCommandAsync(self.session_id.?, method, params) catch {};
                return;
            }
            pc.sendCommandAsync(method, params) catch {};
        }
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

        // Re-enable Runtime domain on nav_ws for console events
        const runtime_result = try self.nav_ws.?.sendCommand("Runtime.enable", null);
        self.allocator.free(runtime_result);

        // Re-enable Page domain on nav_ws for navigation events
        const page_result = try self.nav_ws.?.sendCommand("Page.enable", null);
        self.allocator.free(page_result);

        // Re-enable downloads on nav_ws for download events
        const download_params = try std.fmt.allocPrint(self.allocator, "{{\"behavior\":\"allow\",\"downloadPath\":\"/tmp/termweb-downloads\",\"eventsEnabled\":true}}", .{});
        defer self.allocator.free(download_params);
        const download_result = try self.nav_ws.?.sendCommand("Browser.setDownloadBehavior", download_params);
        self.allocator.free(download_result);

        logToFile("[CDP] All WebSockets reconnected successfully\n", .{});
    }

    /// Send CDP command and wait for response - uses session
    pub fn sendCommand(
        self: *CdpClient,
        method: []const u8,
        params: ?[]const u8,
    ) ![]u8 {
        // In WebSocket-only mode, use nav_ws
        if (self.websocket_only) {
            if (self.nav_ws) |ws| {
                return ws.sendCommand(method, params);
            }
            return CdpError.WebSocketConnectionFailed;
        }
        // Pipe mode
        if (self.session_id != null) {
            return self.pipe_client.?.sendSessionCommand(self.session_id.?, method, params);
        }
        return self.pipe_client.?.sendCommand(method, params);
    }

    /// Send CDP command without waiting for response - uses session
    pub fn sendCommandAsync(
        self: *CdpClient,
        method: []const u8,
        params: ?[]const u8,
    ) !void {
        // In WebSocket-only mode, use nav_ws
        if (self.websocket_only) {
            if (self.nav_ws) |ws| {
                ws.sendCommandAsync(method, params);
                return;
            }
            return CdpError.WebSocketConnectionFailed;
        }
        // Pipe mode
        if (self.session_id != null) {
            return self.pipe_client.?.sendSessionCommandAsync(self.session_id.?, method, params);
        }
        return self.pipe_client.?.sendCommandAsync(method, params);
    }

    /// Start screencast streaming
    pub fn startScreencast(
        self: *CdpClient,
        format: []const u8,
        quality: u8,
        width: u32,
        height: u32,
    ) !void {
        // Send startScreencast command with session
        const params = try std.fmt.allocPrint(
            self.allocator,
            "{{\"format\":\"{s}\",\"quality\":{d},\"maxWidth\":{d},\"maxHeight\":{d},\"everyNthFrame\":2}}",
            .{ format, quality, width, height },
        );
        defer self.allocator.free(params);

        if (self.websocket_only) {
            // WebSocket-only mode - screencast frames come via screencast_ws events
            if (self.screencast_ws) |ws| {
                const result = try ws.sendCommand("Page.startScreencast", params);
                self.allocator.free(result);
            }
        } else {
            // Pipe mode - start reader thread first
            try self.pipe_client.?.startReaderThread();
            const result = try self.sendCommand("Page.startScreencast", params);
            self.allocator.free(result);
        }
    }

    /// Stop screencast streaming (for resize - keeps reader thread alive)
    /// Call stopScreencastFull for complete shutdown
    pub fn stopScreencast(self: *CdpClient) !void {
        // Send Page.stopScreencast to Chrome to stop frames
        // Don't stop the reader thread - we need it for the next startScreencast
        const result = self.sendCommand("Page.stopScreencast", null) catch null;
        if (result) |r| self.allocator.free(r);
    }

    /// Stop screencast completely including reader thread (for shutdown)
    pub fn stopScreencastFull(self: *CdpClient) !void {
        // Send stop command first
        const result = self.sendCommand("Page.stopScreencast", null) catch null;
        if (result) |r| self.allocator.free(r);

        // Now stop the reader thread (pipe mode only)
        if (self.pipe_client) |pc| {
            pc.stopReaderThread();
        }
    }

    /// Get latest screencast frame (non-blocking)
    pub fn getLatestFrame(self: *CdpClient) ?ScreencastFrame {
        if (self.websocket_only) {
            // WebSocket mode - frames come via events, need different handling
            // TODO: Implement WebSocket-based frame retrieval
            return null;
        }
        return self.pipe_client.?.getLatestFrame();
    }

    /// Get count of frames received
    pub fn getFrameCount(self: *CdpClient) u32 {
        if (self.websocket_only) {
            return 0; // TODO: Track WebSocket frame count
        }
        return self.pipe_client.?.getFrameCount();
    }

    /// Get next event from WebSockets
    /// Pipe is ONLY for screencast frames - all events come from WebSockets
    pub fn nextEvent(self: *CdpClient, allocator: std.mem.Allocator) !?CdpEvent {
        _ = allocator;
        // Check browser_ws for download events
        if (self.browser_ws) |bws| {
            if (bws.nextEvent()) |raw| {
                return CdpEvent{
                    .method = raw.method,
                    .payload = raw.payload,
                    .allocator = bws.allocator,
                };
            }
        }
        // Check nav_ws for page events
        const ws = self.nav_ws orelse return null;
        const raw = ws.nextEvent() orelse return null;
        return CdpEvent{
            .method = raw.method,
            .payload = raw.payload,
            .allocator = ws.allocator,
        };
    }

    /// Switch to a different target (for tab switching)
    /// Attaches to the target and updates the session ID
    /// Note: Tab switching not fully supported in WebSocket-only mode
    pub fn switchToTarget(self: *CdpClient, target_id: []const u8) !void {
        logToFile("[CDP] Switching to target: {s}\n", .{target_id});

        // WebSocket-only mode doesn't support session-based targeting well
        // TODO: For WebSocket-only, would need to reconnect to different WebSocket URL
        if (self.websocket_only) {
            logToFile("[CDP] Tab switching not fully supported in WebSocket-only mode\n", .{});
            // Try to activate via nav_ws but don't change sessions
            var activate_buf: [256]u8 = undefined;
            const activate_params = std.fmt.bufPrint(&activate_buf, "{{\"targetId\":\"{s}\"}}", .{target_id}) catch return error.OutOfMemory;
            const activate_result = self.sendCommand("Target.activateTarget", activate_params) catch |err| {
                logToFile("[CDP] Target.activateTarget failed: {}\n", .{err});
                return err;
            };
            self.allocator.free(activate_result);
            return;
        }

        // Activate the target in Chrome (brings it to focus)
        var activate_buf: [256]u8 = undefined;
        const activate_params = std.fmt.bufPrint(&activate_buf, "{{\"targetId\":\"{s}\"}}", .{target_id}) catch return error.OutOfMemory;
        const activate_result = self.pipe_client.?.sendCommand("Target.activateTarget", activate_params) catch |err| {
            logToFile("[CDP] Target.activateTarget failed: {}\n", .{err});
            return err;
        };
        self.allocator.free(activate_result);

        // Attach to the target to get a new session
        var escape_buf: [512]u8 = undefined;
        const escaped_id = json_utils.escapeContents(target_id, &escape_buf) catch return error.OutOfMemory;
        const params = try std.fmt.allocPrint(
            self.allocator,
            "{{\"targetId\":\"{s}\",\"flatten\":true}}",
            .{escaped_id},
        );
        defer self.allocator.free(params);

        const attach_response = self.pipe_client.?.sendCommand("Target.attachToTarget", params) catch |err| {
            logToFile("[CDP] Target.attachToTarget failed: {}\n", .{err});
            return err;
        };
        defer self.allocator.free(attach_response);

        // Extract and update session ID
        const new_session_id = try self.extractSessionId(attach_response);

        // Free old session ID and set new one
        if (self.session_id) |old_sid| {
            self.allocator.free(old_sid);
        }
        self.session_id = new_session_id;

        logToFile("[CDP] Switched to target, new session: {s}\n", .{new_session_id});

        // Re-enable Page domain on the new session (for events)
        const page_result = try self.sendCommand("Page.enable", null);
        self.allocator.free(page_result);
    }
};
