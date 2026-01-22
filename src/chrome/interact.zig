const std = @import("std");
const cdp = @import("cdp_client.zig");
const dom = @import("dom.zig");
const json = @import("../utils/json.zig");

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

    // Use nav_ws - pipe is for screencast only
    const result = try client.sendNavCommand("Runtime.evaluate", params);
    defer allocator.free(result);
}

/// Type text into focused element (fire-and-forget for low latency)
/// Type text into focused element - uses dedicated keyboard WS
pub fn typeText(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
    text: []const u8,
) !void {
    // Check if text contains newlines - use synthetic paste event for multi-line
    const has_newline = std.mem.indexOf(u8, text, "\n") != null;

    // Escape special characters for JSON
    var escape_buf: [65536]u8 = undefined;
    const escaped = json.escapeContents(text, &escape_buf) catch return;

    if (has_newline) {
        // Dispatch synthetic paste event - editors handle this without auto-indent
        // Clear _termwebClipboardData first so polyfill doesn't intercept
        const js = std.fmt.allocPrint(allocator,
            \\(function() {{
            \\  window._termwebClipboardData = '';
            \\  const el = document.activeElement;
            \\  if (!el) return false;
            \\  const dt = new DataTransfer();
            \\  dt.setData('text/plain', "{s}");
            \\  const evt = new ClipboardEvent('paste', {{
            \\    bubbles: true,
            \\    cancelable: true,
            \\    clipboardData: dt
            \\  }});
            \\  return el.dispatchEvent(evt);
            \\}})()
        , .{escaped}) catch return;
        defer allocator.free(js);

        var js_escape_buf: [131072]u8 = undefined;
        const js_escaped = json.escapeString(js, &js_escape_buf) catch return;

        var params_buf: [131072]u8 = undefined;
        const params = std.fmt.bufPrint(&params_buf, "{{\"expression\":{s}}}", .{js_escaped}) catch return;

        client.sendCommandAsync("Runtime.evaluate", params) catch {};
    } else {
        // Single line: use insertText directly
        const params = std.fmt.allocPrint(allocator, "{{\"text\":\"{s}\"}}", .{escaped}) catch return;
        defer allocator.free(params);
        client.sendKeyboardCommandAsync("Input.insertText", params);
    }
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

    const result = try client.sendNavCommand("Runtime.evaluate", params);
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

    const result = try client.sendNavCommand("Runtime.evaluate", params);
    defer allocator.free(result);
}

/// Inject clipboard interceptor - NO-OP, now handled by clipboard_polyfill.js
/// The polyfill is injected via Page.addScriptToEvaluateOnNewDocument in cdp_client.zig
/// and runs automatically in all frames (including iframes)
pub fn injectClipboardInterceptor(client: *cdp.CdpClient, allocator: std.mem.Allocator) !void {
    _ = client;
    _ = allocator;
    // No-op - clipboard interception is now handled by clipboard_polyfill.js
    // which is injected on all new documents via Page.addScriptToEvaluateOnNewDocument
}

/// Update browser's clipboard data (called in response to __TERMWEB_CLIPBOARD_REQUEST__)
/// Uses async command to avoid blocking/hanging on exit
/// Also increments version counter so JS polling knows data was updated
pub fn updateBrowserClipboard(client: *cdp.CdpClient, allocator: std.mem.Allocator, text: []const u8) !void {

    // Limit text size to avoid buffer overflow
    const max_len = 8000;
    const safe_text = if (text.len > max_len) text[0..max_len] else text;

    // Double-escape: first for JS string, then for JSON
    var js_escaped_buf: [16384]u8 = undefined;
    const js_escaped = json.escapeContents(safe_text, &js_escaped_buf) catch return;

    // Build JS: set data AND increment version so JS polling loop exits
    var js_buf: [32768]u8 = undefined;
    const js = std.fmt.bufPrint(&js_buf, "window._termwebClipboardData = \"{s}\"; window._termwebClipboardVersion++", .{js_escaped}) catch return;

    // Escape the entire JS for JSON expression field
    var json_escaped_buf: [65536]u8 = undefined;
    const json_escaped = json.escapeContents(js, &json_escaped_buf) catch return;

    // Build final params
    var params_buf: [131072]u8 = undefined;
    const params = std.fmt.bufPrint(&params_buf, "{{\"expression\":\"{s}\"}}", .{json_escaped}) catch return;

    // Use nav_ws synchronously to ensure clipboard is set before Cmd+V is sent
    // IMPORTANT: Don't use pipe for this - pipe is for screencast only
    const result = client.sendNavCommand("Runtime.evaluate", params) catch return;
    allocator.free(result);
}

/// Execute copy command via document.execCommand - triggers same flow as menu copy
/// This fires the copy event which our polyfill catches
pub fn execCopy(client: *cdp.CdpClient) void {
    const js = "document.execCommand('copy')";
    var params_buf: [256]u8 = undefined;
    const params = std.fmt.bufPrint(&params_buf, "{{\"expression\":\"{s}\"}}", .{js}) catch return;
    client.sendCommandAsync("Runtime.evaluate", params) catch {};
}

/// Execute cut command - dispatch Cmd+X keyboard event to active element
pub fn execCut(client: *cdp.CdpClient) void {
    const js =
        \\(function() {
        \\  const el = document.activeElement;
        \\  if (!el) return;
        \\  const evt = new KeyboardEvent('keydown', {
        \\    key: 'x', code: 'KeyX', keyCode: 88, which: 88,
        \\    metaKey: true, bubbles: true, cancelable: true
        \\  });
        \\  el.dispatchEvent(evt);
        \\  document.execCommand('cut');
        \\})()
    ;
    var params_buf: [512]u8 = undefined;
    const params = std.fmt.bufPrint(&params_buf, "{{\"expression\":\"{s}\"}}", .{js}) catch return;
    client.sendCommandAsync("Runtime.evaluate", params) catch {};
}

/// Clear browser's cached clipboard data - prevents polyfill from intercepting paste
pub fn clearBrowserClipboard(client: *cdp.CdpClient) void {
    const js = "window._termwebClipboardData = ''";
    var params_buf: [256]u8 = undefined;
    const params = std.fmt.bufPrint(&params_buf, "{{\"expression\":\"{s}\"}}", .{js}) catch return;
    client.sendCommandAsync("Runtime.evaluate", params) catch {};
}

/// Read text from browser's clipboard - tries polyfill cache first, then Clipboard API
/// Returns allocated string that caller must free, or null if failed
pub fn readBrowserClipboard(client: *cdp.CdpClient, allocator: std.mem.Allocator) ?[]const u8 {
    // First try our polyfill's cached data (works across frames)
    // Then fall back to original Clipboard API
    const js =
        \\(async function() {
        \\  try {
        \\    // Check all frames for _termwebClipboardData
        \\    if (window._termwebClipboardData) return window._termwebClipboardData;
        \\    try {
        \\      if (window.parent && window.parent._termwebClipboardData) return window.parent._termwebClipboardData;
        \\    } catch(e) {}
        \\    try {
        \\      if (window.top && window.top._termwebClipboardData) return window.top._termwebClipboardData;
        \\    } catch(e) {}
        \\    // Fall back to Clipboard API
        \\    if (window._termwebOrigReadText) {
        \\      return await window._termwebOrigReadText();
        \\    }
        \\    return await navigator.clipboard.readText();
        \\  } catch(e) {
        \\    return '';
        \\  }
        \\})()
    ;

    var js_escaped_buf: [2048]u8 = undefined;
    const js_escaped = json.escapeString(js, &js_escaped_buf) catch return null;

    var params_buf: [4096]u8 = undefined;
    const params = std.fmt.bufPrint(&params_buf, "{{\"expression\":{s},\"awaitPromise\":true,\"returnByValue\":true}}", .{js_escaped}) catch return null;

    const result = client.sendNavCommand("Runtime.evaluate", params) catch {
        return null;
    };
    defer allocator.free(result);

    // Parse result: {"id":N,"result":{"result":{"type":"string","value":"clipboard text"}}}
    // Look for "value":" pattern
    const value_marker = "\"value\":\"";
    const value_start = std.mem.indexOf(u8, result, value_marker) orelse return null;
    const text_start = value_start + value_marker.len;

    // Find closing quote (handle escaped quotes)
    var text_end = text_start;
    while (text_end < result.len) {
        if (result[text_end] == '"' and (text_end == text_start or result[text_end - 1] != '\\')) {
            break;
        }
        text_end += 1;
    }

    if (text_end <= text_start) return null;

    const clipboard_text = result[text_start..text_end];
    if (clipboard_text.len == 0) return null;

    // Unescape JSON string (handle \n, \t, \\, \", etc.)
    var unescaped = allocator.alloc(u8, clipboard_text.len) catch return null;
    var i: usize = 0;
    var j: usize = 0;
    while (i < clipboard_text.len) {
        if (clipboard_text[i] == '\\' and i + 1 < clipboard_text.len) {
            switch (clipboard_text[i + 1]) {
                'n' => {
                    unescaped[j] = '\n';
                    i += 2;
                },
                't' => {
                    unescaped[j] = '\t';
                    i += 2;
                },
                'r' => {
                    unescaped[j] = '\r';
                    i += 2;
                },
                '\\' => {
                    unescaped[j] = '\\';
                    i += 2;
                },
                '"' => {
                    unescaped[j] = '"';
                    i += 2;
                },
                else => {
                    unescaped[j] = clipboard_text[i];
                    i += 1;
                },
            }
        } else {
            unescaped[j] = clipboard_text[i];
            i += 1;
        }
        j += 1;
    }

    // Shrink to actual size
    const final = allocator.realloc(unescaped, j) catch {
        allocator.free(unescaped);
        return null;
    };
    return final;
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

    // Escape the text for JSON (handles quotes, backslashes)
    var escape_buf: [16]u8 = undefined;
    const escaped_text = json.escapeContents(text, &escape_buf) catch return;

    // windowsVirtualKeyCode (uppercase for A-Z, ASCII otherwise)
    const vk_code: u8 = if (char >= 'a' and char <= 'z') char - 32 else char;

    // If shortcut modifiers (Ctrl, Alt, Meta), send without text field to trigger shortcuts
    if (has_shortcut_mod) {
        var down_buf: [512]u8 = undefined;
        const down_params = std.fmt.bufPrint(&down_buf,
            "{{\"type\":\"keyDown\",\"key\":\"{s}\",\"code\":\"Key{c}\",\"windowsVirtualKeyCode\":{d},\"modifiers\":{d}}}",
            .{ escaped_text, std.ascii.toUpper(char), vk_code, modifiers }) catch return;

        var up_buf: [512]u8 = undefined;
        const up_params = std.fmt.bufPrint(&up_buf,
            "{{\"type\":\"keyUp\",\"key\":\"{s}\",\"code\":\"Key{c}\",\"windowsVirtualKeyCode\":{d},\"modifiers\":{d}}}",
            .{ escaped_text, std.ascii.toUpper(char), vk_code, modifiers }) catch return;

        client.sendKeyboardCommandAsync("Input.dispatchKeyEvent", down_params);
        client.sendKeyboardCommandAsync("Input.dispatchKeyEvent", up_params);
        return;
    }

    // Normal text input - use insertText to avoid auto-indent issues with paste
    var text_param_buf: [64]u8 = undefined;
    const text_params = std.fmt.bufPrint(&text_param_buf, "{{\"text\":\"{s}\"}}", .{escaped_text}) catch return;
    client.sendKeyboardCommandAsync("Input.insertText", text_params);
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
    // Escape key_name for JSON (handles any special chars)
    var escape_buf: [64]u8 = undefined;
    const escaped_key = json.escapeContents(key_name, &escape_buf) catch return;

    var down_buf: [256]u8 = undefined;
    const down_params = std.fmt.bufPrint(&down_buf, "{{\"type\":\"keyDown\",\"key\":\"{s}\",\"code\":\"{s}\",\"windowsVirtualKeyCode\":{d},\"modifiers\":{d}}}", .{ escaped_key, escaped_key, key_code, modifiers }) catch return;

    var up_buf: [256]u8 = undefined;
    const up_params = std.fmt.bufPrint(&up_buf, "{{\"type\":\"keyUp\",\"key\":\"{s}\",\"code\":\"{s}\",\"windowsVirtualKeyCode\":{d},\"modifiers\":{d}}}", .{ escaped_key, escaped_key, key_code, modifiers }) catch return;

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

    var escape_buf: [4096]u8 = undefined;
    for (files, 0..) |file, i| {
        if (i > 0) try files_json.append(allocator, ',');
        // Use escapeString which includes quotes and handles special chars
        const escaped = json.escapeString(file, &escape_buf) catch continue;
        try files_json.appendSlice(allocator, escaped);
    }
    try files_json.append(allocator, ']');

    const params = try std.fmt.allocPrint(
        allocator,
        "{{\"action\":\"accept\",\"files\":{s}}}",
        .{files_json.items},
    );
    defer allocator.free(params);

    const result = try client.sendNavCommand("Page.handleFileChooser", params);
    defer allocator.free(result);
}

/// Cancel intercepted file chooser dialog
pub fn cancelFileChooser(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
) !void {
    const result = try client.sendNavCommand("Page.handleFileChooser", "{\"action\":\"cancel\"}");
    defer allocator.free(result);
}
