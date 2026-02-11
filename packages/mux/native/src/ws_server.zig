//! WebSocket server implementation with zstd compression support.
//!
//! Implements RFC 6455 WebSocket protocol with extensions:
//! - Binary and text message framing
//! - Per-connection zstd compression (app-level, not permessage-deflate)
//! - SIMD-accelerated XOR masking for frame decoding
//! - Configurable read/write timeouts for connection health
//!
//! Used for three separate WebSocket endpoints:
//! - Panel streams: H.264 video frames to browser
//! - Control channel: Terminal input, resize, panel management
//! - File transfer: Compressed file upload/download with hashing
//!
const std = @import("std");
const builtin = @import("builtin");
const net = std.net;
const posix = std.posix;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;

const zstd = @import("zstd.zig");
const simd_mask = @import("simd_mask");

/// Callback invoked when a new WebSocket connection is established.
pub const OnConnectFn = *const fn (*Connection) void;

/// Callback invoked when a message is received.
/// Parameters: connection, payload data, is_binary flag.
pub const OnMessageFn = *const fn (*Connection, []u8, bool) void;

/// Callback invoked when a WebSocket connection is closed.
pub const OnDisconnectFn = *const fn (*Connection) void;

/// WebSocket-specific errors.
pub const WsError = error{
    /// Connection was closed before handshake completed.
    ConnectionClosed,
    /// Missing or invalid Sec-WebSocket-Key header.
    InvalidHandshake,
    /// Payload exceeds maximum allowed size.
    PayloadTooLarge,
    /// zstd decompression failed.
    DecompressionFailed,
};

/// Maximum WebSocket payload size (16MB).
/// Prevents memory exhaustion from malicious or malformed frames.
const max_payload_size = 16 * 1024 * 1024;

/// Maximum size for decompressed messages (16MB).
/// Prevents zip bomb attacks via compressed payloads.
const max_decompressed_size = 16 * 1024 * 1024;

/// Buffer size for HTTP header parsing.
const header_buffer_size = 4096;

/// Socket write timeout in milliseconds.
/// Prevents blocking on slow/unresponsive clients.
const write_timeout_ms = 1000;

/// Configure socket for low-latency interactive use.
/// Disables Nagle's algorithm and enables keepalive for long-lived connections.
fn setSocketOptions(fd: posix.socket_t) void {
    // TCP_NODELAY: disable Nagle's algorithm — send small packets immediately
    // Critical for keyboard input latency (otherwise 40-200ms delay)
    posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};
    // SO_KEEPALIVE: detect dead connections through NAT/firewalls
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.KEEPALIVE, &std.mem.toBytes(@as(c_int, 1))) catch {};
}

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



// WebSocket Protocol


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


// WebSocket Connection


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
    // Serializes cross-thread writes (sendBinary) with deinit to prevent
    // use-after-free when broadcast threads access a connection being torn down.
    write_mutex: Thread.Mutex = .{},

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
            .write_mutex = .{},
        };
    }

    pub fn deinit(self: *Connection) void {
        // Lock write_mutex to prevent broadcast threads from using the
        // compressor or stream while we tear them down.
        self.write_mutex.lock();
        self.is_open = false;
        if (self.compressor) |*comp| {
            comp.deinit();
            self.compressor = null;
        }
        if (self.decompressor) |*decomp| {
            decomp.deinit();
            self.decompressor = null;
        }
        self.write_mutex.unlock();
        // Close stream and free URI after unlocking (no longer accessed by writers)
        if (self.request_uri) |uri| {
            self.allocator.free(uri);
            self.request_uri = null;
        }
        self.stream.close();
    }

    /// Perform WebSocket handshake (server side).
    /// Set enable_zstd=false for connections that carry pre-compressed data (like video frames).
    pub fn acceptHandshake(self: *Connection) !void {
        return self.acceptHandshakeWithOptions(true);
    }

    pub fn acceptHandshakeNoDeflate(self: *Connection) !void {
        return self.acceptHandshakeWithOptions(false);
    }

    fn acceptHandshakeWithOptions(self: *Connection, enable_zstd: bool) !void {
        var buf: [header_buffer_size]u8 = undefined;
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

        // Send handshake response
        const response = "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: ";
        _ = try self.stream.write(response);
        _ = try self.stream.write(&accept_key);

        // Always enable zstd on non-H264 channels (control, file).
        // H264 channels use initNoDeflate which sets enable_zstd=false.
        if (enable_zstd) {
            self.zstd_enabled = true;
            self.compressor = zstd.Compressor.init(self.allocator, 3) catch null;
            self.decompressor = zstd.Decompressor.init(self.allocator) catch null;
        }

        _ = try self.stream.write("\r\n\r\n");
    }

    /// Accept handshake with pre-read request (for HTTP server upgrade).
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

        // Send handshake response
        const response = "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: ";
        _ = try self.stream.write(response);
        _ = try self.stream.write(&accept_key);

        // Always enable zstd on non-H264 channels (control, file).
        // H264 channels use initNoDeflate which sets enable_zstd=false.
        if (enable_zstd) {
            self.zstd_enabled = true;
            self.compressor = zstd.Compressor.init(self.allocator, 3) catch null;
            self.decompressor = zstd.Decompressor.init(self.allocator) catch null;
        }

        _ = try self.stream.write("\r\n\r\n");
    }

    /// Read a WebSocket frame.
    /// App-level zstd: first byte of binary payload is compression flag (0x01 = zstd compressed).
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
        if (payload_len > max_payload_size) return error.PayloadTooLarge;
        var payload = try self.allocator.alloc(u8, @intCast(payload_len));
        errdefer self.allocator.free(payload);

        var total_read: usize = 0;
        while (total_read < payload.len) {
            const read = self.stream.read(payload[total_read..]) catch return error.BrokenPipe;
            if (read == 0) return error.BrokenPipe; // Connection closed mid-frame
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
                    const max_decompressed = max_decompressed_size;

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

    /// Write a WebSocket frame with optional zstd compression.
    /// For binary frames with zstd enabled: [compression_flag:u8][data...].
    /// compression_flag: 0x00 = uncompressed, 0x01 = zstd compressed.
    pub fn writeFrame(self: *Connection, opcode: Opcode, payload: []const u8) !void {
        if (opcode == .binary and self.zstd_enabled) {
            // Always try compression — batching makes zstd efficient at any size
            if (self.compressor) |*comp| {
                if (comp.compress(payload)) |compressed| {
                    defer self.allocator.free(compressed);
                    if (compressed.len + 1 < payload.len) {
                        const flag = [_]u8{0x01};
                        return self.writeFrameRawParts(.binary, &flag, compressed);
                    }
                } else |_| {}
            }
            // Compression didn't shrink — send uncompressed with flag
            return self.sendUncompressedWithFlag(payload);
        }

        try self.writeFrameRaw(opcode, payload, false);
    }

    /// Helper: send binary data with uncompressed flag prefix (zero-alloc via writev).
    fn sendUncompressedWithFlag(self: *Connection, payload: []const u8) !void {
        const flag = [_]u8{0x00};
        try self.writeFrameRawParts(.binary, &flag, payload);
    }

    /// Write raw WebSocket frame without compression processing.
    /// Uses writev to send header+payload in a single syscall.
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

        // Empty payload (e.g. close frame): single write, no writev needed
        if (payload.len == 0) {
            _ = self.stream.write(header[0..header_len]) catch return error.BrokenPipe;
            return;
        }

        var iovecs = [_]posix.iovec_const{
            .{ .base = &header, .len = header_len },
            .{ .base = payload.ptr, .len = payload.len },
        };
        const original_total = header_len + payload.len;
        var total = original_total;
        while (total > 0) {
            const written = posix.writev(self.stream.handle, &iovecs) catch |err| switch (err) {
                error.WouldBlock => {
                    if (total == original_total) return error.WouldBlock; // Nothing written yet — safe to drop
                    // Partial frame in TCP buffer — close to prevent protocol corruption
                    self.is_open = false;
                    return error.BrokenPipe;
                },
                else => return error.BrokenPipe,
            };
            if (written == 0) return error.BrokenPipe;
            total -= written;
            // Advance iovecs past written bytes
            var remaining = written;
            for (&iovecs) |*iov| {
                if (remaining == 0) break;
                if (remaining >= iov.len) {
                    remaining -= iov.len;
                    iov.base = iov.base + iov.len;
                    iov.len = 0;
                } else {
                    iov.base = iov.base + remaining;
                    iov.len -= remaining;
                    remaining = 0;
                }
            }
        }
    }

    /// Write WebSocket frame with a prefix + payload (3 iovecs, zero-alloc).
    /// Used for compression flag byte + data without concatenation.
    pub fn writeFrameRawParts(self: *Connection, opcode: Opcode, prefix: []const u8, payload: []const u8) !void {
        var header: [10]u8 = undefined;
        var header_len: usize = 2;
        const total_payload = prefix.len + payload.len;

        header[0] = 0x80 | @as(u8, @intFromEnum(opcode));

        if (total_payload < 126) {
            header[1] = @intCast(total_payload);
        } else if (total_payload < 65536) {
            header[1] = 126;
            std.mem.writeInt(u16, header[2..4], @intCast(total_payload), .big);
            header_len = 4;
        } else {
            header[1] = 127;
            std.mem.writeInt(u64, header[2..10], total_payload, .big);
            header_len = 10;
        }

        var iovecs = [_]posix.iovec_const{
            .{ .base = &header, .len = header_len },
            .{ .base = prefix.ptr, .len = prefix.len },
            .{ .base = payload.ptr, .len = payload.len },
        };
        const original_total = header_len + total_payload;
        var total = original_total;
        while (total > 0) {
            const written = posix.writev(self.stream.handle, &iovecs) catch |err| switch (err) {
                error.WouldBlock => {
                    if (total == original_total) return error.WouldBlock;
                    self.is_open = false;
                    return error.BrokenPipe;
                },
                else => return error.BrokenPipe,
            };
            if (written == 0) return error.BrokenPipe;
            total -= written;
            var remaining = written;
            for (&iovecs) |*iov| {
                if (remaining == 0) break;
                if (remaining >= iov.len) {
                    remaining -= iov.len;
                    iov.base = iov.base + iov.len;
                    iov.len = 0;
                } else {
                    iov.base = iov.base + remaining;
                    iov.len -= remaining;
                    remaining = 0;
                }
            }
        }
    }

    /// Send binary data (thread-safe — may be called from broadcast threads).
    pub fn sendBinary(self: *Connection, data: []const u8) !void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        if (!self.is_open) return error.ConnectionClosed;
        try self.writeFrame(.binary, data);
    }

    /// Send binary data with prefix + payload (thread-safe, zero-alloc via writev).
    /// Used for sending [prefix][payload] without allocating a concatenated buffer.
    pub fn sendBinaryParts(self: *Connection, prefix: []const u8, payload: []const u8) !void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        if (!self.is_open) return error.ConnectionClosed;
        try self.writeFrameRawParts(.binary, prefix, payload);
    }

    /// Send text data (thread-safe — may be called from broadcast threads).
    pub fn sendText(self: *Connection, data: []const u8) !void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        if (!self.is_open) return error.ConnectionClosed;
        try self.writeFrame(.text, data);
    }

    /// Send close frame.
    pub fn sendClose(self: *Connection) !void {
        if (!self.is_open) return; // Already closed
        try self.writeFrame(.close, &[_]u8{});
        self.is_open = false;
    }

    /// Send pong in response to ping.
    pub fn sendPong(self: *Connection, data: []const u8) !void {
        try self.writeFrame(.pong, data);
    }
};


// WebSocket Server


pub const Server = struct {
    listener: net.Server,
    allocator: Allocator,
    running: std.atomic.Value(bool),
    stopped: std.atomic.Value(bool),
    active_connections: std.atomic.Value(u32), // Track active connection threads
    shutdown_fd: posix.fd_t, // Read end: polled by connection threads for shutdown signal
    shutdown_write_fd: posix.fd_t, // Write end: signaled by stop() to wake all threads
    enable_zstd: bool,
    send_timeout_ms: u32, // Per-connection write timeout (0 = non-blocking for droppable frames)
    /// Called when a new WebSocket connection is established.
    on_connect: ?OnConnectFn,
    /// Called when a message is received. Args: connection, payload, is_binary.
    on_message: ?OnMessageFn,
    /// Called when a connection is closed.
    on_disconnect: ?OnDisconnectFn,

    pub fn init(allocator: Allocator, address: []const u8, port: u16) !*Server {
        return initWithOptions(allocator, address, port, true);
    }

    pub fn initNoCompression(allocator: Allocator, address: []const u8, port: u16) !*Server {
        return initWithOptions(allocator, address, port, false);
    }

    fn initWithOptions(allocator: Allocator, address: []const u8, port: u16, enable_zstd: bool) !*Server {
        const server = try allocator.create(Server);
        errdefer allocator.destroy(server);

        var shutdown_fd: posix.fd_t = undefined;
        var shutdown_write_fd: posix.fd_t = undefined;
        if (comptime builtin.os.tag == .linux) {
            const efd = try posix.eventfd(0, std.os.linux.EFD.NONBLOCK | std.os.linux.EFD.CLOEXEC);
            shutdown_fd = efd;
            shutdown_write_fd = efd;
        } else {
            const fds = try posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
            shutdown_fd = fds[0];
            shutdown_write_fd = fds[1];
        }

        const addr = try net.Address.parseIp4(address, port);
        server.* = .{
            .listener = try addr.listen(.{ .reuse_address = true }),
            .allocator = allocator,
            .running = std.atomic.Value(bool).init(false),
            .stopped = std.atomic.Value(bool).init(false),
            .active_connections = std.atomic.Value(u32).init(0),
            .shutdown_fd = shutdown_fd,
            .shutdown_write_fd = shutdown_write_fd,
            .enable_zstd = enable_zstd,
            .send_timeout_ms = write_timeout_ms,
            .on_connect = null,
            .on_message = null,
            .on_disconnect = null,
        };

        return server;
    }

    pub fn deinit(self: *Server) void {
        self.stop(); // Also closes listener and signals shutdown fd
        // Wait for active connection threads to finish (3s timeout gives
        // transfer goroutines time to notice cancellation and clean up)
        var wait_count: u32 = 0;
        while (self.active_connections.load(.acquire) > 0) {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            wait_count += 1;
            if (wait_count > 300) break;
        }
        // Close shutdown fds
        posix.close(self.shutdown_fd);
        if (self.shutdown_write_fd != self.shutdown_fd) {
            posix.close(self.shutdown_write_fd);
        }
        self.allocator.destroy(self);
    }

    /// Set callbacks for connection lifecycle events.
    pub fn setCallbacks(
        self: *Server,
        on_connect: ?OnConnectFn,
        on_message: ?OnMessageFn,
        on_disconnect: ?OnDisconnectFn,
    ) void {
        self.on_connect = on_connect;
        self.on_message = on_message;
        self.on_disconnect = on_disconnect;
    }

    pub fn stop(self: *Server) void {
        if (self.stopped.swap(true, .acq_rel)) return;
        self.running.store(false, .release);
        // Signal shutdown fd to wake all connection threads blocked in poll()
        // This is async-signal-safe (just a write syscall)
        if (comptime builtin.os.tag == .linux) {
            const val: u64 = 1;
            _ = posix.write(self.shutdown_write_fd, std.mem.asBytes(&val)) catch {};
        } else {
            _ = posix.write(self.shutdown_write_fd, &[_]u8{1}) catch {};
        }
        // shutdown() interrupts blocked accept() in another thread reliably on Linux
        // (close() alone is NOT guaranteed to unblock accept on Linux)
        posix.shutdown(self.listener.stream.handle, .both) catch {};
        self.listener.deinit();
    }

    // Accept one connection and handle it (blocking)
    pub fn acceptOne(self: *Server) !*Connection {
        const stream = try self.listener.accept();

        const conn = try self.allocator.create(Connection);
        conn.* = Connection.init(stream.stream, self.allocator);

        // Configure socket for low-latency interactive use
        setSocketOptions(stream.stream.handle);
        setReadTimeout(stream.stream.handle, 100); // 100ms wakeup for shutdown check
        setWriteTimeout(stream.stream.handle, self.send_timeout_ms);

        // Perform handshake (with or without zstd based on server config)
        try conn.acceptHandshakeWithOptions(self.enable_zstd);

        if (self.on_connect) |cb| cb(conn);

        return conn;
    }

    /// Wait for data on socket or shutdown signal. Returns true if socket has data.
    fn waitForData(self: *Server, socket_fd: posix.socket_t) bool {
        var fds = [_]posix.pollfd{
            .{ .fd = socket_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = self.shutdown_fd, .events = posix.POLL.IN, .revents = 0 },
        };
        const ready = posix.poll(&fds, 1000) catch return false; // 1s fallback timeout
        if (ready == 0) return false; // timeout
        if (fds[1].revents & posix.POLL.IN != 0) return false; // shutdown signaled
        return (fds[0].revents & posix.POLL.IN != 0);
    }

    // Handle connection messages in a loop
    pub fn handleConnection(self: *Server, conn: *Connection) void {
        while (conn.is_open and self.running.load(.acquire)) {
            // Wait for data or shutdown — replaces blocking read with SO_RCVTIMEO
            if (!self.waitForData(conn.stream.handle)) continue;

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

    /// Run server loop. Blocks until stop() is called (which closes listener to unblock accept).
    pub fn run(self: *Server) !void {
        self.running.store(true, .release);

        while (self.running.load(.acquire)) {
            // Blocking accept — stop() closes listener to unblock
            const conn = self.acceptOne() catch break;

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
        // Reject upgrades during shutdown to avoid use-after-free
        if (!self.running.load(.acquire)) return;

        const conn = self.allocator.create(Connection) catch return;
        conn.* = Connection.init(stream, self.allocator);

        // Configure socket for low-latency interactive use
        setSocketOptions(stream.handle);
        setReadTimeout(stream.handle, 100); // 100ms wakeup for shutdown check
        setWriteTimeout(stream.handle, self.send_timeout_ms);

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
