const std = @import("std");

pub const WebSocketError = error{
    ConnectionFailed,
    HandshakeFailed,
    InvalidFrame,
    ConnectionClosed,
    ProtocolError,
    InvalidUrl,
    OutOfMemory,
};

const Frame = struct {
    opcode: u8,
    payload: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Frame) void {
        self.allocator.free(self.payload);
    }
};

const ParsedUrl = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
};

pub const WebSocketCdpClient = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    next_id: std.atomic.Value(u32),

    pub fn connect(allocator: std.mem.Allocator, ws_url: []const u8) !*WebSocketCdpClient {
        const parsed = try parseWsUrl(allocator, ws_url);
        defer allocator.free(parsed.host);
        defer allocator.free(parsed.path);

        // TCP connect
        const address = try std.net.Address.parseIp(parsed.host, parsed.port);
        const stream = try std.net.tcpConnectToAddress(address);

        const client = try allocator.create(WebSocketCdpClient);
        client.* = .{
            .allocator = allocator,
            .stream = stream,
            .next_id = std.atomic.Value(u32).init(1),
        };

        // Perform WebSocket handshake
        try client.performHandshake(parsed.host, parsed.path);

        return client;
    }

    pub fn deinit(self: *WebSocketCdpClient) void {
        self.stream.close();
        self.allocator.destroy(self);
    }

    pub fn sendCommand(self: *WebSocketCdpClient, method: []const u8, params: ?[]const u8) ![]u8 {
        // Get unique ID
        const id = self.next_id.fetchAdd(1, .monotonic);

        // Build JSON command
        const command = if (params) |p|
            try std.fmt.allocPrint(
                self.allocator,
                "{{\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}",
                .{ id, method, p },
            )
        else
            try std.fmt.allocPrint(
                self.allocator,
                "{{\"id\":{d},\"method\":\"{s}\"}}",
                .{ id, method },
            );
        defer self.allocator.free(command);

        // Send as WebSocket text frame
        try self.sendFrame(0x1, command);

        // Wait for response with matching ID
        while (true) {
            var frame = try self.recvFrame();
            defer frame.deinit();

            // Parse JSON to find ID
            if (std.mem.indexOf(u8, frame.payload, "\"id\":")) |id_pos| {
                const id_str = try std.fmt.allocPrint(self.allocator, "{d}", .{id});
                defer self.allocator.free(id_str);

                // Check if this response matches our request ID
                if (std.mem.indexOf(u8, frame.payload[id_pos..], id_str)) |_| {
                    // Extract result
                    if (std.mem.indexOf(u8, frame.payload, "\"result\":")) |_| {
                        // Return entire response for parsing by caller
                        return try self.allocator.dupe(u8, frame.payload);
                    } else if (std.mem.indexOf(u8, frame.payload, "\"error\":")) |_| {
                        return WebSocketError.ProtocolError;
                    }
                }
            }
            // Non-matching response - continue waiting
        }
    }

    fn performHandshake(self: *WebSocketCdpClient, host: []const u8, path: []const u8) !void {
        var buf: [4096]u8 = undefined;

        // Generate random WebSocket key
        var key_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&key_bytes);

        var key_b64: [24]u8 = undefined;
        const key_b64_len = std.base64.standard.Encoder.encode(&key_b64, &key_bytes).len;

        // Build handshake request
        var request_buf: [1024]u8 = undefined;
        const request = try std.fmt.bufPrint(&request_buf,
            "GET {s} HTTP/1.1\r\n" ++
            "Host: {s}\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: {s}\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "\r\n",
            .{ path, host, key_b64[0..key_b64_len] }
        );

        // Send handshake request
        _ = try self.stream.writeAll(request);

        // Read response line by line
        var total_read: usize = 0;
        while (total_read < buf.len) {
            const bytes_read = try self.stream.read(buf[total_read..]);
            if (bytes_read == 0) break;
            total_read += bytes_read;

            // Check for HTTP 101 response
            const response_so_far = buf[0..total_read];
            if (std.mem.indexOf(u8, response_so_far, "101")) |_| {
                // Found 101, handshake successful
                break;
            }
        }

        // Verify we got a 101 response
        const response = buf[0..total_read];
        if (std.mem.indexOf(u8, response, "101")) |_| {
            return;  // Success
        }

        return WebSocketError.HandshakeFailed;
    }

    fn sendFrame(self: *WebSocketCdpClient, opcode: u8, payload: []const u8) !void {
        var frame_buf: [16384]u8 = undefined;
        var frame_len: usize = 0;
        const payload_len = payload.len;

        // Byte 0: FIN (1) + RSV (0) + opcode
        frame_buf[frame_len] = 0x80 | opcode;
        frame_len += 1;

        // Byte 1: MASK (1) + payload length
        if (payload_len < 126) {
            frame_buf[frame_len] = 0x80 | @as(u8, @intCast(payload_len));
            frame_len += 1;
        } else if (payload_len < 65536) {
            frame_buf[frame_len] = 0x80 | 126;
            frame_len += 1;
            std.mem.writeInt(u16, frame_buf[frame_len..][0..2], @intCast(payload_len), .big);
            frame_len += 2;
        } else {
            frame_buf[frame_len] = 0x80 | 127;
            frame_len += 1;
            std.mem.writeInt(u64, frame_buf[frame_len..][0..8], @intCast(payload_len), .big);
            frame_len += 8;
        }

        // Generate masking key
        var mask: [4]u8 = undefined;
        std.crypto.random.bytes(&mask);
        @memcpy(frame_buf[frame_len..][0..4], &mask);
        frame_len += 4;

        // Write masked payload
        for (payload, 0..) |byte, i| {
            frame_buf[frame_len] = byte ^ mask[i % 4];
            frame_len += 1;
        }

        // Send frame
        _ = try self.stream.writeAll(frame_buf[0..frame_len]);
    }

    fn recvFrame(self: *WebSocketCdpClient) !Frame {
        var header_buf: [14]u8 = undefined;

        // Read first 2 bytes
        _ = try self.stream.readAtLeast(header_buf[0..2], 2);
        const byte0 = header_buf[0];
        const byte1 = header_buf[1];

        const opcode = byte0 & 0x0F;
        const masked = (byte1 & 0x80) != 0;
        var payload_len: u64 = byte1 & 0x7F;
        var header_len: usize = 2;

        // Handle extended payload length
        if (payload_len == 126) {
            _ = try self.stream.readAtLeast(header_buf[header_len..][0..2], 2);
            payload_len = std.mem.readInt(u16, header_buf[header_len..][0..2], .big);
            header_len += 2;
        } else if (payload_len == 127) {
            _ = try self.stream.readAtLeast(header_buf[header_len..][0..8], 8);
            payload_len = std.mem.readInt(u64, header_buf[header_len..][0..8], .big);
            header_len += 8;
        }

        // Read masking key (server frames should not be masked)
        if (masked) {
            _ = try self.stream.readAtLeast(header_buf[header_len..][0..4], 4);
            header_len += 4;
        }

        // Read payload
        const payload = try self.allocator.alloc(u8, @intCast(payload_len));
        errdefer self.allocator.free(payload);
        const bytes_read = try self.stream.readAtLeast(payload, @intCast(payload_len));

        if (bytes_read != payload_len) {
            self.allocator.free(payload);
            return WebSocketError.InvalidFrame;
        }

        // Handle control frames
        switch (opcode) {
            0x9 => { // Ping
                try self.sendFrame(0xA, payload); // Pong
                self.allocator.free(payload);
                return self.recvFrame(); // Continue to next frame
            },
            0x8 => { // Close
                self.allocator.free(payload);
                return WebSocketError.ConnectionClosed;
            },
            0x1, 0x2 => { // Text or Binary
                return Frame{
                    .opcode = opcode,
                    .payload = payload,
                    .allocator = self.allocator,
                };
            },
            else => {
                self.allocator.free(payload);
                return WebSocketError.InvalidFrame;
            },
        }
    }
};

/// Parse WebSocket URL: ws://host:port/path
fn parseWsUrl(allocator: std.mem.Allocator, ws_url: []const u8) !ParsedUrl {
    // Check prefix
    if (!std.mem.startsWith(u8, ws_url, "ws://")) {
        return WebSocketError.InvalidUrl;
    }

    const after_protocol = ws_url["ws://".len..];

    // Find first / for path
    const slash_idx = std.mem.indexOf(u8, after_protocol, "/") orelse after_protocol.len;
    const authority = after_protocol[0..slash_idx];
    const path = if (slash_idx < after_protocol.len)
        try allocator.dupe(u8, after_protocol[slash_idx..])
    else
        try allocator.dupe(u8, "/");

    // Parse host:port
    if (std.mem.indexOf(u8, authority, ":")) |colon_idx| {
        const host = try allocator.dupe(u8, authority[0..colon_idx]);
        const port_str = authority[colon_idx + 1 ..];
        const port = std.fmt.parseInt(u16, port_str, 10) catch {
            allocator.free(host);
            allocator.free(path);
            return WebSocketError.InvalidUrl;
        };

        return ParsedUrl{
            .host = host,
            .port = port,
            .path = path,
        };
    } else {
        const host = try allocator.dupe(u8, authority);
        return ParsedUrl{
            .host = host,
            .port = 80,
            .path = path,
        };
    }
}
