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

// PWA manifest (served without auth)
const pwa_manifest =
    \\{"name":"termweb","short_name":"termweb","start_url":"/","display":"standalone",
    \\"background_color":"#1a1a2e","theme_color":"#1a1a2e",
    \\"icons":[{"src":"data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>👻</text></svg>","sizes":"any","type":"image/svg+xml"}]}
;

// Login page HTML template. GitHub/Google buttons are conditionally shown via data attributes
// injected at serve time. The page is a simple centered card with token input and OAuth buttons.
const login_page_html =
    \\<!DOCTYPE html><html><head>
    \\<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    \\<link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>👻</text></svg>">
    \\<link rel="manifest" href="/manifest.json">
    \\<title>termweb - Login</title>
    \\<style>
    \\*{margin:0;padding:0;box-sizing:border-box}
    \\body{background:#1a1a2e;color:#e0e0e0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
    \\height:100vh;display:flex;align-items:center;justify-content:center}
    \\.card{background:#16213e;border:1px solid rgba(255,255,255,0.1);border-radius:12px;padding:32px;
    \\width:360px;max-width:90vw;text-align:center}
    \\.logo{font-size:48px;margin-bottom:8px}
    \\h1{font-size:20px;font-weight:600;margin-bottom:4px;color:#fff}
    \\.subtitle{font-size:13px;color:#888;margin-bottom:24px}
    \\.divider{border:none;border-top:1px solid rgba(255,255,255,0.1);margin:16px 0}
    \\form{display:flex;flex-direction:column;gap:8px}
    \\input[type=text]{background:#0f1629;border:1px solid rgba(255,255,255,0.15);border-radius:6px;
    \\padding:10px 12px;color:#fff;font-size:14px;outline:none}
    \\input[type=text]:focus{border-color:#7c3aed}
    \\input[type=text]::placeholder{color:#555}
    \\.btn{padding:10px 16px;border:none;border-radius:6px;font-size:14px;font-weight:500;
    \\cursor:pointer;display:flex;align-items:center;justify-content:center;gap:8px;width:100%;
    \\transition:background .15s}
    \\.btn-primary{background:#7c3aed;color:#fff}
    \\.btn-primary:hover{background:#6d28d9}
    \\.btn-github{background:#24292e;color:#fff}
    \\.btn-github:hover{background:#2f363d}
    \\.btn-google{background:#fff;color:#333}
    \\.btn-google:hover{background:#f0f0f0}
    \\.oauth-section{display:flex;flex-direction:column;gap:8px}
    \\.error{background:rgba(239,68,68,0.15);border:1px solid rgba(239,68,68,0.3);
    \\border-radius:6px;padding:8px;font-size:13px;color:#ef4444;margin-bottom:8px}
    \\.hidden{display:none}
    \\</style></head><body>
    \\<div class="card">
    \\<div class="logo">👻</div>
    \\<h1>termweb</h1>
    \\<div class="subtitle">Terminal in your browser</div>
    \\<div id="error" class="error hidden"></div>
    \\<div class="oauth-section">
    \\<a id="gh-btn" class="btn btn-github hidden" href="/auth/github">
    \\<svg width="20" height="20" viewBox="0 0 16 16" fill="currentColor"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"/></svg>
    \\Sign in with GitHub</a>
    \\<a id="gg-btn" class="btn btn-google hidden" href="/auth/google">
    \\<svg width="20" height="20" viewBox="0 0 48 48"><path fill="#EA4335" d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z"/><path fill="#4285F4" d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z"/><path fill="#FBBC05" d="M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z"/><path fill="#34A853" d="M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z"/></svg>
    \\Sign in with Google</a>
    \\</div>
    \\<hr class="divider">
    \\<form method="POST" action="/auth/login">
    \\<input type="text" name="token" placeholder="Paste access token..." autocomplete="off" autofocus>
    \\<button type="submit" class="btn btn-primary">Sign in with Token</button>
    \\</form>
    \\</div>
    \\<script>
    \\var p=new URLSearchParams(location.search);
    \\if(p.get('error')){var e=document.getElementById('error');e.textContent=p.get('error');e.classList.remove('hidden')}
    \\if(document.body.dataset.github==='1')document.getElementById('gh-btn').classList.remove('hidden');
    \\if(document.body.dataset.google==='1')document.getElementById('gg-btn').classList.remove('hidden');
    \\</script></body></html>
;

// Comptime split of login page around <body> tag for data attribute injection
const login_body_tag = "<body>";
const login_body_pos = std.mem.indexOf(u8, login_page_html, login_body_tag) orelse @compileError("<body> tag not found in login page");
const login_before_body = login_page_html[0..login_body_pos];
const login_after_body = login_page_html[login_body_pos + login_body_tag.len ..];


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

        const is_get = std.mem.eql(u8, method, "GET");
        const is_post = std.mem.eql(u8, method, "POST");
        if (!is_get and !is_post) {
            self.sendError(stream, 405, "Method Not Allowed");
            stream.close();
            return;
        }

        // Public paths — no auth required
        const is_public = std.mem.eql(u8, path, "/manifest.json") or
            std.mem.eql(u8, path, "/favicon.ico") or
            std.mem.startsWith(u8, path, "/auth/");

        // Auth check — all requests except public paths require a valid token
        if (!is_public) {
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
                    // No token — serve login page on GET / instead of 401
                    if (is_get and (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html"))) {
                        self.sendLoginPage(stream);
                        stream.close();
                        return;
                    }
                    self.sendError(stream, 401, "Unauthorized");
                    stream.close();
                    return;
                }
            }
        }

        // Handle POST routes
        if (is_post) {
            defer stream.close();
            if (std.mem.eql(u8, path, "/auth/login")) {
                self.handleAuthLogin(stream, request, n);
            } else {
                self.sendError(stream, 404, "Not Found");
            }
            return;
        }

        // Handle public GET routes
        if (std.mem.eql(u8, path, "/manifest.json")) {
            self.sendStaticContent(stream, "application/json", pwa_manifest);
            stream.close();
            return;
        }
        if (std.mem.eql(u8, path, "/auth/github")) {
            self.handleOAuthRedirect(stream, "github", request);
            stream.close();
            return;
        }
        if (std.mem.eql(u8, path, "/auth/google")) {
            self.handleOAuthRedirect(stream, "google", request);
            stream.close();
            return;
        }
        if (std.mem.eql(u8, path, "/auth/github/callback")) {
            self.handleOAuthCallback(stream, "github", full_path, request);
            stream.close();
            return;
        }
        if (std.mem.eql(u8, path, "/auth/google/callback")) {
            self.handleOAuthCallback(stream, "google", full_path, request);
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

    fn isWebSocketUpgrade(_: *HttpServer, request: []const u8) bool {
        const value = extractHeader(request, "Upgrade:") orelse return false;
        return std.ascii.eqlIgnoreCase(value, "websocket");
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

    /// Serve the login page with OAuth provider flags injected as data attributes.
    fn sendLoginPage(self: *HttpServer, stream: net.Stream) void {
        const has_github: bool = if (self.auth_state) |as| as.github_oauth != null else false;
        const has_google: bool = if (self.auth_state) |as| as.google_oauth != null else false;

        var body_tag_buf: [64]u8 = undefined;
        const body_tag = std.fmt.bufPrint(&body_tag_buf, "<body data-github=\"{}\" data-google=\"{}\">", .{
            @as(u8, if (has_github) 1 else 0),
            @as(u8, if (has_google) 1 else 0),
        }) catch "<body>";

        const total_len = login_before_body.len + body_tag.len + login_after_body.len;
        var header_buf: [512]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\n" ++ cross_origin_headers ++ "Connection: close\r\n\r\n", .{total_len}) catch return;
        _ = stream.write(header) catch return;
        _ = stream.write(login_before_body) catch return;
        _ = stream.write(body_tag) catch return;
        _ = stream.write(login_after_body) catch return;
    }

    /// Send a static content response with given content type.
    fn sendStaticContent(_: *HttpServer, stream: net.Stream, content_type: []const u8, content: []const u8) void {
        var header_buf: [512]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {}\r\n" ++ cross_origin_headers ++ "Connection: close\r\n\r\n", .{ content_type, content.len }) catch return;
        _ = stream.write(header) catch return;
        _ = stream.write(content) catch return;
    }

    /// Handle POST /auth/login — validate submitted token, create JWT, redirect.
    fn handleAuthLogin(self: *HttpServer, stream: net.Stream, request: []const u8, request_len: usize) void {
        const auth_st = self.auth_state orelse {
            self.sendError(stream, 500, "Auth not configured");
            return;
        };

        // Find request body (after \r\n\r\n)
        const body = findRequestBody(request, request_len) orelse {
            self.sendLoginRedirectWithError(stream, "No token provided");
            return;
        };

        // Parse form body: token=<value>
        const token_value = extractFormValue(body, "token") orelse {
            self.sendLoginRedirectWithError(stream, "No token provided");
            return;
        };

        if (token_value.len == 0) {
            self.sendLoginRedirectWithError(stream, "No token provided");
            return;
        }

        // URL-decode the token
        var decode_buf: [256]u8 = undefined;
        const decoded_token = auth.decodeToken(&decode_buf, token_value);

        // Validate the token
        const result = auth_st.validateToken(decoded_token);
        if (result.role == .none) {
            self.sendLoginRedirectWithError(stream, "Invalid token");
            return;
        }

        // Find session for JWT creation
        const session = if (result.session_id) |sid|
            auth_st.getSession(sid)
        else
            auth_st.getSessionByRole(result.role) orelse auth_st.getSession("default");

        if (session) |s| {
            var jwt_buf: [256]u8 = undefined;
            const jwt = auth_st.createJwt(s, &jwt_buf);
            self.sendRedirectPage(stream, jwt);
        } else {
            self.sendLoginRedirectWithError(stream, "Session not found");
        }
    }

    /// Redirect to OAuth provider's authorization URL.
    fn handleOAuthRedirect(self: *HttpServer, stream: net.Stream, provider: []const u8, request: []const u8) void {
        const auth_st = self.auth_state orelse {
            self.sendLoginRedirectWithError(stream, "Auth not configured");
            return;
        };

        // Detect redirect URI from Host header
        var redirect_uri_buf: [512]u8 = undefined;
        const redirect_uri = self.buildRedirectUri(&redirect_uri_buf, provider, request) orelse {
            self.sendLoginRedirectWithError(stream, "Cannot determine redirect URI");
            return;
        };

        if (std.mem.eql(u8, provider, "github")) {
            const gh = auth_st.github_oauth orelse {
                self.sendLoginRedirectWithError(stream, "GitHub OAuth not configured");
                return;
            };
            // Redirect to GitHub authorization
            var url_buf: [1024]u8 = undefined;
            const url = std.fmt.bufPrint(&url_buf, "https://github.com/login/oauth/authorize?client_id={s}&redirect_uri={s}&scope=user:email", .{
                gh.client_id,
                redirect_uri,
            }) catch {
                self.sendLoginRedirectWithError(stream, "URL too long");
                return;
            };
            self.sendHttpRedirect(stream, url);
        } else if (std.mem.eql(u8, provider, "google")) {
            const gg = auth_st.google_oauth orelse {
                self.sendLoginRedirectWithError(stream, "Google OAuth not configured");
                return;
            };
            var url_buf: [1024]u8 = undefined;
            const url = std.fmt.bufPrint(&url_buf, "https://accounts.google.com/o/oauth2/v2/auth?client_id={s}&redirect_uri={s}&response_type=code&scope=openid+email+profile", .{
                gg.client_id,
                redirect_uri,
            }) catch {
                self.sendLoginRedirectWithError(stream, "URL too long");
                return;
            };
            self.sendHttpRedirect(stream, url);
        } else {
            self.sendLoginRedirectWithError(stream, "Unknown OAuth provider");
        }
    }

    /// Handle OAuth callback — exchange code for token, get user info, create session.
    fn handleOAuthCallback(self: *HttpServer, stream: net.Stream, provider: []const u8, full_path: []const u8, request: []const u8) void {
        const auth_st = self.auth_state orelse {
            self.sendLoginRedirectWithError(stream, "Auth not configured");
            return;
        };

        // Extract code from query string and URL-decode it
        const raw_code = extractQueryParam(full_path, "code") orelse {
            self.sendLoginRedirectWithError(stream, "No authorization code");
            return;
        };
        var code_buf: [256]u8 = undefined;
        const code = auth.decodeToken(&code_buf, raw_code);

        // Build redirect URI for token exchange (must match the one used in the redirect)
        var redirect_uri_buf: [512]u8 = undefined;
        const redirect_uri = self.buildRedirectUri(&redirect_uri_buf, provider, request) orelse {
            self.sendLoginRedirectWithError(stream, "Cannot determine redirect URI");
            return;
        };

        if (std.mem.eql(u8, provider, "github")) {
            self.handleGitHubCallback(stream, auth_st, code, redirect_uri);
        } else if (std.mem.eql(u8, provider, "google")) {
            self.handleGoogleCallback(stream, auth_st, code, redirect_uri);
        } else {
            self.sendLoginRedirectWithError(stream, "Unknown provider");
        }
    }

    /// GitHub OAuth: exchange code → access token → user info → create session → redirect with JWT.
    fn handleGitHubCallback(self: *HttpServer, stream: net.Stream, auth_st: *auth.AuthState, code: []const u8, redirect_uri: []const u8) void {
        const gh = auth_st.github_oauth orelse {
            self.sendLoginRedirectWithError(stream, "GitHub OAuth not configured");
            return;
        };

        // Step 1: Exchange code for access token
        var post_body_buf: [1024]u8 = undefined;
        const post_body = std.fmt.bufPrint(&post_body_buf, "client_id={s}&client_secret={s}&code={s}&redirect_uri={s}", .{
            gh.client_id,
            gh.client_secret,
            code,
            redirect_uri,
        }) catch {
            self.sendLoginRedirectWithError(stream, "Request too large");
            return;
        };

        var response_buf: [4096]u8 = undefined;
        const token_response = httpFetch(self.allocator, "github.com", "/login/oauth/access_token", &response_buf, .{
            .method = .POST,
            .payload = post_body,
            .content_type = "application/x-www-form-urlencoded",
        }) orelse {
            self.sendLoginRedirectWithError(stream, "Failed to exchange code with GitHub");
            return;
        };

        // Parse access_token from response JSON: {"access_token":"...","token_type":"bearer",...}
        const access_token = extractJsonString(token_response, "\"access_token\":\"") orelse {
            self.sendLoginRedirectWithError(stream, "GitHub did not return access token");
            return;
        };

        // Step 2: Get user info
        var user_response_buf: [4096]u8 = undefined;
        const user_response = httpFetch(self.allocator, "api.github.com", "/user", &user_response_buf, .{
            .bearer_token = access_token,
        }) orelse {
            self.sendLoginRedirectWithError(stream, "Failed to get GitHub user info");
            return;
        };

        // Parse user info: {"id":12345,"login":"username",...}
        const user_id_str = extractJsonValue(user_response, "\"id\":") orelse {
            self.sendLoginRedirectWithError(stream, "Failed to parse GitHub user");
            return;
        };
        const login = extractJsonString(user_response, "\"login\":\"") orelse "github-user";

        // Step 3: Create session and redirect
        self.createOAuthSessionAndRedirect(stream, auth_st, "github", user_id_str, login);
    }

    /// Google OAuth: exchange code → ID token → parse claims → create session → redirect with JWT.
    fn handleGoogleCallback(self: *HttpServer, stream: net.Stream, auth_st: *auth.AuthState, code: []const u8, redirect_uri: []const u8) void {
        const gg = auth_st.google_oauth orelse {
            self.sendLoginRedirectWithError(stream, "Google OAuth not configured");
            return;
        };

        // Step 1: Exchange code for tokens
        var post_body_buf: [1024]u8 = undefined;
        const post_body = std.fmt.bufPrint(&post_body_buf, "client_id={s}&client_secret={s}&code={s}&redirect_uri={s}&grant_type=authorization_code", .{
            gg.client_id,
            gg.client_secret,
            code,
            redirect_uri,
        }) catch {
            self.sendLoginRedirectWithError(stream, "Request too large");
            return;
        };

        var response_buf: [8192]u8 = undefined;
        const token_response = httpFetch(self.allocator, "oauth2.googleapis.com", "/token", &response_buf, .{
            .method = .POST,
            .payload = post_body,
            .content_type = "application/x-www-form-urlencoded",
        }) orelse {
            self.sendLoginRedirectWithError(stream, "Failed to exchange code with Google");
            return;
        };

        // Parse id_token from response (it's a JWT with user claims)
        const id_token = extractJsonString(token_response, "\"id_token\":\"") orelse {
            self.sendLoginRedirectWithError(stream, "Google did not return ID token");
            return;
        };

        // Decode ID token payload (we trust Google's response, no need to verify signature here)
        const first_dot = std.mem.indexOfScalar(u8, id_token, '.') orelse {
            self.sendLoginRedirectWithError(stream, "Invalid ID token format");
            return;
        };
        const rest = id_token[first_dot + 1 ..];
        const second_dot = std.mem.indexOfScalar(u8, rest, '.') orelse {
            self.sendLoginRedirectWithError(stream, "Invalid ID token format");
            return;
        };
        const payload_b64 = id_token[first_dot + 1 ..][0..second_dot];
        var payload_buf: [2048]u8 = undefined;
        const payload_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload_b64) catch {
            self.sendLoginRedirectWithError(stream, "Invalid ID token encoding");
            return;
        };
        if (payload_len > payload_buf.len) {
            self.sendLoginRedirectWithError(stream, "ID token too large");
            return;
        }
        std.base64.url_safe_no_pad.Decoder.decode(payload_buf[0..payload_len], payload_b64) catch {
            self.sendLoginRedirectWithError(stream, "Invalid ID token encoding");
            return;
        };
        const payload = payload_buf[0..payload_len];

        // Extract claims: sub (user ID), name, email
        const sub = extractJsonString(payload, "\"sub\":\"") orelse {
            self.sendLoginRedirectWithError(stream, "No user ID in Google token");
            return;
        };
        const name = extractJsonString(payload, "\"name\":\"") orelse
            extractJsonString(payload, "\"email\":\"") orelse "google-user";

        // Step 2: Create session and redirect
        self.createOAuthSessionAndRedirect(stream, auth_st, "google", sub, name);
    }

    /// Build the OAuth redirect URI from the request's Host header.
    fn buildRedirectUri(self: *HttpServer, buf: *[512]u8, provider: []const u8, request: []const u8) ?[]const u8 {
        _ = self;
        const host = extractHeader(request, "Host:") orelse return null;

        // Detect protocol from X-Forwarded-Proto or default to http for localhost
        const proto = extractHeader(request, "X-Forwarded-Proto:") orelse
            (if (std.mem.startsWith(u8, host, "localhost") or std.mem.startsWith(u8, host, "127.0.0.1")) "http" else "https");

        return std.fmt.bufPrint(buf, "{s}://{s}/auth/{s}/callback", .{ proto, host, provider }) catch null;
    }

    /// Find or create an OAuth session and redirect to the app with a JWT.
    fn createOAuthSessionAndRedirect(self: *HttpServer, stream: net.Stream, auth_st: *auth.AuthState, provider: []const u8, user_id: []const u8, username: []const u8) void {
        const session = auth_st.findOrCreateOAuthSession(provider, user_id, username) catch {
            self.sendLoginRedirectWithError(stream, "Failed to create session");
            return;
        };
        var jwt_buf: [256]u8 = undefined;
        const jwt = auth_st.createJwt(session, &jwt_buf);
        self.sendRedirectPage(stream, jwt);
    }

    /// Send a 302 redirect.
    fn sendHttpRedirect(_: *HttpServer, stream: net.Stream, location: []const u8) void {
        var header_buf: [1536]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "HTTP/1.1 302 Found\r\nLocation: {s}\r\nContent-Length: 0\r\n" ++ cross_origin_headers ++ "Connection: close\r\n\r\n", .{location}) catch return;
        _ = stream.write(header) catch {};
    }

    /// Redirect back to login page with error message (URL-encodes spaces).
    fn sendLoginRedirectWithError(_: *HttpServer, stream: net.Stream, message: []const u8) void {
        // URL-encode the message: replace spaces with %20
        var encoded_buf: [256]u8 = undefined;
        var encoded_len: usize = 0;
        for (message) |c| {
            if (encoded_len + 3 > encoded_buf.len) break;
            if (c == ' ') {
                encoded_buf[encoded_len] = '%';
                encoded_buf[encoded_len + 1] = '2';
                encoded_buf[encoded_len + 2] = '0';
                encoded_len += 3;
            } else {
                encoded_buf[encoded_len] = c;
                encoded_len += 1;
            }
        }
        const encoded = encoded_buf[0..encoded_len];
        var header_buf: [512]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "HTTP/1.1 302 Found\r\nLocation: /?error={s}\r\nContent-Length: 0\r\n" ++ cross_origin_headers ++ "Connection: close\r\n\r\n", .{encoded}) catch return;
        _ = stream.write(header) catch {};
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

// --- Free functions for HTTP client and helpers ---

/// Extract a header value from raw HTTP request (case-insensitive key match).
fn extractHeader(request: []const u8, header_name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < request.len) {
        const line_start = i;
        while (i < request.len and request[i] != '\r') : (i += 1) {}
        const line = request[line_start..i];
        if (i + 1 < request.len and request[i] == '\r' and request[i + 1] == '\n') {
            i += 2;
        } else break;

        if (line.len >= header_name.len) {
            if (std.ascii.eqlIgnoreCase(line[0..header_name.len], header_name)) {
                return std.mem.trim(u8, line[header_name.len..], " \t");
            }
        }
    }
    return null;
}

/// Find the body of an HTTP request (content after \r\n\r\n).
fn findRequestBody(request: []const u8, request_len: usize) ?[]const u8 {
    if (std.mem.indexOf(u8, request[0..request_len], "\r\n\r\n")) |pos| {
        const body_start = pos + 4;
        if (body_start < request_len) {
            return request[body_start..request_len];
        }
    }
    return null;
}

/// Extract a value from URL-encoded form data (e.g., "token=abc&foo=bar" → "abc" for key "token").
fn extractFormValue(body: []const u8, key: []const u8) ?[]const u8 {
    // Find key= at start of body or after &
    var pos: usize = 0;
    while (true) {
        if (pos == 0 or (pos < body.len and body[pos - 1] == '&')) {
            if (pos + key.len < body.len and
                std.mem.eql(u8, body[pos..][0..key.len], key) and
                body[pos + key.len] == '=')
            {
                const start = pos + key.len + 1;
                var end = start;
                while (end < body.len and body[end] != '&') : (end += 1) {}
                return body[start..end];
            }
        }
        pos = (std.mem.indexOfScalarPos(u8, body, pos, '&') orelse return null) + 1;
    }
}

/// Extract a query parameter value from a URL path.
fn extractQueryParam(full_path: []const u8, key: []const u8) ?[]const u8 {
    const query_start = std.mem.indexOf(u8, full_path, "?") orelse return null;
    const query = full_path[query_start + 1 ..];
    return extractFormValue(query, key);
}

/// Extract a JSON string value given a prefix like `"key":"`.
fn extractJsonString(data: []const u8, prefix: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, data, prefix)) |pos| {
        const val_start = pos + prefix.len;
        if (std.mem.indexOfPos(u8, data, val_start, "\"")) |val_end| {
            return data[val_start..val_end];
        }
    }
    return null;
}

/// Extract a JSON numeric/unquoted value (e.g., "id": 12345).
fn extractJsonValue(data: []const u8, prefix: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, data, prefix)) |pos| {
        var start = pos + prefix.len;
        // Skip whitespace
        while (start < data.len and (data[start] == ' ' or data[start] == '\t')) : (start += 1) {}
        var end = start;
        while (end < data.len and data[end] != ',' and data[end] != '}' and data[end] != ' ' and data[end] != '\n') : (end += 1) {}
        if (end > start) return data[start..end];
    }
    return null;
}

/// Make an HTTPS request (GET or POST) and return the response body.
/// For POST: pass payload, content_type, and accept. For GET with Bearer auth: pass bearer_token.
fn httpFetch(
    allocator: Allocator,
    host: []const u8,
    path: []const u8,
    response_buf: []u8,
    opts: struct {
        method: std.http.Method = .GET,
        payload: ?[]const u8 = null,
        content_type: ?[]const u8 = null,
        accept: []const u8 = "application/json",
        bearer_token: ?[]const u8 = null,
    },
) ?[]const u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var uri_buf: [1024]u8 = undefined;
    const uri_str = std.fmt.bufPrint(&uri_buf, "https://{s}{s}", .{ host, path }) catch return null;

    // Build extra headers (up to 4)
    var headers: [4]std.http.Header = undefined;
    var header_count: usize = 0;
    if (opts.content_type) |ct| {
        headers[header_count] = .{ .name = "Content-Type", .value = ct };
        header_count += 1;
    }
    var auth_header_buf: [256]u8 = undefined;
    if (opts.bearer_token) |token| {
        const auth_val = std.fmt.bufPrint(&auth_header_buf, "Bearer {s}", .{token}) catch return null;
        headers[header_count] = .{ .name = "Authorization", .value = auth_val };
        header_count += 1;
    }
    headers[header_count] = .{ .name = "Accept", .value = opts.accept };
    header_count += 1;
    headers[header_count] = .{ .name = "User-Agent", .value = "termweb/1.0" };
    header_count += 1;

    var writer = std.Io.Writer.fixed(response_buf);
    const result = client.fetch(.{
        .location = .{ .url = uri_str },
        .method = opts.method,
        .payload = opts.payload,
        .response_writer = &writer,
        .extra_headers = headers[0..header_count],
    }) catch return null;

    if (result.status != .ok) return null;
    return response_buf[0..writer.end];
}

// --- Tests for free functions ---

test "extractHeader: finds case-insensitive header" {
    const req = "GET / HTTP/1.1\r\nHost: example.com\r\nUpgrade: websocket\r\n\r\n";
    try std.testing.expectEqualStrings("example.com", extractHeader(req, "Host:").?);
    try std.testing.expectEqualStrings("websocket", extractHeader(req, "Upgrade:").?);
    try std.testing.expectEqualStrings("websocket", extractHeader(req, "upgrade:").?);
    try std.testing.expect(extractHeader(req, "Missing:") == null);
}

test "extractHeader: trims whitespace" {
    const req = "GET / HTTP/1.1\r\nContent-Type:  application/json  \r\n\r\n";
    try std.testing.expectEqualStrings("application/json", extractHeader(req, "Content-Type:").?);
}

test "findRequestBody: extracts body after blank line" {
    const req = "POST /auth HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello";
    try std.testing.expectEqualStrings("hello", findRequestBody(req, req.len).?);
}

test "findRequestBody: returns null when no body" {
    const req = "GET / HTTP/1.1\r\nHost: x\r\n\r\n";
    try std.testing.expect(findRequestBody(req, req.len) == null);
}

test "extractFormValue: first key" {
    try std.testing.expectEqualStrings("abc", extractFormValue("token=abc&foo=bar", "token").?);
}

test "extractFormValue: middle key" {
    try std.testing.expectEqualStrings("bar", extractFormValue("token=abc&foo=bar&baz=1", "foo").?);
}

test "extractFormValue: last key" {
    try std.testing.expectEqualStrings("1", extractFormValue("token=abc&baz=1", "baz").?);
}

test "extractFormValue: missing key" {
    try std.testing.expect(extractFormValue("token=abc", "missing") == null);
}

test "extractFormValue: partial key match does not match" {
    // "tok" should not match "token=abc"
    try std.testing.expect(extractFormValue("token=abc", "tok") == null);
}

test "extractQueryParam: extracts from URL" {
    try std.testing.expectEqualStrings("xyz", extractQueryParam("/path?code=xyz&state=1", "code").?);
    try std.testing.expectEqualStrings("1", extractQueryParam("/path?code=xyz&state=1", "state").?);
    try std.testing.expect(extractQueryParam("/path?code=xyz", "missing") == null);
    try std.testing.expect(extractQueryParam("/path", "code") == null);
}

test "extractJsonString: parses string values" {
    const json = "{\"name\":\"alice\",\"role\":\"admin\"}";
    try std.testing.expectEqualStrings("alice", extractJsonString(json, "\"name\":\"").?);
    try std.testing.expectEqualStrings("admin", extractJsonString(json, "\"role\":\"").?);
    try std.testing.expect(extractJsonString(json, "\"missing\":\"") == null);
}

test "extractJsonValue: parses numeric values" {
    const json = "{\"id\": 12345, \"count\":99}";
    try std.testing.expectEqualStrings("12345", extractJsonValue(json, "\"id\":").?);
    try std.testing.expectEqualStrings("99", extractJsonValue(json, "\"count\":").?);
}
