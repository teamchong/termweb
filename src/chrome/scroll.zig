const std = @import("std");
const cdp = @import("cdp_client.zig");

/// Internal helper: Scroll by CDP mouse wheel event
/// deltaY negative = scroll down (page moves up)
/// deltaY positive = scroll up (page moves down)
fn scrollByDelta(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
    x: u32,
    y: u32,
    deltaY: i32,
) !void {
    const params = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"mouseWheel\",\"x\":{d},\"y\":{d},\"deltaX\":0,\"deltaY\":{d}}}",
        .{ x, y, deltaY },
    );
    defer allocator.free(params);

    const result = try client.sendCommand("Input.dispatchMouseEvent", params);
    defer allocator.free(result);

    // Small delay for browser to process wheel event
    std.Thread.sleep(50 * std.time.ns_per_ms);
}

/// Scroll down by one line (~20px)
pub fn scrollLineDown(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
    viewport_width: u32,
    viewport_height: u32,
) !void {
    const x = viewport_width / 2;
    const y = viewport_height / 2;
    try scrollByDelta(client, allocator, x, y, -20);
}

/// Scroll up by one line (~20px)
pub fn scrollLineUp(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
    viewport_width: u32,
    viewport_height: u32,
) !void {
    const x = viewport_width / 2;
    const y = viewport_height / 2;
    try scrollByDelta(client, allocator, x, y, 20);
}

/// Scroll down by half page
pub fn scrollHalfPageDown(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
    viewport_width: u32,
    viewport_height: u32,
) !void {
    const x = viewport_width / 2;
    const y = viewport_height / 2;
    const delta = -@as(i32, @intCast(viewport_height / 2));
    try scrollByDelta(client, allocator, x, y, delta);
}

/// Scroll up by half page
pub fn scrollHalfPageUp(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
    viewport_width: u32,
    viewport_height: u32,
) !void {
    const x = viewport_width / 2;
    const y = viewport_height / 2;
    const delta = @as(i32, @intCast(viewport_height / 2));
    try scrollByDelta(client, allocator, x, y, delta);
}

/// Scroll down by full page (leave 40px overlap for context)
pub fn scrollPageDown(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
    viewport_width: u32,
    viewport_height: u32,
) !void {
    const x = viewport_width / 2;
    const y = viewport_height / 2;
    const delta = -@as(i32, @intCast(viewport_height - 40));
    try scrollByDelta(client, allocator, x, y, delta);
}

/// Scroll up by full page (leave 40px overlap for context)
pub fn scrollPageUp(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
    viewport_width: u32,
    viewport_height: u32,
) !void {
    const x = viewport_width / 2;
    const y = viewport_height / 2;
    const delta = @as(i32, @intCast(viewport_height - 40));
    try scrollByDelta(client, allocator, x, y, delta);
}
