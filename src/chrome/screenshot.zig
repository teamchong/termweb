const std = @import("std");
const config = @import("../config.zig").Config;
const cdp = @import("cdp_client.zig");
const interact = @import("interact.zig");
const json = @import("../utils/json.zig");

/// Check if mouse debug overlay is enabled (via TERMWEB_DEBUG_MOUSE=1)
fn isMouseDebugEnabled() bool {
    const val = std.process.getEnvVarOwned(std.heap.page_allocator, "TERMWEB_DEBUG_MOUSE") catch return false;
    defer std.heap.page_allocator.free(val);
    return std.mem.eql(u8, val, "1");
}

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
    quality: u8 = config.JPEG_QUALITY, // Lower quality = faster encode/transfer (0-100)
    full_page: bool = false,
    // Viewport dimensions for screencast (1:1 coordinate mapping)
    width: u32 = 1920,
    height: u32 = 1080,
    // Frame skip: 1=every frame, 2=every other frame (reduces bandwidth for video)
    every_nth_frame: u8 = 1,
};

fn logNav(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
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

/// Navigate to URL and wait for load
pub fn navigateToUrl(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
    url: []const u8,
) !void {
    // Non-blocking navigation - just send the command and return
    // CDP events (Page.frameNavigated, Page.loadEventFired) handle the rest
    return navigateToUrlAsync(client, allocator, url);
}

/// Navigate to URL without waiting - returns immediately after sending command
pub fn navigateToUrlAsync(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
    url: []const u8,
) !void {
    logNav("[NAV] navigateToUrlAsync() called with url: '{s}' (len={})\n", .{ url, url.len });

    // Normalize URL - add https:// if no protocol specified
    const has_protocol = std.mem.indexOf(u8, url, "://") != null;
    const normalized_url = if (has_protocol)
        url
    else
        try std.fmt.allocPrint(allocator, "https://{s}", .{url});
    defer if (normalized_url.ptr != url.ptr) allocator.free(normalized_url);

    logNav("[NAV] normalized_url: '{s}'\n", .{normalized_url});

    // Escape URL for JSON (handles quotes, backslashes in URLs)
    var escape_buf: [8192]u8 = undefined;
    const escaped_url = json.escapeContents(normalized_url, &escape_buf) catch return error.NavigationFailed;
    const params = try std.fmt.allocPrint(allocator, "{{\"url\":\"{s}\"}}", .{escaped_url});
    defer allocator.free(params);

    logNav("[NAV] sending Page.navigate with params: {s}\n", .{params});

    // Use dedicated nav WebSocket for Page.navigate
    const result = try client.sendNavCommand("Page.navigate", params);
    defer allocator.free(result);

    logNav("[NAV] Page.navigate result: {s}\n", .{result});
    // No waiting - CDP events will notify when page loads
}

/// Capture screenshot and return base64-encoded PNG/JPEG data
pub fn captureScreenshot(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
    options: ScreenshotOptions,
) ![]const u8 {
    // Inject JavaScript to force white background - use nav_ws (pipe is for screencast only)
    const js_params = "{\"expression\":\"document.body.style.backgroundColor = 'white'; document.documentElement.style.backgroundColor = 'white';\"}";
    const js_result = try client.sendNavCommand("Runtime.evaluate", js_params);
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
/// dpr: device pixel ratio (passed for compatibility but we use 1 to avoid Chrome scaling issues)
pub fn setViewport(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    dpr: u32,
) !void {
    _ = dpr; // Chrome's deviceScaleFactor causes viewport mismatch - use 1 instead
    const params = try std.fmt.allocPrint(
        allocator,
        "{{\"width\":{d},\"height\":{d},\"deviceScaleFactor\":1,\"mobile\":false}}",
        .{ width, height },
    );
    defer allocator.free(params);

    // Use nav_ws for viewport configuration (pipe is for screencast only)
    const result = try client.sendNavCommand("Emulation.setDeviceMetricsOverride", params);
    defer allocator.free(result);
}

/// Get Chrome's actual viewport dimensions via JavaScript
pub fn getActualViewport(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
) !struct { width: u32, height: u32 } {
    // Use nav_ws for Runtime.evaluate (pipe is for screencast only)
    const result = try client.sendNavCommand(
        "Runtime.evaluate",
        "{\"expression\":\"JSON.stringify({w:window.innerWidth,h:window.innerHeight})\",\"returnByValue\":true}",
    );
    defer allocator.free(result);

    // Debug: log raw response
    if (std.fs.createFileAbsolute("/tmp/viewport_debug.log", .{ .truncate = false })) |f| {
        f.seekFromEnd(0) catch {};
        _ = f.write(result) catch {};
        _ = f.write("\n") catch {};
        f.close();
    } else |_| {}

    // Parse result: {"id":N,"result":{"result":{"type":"string","value":"{\"w\":984,\"h\":1107}"}}}
    // Find the value field and extract w/h directly from result (avoid escaped quote issues)
    var width: u32 = 0;
    var height: u32 = 0;

    // Look for \"w\": pattern (escaped quotes in JSON string value)
    if (std.mem.indexOf(u8, result, "\\\"w\\\":")) |w_start| {
        const num_start = w_start + 6; // skip \"w\":
        var num_end = num_start;
        while (num_end < result.len and result[num_end] >= '0' and result[num_end] <= '9') : (num_end += 1) {}
        width = std.fmt.parseInt(u32, result[num_start..num_end], 10) catch 0;
    }

    if (std.mem.indexOf(u8, result, "\\\"h\\\":")) |h_start| {
        const num_start = h_start + 6; // skip \"h\":
        var num_end = num_start;
        while (num_end < result.len and result[num_end] >= '0' and result[num_end] <= '9') : (num_end += 1) {}
        height = std.fmt.parseInt(u32, result[num_start..num_end], 10) catch 0;
    }

    return .{ .width = width, .height = height };
}

/// Navigate back in browser history using Page.navigateToHistoryEntry
/// (Page.goBack was removed from Chrome DevTools Protocol)
/// Returns true if navigation happened, false if there was no history
pub fn goBack(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
) !bool {
    // Get current navigation history
    const history = try client.sendNavCommand("Page.getNavigationHistory", null);
    defer allocator.free(history);

    // Parse currentIndex and find the previous entry ID
    const current_index = parseCurrentIndex(history) orelse return false;
    if (current_index <= 0) return false;

    // Check if previous entry is about:blank (Chrome's initial page)
    // If so, don't navigate back to it
    if (isEntryAboutBlank(history, @intCast(current_index - 1))) {
        return false;
    }

    const target_entry_id = parseEntryIdAtIndex(history, @intCast(current_index - 1)) orelse return false;

    // Navigate to the previous entry
    const params = try std.fmt.allocPrint(allocator, "{{\"entryId\":{d}}}", .{target_entry_id});
    defer allocator.free(params);

    const result = client.sendNavCommand("Page.navigateToHistoryEntry", params) catch {
        return false;
    };
    defer allocator.free(result);
    // Non-blocking - CDP events handle load completion
    return true;
}

/// Navigate forward in browser history using Page.navigateToHistoryEntry
/// (Page.goForward was removed from Chrome DevTools Protocol)
/// Returns true if navigation happened, false if there was no history
pub fn goForward(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
) !bool {
    // Get current navigation history
    const history = try client.sendNavCommand("Page.getNavigationHistory", null);
    defer allocator.free(history);

    // Parse currentIndex and entry count, find the next entry ID
    const current_index = parseCurrentIndex(history) orelse return false;
    const entry_count = countEntries(history);
    if (current_index >= entry_count - 1) return false;

    const target_entry_id = parseEntryIdAtIndex(history, @intCast(current_index + 1)) orelse return false;

    // Navigate to the next entry
    const params = try std.fmt.allocPrint(allocator, "{{\"entryId\":{d}}}", .{target_entry_id});
    defer allocator.free(params);

    const result = client.sendNavCommand("Page.navigateToHistoryEntry", params) catch {
        return false;
    };
    defer allocator.free(result);
    // Non-blocking - CDP events handle load completion
    return true;
}

/// Parse currentIndex from navigation history response
fn parseCurrentIndex(history: []const u8) ?i32 {
    const marker = "\"currentIndex\":";
    const idx = std.mem.indexOf(u8, history, marker) orelse return null;
    const start = idx + marker.len;
    var end = start;
    while (end < history.len and (history[end] >= '0' and history[end] <= '9')) : (end += 1) {}
    if (end == start) return null;
    return std.fmt.parseInt(i32, history[start..end], 10) catch null;
}

/// Count number of entries in navigation history
fn countEntries(history: []const u8) i32 {
    var count: i32 = 0;
    const entries_start = std.mem.indexOf(u8, history, "\"entries\":[") orelse return 0;
    var pos = entries_start;
    while (std.mem.indexOfPos(u8, history, pos, "\"url\":")) |url_pos| {
        count += 1;
        pos = url_pos + 1;
    }
    return count;
}

/// Parse entry ID at a specific index in the entries array
/// Format: "entries":[{"id":2,...},{"id":7,...},...]
fn parseEntryIdAtIndex(history: []const u8, target_index: usize) ?i32 {
    const entries_marker = "\"entries\":[";
    const entries_start = std.mem.indexOf(u8, history, entries_marker) orelse return null;
    var pos = entries_start + entries_marker.len;

    var current_index: usize = 0;
    while (pos < history.len) {
        // Find next entry object start
        const obj_start = std.mem.indexOfPos(u8, history, pos, "{\"id\":") orelse break;

        if (current_index == target_index) {
            // Parse the ID value
            const id_start = obj_start + "{\"id\":".len;
            var id_end = id_start;
            while (id_end < history.len and (history[id_end] >= '0' and history[id_end] <= '9')) : (id_end += 1) {}
            if (id_end == id_start) return null;
            return std.fmt.parseInt(i32, history[id_start..id_end], 10) catch null;
        }

        current_index += 1;
        pos = obj_start + 1;
    }

    return null;
}

/// Check if entry at index is about:blank
fn isEntryAboutBlank(history: []const u8, target_index: usize) bool {
    const entries_marker = "\"entries\":[";
    const entries_start = std.mem.indexOf(u8, history, entries_marker) orelse return false;
    var pos = entries_start + entries_marker.len;

    var current_index: usize = 0;
    while (pos < history.len) {
        // Find next entry object start
        const obj_start = std.mem.indexOfPos(u8, history, pos, "{\"id\":") orelse break;

        if (current_index == target_index) {
            // Find the URL in this entry
            const url_marker = "\"url\":\"";
            const url_start_rel = std.mem.indexOfPos(u8, history, obj_start, url_marker) orelse return false;
            const url_start = url_start_rel + url_marker.len;
            const url_end = std.mem.indexOfPos(u8, history, url_start, "\"") orelse return false;
            const url = history[url_start..url_end];
            return std.mem.eql(u8, url, "about:blank");
        }

        current_index += 1;
        pos = obj_start + 1;
    }

    return false;
}

/// Reload current page - uses dedicated nav WebSocket
/// Note: Scroll reset is handled by viewer after navigation event
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
    // Non-blocking - CDP events handle load completion
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

    // Can go back if currentIndex > 0 AND previous entry is not about:blank
    var can_back = current_index > 0;
    if (can_back and current_index == 1) {
        // Check if entry[0] is about:blank
        if (isEntryAboutBlank(result, 0)) {
            can_back = false;
        }
    }

    return NavigationState{
        .can_go_back = can_back,
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
        options.every_nth_frame,
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
