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

/// Inject mouse debug tracker - shows red dot where Chrome thinks mouse is
pub fn injectMouseDebugTracker(client: *cdp.CdpClient, allocator: std.mem.Allocator) !void {
    const js =
        \\(function() {
        \\  if (window._mouseDebugDot) return;
        \\  var dot = document.createElement('div');
        \\  dot.id = '_mouseDebugDot';
        \\  dot.style.cssText = 'position:fixed;width:10px;height:10px;background:red;border-radius:50%;pointer-events:none;z-index:999999;transform:translate(-50%,-50%)';
        \\  document.body.appendChild(dot);
        \\  window._mouseDebugDot = dot;
        \\  var info = document.createElement('div');
        \\  info.id = '_mouseDebugInfo';
        \\  info.style.cssText = 'position:fixed;top:0;left:0;background:rgba(0,0,0,0.8);color:lime;font:12px monospace;padding:4px 8px;z-index:999999;pointer-events:none';
        \\  info.textContent = 'VP:' + window.innerWidth + 'x' + window.innerHeight;
        \\  document.body.appendChild(info);
        \\  document.addEventListener('mousemove', function(e) {
        \\    dot.style.left = e.clientX + 'px';
        \\    dot.style.top = e.clientY + 'px';
        \\    info.textContent = 'VP:' + window.innerWidth + 'x' + window.innerHeight + ' M:' + e.clientX + ',' + e.clientY;
        \\  });
        \\})()
    ;

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
    sendCharWithModifiers(client, allocator, char, 0);
}

/// Apply shift mapping for US keyboard layout
fn applyShiftMapping(char: u8) u8 {
    if (char >= 'a' and char <= 'z') return char - 32; // A-Z
    return switch (char) {
        '1' => '!', '2' => '@', '3' => '#', '4' => '$', '5' => '%',
        '6' => '^', '7' => '&', '8' => '*', '9' => '(', '0' => ')',
        '-' => '_', '=' => '+', '[' => '{', ']' => '}', '\\' => '|',
        ';' => ':', '\'' => '"', ',' => '<', '.' => '>', '/' => '?', '`' => '~',
        else => char,
    };
}

/// Send a character to the browser with modifiers (for Cmd+A, Ctrl+C, etc.)
/// CDP requires: type, key, code, text, unmodifiedText, windowsVirtualKeyCode, modifiers
pub fn sendCharWithModifiers(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
    char: u8,
    modifiers: u8,
) void {
    _ = allocator;

    // CDP modifiers: 1=alt, 2=ctrl, 4=meta, 8=shift
    const has_shift = (modifiers & 8) != 0;
    const has_shortcut_mod = (modifiers & (1 | 2 | 4)) != 0; // alt, ctrl, or meta

    // text = what should appear (with shift applied)
    // unmodifiedText = what would appear without modifiers (except shift for letters)
    const text_char: u8 = if (has_shift) applyShiftMapping(char) else char;

    var text_buf: [2]u8 = .{ text_char, 0 };
    const text: []const u8 = text_buf[0..1];

    var unmod_buf: [2]u8 = .{ char, 0 };
    const unmodified_text: []const u8 = unmod_buf[0..1];

    // windowsVirtualKeyCode (uppercase for A-Z, ASCII otherwise)
    const vk_code: u8 = if (char >= 'a' and char <= 'z') char - 32 else char;

    // If shortcut modifiers (Ctrl, Alt, Meta), send without text field to trigger shortcuts
    if (has_shortcut_mod) {
        var down_buf: [512]u8 = undefined;
        const down_params = std.fmt.bufPrint(&down_buf,
            "{{\"type\":\"keyDown\",\"key\":\"{s}\",\"code\":\"Key{c}\",\"windowsVirtualKeyCode\":{d},\"modifiers\":{d}}}",
            .{ text, std.ascii.toUpper(char), vk_code, modifiers }) catch return;

        var up_buf: [512]u8 = undefined;
        const up_params = std.fmt.bufPrint(&up_buf,
            "{{\"type\":\"keyUp\",\"key\":\"{s}\",\"code\":\"Key{c}\",\"windowsVirtualKeyCode\":{d},\"modifiers\":{d}}}",
            .{ text, std.ascii.toUpper(char), vk_code, modifiers }) catch return;

        client.sendKeyboardCommandAsync("Input.dispatchKeyEvent", down_params);
        client.sendKeyboardCommandAsync("Input.dispatchKeyEvent", up_params);
        return;
    }

    // Normal text input - include all required fields
    var down_buf: [512]u8 = undefined;
    const down_params = std.fmt.bufPrint(&down_buf,
        "{{\"type\":\"keyDown\",\"key\":\"{s}\",\"code\":\"Key{c}\",\"text\":\"{s}\",\"unmodifiedText\":\"{s}\",\"windowsVirtualKeyCode\":{d},\"modifiers\":{d}}}",
        .{ text, std.ascii.toUpper(char), text, unmodified_text, vk_code, modifiers }) catch return;

    var up_buf: [512]u8 = undefined;
    const up_params = std.fmt.bufPrint(&up_buf,
        "{{\"type\":\"keyUp\",\"key\":\"{s}\",\"code\":\"Key{c}\",\"windowsVirtualKeyCode\":{d},\"modifiers\":{d}}}",
        .{ text, std.ascii.toUpper(char), vk_code, modifiers }) catch return;

    client.sendKeyboardCommandAsync("Input.dispatchKeyEvent", down_params);
    client.sendKeyboardCommandAsync("Input.dispatchKeyEvent", up_params);
}

/// Send Enter key with text property (needed for text editors like Monaco/VSCode)
pub fn sendEnterKey(
    client: *cdp.CdpClient,
    modifiers: u8,
) void {
    // keyDown (no text - char event handles text insertion)
    var down_buf: [256]u8 = undefined;
    const down_params = std.fmt.bufPrint(&down_buf, "{{\"type\":\"keyDown\",\"key\":\"Enter\",\"code\":\"Enter\",\"windowsVirtualKeyCode\":13,\"modifiers\":{d}}}", .{modifiers}) catch return;

    // char event for text input (this inserts the newline)
    var char_buf: [256]u8 = undefined;
    const char_params = std.fmt.bufPrint(&char_buf, "{{\"type\":\"char\",\"key\":\"Enter\",\"text\":\"\\r\",\"windowsVirtualKeyCode\":13,\"modifiers\":{d}}}", .{modifiers}) catch return;

    // keyUp
    var up_buf: [256]u8 = undefined;
    const up_params = std.fmt.bufPrint(&up_buf, "{{\"type\":\"keyUp\",\"key\":\"Enter\",\"code\":\"Enter\",\"windowsVirtualKeyCode\":13,\"modifiers\":{d}}}", .{modifiers}) catch return;

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
    sendSpecialKeyWithModifiers(client, key_name, key_code, 0);
}

/// Send a special key with modifiers (shift=8, ctrl=4, alt=2, meta=1 in CDP)
pub fn sendSpecialKeyWithModifiers(
    client: *cdp.CdpClient,
    key_name: []const u8,
    key_code: u16,
    modifiers: u8,
) void {
    var down_buf: [256]u8 = undefined;
    const down_params = std.fmt.bufPrint(&down_buf, "{{\"type\":\"keyDown\",\"key\":\"{s}\",\"code\":\"{s}\",\"windowsVirtualKeyCode\":{d},\"modifiers\":{d}}}", .{ key_name, key_name, key_code, modifiers }) catch return;

    var up_buf: [256]u8 = undefined;
    const up_params = std.fmt.bufPrint(&up_buf, "{{\"type\":\"keyUp\",\"key\":\"{s}\",\"code\":\"{s}\",\"windowsVirtualKeyCode\":{d},\"modifiers\":{d}}}", .{ key_name, key_name, key_code, modifiers }) catch return;

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
