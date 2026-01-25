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
        viewer.log("[TABS] Selected tab {}\n", .{index});
        try switchToTab(viewer, index);
    }
}

/// Switch to a different tab
pub fn switchToTab(viewer: anytype, index: usize) !void {
    if (index >= viewer.tabs.items.len) return;

    viewer.active_tab_index = index;
    const tab = viewer.tabs.items[index];

    viewer.log("[TABS] Switching to tab {}: {s} (target={s})\n", .{ index, tab.url, tab.target_id });

    viewer.cdp_client.switchToTarget(tab.target_id) catch |err| {
        viewer.log("[TABS] switchToTarget failed: {}, falling back to navigation\n", .{err});
        _ = try screenshot_api.navigateToUrl(viewer.cdp_client, viewer.allocator, tab.url);
    };

    // Set viewport on new tab to ensure consistent resolution
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

    if (viewer.toolbar_renderer) |*renderer| {
        renderer.blurUrl();
        renderer.setUrl(tab.url);
    }

    viewer.allocator.free(viewer.current_url);
    viewer.current_url = try viewer.allocator.dupe(u8, tab.url);

    viewer.ui_dirty = true;
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
