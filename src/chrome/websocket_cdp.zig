/// WebSocket client implementation for Chrome DevTools Protocol.
///
/// Low-level WebSocket protocol handling including:
/// - HTTP-to-WebSocket upgrade handshake with Sec-WebSocket-Key
/// - Frame parsing and serialization (text, binary, ping/pong, close)
/// - Message masking for client-to-server frames
/// - Request/response correlation via CDP message IDs
/// - Automatic ping/pong handling for connection keep-alive
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

// Response queue entry for request/response pattern
const ResponseQueueEntry = struct {
    id: u32,
    payload: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ResponseQueueEntry) void {
        self.allocator.free(self.payload);
    }
};

// Screencast frame structure with metadata
pub const ScreencastFrame = struct {
    data: []u8,  // base64 PNG data
    session_id: u32,
    device_width: u32,  // Actual frame width from CDP metadata
    device_height: u32, // Actual frame height from CDP metadata
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ScreencastFrame) void {
        self.allocator.free(self.data);
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

    // Threading infrastructure
    reader_thread: ?std.Thread,
    running: std.atomic.Value(bool),

    // Response queue for request/response pattern
    response_queue: std.ArrayList(ResponseQueueEntry),
    response_mutex: std.Thread.Mutex,

    // Frame buffer for screencast frames
    current_frame: ?ScreencastFrame,
    frame_mutex: std.Thread.Mutex,
    frame_count: std.atomic.Value(u32),  // Debug: count received frames

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
            .reader_thread = null,
            .running = std.atomic.Value(bool).init(false),
            .response_queue = try std.ArrayList(ResponseQueueEntry).initCapacity(allocator, 0),
            .response_mutex = .{},
            .current_frame = null,
            .frame_mutex = .{},
            .frame_count = std.atomic.Value(u32).init(0),
        };

        // Perform WebSocket handshake
        try client.performHandshake(parsed.host, parsed.path);

        return client;
    }

    pub fn deinit(self: *WebSocketCdpClient) void {
        // Stop reader thread if running
        self.stopReaderThread();

        // Free current frame if exists
        if (self.current_frame) |*frame| {
            frame.deinit();
        }

        // Free response queue
        for (self.response_queue.items) |*entry| {
            entry.deinit();
        }
        self.response_queue.deinit(self.allocator);

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

        // If reader thread is running, poll response queue
        // Otherwise, fall back to blocking recv (backward compatibility)
        if (self.reader_thread != null) {
            // Poll response queue with timeout
            const timeout_ns = 5 * std.time.ns_per_s;
            const start_time = std.time.nanoTimestamp();

            while (true) {
                // Check timeout
                if (std.time.nanoTimestamp() - start_time > timeout_ns) {
                    return error.TimeoutWaitingForResponse;
                }

                // Try to find response in queue
                self.response_mutex.lock();
                defer self.response_mutex.unlock();

                var i: usize = 0;
                while (i < self.response_queue.items.len) : (i += 1) {
                    const entry = self.response_queue.items[i];
                    if (entry.id == id) {
                        const response = entry.payload;
                        _ = self.response_queue.swapRemove(i);

                        // Check for error in response
                        if (std.mem.indexOf(u8, response, "\"error\":")) |_| {
                            self.allocator.free(response);
                            return WebSocketError.ProtocolError;
                        }

                        return response;
                    }
                }

                // Sleep briefly before retry
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
        } else {
            // Fallback: blocking recv (original behavior)
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
    }

    /// Start background reader thread for event-driven operation
    pub fn startReaderThread(self: *WebSocketCdpClient) !void {
        if (self.reader_thread != null) return; // Already running

        self.running.store(true, .release);
        self.reader_thread = try std.Thread.spawn(.{}, readerThreadMain, .{self});
    }

    /// Stop background reader thread
    pub fn stopReaderThread(self: *WebSocketCdpClient) void {
        if (self.reader_thread) |thread| {
            self.running.store(false, .release);
            thread.join();
            self.reader_thread = null;
        }
    }

    /// Get latest screencast frame (non-blocking)
    /// Consumes the frame - subsequent calls return null until new frame arrives
    pub fn getLatestFrame(self: *WebSocketCdpClient) ?ScreencastFrame {
        self.frame_mutex.lock();
        defer self.frame_mutex.unlock();

        if (self.current_frame) |frame| {
            // Take ownership of the frame (no copy needed)
            const result = frame;
            self.current_frame = null;
            return result;
        }
        return null;
    }

    /// Get count of frames received (for debugging)
    pub fn getFrameCount(self: *WebSocketCdpClient) u32 {
        return self.frame_count.load(.monotonic);
    }

    /// Background thread main function - continuously reads WebSocket frames
    fn readerThreadMain(self: *WebSocketCdpClient) void {
        while (self.running.load(.acquire)) {
            var frame = self.recvFrame() catch |err| {
                if (err == error.ConnectionClosed) break;
                continue;
            };
            defer frame.deinit();

            // Route message based on type
            if (std.mem.indexOf(u8, frame.payload, "\"method\":")) |_| {
                // EVENT (unsolicited message from Chrome)
                self.handleEvent(frame.payload) catch {};
            } else if (std.mem.indexOf(u8, frame.payload, "\"id\":")) |_| {
                // RESPONSE (reply to our command)
                self.handleResponse(frame.payload) catch {};
            }
        }
    }

    /// Handle incoming CDP event
    fn handleEvent(self: *WebSocketCdpClient, payload: []const u8) !void {
        // Extract method name
        const method_start = std.mem.indexOf(u8, payload, "\"method\":\"") orelse return;
        const method_value_start = method_start + "\"method\":\"".len;
        const method_end = std.mem.indexOfPos(u8, payload, method_value_start, "\"") orelse return;
        const method = payload[method_value_start..method_end];

        // Special handling for screencast frames
        if (std.mem.eql(u8, method, "Page.screencastFrame")) {
            try self.handleScreencastFrame(payload);
            return;
        }

        // Future: Add generic event callback here
    }

    /// Handle screencast frame event
    fn handleScreencastFrame(self: *WebSocketCdpClient, payload: []const u8) !void {
        // Parse sessionId
        const session_id = try self.extractSessionId(payload);

        // Parse base64 data
        const base64_data = try self.extractScreencastData(payload);

        // Parse metadata dimensions
        const device_width = self.extractMetadataInt(payload, "deviceWidth") catch 0;
        const device_height = self.extractMetadataInt(payload, "deviceHeight") catch 0;

        // Create new frame with metadata
        const new_frame = ScreencastFrame{
            .data = try self.allocator.dupe(u8, base64_data),
            .session_id = session_id,
            .device_width = device_width,
            .device_height = device_height,
            .allocator = self.allocator,
        };

        // Atomic swap into current_frame
        self.frame_mutex.lock();
        defer self.frame_mutex.unlock();

        if (self.current_frame) |*old_frame| {
            old_frame.deinit();  // Free old frame
        }
        self.current_frame = new_frame;
        _ = self.frame_count.fetchAdd(1, .monotonic);  // Increment frame counter

        // Send acknowledgment (fire-and-forget)
        self.acknowledgeFrame(session_id) catch {};
    }

    /// Extract integer value from metadata object
    fn extractMetadataInt(self: *WebSocketCdpClient, payload: []const u8, key: []const u8) !u32 {
        _ = self;
        // Find "metadata":{...} section, then find key within it
        const metadata_start = std.mem.indexOf(u8, payload, "\"metadata\":{") orelse return error.NotFound;
        const search_start = metadata_start + "\"metadata\":{".len;

        // Find key within metadata
        var buf: [64]u8 = undefined;
        const search_key = std.fmt.bufPrint(&buf, "\"{s}\":", .{key}) catch return error.NotFound;
        const key_start = std.mem.indexOfPos(u8, payload, search_start, search_key) orelse return error.NotFound;
        const value_start = key_start + search_key.len;

        // Parse integer value
        var end = value_start;
        while (end < payload.len and (payload[end] >= '0' and payload[end] <= '9')) : (end += 1) {}
        if (end == value_start) return error.NotFound;

        return std.fmt.parseInt(u32, payload[value_start..end], 10) catch error.NotFound;
    }

    /// Handle command response
    fn handleResponse(self: *WebSocketCdpClient, payload: []const u8) !void {
        // Extract ID from payload
        const id = try self.extractMessageId(payload);

        // Add to response queue
        self.response_mutex.lock();
        defer self.response_mutex.unlock();

        try self.response_queue.append(self.allocator, .{
            .id = id,
            .payload = try self.allocator.dupe(u8, payload),
            .allocator = self.allocator,
        });
    }

    /// Extract message ID from JSON payload
    fn extractMessageId(_: *WebSocketCdpClient, payload: []const u8) !u32 {
        const id_pos = std.mem.indexOf(u8, payload, "\"id\":") orelse return error.InvalidFormat;
        const id_value_start = id_pos + "\"id\":".len;

        // Find end of number
        var id_value_end = id_value_start;
        while (id_value_end < payload.len) : (id_value_end += 1) {
            const c = payload[id_value_end];
            if (c < '0' or c > '9') break;
        }

        const id_str = payload[id_value_start..id_value_end];
        return try std.fmt.parseInt(u32, id_str, 10);
    }

    /// Extract sessionId from screencast frame event
    fn extractSessionId(_: *WebSocketCdpClient, payload: []const u8) !u32 {
        const session_pos = std.mem.indexOf(u8, payload, "\"sessionId\":") orelse return error.InvalidFormat;
        const session_value_start = session_pos + "\"sessionId\":".len;

        // Find end of number
        var session_value_end = session_value_start;
        while (session_value_end < payload.len) : (session_value_end += 1) {
            const c = payload[session_value_end];
            if (c < '0' or c > '9') break;
        }

        const session_str = payload[session_value_start..session_value_end];
        return try std.fmt.parseInt(u32, session_str, 10);
    }

    /// Extract base64 PNG data from screencast frame event
    fn extractScreencastData(_: *WebSocketCdpClient, payload: []const u8) ![]const u8 {
        const data_pos = std.mem.indexOf(u8, payload, "\"data\":\"") orelse return error.InvalidFormat;
        const data_value_start = data_pos + "\"data\":\"".len;
        const data_value_end = std.mem.indexOfPos(u8, payload, data_value_start, "\"") orelse return error.InvalidFormat;

        return payload[data_value_start..data_value_end];
    }

    /// Send frame acknowledgment
    fn acknowledgeFrame(self: *WebSocketCdpClient, session_id: u32) !void {
        const params = try std.fmt.allocPrint(
            self.allocator,
            "{{\"sessionId\":{d}}}",
            .{session_id},
        );
        defer self.allocator.free(params);

        // Fire-and-forget acknowledgment (don't wait for response)
        const id = self.next_id.fetchAdd(1, .monotonic);
        const command = try std.fmt.allocPrint(
            self.allocator,
            "{{\"id\":{d},\"method\":\"Page.screencastFrameAck\",\"params\":{s}}}",
            .{ id, params },
        );
        defer self.allocator.free(command);

        try self.sendFrame(0x1, command);
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
