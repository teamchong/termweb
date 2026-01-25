/// Tab management for the viewer.
/// Handles tab creation, switching, and the tab picker dialog.
const std = @import("std");
const config = @import("../config.zig").Config;
const screenshot_api = @import("../chrome/screenshot.zig");
const ui_mod = @import("../ui/mod.zig");
const dialog_mod = ui_mod.dialog;

/// Add a new tab to the tabs list
pub fn addTab(viewer: anytype, target_id: []const u8, url: []const u8, title: []const u8) !void {
    const tab = try ui_mod.Tab.init(viewer.allocator, target_id, url, title);
    try viewer.tabs.append(viewer.allocator, tab);

    if (viewer.toolbar_renderer) |*renderer| {
        renderer.setTabCount(@intCast(viewer.tabs.items.len));
    }
    viewer.ui_dirty = true;

    viewer.log("[TABS] Added tab: url={s}, total={}\n", .{ url, viewer.tabs.items.len });
}

/// Show native tab picker dialog
pub fn showTabPicker(viewer: anytype) !void {
    if (viewer.tabs.items.len == 0) {
        viewer.log("[TABS] No tabs to show\n", .{});
        return;
    }

    var tab_titles = try std.ArrayList([]const u8).initCapacity(viewer.allocator, viewer.tabs.items.len);
    defer tab_titles.deinit(viewer.allocator);

    for (viewer.tabs.items, 0..) |tab, i| {
        var title_buf: [256]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "{d}. {s}", .{
            i + 1,
            if (tab.title.len > 0) tab.title else tab.url,
        }) catch continue;

        const title_copy = try viewer.allocator.dupe(u8, title);
        try tab_titles.append(viewer.allocator, title_copy);
    }
    defer {
        for (tab_titles.items) |t| viewer.allocator.free(t);
    }

    viewer.log("[TABS] Showing picker with {} tabs, current={}\n", .{ tab_titles.items.len, viewer.active_tab_index });

    const selected = try dialog_mod.showNativeListPicker(
        viewer.allocator,
        "Select Tab",
        tab_titles.items,
        viewer.active_tab_index, // Pre-select current tab
    );

    if (selected) |index| {
        viewer.log("[TABS] Selected tab {}, requesting deferred switch\n", .{index});
        viewer.requestTabSwitch(index);
    }
}

const render_mod = @import("render.zig");

/// Clear the content area (delete main content image)
/// Call this when switching tabs to avoid stale content showing
fn clearContentArea(viewer: anytype) void {
    // Delete content image (ID 100) to clear previous page
    const stdout = std.fs.File.stdout();
    _ = stdout.write("\x1b_Ga=d,d=i,i=100\x1b\\") catch {};
    viewer.last_content_image_id = null;
    viewer.last_rendered_generation = 0; // Reset generation to accept new frames
}

/// Check if URL is a blank/empty page that won't stream content
fn isBlankPage(url: []const u8) bool {
    return std.mem.eql(u8, url, "about:blank") or
        std.mem.eql(u8, url, "about:newtab") or
        std.mem.eql(u8, url, "chrome://newtab/") or
        url.len == 0;
}

/// Switch to a different tab
pub fn switchToTab(viewer: anytype, index: usize) !void {
    if (index >= viewer.tabs.items.len) return;

    viewer.active_tab_index = index;
    const tab = viewer.tabs.items[index];

    viewer.log("[TABS] Switching to tab {}: {s} (target={s})\n", .{ index, tab.url, tab.target_id });

    // For blank pages, render placeholder; otherwise clear for new content
    if (isBlankPage(tab.url)) {
        render_mod.renderBlankPage(viewer);
        // Note: renderBlankPage sets showing_blank_placeholder = true
    } else {
        clearContentArea(viewer);
        viewer.showing_blank_placeholder = false;
    }

    // Note: stopScreencast skipped - starting new screencast implicitly handles it
    // This saves ~50-100ms of blocking time

    viewer.cdp_client.switchToTarget(tab.target_id) catch |err| {
        viewer.log("[TABS] switchToTarget failed: {}, falling back to navigation\n", .{err});
        _ = try screenshot_api.navigateToUrl(viewer.cdp_client, viewer.allocator, tab.url);
    };

    // Set viewport and start screencast on new tab
    screenshot_api.setViewport(viewer.cdp_client, viewer.allocator, viewer.viewport_width, viewer.viewport_height, viewer.dpr) catch |err| {
        viewer.log("[TABS] setViewport failed: {}\n", .{err});
    };

    const tab_total_pixels: u64 = @as(u64, viewer.viewport_width) * @as(u64, viewer.viewport_height);
    const tab_quality = config.getAdaptiveQuality(tab_total_pixels);
    const tab_every_nth = config.getEveryNthFrame(viewer.target_fps);
    screenshot_api.startScreencast(viewer.cdp_client, viewer.allocator, .{
        .format = viewer.screencast_format,
        .quality = tab_quality,
        .width = viewer.viewport_width,
        .height = viewer.viewport_height,
        .every_nth_frame = tab_every_nth,
    }) catch |err| {
        viewer.log("[TABS] startScreencast failed after switch: {}\n", .{err});
    };

    // Update UI (non-blocking)
    if (viewer.toolbar_renderer) |*renderer| {
        renderer.blurUrl();
        renderer.setUrl(tab.url);
    }

    viewer.allocator.free(viewer.current_url);
    viewer.current_url = try viewer.allocator.dupe(u8, tab.url);

    viewer.ui_dirty = true;
}

/// Create a new blank tab (about:blank)
/// Uses optimized createAndAttachTarget to skip redundant activation step
pub fn createNewTab(viewer: anytype) !void {
    viewer.log("[TABS] Creating new blank tab (optimized)\n", .{});

    // Create and attach in one optimized call (skips activation since new tabs are focused)
    const target_id = try viewer.cdp_client.createAndAttachTarget("about:blank");
    defer viewer.allocator.free(target_id);

    // Add to tabs list
    try addTab(viewer, target_id, "about:blank", "New Tab");
    viewer.active_tab_index = viewer.tabs.items.len - 1;

    // Set viewport and start screencast on new tab
    screenshot_api.setViewport(viewer.cdp_client, viewer.allocator, viewer.viewport_width, viewer.viewport_height, viewer.dpr) catch |err| {
        viewer.log("[TABS] setViewport failed: {}\n", .{err});
    };

    const tab_total_pixels: u64 = @as(u64, viewer.viewport_width) * @as(u64, viewer.viewport_height);
    const tab_quality = config.getAdaptiveQuality(tab_total_pixels);
    const tab_every_nth = config.getEveryNthFrame(viewer.target_fps);
    screenshot_api.startScreencast(viewer.cdp_client, viewer.allocator, .{
        .format = viewer.screencast_format,
        .quality = tab_quality,
        .width = viewer.viewport_width,
        .height = viewer.viewport_height,
        .every_nth_frame = tab_every_nth,
    }) catch |err| {
        viewer.log("[TABS] startScreencast failed: {}\n", .{err});
    };

    // Update URL display and auto-focus address bar for immediate typing
    if (viewer.toolbar_renderer) |*renderer| {
        renderer.setUrl("");  // Clear URL for fresh input
        renderer.focusUrl();  // Focus the address bar
    }
    viewer.mode = .url_prompt;  // Enter URL prompt mode

    viewer.allocator.free(viewer.current_url);
    viewer.current_url = try viewer.allocator.dupe(u8, "about:blank");

    // Render blank page placeholder (about:blank won't stream anything)
    render_mod.renderBlankPage(viewer);
    viewer.ui_dirty = true;
}

/// Close the current tab
/// Returns true if the viewer should quit (last tab closed)
pub fn closeCurrentTab(viewer: anytype) !bool {
    if (viewer.tabs.items.len == 0) {
        viewer.log("[TABS] No tabs to close\n", .{});
        return true; // Quit if no tabs
    }

    // If only one tab, signal quit
    if (viewer.tabs.items.len == 1) {
        viewer.log("[TABS] Closing last tab, quitting\n", .{});
        return true;
    }

    const current_index = viewer.active_tab_index;
    const tab = viewer.tabs.items[current_index];
    const old_target_id = tab.target_id;

    viewer.log("[TABS] Closing tab {}: {s}\n", .{ current_index, tab.url });

    // Calculate which tab to switch to BEFORE removing
    // Prefer previous tab, or next if at start
    const new_index = if (current_index > 0) current_index - 1 else 1;

    // Switch to new tab FIRST (before closing old one)
    // This ensures CDP is attached to valid target before we close the old one
    if (new_index < viewer.tabs.items.len) {
        const new_tab = viewer.tabs.items[new_index];
        viewer.log("[TABS] Switching to tab {} before close: {s}\n", .{ new_index, new_tab.url });

        // For blank pages, render placeholder; otherwise clear for new content
        if (isBlankPage(new_tab.url)) {
            render_mod.renderBlankPage(viewer);
            // Note: renderBlankPage sets showing_blank_placeholder = true
        } else {
            clearContentArea(viewer);
            viewer.showing_blank_placeholder = false;
        }

        // Switch to new target
        viewer.cdp_client.switchToTarget(new_tab.target_id) catch |err| {
            viewer.log("[TABS] switchToTarget failed: {}\n", .{err});
        };

        // Update active index (adjusted for removal if needed)
        viewer.active_tab_index = if (current_index > 0) new_index else 0;

        // Set viewport and start screencast
        screenshot_api.setViewport(viewer.cdp_client, viewer.allocator, viewer.viewport_width, viewer.viewport_height, viewer.dpr) catch {};

        const tab_total_pixels: u64 = @as(u64, viewer.viewport_width) * @as(u64, viewer.viewport_height);
        const tab_quality = config.getAdaptiveQuality(tab_total_pixels);
        const tab_every_nth = config.getEveryNthFrame(viewer.target_fps);
        screenshot_api.startScreencast(viewer.cdp_client, viewer.allocator, .{
            .format = viewer.screencast_format,
            .quality = tab_quality,
            .width = viewer.viewport_width,
            .height = viewer.viewport_height,
            .every_nth_frame = tab_every_nth,
        }) catch {};

        // Update toolbar
        if (viewer.toolbar_renderer) |*renderer| {
            renderer.blurUrl();
            renderer.setUrl(new_tab.url);
        }

        viewer.allocator.free(viewer.current_url);
        viewer.current_url = viewer.allocator.dupe(u8, new_tab.url) catch "";
    }

    // NOW close the old target in Chrome (after we've switched away)
    viewer.cdp_client.closeTarget(old_target_id) catch |err| {
        viewer.log("[TABS] closeTarget failed: {}\n", .{err});
    };

    // Remove from list first, then clean up the removed item
    var removed_tab = viewer.tabs.orderedRemove(current_index);
    removed_tab.deinit();

    // Adjust active index if we removed a tab before current position
    if (current_index > 0 and viewer.active_tab_index >= current_index) {
        viewer.active_tab_index = current_index - 1;
    }

    // Update toolbar tab count
    if (viewer.toolbar_renderer) |*renderer| {
        renderer.setTabCount(@intCast(viewer.tabs.items.len));
    }

    viewer.ui_dirty = true;
    return false; // Don't quit
}

/// Launch termweb in a new terminal window
pub fn launchInNewTerminal(viewer: anytype, url: []const u8) void {
    var exe_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.selfExePath(&exe_path_buf) catch {
        viewer.log("[NEW TAB] Failed to get exe path\n", .{});
        return;
    };

    const tmp_dir = std.posix.getenv("TMPDIR") orelse "/tmp";
    var script_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const script_path = std.fmt.bufPrint(&script_path_buf, "{s}/termweb_launch_{d}.command", .{ tmp_dir, std.time.milliTimestamp() }) catch return;

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.fs.cwd().realpath(".", &cwd_buf) catch ".";

    var script_buf: [2048]u8 = undefined;
    const script = std.fmt.bufPrint(&script_buf,
        \\#!/bin/bash
        \\cd "{s}"
        \\exec "{s}" open "{s}"
    , .{ cwd, exe_path, url }) catch return;

    const file = std.fs.createFileAbsolute(script_path, .{}) catch |err| {
        viewer.log("[NEW TAB] Failed to create script: {}\n", .{err});
        return;
    };
    defer file.close();
    file.writeAll(script) catch return;

    std.fs.chdirAbsolute(tmp_dir) catch {};
    const chmod_argv = [_][]const u8{ "chmod", "+x", script_path };
    var chmod_child = std.process.Child.init(&chmod_argv, viewer.allocator);
    _ = chmod_child.spawnAndWait() catch {};

    viewer.log("[NEW TAB] Launching via open: {s}\n", .{url});
    const argv = [_][]const u8{ "open", script_path };
    var child = std.process.Child.init(&argv, viewer.allocator);
    child.spawn() catch |err| {
        viewer.log("[NEW TAB] Launch failed: {}\n", .{err});
        return;
    };
    viewer.log("[NEW TAB] Launched: {s}\n", .{url});
}
