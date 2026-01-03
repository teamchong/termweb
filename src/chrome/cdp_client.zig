/// Chrome DevTools Protocol (CDP) client implementation.
///
/// Provides high-level interface for communicating with Chrome/Chromium browser
/// via WebSocket. Handles page discovery, connection management, and command
/// dispatch. Uses HTTP /json/list endpoint to discover page targets, then
/// establishes WebSocket connection for real-time CDP communication.
const std = @import("std");
const websocket_cdp = @import("websocket_cdp.zig");

pub const CdpError = error{
    ConnectionFailed,
    SendFailed,
    ReceiveFailed,
    InvalidResponse,
    CommandFailed,
    TimeoutWaitingForResponse,
    OutOfMemory,
};

/// CDP Client using WebSocket for real-time communication
pub const CdpClient = struct {
    allocator: std.mem.Allocator,
    ws_client: *websocket_cdp.WebSocketCdpClient,
    http_client: std.http.Client,
    base_url: []const u8,
    page_id: []const u8,

    pub fn init(allocator: std.mem.Allocator, ws_url: []const u8) !*CdpClient {
        // Extract HTTP base URL from WebSocket URL
        // ws://127.0.0.1:9222/devtools/browser/xxx -> http://127.0.0.1:9222
        const base_url = try extractHttpUrl(allocator, ws_url);

        const client = try allocator.create(CdpClient);
        client.* = .{
            .allocator = allocator,
            .ws_client = undefined,  // Will be set after discovering page WebSocket URL
            .http_client = std.http.Client{ .allocator = allocator },
            .base_url = base_url,
            .page_id = undefined,  // Will be set by discoverPage
        };

        // Discover the page's WebSocket URL via HTTP /json/list
        const page_ws_url = try client.discoverPageWebSocketUrl();
        defer allocator.free(page_ws_url);

        // Connect to page's WebSocket endpoint
        client.ws_client = try websocket_cdp.WebSocketCdpClient.connect(allocator, page_ws_url);

        return client;
    }

    pub fn deinit(self: *CdpClient) void {
        self.ws_client.deinit();
        self.http_client.deinit();
        self.allocator.free(self.base_url);
        self.allocator.free(self.page_id);
        self.allocator.destroy(self);
    }

    /// Discover the first page target's WebSocket URL via HTTP /json/list
    fn discoverPageWebSocketUrl(self: *CdpClient) ![]const u8 {
        // Build URL for /json/list endpoint
        const list_url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/json/list",
            .{self.base_url},
        );
        defer self.allocator.free(list_url);

        const uri = try std.Uri.parse(list_url);

        // Make HTTP request
        var req = try self.http_client.request(.GET, uri, .{});
        defer req.deinit();

        try req.sendBodiless();

        // Read response head
        var redirect_buf: [1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        // Read response body
        var reader_buf: [4096]u8 = undefined;
        var reader = response.reader(&reader_buf);
        const body = try reader.allocRemaining(self.allocator, .unlimited);
        defer self.allocator.free(body);

        // Parse JSON array: [{"id": "...", "type": "page", ...}, ...]
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
        defer parsed.deinit();

        // Find first page target and extract its WebSocket URL
        switch (parsed.value) {
            .array => |arr| {
                for (arr.items) |target| {
                    switch (target) {
                        .object => |obj| {
                            if (obj.get("type")) |type_val| {
                                switch (type_val) {
                                    .string => |type_str| {
                                        if (std.mem.eql(u8, type_str, "page")) {
                                            // Get both ID and WebSocket URL
                                            if (obj.get("id")) |id_val| {
                                                switch (id_val) {
                                                    .string => |id_str| {
                                                        self.page_id = try self.allocator.dupe(u8, id_str);
                                                    },
                                                    else => {},
                                                }
                                            }
                                            if (obj.get("webSocketDebuggerUrl")) |ws_val| {
                                                switch (ws_val) {
                                                    .string => |ws_url| {
                                                        return try self.allocator.dupe(u8, ws_url);
                                                    },
                                                    else => {},
                                                }
                                            }
                                        }
                                    },
                                    else => {},
                                }
                            }
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }

        return CdpError.InvalidResponse;  // No page target found
    }

    /// Send CDP command via WebSocket
    pub fn sendCommand(
        self: *CdpClient,
        method: []const u8,
        params: ?[]const u8,
    ) ![]u8 {
        // Delegate to WebSocket client
        return self.ws_client.sendCommand(method, params);
    }

    /// Send CDP command without waiting for response (fire-and-forget)
    pub fn sendCommandAsync(
        self: *CdpClient,
        method: []const u8,
        params: ?[]const u8,
    ) !void {
        return self.ws_client.sendCommandAsync(method, params);
    }

    /// Start screencast streaming with exact viewport dimensions for 1:1 coordinate mapping
    pub fn startScreencast(
        self: *CdpClient,
        format: []const u8,
        quality: u8,
        width: u32,
        height: u32,
    ) !void {
        // Use exact viewport dimensions - no scaling needed, coordinates are 1:1
        const params = try std.fmt.allocPrint(
            self.allocator,
            "{{\"format\":\"{s}\",\"quality\":{d},\"maxWidth\":{d},\"maxHeight\":{d},\"everyNthFrame\":1}}",
            .{ format, quality, width, height },
        );
        defer self.allocator.free(params);

        const result = try self.sendCommand("Page.startScreencast", params);
        defer self.allocator.free(result);

        // Start reader thread for event handling
        try self.ws_client.startReaderThread();
    }

    /// Stop screencast streaming
    pub fn stopScreencast(self: *CdpClient) !void {
        const result = try self.sendCommand("Page.stopScreencast", null);
        defer self.allocator.free(result);
    }

    /// Get latest screencast frame (non-blocking)
    pub fn getLatestFrame(self: *CdpClient) ?websocket_cdp.ScreencastFrame {
        return self.ws_client.getLatestFrame();
    }

    /// Get count of frames received (for debugging)
    pub fn getFrameCount(self: *CdpClient) u32 {
        return self.ws_client.getFrameCount();
    }
};

/// Extract HTTP URL from WebSocket URL
/// ws://127.0.0.1:9222/... -> http://127.0.0.1:9222
fn extractHttpUrl(allocator: std.mem.Allocator, ws_url: []const u8) ![]const u8 {
    // Find the end of the authority (host:port)
    // ws://127.0.0.1:9222/devtools/browser/xxx
    const prefix = "ws://";
    if (!std.mem.startsWith(u8, ws_url, prefix)) {
        return error.InvalidResponse;
    }

    const after_prefix = ws_url[prefix.len..];
    const slash_idx = std.mem.indexOf(u8, after_prefix, "/") orelse after_prefix.len;

    const authority = after_prefix[0..slash_idx];

    return try std.fmt.allocPrint(allocator, "http://{s}", .{authority});
}
