//! WebSocket Client Implementation for EdgeBox WASM
//!
//! RFC 6455 compliant WebSocket with TLS support.
//! Adapted from metal0's websocket package for WASM context.

const std = @import("std");
const host = @import("host.zig");
const tls = @import("tls.zig");

const wasm_allocator = std.heap.wasm_allocator;

// ============================================================================
// WebSocket Protocol (RFC 6455)
// ============================================================================

pub const Opcode = enum(u4) {
    Continue = 0x0,
    Text = 0x1,
    Binary = 0x2,
    Close = 0x8,
    Ping = 0x9,
    Pong = 0xA,
    _,

    pub fn isControl(self: Opcode) bool {
        return @intFromEnum(self) & 0x8 != 0;
    }
};

pub const CloseCode = enum(u16) {
    Normal = 1000,
    GoingAway = 1001,
    ProtocolError = 1002,
    UnsupportedData = 1003,
    NoStatus = 1005,
    Abnormal = 1006,
    InvalidPayload = 1007,
    PolicyViolation = 1008,
    MessageTooBig = 1009,
    MandatoryExtension = 1010,
    InternalError = 1011,
    _,
};

/// Apply XOR mask to payload data
pub fn applyMask(data: []u8, mask: [4]u8) void {
    for (data, 0..) |*byte, i| {
        byte.* ^= mask[i % 4];
    }
}

/// Generate random masking key
pub fn generateMask() [4]u8 {
    var mask: [4]u8 = undefined;
    std.crypto.random.bytes(&mask);
    return mask;
}

// ============================================================================
// WebSocket Errors
// ============================================================================

pub const WebSocketError = error{
    ConnectionFailed,
    HandshakeFailed,
    InvalidResponse,
    ConnectionClosed,
    InvalidFrame,
    MessageTooLarge,
    ProtocolError,
    TlsError,
    TlsHandshakeFailed,
    SendFailed,
    RecvFailed,
    OutOfMemory,
};

// ============================================================================
// WebSocket State
// ============================================================================

pub const State = enum {
    Connecting,
    Open,
    Closing,
    Closed,
};

// ============================================================================
// WebSocket Message
// ============================================================================

pub const Message = struct {
    data: []u8,
    is_binary: bool,
    owned: bool, // Whether data should be freed

    pub fn text(data: []const u8) !Message {
        const copy = try wasm_allocator.alloc(u8, data.len);
        @memcpy(copy, data);
        return .{ .data = copy, .is_binary = false, .owned = true };
    }

    pub fn binary(data: []const u8) !Message {
        const copy = try wasm_allocator.alloc(u8, data.len);
        @memcpy(copy, data);
        return .{ .data = copy, .is_binary = true, .owned = true };
    }

    pub fn deinit(self: *Message) void {
        if (self.owned) {
            wasm_allocator.free(self.data);
        }
    }
};

// ============================================================================
// WebSocket Client
// ============================================================================

pub const WebSocketClient = struct {
    fd: i32, // Host socket file descriptor
    tls_conn: ?*tls.TlsConnection, // TLS connection for wss://
    is_tls: bool,
    state: State,
    host_name: []const u8, // Kept for handshake
    path: []const u8,
    max_message_size: usize,
    // Fragmentation state (RFC 6455)
    fragment_buffer: ?[]u8, // Accumulated fragment data
    fragment_opcode: ?Opcode, // Original message type (Text/Binary)
    fragment_len: usize, // Current accumulated length

    const Self = @This();

    /// Parse URL and create WebSocket client
    pub fn init(url: []const u8) !*Self {
        const client = try wasm_allocator.create(Self);
        errdefer wasm_allocator.destroy(client);

        // Parse URL (ws://host:port/path or wss://host:port/path)
        var is_tls = false;
        var start: usize = 0;

        if (std.mem.startsWith(u8, url, "wss://")) {
            is_tls = true;
            start = 6;
        } else if (std.mem.startsWith(u8, url, "ws://")) {
            start = 5;
        } else {
            return WebSocketError.ConnectionFailed;
        }

        const rest = url[start..];

        // Find path start
        const path_start = std.mem.indexOf(u8, rest, "/") orelse rest.len;
        const host_port = rest[0..path_start];
        const path = if (path_start < rest.len) rest[path_start..] else "/";

        // Parse host:port
        var host_name: []const u8 = undefined;
        var port: u16 = if (is_tls) 443 else 80;

        if (std.mem.indexOf(u8, host_port, ":")) |colon| {
            host_name = host_port[0..colon];
            port = std.fmt.parseInt(u16, host_port[colon + 1 ..], 10) catch port;
        } else {
            host_name = host_port;
        }

        // Copy host name (we need it for handshake)
        const host_copy = try wasm_allocator.alloc(u8, host_name.len);
        @memcpy(host_copy, host_name);

        // Copy path
        const path_copy = try wasm_allocator.alloc(u8, path.len);
        @memcpy(path_copy, path);

        // Connect to host
        const fd = host.netConnect(host_name, port);
        if (fd < 0) {
            wasm_allocator.free(host_copy);
            wasm_allocator.free(path_copy);
            return WebSocketError.ConnectionFailed;
        }

        client.* = .{
            .fd = fd,
            .tls_conn = null,
            .is_tls = is_tls,
            .state = .Connecting,
            .host_name = host_copy,
            .path = path_copy,
            .max_message_size = 16 * 1024 * 1024, // 16MB
            .fragment_buffer = null,
            .fragment_opcode = null,
            .fragment_len = 0,
        };

        return client;
    }

    pub fn deinit(self: *Self) void {
        self.close() catch {};

        if (self.tls_conn) |tc| {
            tc.deinit();
        }

        // Clean up any pending fragment buffer
        if (self.fragment_buffer) |buf| {
            wasm_allocator.free(buf);
        }

        wasm_allocator.free(@constCast(self.host_name));
        wasm_allocator.free(@constCast(self.path));
        host.netClose(self.fd);
        wasm_allocator.destroy(self);
    }

    /// Perform WebSocket connection and handshake
    pub fn connect(self: *Self) !void {
        if (self.state != .Connecting) return;

        // Perform TLS handshake if wss://
        if (self.is_tls) {
            self.tls_conn = tls.TlsConnection.init(self.fd) catch {
                self.state = .Closed;
                return WebSocketError.TlsError;
            };

            self.tls_conn.?.handshake(self.host_name, &[_][]const u8{}) catch {
                if (self.tls_conn) |tc| {
                    tc.deinit();
                    self.tls_conn = null;
                }
                self.state = .Closed;
                return WebSocketError.TlsHandshakeFailed;
            };
        }

        // Perform WebSocket handshake
        try self.performHandshake();
        self.state = .Open;
    }

    fn performHandshake(self: *Self) !void {
        // Generate WebSocket key
        var key_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&key_bytes);
        var key_encoded: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key_encoded, &key_bytes);

        // Build HTTP upgrade request
        var request_buf: [2048]u8 = undefined;
        const request = std.fmt.bufPrint(&request_buf,
            "GET {s} HTTP/1.1\r\n" ++
                "Host: {s}\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Sec-WebSocket-Key: {s}\r\n" ++
                "Sec-WebSocket-Version: 13\r\n" ++
                "\r\n",
            .{ self.path, self.host_name, key_encoded },
        ) catch return WebSocketError.ConnectionFailed;

        // Send upgrade request
        try self.writeAll(request);

        // Read response
        var response_buf: [4096]u8 = undefined;
        var total_read: usize = 0;

        while (total_read < response_buf.len) {
            const n = try self.readSome(response_buf[total_read..]);
            if (n == 0) return WebSocketError.ConnectionClosed;
            total_read += n;

            // Check for end of headers
            if (std.mem.indexOf(u8, response_buf[0..total_read], "\r\n\r\n")) |_| {
                break;
            }
        }

        const response = response_buf[0..total_read];

        // Verify 101 Switching Protocols
        if (!std.mem.startsWith(u8, response, "HTTP/1.1 101")) {
            return WebSocketError.HandshakeFailed;
        }

        // Verify Upgrade header
        if (std.mem.indexOf(u8, response, "Upgrade: websocket") == null and
            std.mem.indexOf(u8, response, "upgrade: websocket") == null)
        {
            return WebSocketError.HandshakeFailed;
        }
    }

    // === I/O Helpers ===

    fn writeAll(self: *Self, data: []const u8) !void {
        if (self.tls_conn) |tc| {
            tc.send(data) catch return WebSocketError.TlsError;
        } else {
            var written: usize = 0;
            while (written < data.len) {
                const n = host.netSend(self.fd, data[written..]);
                if (n <= 0) return WebSocketError.SendFailed;
                written += @intCast(n);
            }
        }
    }

    fn readSome(self: *Self, buffer: []u8) !usize {
        if (self.tls_conn) |tc| {
            return tc.recv(buffer) catch return WebSocketError.TlsError;
        } else {
            const n = host.netRecv(self.fd, buffer);
            if (n < 0) return WebSocketError.RecvFailed;
            return @intCast(n);
        }
    }

    fn readAll(self: *Self, buffer: []u8) !void {
        var total: usize = 0;
        while (total < buffer.len) {
            const n = try self.readSome(buffer[total..]);
            if (n == 0) return WebSocketError.ConnectionClosed;
            total += n;
        }
    }

    // === Public API ===

    /// Send a text message
    pub fn sendText(self: *Self, data: []const u8) !void {
        try self.sendFrame(.Text, data);
    }

    /// Send a binary message
    pub fn sendBinary(self: *Self, data: []const u8) !void {
        try self.sendFrame(.Binary, data);
    }

    /// Send a ping
    pub fn ping(self: *Self) !void {
        try self.sendFrame(.Ping, &[_]u8{});
    }

    /// Send a close frame
    pub fn close(self: *Self) !void {
        if (self.state != .Open) return;
        self.state = .Closing;

        // Send close frame with normal close code
        var payload: [2]u8 = undefined;
        payload[0] = @truncate(@intFromEnum(CloseCode.Normal) >> 8);
        payload[1] = @truncate(@intFromEnum(CloseCode.Normal));
        self.sendFrame(.Close, &payload) catch {};

        self.state = .Closed;
    }

    fn sendFrame(self: *Self, opcode: Opcode, data: []const u8) !void {
        if (self.state != .Open and opcode != .Close) return WebSocketError.ConnectionClosed;

        const payload_len = data.len;

        // Build header
        var header_buf: [14]u8 = undefined;
        var header_len: usize = 2;

        // First byte: FIN + opcode
        header_buf[0] = 0x80 | @as(u8, @intFromEnum(opcode)); // FIN=1

        // Second byte: MASK + length
        if (payload_len <= 125) {
            header_buf[1] = 0x80 | @as(u8, @truncate(payload_len)); // MASK=1
        } else if (payload_len <= 65535) {
            header_buf[1] = 0x80 | 126;
            header_buf[2] = @truncate(payload_len >> 8);
            header_buf[3] = @truncate(payload_len);
            header_len = 4;
        } else {
            header_buf[1] = 0x80 | 127;
            const len64: u64 = @intCast(payload_len);
            header_buf[2] = @truncate(len64 >> 56);
            header_buf[3] = @truncate(len64 >> 48);
            header_buf[4] = @truncate(len64 >> 40);
            header_buf[5] = @truncate(len64 >> 32);
            header_buf[6] = @truncate(len64 >> 24);
            header_buf[7] = @truncate(len64 >> 16);
            header_buf[8] = @truncate(len64 >> 8);
            header_buf[9] = @truncate(len64);
            header_len = 10;
        }

        // Write header
        try self.writeAll(header_buf[0..header_len]);

        // Write mask
        const mask = generateMask();
        try self.writeAll(&mask);

        // Write masked payload
        if (payload_len > 0) {
            const masked_data = try wasm_allocator.alloc(u8, payload_len);
            defer wasm_allocator.free(masked_data);
            @memcpy(masked_data, data);
            applyMask(masked_data, mask);
            try self.writeAll(masked_data);
        }
    }

    /// Receive a message
    pub fn recv(self: *Self) !Message {
        if (self.state != .Open) return WebSocketError.ConnectionClosed;

        while (true) {
            // Read header (2 bytes)
            var header: [2]u8 = undefined;
            try self.readAll(&header);

            const fin = (header[0] & 0x80) != 0;
            const opcode: Opcode = @enumFromInt(@as(u4, @truncate(header[0] & 0x0F)));
            const masked = (header[1] & 0x80) != 0;
            var payload_len: usize = header[1] & 0x7F;

            // Read extended length
            if (payload_len == 126) {
                var len_bytes: [2]u8 = undefined;
                try self.readAll(&len_bytes);
                payload_len = (@as(usize, len_bytes[0]) << 8) | len_bytes[1];
            } else if (payload_len == 127) {
                var len_bytes: [8]u8 = undefined;
                try self.readAll(&len_bytes);
                const len64 = std.mem.readInt(u64, &len_bytes, .big);
                // Check if length fits in usize (important for 32-bit WASM)
                if (len64 > std.math.maxInt(usize)) {
                    return WebSocketError.MessageTooLarge;
                }
                payload_len = @intCast(len64);
            }

            if (payload_len > self.max_message_size) {
                return WebSocketError.MessageTooLarge;
            }

            // Read mask if present
            var mask: ?[4]u8 = null;
            if (masked) {
                var mask_bytes: [4]u8 = undefined;
                try self.readAll(&mask_bytes);
                mask = mask_bytes;
            }

            // Read payload
            const payload = try wasm_allocator.alloc(u8, payload_len);
            errdefer wasm_allocator.free(payload);

            if (payload_len > 0) {
                try self.readAll(payload);
                if (mask) |m| {
                    applyMask(payload, m);
                }
            }

            // Handle control frames (can be interleaved with fragments)
            switch (opcode) {
                .Close => {
                    self.state = .Closed;
                    wasm_allocator.free(payload);
                    return WebSocketError.ConnectionClosed;
                },
                .Ping => {
                    // Send pong with same payload
                    self.sendFrame(.Pong, payload) catch {};
                    wasm_allocator.free(payload);
                    continue;
                },
                .Pong => {
                    wasm_allocator.free(payload);
                    continue;
                },
                .Text, .Binary => {
                    if (fin) {
                        // Complete message in single frame
                        return Message{
                            .data = payload,
                            .is_binary = opcode == .Binary,
                            .owned = true,
                        };
                    } else {
                        // Start of fragmented message
                        if (self.fragment_buffer != null) {
                            // Protocol error: new fragment started before previous completed
                            wasm_allocator.free(payload);
                            return WebSocketError.ProtocolError;
                        }
                        // Allocate buffer for accumulating fragments
                        self.fragment_buffer = try wasm_allocator.alloc(u8, self.max_message_size);
                        self.fragment_opcode = opcode;
                        self.fragment_len = payload_len;
                        @memcpy(self.fragment_buffer.?[0..payload_len], payload);
                        wasm_allocator.free(payload);
                        continue;
                    }
                },
                .Continue => {
                    // Continuation frame
                    if (self.fragment_buffer == null) {
                        // Protocol error: continuation without initial frame
                        wasm_allocator.free(payload);
                        return WebSocketError.ProtocolError;
                    }
                    // Check if adding this payload exceeds max size
                    if (self.fragment_len + payload_len > self.max_message_size) {
                        wasm_allocator.free(payload);
                        if (self.fragment_buffer) |buf| wasm_allocator.free(buf);
                        self.fragment_buffer = null;
                        return WebSocketError.MessageTooLarge;
                    }
                    // Append to fragment buffer
                    @memcpy(self.fragment_buffer.?[self.fragment_len .. self.fragment_len + payload_len], payload);
                    self.fragment_len += payload_len;
                    wasm_allocator.free(payload);

                    if (fin) {
                        // Final fragment - return complete message
                        const is_binary = self.fragment_opcode == .Binary;
                        // Shrink buffer to actual size
                        const complete_data = wasm_allocator.realloc(self.fragment_buffer.?, self.fragment_len) catch self.fragment_buffer.?[0..self.fragment_len];
                        self.fragment_buffer = null;
                        self.fragment_opcode = null;
                        const len = self.fragment_len;
                        self.fragment_len = 0;
                        return Message{
                            .data = complete_data[0..len],
                            .is_binary = is_binary,
                            .owned = true,
                        };
                    }
                    continue;
                },
                else => {
                    wasm_allocator.free(payload);
                    continue;
                },
            }
        }
    }
};
