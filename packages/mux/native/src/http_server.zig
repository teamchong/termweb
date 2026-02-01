const std = @import("std");
const net = std.net;
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("ghostty.h");
});

// Color struct matching ghostty_config_color_s
const Color = extern struct {
    r: u8,
    g: u8,
    b: u8,
};

// Simple HTTP server for static files + config endpoint
pub const HttpServer = struct {
    listener: net.Server,
    allocator: Allocator,
    web_root: []const u8,
    running: std.atomic.Value(bool),
    panel_ws_port: u16,
    control_ws_port: u16,
    file_ws_port: u16,
    ghostty_config: c.ghostty_config_t,

    pub fn init(allocator: Allocator, address: []const u8, port: u16, web_root: []const u8, ghostty_config: c.ghostty_config_t) !*HttpServer {
        const server = try allocator.create(HttpServer);
        errdefer allocator.destroy(server);

        const addr = try net.Address.parseIp4(address, port);
        server.* = .{
            .listener = try addr.listen(.{ .reuse_address = true }),
            .allocator = allocator,
            .web_root = web_root,
            .running = std.atomic.Value(bool).init(false),
            .panel_ws_port = 0,
            .control_ws_port = 0,
            .file_ws_port = 0,
            .ghostty_config = ghostty_config,
        };

        return server;
    }

    pub fn setWsPorts(self: *HttpServer, panel_port: u16, control_port: u16, file_port: u16) void {
        self.panel_ws_port = panel_port;
        self.control_ws_port = control_port;
        self.file_ws_port = file_port;
    }

    pub fn deinit(self: *HttpServer) void {
        self.stop();
        self.listener.deinit();
        self.allocator.destroy(self);
    }

    pub fn stop(self: *HttpServer) void {
        self.running.store(false, .release);
    }

    pub fn run(self: *HttpServer) !void {
        self.running.store(true, .release);
        std.debug.print("HTTP server listening on port {}\n", .{self.listener.listen_address.getPort()});

        while (self.running.load(.acquire)) {
            const conn = self.listener.accept() catch |err| {
                if (err == error.WouldBlock) {
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                    continue;
                }
                continue;
            };

            const thread = std.Thread.spawn(.{}, handleConnection, .{ self, conn.stream }) catch {
                conn.stream.close();
                continue;
            };
            thread.detach();
        }
    }

    fn handleConnection(self: *HttpServer, stream: net.Stream) void {
        defer stream.close();

        var buf: [4096]u8 = undefined;
        const n = stream.read(&buf) catch return;
        if (n == 0) return;

        const request = buf[0..n];

        // Parse request line
        const line_end = std.mem.indexOf(u8, request, "\r\n") orelse return;
        const request_line = request[0..line_end];

        // Parse method and path
        var parts = std.mem.splitScalar(u8, request_line, ' ');
        const method = parts.next() orelse return;
        const path = parts.next() orelse return;

        if (!std.mem.eql(u8, method, "GET")) {
            self.sendError(stream, 405, "Method Not Allowed");
            return;
        }

        // Handle /config endpoint - returns WebSocket ports
        if (std.mem.eql(u8, path, "/config")) {
            self.sendConfig(stream);
            return;
        }

        // Sanitize path
        const clean_path = if (std.mem.eql(u8, path, "/")) "/index.html" else path;
        if (std.mem.indexOf(u8, clean_path, "..") != null) {
            self.sendError(stream, 403, "Forbidden");
            return;
        }

        // Build full path
        var full_path_buf: [1024]u8 = undefined;
        const full_path = std.fmt.bufPrint(&full_path_buf, "{s}{s}", .{ self.web_root, clean_path }) catch {
            self.sendError(stream, 500, "Internal Error");
            return;
        };

        // Read file
        const file = std.fs.openFileAbsolute(full_path, .{}) catch {
            self.sendError(stream, 404, "Not Found");
            return;
        };
        defer file.close();

        const stat = file.stat() catch {
            self.sendError(stream, 500, "Internal Error");
            return;
        };

        const content = file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch {
            self.sendError(stream, 500, "Internal Error");
            return;
        };
        defer self.allocator.free(content);

        // Determine content type
        const content_type = getContentType(clean_path);

        // Send response
        var header_buf: [512]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", .{ content_type, stat.size }) catch return;

        _ = stream.write(header) catch return;
        _ = stream.write(content) catch return;
    }

    fn sendError(self: *HttpServer, stream: net.Stream, code: u16, message: []const u8) void {
        _ = self;
        var buf: [256]u8 = undefined;
        const response = std.fmt.bufPrint(&buf, "HTTP/1.1 {} {s}\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{s}", .{ code, message, message.len, message }) catch return;
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

        var body_buf: [512]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf,
            \\{{"panelWsPort":{},"controlWsPort":{},"fileWsPort":{},"colors":{{"background":"#{x:0>2}{x:0>2}{x:0>2}","foreground":"#{x:0>2}{x:0>2}{x:0>2}"}}}}
        , .{
            self.panel_ws_port,
            self.control_ws_port,
            self.file_ws_port,
            bg.r, bg.g, bg.b,
            fg.r, fg.g, fg.b,
        }) catch return;

        var header_buf: [256]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n", .{body.len}) catch return;

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
        return "application/octet-stream";
    }
};
