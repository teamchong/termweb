/// Pipe-based CDP client for Chrome DevTools Protocol.
///
/// Uses `--remote-debugging-pipe` mode which communicates via file descriptors:
/// - FD 3: Chrome reads commands from this pipe
/// - FD 4: Chrome writes responses/events to this pipe
const std = @import("std");
const simd = @import("../simd/dispatch.zig");

/// Debug logging - write to pipe_debug.log
var pipe_debug_file: ?std.fs.File = null;

fn logToFile(comptime fmt: []const u8, args: anytype) void {
    if (pipe_debug_file == null) {
        pipe_debug_file = std.fs.cwd().createFile("pipe_debug.log", .{ .truncate = false }) catch null;
        if (pipe_debug_file) |f| {
            f.seekFromEnd(0) catch {};
        }
    }
    const file = pipe_debug_file orelse return;
    var buf: [8192]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = file.write(slice) catch {};
    file.sync() catch {}; // Flush to disk for debugging
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
    PipeBroken, // Chrome closed the connection
};

const ResponseQueueEntry = struct {
    id: u32,
    payload: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ResponseQueueEntry) void {
        self.allocator.free(self.payload);
    }
};

/// Event queue entry for CDP events (console, dialogs, etc.)
const EventQueueEntry = struct {
    method: []u8,
    payload: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *EventQueueEntry) void {
        self.allocator.free(self.method);
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

    // Event queue for console messages, dialogs, etc.
    event_queue: std.ArrayList(EventQueueEntry),
    event_mutex: std.Thread.Mutex,

    write_mutex: std.Thread.Mutex,

    read_buffer: []u8,
    read_pos: usize,

    // Track if files have been closed to avoid double-close panics
    read_file_closed: bool,
    write_file_closed: bool,

    // Set by reader thread when Chrome closes the pipe
    pipe_broken: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, read_fd: std.posix.fd_t, write_fd: std.posix.fd_t) !*PipeCdpClient {
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
            .write_mutex = .{},
            .read_buffer = read_buffer,
            .read_pos = 0,
            .read_file_closed = false,
            .write_file_closed = false,
            .pipe_broken = std.atomic.Value(bool).init(false),
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

        // Free any remaining response queue entries (in case stopReaderThread wasn't called)
        for (self.response_queue.items) |*entry| {
            self.allocator.free(entry.payload);
        }
        self.response_queue.deinit(self.allocator);

        // Free any remaining event queue entries
        for (self.event_queue.items) |*entry| {
            entry.deinit();
        }
        self.event_queue.deinit(self.allocator);
        logToFile("[PIPE deinit] Response and event queues deinit done\n", .{});

        self.allocator.free(self.read_buffer);
        self.allocator.destroy(self);
    }

    /// Check if Chrome closed the pipe (detected by reader thread)
    pub fn isPipeBroken(self: *PipeCdpClient) bool {
        return self.pipe_broken.load(.acquire);
    }

    pub fn sendCommandAsync(self: *PipeCdpClient, method: []const u8, params: ?[]const u8) !void {
        _ = try self.sendCommandAsyncWithId(method, params);
    }

    /// Send command async and return the command ID for polling
    pub fn sendCommandAsyncWithId(self: *PipeCdpClient, method: []const u8, params: ?[]const u8) !u32 {
        // Fail fast if Chrome closed the pipe
        if (self.pipe_broken.load(.acquire)) {
            logToFile("[PIPE] sendCommandAsyncWithId FAILED (pipe already broken) method={s}\n", .{method});
            return PipeError.PipeBroken;
        }

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

        logToFile("[PIPE] sendCommandAsyncWithId id={} method={s}\n", .{ id, method });

        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        self.write_file.writeAll(command) catch |err| {
            logToFile("[PIPE] sendCommandAsyncWithId FAILED: {}\n", .{err});
            return err;
        };
        return id;
    }

    pub fn sendSessionCommandAsync(self: *PipeCdpClient, session_id: []const u8, method: []const u8, params: ?[]const u8) !void {
        _ = try self.sendSessionCommandAsyncWithId(session_id, method, params);
    }

    /// Send session command async and return the command ID for polling
    pub fn sendSessionCommandAsyncWithId(self: *PipeCdpClient, session_id: []const u8, method: []const u8, params: ?[]const u8) !u32 {
        // Fail fast if Chrome closed the pipe
        if (self.pipe_broken.load(.acquire)) {
            logToFile("[PIPE] sendSessionCommandAsyncWithId FAILED (pipe already broken) method={s}\n", .{method});
            return PipeError.PipeBroken;
        }

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

        logToFile("[PIPE] sendSessionCommandAsyncWithId id={} sid={s} method={s}\n", .{ id, session_id, method });

        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        self.write_file.writeAll(command) catch |err| {
            logToFile("[PIPE] sendSessionCommandAsyncWithId FAILED id={} method={s}: {}\n", .{ id, method, err });
            return err;
        };
        return id;
    }

    /// Poll for a response by command ID (non-blocking)
    /// Returns the response payload if found, null if not yet available
    /// Caller owns the returned memory
    pub fn pollResponse(self: *PipeCdpClient, id: u32) ?[]u8 {
        self.response_mutex.lock();
        defer self.response_mutex.unlock();

        var i: usize = 0;
        while (i < self.response_queue.items.len) : (i += 1) {
            const entry = self.response_queue.items[i];
            if (entry.id == id) {
                const response = entry.payload;
                _ = self.response_queue.swapRemove(i);
                logToFile("[PIPE] pollResponse id={} found ({} bytes)\n", .{ id, response.len });
                return response;
            }
        }
        return null;
    }

    pub fn sendSessionCommand(self: *PipeCdpClient, session_id: []const u8, method: []const u8, params: ?[]const u8) ![]u8 {
        // Fail fast if Chrome closed the pipe
        if (self.pipe_broken.load(.acquire)) {
            logToFile("[PIPE] sendSessionCommand FAILED (pipe already broken) method={s}\n", .{method});
            return PipeError.PipeBroken;
        }

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
        // Fail fast if Chrome closed the pipe
        if (self.pipe_broken.load(.acquire)) {
            logToFile("[PIPE] sendCommand FAILED (pipe already broken) method={s}\n", .{method});
            return PipeError.PipeBroken;
        }

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

        logToFile("[PIPE] sendCommand id={} method={s}\n", .{ id, method });

        {
            self.write_mutex.lock();
            defer self.write_mutex.unlock();
            self.write_file.writeAll(command) catch |err| {
                logToFile("[PIPE] sendCommand WRITE FAILED: {}\n", .{err});
                return err;
            };
        }

        return self.waitForResponse(id) catch |err| {
            logToFile("[PIPE] sendCommand WAIT FAILED id={} method={s}: {}\n", .{ id, method, err });
            return err;
        };
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

            // Clean up any responses added between unlock and join (race window)
            self.response_mutex.lock();
            for (self.response_queue.items) |*entry| {
                self.allocator.free(entry.payload);
            }
            self.response_queue.clearRetainingCapacity();
            self.response_mutex.unlock();
        }
    }

    // NOTE: nextEvent removed - events come from nav_ws, not pipe

    fn readerThreadMain(self: *PipeCdpClient) void {
        logToFile("[PIPE READER] Thread started\n", .{});
        while (self.running.load(.acquire)) {
            const message = self.readMessage() catch |err| {
                // Pipe closed (either ConnectionFailed or NotOpenForReading from stopReaderThread)
                if (err == PipeError.ConnectionFailed) {
                    logToFile("[PIPE READER] Chrome closed pipe (ConnectionFailed)\n", .{});
                    self.pipe_broken.store(true, .release);
                    break;
                }
                if (err == error.NotOpenForReading) {
                    logToFile("[PIPE READER] Pipe closed for reading (stopping)\n", .{});
                    break;
                }
                if (!self.running.load(.acquire)) break;
                logToFile("[PIPE READER] readMessage error: {}, continuing\n", .{err});
                continue;
            };
            defer self.allocator.free(message);

            if (std.mem.indexOf(u8, message, "\"method\":")) |_| {
                self.handleEvent(message) catch {};
            } else if (std.mem.indexOf(u8, message, "\"id\":")) |_| {
                self.handleResponse(message) catch {};
            }
        }
        logToFile("[PIPE READER] Thread exiting\n", .{});
    }

    /// Handle CDP events from pipe
    fn handleEvent(self: *PipeCdpClient, payload: []const u8) !void {
        const method_start = std.mem.indexOf(u8, payload, "\"method\":\"") orelse return;
        const method_v_start = method_start + "\"method\":\"".len;
        const method_end = std.mem.indexOfPos(u8, payload, method_v_start, "\"") orelse return;
        const method = payload[method_v_start..method_end];

        // Queue events for processing (console messages, dialogs, etc.)
        self.event_mutex.lock();
        defer self.event_mutex.unlock();

        if (!self.running.load(.acquire)) return;

        const MAX_EVENT_QUEUE_SIZE = 100;
        while (self.event_queue.items.len >= MAX_EVENT_QUEUE_SIZE) {
            var old = self.event_queue.swapRemove(0);
            old.deinit();
        }

        // Allocate copies before append
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
    }

    /// Get next event from queue (non-blocking)
    pub fn nextEvent(self: *PipeCdpClient) ?EventQueueEntry {
        self.event_mutex.lock();
        defer self.event_mutex.unlock();

        if (self.event_queue.items.len == 0) return null;
        return self.event_queue.orderedRemove(0);
    }

    /// Clear pending responses that will never arrive (call during session reset)
    /// This prevents waitForResponse from blocking forever on stale request IDs
    pub fn clearResponseQueue(self: *PipeCdpClient) void {
        self.response_mutex.lock();
        defer self.response_mutex.unlock();

        for (self.response_queue.items) |*entry| {
            self.allocator.free(entry.payload);
        }
        self.response_queue.clearRetainingCapacity();
        logToFile("[PIPE] Response queue cleared\n", .{});
    }

    /// Clear pending events (call during full session reset)
    pub fn clearEventQueue(self: *PipeCdpClient) void {
        self.event_mutex.lock();
        defer self.event_mutex.unlock();

        for (self.event_queue.items) |*entry| {
            self.allocator.free(entry.method);
            self.allocator.free(entry.payload);
        }
        self.event_queue.clearRetainingCapacity();
        logToFile("[PIPE] Event queue cleared\n", .{});
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

};
