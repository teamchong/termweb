/// Pipe-based CDP client for Chrome DevTools Protocol.
///
/// Uses `--remote-debugging-pipe` mode which communicates via file descriptors:
/// - FD 3: Chrome reads commands from this pipe
/// - FD 4: Chrome writes responses/events to this pipe
const std = @import("std");
const simd = @import("../simd/dispatch.zig");
const FramePool = @import("../simd/frame_pool.zig").FramePool;
const FrameSlot = @import("../simd/frame_pool.zig").FrameSlot;

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

        for (self.response_queue.items) |*entry| {
            entry.deinit();
        }
        self.response_queue.deinit(self.allocator);

        self.allocator.free(self.read_buffer);
        self.allocator.destroy(self);
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

        {
            self.write_mutex.lock();
            defer self.write_mutex.unlock();
            _ = try self.write_file.writeAll(command);
        }

        return self.waitForResponse(id);
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
            var waited: u32 = 0;
            while (waited < 10) : (waited += 1) {
                std.Thread.sleep(50 * std.time.ns_per_ms);
            }
            thread.detach();
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

        if (std.mem.eql(u8, method, "Page.screencastFrame")) {
            try self.handleScreencastFrame(payload);
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
