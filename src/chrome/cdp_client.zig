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

/// Debug logging - always enabled, appends to cdp_debug.log
fn logToFile(comptime fmt: []const u8, args: anytype) void {
    // Always log to cdp_debug.log (append mode like websocket_cdp.zig)
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

/// CDP Client - Supports both Pipe+WebSocket and WebSocket-only modes
///
/// Pipe+WebSocket mode (legacy):
/// - pipe_client: screencast frames (high bandwidth)
/// - page_ws: all page-level commands (mouse, keyboard, navigation, events)
/// - browser_ws: browser-level commands (downloads)
///
/// WebSocket-only mode:
/// - pipe_client: null
/// - page_ws: handles EVERYTHING including screencast frames
/// - browser_ws: browser-level commands (downloads)
pub const CdpClient = struct {
    allocator: std.mem.Allocator,
    pipe_client: ?*cdp_pipe.PipeCdpClient,
    session_id: ?[]const u8, // Session ID for page-level commands
    current_target_id: ?[]const u8, // Current target ID (for tab switching)
    debug_port: u16, // Chrome's debugging port for WebSocket connections

    // WebSocket clients
    // In WebSocket-only mode, page_ws handles screencast frames too
    page_ws: ?*websocket_cdp.WebSocketCdpClient, // All page-level commands
    browser_ws: ?*websocket_cdp.WebSocketCdpClient, // Browser-level for downloads
    page_ws_mutex: std.Thread.Mutex, // Protects page_ws reconnection

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
            .current_target_id = null,
            .debug_port = debug_port,
            .page_ws = null,
            .browser_ws = null,
            .page_ws_mutex = .{},
        };

        // Attach to page target to enable page-level commands
        try client.attachToPageTarget();

        // Create downloads directory
        std.fs.makeDirAbsolute("/tmp/termweb-downloads") catch |err| {
            if (err != error.PathAlreadyExists) {
                logToFile("[CDP] Failed to create download dir: {}\n", .{err});
            }
        };

        // === ASYNC INIT: Fire commands in parallel, await only what's needed ===

        // Send Page.enable async (need to await before scripts)
        const page_enable_id = try client.pipe_client.?.sendSessionCommandAsyncWithId(
            client.session_id.?,
            "Page.enable",
            null,
        );

        // Fire-and-forget: domain enables and permissions (parallel with Page.enable)
        client.sendCommandAsync("Network.enable", null) catch |err| {
            logToFile("[CDP] Network.enable async failed: {}\n", .{err});
        };
        client.sendCommandAsync("Page.setInterceptFileChooserDialog", "{\"enabled\":true}") catch |err| {
            logToFile("[CDP] setInterceptFileChooserDialog async failed: {}\n", .{err});
        };
        client.pipe_client.?.sendCommandAsync("Browser.grantPermissions", "{\"permissions\":[\"clipboardReadWrite\",\"clipboardSanitizedWrite\"]}") catch |err| {
            logToFile("[CDP] grantPermissions async failed: {}\n", .{err});
        };

        // Await Page.enable before injecting scripts
        const page_enable_response = client.pipe_client.?.awaitResponse(page_enable_id) catch |err| {
            logToFile("[CDP] Page.enable await failed: {}\n", .{err});
            return err;
        };
        allocator.free(page_enable_response);

        // Fire-and-forget: polyfill injections (Chrome queues them in order)
        const polyfill_script = @embedFile("fs_polyfill.js");
        var polyfill_json_buf: [65536]u8 = undefined;
        const polyfill_json = json_utils.escapeString(polyfill_script, &polyfill_json_buf) catch return error.OutOfMemory;
        var polyfill_params_buf: [65536]u8 = undefined;
        const polyfill_params = std.fmt.bufPrint(&polyfill_params_buf, "{{\"source\":{s}}}", .{polyfill_json}) catch return error.OutOfMemory;
        client.sendCommandAsync("Page.addScriptToEvaluateOnNewDocument", polyfill_params) catch |err| {
            logToFile("[CDP] fs_polyfill inject failed: {}\n", .{err});
        };

        const clipboard_script = @embedFile("clipboard_polyfill.js");
        var clipboard_json_buf: [16384]u8 = undefined;
        const clipboard_json = json_utils.escapeString(clipboard_script, &clipboard_json_buf) catch return error.OutOfMemory;
        var clipboard_params_buf: [32768]u8 = undefined;
        const clipboard_params = std.fmt.bufPrint(&clipboard_params_buf, "{{\"source\":{s}}}", .{clipboard_json}) catch return error.OutOfMemory;
        client.sendCommandAsync("Page.addScriptToEvaluateOnNewDocument", clipboard_params) catch |err| {
            logToFile("[CDP] clipboard_polyfill inject failed: {}\n", .{err});
        };

        const resize_script = @embedFile("resize_polyfill.js");
        var resize_json_buf: [4096]u8 = undefined;
        const resize_json = json_utils.escapeString(resize_script, &resize_json_buf) catch return error.OutOfMemory;
        var resize_params_buf: [8192]u8 = undefined;
        const resize_params = std.fmt.bufPrint(&resize_params_buf, "{{\"source\":{s},\"worldName\":\"termweb\"}}", .{resize_json}) catch return error.OutOfMemory;
        client.sendCommandAsync("Page.addScriptToEvaluateOnNewDocument", resize_params) catch |err| {
            logToFile("[CDP] resize_polyfill inject failed: {}\n", .{err});
        };

        // NOTE: Runtime.enable is called on page_ws after WebSocket connect (not on pipe)
        // Pipe is ONLY for screencast frames - events come from page_ws

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

            // Connect single page WebSocket for all page-level commands
            client.page_ws = try websocket_cdp.WebSocketCdpClient.connect(allocator, url);
            try client.page_ws.?.startReaderThread();

            // Fire-and-forget: enable domains on page_ws (WebSocket async returns void)
            client.page_ws.?.sendCommandAsync("Runtime.enable", null);
            client.page_ws.?.sendCommandAsync("Page.enable", null);
            client.page_ws.?.sendCommandAsync("Page.setInterceptFileChooserDialog", "{\"enabled\":true}");
        }

        // Connect browser_ws for Browser domain events (downloads)
        if (client.discoverBrowserWebSocketUrl(allocator)) |browser_url| {
            defer allocator.free(browser_url);
            client.browser_ws = websocket_cdp.WebSocketCdpClient.connect(allocator, browser_url) catch null;
            if (client.browser_ws) |bws| {
                try bws.startReaderThread();
                // Async - no need to wait
                bws.sendCommandAsync("Browser.setDownloadBehavior", "{\"behavior\":\"allowAndName\",\"downloadPath\":\"/tmp/termweb-downloads\",\"eventsEnabled\":true}");
                bws.sendCommandAsync("Target.setDiscoverTargets", "{\"discover\":true}");
            }
        } else |_| {}
        return client;
    }

    /// Initialize CDP client using WebSocket-only mode
    /// All CDP communication including screencast goes through WebSocket
    pub fn initFromWebSocket(allocator: std.mem.Allocator, debug_port: u16) !*CdpClient {
        const client = try allocator.create(CdpClient);
        client.* = .{
            .allocator = allocator,
            .pipe_client = null, // No pipe in WebSocket-only mode
            .session_id = null,
            .current_target_id = null,
            .debug_port = debug_port,
            .page_ws = null,
            .browser_ws = null,
            .page_ws_mutex = .{},
        };

        // Create downloads directory
        std.fs.makeDirAbsolute("/tmp/termweb-downloads") catch |err| {
            if (err != error.PathAlreadyExists) {
                logToFile("[CDP] Failed to create download dir: {}\n", .{err});
            }
        };

        // Wait for Chrome to be ready on the discovered port with retries
        var ws_url: ?[]const u8 = null;
        var retry: u32 = 0;
        while (retry < 50) : (retry += 1) {
            std.Thread.sleep(200 * std.time.ns_per_ms);
            ws_url = client.discoverPageWebSocketUrl(allocator) catch blk: {
                if (retry % 5 == 0) logToFile("[CDP WS-only] Retry {}/50: Failed to get WS URL\n", .{retry});
                break :blk null;
            };
            if (ws_url != null) break;
        } else {
            allocator.destroy(client);
            return CdpError.WebSocketConnectionFailed;
        }

        if (ws_url) |url| {
            defer allocator.free(url);

            // Connect page WebSocket for all page-level commands including screencast
            client.page_ws = try websocket_cdp.WebSocketCdpClient.connect(allocator, url);
            try client.page_ws.?.startReaderThread();

            // Enable domains async (fire-and-forget, faster startup)
            client.page_ws.?.sendCommandAsync("Runtime.enable", null);
            client.page_ws.?.sendCommandAsync("Page.enable", null);
            client.page_ws.?.sendCommandAsync("Network.enable", null);
            client.page_ws.?.sendCommandAsync("Page.setInterceptFileChooserDialog", "{\"enabled\":true}");
            client.page_ws.?.sendCommandAsync("Browser.grantPermissions", "{\"permissions\":[\"clipboardReadWrite\",\"clipboardSanitizedWrite\"]}");

            // Inject polyfills async (Chrome processes in order)
            const polyfill_script = @embedFile("fs_polyfill.js");
            var polyfill_json_buf: [65536]u8 = undefined;
            const polyfill_json = json_utils.escapeString(polyfill_script, &polyfill_json_buf) catch return CdpError.OutOfMemory;
            var polyfill_params_buf: [65536]u8 = undefined;
            const polyfill_params = std.fmt.bufPrint(&polyfill_params_buf, "{{\"source\":{s}}}", .{polyfill_json}) catch return CdpError.OutOfMemory;
            client.page_ws.?.sendCommandAsync("Page.addScriptToEvaluateOnNewDocument", polyfill_params);

            const clipboard_script = @embedFile("clipboard_polyfill.js");
            var clipboard_json_buf: [16384]u8 = undefined;
            const clipboard_json = json_utils.escapeString(clipboard_script, &clipboard_json_buf) catch return CdpError.OutOfMemory;
            var clipboard_params_buf: [32768]u8 = undefined;
            const clipboard_params = std.fmt.bufPrint(&clipboard_params_buf, "{{\"source\":{s}}}", .{clipboard_json}) catch return CdpError.OutOfMemory;
            client.page_ws.?.sendCommandAsync("Page.addScriptToEvaluateOnNewDocument", clipboard_params);

            const resize_script = @embedFile("resize_polyfill.js");
            var resize_json_buf: [4096]u8 = undefined;
            const resize_json = json_utils.escapeString(resize_script, &resize_json_buf) catch return CdpError.OutOfMemory;
            var resize_params_buf: [8192]u8 = undefined;
            const resize_params = std.fmt.bufPrint(&resize_params_buf, "{{\"source\":{s},\"worldName\":\"termweb\"}}", .{resize_json}) catch return CdpError.OutOfMemory;
            client.page_ws.?.sendCommandAsync("Page.addScriptToEvaluateOnNewDocument", resize_params);
        }

        // Connect browser_ws for Browser domain events (downloads)
        if (client.discoverBrowserWebSocketUrl(allocator)) |browser_url| {
            defer allocator.free(browser_url);
            client.browser_ws = websocket_cdp.WebSocketCdpClient.connect(allocator, browser_url) catch null;
            if (client.browser_ws) |bws| {
                try bws.startReaderThread();
                // Async - no need to wait for response
                bws.sendCommandAsync("Browser.setDownloadBehavior", "{\"behavior\":\"allowAndName\",\"downloadPath\":\"/tmp/termweb-downloads\",\"eventsEnabled\":true}");
                bws.sendCommandAsync("Target.setDiscoverTargets", "{\"discover\":true}");
            }
        } else |_| {}

        logToFile("[CDP] Initialized in WebSocket-only mode on port {}\n", .{debug_port});
        return client;
    }

    /// Discover page WebSocket URL from Chrome's HTTP endpoint
    /// If current_target_id is set, finds that specific target; otherwise finds any page target
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

        // Iterate over targets to find the correct one
        if (parsed != .array) return CdpError.InvalidResponse;

        var first_page_ws_url: ?[]const u8 = null;

        for (parsed.array.items) |target| {
            if (target != .object) continue;

            const type_val = target.object.get("type") orelse continue;
            if (type_val != .string or !std.mem.eql(u8, type_val.string, "page")) continue;

            const url_val = target.object.get("webSocketDebuggerUrl") orelse continue;
            if (url_val != .string) continue;

            // If we have a current_target_id, look for that specific target
            if (self.current_target_id) |target_id| {
                const id_val = target.object.get("id") orelse {
                    logToFile("[CDP discoverWS] target has no 'id' field\n", .{});
                    continue;
                };
                if (id_val == .string) {
                    logToFile("[CDP discoverWS] comparing target_id={s} with json id={s}\n", .{ target_id, id_val.string });
                    if (std.mem.eql(u8, id_val.string, target_id)) {
                        logToFile("[CDP discoverWS] MATCH! Found WebSocket URL for target {s}\n", .{target_id});
                        return try allocator.dupe(u8, url_val.string);
                    }
                }
            }

            // Track first page target as fallback
            if (first_page_ws_url == null) {
                first_page_ws_url = url_val.string;
            }
        }

        // If we didn't find the specific target, fall back to first page
        if (first_page_ws_url) |ws_url| {
            logToFile("[CDP] Using fallback WebSocket URL (first page target)\n", .{});
            return try allocator.dupe(u8, ws_url);
        }

        // Return first target of any type as last resort
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
        // Store target_id (don't free - we keep it)
        self.current_target_id = target_id;

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
        if (self.page_ws) |ws| ws.deinit();
        if (self.browser_ws) |ws| ws.deinit();
        if (self.session_id) |sid| self.allocator.free(sid);
        if (self.current_target_id) |tid| self.allocator.free(tid);
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

    /// Send mouse command (fire-and-forget) - uses page WebSocket with lazy recovery
    /// Silently ignores errors - safe during shutdown
    pub fn sendMouseCommandAsync(
        self: *CdpClient,
        method: []const u8,
        params: ?[]const u8,
    ) void {
        // Lazy recovery: try to reconnect if dead
        self.ensurePageWsConnected() catch {};

        if (self.page_ws) |ws| {
            ws.sendCommandAsync(method, params);
        }
    }

    /// Send keyboard command (fire-and-forget) - uses page WebSocket with lazy recovery
    /// Silently ignores errors - safe during shutdown
    pub fn sendKeyboardCommandAsync(
        self: *CdpClient,
        method: []const u8,
        params: ?[]const u8,
    ) void {
        // Lazy recovery: try to reconnect if dead
        self.ensurePageWsConnected() catch {};

        if (self.page_ws) |ws| {
            ws.sendCommandAsync(method, params);
        }
    }

    /// Send navigation command and wait for response - uses page WebSocket with lazy recovery
    pub fn sendNavCommand(
        self: *CdpClient,
        method: []const u8,
        params: ?[]const u8,
    ) ![]u8 {
        // Lazy recovery: try to reconnect if dead
        try self.ensurePageWsConnected();

        if (self.page_ws) |ws| {
            return ws.sendCommand(method, params);
        }
        return CdpError.WebSocketConnectionFailed;
    }

    /// Send navigation command (fire-and-forget) - uses page WebSocket with lazy recovery
    pub fn sendNavCommandAsync(
        self: *CdpClient,
        method: []const u8,
        params: ?[]const u8,
    ) void {
        // Lazy recovery: try to reconnect if dead
        self.ensurePageWsConnected() catch {};

        if (self.page_ws) |ws| {
            ws.sendCommandAsync(method, params);
        }
    }

    /// Check if page WebSocket is alive
    fn isPageWsAlive(self: *CdpClient) bool {
        if (self.page_ws) |ws| {
            return ws.running.load(.acquire);
        }
        return false;
    }

    /// Check if browser WebSocket is alive
    fn isBrowserWsAlive(self: *CdpClient) bool {
        if (self.browser_ws) |ws| {
            return ws.running.load(.acquire);
        }
        return false;
    }

    /// Ensure page WebSocket is connected (lazy recovery)
    /// Thread-safe: uses mutex to prevent multiple simultaneous reconnections
    fn ensurePageWsConnected(self: *CdpClient) !void {
        // Quick check without mutex (common case - ws is alive)
        if (self.isPageWsAlive()) return;

        // Take mutex before reconnecting to prevent race condition
        self.page_ws_mutex.lock();
        defer self.page_ws_mutex.unlock();

        // Double-check after acquiring mutex (another thread may have reconnected)
        if (self.isPageWsAlive()) return;

        logToFile("[CDP] page_ws dead, attempting lazy recovery...\n", .{});
        try self.reconnectPageWebSocket();
    }

    /// Ensure browser WebSocket is connected (lazy recovery)
    fn ensureBrowserWsConnected(self: *CdpClient) !void {
        if (self.isBrowserWsAlive()) return;
        logToFile("[CDP] browser_ws dead, attempting lazy recovery...\n", .{});
        try self.reconnectBrowserWebSocket();
    }

    /// Reconnect browser WebSocket
    fn reconnectBrowserWebSocket(self: *CdpClient) !void {
        logToFile("[CDP reconnectBrowserWS] Starting...\n", .{});

        // Close old connection
        if (self.browser_ws) |ws| {
            ws.deinit();
            self.browser_ws = null;
        }

        // Discover browser WebSocket URL
        const browser_url = try self.discoverBrowserWebSocketUrl(self.allocator);
        defer self.allocator.free(browser_url);
        logToFile("[CDP reconnectBrowserWS] Got URL: {s}\n", .{browser_url});

        // Connect browser WebSocket
        self.browser_ws = try websocket_cdp.WebSocketCdpClient.connect(self.allocator, browser_url);
        try self.browser_ws.?.startReaderThread();

        // Re-enable async - no need to wait
        self.browser_ws.?.sendCommandAsync("Browser.setDownloadBehavior", "{\"behavior\":\"allowAndName\",\"downloadPath\":\"/tmp/termweb-downloads\",\"eventsEnabled\":true}");
        self.browser_ws.?.sendCommandAsync("Target.setDiscoverTargets", "{\"discover\":true}");

        logToFile("[CDP reconnectBrowserWS] Done\n", .{});
    }

    /// Reconnect page WebSocket to current page target
    /// Cross-origin navigation creates new page target, invalidating connections
    fn reconnectPageWebSocket(self: *CdpClient) !void {
        logToFile("[CDP reconnectWS] Starting...\n", .{});

        // Close old connection
        if (self.page_ws) |ws| {
            logToFile("[CDP reconnectWS] Closing old WebSocket...\n", .{});
            ws.deinit();
            self.page_ws = null;
            logToFile("[CDP reconnectWS] Old WebSocket closed\n", .{});
        }

        // Discover new page WebSocket URL
        logToFile("[CDP reconnectWS] Discovering WebSocket URL...\n", .{});
        const ws_url = try self.discoverPageWebSocketUrl(self.allocator);
        defer self.allocator.free(ws_url);
        logToFile("[CDP reconnectWS] Got URL: {s}\n", .{ws_url});

        // Connect page WebSocket
        logToFile("[CDP reconnectWS] Connecting...\n", .{});
        self.page_ws = try websocket_cdp.WebSocketCdpClient.connect(self.allocator, ws_url);
        try self.page_ws.?.startReaderThread();
        logToFile("[CDP reconnectWS] Connected\n", .{});

        // Re-enable domains async
        logToFile("[CDP reconnectWS] Enabling domains async...\n", .{});
        self.page_ws.?.sendCommandAsync("Runtime.enable", null);
        self.page_ws.?.sendCommandAsync("Page.enable", null);
        self.page_ws.?.sendCommandAsync("Page.setInterceptFileChooserDialog", "{\"enabled\":true}");

        logToFile("[CDP reconnectWS] Done\n", .{});
    }

    /// Send CDP command and wait for response - uses session (pipe) or WebSocket
    pub fn sendCommand(
        self: *CdpClient,
        method: []const u8,
        params: ?[]const u8,
    ) ![]u8 {
        // WebSocket-only mode: use page_ws
        if (self.pipe_client == null) {
            if (self.page_ws) |ws| {
                return ws.sendCommand(method, params);
            }
            return CdpError.WebSocketConnectionFailed;
        }
        // Pipe mode: use pipe_client with session
        if (self.session_id != null) {
            return self.pipe_client.?.sendSessionCommand(self.session_id.?, method, params);
        }
        return self.pipe_client.?.sendCommand(method, params);
    }

    /// Send CDP command without waiting for response - uses session (pipe) or WebSocket
    pub fn sendCommandAsync(
        self: *CdpClient,
        method: []const u8,
        params: ?[]const u8,
    ) !void {
        // WebSocket-only mode: use page_ws
        if (self.pipe_client == null) {
            if (self.page_ws) |ws| {
                ws.sendCommandAsync(method, params);
                return;
            }
            return CdpError.WebSocketConnectionFailed;
        }
        // Pipe mode: use pipe_client with session
        if (self.session_id != null) {
            return self.pipe_client.?.sendSessionCommandAsync(self.session_id.?, method, params);
        }
        return self.pipe_client.?.sendCommandAsync(method, params);
    }

    /// Start screencast streaming
    /// everyNthFrame controls how many frames Chrome skips (1=all frames, 2=every other)
    pub fn startScreencast(
        self: *CdpClient,
        format: []const u8,
        quality: u8,
        width: u32,
        height: u32,
        every_nth_frame: u8,
    ) !void {
        // WebSocket-only mode: initialize frame pool and start reader thread
        if (self.pipe_client == null) {
            if (self.page_ws) |ws| {
                try ws.initFramePool();
                try ws.startReaderThread();
            } else {
                return CdpError.WebSocketConnectionFailed;
            }
        } else {
            // Pipe mode: start reader thread
            try self.pipe_client.?.startReaderThread();
        }

        // Send startScreencast command
        const params = try std.fmt.allocPrint(
            self.allocator,
            "{{\"format\":\"{s}\",\"quality\":{d},\"maxWidth\":{d},\"maxHeight\":{d},\"everyNthFrame\":{d}}}",
            .{ format, quality, width, height, every_nth_frame },
        );
        defer self.allocator.free(params);

        // Async - Chrome will start sending frames
        self.sendCommandAsync("Page.startScreencast", params) catch {};
    }

    /// Stop screencast streaming (for resize - keeps reader thread alive)
    /// Call stopScreencastFull for complete shutdown
    pub fn stopScreencast(self: *CdpClient) !void {
        // Async - Chrome will stop frames
        self.sendCommandAsync("Page.stopScreencast", null) catch {};
    }

    /// Stop screencast completely including reader thread (for shutdown)
    pub fn stopScreencastFull(self: *CdpClient) !void {
        // Send stop command async (don't wait for response - we're shutting down)
        self.sendCommandAsync("Page.stopScreencast", null) catch {};

        // Now stop the reader thread (pipe mode only)
        if (self.pipe_client) |pc| {
            pc.stopReaderThread();
        }
        // WebSocket mode: frame pool cleanup happens in deinit
    }

    /// Get latest screencast frame (non-blocking)
    /// Works in both pipe mode and WebSocket-only mode
    pub fn getLatestFrame(self: *CdpClient) ?ScreencastFrame {
        // WebSocket-only mode: get from page_ws
        if (self.pipe_client == null) {
            if (self.page_ws) |ws| {
                if (ws.getLatestFrame()) |ws_frame| {
                    // Convert websocket_cdp.ScreencastFrame to cdp_pipe.ScreencastFrame
                    // They have the same structure, so we can reinterpret
                    return ScreencastFrame{
                        .data = ws_frame.data,
                        .slot = ws_frame.slot,
                        .session_id = ws_frame.session_id,
                        .device_width = ws_frame.device_width,
                        .device_height = ws_frame.device_height,
                        .generation = ws_frame.generation,
                        .chrome_timestamp_ms = ws_frame.chrome_timestamp_ms,
                        .receive_timestamp_ns = ws_frame.receive_timestamp_ns,
                    };
                }
            }
            return null;
        }
        // Pipe mode
        return self.pipe_client.?.getLatestFrame();
    }

    /// Get count of frames received
    pub fn getFrameCount(self: *CdpClient) u32 {
        // WebSocket-only mode: get from page_ws
        if (self.pipe_client == null) {
            if (self.page_ws) |ws| {
                return ws.getFrameCount();
            }
            return 0;
        }
        // Pipe mode
        return self.pipe_client.?.getFrameCount();
    }

    /// Flush pending ACK (call from main loop)
    pub fn flushPendingAck(self: *CdpClient) void {
        if (self.pipe_client) |pc| {
            pc.flushPendingAck();
        }
        // WebSocket mode: ACKs are sent immediately, no-op
        if (self.page_ws) |ws| {
            ws.flushPendingAck();
        }
    }

    /// Get next event from WebSockets
    /// Pipe is ONLY for screencast frames - all events come from WebSockets
    /// Uses lazy recovery: reconnects dead WebSockets on demand
    pub fn nextEvent(self: *CdpClient, allocator: std.mem.Allocator) !?CdpEvent {
        _ = allocator;

        // Lazy recovery for browser_ws (download events)
        self.ensureBrowserWsConnected() catch {};

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

        // Lazy recovery for page_ws (page events)
        self.ensurePageWsConnected() catch {};

        // Check page_ws for page events
        const ws = self.page_ws orelse return null;
        const raw = ws.nextEvent() orelse return null;
        return CdpEvent{
            .method = raw.method,
            .payload = raw.payload,
            .allocator = ws.allocator,
        };
    }

    /// Switch to a different target (for tab switching)
    /// In pipe mode: Detaches from current session and attaches to new target
    /// In WebSocket-only mode: Closes current page_ws and reconnects to new target
    pub fn switchToTarget(self: *CdpClient, target_id: []const u8) !void {
        logToFile("[CDP switchToTarget] START target={s}\n", .{target_id});

        // WebSocket-only mode: just update target and reconnect
        if (self.pipe_client == null) {
            // Update current target ID
            if (self.current_target_id) |old_tid| {
                self.allocator.free(old_tid);
            }
            self.current_target_id = try self.allocator.dupe(u8, target_id);

            // Activate target via browser_ws (async - no need to wait)
            if (self.browser_ws) |bws| {
                var activate_buf: [256]u8 = undefined;
                const activate_params = std.fmt.bufPrint(&activate_buf, "{{\"targetId\":\"{s}\"}}", .{target_id}) catch return error.OutOfMemory;
                bws.sendCommandAsync("Target.activateTarget", activate_params);
            }

            // Close and reconnect page_ws (hold mutex throughout to prevent race)
            {
                self.page_ws_mutex.lock();
                defer self.page_ws_mutex.unlock();
                if (self.page_ws) |ws| {
                    ws.deinit();
                    self.page_ws = null;
                }
                // Reconnect immediately (needed for screencast)
                try self.reconnectPageWebSocket();
            }
            logToFile("[CDP switchToTarget] END success (WS-only mode)\n", .{});
            return;
        }

        // Pipe mode: use session-based attach/detach
        // Detach from current session (async - don't wait, OK if fails)
        if (self.session_id) |old_sid| {
            logToFile("[CDP switchToTarget] Detaching from session (async): {s}\n", .{old_sid});
            var detach_buf: [256]u8 = undefined;
            const detach_params = std.fmt.bufPrint(&detach_buf, "{{\"sessionId\":\"{s}\"}}", .{old_sid}) catch "";
            if (detach_params.len > 0) {
                self.pipe_client.?.sendCommandAsync("Target.detachFromTarget", detach_params) catch |err| {
                    logToFile("[CDP switchToTarget] Detach async failed (OK): {}\n", .{err});
                };
            }
        }

        // Activate the target (async - just brings tab to focus)
        logToFile("[CDP switchToTarget] Activating target (async)...\n", .{});
        var activate_buf: [256]u8 = undefined;
        const activate_params = std.fmt.bufPrint(&activate_buf, "{{\"targetId\":\"{s}\"}}", .{target_id}) catch return error.OutOfMemory;
        self.pipe_client.?.sendCommandAsync("Target.activateTarget", activate_params) catch |err| {
            logToFile("[CDP switchToTarget] Activate async failed: {}\n", .{err});
        };

        // Attach to the target to get a new session
        logToFile("[CDP switchToTarget] Attaching to target...\n", .{});
        var escape_buf: [512]u8 = undefined;
        const escaped_id = json_utils.escapeContents(target_id, &escape_buf) catch return error.OutOfMemory;
        const params = try std.fmt.allocPrint(
            self.allocator,
            "{{\"targetId\":\"{s}\",\"flatten\":true}}",
            .{escaped_id},
        );
        defer self.allocator.free(params);

        const attach_response = self.pipe_client.?.sendCommand("Target.attachToTarget", params) catch |err| {
            logToFile("[CDP switchToTarget] Target.attachToTarget FAILED: {}\n", .{err});
            return err;
        };
        defer self.allocator.free(attach_response);
        logToFile("[CDP switchToTarget] Attach done\n", .{});

        // Extract and update session ID
        const new_session_id = self.extractSessionId(attach_response) catch |err| {
            logToFile("[CDP] Could not extract session ID: {}\n", .{err});
            return error.InvalidResponse;
        };

        // Free old session ID and set new one
        if (self.session_id) |old_sid| {
            self.allocator.free(old_sid);
        }
        self.session_id = new_session_id;

        // Update current target ID
        if (self.current_target_id) |old_tid| {
            self.allocator.free(old_tid);
        }
        self.current_target_id = try self.allocator.dupe(u8, target_id);

        logToFile("[CDP switchToTarget] Switched to target, new session: {s}\n", .{new_session_id});

        // Re-enable Page domain on the new session (async - don't block UI)
        logToFile("[CDP switchToTarget] Enabling Page domain (async)...\n", .{});
        self.sendCommandAsync("Page.enable", null) catch |err| {
            logToFile("[CDP switchToTarget] Page.enable async failed: {}\n", .{err});
        };

        // WebSocket reconnection is deferred - lazy recovery will handle it when input is needed
        // This avoids blocking tab switch on slow WebSocket handshake (~200-500ms)
        // Screencast works via pipe, so display is immediate
        {
            self.page_ws_mutex.lock();
            defer self.page_ws_mutex.unlock();
            if (self.page_ws) |ws| {
                ws.deinit();
                self.page_ws = null;
            }
        }
        logToFile("[CDP switchToTarget] END success (ws reconnect deferred)\n", .{});
    }

    /// Get the current target ID
    pub fn getCurrentTargetId(self: *CdpClient) ?[]const u8 {
        return self.current_target_id;
    }

    /// Create a new target (tab) with the given URL
    /// Returns the new target ID
    pub fn createTarget(self: *CdpClient, url: []const u8) ![]const u8 {
        logToFile("[CDP] Creating new target: {s}\n", .{url});
        var buf: [512]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"url\":\"{s}\"}}", .{url}) catch return error.OutOfMemory;

        // Use browser_ws for Target.* commands in WebSocket-only mode
        const result = if (self.pipe_client == null) blk: {
            if (self.browser_ws) |bws| {
                break :blk bws.sendCommand("Target.createTarget", params) catch |err| {
                    logToFile("[CDP] Target.createTarget failed: {}\n", .{err});
                    return err;
                };
            }
            return CdpError.WebSocketConnectionFailed;
        } else blk: {
            break :blk self.pipe_client.?.sendCommand("Target.createTarget", params) catch |err| {
                logToFile("[CDP] Target.createTarget failed: {}\n", .{err});
                return err;
            };
        };
        defer self.allocator.free(result);

        // Parse targetId from response: {"result":{"targetId":"..."}}
        const marker = "\"targetId\":\"";
        const start = std.mem.indexOf(u8, result, marker) orelse return error.InvalidResponse;
        const id_start = start + marker.len;
        const id_end = std.mem.indexOfPos(u8, result, id_start, "\"") orelse return error.InvalidResponse;
        return try self.allocator.dupe(u8, result[id_start..id_end]);
    }

    /// Create and immediately attach to a new target (optimized for new tab)
    /// Skips activation step since new targets are already focused
    /// Returns the new target ID (caller owns)
    pub fn createAndAttachTarget(self: *CdpClient, url: []const u8) ![]const u8 {
        logToFile("[CDP createAndAttach] START url={s}\n", .{url});

        // Create target via browser_ws (WebSocket-only) or pipe_client
        var create_buf: [512]u8 = undefined;
        const create_params = std.fmt.bufPrint(&create_buf, "{{\"url\":\"{s}\"}}", .{url}) catch return error.OutOfMemory;

        const create_result = if (self.pipe_client == null) blk: {
            if (self.browser_ws) |bws| {
                break :blk bws.sendCommand("Target.createTarget", create_params) catch |err| {
                    logToFile("[CDP createAndAttach] createTarget failed: {}\n", .{err});
                    return err;
                };
            }
            return CdpError.WebSocketConnectionFailed;
        } else blk: {
            break :blk self.pipe_client.?.sendCommand("Target.createTarget", create_params) catch |err| {
                logToFile("[CDP createAndAttach] createTarget failed: {}\n", .{err});
                return err;
            };
        };
        defer self.allocator.free(create_result);

        // Parse targetId
        const marker = "\"targetId\":\"";
        const start = std.mem.indexOf(u8, create_result, marker) orelse return error.InvalidResponse;
        const id_start = start + marker.len;
        const id_end = std.mem.indexOfPos(u8, create_result, id_start, "\"") orelse return error.InvalidResponse;
        const target_id = create_result[id_start..id_end];
        logToFile("[CDP createAndAttach] Created target: {s}\n", .{target_id});

        // WebSocket-only mode: just update target and reconnect
        if (self.pipe_client == null) {
            // Update current target ID
            if (self.current_target_id) |old_tid| {
                self.allocator.free(old_tid);
            }
            self.current_target_id = try self.allocator.dupe(u8, target_id);

            // Close and reconnect page_ws (hold mutex throughout to prevent race)
            {
                self.page_ws_mutex.lock();
                defer self.page_ws_mutex.unlock();
                if (self.page_ws) |ws| {
                    ws.deinit();
                    self.page_ws = null;
                }
                try self.reconnectPageWebSocket();
            }
            logToFile("[CDP createAndAttach] END success (WS-only mode)\n", .{});
            return try self.allocator.dupe(u8, target_id);
        }

        // Pipe mode: use session-based attach
        // Detach from current session async (if any)
        if (self.session_id) |old_sid| {
            var detach_buf: [256]u8 = undefined;
            const detach_params = std.fmt.bufPrint(&detach_buf, "{{\"sessionId\":\"{s}\"}}", .{old_sid}) catch "";
            if (detach_params.len > 0) {
                self.pipe_client.?.sendCommandAsync("Target.detachFromTarget", detach_params) catch {};
            }
            self.allocator.free(old_sid);
            self.session_id = null;
        }

        // Attach to new target (skip activateTarget - new tabs are already focused)
        var escape_buf: [512]u8 = undefined;
        const escaped_id = json_utils.escapeContents(target_id, &escape_buf) catch return error.OutOfMemory;
        const attach_params = try std.fmt.allocPrint(self.allocator, "{{\"targetId\":\"{s}\",\"flatten\":true}}", .{escaped_id});
        defer self.allocator.free(attach_params);

        const attach_response = self.pipe_client.?.sendCommand("Target.attachToTarget", attach_params) catch |err| {
            logToFile("[CDP createAndAttach] attachToTarget failed: {}\n", .{err});
            return err;
        };
        defer self.allocator.free(attach_response);

        // Extract session ID
        const new_session_id = self.extractSessionId(attach_response) catch |err| {
            logToFile("[CDP createAndAttach] extractSessionId failed: {}\n", .{err});
            return error.InvalidResponse;
        };
        self.session_id = new_session_id;

        // Update current target ID
        if (self.current_target_id) |old_tid| {
            self.allocator.free(old_tid);
        }
        self.current_target_id = try self.allocator.dupe(u8, target_id);

        // Enable Page domain async
        self.sendCommandAsync("Page.enable", null) catch {};

        // Clear old WebSocket (lazy recovery will handle reconnection when needed)
        {
            self.page_ws_mutex.lock();
            defer self.page_ws_mutex.unlock();
            if (self.page_ws) |ws| {
                ws.deinit();
                self.page_ws = null;
            }
        }

        logToFile("[CDP createAndAttach] END success\n", .{});
        return try self.allocator.dupe(u8, target_id);
    }

    /// Close a target (for single-tab mode - close unwanted popups)
    pub fn closeTarget(self: *CdpClient, target_id: []const u8) !void {
        logToFile("[CDP] Closing target: {s}\n", .{target_id});
        var buf: [256]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"targetId\":\"{s}\"}}", .{target_id}) catch return error.OutOfMemory;

        // Use browser_ws for Target.* commands in WebSocket-only mode
        const result = if (self.pipe_client == null) blk: {
            if (self.browser_ws) |bws| {
                break :blk bws.sendCommand("Target.closeTarget", params) catch |err| {
                    logToFile("[CDP] Target.closeTarget failed: {}\n", .{err});
                    return err;
                };
            }
            return CdpError.WebSocketConnectionFailed;
        } else blk: {
            break :blk self.pipe_client.?.sendCommand("Target.closeTarget", params) catch |err| {
                logToFile("[CDP] Target.closeTarget failed: {}\n", .{err});
                return err;
            };
        };
        self.allocator.free(result);
    }

    /// Get DevTools frontend URL for the current page
    /// Returns URL like: devtools://devtools/bundled/inspector.html?ws=...
    pub fn getDevToolsUrl(self: *CdpClient) ?[]const u8 {
        // Connect to Chrome's /json/list endpoint
        const stream = std.net.tcpConnectToHost(self.allocator, "127.0.0.1", self.debug_port) catch return null;
        defer stream.close();

        var request_buf: [128]u8 = undefined;
        const request = std.fmt.bufPrint(&request_buf, "GET /json/list HTTP/1.1\r\nHost: 127.0.0.1:{}\r\n\r\n", .{self.debug_port}) catch return null;
        _ = stream.write(request) catch return null;

        var buf: [8192]u8 = undefined;
        const n = stream.read(&buf) catch return null;
        const response = buf[0..n];

        // Find devtoolsFrontendUrl in response
        const marker = "\"devtoolsFrontendUrl\":\"";
        const start = std.mem.indexOf(u8, response, marker) orelse return null;
        const url_start = start + marker.len;
        const url_end = std.mem.indexOfPos(u8, response, url_start, "\"") orelse return null;
        const relative_url = response[url_start..url_end];

        // Convert relative URL to absolute
        // Chrome returns: /devtools/inspector.html?ws=...
        // We need: http://127.0.0.1:PORT/devtools/inspector.html?ws=...
        var url_buf: [512]u8 = undefined;
        const full_url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}{s}", .{ self.debug_port, relative_url }) catch return null;
        return self.allocator.dupe(u8, full_url) catch return null;
    }
};
