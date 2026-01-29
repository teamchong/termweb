const std = @import("std");
const net = std.net;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;

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

    pub fn init(stream: net.Stream, allocator: Allocator) Connection {
        return .{
            .stream = stream,
            .allocator = allocator,
            .is_open = true,
            .user_data = null,
        };
    }

    pub fn deinit(self: *Connection) void {
        self.stream.close();
        self.is_open = false;
    }

    // Perform WebSocket handshake (server side)
    pub fn acceptHandshake(self: *Connection) !void {
        var buf: [4096]u8 = undefined;
        const n = try self.stream.read(&buf);
        if (n == 0) return error.ConnectionClosed;

        const request = buf[0..n];

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

        // Send handshake response
        const response = "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: ";
        _ = try self.stream.write(response);
        _ = try self.stream.write(&accept_key);
        _ = try self.stream.write("\r\n\r\n");
    }

    // Read a WebSocket frame
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
        const payload = try self.allocator.alloc(u8, @intCast(payload_len));
        errdefer self.allocator.free(payload);

        var total_read: usize = 0;
        while (total_read < payload.len) {
            const read = self.stream.read(payload[total_read..]) catch break;
            if (read == 0) break;
            total_read += read;
        }

        // Unmask if needed
        if (masked) {
            for (payload, 0..) |*byte, i| {
                byte.* ^= mask[i % 4];
            }
        }

        return .{
            .fin = fin,
            .opcode = opcode,
            .payload = payload,
        };
    }

    // Write a WebSocket frame
    pub fn writeFrame(self: *Connection, opcode: Opcode, payload: []const u8) !void {
        // Frame header
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
    on_connect: ?*const fn (*Connection) void,
    on_message: ?*const fn (*Connection, []u8, bool) void, // conn, data, is_binary
    on_disconnect: ?*const fn (*Connection) void,

    pub fn init(allocator: Allocator, address: []const u8, port: u16) !*Server {
        const server = try allocator.create(Server);
        errdefer allocator.destroy(server);

        const addr = try net.Address.parseIp4(address, port);
        server.* = .{
            .listener = try addr.listen(.{ .reuse_address = true }),
            .allocator = allocator,
            .running = std.atomic.Value(bool).init(false),
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

        // Perform handshake
        try conn.acceptHandshake();

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
