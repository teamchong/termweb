/// Pipe-based CDP client for Chrome DevTools Protocol.
///
/// Uses `--remote-debugging-pipe` mode which communicates via file descriptors:
/// - FD 3: Chrome reads commands from this pipe
/// - FD 4: Chrome writes responses/events to this pipe
const std = @import("std");
const simd = @import("../simd/dispatch.zig");
const FramePool = @import("../simd/frame_pool.zig").FramePool;
const FrameSlot = @import("../simd/frame_pool.zig").FrameSlot;
const json = @import("../utils/json.zig");

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

// NOTE: Event queue removed - pipe is ONLY for screencast frames
// All events (console, dialogs, file chooser) go through nav_ws

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

    // NOTE: No event queue - pipe is ONLY for screencast frames
    // Events go through nav_ws

    // Navigation event flag - set when Page.frameNavigated or similar events occur
    navigation_happened: std.atomic.Value(bool),

    frame_pool: *FramePool,
    frame_count: std.atomic.Value(u32),

    write_mutex: std.Thread.Mutex,

    read_buffer: []u8,
    read_pos: usize,

    // Track if files have been closed to avoid double-close panics
    read_file_closed: bool,
    write_file_closed: bool,

    // Pending ack for adaptive frame throttling
    // We delay acking until the viewer consumes the frame via getLatestFrame()
    pending_ack_frame_sid: ?u32,
    pending_ack_routing_sid: ?[]u8, // Owned copy

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
            .navigation_happened = std.atomic.Value(bool).init(false),
            .frame_pool = frame_pool,
            .frame_count = std.atomic.Value(u32).init(0),
            .write_mutex = .{},
            .read_buffer = read_buffer,
            .read_pos = 0,
            .read_file_closed = false,
            .write_file_closed = false,
            .pending_ack_frame_sid = null,
            .pending_ack_routing_sid = null,
        };

        return client;
    }

    pub fn deinit(self: *PipeCdpClient) void {
        logToFile("[PIPE deinit] Starting, response_queue.len={}\n", .{self.response_queue.items.len});

        self.stopReaderThread(); // Closes read_file and joins thread

        logToFile("[PIPE deinit] After stopReaderThread, response_queue.len={}\n", .{self.response_queue.items.len});

        // Close write pipe (we own both fds from launcher)
        // Use raw syscall to handle EBADF gracefully (pipe may already be closed by Chrome)
        if (!self.write_file_closed) {
            _ = std.posix.system.close(self.write_file.handle);
            self.write_file_closed = true;
        }

        self.frame_pool.deinit();

        // Free pending ack routing sid if set
        if (self.pending_ack_routing_sid) |sid| {
            self.allocator.free(sid);
        }

        // Free response queue entries - lock just in case
        self.response_mutex.lock();
        const queue_len = self.response_queue.items.len;
        for (self.response_queue.items) |*entry| {
            entry.deinit();
        }
        self.response_queue.deinit(self.allocator);
        self.response_mutex.unlock();

        logToFile("[PIPE deinit] Freed {} response queue entries\n", .{queue_len});

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
            // Acquire lock to ensure no in-flight operations
            self.response_mutex.lock();
            self.running.store(false, .release);
            self.response_mutex.unlock();

            // Close read pipe to unblock the reader thread from blocking read()
            // Use raw syscall to handle EBADF gracefully (pipe may already be closed by Chrome)
            if (!self.read_file_closed) {
                _ = std.posix.system.close(self.read_file.handle);
                self.read_file_closed = true;
            }
            // Now we can safely wait for thread to finish
            thread.join();
            self.reader_thread = null;
        }
    }

    pub fn getLatestFrame(self: *PipeCdpClient) ?ScreencastFrame {
        const slot = self.frame_pool.acquireLatestFrame() orelse return null;

        // Send pending ack for adaptive throttling
        // This tells Chrome we're ready for more frames
        if (self.pending_ack_frame_sid) |frame_sid| {
            self.acknowledgeFrame(self.pending_ack_routing_sid, frame_sid) catch {};
            // Free the routing_sid copy
            if (self.pending_ack_routing_sid) |sid| {
                self.allocator.free(sid);
            }
            self.pending_ack_frame_sid = null;
            self.pending_ack_routing_sid = null;
        }

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

    // NOTE: nextEvent removed - events come from nav_ws, not pipe

    fn readerThreadMain(self: *PipeCdpClient) void {
        while (self.running.load(.acquire)) {
            const message = self.readMessage() catch |err| {
                // Pipe closed (either ConnectionFailed or NotOpenForReading from stopReaderThread)
                if (err == PipeError.ConnectionFailed) break;
                if (err == error.NotOpenForReading) break;
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

    /// Handle CDP events from pipe
    /// PIPE IS ONLY FOR SCREENCAST FRAMES - events go through nav_ws
    fn handleEvent(self: *PipeCdpClient, payload: []const u8) !void {
        const method_start = std.mem.indexOf(u8, payload, "\"method\":\"") orelse return;
        const method_v_start = method_start + "\"method\":\"".len;
        const method_end = std.mem.indexOfPos(u8, payload, method_v_start, "\"") orelse return;
        const method = payload[method_v_start..method_end];

        // Set navigation flag for main frame navigation only (not iframes)
        // Main frame doesn't have parentId in the frame object
        if (std.mem.eql(u8, method, "Page.frameNavigated")) {
            // Only trigger for main frame (no parentId field)
            if (std.mem.indexOf(u8, payload, "\"parentId\"") == null) {
                self.navigation_happened.store(true, .release);
            }
        } else if (std.mem.eql(u8, method, "Page.navigatedWithinDocument")) {
            self.navigation_happened.store(true, .release);
        }

        // PIPE ONLY HANDLES SCREENCAST FRAMES
        // All other events (console, dialogs, file chooser) go through nav_ws
        if (std.mem.eql(u8, method, "Page.screencastFrame")) {
            self.handleScreencastFrame(payload) catch return;
        }
        // Ignore all other events - they're handled by nav_ws
    }

    fn handleScreencastFrame(self: *PipeCdpClient, payload: []const u8) !void {
        const routing_sid = self.extractRoutingSessionId(payload) catch null;
        const frame_sid = try self.extractFrameSessionId(payload);
        const data = try self.extractScreencastData(payload);
        const width = self.extractMetadataInt(payload, "deviceWidth") catch 0;
        const height = self.extractMetadataInt(payload, "deviceHeight") catch 0;

        // Debug: log first few frames' metadata dimensions
        const frame_count = self.frame_count.load(.monotonic);
        if (frame_count < 3) {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "[PIPE] Frame {}: device={}x{}\n", .{ frame_count, width, height }) catch "";
            if (std.fs.cwd().openFile("/tmp/pipe_debug.log", .{ .mode = .write_only })) |f| {
                f.seekFromEnd(0) catch {};
                _ = f.write(msg) catch {};
                f.close();
            } else |_| {}
        }

        if (try self.frame_pool.writeFrame(data, frame_sid, width, height)) |_| {
            _ = self.frame_count.fetchAdd(1, .monotonic);
        }

        // Store pending ack info for adaptive throttling
        // The ack will be sent when getLatestFrame() is called
        // Free old routing_sid if there was one
        if (self.pending_ack_routing_sid) |old_sid| {
            self.allocator.free(old_sid);
            self.pending_ack_routing_sid = null;
        }

        // Store new pending ack info
        self.pending_ack_frame_sid = frame_sid;
        if (routing_sid) |rsid| {
            self.pending_ack_routing_sid = self.allocator.dupe(u8, rsid) catch null;
        }
    }

    fn handleResponse(self: *PipeCdpClient, payload: []const u8) !void {
        const id = self.extractMessageId(payload) catch return;

        self.response_mutex.lock();
        defer self.response_mutex.unlock();

        // Check running while holding lock - prevents race with deinit
        if (!self.running.load(.acquire)) return;

        const MAX_QUEUE_SIZE = 50;
        while (self.response_queue.items.len >= MAX_QUEUE_SIZE) {
            var old = self.response_queue.swapRemove(0);
            old.deinit();
        }

        // Allocate payload copy BEFORE append to handle failure properly
        const payload_copy = self.allocator.dupe(u8, payload) catch return;
        self.response_queue.append(self.allocator, .{
            .id = id,
            .payload = payload_copy,
            .allocator = self.allocator,
        }) catch {
            // Free the duped payload if append fails
            self.allocator.free(payload_copy);
            return;
        };
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
        const command = if (r_sid) |rsid| blk: {
            // Escape session ID for JSON (handles any special chars)
            var escape_buf: [256]u8 = undefined;
            const escaped_sid = json.escapeContents(rsid, &escape_buf) catch return error.OutOfMemory;
            break :blk try std.fmt.allocPrint(self.allocator, "{{\"id\":{d},\"sessionId\":\"{s}\",\"method\":\"Page.screencastFrameAck\",\"params\":{{\"sessionId\":{d}}}}}\x00", .{ id, escaped_sid, f_sid });
        } else
            try std.fmt.allocPrint(self.allocator, "{{\"id\":{d},\"method\":\"Page.screencastFrameAck\",\"params\":{{\"sessionId\":{d}}}}}\x00", .{ id, f_sid });
        defer self.allocator.free(command);
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        _ = try self.write_file.writeAll(command);
    }
};
