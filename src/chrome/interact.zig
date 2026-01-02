const std = @import("std");
const cdp = @import("cdp_client.zig");
const dom = @import("dom.zig");

/// Click at specific coordinates
pub fn clickAt(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
    x: u32,
    y: u32,
) !void {
    // Mouse pressed
    const press_params = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"mousePressed\",\"x\":{d},\"y\":{d},\"button\":\"left\",\"clickCount\":1}}",
        .{ x, y },
    );
    defer allocator.free(press_params);

    const press_result = try client.sendCommand("Input.dispatchMouseEvent", press_params);
    defer allocator.free(press_result);

    // Small delay
    std.Thread.sleep(50 * std.time.ns_per_ms);

    // Mouse released
    const release_params = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"mouseReleased\",\"x\":{d},\"y\":{d},\"button\":\"left\",\"clickCount\":1}}",
        .{ x, y },
    );
    defer allocator.free(release_params);

    const release_result = try client.sendCommand("Input.dispatchMouseEvent", release_params);
    defer allocator.free(release_result);

    // Wait for potential navigation
    std.Thread.sleep(500 * std.time.ns_per_ms);
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

/// Type text into focused element
pub fn typeText(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
    text: []const u8,
) !void {
    const params = try std.fmt.allocPrint(allocator, "{{\"text\":\"{s}\"}}", .{text});
    defer allocator.free(params);

    const result = try client.sendCommand("Input.insertText", params);
    defer allocator.free(result);
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

/// Press Enter key
pub fn pressEnter(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
) !void {
    const down_result = try client.sendCommand(
        "Input.dispatchKeyEvent",
        "{{\"type\":\"keyDown\",\"key\":\"Enter\"}}",
    );
    defer allocator.free(down_result);

    const up_result = try client.sendCommand(
        "Input.dispatchKeyEvent",
        "{{\"type\":\"keyUp\",\"key\":\"Enter\"}}",
    );
    defer allocator.free(up_result);
}
