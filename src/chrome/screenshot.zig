const std = @import("std");
const cdp = @import("cdp_client.zig");

/// Re-export ScreencastFrame for caller use
pub const ScreencastFrame = cdp.ScreencastFrame;

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
    format: ScreenshotFormat = .jpeg,  // JPEG is faster to decode than PNG
    quality: u8 = 50, // Lower quality = faster encode/transfer (0-100)
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

    const params = try std.fmt.allocPrint(allocator, "{{\"url\":\"{s}\"}}", .{normalized_url});
    defer allocator.free(params);

    // Use dedicated nav WebSocket for Page.navigate
    const result = try client.sendNavCommand("Page.navigate", params);
    defer allocator.free(result);

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

/// Navigate back in browser history - uses dedicated nav WebSocket
/// Returns true if navigation happened, false if there was no history
pub fn goBack(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
) !bool {
    const result = client.sendNavCommand("Page.goBack", null) catch {
        // No history to go back to
        return false;
    };
    defer allocator.free(result);

    // In screencast mode, new frames arrive automatically - no need to block
    return true;
}

/// Navigate forward in browser history - uses dedicated nav WebSocket
/// Returns true if navigation happened, false if there was no history
pub fn goForward(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
) !bool {
    const result = client.sendNavCommand("Page.goForward", null) catch {
        // No forward history
        return false;
    };
    defer allocator.free(result);

    // In screencast mode, new frames arrive automatically - no need to block
    return true;
}

/// Reload current page - uses dedicated nav WebSocket
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

    const result = try client.sendNavCommand("Page.reload", params);
    defer allocator.free(result);

    // In screencast mode, new frames arrive automatically - no need to block
}

/// Stop page loading - uses dedicated nav WebSocket
pub fn stopLoading(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
) !void {
    const result = try client.sendNavCommand("Page.stopLoading", null);
    defer allocator.free(result);
}


/// Navigation history state
pub const NavigationState = struct {
    can_go_back: bool,
    can_go_forward: bool,
};

/// Get current navigation history state - uses dedicated nav WebSocket
pub fn getNavigationState(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
) !NavigationState {
    const result = try client.sendNavCommand("Page.getNavigationHistory", null);
    defer allocator.free(result);

    // Parse response: {"id":N,"result":{"currentIndex":X,"entries":[...]}}
    // Can go back if currentIndex > 0
    // Can go forward if currentIndex < entries.length - 1

    var current_index: i32 = 0;
    var entry_count: i32 = 0;

    // Find currentIndex
    if (std.mem.indexOf(u8, result, "\"currentIndex\":")) |idx| {
        const start = idx + "\"currentIndex\":".len;
        var end = start;
        while (end < result.len and (result[end] >= '0' and result[end] <= '9')) : (end += 1) {}
        if (end > start) {
            current_index = std.fmt.parseInt(i32, result[start..end], 10) catch 0;
        }
    }

    // Count entries by counting "url": occurrences in entries array
    if (std.mem.indexOf(u8, result, "\"entries\":[")) |entries_start| {
        var pos = entries_start;
        while (std.mem.indexOfPos(u8, result, pos, "\"url\":")) |url_pos| {
            entry_count += 1;
            pos = url_pos + 1;
        }
    }

    return NavigationState{
        .can_go_back = current_index > 0,
        .can_go_forward = current_index < entry_count - 1,
    };
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
