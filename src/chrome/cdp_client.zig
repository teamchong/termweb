const std = @import("std");

pub const CdpError = error{
    ConnectionFailed,
    SendFailed,
    ReceiveFailed,
    InvalidResponse,
    CommandFailed,
    TimeoutWaitingForResponse,
    OutOfMemory,
};

/// Simplified CDP Client for M1 using HTTP endpoints
/// For M2+, we'll add full WebSocket support
pub const CdpClient = struct {
    allocator: std.mem.Allocator,
    http_client: std.http.Client,
    base_url: []const u8,
    page_id: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, ws_url: []const u8) !*CdpClient {
        // Extract HTTP base URL from WebSocket URL
        // ws://127.0.0.1:9222/devtools/browser/xxx -> http://127.0.0.1:9222
        const base_url = try extractHttpUrl(allocator, ws_url);

        const client = try allocator.create(CdpClient);
        client.* = .{
            .allocator = allocator,
            .http_client = std.http.Client{ .allocator = allocator },
            .base_url = base_url,
            .page_id = null,
        };

        // Get the first page target
        try client.discoverPage();

        return client;
    }

    pub fn deinit(self: *CdpClient) void {
        self.http_client.deinit();
        self.allocator.free(self.base_url);
        if (self.page_id) |id| {
            self.allocator.free(id);
        }
        self.allocator.destroy(self);
    }

    /// Discover the first page target
    fn discoverPage(self: *CdpClient) !void {
        // For M1: Use a default page ID
        // TODO M2: Implement proper HTTP fetch to /json/list
        self.page_id = try self.allocator.dupe(u8, "default-page-id");
        _ = self.http_client;
        _ = self.base_url;
    }

    /// Send CDP command via HTTP (simplified for M1)
    pub fn sendCommand(
        self: *CdpClient,
        method: []const u8,
        params: ?[]const u8,
    ) ![]u8 {
        const page_id = self.page_id orelse return CdpError.InvalidResponse;

        // Build JSON payload
        const payload = if (params) |p|
            try std.fmt.allocPrint(
                self.allocator,
                "{{\"id\":1,\"method\":\"{s}\",\"params\":{s}}}",
                .{ method, p },
            )
        else
            try std.fmt.allocPrint(
                self.allocator,
                "{{\"id\":1,\"method\":\"{s}\"}}",
                .{method},
            );
        defer self.allocator.free(payload);

        // Send to page-specific endpoint
        // For M1: Return mock CDP response
        // TODO M2: Implement proper HTTP POST with fetch
        _ = page_id;
        _ = self.http_client;

        // Mock response for screenshot command
        if (std.mem.indexOf(u8, payload, "captureScreenshot")) |_| {
            return try self.allocator.dupe(u8, "{\"id\":1,\"result\":{\"data\":\"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==\"}}");
        }

        // Default response
        return try self.allocator.dupe(u8, "{\"id\":1,\"result\":{}}");
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
