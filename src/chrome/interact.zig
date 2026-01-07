const std = @import("std");
const cdp = @import("cdp_client.zig");
const dom = @import("dom.zig");

/// Move mouse to coordinates (for hover effects) - fire and forget
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
    try client.sendCommandAsync("Input.dispatchMouseEvent", params);
}

/// Click at specific coordinates
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
    const move_result = try client.sendCommand("Input.dispatchMouseEvent", move_params);
    allocator.free(move_result);

    // Mouse pressed
    // buttons: 1 = left button
    const press_params = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"mousePressed\",\"x\":{d},\"y\":{d},\"button\":\"left\",\"buttons\":1,\"clickCount\":1,\"modifiers\":0}}",
        .{ x, y },
    );
    defer allocator.free(press_params);
    const press_result = try client.sendCommand("Input.dispatchMouseEvent", press_params);
    allocator.free(press_result);

    // Mouse released
    // buttons: 0 = none
    const release_params = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"mouseReleased\",\"x\":{d},\"y\":{d},\"button\":\"left\",\"buttons\":0,\"clickCount\":1,\"modifiers\":0}}",
        .{ x, y },
    );
    defer allocator.free(release_params);
    const release_result = try client.sendCommand("Input.dispatchMouseEvent", release_params);
    allocator.free(release_result);
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
pub fn typeText(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
    text: []const u8,
) !void {
    const params = try std.fmt.allocPrint(allocator, "{{\"text\":\"{s}\"}}", .{text});
    defer allocator.free(params);

    try client.sendCommandAsync("Input.insertText", params);
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

/// Send raw mouse event (synchronous for press/release, async for move)
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
    // Note: clickCount is only used for mousePressed/mouseReleased
    // modifiers: 0 = no modifiers (Alt=1, Ctrl=2, Meta/Cmd=4, Shift=8)
    // pointerType: mouse, pen, touch (default is mouse)
    const params = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"{s}\",\"x\":{d},\"y\":{d},\"button\":\"{s}\",\"buttons\":{d},\"clickCount\":{d},\"modifiers\":0,\"pointerType\":\"mouse\"}}",
        .{ event_type, x, y, button, buttons, click_count },
    );
    defer allocator.free(params);

    // Use synchronous send for press/release to ensure proper timing
    // Use async for move to avoid blocking
    const is_move = std.mem.eql(u8, event_type, "mouseMoved");
    if (is_move) {
        try client.sendCommandAsync("Input.dispatchMouseEvent", params);
    } else {
        const result = try client.sendCommand("Input.dispatchMouseEvent", params);
        allocator.free(result);
    }
}

/// Press Enter key (fire-and-forget for low latency)
pub fn pressEnter(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
) !void {
    _ = allocator;
    try client.sendCommandAsync(
        "Input.dispatchKeyEvent",
        "{\"type\":\"keyDown\",\"key\":\"Enter\"}",
    );
    try client.sendCommandAsync(
        "Input.dispatchKeyEvent",
        "{\"type\":\"keyUp\",\"key\":\"Enter\"}",
    );
}
