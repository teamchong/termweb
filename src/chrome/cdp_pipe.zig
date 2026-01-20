/// Pipe-based CDP client for Chrome DevTools Protocol.
///
/// Uses `--remote-debugging-pipe` mode which communicates via file descriptors:
/// - FD 3: Chrome reads commands from this pipe
/// - FD 4: Chrome writes responses/events to this pipe
const std = @import("std");
const simd = @import("../simd/dispatch.zig");
const FramePool = @import("../simd/frame_pool.zig").FramePool;
const FrameSlot = @import("../simd/frame_pool.zig").FrameSlot;

fn logToFile(comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
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

pub const PipeError = error{
    ConnectionFailed,
    SendFailed,
    ReceiveFailed,
    InvalidResponse,
    ProtocolError,
    InvalidFormat,
    TimeoutWaitingForResponse,
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

const ResponseQueueEntry = struct {
    id: u32,
    payload: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ResponseQueueEntry) void {
        self.allocator.free(self.payload);
    }
};

const EventQueueEntry = struct {
    method: []const u8,
    payload: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *EventQueueEntry, gpa: std.mem.Allocator) void {
        gpa.free(self.method);
        gpa.free(self.payload);
    }
};

/// Pipe-based CDP client
pub const PipeCdpClient = struct {
    allocator: std.mem.Allocator,
    read_file: std.fs.File, 
    write_file: std.fs.File, 
    next_id: std.atomic.Value(u32),

    reader_thread: ?std.Thread,
    running: std.atomic.Value(bool),

    response_queue: std.ArrayList(ResponseQueueEntry),
    response_mutex: std.Thread.Mutex,

    event_queue: std.ArrayList(EventQueueEntry),
    event_mutex: std.Thread.Mutex,

    // Navigation event flag - set when Page.frameNavigated or similar events occur
    navigation_happened: std.atomic.Value(bool),

    frame_pool: *FramePool,
    frame_count: std.atomic.Value(u32),

    write_mutex: std.Thread.Mutex,

    read_buffer: []u8,
    read_pos: usize,

    pub fn init(allocator: std.mem.Allocator, read_fd: std.posix.fd_t, write_fd: std.posix.fd_t) !*PipeCdpClient {
        const frame_pool = try FramePool.init(allocator);

        // Allocate large read buffer for bursts
        const read_buffer = try allocator.alloc(u8, 4 * 1024 * 1024);

        const client = try allocator.create(PipeCdpClient);
        client.* = .{
            .allocator = allocator,
            .read_file = std.fs.File{ .handle = read_fd },
            .write_file = std.fs.File{ .handle = write_fd },
            .next_id = std.atomic.Value(u32).init(1),
            .reader_thread = null,
            .running = std.atomic.Value(bool).init(false),
            .response_queue = try std.ArrayList(ResponseQueueEntry).initCapacity(allocator, 0),
            .response_mutex = .{},
            .event_queue = try std.ArrayList(EventQueueEntry).initCapacity(allocator, 0),
            .event_mutex = .{},
            .navigation_happened = std.atomic.Value(bool).init(false),
            .frame_pool = frame_pool,
            .frame_count = std.atomic.Value(u32).init(0),
            .write_mutex = .{},
            .read_buffer = read_buffer,
            .read_pos = 0,
        };

        return client;
    }

    pub fn deinit(self: *PipeCdpClient) void {
        self.stopReaderThread();
        self.frame_pool.deinit();

        // Free response queue entries with lock
        self.response_mutex.lock();
        for (self.response_queue.items) |*entry| {
            entry.deinit();
        }
        self.response_queue.deinit(self.allocator);
        self.response_mutex.unlock();

        // Free event queue entries with lock
        self.event_mutex.lock();
        for (self.event_queue.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.event_queue.deinit(self.allocator);
        self.event_mutex.unlock();

        self.allocator.free(self.read_buffer);
        self.allocator.destroy(self);
    }

    /// Check if navigation happened and clear the flag (atomic swap)
    pub fn checkNavigationHappened(self: *PipeCdpClient) bool {
        return self.navigation_happened.swap(false, .acq_rel);
    }

    pub fn sendCommandAsync(self: *PipeCdpClient, method: []const u8, params: ?[]const u8) !void {
        const id = self.next_id.fetchAdd(1, .monotonic);

        const command = if (params) |p|
            try std.fmt.allocPrint(
                self.allocator,
                "{{\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}\x00",
                .{ id, method, p },
            )
        else
            try std.fmt.allocPrint(
                self.allocator,
                "{{\"id\":{d},\"method\":\"{s}\"}}\x00",
                .{ id, method },
            );
        defer self.allocator.free(command);

        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        _ = try self.write_file.writeAll(command);
    }

    pub fn sendSessionCommandAsync(self: *PipeCdpClient, session_id: []const u8, method: []const u8, params: ?[]const u8) !void {
        const id = self.next_id.fetchAdd(1, .monotonic);

        const command = if (params) |p|
            try std.fmt.allocPrint(
                self.allocator,
                "{{\"id\":{d},\"sessionId\":\"{s}\",\"method\":\"{s}\",\"params\":{s}}}\x00",
                .{ id, session_id, method, p },
            )
        else
            try std.fmt.allocPrint(
                self.allocator,
                "{{\"id\":{d},\"sessionId\":\"{s}\",\"method\":\"{s}\"}}\x00",
                .{ id, session_id, method },
            );
        defer self.allocator.free(command);

        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        _ = try self.write_file.writeAll(command);
    }

    pub fn sendSessionCommand(self: *PipeCdpClient, session_id: []const u8, method: []const u8, params: ?[]const u8) ![]u8 {
        const id = self.next_id.fetchAdd(1, .monotonic);

        const command = if (params) |p|
            try std.fmt.allocPrint(
                self.allocator,
                "{{\"id\":{d},\"sessionId\":\"{s}\",\"method\":\"{s}\",\"params\":{s}}}\x00",
                .{ id, session_id, method, p },
            )
        else
            try std.fmt.allocPrint(
                self.allocator,
                "{{\"id\":{d},\"sessionId\":\"{s}\",\"method\":\"{s}\"}}\x00",
                .{ id, session_id, method },
            );
        defer self.allocator.free(command);

        logToFile("[PIPE] sendSessionCommand id={d} session={s} method={s}\n", .{ id, session_id, method });

        {
            self.write_mutex.lock();
            defer self.write_mutex.unlock();
            _ = try self.write_file.writeAll(command);
        }

        const response = self.waitForResponse(id) catch |err| {
            logToFile("[PIPE] sendSessionCommand id={d} method={s} ERROR: {}\n", .{ id, method, err });
            return err;
        };

        // Log first 500 chars of response
        const log_len = @min(response.len, 500);
        logToFile("[PIPE] sendSessionCommand id={d} method={s} response ({d} bytes): {s}\n", .{ id, method, response.len, response[0..log_len] });

        return response;
    }

    pub fn sendCommand(self: *PipeCdpClient, method: []const u8, params: ?[]const u8) ![]u8 {
        const id = self.next_id.fetchAdd(1, .monotonic);

        const command = if (params) |p|
            try std.fmt.allocPrint(
                self.allocator,
                "{{\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}\x00",
                .{ id, method, p },
            )
        else
            try std.fmt.allocPrint(
                self.allocator,
                "{{\"id\":{d},\"method\":\"{s}\"}}\x00",
                .{ id, method },
            );
        defer self.allocator.free(command);

        {
            self.write_mutex.lock();
            defer self.write_mutex.unlock();
            _ = try self.write_file.writeAll(command);
        }

        return self.waitForResponse(id);
    }

    fn waitForResponse(self: *PipeCdpClient, id: u32) ![]u8 {
        if (self.reader_thread != null) {
            const timeout_ns = 5 * std.time.ns_per_s;
            const start_time = std.time.nanoTimestamp();

            while (true) {
                if (std.time.nanoTimestamp() - start_time > timeout_ns) {
                    logToFile("[PIPE] waitForResponse id={d} TIMEOUT\n", .{id});
                    return PipeError.TimeoutWaitingForResponse;
                }

                self.response_mutex.lock();
                defer self.response_mutex.unlock();

                var i: usize = 0;
                while (i < self.response_queue.items.len) : (i += 1) {
                    const entry = self.response_queue.items[i];
                    if (entry.id == id) {
                        const response = entry.payload;
                        _ = self.response_queue.swapRemove(i);

                        if (std.mem.indexOf(u8, response, "\"error\":{")) |err_pos| {
                            if (err_pos < 20) {
                                // Log the full error response before freeing
                                const log_len = @min(response.len, 1000);
                                logToFile("[PIPE] waitForResponse id={d} PROTOCOL_ERROR: {s}\n", .{ id, response[0..log_len] });
                                self.allocator.free(response);
                                return PipeError.ProtocolError;
                            }
                        }

                        return response;
                    }
                }

                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
        } else {
            while (true) {
                const message = try self.readMessage();

                if (std.mem.indexOf(u8, message, "\"id\":")) |id_pos| {
                    const id_str = try std.fmt.allocPrint(self.allocator, "{d}", .{id});
                    defer self.allocator.free(id_str);

                    if (std.mem.indexOf(u8, message[id_pos..], id_str)) |_| {
                        if (std.mem.indexOf(u8, message, "\"result\":")) |_| {
                            return message;
                        }
                        if (std.mem.indexOf(u8, message, "\"error\":{")) |err_pos| {
                            if (err_pos < 20) {
                                // Log the full error response before freeing
                                const log_len = @min(message.len, 1000);
                                logToFile("[PIPE] waitForResponse id={d} PROTOCOL_ERROR (sync): {s}\n", .{ id, message[0..log_len] });
                                self.allocator.free(message);
                                return PipeError.ProtocolError;
                            }
                        }
                        return message;
                    }
                }
                self.allocator.free(message);
            }
        }
    }

    fn readMessage(self: *PipeCdpClient) ![]u8 {
        while (true) {
            if (std.mem.indexOf(u8, self.read_buffer[0..self.read_pos], &[_]u8{0})) |null_pos| {
                const message = try self.allocator.dupe(u8, self.read_buffer[0..null_pos]);

                const remaining = self.read_pos - null_pos - 1;
                if (remaining > 0) {
                    std.mem.copyForwards(u8, self.read_buffer[0..remaining], self.read_buffer[null_pos + 1 .. self.read_pos]);
                }
                self.read_pos = remaining;

                return message;
            }

            if (self.read_pos >= self.read_buffer.len) {
                const new_buffer = try self.allocator.alloc(u8, self.read_buffer.len * 2);
                @memcpy(new_buffer[0..self.read_pos], self.read_buffer[0..self.read_pos]);
                self.allocator.free(self.read_buffer);
                self.read_buffer = new_buffer;
            }

            const bytes_read = try self.read_file.read(self.read_buffer[self.read_pos..]);
            if (bytes_read == 0) {
                return PipeError.ConnectionFailed;
            }
            self.read_pos += bytes_read;
        }
    }

    pub fn startReaderThread(self: *PipeCdpClient) !void {
        if (self.reader_thread != null) return;
        self.running.store(true, .release);
        self.reader_thread = try std.Thread.spawn(.{}, readerThreadMain, .{self});
    }

    pub fn stopReaderThread(self: *PipeCdpClient) void {
        if (self.reader_thread) |thread| {
            self.running.store(false, .release);
            // Join the thread to ensure it's fully stopped before we free resources
            thread.join();
            self.reader_thread = null;
        }
    }

    pub fn getLatestFrame(self: *PipeCdpClient) ?ScreencastFrame {
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

    pub fn getFrameCount(self: *PipeCdpClient) u32 {
        return self.frame_count.load(.monotonic);
    }

    pub fn nextEvent(self: *PipeCdpClient, allocator: std.mem.Allocator) !?struct { method: []const u8, payload: []const u8 } {
        self.event_mutex.lock();
        defer self.event_mutex.unlock();

        if (self.event_queue.items.len == 0) return null;

        var entry = self.event_queue.orderedRemove(0);
        defer entry.deinit(self.allocator);

        return .{
            .method = try allocator.dupe(u8, entry.method),
            .payload = try allocator.dupe(u8, entry.payload),
        };
    }

    fn readerThreadMain(self: *PipeCdpClient) void {
        while (self.running.load(.acquire)) {
            const message = self.readMessage() catch |err| {
                if (err == PipeError.ConnectionFailed) break;
                if (!self.running.load(.acquire)) break;
                continue;
            };
            defer self.allocator.free(message);

            if (std.mem.indexOf(u8, message, "\"method\":")) |_| {
                self.handleEvent(message) catch {};
            } else if (std.mem.indexOf(u8, message, "\"id\":")) |_| {
                self.handleResponse(message) catch {};
            }
        }
    }

    fn handleEvent(self: *PipeCdpClient, payload: []const u8) !void {
        const method_start = std.mem.indexOf(u8, payload, "\"method\":\"") orelse return;
        const method_v_start = method_start + "\"method\":\"".len;
        const method_end = std.mem.indexOfPos(u8, payload, method_v_start, "\"") orelse return;
        const method = payload[method_v_start..method_end];

        // Set navigation flag for navigation events (event bus pattern)
        if (std.mem.eql(u8, method, "Page.frameNavigated") or
            std.mem.eql(u8, method, "Page.navigatedWithinDocument"))
        {
            self.navigation_happened.store(true, .release);
        }

        if (std.mem.eql(u8, method, "Page.screencastFrame")) {
            try self.handleScreencastFrame(payload);
        } else {
            // Queue other events for the main thread to process
            self.event_mutex.lock();
            defer self.event_mutex.unlock();

            const MAX_EVENT_QUEUE = 50;
            if (self.event_queue.items.len >= MAX_EVENT_QUEUE) {
                var old = self.event_queue.orderedRemove(0);
                old.deinit(self.allocator);
            }

            try self.event_queue.append(self.allocator, .{
                .method = try self.allocator.dupe(u8, method),
                .payload = try self.allocator.dupe(u8, payload),
                .allocator = self.allocator,
            });
        }
    }

    fn handleScreencastFrame(self: *PipeCdpClient, payload: []const u8) !void {
        const routing_sid = self.extractRoutingSessionId(payload) catch null;
        const frame_sid = try self.extractFrameSessionId(payload);
        const data = try self.extractScreencastData(payload);
        const width = self.extractMetadataInt(payload, "deviceWidth") catch 0;
        const height = self.extractMetadataInt(payload, "deviceHeight") catch 0;

        if (try self.frame_pool.writeFrame(data, frame_sid, width, height)) |_| {
            _ = self.frame_count.fetchAdd(1, .monotonic);
        }

        try self.acknowledgeFrame(routing_sid, frame_sid);
    }

    fn handleResponse(self: *PipeCdpClient, payload: []const u8) !void {
        const id = try self.extractMessageId(payload);
        self.response_mutex.lock();
        defer self.response_mutex.unlock();

        const MAX_QUEUE_SIZE = 50;
        while (self.response_queue.items.len >= MAX_QUEUE_SIZE) {
            var old = self.response_queue.swapRemove(0);
            old.deinit();
        }

        try self.response_queue.append(self.allocator, .{
            .id = id,
            .payload = try self.allocator.dupe(u8, payload),
            .allocator = self.allocator,
        });
    }

    fn extractMessageId(_: *PipeCdpClient, payload: []const u8) !u32 {
        const pos = simd.findPattern(payload, "\"id\":", 0) orelse return error.InvalidFormat;
        const start = pos + "\"id\":".len;
        var end = start;
        while (end < payload.len and (payload[end] >= '0' and payload[end] <= '9')) : (end += 1) {}
        return std.fmt.parseInt(u32, payload[start..end], 10);
    }

    fn extractRoutingSessionId(_: *PipeCdpClient, payload: []const u8) ![]const u8 {
        const marker = "\"sessionId\":\"";
        const pos = simd.findPattern(payload, marker, 0) orelse return error.NotFound;
        const start = pos + marker.len;
        const end = simd.findClosingQuote(payload, start) orelse return error.InvalidFormat;
        return payload[start..end];
    }

    fn extractFrameSessionId(_: *PipeCdpClient, payload: []const u8) !u32 {
        const p_marker = "\"params\":{";
        const p_pos = simd.findPattern(payload, p_marker, 0) orelse return error.NotFound;
        const s_marker = "\"sessionId\":";
        const pos = simd.findPattern(payload, s_marker, p_pos + p_marker.len) orelse return error.NotFound;
        const start = pos + s_marker.len;
        var end = start;
        while (end < payload.len and (payload[end] >= '0' and payload[end] <= '9')) : (end += 1) {}
        return std.fmt.parseInt(u32, payload[start..end], 10);
    }

    fn extractScreencastData(_: *PipeCdpClient, payload: []const u8) ![]const u8 {
        const pos = simd.findPattern(payload, "\"data\":\"", 0) orelse return error.InvalidFormat;
        const start = pos + "\"data\":\"".len;
        const end = simd.findClosingQuote(payload, start) orelse return error.InvalidFormat;
        return payload[start..end];
    }

    fn extractMetadataInt(self: *PipeCdpClient, payload: []const u8, key: []const u8) !u32 {
        _ = self;
        const m_start = std.mem.indexOf(u8, payload, "\"metadata\":{") orelse return error.NotFound;
        var buf: [64]u8 = undefined;
        const s_key = std.fmt.bufPrint(&buf, "\"{s}\":", .{key}) catch return error.NotFound;
        const k_start = std.mem.indexOfPos(u8, payload, m_start, s_key) orelse return error.NotFound;
        const v_start = k_start + s_key.len;
        var end = v_start;
        while (end < payload.len and (payload[end] >= '0' and payload[end] <= '9')) : (end += 1) {}
        return std.fmt.parseInt(u32, payload[v_start..end], 10);
    }

    fn acknowledgeFrame(self: *PipeCdpClient, r_sid: ?[]const u8, f_sid: u32) !void {
        const id = self.next_id.fetchAdd(1, .monotonic);
        const command = if (r_sid) |rsid|
            try std.fmt.allocPrint(self.allocator, "{{\"id\":{d},\"sessionId\":\"{s}\",\"method\":\"Page.screencastFrameAck\",\"params\":{{\"sessionId\":{d}}}}}\x00", .{ id, rsid, f_sid })
        else
            try std.fmt.allocPrint(self.allocator, "{{\"id\":{d},\"method\":\"Page.screencastFrameAck\",\"params\":{{\"sessionId\":{d}}}}}\x00", .{ id, f_sid });
        defer self.allocator.free(command);
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        _ = try self.write_file.writeAll(command);
    }
};
