//! HTTP server for embedded web assets and WebSocket upgrades.
//!
//! Serves the termweb web client (index.html, client.js, zstd.wasm) from embedded
//! assets compiled into the binary. Also provides:
//! - `/config` endpoint for terminal configuration (colors, fonts)
//! - WebSocket upgrade handling for panel, control, file, and preview endpoints
//! - COOP/COEP headers for SharedArrayBuffer support in Web Workers
//!
//! The server runs on a single port and routes requests based on path:
//! - `/` or `/index.html` → embedded HTML
//! - `/client.js` → embedded JavaScript bundle
//! - `/zstd.wasm` → embedded zstd WASM module for browser compression
//! - `/config` → JSON terminal configuration from ghostty
//! - `/ws/*` → WebSocket upgrade to appropriate handler
//!
const std = @import("std");
const builtin = @import("builtin");
const net = std.net;
const posix = std.posix;
const Allocator = std.mem.Allocator;

// Set socket read timeout for blocking I/O with periodic wakeup
fn setReadTimeout(fd: posix.socket_t, timeout_ms: u32) void {
    const tv = posix.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
}

// Platform detection
const is_macos = builtin.os.tag == .macos;

// Platform-specific ghostty import
const c = if (is_macos) @cImport({
    @cInclude("ghostty.h");
}) else struct {
    // Stub for Linux
    const ghostty_stub = @import("ghostty_stub.zig");
    pub const ghostty_config_t = ghostty_stub.ghostty_config_t;
    pub fn ghostty_config_get(_: ghostty_config_t, _: anytype, _: [*:0]const u8, _: usize) c_int {
        return -1; // Not found
    }
};

// Embedded web assets - from web_assets module
const web_assets = @import("web_assets");
const embedded_index_html = web_assets.index_html;
const embedded_client_js = web_assets.client_js;
const embedded_file_worker_js = web_assets.file_worker_js;
const embedded_zstd_wasm = web_assets.zstd_wasm;

// Common headers for all responses:
// - COOP/COEP for SharedArrayBuffer support (required for Web Workers with shared memory)
// - CORP cross-origin: allows this page to be loaded in cross-origin iframes with COEP
// - CSP frame-ancestors *: allow embedding in iframes from any origin
// - Cache-Control: aggressive no-cache to prevent browsers from caching (security + dev workflow)
// - Pragma/Expires: legacy cache-busting for HTTP/1.0 and old browsers
const cross_origin_headers = "Cross-Origin-Opener-Policy: same-origin\r\n" ++
    "Cross-Origin-Embedder-Policy: require-corp\r\n" ++
    "Cross-Origin-Resource-Policy: cross-origin\r\n" ++
    "Content-Security-Policy: frame-ancestors *\r\n" ++
    "Cache-Control: no-store, no-cache, must-revalidate, max-age=0\r\n" ++
    "Pragma: no-cache\r\n" ++
    "Expires: 0\r\n";

// Color struct matching ghostty_config_color_s
const Color = extern struct {
    r: u8,
    g: u8,
    b: u8,
};

/// Callback for WebSocket upgrade requests.
/// Called when a client requests upgrade to WebSocket protocol.
/// Parameters: network stream, HTTP request headers, user context data.
pub const WsUpgradeCallback = *const fn (stream: net.Stream, request: []const u8, user_data: ?*anyopaque) void;

/// Callback for API requests. Returns JSON response body (caller frees), or null if path not handled.
pub const ApiCallback = *const fn (path: []const u8, user_data: ?*anyopaque) ?[]const u8;

// Simple HTTP server for embedded static files + config endpoint + WebSocket upgrades
pub const HttpServer = struct {
    listener: net.Server,
    allocator: Allocator,
    running: std.atomic.Value(bool),
    stopped: std.atomic.Value(bool),
    active_connections: std.atomic.Value(u32),
    panel_ws_port: u16,
    control_ws_port: u16,
    file_ws_port: u16,
    ghostty_config: ?c.ghostty_config_t,
    // WebSocket upgrade callbacks
    panel_ws_callback: ?WsUpgradeCallback = null,
    control_ws_callback: ?WsUpgradeCallback = null,
    file_ws_callback: ?WsUpgradeCallback = null,
    preview_ws_callback: ?WsUpgradeCallback = null,
    ws_user_data: ?*anyopaque = null,
    // API callback for custom endpoints (e.g., /api/benchmark/stats)
    api_callback: ?ApiCallback = null,
    api_user_data: ?*anyopaque = null,

    pub fn init(allocator: Allocator, address: []const u8, port: u16, ghostty_config: ?c.ghostty_config_t) !*HttpServer {
        const server = try allocator.create(HttpServer);
        errdefer allocator.destroy(server);

        const addr = try net.Address.parseIp4(address, port);
        server.* = .{
            .listener = try addr.listen(.{ .reuse_address = true }),
            .allocator = allocator,
            .running = std.atomic.Value(bool).init(false),
            .stopped = std.atomic.Value(bool).init(false),
            .active_connections = std.atomic.Value(u32).init(0),
            .panel_ws_port = 0,
            .control_ws_port = 0,
            .file_ws_port = 0,
            .ghostty_config = ghostty_config,
            .panel_ws_callback = null,
            .control_ws_callback = null,
            .file_ws_callback = null,
            .ws_user_data = null,
        };

        return server;
    }

    pub fn setWsPorts(self: *HttpServer, panel_port: u16, control_port: u16, file_port: u16) void {
        self.panel_ws_port = panel_port;
        self.control_ws_port = control_port;
        self.file_ws_port = file_port;
    }

    pub fn setWsCallbacks(
        self: *HttpServer,
        panel_cb: ?WsUpgradeCallback,
        control_cb: ?WsUpgradeCallback,
        file_cb: ?WsUpgradeCallback,
        preview_cb: ?WsUpgradeCallback,
        user_data: ?*anyopaque,
    ) void {
        self.panel_ws_callback = panel_cb;
        self.control_ws_callback = control_cb;
        self.file_ws_callback = file_cb;
        self.preview_ws_callback = preview_cb;
        self.ws_user_data = user_data;
    }

    pub fn deinit(self: *HttpServer) void {
        self.stop();
        // Wait for all active HTTP connection threads to finish
        var wait_count: u32 = 0;
        while (self.active_connections.load(.acquire) > 0) {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            wait_count += 1;
            if (wait_count > 200) break; // 2s timeout
        }
        self.allocator.destroy(self);
    }

    pub fn stop(self: *HttpServer) void {
        // Only stop once (use stopped flag since running starts as false)
        if (self.stopped.swap(true, .acq_rel)) return;
        self.running.store(false, .release);
        // shutdown() interrupts blocked accept() in another thread reliably on Linux
        // (close() alone is NOT guaranteed to unblock accept on Linux)
        posix.shutdown(self.listener.stream.handle, .both) catch {};
        self.listener.deinit();
    }

    pub fn run(self: *HttpServer) !void {
        self.running.store(true, .release);
        std.debug.print("HTTP server listening on port {}\n", .{self.listener.listen_address.getPort()});

        while (self.running.load(.acquire)) {
            // Blocking accept — stop() closes listener to unblock
            const conn = self.listener.accept() catch break;

            const thread = std.Thread.spawn(.{}, handleConnection, .{ self, conn.stream }) catch {
                conn.stream.close();
                continue;
            };
            thread.detach();
        }
    }

    fn handleConnection(self: *HttpServer, stream: net.Stream) void {
        _ = self.active_connections.fetchAdd(1, .acq_rel);
        defer _ = self.active_connections.fetchSub(1, .acq_rel);

        // Set read timeout so we don't block forever during shutdown
        setReadTimeout(stream.handle, 1000); // 1 second timeout

        var buf: [4096]u8 = undefined;
        const n = stream.read(&buf) catch {
            stream.close();
            return;
        };
        if (n == 0) {
            stream.close();
            return;
        }

        const request = buf[0..n];

        // Parse request line
        const line_end = std.mem.indexOf(u8, request, "\r\n") orelse {
            stream.close();
            return;
        };
        const request_line = request[0..line_end];

        // Parse method and path
        var parts = std.mem.splitScalar(u8, request_line, ' ');
        const method = parts.next() orelse {
            stream.close();
            return;
        };
        const full_path = parts.next() orelse {
            stream.close();
            return;
        };

        // Split path from query string
        const path = if (std.mem.indexOf(u8, full_path, "?")) |idx| full_path[0..idx] else full_path;

        if (!std.mem.eql(u8, method, "GET")) {
            self.sendError(stream, 405, "Method Not Allowed");
            stream.close();
            return;
        }

        // Check for WebSocket upgrade
        if (self.isWebSocketUpgrade(request)) {
            // Route WebSocket by path - 3 channels: h264 (video) + control (zstd) + file (transfers)
            if (std.mem.eql(u8, path, "/ws/h264")) {
                if (self.panel_ws_callback) |cb| {
                    cb(stream, request, self.ws_user_data);
                    return; // Callback owns the stream
                }
            } else if (std.mem.eql(u8, path, "/ws/control")) {
                if (self.control_ws_callback) |cb| {
                    cb(stream, request, self.ws_user_data);
                    return;
                }
            } else if (std.mem.eql(u8, path, "/ws/file")) {
                if (self.file_ws_callback) |cb| {
                    cb(stream, request, self.ws_user_data);
                    return;
                }
            }
            // Unknown WebSocket path or no callback
            self.sendError(stream, 404, "WebSocket endpoint not found");
            stream.close();
            return;
        }

        // Regular HTTP - close stream when done
        defer stream.close();

        // Handle /api/* endpoints via callback
        if (std.mem.startsWith(u8, path, "/api/")) {
            if (self.api_callback) |cb| {
                if (cb(path, self.api_user_data)) |json| {
                    var api_header_buf: [256]u8 = undefined;
                    const api_header = std.fmt.bufPrint(&api_header_buf, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\n" ++ cross_origin_headers ++ "Connection: close\r\n\r\n", .{json.len}) catch {
                        self.sendError(stream, 500, "Internal Server Error");
                        return;
                    };
                    _ = stream.write(api_header) catch return;
                    _ = stream.write(json) catch return;
                    return;
                }
            }
            self.sendError(stream, 404, "API endpoint not found");
            return;
        }

        // Handle /config endpoint - returns WebSocket info
        if (std.mem.eql(u8, path, "/config")) {
            self.sendConfig(stream);
            return;
        }

        // Handle /favicon.ico - return 204 No Content (we use inline SVG)
        if (std.mem.eql(u8, path, "/favicon.ico")) {
            stream.writeAll("HTTP/1.1 204 No Content\r\n" ++ cross_origin_headers ++ "Connection: close\r\n\r\n") catch return;
            return;
        }

        // Serve embedded files
        const clean_path = if (std.mem.eql(u8, path, "/")) "/index.html" else path;

        const content: []const u8 = if (std.mem.eql(u8, clean_path, "/index.html"))
            embedded_index_html
        else if (std.mem.eql(u8, clean_path, "/client.js"))
            embedded_client_js
        else if (std.mem.eql(u8, clean_path, "/file-worker.js"))
            embedded_file_worker_js
        else if (std.mem.eql(u8, clean_path, "/zstd.wasm"))
            embedded_zstd_wasm
        else {
            self.sendError(stream, 404, "Not Found");
            return;
        };

        // Determine content type
        const content_type = getContentType(clean_path);

        // Send response with COOP/COEP headers for SharedArrayBuffer support
        var header_buf: [768]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {}\r\n" ++ cross_origin_headers ++ "Connection: close\r\n\r\n", .{ content_type, content.len }) catch return;

        _ = stream.write(header) catch return;
        _ = stream.write(content) catch return;
    }

    fn isWebSocketUpgrade(self: *HttpServer, request: []const u8) bool {
        _ = self;
        // Check for "Upgrade: websocket" header (case-insensitive)
        var i: usize = 0;
        while (i < request.len) {
            // Find next line
            const line_start = i;
            while (i < request.len and request[i] != '\r') : (i += 1) {}
            const line = request[line_start..i];

            // Skip \r\n
            if (i + 1 < request.len and request[i] == '\r' and request[i + 1] == '\n') {
                i += 2;
            } else {
                break;
            }

            // Check for Upgrade header
            if (line.len >= 18) { // "Upgrade: websocket"
                if (std.ascii.eqlIgnoreCase(line[0..8], "Upgrade:")) {
                    const value = std.mem.trim(u8, line[8..], " \t");
                    if (std.ascii.eqlIgnoreCase(value, "websocket")) {
                        return true;
                    }
                }
            }
        }
        return false;
    }

    fn sendError(self: *HttpServer, stream: net.Stream, code: u16, message: []const u8) void {
        _ = self;
        var buf: [512]u8 = undefined;
        const response = std.fmt.bufPrint(&buf, "HTTP/1.1 {} {s}\r\nContent-Type: text/plain\r\nContent-Length: {}\r\n" ++ cross_origin_headers ++ "Connection: close\r\n\r\n{s}", .{ code, message, message.len, message }) catch return;
        _ = stream.write(response) catch {};
    }

    fn sendConfig(self: *HttpServer, stream: net.Stream) void {
        // Get colors from ghostty config
        var bg: Color = .{ .r = 0x28, .g = 0x2C, .b = 0x34 }; // default
        var fg: Color = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF }; // default

        if (self.ghostty_config) |cfg| {
            _ = c.ghostty_config_get(cfg, &bg, "background", 10);
            _ = c.ghostty_config_get(cfg, &fg, "foreground", 10);
        }

        // Return config - client uses path-based WebSocket on same port
        var body_buf: [512]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf,
            \\{{"wsPath":true,"colors":{{"background":"#{x:0>2}{x:0>2}{x:0>2}","foreground":"#{x:0>2}{x:0>2}{x:0>2}"}}}}
        , .{
            bg.r, bg.g, bg.b,
            fg.r, fg.g, fg.b,
        }) catch return;

        var header_buf: [512]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n" ++ cross_origin_headers ++ "Connection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n", .{body.len}) catch return;

        _ = stream.write(header) catch return;
        _ = stream.write(body) catch return;
    }

    fn getContentType(path: []const u8) []const u8 {
        if (std.mem.endsWith(u8, path, ".html")) return "text/html; charset=utf-8";
        if (std.mem.endsWith(u8, path, ".js")) return "application/javascript";
        if (std.mem.endsWith(u8, path, ".css")) return "text/css";
        if (std.mem.endsWith(u8, path, ".json")) return "application/json";
        if (std.mem.endsWith(u8, path, ".png")) return "image/png";
        if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
        if (std.mem.endsWith(u8, path, ".ico")) return "image/x-icon";
        if (std.mem.endsWith(u8, path, ".wasm")) return "application/wasm";
        return "application/octet-stream";
    }
};
