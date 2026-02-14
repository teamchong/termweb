//! HTTP server for embedded web assets and WebSocket upgrades.
//!
//! Serves the termweb web client from embedded assets compiled into the binary.
//! The index.html has client.js inlined at comptime and config JSON injected at
//! serve time via a template marker. Also provides:
//! - WebSocket upgrade handling for panel, control, file, and preview endpoints
//! - CORP/CSP headers for cross-origin iframe embedding
//!
//! The server runs on a single port and routes requests based on path:
//! - `/` or `/index.html` → embedded HTML with inlined JS and injected config
//! - `/file-worker.js` → embedded file transfer worker
//! - `/zstd.wasm` → embedded zstd WASM module for browser compression
//! - `/ws/*` → WebSocket upgrade to appropriate handler
//!
const std = @import("std");
const net = std.net;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const auth = @import("auth.zig");
const build_options = @import("build_options");

// Set socket read timeout for blocking I/O with periodic wakeup
fn setReadTimeout(fd: posix.socket_t, timeout_ms: u32) void {
    const tv = posix.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
}

// Embedded web assets - from web_assets module
const web_assets = @import("web_assets");
const embedded_file_worker_js = web_assets.file_worker_js;
const embedded_zstd_wasm = web_assets.zstd_wasm;

// Inlined HTML: JS is embedded directly so no sub-resource fetch is needed.
// This avoids needing cookies or separate auth for static assets.
const embedded_index_html = blk: {
    const raw_html = web_assets.index_html;
    const marker = "<script src=\"client.js\"></script>";
    const pos = std.mem.indexOf(u8, raw_html, marker) orelse @compileError("client.js script tag not found in index.html");
    break :blk raw_html[0..pos] ++ "<script>" ++ web_assets.client_js ++ "</script>" ++ raw_html[pos + marker.len ..];
};

// Split the embedded HTML at the config marker for runtime config injection.
// At serve time, the server writes: html_before_config + config script + html_after_config.
const config_marker = "<!--TERMWEB_CONFIG-->";
const config_split_pos = std.mem.indexOf(u8, embedded_index_html, config_marker) orelse @compileError("config marker not found in index.html");
const html_before_config = embedded_index_html[0..config_split_pos];
const html_after_config = embedded_index_html[config_split_pos + config_marker.len ..];

const config_script_prefix = "<script>window.__TERMWEB_CONFIG__=";
const config_script_suffix = "</script>";

// Common headers for all responses:
// - CORP cross-origin: allows resources to be loaded in cross-origin contexts
// - No frame-ancestors CSP: omitted so non-network schemes (e.g. vscode-file://) can embed
// - Cache-Control: aggressive no-cache to prevent browsers from caching (security + dev workflow)
// - Pragma/Expires: legacy cache-busting for HTTP/1.0 and old browsers
const cross_origin_headers = "Cross-Origin-Resource-Policy: cross-origin\r\n" ++
    "Cache-Control: no-store, no-cache, must-revalidate, max-age=0\r\n" ++
    "Pragma: no-cache\r\n" ++
    "Expires: 0\r\n";

/// Callback for WebSocket upgrade requests.
/// Called when a client requests upgrade to WebSocket protocol.
/// Parameters: network stream, HTTP request headers, user context data.
pub const WsUpgradeCallback = *const fn (stream: net.Stream, request: []const u8, user_data: ?*anyopaque) void;

/// Callback for API requests. Returns JSON response body (caller frees), or null if path not handled.
pub const ApiCallback = *const fn (path: []const u8, user_data: ?*anyopaque) ?[]const u8;

// Simple HTTP server for embedded static files + WebSocket upgrades
pub const HttpServer = struct {
    listener: net.Server,
    allocator: Allocator,
    running: std.atomic.Value(bool),
    stopped: std.atomic.Value(bool),
    active_connections: std.atomic.Value(u32),
    panel_ws_port: u16,
    control_ws_port: u16,
    file_ws_port: u16,
    config_json: ?[]const u8,
    // WebSocket upgrade callbacks
    panel_ws_callback: ?WsUpgradeCallback = null,
    control_ws_callback: ?WsUpgradeCallback = null,
    file_ws_callback: ?WsUpgradeCallback = null,
    preview_ws_callback: ?WsUpgradeCallback = null,
    ws_user_data: ?*anyopaque = null,
    // API callback for custom endpoints (e.g., /api/benchmark/stats)
    api_callback: ?ApiCallback = null,
    api_user_data: ?*anyopaque = null,
    // Auth state for token validation on all requests
    auth_state: ?*auth.AuthState = null,
    // Rate limiter for failed auth attempts
    rate_limiter: ?*auth.RateLimiter = null,

    pub fn init(allocator: Allocator, address: []const u8, port: u16, config_json: ?[]const u8) !*HttpServer {
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
            .config_json = config_json,
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

            const thread = std.Thread.spawn(.{}, handleConnection, .{ self, conn.stream, conn.address }) catch {
                conn.stream.close();
                continue;
            };
            thread.detach();
        }
    }

    fn handleConnection(self: *HttpServer, stream: net.Stream, peer_addr: net.Address) void {
        _ = self.active_connections.fetchAdd(1, .acq_rel);
        defer _ = self.active_connections.fetchSub(1, .acq_rel);

        // Format peer IP for rate limiting
        var ip_buf: [45]u8 = undefined;
        const ip_full = std.fmt.bufPrint(&ip_buf, "{f}", .{peer_addr}) catch "";
        // Strip port suffix (e.g. "127.0.0.1:8080" → "127.0.0.1")
        const ip_str = if (std.mem.lastIndexOfScalar(u8, ip_full, ':')) |colon|
            ip_full[0..colon]
        else
            ip_full;

        // Rate limit check — reject before reading request body
        if (self.rate_limiter) |rl| {
            if (rl.isBlocked(ip_str)) {
                self.sendError(stream, 429, "Too Many Requests");
                stream.close();
                return;
            }
        }

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

        // Auth check — all requests require a valid token in query param
        if (self.auth_state) |auth_st| {
            const raw_token = auth.extractTokenFromQuery(full_path);
            var token_buf: [256]u8 = undefined;
            const token = if (raw_token) |t| auth.decodeToken(&token_buf, t) else null;

            if (token) |t| {
                const result = auth_st.validateToken(t);
                if (result.role == .none) {
                    if (self.rate_limiter) |rl| rl.recordFailure(ip_str);
                    self.sendError(stream, 401, "Unauthorized");
                    stream.close();
                    return;
                }
                if (self.rate_limiter) |rl| rl.recordSuccess(ip_str);

                // Permanent token on non-WebSocket request → exchange for JWT and redirect
                if (auth.isPermanentToken(t) and !self.isWebSocketUpgrade(request)) {
                    // For share links (no session_id), find a session matching the link's role
                    const session = if (result.session_id) |sid|
                        auth_st.getSession(sid)
                    else
                        auth_st.getSessionByRole(result.role) orelse auth_st.getSession("default");
                    if (session) |s| {
                        var jwt_buf: [256]u8 = undefined;
                        const jwt = auth_st.createJwt(s, &jwt_buf);
                        self.sendRedirectPage(stream, jwt);
                        stream.close();
                        return;
                    }
                }
            } else {
                // No token at all
                self.sendError(stream, 401, "Unauthorized");
                stream.close();
                return;
            }
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

        // Handle /api/* endpoints via callback (benchmark-only)
        if (comptime build_options.enable_benchmark) {
            if (std.mem.startsWith(u8, path, "/api/")) {
                if (self.api_callback) |cb| {
                    if (cb(path, self.api_user_data)) |json| {
                        var api_header_buf: [512]u8 = undefined;
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
        }

        // Serve embedded files
        const clean_path = if (std.mem.eql(u8, path, "/")) "/index.html" else path;

        // index.html is served dynamically with config JSON injected at the marker
        if (std.mem.eql(u8, clean_path, "/index.html")) {
            self.sendIndexHtml(stream);
            return;
        }

        const content: []const u8 = if (std.mem.eql(u8, clean_path, "/file-worker.js"))
            embedded_file_worker_js
        else if (std.mem.eql(u8, clean_path, "/zstd.wasm"))
            embedded_zstd_wasm
        else {
            self.sendError(stream, 404, "Not Found");
            return;
        };

        // Determine content type
        const content_type = getContentType(clean_path);

        var header_buf: [768]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {}\r\n" ++ cross_origin_headers ++ "Connection: close\r\n\r\n", .{ content_type, content.len }) catch return;

        _ = stream.write(header) catch return;
        _ = stream.write(content) catch return;
    }

    /// Serve index.html with config JSON injected at the template marker.
    /// The HTML is split at comptime around `<!--TERMWEB_CONFIG-->`. At serve time
    /// we write: before + <script>window.__TERMWEB_CONFIG__=JSON</script> + after.
    fn sendIndexHtml(self: *HttpServer, stream: net.Stream) void {
        const config_body = self.config_json orelse "{}";
        const total_len = html_before_config.len + config_script_prefix.len + config_body.len + config_script_suffix.len + html_after_config.len;

        var header_buf: [768]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\n" ++ cross_origin_headers ++ "Connection: close\r\n\r\n", .{total_len}) catch return;

        _ = stream.write(header) catch return;
        _ = stream.write(html_before_config) catch return;
        _ = stream.write(config_script_prefix) catch return;
        _ = stream.write(config_body) catch return;
        _ = stream.write(config_script_suffix) catch return;
        _ = stream.write(html_after_config) catch return;
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

    /// Send a minimal HTML page with a spinner that redirects to the JWT URL.
    /// Used to exchange static tokens for JWTs without the static token entering browser history.
    fn sendRedirectPage(_: *HttpServer, stream: net.Stream, jwt: []const u8) void {
        const header = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nCache-Control: no-store\r\n" ++ cross_origin_headers ++ "Connection: close\r\n\r\n";
        const prefix =
            \\<!DOCTYPE html><html><head><style>
            \\body{display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#1a1a2e}
            \\.s{width:40px;height:40px;border:3px solid #333;border-top-color:#7c3aed;border-radius:50%;animation:r .6s linear infinite}
            \\@keyframes r{to{transform:rotate(360deg)}}
            \\</style></head><body><div class="s"></div><script>location.replace(location.pathname+'?token=
        ;
        const suffix = "')</script></body></html>";
        _ = stream.write(header) catch return;
        _ = stream.write(prefix) catch return;
        _ = stream.write(jwt) catch return;
        _ = stream.write(suffix) catch return;
    }

    fn sendError(self: *HttpServer, stream: net.Stream, code: u16, message: []const u8) void {
        _ = self;
        var buf: [512]u8 = undefined;
        const response = std.fmt.bufPrint(&buf, "HTTP/1.1 {} {s}\r\nContent-Type: text/plain\r\nContent-Length: {}\r\n" ++ cross_origin_headers ++ "Connection: close\r\n\r\n{s}", .{ code, message, message.len, message }) catch return;
        _ = stream.write(response) catch {};
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
