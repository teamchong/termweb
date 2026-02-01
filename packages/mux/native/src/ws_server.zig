const std = @import("std");
const net = std.net;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("libdeflate.h");
});

const simd_mask = @import("simd_mask");

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
    // permessage-deflate fields
    deflate_enabled: bool = false,
    compressor: ?*c.libdeflate_compressor = null,
    decompressor: ?*c.libdeflate_decompressor = null,

    pub fn init(stream: net.Stream, allocator: Allocator) Connection {
        return .{
            .stream = stream,
            .allocator = allocator,
            .is_open = true,
            .user_data = null,
            .request_uri = null,
            .deflate_enabled = false,
            .compressor = null,
            .decompressor = null,
        };
    }

    pub fn deinit(self: *Connection) void {
        // Free deflate resources
        if (self.compressor) |comp| c.libdeflate_free_compressor(comp);
        if (self.decompressor) |decomp| c.libdeflate_free_decompressor(decomp);
        if (self.request_uri) |uri| self.allocator.free(uri);
        self.stream.close();
        self.is_open = false;
    }

    // Perform WebSocket handshake (server side)
    // Set enable_deflate=false for connections that carry pre-compressed data (like video frames)
    pub fn acceptHandshake(self: *Connection) !void {
        return self.acceptHandshakeWithOptions(true);
    }

    pub fn acceptHandshakeNoDeflate(self: *Connection) !void {
        return self.acceptHandshakeWithOptions(false);
    }

    fn acceptHandshakeWithOptions(self: *Connection, enable_deflate: bool) !void {
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

        // Find Sec-WebSocket-Key header
        const key_header = "Sec-WebSocket-Key: ";
        const key_start = std.mem.indexOf(u8, request, key_header) orelse return error.InvalidHandshake;
        const key_value_start = key_start + key_header.len;
        const key_end = std.mem.indexOfPos(u8, request, key_value_start, "\r\n") orelse return error.InvalidHandshake;
        const ws_key = request[key_value_start..key_end];

        // Generate accept key: base64(sha1(key + magic))
        const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
        var hasher = std.crypto.hash.Sha1.init(.{});
        hasher.update(ws_key);
        hasher.update(magic);
        const hash = hasher.finalResult();

        var accept_key: [28]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&accept_key, &hash);

        // Check for permessage-deflate extension (only if enabled for this connection)
        const has_deflate = enable_deflate and std.mem.indexOf(u8, request, "permessage-deflate") != null;

        // Send handshake response
        const response = "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: ";
        _ = try self.stream.write(response);
        _ = try self.stream.write(&accept_key);

        // Enable permessage-deflate if client supports it
        if (has_deflate) {
            _ = try self.stream.write("\r\nSec-WebSocket-Extensions: permessage-deflate; server_no_context_takeover; client_no_context_takeover");
            self.deflate_enabled = true;
            self.compressor = c.libdeflate_alloc_compressor(6);
            self.decompressor = c.libdeflate_alloc_decompressor();
        }

        _ = try self.stream.write("\r\n\r\n");
    }

    // Read a WebSocket frame
    pub fn readFrame(self: *Connection) !?Frame {
        var header: [2]u8 = undefined;
        const header_read = self.stream.read(&header) catch return null;
        if (header_read < 2) return null;

        const fin = (header[0] & 0x80) != 0;
        const rsv1 = (header[0] & 0x40) != 0; // Compression flag per RFC 7692
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

        // Decompress if RSV1 is set and deflate is enabled (per RFC 7692)
        if (rsv1 and self.deflate_enabled) {
            if (self.decompressor) |decomp| {
                // Per RFC 7692, sender removed trailing 0x00 0x00 0xFF 0xFF from deflate output.
                // We add it back, then append a final empty stored block with BFINAL=1.
                // libdeflate requires BFINAL=1 to know the stream is complete.
                const input = try self.allocator.alloc(u8, payload.len + 4 + 5);
                defer self.allocator.free(input);
                @memcpy(input[0..payload.len], payload);
                // Complete original empty stored block (BFINAL=0)
                input[payload.len..][0..4].* = .{ 0x00, 0x00, 0xFF, 0xFF };
                // Add final empty stored block (BFINAL=1)
                input[payload.len + 4 ..][0..5].* = .{ 0x01, 0x00, 0x00, 0xFF, 0xFF };

                // Allocate decompression buffer (start with 10x, retry with larger if needed)
                var decompress_buf = try self.allocator.alloc(u8, payload.len * 10 + 4096);

                var actual_size: usize = 0;
                var result = c.libdeflate_deflate_decompress(
                    decomp,
                    input.ptr,
                    input.len,
                    decompress_buf.ptr,
                    decompress_buf.len,
                    &actual_size,
                );

                // If buffer too small, try with larger buffer
                if (result == c.LIBDEFLATE_INSUFFICIENT_SPACE) {
                    self.allocator.free(decompress_buf);
                    decompress_buf = try self.allocator.alloc(u8, payload.len * 100 + 65536);
                    result = c.libdeflate_deflate_decompress(
                        decomp,
                        input.ptr,
                        input.len,
                        decompress_buf.ptr,
                        decompress_buf.len,
                        &actual_size,
                    );
                }

                if (result != c.LIBDEFLATE_SUCCESS) {
                    self.allocator.free(decompress_buf);
                    return error.DecompressionFailed;
                }

                // Replace payload with decompressed data
                self.allocator.free(payload);
                const final_payload = try self.allocator.alloc(u8, actual_size);
                @memcpy(final_payload, decompress_buf[0..actual_size]);
                self.allocator.free(decompress_buf);
                payload = final_payload;
            }
        }

        return .{
            .fin = fin,
            .opcode = opcode,
            .payload = payload,
        };
    }

    // Write a WebSocket frame
    // Note: Server-side compression disabled because libdeflate produces complete
    // deflate streams with BFINAL=1, not Z_SYNC_FLUSH format that browsers expect.
    // Client->server decompression still works.
    pub fn writeFrame(self: *Connection, opcode: Opcode, payload: []const u8) !void {
        var header: [10]u8 = undefined;
        var header_len: usize = 2;

        header[0] = 0x80 | @as(u8, @intFromEnum(opcode)); // FIN + opcode, no compression

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
    enable_deflate: bool,
    on_connect: ?*const fn (*Connection) void,
    on_message: ?*const fn (*Connection, []u8, bool) void, // conn, data, is_binary
    on_disconnect: ?*const fn (*Connection) void,

    pub fn init(allocator: Allocator, address: []const u8, port: u16) !*Server {
        return initWithOptions(allocator, address, port, true);
    }

    pub fn initNoDeflate(allocator: Allocator, address: []const u8, port: u16) !*Server {
        return initWithOptions(allocator, address, port, false);
    }

    fn initWithOptions(allocator: Allocator, address: []const u8, port: u16, enable_deflate: bool) !*Server {
        const server = try allocator.create(Server);
        errdefer allocator.destroy(server);

        const addr = try net.Address.parseIp4(address, port);
        server.* = .{
            .listener = try addr.listen(.{ .reuse_address = true }),
            .allocator = allocator,
            .running = std.atomic.Value(bool).init(false),
            .enable_deflate = enable_deflate,
            .on_connect = null,
            .on_message = null,
            .on_disconnect = null,
        };

        return server;
    }

    pub fn deinit(self: *Server) void {
        self.stop();
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

        // Perform handshake (with or without deflate based on server config)
        try conn.acceptHandshakeWithOptions(self.enable_deflate);

        if (self.on_connect) |cb| cb(conn);

        return conn;
    }

    // Handle connection messages in a loop
    pub fn handleConnection(self: *Server, conn: *Connection) void {
        while (conn.is_open and self.running.load(.acquire)) {
            const frame = conn.readFrame() catch |err| {
                std.debug.print("Read error: {}\n", .{err});
                break;
            };

            if (frame == null) {
                std.Thread.sleep(1 * std.time.ns_per_ms);
                continue;
            }

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
        std.debug.print("WebSocket server listening on port {}\n", .{self.listener.listen_address.getPort()});

        while (self.running.load(.acquire)) {
            const conn = self.acceptOne() catch |err| {
                if (err == error.WouldBlock) {
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                    continue;
                }
                std.debug.print("Accept error: {}\n", .{err});
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
        self.handleConnection(conn);
    }
};
