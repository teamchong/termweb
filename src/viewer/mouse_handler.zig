/// Mouse event handling for the viewer.
/// Handles mouse events, tab bar clicks, and cursor tracking.
const std = @import("std");
const input_mod = @import("../terminal/input.zig");
const terminal_mod = @import("../terminal/terminal.zig");
const coordinates_mod = @import("../terminal/coordinates.zig");
const screenshot_api = @import("../chrome/screenshot.zig");

const MouseEvent = input_mod.MouseEvent;
const CoordinateMapper = coordinates_mod.CoordinateMapper;

/// Handle mouse event - records to event bus and dispatches to mode-specific handlers
/// Throttling/prioritization is handled by the event bus (30fps tick)
pub fn handleMouse(viewer: anytype, mouse: MouseEvent) !void {
    // Normalize mouse coordinates:
    // - SGR 1006 (cell mode): 1-indexed, need to subtract 1
    // - SGR 1016 (pixel mode): 0-indexed, no adjustment needed
    const is_pixel = if (viewer.coord_mapper) |m| m.is_pixel_mode else false;
    const norm_x = if (is_pixel) mouse.x else if (mouse.x > 0) mouse.x - 1 else 0;
    const norm_y = if (is_pixel) mouse.y else if (mouse.y > 0) mouse.y - 1 else 0;

    // Track mouse position for cursor rendering
    viewer.mouse_x = norm_x;
    viewer.mouse_y = norm_y;
    viewer.mouse_visible = true;
    viewer.ui_dirty = true;

    // Log parsed mouse events (if enabled)
    if (viewer.debug_input) {
        viewer.log("[MOUSE] type={s} button={s} x={} y={} (raw={},{}) delta_y={}\n", .{
            @tagName(mouse.type),
            @tagName(mouse.button),
            norm_x,
            norm_y,
            mouse.x,
            mouse.y,
            mouse.delta_y,
        });
    }

    // Get viewport size for event bus
    const term_size = viewer.terminal.getSize() catch terminal_mod.TerminalSize{
        .cols = 80,
        .rows = 24,
        .width_px = 800,
        .height_px = 600,
    };

    // Update event bus coord mapper reference and record the event
    // The bus handles all throttling/prioritization and dispatches at 30fps
    if (viewer.coord_mapper) |*mapper| {
        viewer.event_bus.setCoordMapper(mapper);
    }
    viewer.mouse_buttons = viewer.event_bus.record(mouse, norm_x, norm_y, term_size.width_px, term_size.height_px);

    // Dispatch to mode-specific handlers (for local UI interactions only)
    switch (viewer.mode) {
        .normal => try handleMouseNormal(viewer, mouse),
        .url_prompt => {
            // Click outside URL bar cancels prompt and returns to normal mode
            if (mouse.type == .press) {
                if (viewer.toolbar_renderer) |*renderer| {
                    const mouse_pixels = mouseToPixels(viewer);
                    const in_url_bar = mouse_pixels.x >= renderer.url_bar_x and
                        mouse_pixels.x < renderer.url_bar_x + renderer.url_bar_width and
                        mouse_pixels.y <= renderer.toolbar_height;
                    if (!in_url_bar) {
                        renderer.blurUrl();
                        viewer.mode = .normal;
                        viewer.ui_dirty = true;
                    }
                }
            }
        },
    }
}

/// Handle click on tab bar buttons
pub fn handleTabBarClick(viewer: anytype, pixel_x: u32, pixel_y: u32, mapper: CoordinateMapper) !void {
    if (viewer.toolbar_renderer) |*renderer| {
        viewer.log("[CLICK] handleTabBarClick x={} y={}\n", .{ pixel_x, pixel_y });

        if (renderer.hitTest(pixel_x, pixel_y)) |button| {
            viewer.log("[CLICK] Button hit: {}\n", .{button});

            switch (button) {
                .back => {
                    viewer.log("[CLICK] Back button (can_back={})\n", .{viewer.ui_state.can_go_back});
                    // Always try to go back even if state says no (state might be stale)
                    _ = screenshot_api.goBack(viewer.cdp_client, viewer.allocator) catch |err| {
                        viewer.log("[CLICK] Back failed: {}\n", .{err});
                        return; // Don't update UI state if command failed
                    };
                    // Optimistic update only on success
                    viewer.ui_state.can_go_forward = true;
                    viewer.ui_dirty = true;
                },
                .forward => {
                    viewer.log("[CLICK] Forward button\n", .{});
                    if (viewer.ui_state.can_go_forward) {
                        _ = screenshot_api.goForward(viewer.cdp_client, viewer.allocator) catch |err| {
                            viewer.log("[CLICK] Forward failed: {}\n", .{err});
                            return; // Don't update UI state if command failed
                        };
                        viewer.ui_state.can_go_back = true;
                        viewer.ui_dirty = true;
                    }
                },
                .refresh => {
                    viewer.log("[CLICK] Refresh button (loading={})\n", .{viewer.ui_state.is_loading});
                    if (viewer.ui_state.is_loading) {
                        // Stop loading if currently loading
                        viewer.log("[CLICK] Sending stop command\n", .{});
                        screenshot_api.stopLoading(viewer.cdp_client, viewer.allocator) catch |err| {
                            viewer.log("[CLICK] Stop failed: {}\n", .{err});
                            return;
                        };
                        viewer.ui_state.is_loading = false;
                        if (viewer.toolbar_renderer) |*tr| {
                            tr.is_loading = false;
                        }
                    } else {
                        // Reload if not loading
                        viewer.log("[CLICK] Sending reload command\n", .{});
                        _ = screenshot_api.reload(viewer.cdp_client, viewer.allocator, true) catch |err| {
                            viewer.log("[CLICK] Reload failed: {}\n", .{err});
                            return;
                        };
                        viewer.ui_state.is_loading = true;
                        if (viewer.toolbar_renderer) |*tr| {
                            tr.is_loading = true;
                        }
                        viewer.loading_started_at = std.time.nanoTimestamp();
                    }
                    viewer.ui_dirty = true;
                },
                .close => {
                    viewer.log("[CLICK] Close button\n", .{});
                    viewer.running = false;
                },
                .tabs => {
                    viewer.log("[CLICK] Tabs button\n", .{});
                    viewer.showTabPicker() catch |err| {
                        viewer.log("[CLICK] Tab picker failed: {}\n", .{err});
                    };
                },
            }
            return;
        }

        // Check if click is in URL bar area
        if (pixel_x >= renderer.url_bar_x and pixel_x < renderer.url_bar_x + renderer.url_bar_width) {
            viewer.log("[TABBAR] URL bar clicked\n", .{});
            renderer.focusUrl();
            viewer.mode = .url_prompt;
            viewer.ui_dirty = true;
            return;
        }
    }

    // Calculate cell width for button positions
    const cell_width: u16 = if (mapper.terminal_cols > 0)
        mapper.terminal_width_px / mapper.terminal_cols
    else
        14;

    // Convert pixel X to column (0-indexed)
    const col: i32 = @intCast(pixel_x / cell_width);

    viewer.log("[TABBAR] Click at pixel_x={}, pixel_y={}, cell_width={}, col={}\n", .{ pixel_x, pixel_y, cell_width, col });

    // Fallback: column-based detection
    if (col <= 2) {
        viewer.running = false;
    } else if (col >= 4 and col <= 6 and viewer.ui_state.can_go_back) {
        _ = try screenshot_api.goBack(viewer.cdp_client, viewer.allocator);
        viewer.updateNavigationState();
    } else if (col >= 8 and col <= 10 and viewer.ui_state.can_go_forward) {
        _ = try screenshot_api.goForward(viewer.cdp_client, viewer.allocator);
        viewer.updateNavigationState();
    } else if (col >= 12 and col <= 14) {
        try screenshot_api.reload(viewer.cdp_client, viewer.allocator, false);
    } else if (col >= 18) {
        viewer.mode = .url_prompt;
        if (viewer.toolbar_renderer) |*renderer| {
            renderer.focusUrl();
        }
        viewer.ui_dirty = true;
    }
}

/// Handle mouse event in normal mode - local UI interactions only
/// CDP dispatch is handled by the event bus (30fps tick)
pub fn handleMouseNormal(viewer: anytype, mouse: MouseEvent) !void {
    const mapper = viewer.coord_mapper orelse return;

    switch (mouse.type) {
        .press => {
            // Check if click is in browser area or tab bar
            if (mapper.terminalToBrowser(viewer.mouse_x, viewer.mouse_y)) |coords| {
                // Store click info for status line display
                if (mouse.button == .left) {
                    viewer.last_click = .{
                        .term_x = viewer.mouse_x,
                        .term_y = viewer.mouse_y,
                        .browser_x = coords.x,
                        .browser_y = coords.y,
                    };
                    // Update navigation state (click may have navigated)
                    viewer.updateNavigationState();
                }
            } else {
                // Click is in tab bar - handle button clicks locally
                // We handle this on PRESS for immediate feedback (like most UI buttons)
                const mouse_pixels = mouseToPixels(viewer);
                viewer.log("[CLICK] In tab bar: mouse=({},{}) pixels=({},{}) tabbar_height={} is_pixel_mode={}\n", .{
                    viewer.mouse_x, viewer.mouse_y, mouse_pixels.x, mouse_pixels.y, mapper.tabbar_height, mapper.is_pixel_mode,
                });
                try handleTabBarClick(viewer, mouse_pixels.x, mouse_pixels.y, mapper);
            }
        },
        .release => {
            // No local UI handling needed for release
        },
        .move, .drag => {
            // Check if mouse is hovering over toolbar buttons (local UI)
            if (viewer.toolbar_renderer) |*renderer| {
                // Track previous hover states
                const old_close = renderer.close_hover;
                const old_back = renderer.back_hover;
                const old_forward = renderer.forward_hover;
                const old_refresh = renderer.refresh_hover;
                const old_tabs = renderer.tabs_hover;
                const old_url = renderer.url_bar_hover;

                // Reset all hover states
                renderer.close_hover = false;
                renderer.back_hover = false;
                renderer.forward_hover = false;
                renderer.refresh_hover = false;
                renderer.tabs_hover = false;
                renderer.url_bar_hover = false;

                // Set hover for the button under cursor
                const mouse_pixels = mouseToPixels(viewer);
                if (renderer.hitTest(mouse_pixels.x, mouse_pixels.y)) |button| {
                    switch (button) {
                        .close => renderer.close_hover = true,
                        .back => renderer.back_hover = true,
                        .forward => renderer.forward_hover = true,
                        .refresh => renderer.refresh_hover = true,
                        .tabs => renderer.tabs_hover = true,
                    }
                } else if (mouse_pixels.y < renderer.toolbar_height) {
                    // Check URL bar hover (within toolbar area)
                    if (mouse_pixels.x >= renderer.url_bar_x and
                        mouse_pixels.x < renderer.url_bar_x + renderer.url_bar_width)
                    {
                        renderer.url_bar_hover = true;
                    }
                }

                // Re-render toolbar if any hover state changed
                if (renderer.close_hover != old_close or
                    renderer.back_hover != old_back or
                    renderer.forward_hover != old_forward or
                    renderer.refresh_hover != old_refresh or
                    renderer.tabs_hover != old_tabs or
                    renderer.url_bar_hover != old_url)
                {
                    viewer.ui_dirty = true;
                }
            }
        },
        .wheel => {
            // Wheel events are fully handled by the event bus
        },
    }
}

/// Convert mouse coordinates to pixel coordinates for toolbar hit testing.
/// When terminal is in cell mode (not pixel mode), converts cell coordinates to pixels.
pub fn mouseToPixels(viewer: anytype) struct { x: u32, y: u32 } {
    const mapper = viewer.coord_mapper orelse return .{ .x = viewer.mouse_x, .y = viewer.mouse_y };

    if (mapper.is_pixel_mode) {
        // Already in pixel coordinates
        return .{ .x = viewer.mouse_x, .y = viewer.mouse_y };
    }

    // Convert cell coordinates to pixel coordinates
    const cell_width: u32 = if (mapper.terminal_cols > 0)
        mapper.terminal_width_px / mapper.terminal_cols
    else
        14;
    const cell_height: u32 = mapper.cell_height;

    // Convert cell to pixel (top-left of cell)
    const pixel_x: u32 = @as(u32, viewer.mouse_x) * cell_width;
    const pixel_y: u32 = @as(u32, viewer.mouse_y) * cell_height;

    return .{ .x = pixel_x, .y = pixel_y };
}
