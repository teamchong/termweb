/// WebSocket client implementation for Chrome DevTools Protocol.
///
/// Low-level WebSocket protocol handling including:
/// - HTTP-to-WebSocket upgrade handshake with Sec-WebSocket-Key
/// - Frame parsing and serialization (text, binary, ping/pong, close)
/// - Message masking for client-to-server frames
/// - Request/response correlation via CDP message IDs
/// - Automatic ping/pong handling for connection keep-alive
const std = @import("std");
const simd = @import("../simd/dispatch.zig");
const FramePool = @import("../simd/frame_pool.zig").FramePool;

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

const FrameSlot = @import("../simd/frame_pool.zig").FrameSlot;

// Screencast frame structure with zero-copy reference to pool slot
pub const ScreencastFrame = struct {
    data: []const u8,   // base64 PNG data (zero-copy reference to pool)
    slot: *FrameSlot,   // Reference to pool slot (for release)
    session_id: u32,
    device_width: u32,  // Actual frame width from CDP metadata
    device_height: u32, // Actual frame height from CDP metadata
    generation: u64,    // Pool generation for validity checking

    /// Release the pool slot reference
    pub fn deinit(self: *ScreencastFrame) void {
        self.slot.release();
    }
};

const ParsedUrl = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
};

fn logToFile(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, fmt, args) catch return;

    const file = std.fs.cwd().openFile("cdp_debug.log", .{ .mode = .read_write }) catch |err| blk: {
        if (err == error.FileNotFound) {
             break :blk std.fs.cwd().createFile("cdp_debug.log", .{ .read = true }) catch return;
        }
        return;
    };
    defer file.close();
    file.seekFromEnd(0) catch return;
    file.writeAll(slice) catch return;
}

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

    // Zero-copy frame pool for screencast frames (avoids per-frame allocations)
    frame_pool: *FramePool,
    frame_count: std.atomic.Value(u32),  // Debug: count received frames

    // Write mutex to prevent concurrent WebSocket writes (reader acks vs main thread commands)
    write_mutex: std.Thread.Mutex,

    pub fn connect(allocator: std.mem.Allocator, ws_url: []const u8) !*WebSocketCdpClient {
        const parsed = try parseWsUrl(allocator, ws_url);
        defer allocator.free(parsed.host);
        defer allocator.free(parsed.path);

        // TCP connect
        const stream = try std.net.tcpConnectToHost(allocator, parsed.host, parsed.port);

        // Initialize frame pool (triple-buffered, 512KB slots)
        const frame_pool = try FramePool.init(allocator);

        const client = try allocator.create(WebSocketCdpClient);
        client.* = .{
            .allocator = allocator,
            .stream = stream,
            .next_id = std.atomic.Value(u32).init(1),
            .reader_thread = null,
            .running = std.atomic.Value(bool).init(false),
            .response_queue = try std.ArrayList(ResponseQueueEntry).initCapacity(allocator, 0),
            .response_mutex = .{},
            .frame_pool = frame_pool,
            .frame_count = std.atomic.Value(u32).init(0),
            .write_mutex = .{},
        };

        // Perform WebSocket handshake
        try client.performHandshake(parsed.host, parsed.path);

        return client;
    }

    pub fn deinit(self: *WebSocketCdpClient) void {
        // Signal thread to stop and detach it
        self.stopReaderThread();

        // Close stream to unblock any pending reads
        self.stream.close();

        // Free frame pool
        self.frame_pool.deinit();

        // Free response queue
        for (self.response_queue.items) |*entry| {
            entry.deinit();
        }
        self.response_queue.deinit(self.allocator);

        self.allocator.destroy(self);
    }

    /// Send command without waiting for response (fire-and-forget)
    /// Use for actions like scroll, click, mouse events
    /// Silently ignores connection errors (broken pipe, etc.) - safe during shutdown
    pub fn sendCommandAsync(self: *WebSocketCdpClient, method: []const u8, params: ?[]const u8) void {
        const id = self.next_id.fetchAdd(1, .monotonic);

        const command = if (params) |p|
            std.fmt.allocPrint(
                self.allocator,
                "{{\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}",
                .{ id, method, p },
            ) catch return
        else
            std.fmt.allocPrint(
                self.allocator,
                "{{\"id\":{d},\"method\":\"{s}\"}}",
                .{ id, method },
            ) catch return;
        defer self.allocator.free(command);

        // Use priority send for input commands to minimize latency
        // Fire-and-forget: ignore errors (connection may be closed during shutdown)
        self.sendFramePriority(0x1, command) catch {};
    }

    pub fn sendCommand(self: *WebSocketCdpClient, method: []const u8, params: ?[]const u8) ![]u8 {
        // Get unique ID
        const id = self.next_id.fetchAdd(1, .monotonic);

        logToFile("[WS] sendCommand id={} method={s}\n", .{ id, method });

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
                // Check if reader thread died (connection broken)
                if (!self.running.load(.acquire)) {
                    return error.ConnectionClosed;
                }

                // Check timeout
                if (std.time.nanoTimestamp() - start_time > timeout_ns) {
                    logToFile("[WS] TIMEOUT waiting for response id={}\n", .{id});
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

                        logToFile("[WS] got response for id={} len={}\n", .{ id, response.len });

                        // Check for error in response
                        if (std.mem.indexOf(u8, response, "\"error\":")) |_| {
                            logToFile("[WS] response has error\n", .{});
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
            // Just detach - thread will exit when socket closes or process ends
            thread.detach();
            self.reader_thread = null;
        }
    }

    /// Get latest screencast frame (non-blocking, zero-copy with reference counting)
    /// Returns a zero-copy reference to pool data - MUST call deinit() when done
    pub fn getLatestFrame(self: *WebSocketCdpClient) ?ScreencastFrame {
        // Acquire slot with reference count (prevents overwrite during use)
        const slot = self.frame_pool.acquireLatestFrame() orelse return null;

        return ScreencastFrame{
            .data = slot.data(),
            .slot = slot,
            .session_id = slot.session_id,
            .device_width = slot.device_width,
            .device_height = slot.device_height,
            .generation = slot.generation,
        };
    }

    /// Get count of frames received (for debugging)
    pub fn getFrameCount(self: *WebSocketCdpClient) u32 {
        return self.frame_count.load(.monotonic);
    }

    /// Send WebSocket ping frame to keep connection alive
    pub fn sendPing(self: *WebSocketCdpClient) !void {
        try self.sendFrame(0x9, "keepalive"); // opcode 0x9 = ping
    }

    /// Background thread main function - continuously reads WebSocket frames
    fn readerThreadMain(self: *WebSocketCdpClient) void {
        logToFile("[WS] Reader thread started\n", .{});

        var last_activity = std.time.nanoTimestamp();
        const keepalive_interval_ns = 15 * std.time.ns_per_s; // Send ping every 15 seconds of inactivity

        while (self.running.load(.acquire)) {
            // Check if we need to send keepalive ping
            const now = std.time.nanoTimestamp();
            if (now - last_activity > keepalive_interval_ns) {
                self.sendPing() catch |err| {
                    logToFile("[WS] sendPing failed: {}\n", .{err});
                };
                last_activity = now;
            }

            var frame = self.recvFrame() catch |err| {
                // Only log non-spam errors
                if (err != error.WouldBlock) {
                    logToFile("[WS] recvFrame error: {}\n", .{err});
                }

                if (err == error.ConnectionClosed or
                    err == error.EndOfStream or
                    err == error.BrokenPipe or
                    err == error.ConnectionResetByPeer or
                    err == error.NotOpenForReading or
                    err == error.InvalidFrame) {
                    logToFile("[WS] connection broken, exiting reader thread\n", .{});
                    self.running.store(false, .release);
                    return;
                }

                // On timeout or other errors, check if we should stop
                if (!self.running.load(.acquire)) break;
                continue;
            };
            // Update last activity on successful frame receive
            last_activity = std.time.nanoTimestamp();
            defer frame.deinit();

            // Check if we should stop before processing
            if (!self.running.load(.acquire)) break;

            // Route message based on type
            if (std.mem.indexOf(u8, frame.payload, "\"method\":")) |_| {
                // EVENT (unsolicited message from Chrome)
                self.handleEvent(frame.payload) catch {};
            } else if (std.mem.indexOf(u8, frame.payload, "\"id\":")) |_| {
                // RESPONSE (reply to our command)
                // Log response processing
                // std.debug.print("[WS] Processing response\n", .{});
                self.handleResponse(frame.payload) catch {};
            }
        }
        // std.debug.print("[WS] Reader thread exiting\n", .{});
    }

    /// Handle incoming CDP event
    fn handleEvent(self: *WebSocketCdpClient, payload: []const u8) !void {
        // Extract method name
        const method_start = std.mem.indexOf(u8, payload, "\"method\":\"") orelse return;
        const method_value_start = method_start + "\"method\":\"".len;
        const method_end = std.mem.indexOfPos(u8, payload, method_value_start, "\"") orelse return;
        const method = payload[method_value_start..method_end];

        // Debug: log all received events
        {
            const log_file = std.fs.cwd().openFile("termweb_debug.log", .{ .mode = .write_only }) catch return;
            defer log_file.close();
            log_file.seekFromEnd(0) catch {};
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "[CDP EVENT] method={s}, payload_len={}\n", .{ method, payload.len }) catch return;
            log_file.writeAll(msg) catch {};
        }

        // Special handling for screencast frames
        if (std.mem.eql(u8, method, "Page.screencastFrame")) {
            try self.handleScreencastFrame(payload);
            return;
        }

        // Future: Add generic event callback here
    }

    /// Handle screencast frame event (zero-copy to pool)
    fn handleScreencastFrame(self: *WebSocketCdpClient, payload: []const u8) !void {
        // Parse sessionId
        const session_id = self.extractSessionId(payload) catch |err| {
            // Debug: log parse error
            const log_file = std.fs.cwd().openFile("termweb_debug.log", .{ .mode = .write_only }) catch return;
            defer log_file.close();
            log_file.seekFromEnd(0) catch {};
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "[CDP] extractSessionId failed: {}\n", .{err}) catch return;
            log_file.writeAll(msg) catch {};
            return err;
        };

        // Parse base64 data (zero-copy slice into payload)
        const base64_data = self.extractScreencastData(payload) catch |err| {
            const log_file = std.fs.cwd().openFile("termweb_debug.log", .{ .mode = .write_only }) catch return;
            defer log_file.close();
            log_file.seekFromEnd(0) catch {};
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "[CDP] extractScreencastData failed: {}\n", .{err}) catch return;
            log_file.writeAll(msg) catch {};
            return err;
        };

        // Parse metadata dimensions
        const device_width = self.extractMetadataInt(payload, "deviceWidth") catch 0;
        const device_height = self.extractMetadataInt(payload, "deviceHeight") catch 0;

        // Write to frame pool (single memcpy, reuses pre-allocated buffers)
        // Returns null if all slots are in use (backpressure - drop frame)
        if (try self.frame_pool.writeFrame(
            base64_data,
            session_id,
            device_width,
            device_height,
        )) |gen| {
            _ = self.frame_count.fetchAdd(1, .monotonic);
            // Debug: log successful frame write
            const log_file = std.fs.cwd().openFile("termweb_debug.log", .{ .mode = .write_only }) catch return;
            defer log_file.close();
            log_file.seekFromEnd(0) catch {};
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "[CDP] Frame written: session={}, gen={}, size={}, {}x{}\n", .{ session_id, gen, base64_data.len, device_width, device_height }) catch return;
            log_file.writeAll(msg) catch {};
        } else {
            // Debug: log dropped frame
            const log_file = std.fs.cwd().openFile("termweb_debug.log", .{ .mode = .write_only }) catch return;
            defer log_file.close();
            log_file.seekFromEnd(0) catch {};
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "[CDP] Frame DROPPED (all slots in use): session={}\n", .{session_id}) catch return;
            log_file.writeAll(msg) catch {};
        }
        // Always acknowledge to prevent Chrome from stalling
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

        self.response_mutex.lock();
        defer self.response_mutex.unlock();

        // Limit queue size to prevent memory growth from fire-and-forget commands
        // Drop oldest responses if queue is too large
        const MAX_QUEUE_SIZE = 50;
        while (self.response_queue.items.len >= MAX_QUEUE_SIZE) {
            var old = self.response_queue.swapRemove(0);
            old.deinit();
        }

        // Add to response queue
        try self.response_queue.append(self.allocator, .{
            .id = id,
            .payload = try self.allocator.dupe(u8, payload),
            .allocator = self.allocator,
        });
    }

    /// Extract message ID from JSON payload (SIMD-accelerated)
    fn extractMessageId(_: *WebSocketCdpClient, payload: []const u8) !u32 {
        // Use SIMD pattern search for large payloads
        const id_pos = simd.findPattern(payload, "\"id\":", 0) orelse return error.InvalidFormat;
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

    /// Extract sessionId from screencast frame event (SIMD-accelerated)
    fn extractSessionId(_: *WebSocketCdpClient, payload: []const u8) !u32 {
        const session_pos = simd.findPattern(payload, "\"sessionId\":", 0) orelse return error.InvalidFormat;
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

    /// Extract base64 PNG data from screencast frame event (SIMD-accelerated)
    fn extractScreencastData(_: *WebSocketCdpClient, payload: []const u8) ![]const u8 {
        // SIMD pattern search - big win for large payloads
        const data_pos = simd.findPattern(payload, "\"data\":\"", 0) orelse return error.InvalidFormat;
        const data_value_start = data_pos + "\"data\":\"".len;
        // Use SIMD to find closing quote
        const data_value_end = simd.findClosingQuote(payload, data_value_start) orelse return error.InvalidFormat;

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

    /// Send frame with priority - uses tryLock to avoid blocking on ack traffic
    /// Retries with exponential backoff if lock is contended
    fn sendFramePriority(self: *WebSocketCdpClient, opcode: u8, payload: []const u8) !void {
        var attempts: u32 = 0;
        while (attempts < 10) : (attempts += 1) {
            if (self.write_mutex.tryLock()) {
                defer self.write_mutex.unlock();
                return self.sendFrameUnlocked(opcode, payload);
            }
            // Brief spin before retry (exponential: 10us, 20us, 40us...)
            const shift: u6 = @intCast(@min(attempts, 4));
            std.Thread.sleep(@as(u64, @as(u64, 10) << shift) * std.time.ns_per_us);
        }
        // Fall back to blocking if all retries failed
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        return self.sendFrameUnlocked(opcode, payload);
    }

    fn sendFrame(self: *WebSocketCdpClient, opcode: u8, payload: []const u8) !void {
        // Mutex protects against concurrent writes from reader thread (acks) and main thread (commands)
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        return self.sendFrameUnlocked(opcode, payload);
    }

    fn sendFrameUnlocked(self: *WebSocketCdpClient, opcode: u8, payload: []const u8) !void {

        const header_len_max = 14;
        const required_len = payload.len + header_len_max;

        // Use stack buffer for small frames, allocate for large ones
        var stack_buf: [16384]u8 = undefined;
        var heap_buf: ?[]u8 = null;
        defer if (heap_buf) |b| self.allocator.free(b);

        var frame_buf: []u8 = undefined;

        if (required_len <= stack_buf.len) {
            frame_buf = stack_buf[0..];
        } else {
            heap_buf = try self.allocator.alloc(u8, required_len);
            frame_buf = heap_buf.?;
        }

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
        const bytes_read = self.stream.readAtLeast(payload, @intCast(payload_len)) catch |err| {
            self.allocator.free(payload);
            return err;
        };

        if (bytes_read != payload_len) {
            self.allocator.free(payload);
            return WebSocketError.InvalidFrame;
        }

        // Handle control frames
        switch (opcode) {
            0x9 => { // Ping - respond with pong, free payload, continue
                self.sendFrame(0xA, payload) catch {
                    // Ignore pong send errors, just free and continue
                };
                self.allocator.free(payload);
                return self.recvFrame();
            },
            0x8 => { // Close
                self.allocator.free(payload);
                return WebSocketError.ConnectionClosed;
            },
            0x1, 0x2 => { // Text or Binary - ownership transfers to Frame
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
