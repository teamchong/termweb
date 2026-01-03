const std = @import("std");
const cdp = @import("cdp_client.zig");
const websocket_cdp = @import("websocket_cdp.zig");

/// Re-export ScreencastFrame for caller use
pub const ScreencastFrame = websocket_cdp.ScreencastFrame;

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
    quality: u8 = 80, // 0-100, for JPEG (ignored for PNG)
    full_page: bool = false,
    // Viewport dimensions for screencast (1:1 coordinate mapping)
    width: u32 = 1920,
    height: u32 = 1080,
};

/// Navigate to URL and wait for load
pub fn navigateToUrl(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
    url: []const u8,
) !void {
    // std.debug.print("[DEBUG] navigateToUrl() starting with url: {s}\n", .{url});

    // Normalize URL - add https:// if no protocol specified
    const has_protocol = std.mem.indexOf(u8, url, "://") != null;
    const normalized_url = if (has_protocol)
        url
    else
        try std.fmt.allocPrint(allocator, "https://{s}", .{url});
    defer if (normalized_url.ptr != url.ptr) allocator.free(normalized_url);

    std.debug.print("[DEBUG] navigateToUrl: {s}\n", .{normalized_url});

    const params = try std.fmt.allocPrint(allocator, "{{\"url\":\"{s}\"}}", .{normalized_url});
    defer allocator.free(params);

    // std.debug.print("[DEBUG] Sending Page.navigate command...\n", .{});
    const result = try client.sendCommand("Page.navigate", params);
    defer allocator.free(result);
    // std.debug.print("[DEBUG] Page.navigate response: {s}\n", .{result});

    // Wait for page to load (simple approach - wait fixed time)
    // TODO M2: Use Page.loadEventFired event for proper synchronization
    // std.debug.print("[DEBUG] Waiting 3 seconds for page load...\n", .{});
    std.Thread.sleep(3 * std.time.ns_per_s);
    // std.debug.print("[DEBUG] navigateToUrl() complete\n", .{});
}

/// Capture screenshot and return base64-encoded PNG/JPEG data
pub fn captureScreenshot(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
    options: ScreenshotOptions,
) ![]const u8 {
    // Inject JavaScript to force white background
    const js_params = "{\"expression\":\"document.body.style.backgroundColor = 'white'; document.documentElement.style.backgroundColor = 'white';\"}";
    const js_result = try client.sendCommand("Runtime.evaluate", js_params);
    defer allocator.free(js_result);

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
/// Returns true if navigation happened, false if there was no history
pub fn goBack(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
) !bool {
    const result = client.sendCommand("Page.goBack", null) catch {
        // No history to go back to
        return false;
    };
    defer allocator.free(result);

    // In screencast mode, new frames arrive automatically - no need to block
    return true;
}

/// Navigate forward in browser history
/// Returns true if navigation happened, false if there was no history
pub fn goForward(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
) !bool {
    const result = client.sendCommand("Page.goForward", null) catch {
        // No forward history
        return false;
    };
    defer allocator.free(result);

    // In screencast mode, new frames arrive automatically - no need to block
    return true;
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

    // In screencast mode, new frames arrive automatically - no need to block
}

/// Start screencast streaming (event-driven)
/// Pass exact viewport dimensions for 1:1 coordinate mapping (no scaling)
pub fn startScreencast(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
    options: ScreenshotOptions,
) !void {
    _ = allocator;
    return client.startScreencast(
        options.format.toString(),
        options.quality,
        options.width,
        options.height,
    );
}

/// Stop screencast streaming
pub fn stopScreencast(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
) !void {
    _ = allocator;
    return client.stopScreencast();
}

/// Get latest screencast frame (non-blocking)
/// Returns null if no new frame available
/// Caller MUST call frame.deinit() when done to free memory
pub fn getLatestScreencastFrame(
    client: *cdp.CdpClient,
) ?ScreencastFrame {
    return client.getLatestFrame();
}
