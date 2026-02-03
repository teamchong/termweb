const std = @import("std");
const net = std.net;
const posix = std.posix;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;

const zstd = @import("zstd.zig");
const simd_mask = @import("simd_mask");

// Set socket read timeout for blocking I/O with periodic wakeup
fn setReadTimeout(fd: posix.socket_t, timeout_ms: u32) void {
    const tv = posix.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
}

// Set socket write timeout to prevent blocking on slow/unresponsive clients
fn setWriteTimeout(fd: posix.socket_t, timeout_ms: u32) void {
    const tv = posix.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch {};
}

// Find HTTP header value case-insensitively (proxies may lowercase headers)
fn findHeaderValue(request: []const u8, header_name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < request.len) {
        // Find line start
        const line_start = i;
        // Find end of line
        while (i < request.len and request[i] != '\r') : (i += 1) {}
        const line = request[line_start..i];

        // Skip \r\n
        if (i + 1 < request.len and request[i] == '\r' and request[i + 1] == '\n') {
            i += 2;
        } else {
            break;
        }

        // Check if line starts with header name (case-insensitive)
        if (line.len > header_name.len + 1) { // +1 for ':'
            var matches = true;
            for (0..header_name.len) |j| {
                if (std.ascii.toLower(line[j]) != std.ascii.toLower(header_name[j])) {
                    matches = false;
                    break;
                }
            }
            if (matches and line[header_name.len] == ':') {
                // Found header, extract value (skip ': ' prefix)
                var value_start = header_name.len + 1;
                while (value_start < line.len and (line[value_start] == ' ' or line[value_start] == '\t')) {
                    value_start += 1;
                }
                return line[value_start..];
            }
        }
    }
    return null;
}

// ============================================================================
// WebSocket Protocol
// ============================================================================

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,
};

pub const Frame = struct {
    fin: bool,
    opcode: Opcode,
    payload: []u8,
};

// ============================================================================
// WebSocket Connection
// ============================================================================

pub const Connection = struct {
    stream: net.Stream,
    allocator: Allocator,
    is_open: bool,
    user_data: ?*anyopaque,
    request_uri: ?[]const u8 = null,  // Request URI for auth token extraction
    // App-level zstd compression (replaces permessage-deflate)
    zstd_enabled: bool = false,
    compressor: ?zstd.Compressor = null,
    decompressor: ?zstd.Decompressor = null,

    pub fn init(stream: net.Stream, allocator: Allocator) Connection {
        return .{
            .stream = stream,
            .allocator = allocator,
            .is_open = true,
            .user_data = null,
            .request_uri = null,
            .zstd_enabled = false,
            .compressor = null,
            .decompressor = null,
        };
    }

    pub fn deinit(self: *Connection) void {
        // Free zstd resources - null out after freeing to prevent double-free
        if (self.compressor) |*comp| {
            comp.deinit();
            self.compressor = null;
        }
        if (self.decompressor) |*decomp| {
            decomp.deinit();
            self.decompressor = null;
        }
        if (self.request_uri) |uri| {
            self.allocator.free(uri);
            self.request_uri = null;
        }
        self.stream.close();
        self.is_open = false;
    }

    // Perform WebSocket handshake (server side)
    // Set enable_zstd=false for connections that carry pre-compressed data (like video frames)
    pub fn acceptHandshake(self: *Connection) !void {
        return self.acceptHandshakeWithOptions(true);
    }

    pub fn acceptHandshakeNoDeflate(self: *Connection) !void {
        return self.acceptHandshakeWithOptions(false);
    }

    fn acceptHandshakeWithOptions(self: *Connection, enable_zstd: bool) !void {
        var buf: [4096]u8 = undefined;
        const n = try self.stream.read(&buf);
        if (n == 0) return error.ConnectionClosed;

        const request = buf[0..n];

        // Extract request URI from first line (e.g., "GET /control?token=xyz HTTP/1.1")
        if (std.mem.indexOf(u8, request, " ")) |method_end| {
            const uri_start = method_end + 1;
            if (std.mem.indexOfPos(u8, request, uri_start, " ")) |uri_end| {
                self.request_uri = self.allocator.dupe(u8, request[uri_start..uri_end]) catch null;
            }
        }

        // Find Sec-WebSocket-Key header (case-insensitive - proxies may lowercase)
        const ws_key = findHeaderValue(request, "sec-websocket-key") orelse return error.InvalidHandshake;

        // Generate accept key: base64(sha1(key + magic))
        const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
        var hasher = std.crypto.hash.Sha1.init(.{});
        hasher.update(ws_key);
        hasher.update(magic);
        const hash = hasher.finalResult();

        var accept_key: [28]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&accept_key, &hash);

        // Check for X-Compression: zstd header (app-level compression)
        const has_zstd = enable_zstd and findHeaderValue(request, "x-compression") != null;

        // Send handshake response (no permessage-deflate - we use app-level zstd)
        const response = "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: ";
        _ = try self.stream.write(response);
        _ = try self.stream.write(&accept_key);

        // Enable zstd if client supports it (indicated by X-Compression header)
        if (has_zstd) {
            _ = try self.stream.write("\r\nX-Compression: zstd");
            self.zstd_enabled = true;
            self.compressor = zstd.Compressor.init(self.allocator, 3) catch null;
            self.decompressor = zstd.Decompressor.init(self.allocator) catch null;
        }

        _ = try self.stream.write("\r\n\r\n");
    }

    // Accept handshake with pre-read request (for HTTP server upgrade)
    pub fn acceptHandshakeFromRequest(self: *Connection, request: []const u8, enable_zstd: bool) !void {
        // Extract request URI from first line (e.g., "GET /ws/panel?token=xyz HTTP/1.1")
        if (std.mem.indexOf(u8, request, " ")) |method_end| {
            const uri_start = method_end + 1;
            if (std.mem.indexOfPos(u8, request, uri_start, " ")) |uri_end| {
                self.request_uri = self.allocator.dupe(u8, request[uri_start..uri_end]) catch null;
            }
        }

        // Find Sec-WebSocket-Key header (case-insensitive - proxies may lowercase)
        const ws_key = findHeaderValue(request, "sec-websocket-key") orelse return error.InvalidHandshake;

        // Generate accept key: base64(sha1(key + magic))
        const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
        var hasher = std.crypto.hash.Sha1.init(.{});
        hasher.update(ws_key);
        hasher.update(magic);
        const hash = hasher.finalResult();

        var accept_key: [28]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&accept_key, &hash);

        // Check for X-Compression: zstd header (app-level compression)
        const has_zstd = enable_zstd and findHeaderValue(request, "x-compression") != null;

        // Send handshake response (no permessage-deflate - we use app-level zstd)
        const response = "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: ";
        _ = try self.stream.write(response);
        _ = try self.stream.write(&accept_key);

        // Enable zstd if client supports it
        if (has_zstd) {
            _ = try self.stream.write("\r\nX-Compression: zstd");
            self.zstd_enabled = true;
            self.compressor = zstd.Compressor.init(self.allocator, 3) catch null;
            self.decompressor = zstd.Decompressor.init(self.allocator) catch null;
        }

        _ = try self.stream.write("\r\n\r\n");
    }

    // Read a WebSocket frame
    // App-level zstd: first byte of binary payload is compression flag (0x01 = zstd compressed)
    pub fn readFrame(self: *Connection) !?Frame {
        var header: [2]u8 = undefined;
        const header_read = self.stream.read(&header) catch return null;
        if (header_read < 2) return null;

        const fin = (header[0] & 0x80) != 0;
        const opcode: Opcode = @enumFromInt(@as(u4, @truncate(header[0] & 0x0F)));
        const masked = (header[1] & 0x80) != 0;
        var payload_len: u64 = header[1] & 0x7F;

        // Extended payload length
        if (payload_len == 126) {
            var ext: [2]u8 = undefined;
            _ = try self.stream.read(&ext);
            payload_len = std.mem.readInt(u16, &ext, .big);
        } else if (payload_len == 127) {
            var ext: [8]u8 = undefined;
            _ = try self.stream.read(&ext);
            payload_len = std.mem.readInt(u64, &ext, .big);
        }

        // Read mask if present
        var mask: [4]u8 = undefined;
        if (masked) {
            _ = try self.stream.read(&mask);
        }

        // Read payload
        if (payload_len > 16 * 1024 * 1024) return error.PayloadTooLarge;
        var payload = try self.allocator.alloc(u8, @intCast(payload_len));
        errdefer self.allocator.free(payload);

        var total_read: usize = 0;
        while (total_read < payload.len) {
            const read = self.stream.read(payload[total_read..]) catch break;
            if (read == 0) break;
            total_read += read;
        }

        // Unmask if needed (SIMD-accelerated)
        if (masked) {
            simd_mask.xorMask(payload, mask);
        }

        // App-level zstd decompression for binary frames
        // Format: [compression_flag:u8][data...]
        // compression_flag: 0x00 = uncompressed, 0x01 = zstd compressed
        if (opcode == .binary and self.zstd_enabled and payload.len > 1) {
            const compression_flag = payload[0];
            if (compression_flag == 0x01) {
                // zstd compressed
                if (self.decompressor) |*decomp| {
                    const compressed_data = payload[1..];
                    const max_decompressed = 16 * 1024 * 1024; // 16MB max

                    const decompressed = decomp.decompress(compressed_data, max_decompressed) catch {
                        return error.DecompressionFailed;
                    };

                    // Replace payload with decompressed data (no compression flag prefix)
                    self.allocator.free(payload);
                    payload = decompressed;
                }
            } else if (compression_flag == 0x00) {
                // Uncompressed - strip the flag byte
                const data = payload[1..];
                const new_payload = try self.allocator.alloc(u8, data.len);
                @memcpy(new_payload, data);
                self.allocator.free(payload);
                payload = new_payload;
            }
            // Unknown flags are passed through as-is
        }

        return .{
            .fin = fin,
            .opcode = opcode,
            .payload = payload,
        };
    }

    // Write a WebSocket frame with optional zstd compression
    // For binary frames with zstd enabled: [compression_flag:u8][data...]
    // compression_flag: 0x00 = uncompressed, 0x01 = zstd compressed
    pub fn writeFrame(self: *Connection, opcode: Opcode, payload: []const u8) !void {
        // For binary frames with zstd enabled, add compression flag prefix
        var final_payload: []const u8 = payload;
        var compressed_buf: ?[]u8 = null;
        defer if (compressed_buf) |buf| self.allocator.free(buf);

        if (opcode == .binary and self.zstd_enabled) {
            // Only try compression for payloads > 64 bytes
            if (payload.len > 64) {
                if (self.compressor) |*comp| {
                    if (comp.compress(payload)) |compressed| {
                        // Only use compression if it actually reduces size
                        if (compressed.len + 1 < payload.len) {
                            // Build compressed payload: [0x01][compressed_data]
                            const with_flag = self.allocator.alloc(u8, compressed.len + 1) catch {
                                self.allocator.free(compressed);
                                // Fall through to send uncompressed with flag
                                return self.sendUncompressedWithFlag(payload);
                            };
                            with_flag[0] = 0x01; // zstd compressed flag
                            @memcpy(with_flag[1..], compressed);
                            self.allocator.free(compressed);
                            compressed_buf = with_flag;
                            final_payload = with_flag;
                        } else {
                            self.allocator.free(compressed);
                            // Compression didn't help, send uncompressed with flag
                            return self.sendUncompressedWithFlag(payload);
                        }
                    } else |_| {
                        // Compression failed, send uncompressed with flag
                        return self.sendUncompressedWithFlag(payload);
                    }
                } else {
                    // No compressor, send uncompressed with flag
                    return self.sendUncompressedWithFlag(payload);
                }
            } else {
                // Small payload, skip compression but still add flag byte
                return self.sendUncompressedWithFlag(payload);
            }
        }

        try self.writeFrameRaw(opcode, final_payload, false);
    }

    // Helper: send binary data with uncompressed flag prefix
    fn sendUncompressedWithFlag(self: *Connection, payload: []const u8) !void {
        const with_flag = try self.allocator.alloc(u8, payload.len + 1);
        defer self.allocator.free(with_flag);
        with_flag[0] = 0x00; // uncompressed flag
        @memcpy(with_flag[1..], payload);
        try self.writeFrameRaw(.binary, with_flag, false);
    }

    // Write raw WebSocket frame without compression processing
    fn writeFrameRaw(self: *Connection, opcode: Opcode, payload: []const u8, _: bool) !void {
        var header: [10]u8 = undefined;
        var header_len: usize = 2;

        header[0] = 0x80 | @as(u8, @intFromEnum(opcode)); // FIN + opcode

        if (payload.len < 126) {
            header[1] = @intCast(payload.len);
        } else if (payload.len < 65536) {
            header[1] = 126;
            std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .big);
            header_len = 4;
        } else {
            header[1] = 127;
            std.mem.writeInt(u64, header[2..10], payload.len, .big);
            header_len = 10;
        }

        _ = try self.stream.write(header[0..header_len]);
        _ = try self.stream.write(payload);
    }

    // Send binary data
    pub fn sendBinary(self: *Connection, data: []const u8) !void {
        try self.writeFrame(.binary, data);
    }

    // Send text data
    pub fn sendText(self: *Connection, data: []const u8) !void {
        try self.writeFrame(.text, data);
    }

    // Send close frame
    pub fn sendClose(self: *Connection) !void {
        if (!self.is_open) return; // Already closed
        try self.writeFrame(.close, &[_]u8{});
        self.is_open = false;
    }

    // Send pong in response to ping
    pub fn sendPong(self: *Connection, data: []const u8) !void {
        try self.writeFrame(.pong, data);
    }
};

// ============================================================================
// WebSocket Server
// ============================================================================

pub const Server = struct {
    listener: net.Server,
    allocator: Allocator,
    running: std.atomic.Value(bool),
    active_connections: std.atomic.Value(u32), // Track active connection threads
    enable_zstd: bool,
    on_connect: ?*const fn (*Connection) void,
    on_message: ?*const fn (*Connection, []u8, bool) void, // conn, data, is_binary
    on_disconnect: ?*const fn (*Connection) void,

    pub fn init(allocator: Allocator, address: []const u8, port: u16) !*Server {
        return initWithOptions(allocator, address, port, true);
    }

    pub fn initNoDeflate(allocator: Allocator, address: []const u8, port: u16) !*Server {
        return initWithOptions(allocator, address, port, false);
    }

    fn initWithOptions(allocator: Allocator, address: []const u8, port: u16, enable_zstd: bool) !*Server {
        const server = try allocator.create(Server);
        errdefer allocator.destroy(server);

        const addr = try net.Address.parseIp4(address, port);
        server.* = .{
            .listener = try addr.listen(.{ .reuse_address = true, .force_nonblocking = true }),
            .allocator = allocator,
            .running = std.atomic.Value(bool).init(false),
            .active_connections = std.atomic.Value(u32).init(0),
            .enable_zstd = enable_zstd,
            .on_connect = null,
            .on_message = null,
            .on_disconnect = null,
        };

        return server;
    }

    pub fn deinit(self: *Server) void {
        self.stop();
        // Wait for all active connection threads to finish
        var wait_count: u32 = 0;
        while (self.active_connections.load(.acquire) > 0) {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            wait_count += 1;
            // Timeout after 2 seconds to avoid hanging forever
            if (wait_count > 200) break;
        }
        self.listener.deinit();
        self.allocator.destroy(self);
    }

    pub fn setCallbacks(
        self: *Server,
        on_connect: ?*const fn (*Connection) void,
        on_message: ?*const fn (*Connection, []u8, bool) void,
        on_disconnect: ?*const fn (*Connection) void,
    ) void {
        self.on_connect = on_connect;
        self.on_message = on_message;
        self.on_disconnect = on_disconnect;
    }

    pub fn stop(self: *Server) void {
        self.running.store(false, .release);
    }

    // Accept one connection and handle it (blocking)
    pub fn acceptOne(self: *Server) !*Connection {
        const stream = try self.listener.accept();

        const conn = try self.allocator.create(Connection);
        conn.* = Connection.init(stream.stream, self.allocator);

        // Set socket timeouts for blocking I/O
        setReadTimeout(stream.stream.handle, 100); // 100ms wakeup for shutdown check
        setWriteTimeout(stream.stream.handle, 1000); // 1s write timeout to prevent blocking

        // Perform handshake (with or without zstd based on server config)
        try conn.acceptHandshakeWithOptions(self.enable_zstd);

        if (self.on_connect) |cb| cb(conn);

        return conn;
    }

    // Handle connection messages in a loop
    pub fn handleConnection(self: *Server, conn: *Connection) void {
        while (conn.is_open and self.running.load(.acquire)) {
            const frame = conn.readFrame() catch break;

            // readFrame returns null on timeout - just continue to check running flag
            if (frame == null) continue;

            const f = frame.?;
            defer conn.allocator.free(f.payload);

            switch (f.opcode) {
                .text, .binary => {
                    if (self.on_message) |cb| {
                        cb(conn, f.payload, f.opcode == .binary);
                    }
                },
                .ping => {
                    conn.sendPong(f.payload) catch {};
                },
                .close => {
                    conn.sendClose() catch {};
                    break;
                },
                else => {},
            }
        }

        if (self.on_disconnect) |cb| cb(conn);
        conn.deinit();
        self.allocator.destroy(conn);
    }

    // Run server loop (blocking)
    pub fn run(self: *Server) !void {
        self.running.store(true, .release);

        while (self.running.load(.acquire)) {
            const conn = self.acceptOne() catch |err| {
                if (err == error.WouldBlock) {
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                    continue;
                }
                continue;
            };

            // Handle in thread
            const thread = Thread.spawn(.{}, handleConnectionThread, .{ self, conn }) catch {
                conn.deinit();
                self.allocator.destroy(conn);
                continue;
            };
            thread.detach();
        }
    }

    fn handleConnectionThread(self: *Server, conn: *Connection) void {
        _ = self.active_connections.fetchAdd(1, .acq_rel);
        defer _ = self.active_connections.fetchSub(1, .acq_rel);
        self.handleConnection(conn);
    }

    // Handle a WebSocket upgrade from an HTTP server
    // The stream and pre-read request are passed from the HTTP handler
    pub fn handleUpgrade(self: *Server, stream: net.Stream, request: []const u8) void {
        const conn = self.allocator.create(Connection) catch return;
        conn.* = Connection.init(stream, self.allocator);

        // Set socket timeouts for blocking I/O
        setReadTimeout(stream.handle, 100); // 100ms wakeup for shutdown check
        setWriteTimeout(stream.handle, 1000); // 1s write timeout to prevent blocking

        // Complete WebSocket handshake with pre-read request
        conn.acceptHandshakeFromRequest(request, self.enable_zstd) catch {
            conn.deinit();
            self.allocator.destroy(conn);
            return;
        };

        if (self.on_connect) |cb| cb(conn);

        // Spawn a new thread to handle this connection
        const thread = std.Thread.spawn(.{}, handleConnectionThread, .{ self, conn }) catch {
            conn.deinit();
            self.allocator.destroy(conn);
            return;
        };
        thread.detach();
    }
};
