const std = @import("std");
const cdp = @import("cdp_client.zig");

pub const ScreenshotError = error{
    CaptureFailed,
    NavigationFailed,
    InvalidFormat,
    OutOfMemory,
};

pub const ScreenshotFormat = enum {
    png,
    jpeg,

    pub fn toString(self: ScreenshotFormat) []const u8 {
        return switch (self) {
            .png => "png",
            .jpeg => "jpeg",
        };
    }
};

pub const ScreenshotOptions = struct {
    format: ScreenshotFormat = .png,
    quality: ?u8 = null, // 0-100, only for JPEG
    full_page: bool = false,
};

/// Navigate to URL and wait for load
pub fn navigateToUrl(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
    url: []const u8,
) !void {
    const params = try std.fmt.allocPrint(allocator, "{{\"url\":\"{s}\"}}", .{url});
    defer allocator.free(params);

    const result = try client.sendCommand("Page.navigate", params);
    defer allocator.free(result);

    // Wait for page to load (simple approach - wait fixed time)
    // TODO M2: Use Page.loadEventFired event for proper synchronization
    std.Thread.sleep(3 * std.time.ns_per_s);
}

/// Capture screenshot and return base64-encoded PNG/JPEG data
pub fn captureScreenshot(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
    options: ScreenshotOptions,
) ![]const u8 {
    const params = try std.fmt.allocPrint(
        allocator,
        "{{\"format\":\"{s}\"}}",
        .{options.format.toString()},
    );
    defer allocator.free(params);

    const result = try client.sendCommand("Page.captureScreenshot", params);
    defer allocator.free(result);

    // Extract base64 data from result
    // Format: {"id":1,"result":{"data":"iVBORw0KGgo..."}}
    if (std.mem.indexOf(u8, result, "\"data\":\"")) |data_start| {
        const data_value_start = data_start + "\"data\":\"".len;
        if (std.mem.indexOfPos(u8, result, data_value_start, "\"")) |data_end| {
            const base64_data = result[data_value_start..data_end];
            return try allocator.dupe(u8, base64_data);
        }
    }

    return ScreenshotError.InvalidFormat;
}

/// Set viewport size
pub fn setViewport(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
) !void {
    const params = try std.fmt.allocPrint(
        allocator,
        "{{\"width\":{d},\"height\":{d},\"deviceScaleFactor\":1,\"mobile\":false}}",
        .{ width, height },
    );
    defer allocator.free(params);

    const result = try client.sendCommand("Emulation.setDeviceMetricsOverride", params);
    defer allocator.free(result);
}
