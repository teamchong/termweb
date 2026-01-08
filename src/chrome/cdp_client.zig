/// Chrome DevTools Protocol (CDP) client implementation.
///
/// Uses Pipe transport (--remote-debugging-pipe) for communication with Chrome.
/// Pipe mode provides higher throughput than WebSocket by eliminating TCP overhead.
///
/// In Pipe mode, we connect to the Browser target first, then must attach to a Page
/// target to send page-level commands like Page.navigate.
const std = @import("std");
const cdp_pipe = @import("cdp_pipe.zig");

pub const CdpError = error{
    ConnectionFailed,
    SendFailed,
    ReceiveFailed,
    InvalidResponse,
    CommandFailed,
    TimeoutWaitingForResponse,
    OutOfMemory,
    NoPageTarget,
};

/// Re-export ScreencastFrame from pipe module
pub const ScreencastFrame = cdp_pipe.ScreencastFrame;

/// CDP Client using Pipe for real-time communication
/// Wraps PipeCdpClient with the same interface used by viewer/screenshot modules
pub const CdpClient = struct {
    allocator: std.mem.Allocator,
    pipe_client: *cdp_pipe.PipeCdpClient,
    session_id: ?[]const u8, // Session ID for page-level commands

    /// Initialize CDP client from pipe file descriptors
    /// read_fd: FD to read from Chrome (Chrome's FD 4)
    /// write_fd: FD to write to Chrome (Chrome's FD 3)
    pub fn initFromPipe(allocator: std.mem.Allocator, read_fd: std.posix.fd_t, write_fd: std.posix.fd_t) !*CdpClient {
        const client = try allocator.create(CdpClient);
        client.* = .{
            .allocator = allocator,
            .pipe_client = try cdp_pipe.PipeCdpClient.init(allocator, read_fd, write_fd),
            .session_id = null,
        };

        // Attach to page target to enable page-level commands
        try client.attachToPageTarget();

        // Enable domains for consistent event delivery
        const page_enable = try client.sendCommand("Page.enable", null);
        allocator.free(page_enable);
        const network_enable = try client.sendCommand("Network.enable", null);
        allocator.free(network_enable);

        return client;
    }

    /// Attach to a page target to enable page-level commands
    fn attachToPageTarget(self: *CdpClient) !void {
        // Step 1: Get list of targets
        const targets_response = try self.pipe_client.sendCommand("Target.getTargets", null);
        defer self.allocator.free(targets_response);

        // Parse targetId from response - look for type "page"
        // Format: {"id":N,"result":{"targetInfos":[{"targetId":"XXX","type":"page",...}]}}
        const target_id = try self.extractPageTargetId(targets_response);
        defer self.allocator.free(target_id);

        // Step 2: Attach to the page target with flatten mode
        const params = try std.fmt.allocPrint(
            self.allocator,
            "{{\"targetId\":\"{s}\",\"flatten\":true}}",
            .{target_id},
        );
        defer self.allocator.free(params);

        const attach_response = try self.pipe_client.sendCommand("Target.attachToTarget", params);
        defer self.allocator.free(attach_response);

        // Extract sessionId from response
        // Format: {"id":N,"result":{"sessionId":"XXX"}}
        self.session_id = try self.extractSessionId(attach_response);
    }

    /// Extract page targetId from Target.getTargets response
    fn extractPageTargetId(self: *CdpClient, response: []const u8) ![]const u8 {
        // Find "type":"page" first
        const type_pos = std.mem.indexOf(u8, response, "\"type\":\"page\"") orelse
            return CdpError.NoPageTarget;

        // Search backwards for targetId
        const search_start = if (type_pos > 200) type_pos - 200 else 0;
        const search_slice = response[search_start..type_pos];

        const target_id_marker = "\"targetId\":\"";
        const target_id_pos = std.mem.lastIndexOf(u8, search_slice, target_id_marker) orelse
            return CdpError.NoPageTarget;

        const id_start = search_start + target_id_pos + target_id_marker.len;
        const id_end_marker = std.mem.indexOfPos(u8, response, id_start, "\"") orelse
            return CdpError.NoPageTarget;

        return try self.allocator.dupe(u8, response[id_start..id_end_marker]);
    }

    /// Extract sessionId from Target.attachToTarget response
    fn extractSessionId(self: *CdpClient, response: []const u8) ![]const u8 {
        const session_marker = "\"sessionId\":\"";
        const session_pos = std.mem.indexOf(u8, response, session_marker) orelse
            return CdpError.InvalidResponse;

        const id_start = session_pos + session_marker.len;
        const id_end = std.mem.indexOfPos(u8, response, id_start, "\"") orelse
            return CdpError.InvalidResponse;

        return try self.allocator.dupe(u8, response[id_start..id_end]);
    }

    pub fn deinit(self: *CdpClient) void {
        if (self.session_id) |sid| self.allocator.free(sid);
        self.pipe_client.deinit();
        self.allocator.destroy(self);
    }

    /// Format a command with sessionId for page-level commands
    fn formatSessionCommand(self: *CdpClient, method: []const u8, params: ?[]const u8) ![]const u8 {
        if (self.session_id) |sid| {
            if (params) |p| {
                return try std.fmt.allocPrint(
                    self.allocator,
                    "{{\"sessionId\":\"{s}\",\"method\":\"{s}\",\"params\":{s}}}",
                    .{ sid, method, p },
                );
            } else {
                return try std.fmt.allocPrint(
                    self.allocator,
                    "{{\"sessionId\":\"{s}\",\"method\":\"{s}\"}}",
                    .{ sid, method },
                );
            }
        } else {
            // No session - shouldn't happen after init
            return CdpError.InvalidResponse;
        }
    }

    /// Send mouse command (fire-and-forget) - uses session
    pub fn sendMouseCommandAsync(
        self: *CdpClient,
        method: []const u8,
        params: ?[]const u8,
    ) !void {
        if (self.session_id != null) {
            // For session commands, we need to embed sessionId in the JSON
            return self.pipe_client.sendSessionCommandAsync(self.session_id.?, method, params);
        }
        return self.pipe_client.sendCommandAsync(method, params);
    }

    /// Send keyboard command (fire-and-forget) - uses session
    pub fn sendKeyboardCommandAsync(
        self: *CdpClient,
        method: []const u8,
        params: ?[]const u8,
    ) !void {
        if (self.session_id != null) {
            return self.pipe_client.sendSessionCommandAsync(self.session_id.?, method, params);
        }
        return self.pipe_client.sendCommandAsync(method, params);
    }

    /// Send navigation command and wait for response - uses session
    pub fn sendNavCommand(
        self: *CdpClient,
        method: []const u8,
        params: ?[]const u8,
    ) ![]u8 {
        if (self.session_id != null) {
            return self.pipe_client.sendSessionCommand(self.session_id.?, method, params);
        }
        return self.pipe_client.sendCommand(method, params);
    }

    /// Send navigation command (fire-and-forget) - uses session
    pub fn sendNavCommandAsync(
        self: *CdpClient,
        method: []const u8,
        params: ?[]const u8,
    ) !void {
        if (self.session_id != null) {
            return self.pipe_client.sendSessionCommandAsync(self.session_id.?, method, params);
        }
        return self.pipe_client.sendCommandAsync(method, params);
    }

    /// Send CDP command and wait for response - uses session
    pub fn sendCommand(
        self: *CdpClient,
        method: []const u8,
        params: ?[]const u8,
    ) ![]u8 {
        if (self.session_id != null) {
            return self.pipe_client.sendSessionCommand(self.session_id.?, method, params);
        }
        return self.pipe_client.sendCommand(method, params);
    }

    /// Send CDP command without waiting for response - uses session
    pub fn sendCommandAsync(
        self: *CdpClient,
        method: []const u8,
        params: ?[]const u8,
    ) !void {
        if (self.session_id != null) {
            return self.pipe_client.sendSessionCommandAsync(self.session_id.?, method, params);
        }
        return self.pipe_client.sendCommandAsync(method, params);
    }

    /// Start screencast streaming
    pub fn startScreencast(
        self: *CdpClient,
        format: []const u8,
        quality: u8,
        width: u32,
        height: u32,
    ) !void {
        // Start reader thread first
        try self.pipe_client.startReaderThread();

        // Send startScreencast command with session
        const params = try std.fmt.allocPrint(
            self.allocator,
            "{{\"format\":\"{s}\",\"quality\":{d},\"maxWidth\":{d},\"maxHeight\":{d},\"everyNthFrame\":1}}",
            .{ format, quality, width, height },
        );
        defer self.allocator.free(params);

        const result = try self.sendCommand("Page.startScreencast", params);
        defer self.allocator.free(result);
    }

    /// Stop screencast streaming
    pub fn stopScreencast(self: *CdpClient) !void {
        self.pipe_client.stopReaderThread();
    }

    /// Get latest screencast frame (non-blocking)
    pub fn getLatestFrame(self: *CdpClient) ?ScreencastFrame {
        return self.pipe_client.getLatestFrame();
    }

    /// Get count of frames received
    pub fn getFrameCount(self: *CdpClient) u32 {
        return self.pipe_client.getFrameCount();
    }
};
