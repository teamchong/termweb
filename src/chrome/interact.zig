const std = @import("std");
const cdp = @import("cdp_client.zig");
const dom = @import("dom.zig");

/// Debug log file for CDP interactions
var debug_log_file: ?std.fs.File = null;

pub fn initDebugLog() void {
    debug_log_file = std.fs.cwd().createFile("/tmp/termweb-mouse.log", .{ .truncate = true }) catch null;
    if (debug_log_file) |f| {
        f.writeAll("=== termweb mouse debug log ===\n") catch {};
    }
}

pub fn deinitDebugLog() void {
    if (debug_log_file) |f| {
        f.close();
        debug_log_file = null;
    }
}

fn debugLog(comptime fmt: []const u8, args: anytype) void {
    if (debug_log_file) |f| {
        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
        f.writeAll(msg) catch {};
        f.sync() catch {};
    }
}

/// Move mouse to coordinates (for hover effects) - fire and forget via dedicated mouse WS
pub fn mouseMove(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
    x: u32,
    y: u32,
) !void {
    const params = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"mouseMoved\",\"x\":{d},\"y\":{d},\"buttons\":0,\"modifiers\":0}}",
        .{ x, y },
    );
    defer allocator.free(params);
    client.sendMouseCommandAsync("Input.dispatchMouseEvent", params);
}

/// Click at specific coordinates - uses dedicated mouse WebSocket
pub fn clickAt(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
    x: u32,
    y: u32,
) !void {
    // First move mouse to position (some pages require hover before click)
    const move_params = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"mouseMoved\",\"x\":{d},\"y\":{d},\"buttons\":0,\"modifiers\":0}}",
        .{ x, y },
    );
    defer allocator.free(move_params);
    client.sendMouseCommandAsync("Input.dispatchMouseEvent", move_params);

    // Mouse pressed
    // buttons: 1 = left button
    const press_params = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"mousePressed\",\"x\":{d},\"y\":{d},\"button\":\"left\",\"buttons\":1,\"clickCount\":1,\"modifiers\":0}}",
        .{ x, y },
    );
    defer allocator.free(press_params);
    client.sendMouseCommandAsync("Input.dispatchMouseEvent", press_params);

    // Mouse released
    // buttons: 0 = none
    const release_params = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"mouseReleased\",\"x\":{d},\"y\":{d},\"button\":\"left\",\"buttons\":0,\"clickCount\":1,\"modifiers\":0}}",
        .{ x, y },
    );
    defer allocator.free(release_params);
    client.sendMouseCommandAsync("Input.dispatchMouseEvent", release_params);
}

/// Click on an element (center of bounding box)
pub fn clickElement(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
    element: *const dom.InteractiveElement,
) !void {
    const center_x = element.x + (element.width / 2);
    const center_y = element.y + (element.height / 2);
    try clickAt(client, allocator, center_x, center_y);
}

/// Focus an element using JavaScript
pub fn focusElement(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
    selector: []const u8,
) !void {
    const js = try std.fmt.allocPrint(
        allocator,
        "document.querySelector('{s}').focus()",
        .{selector},
    );
    defer allocator.free(js);

    const params = try std.fmt.allocPrint(allocator, "{{\"expression\":\"{s}\"}}", .{js});
    defer allocator.free(params);

    const result = try client.sendCommand("Runtime.evaluate", params);
    defer allocator.free(result);
}

/// Type text into focused element (fire-and-forget for low latency)
/// Type text into focused element - uses dedicated keyboard WS
pub fn typeText(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
    text: []const u8,
) !void {
    const params = try std.fmt.allocPrint(allocator, "{{\"text\":\"{s}\"}}", .{text});
    defer allocator.free(params);

    client.sendKeyboardCommandAsync("Input.insertText", params);
}

/// Toggle checkbox using JavaScript
pub fn toggleCheckbox(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
    selector: []const u8,
) !void {
    const js = try std.fmt.allocPrint(
        allocator,
        "document.querySelector('{s}').click()",
        .{selector},
    );
    defer allocator.free(js);

    const params = try std.fmt.allocPrint(allocator, "{{\"expression\":\"{s}\"}}", .{js});
    defer allocator.free(params);

    const result = try client.sendCommand("Runtime.evaluate", params);
    defer allocator.free(result);
}

/// Send raw mouse event - fire-and-forget via dedicated mouse WebSocket
/// Click sequence (HIGH PRIORITY - never throttled):
///   1. mouseMoved (triggers CSS :hover, JS mouseenter)
///   2. mousePressed (sets active state)
///   3. mouseReleased (fires click event)
/// This bypasses viewer-level move throttling - clicks always complete immediately.
pub fn sendMouseEvent(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
    event_type: []const u8, // "mousePressed", "mouseReleased", "mouseMoved"
    x: u32,
    y: u32,
    button: []const u8,    // "left", "middle", "right", "none"
    buttons: u32,         // Bitmask: 1=left, 2=right, 4=middle
    click_count: u32,
) !void {
    debugLog("[MOUSE] sendMouseEvent: type={s} x={d} y={d} button={s} buttons={d} clickCount={d}\n", .{
        event_type, x, y, button, buttons, click_count
    });

    // CRITICAL: For mousePressed, send mouseMoved first to trigger hover states.
    // This is part of the click sequence (HIGH PRIORITY) - not subject to move throttling.
    // Without this, complex UIs (React/Vue/Canvas) may ignore the click.
    if (std.mem.eql(u8, event_type, "mousePressed")) {
        const move_params = try std.fmt.allocPrint(
            allocator,
            "{{\"type\":\"mouseMoved\",\"x\":{d},\"y\":{d},\"button\":\"none\",\"buttons\":0,\"modifiers\":0,\"pointerType\":\"mouse\"}}",
            .{ x, y },
        );
        defer allocator.free(move_params);
        debugLog("[MOUSE] mouseMoved (pre-click): {s}\n", .{move_params});
        client.sendMouseCommandAsync("Input.dispatchMouseEvent", move_params);
    }

    // Note: clickCount is only used for mousePressed/mouseReleased
    // modifiers: 0 = no modifiers (Alt=1, Ctrl=2, Meta/Cmd=4, Shift=8)
    // pointerType: mouse, pen, touch (default is mouse)
    const params = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"{s}\",\"x\":{d},\"y\":{d},\"button\":\"{s}\",\"buttons\":{d},\"clickCount\":{d},\"modifiers\":0,\"pointerType\":\"mouse\"}}",
        .{ event_type, x, y, button, buttons, click_count },
    );
    defer allocator.free(params);

    debugLog("[MOUSE] Sending: {s}\n", .{params});

    // All mouse events go through dedicated mouse websocket (fire-and-forget for low latency)
    client.sendMouseCommandAsync("Input.dispatchMouseEvent", params);
}

/// Press Enter key (fire-and-forget for low latency) - uses dedicated keyboard WS
pub fn pressEnter(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
) void {
    _ = allocator;
    client.sendKeyboardCommandAsync(
        "Input.dispatchKeyEvent",
        "{\"type\":\"keyDown\",\"key\":\"Enter\",\"code\":\"Enter\",\"windowsVirtualKeyCode\":13}",
    );
    client.sendKeyboardCommandAsync(
        "Input.dispatchKeyEvent",
        "{\"type\":\"keyUp\",\"key\":\"Enter\",\"code\":\"Enter\",\"windowsVirtualKeyCode\":13}",
    );
}

/// Send a character key to the browser (keyDown + char + keyUp)
pub fn sendChar(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
    char: u8,
) void {
    var key_buf: [2]u8 = .{ char, 0 };
    const key: []const u8 = key_buf[0..1];

    // Get key code (uppercase for A-Z)
    const code: u8 = if (char >= 'a' and char <= 'z')
        char - 32 // Convert to uppercase for keyCode
    else
        char;

    // Format keyDown event
    var down_buf: [256]u8 = undefined;
    const down_params = std.fmt.bufPrint(&down_buf, "{{\"type\":\"keyDown\",\"key\":\"{s}\",\"text\":\"{s}\",\"windowsVirtualKeyCode\":{d}}}", .{ key, key, code }) catch return;

    // Format char event (for text input)
    var char_buf: [256]u8 = undefined;
    const char_params = std.fmt.bufPrint(&char_buf, "{{\"type\":\"char\",\"key\":\"{s}\",\"text\":\"{s}\",\"windowsVirtualKeyCode\":{d}}}", .{ key, key, code }) catch return;

    // Format keyUp event
    var up_buf: [256]u8 = undefined;
    const up_params = std.fmt.bufPrint(&up_buf, "{{\"type\":\"keyUp\",\"key\":\"{s}\",\"windowsVirtualKeyCode\":{d}}}", .{ key, code }) catch return;

    _ = allocator;
    client.sendKeyboardCommandAsync("Input.dispatchKeyEvent", down_params);
    client.sendKeyboardCommandAsync("Input.dispatchKeyEvent", char_params);
    client.sendKeyboardCommandAsync("Input.dispatchKeyEvent", up_params);
}

/// Send a special key to the browser (Escape, Backspace, Tab, Arrow keys, etc.)
pub fn sendSpecialKey(
    client: *cdp.CdpClient,
    key_name: []const u8,
    key_code: u16,
) void {
    var down_buf: [256]u8 = undefined;
    const down_params = std.fmt.bufPrint(&down_buf, "{{\"type\":\"keyDown\",\"key\":\"{s}\",\"code\":\"{s}\",\"windowsVirtualKeyCode\":{d}}}", .{ key_name, key_name, key_code }) catch return;

    var up_buf: [256]u8 = undefined;
    const up_params = std.fmt.bufPrint(&up_buf, "{{\"type\":\"keyUp\",\"key\":\"{s}\",\"code\":\"{s}\",\"windowsVirtualKeyCode\":{d}}}", .{ key_name, key_name, key_code }) catch return;

    client.sendKeyboardCommandAsync("Input.dispatchKeyEvent", down_params);
    client.sendKeyboardCommandAsync("Input.dispatchKeyEvent", up_params);
}

/// Handle intercepted file chooser dialog
pub fn handleFileChooser(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
    files: []const []const u8,
) !void {
    // Page.handleFileChooser
    // action: accept, cancel, fallback
    // files: (Optional) Array of strings, filenames to set.

    var files_json = std.ArrayList(u8).initCapacity(allocator, 0) catch return error.OutOfMemory;
    defer files_json.deinit(allocator);
    try files_json.append(allocator, '[');
    for (files, 0..) |file, i| {
        if (i > 0) try files_json.append(allocator, ',');
        try files_json.append(allocator, '"');
        try files_json.appendSlice(allocator, file);
        try files_json.append(allocator, '"');
    }
    try files_json.append(allocator, ']');

    const params = try std.fmt.allocPrint(
        allocator,
        "{{\"action\":\"accept\",\"files\":{s}}}",
        .{files_json.items},
    );
    defer allocator.free(params);

    const result = try client.sendCommand("Page.handleFileChooser", params);
    defer allocator.free(result);
}

/// Cancel intercepted file chooser dialog
pub fn cancelFileChooser(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
) !void {
    const result = try client.sendCommand("Page.handleFileChooser", "{\"action\":\"cancel\"}");
    defer allocator.free(result);
}
