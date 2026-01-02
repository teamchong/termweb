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
    std.debug.print("[DEBUG] navigateToUrl() starting with url: {s}\n", .{url});

    // Normalize URL - add https:// if no protocol specified
    const normalized_url = if (std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://"))
        url
    else
        try std.fmt.allocPrint(allocator, "https://{s}", .{url});
    defer if (normalized_url.ptr != url.ptr) allocator.free(normalized_url);

    std.debug.print("[DEBUG] Normalized URL: {s}\n", .{normalized_url});

    const params = try std.fmt.allocPrint(allocator, "{{\"url\":\"{s}\"}}", .{normalized_url});
    defer allocator.free(params);

    std.debug.print("[DEBUG] Sending Page.navigate command...\n", .{});
    const result = try client.sendCommand("Page.navigate", params);
    defer allocator.free(result);
    std.debug.print("[DEBUG] Page.navigate response: {s}\n", .{result});

    // Wait for page to load (simple approach - wait fixed time)
    // TODO M2: Use Page.loadEventFired event for proper synchronization
    std.debug.print("[DEBUG] Waiting 3 seconds for page load...\n", .{});
    std.Thread.sleep(3 * std.time.ns_per_s);
    std.debug.print("[DEBUG] navigateToUrl() complete\n", .{});
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

/// Navigate back in browser history
pub fn goBack(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
) !void {
    const result = try client.sendCommand("Page.goBack", null);
    defer allocator.free(result);

    // Wait for navigation (temporary - M3 will use events)
    std.Thread.sleep(1 * std.time.ns_per_s);
}

/// Navigate forward in browser history
pub fn goForward(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
) !void {
    const result = try client.sendCommand("Page.goForward", null);
    defer allocator.free(result);

    std.Thread.sleep(1 * std.time.ns_per_s);
}

/// Reload current page
pub fn reload(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
    ignore_cache: bool,
) !void {
    const params = try std.fmt.allocPrint(
        allocator,
        "{{\"ignoreCache\":{s}}}",
        .{if (ignore_cache) "true" else "false"},
    );
    defer allocator.free(params);

    const result = try client.sendCommand("Page.reload", params);
    defer allocator.free(result);

    std.Thread.sleep(2 * std.time.ns_per_s);
}
