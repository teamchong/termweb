/// WebSocket client implementation for Chrome DevTools Protocol.
///
/// Low-level WebSocket protocol handling including:
/// - HTTP-to-WebSocket upgrade handshake with Sec-WebSocket-Key
/// - Frame parsing and serialization (text, binary, ping/pong, close)
/// - Message masking for client-to-server frames
/// - Request/response correlation via CDP message IDs
/// - Automatic ping/pong handling for connection keep-alive
/// - Screencast frame handling with zero-copy FramePool
const std = @import("std");
const simd = @import("../simd/dispatch.zig");
const FramePool = @import("../simd/frame_pool.zig").FramePool;
const FrameSlot = @import("../simd/frame_pool.zig").FrameSlot;

pub const WebSocketError = error{
    ConnectionFailed,
    HandshakeFailed,
    InvalidFrame,
    ConnectionClosed,
    ProtocolError,
    InvalidUrl,
    OutOfMemory,
};

/// Screencast frame structure with zero-copy reference to pool slot
pub const ScreencastFrame = struct {
    data: []const u8,
    slot: *FrameSlot,
    session_id: u32,
    device_width: u32,
    device_height: u32,
    generation: u64,

    /// Release the pool slot reference
    pub fn deinit(self: *ScreencastFrame) void {
        self.slot.release();
    }
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

// Event queue entry for CDP events (consoleAPICalled, dialogs, etc.)
const EventQueueEntry = struct {
    method: []u8,
    payload: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *EventQueueEntry) void {
        self.allocator.free(self.method);
        self.allocator.free(self.payload);
    }
};

const ParsedUrl = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
};

/// Check if debug logging is enabled (cached)
fn isDebugEnabled() bool {
    const State = struct {
        var checked: bool = false;
        var enabled: bool = false;
    };
    if (!State.checked) {
        State.enabled = std.posix.getenv("TERMWEB_DEBUG") != null;
        State.checked = true;
    }
    return State.enabled;
}

fn logToFile(comptime fmt: []const u8, args: anytype) void {
    if (!isDebugEnabled()) return;

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

    // Event queue for CDP events (consoleAPICalled, dialogs, file chooser)
    event_queue: std.ArrayList(EventQueueEntry),
    event_mutex: std.Thread.Mutex,

    // Write mutex to prevent concurrent WebSocket writes (reader acks vs main thread commands)
    write_mutex: std.Thread.Mutex,

    // Screencast frame pool for zero-copy frame handling
    frame_pool: ?*FramePool,
    frame_count: std.atomic.Value(u32),

    pub fn connect(allocator: std.mem.Allocator, ws_url: []const u8) !*WebSocketCdpClient {
        const parsed = try parseWsUrl(allocator, ws_url);
        defer allocator.free(parsed.host);
        defer allocator.free(parsed.path);

        // TCP connect
        const stream = try std.net.tcpConnectToHost(allocator, parsed.host, parsed.port);

        const client = try allocator.create(WebSocketCdpClient);
        client.* = .{
            .allocator = allocator,
            .stream = stream,
            .next_id = std.atomic.Value(u32).init(1),
            .reader_thread = null,
            .running = std.atomic.Value(bool).init(false),
            .response_queue = try std.ArrayList(ResponseQueueEntry).initCapacity(allocator, 0),
            .response_mutex = .{},
            .event_queue = try std.ArrayList(EventQueueEntry).initCapacity(allocator, 0),
            .event_mutex = .{},
            .write_mutex = .{},
            .frame_pool = null, // Initialized on demand when screencast starts
            .frame_count = std.atomic.Value(u32).init(0),
        };

        // Perform WebSocket handshake
        try client.performHandshake(parsed.host, parsed.path);

        return client;
    }

    pub fn deinit(self: *WebSocketCdpClient) void {
        // Signal thread to stop
        self.running.store(false, .release);

        // Close stream to unblock any pending reads
        self.stream.close();

        // Join thread (wait for it to exit) - MUST happen before freeing queues
        if (self.reader_thread) |thread| {
            thread.join();
            self.reader_thread = null;
        }

        // Free response queue - safe now, thread is joined
        for (self.response_queue.items) |*entry| {
            entry.deinit();
        }
        self.response_queue.deinit(self.allocator);

        // Free event queue
        for (self.event_queue.items) |*entry| {
            entry.deinit();
        }
        self.event_queue.deinit(self.allocator);

        // Free frame pool if allocated
        if (self.frame_pool) |pool| {
            pool.deinit();
        }

        self.allocator.destroy(self);
    }

    /// Send command without waiting for response (fire-and-forget)
    /// Use for actions like scroll, click, mouse events
    /// Silently ignores connection errors (broken pipe, etc.) - safe during shutdown
    pub fn sendCommandAsync(self: *WebSocketCdpClient, method: []const u8, params: ?[]const u8) void {
        const id = self.next_id.fetchAdd(1, .monotonic);

        // Use stack buffer for command JSON to avoid heap allocation
        var cmd_buf: [2048]u8 = undefined;
        const command = if (params) |p|
            std.fmt.bufPrint(
                &cmd_buf,
                "{{\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}",
                .{ id, method, p },
            ) catch return
        else
            std.fmt.bufPrint(
                &cmd_buf,
                "{{\"id\":{d},\"method\":\"{s}\"}}",
                .{ id, method },
            ) catch return;

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
            const timeout_ns = 15 * std.time.ns_per_s;
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

                // Try to find response in queue (explicit scope to release mutex before sleep)
                {
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
                }

                // Sleep briefly before retry (mutex released)
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

    /// Stop background reader thread (internal use - deinit handles stream closing)
    fn stopReaderThread(self: *WebSocketCdpClient) void {
        if (self.reader_thread) |thread| {
            self.running.store(false, .release);
            // Note: caller must close stream to unblock thread, then call join
            thread.join();
            self.reader_thread = null;
        }
    }

    /// Send WebSocket ping frame to keep connection alive
    pub fn sendPing(self: *WebSocketCdpClient) !void {
        try self.sendFrame(0x9, "keepalive"); // opcode 0x9 = ping
    }

    /// Background thread main function - continuously reads WebSocket frames
    fn readerThreadMain(self: *WebSocketCdpClient) void {
        logToFile("[WS] Reader thread started, running={}\n", .{self.running.load(.acquire)});

        var last_activity = std.time.nanoTimestamp();
        const keepalive_interval_ns = 15 * std.time.ns_per_s; // Send ping every 15 seconds of inactivity
        var frame_count: u32 = 0;

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
            frame_count += 1;
            defer frame.deinit();

            // Log frame receipt for debugging
            if (frame_count <= 20 or frame_count % 100 == 0) {
                logToFile("[WS] Frame #{} received, len={}\n", .{ frame_count, frame.payload.len });
            }

            // Check if we should stop before processing
            if (!self.running.load(.acquire)) break;

            // Route message based on type
            // Check for "id" first - responses have "id" but no "method"
            // Events have "method" (and may have "id" for session-based events)
            const has_id = std.mem.indexOf(u8, frame.payload, "\"id\":") != null;
            const has_method = std.mem.indexOf(u8, frame.payload, "\"method\":") != null;

            // Debug: log routing decision
            logToFile("[WS] Routing: has_id={} has_method={} payload={s}\n", .{ has_id, has_method, frame.payload[0..@min(100, frame.payload.len)] });

            if (has_id and !has_method) {
                // RESPONSE (reply to our command) - has id but no method
                self.handleResponse(frame.payload) catch |err| {
                    logToFile("[WS] handleResponse error: {}\n", .{err});
                };
            } else if (has_method) {
                // EVENT (unsolicited message from Chrome) - has method
                self.handleEvent(frame.payload) catch {};
            } else {
                logToFile("[WS] Unknown message type: {s}\n", .{frame.payload[0..@min(200, frame.payload.len)]});
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

        // Debug: Log all Browser.* and Page.screencast* events
        if (std.mem.startsWith(u8, method, "Browser.")) {
            logToFile("[WS] Browser event: {s}\n", .{method});
        }
        if (std.mem.startsWith(u8, method, "Page.screencast")) {
            logToFile("[WS] Screencast event: {s}\n", .{method});
        }
        if (std.mem.startsWith(u8, method, "Page.fileChooser")) {
            logToFile("[WS] FileChooser event: {s}\n", .{method});
        }

        // Handle screencast frames directly (high-bandwidth, not queued)
        if (std.mem.eql(u8, method, "Page.screencastFrame")) {
            logToFile("[WS] GOT SCREENCAST FRAME! len={}\n", .{payload.len});
            self.handleScreencastFrame(payload) catch |err| {
                logToFile("[WS] handleScreencastFrame error: {}\n", .{err});
            };
            return;
        }

        // Only queue important events for main thread
        const dominated_events = [_][]const u8{
            "Runtime.consoleAPICalled", // Polyfill communication
            "Page.javascriptDialogOpening", // JS dialogs
            "Page.fileChooserOpened", // File picker
            "Browser.downloadWillBegin", // Download started
            "Browser.downloadProgress", // Download progress/completion
            "Page.frameNavigated", // Navigation completed - update URL
            "Page.navigatedWithinDocument", // SPA navigation - update URL
            "Target.targetCreated", // New tab/popup - launch in new terminal
            "Target.targetInfoChanged", // Target URL updated - get URL for new tab
        };

        var dominated = false;
        for (dominated_events) |de| {
            if (std.mem.eql(u8, method, de)) {
                dominated = true;
                break;
            }
        }
        if (!dominated) return;

        // Queue event for main thread
        self.event_mutex.lock();
        defer self.event_mutex.unlock();

        if (!self.running.load(.acquire)) return;

        const MAX_EVENT_QUEUE = 100;
        if (self.event_queue.items.len >= MAX_EVENT_QUEUE) {
            var old = self.event_queue.orderedRemove(0);
            old.deinit();
        }

        const method_copy = self.allocator.dupe(u8, method) catch return;
        const payload_copy = self.allocator.dupe(u8, payload) catch {
            self.allocator.free(method_copy);
            return;
        };

        self.event_queue.append(self.allocator, .{
            .method = method_copy,
            .payload = payload_copy,
            .allocator = self.allocator,
        }) catch {
            self.allocator.free(method_copy);
            self.allocator.free(payload_copy);
            return;
        };

        logToFile("[WS handleEvent] QUEUED method={s} queue_size={d}\n", .{ method, self.event_queue.items.len });
    }

    /// Get next event from queue (non-blocking)
    /// Returns method and payload (caller owns both), or null if queue is empty
    pub fn nextEvent(self: *WebSocketCdpClient) ?struct { method: []u8, payload: []u8 } {
        self.event_mutex.lock();
        defer self.event_mutex.unlock();

        if (self.event_queue.items.len == 0) return null;

        const entry = self.event_queue.orderedRemove(0);
        return .{ .method = entry.method, .payload = entry.payload };
    }

    // ============ Screencast Frame Handling ============

    /// Initialize frame pool on demand (called when screencast starts)
    pub fn initFramePool(self: *WebSocketCdpClient) !void {
        if (self.frame_pool != null) return; // Already initialized
        self.frame_pool = try FramePool.init(self.allocator);
    }

    /// Handle Page.screencastFrame event
    fn handleScreencastFrame(self: *WebSocketCdpClient, payload: []const u8) !void {
        const pool = self.frame_pool orelse return; // No pool = not initialized

        const frame_sid = try self.extractFrameSessionId(payload);
        const data = try self.extractScreencastData(payload);
        const device_width = self.extractMetadataInt(payload, "deviceWidth") catch 0;
        const device_height = self.extractMetadataInt(payload, "deviceHeight") catch 0;

        if (try pool.writeFrame(data, frame_sid, device_width, device_height)) |_| {
            _ = self.frame_count.fetchAdd(1, .monotonic);
        }

        // ACK immediately - don't block reader thread
        self.acknowledgeFrame(frame_sid) catch {};
    }

    /// Get latest screencast frame (zero-copy)
    pub fn getLatestFrame(self: *WebSocketCdpClient) ?ScreencastFrame {
        const pool = self.frame_pool orelse return null;
        const slot = pool.acquireLatestFrame() orelse return null;

        return ScreencastFrame{
            .data = slot.data(),
            .slot = slot,
            .session_id = slot.session_id,
            .device_width = slot.device_width,
            .device_height = slot.device_height,
            .generation = slot.generation,
        };
    }

    /// Get count of frames received
    pub fn getFrameCount(self: *WebSocketCdpClient) u32 {
        return self.frame_count.load(.monotonic);
    }

    /// Flush pending ACK (no-op, kept for API compatibility)
    pub fn flushPendingAck(_: *WebSocketCdpClient) void {}

    fn extractFrameSessionId(_: *WebSocketCdpClient, payload: []const u8) !u32 {
        const p_marker = "\"params\":{";
        const p_pos = simd.findPattern(payload, p_marker, 0) orelse return error.NotFound;
        const s_marker = "\"sessionId\":";
        const pos = simd.findPattern(payload, s_marker, p_pos + p_marker.len) orelse return error.NotFound;
        const start = pos + s_marker.len;
        var end = start;
        while (end < payload.len and (payload[end] >= '0' and payload[end] <= '9')) : (end += 1) {}
        return std.fmt.parseInt(u32, payload[start..end], 10);
    }

    fn extractScreencastData(_: *WebSocketCdpClient, payload: []const u8) ![]const u8 {
        const pos = simd.findPattern(payload, "\"data\":\"", 0) orelse return error.InvalidFormat;
        const start = pos + "\"data\":\"".len;
        const end = simd.findClosingQuote(payload, start) orelse return error.InvalidFormat;
        return payload[start..end];
    }

    fn extractMetadataInt(_: *WebSocketCdpClient, payload: []const u8, key: []const u8) !u32 {
        const m_start = std.mem.indexOf(u8, payload, "\"metadata\":{") orelse return error.NotFound;
        var buf: [64]u8 = undefined;
        const s_key = std.fmt.bufPrint(&buf, "\"{s}\":", .{key}) catch return error.NotFound;
        const k_start = std.mem.indexOfPos(u8, payload, m_start, s_key) orelse return error.NotFound;
        const v_start = k_start + s_key.len;
        var end = v_start;
        while (end < payload.len and (payload[end] >= '0' and payload[end] <= '9')) : (end += 1) {}
        return std.fmt.parseInt(u32, payload[v_start..end], 10);
    }

    fn acknowledgeFrame(self: *WebSocketCdpClient, frame_sid: u32) !void {
        var buf: [128]u8 = undefined;
        const id = self.next_id.fetchAdd(1, .monotonic);
        const command = std.fmt.bufPrint(&buf, "{{\"id\":{d},\"method\":\"Page.screencastFrameAck\",\"params\":{{\"sessionId\":{d}}}}}", .{ id, frame_sid }) catch return;
        try self.sendFrame(0x1, command);
    }

    // ============ End Screencast Frame Handling ============

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
