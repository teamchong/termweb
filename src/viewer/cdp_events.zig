/// CDP Event handlers for the viewer.
/// Handles Chrome DevTools Protocol events like navigation, downloads, console messages.
const std = @import("std");
const cdp = @import("../chrome/cdp_client.zig");
const screenshot_api = @import("../chrome/screenshot.zig");
const download_mod = @import("../chrome/download.zig");
const ui_mod = @import("../ui/mod.zig");
const helpers = @import("helpers.zig");
const tabs_mod = @import("tabs.zig");

const extractUrlFromNavEvent = helpers.extractUrlFromNavEvent;

/// Global IPC callback - set by napi.zig when running as Node.js module
var ipc_callback: ?*const fn ([]const u8) void = null;

/// Register a callback to receive IPC messages from the browser
pub fn setIpcCallback(callback: ?*const fn ([]const u8) void) void {
    ipc_callback = callback;
}

/// Handle CDP event - dispatches to specific handlers
pub fn handleCdpEvent(viewer: anytype, event: *cdp.CdpEvent) !void {
    viewer.log("[CDP EVENT] method={s}\n", .{event.method});

    if (std.mem.eql(u8, event.method, "Page.javascriptDialogOpening")) {
        // Let Chrome show native dialog in screencast - don't intercept
        viewer.log("[DIALOG] Native dialog opened, user can click in screencast\n", .{});
    } else if (std.mem.eql(u8, event.method, "Page.fileChooserOpened")) {
        try showFileChooser(viewer, event.payload);
    } else if (std.mem.eql(u8, event.method, "Runtime.consoleAPICalled")) {
        try handleConsoleMessage(viewer, event.payload);
    } else if (std.mem.eql(u8, event.method, "Browser.downloadWillBegin")) {
        try handleDownloadWillBegin(viewer, event.payload);
    } else if (std.mem.eql(u8, event.method, "Browser.downloadProgress")) {
        try handleDownloadProgress(viewer, event.payload);
    } else if (std.mem.eql(u8, event.method, "Page.frameNavigated")) {
        handleFrameNavigated(viewer, event.payload);
    } else if (std.mem.eql(u8, event.method, "Page.loadEventFired")) {
        // Page fully loaded - mark for nav state update (done in main loop to avoid blocking CDP thread)
        viewer.ui_state.is_loading = false;
        viewer.ui_dirty = true;
        viewer.needs_nav_state_update = true; // Deferred to main loop
        // Reset baseline - next frame will set it for this page
        viewer.baseline_frame_width = 0;
        viewer.baseline_frame_height = 0;
        // Reset viewport cache - will be re-queried from main loop
        viewer.chrome_inner_width = 0;
        viewer.chrome_inner_height = 0;
        viewer.chrome_inner_frame_width = 0;
        viewer.chrome_inner_frame_height = 0;
    } else if (std.mem.eql(u8, event.method, "Page.navigatedWithinDocument")) {
        handleNavigatedWithinDocument(viewer, event.payload);
    } else if (std.mem.eql(u8, event.method, "Target.targetCreated")) {
        handleNewTarget(viewer, event.payload);
    } else if (std.mem.eql(u8, event.method, "Target.targetInfoChanged")) {
        handleTargetInfoChanged(viewer, event.payload);
    }
    // NOTE: Frame changes (download bar, etc.) are detected by comparing current frame
    // dimensions to chrome_inner_frame_width/height and applying ratio adjustment
}

/// Handle Page.frameNavigated - actual page load, show loading for main frame
pub fn handleFrameNavigated(viewer: anytype, payload: []const u8) void {
    const url = extractUrlFromNavEvent(payload) orelse return;
    const is_main_frame = std.mem.indexOf(u8, payload, "\"parentId\"") == null;

    viewer.log("[FRAME NAV] URL: {s} (main_frame={})\n", .{ url, is_main_frame });

    if (!is_main_frame) return;

    // Reset viewport cache on main frame navigation - different pages may have different viewports
    viewer.chrome_inner_width = 0;
    viewer.chrome_inner_height = 0;
    viewer.chrome_inner_frame_width = 0;
    viewer.chrome_inner_frame_height = 0;

    if (!viewer.ui_state.is_loading) {
        viewer.ui_state.is_loading = true;
        viewer.loading_started_at = std.time.nanoTimestamp();
        viewer.ui_dirty = true;
    }

    if (!std.mem.eql(u8, viewer.current_url, url)) {
        const new_url = viewer.allocator.dupe(u8, url) catch return;
        viewer.allocator.free(viewer.current_url);
        viewer.current_url = new_url;

        if (viewer.toolbar_renderer) |*renderer| {
            renderer.setUrl(new_url);
            viewer.ui_dirty = true;
        }
    }

    // Defer nav state update to main loop (avoid blocking CDP thread)
    viewer.needs_nav_state_update = true;
}

/// Handle Page.navigatedWithinDocument - SPA navigation (pushState/hash change)
pub fn handleNavigatedWithinDocument(viewer: anytype, payload: []const u8) void {
    const url = extractUrlFromNavEvent(payload) orelse return;

    viewer.log("[SPA NAV] URL: {s}\n", .{url});

    if (!std.mem.eql(u8, viewer.current_url, url)) {
        const new_url = viewer.allocator.dupe(u8, url) catch return;
        viewer.allocator.free(viewer.current_url);
        viewer.current_url = new_url;

        if (viewer.toolbar_renderer) |*renderer| {
            renderer.setUrl(new_url);
            viewer.ui_dirty = true;
        }
    }

    // Defer nav state update to main loop (avoid blocking CDP thread)
    viewer.needs_nav_state_update = true;
}

/// Handle Target.targetCreated event
pub fn handleNewTarget(viewer: anytype, payload: []const u8) void {
    viewer.log("[NEW TARGET] Payload: {s}\n", .{payload[0..@min(payload.len, 800)]});

    const target_id_marker = "\"targetId\":\"";
    const target_id_start = std.mem.indexOf(u8, payload, target_id_marker) orelse return;
    const id_start = target_id_start + target_id_marker.len;
    const id_end = std.mem.indexOfPos(u8, payload, id_start, "\"") orelse return;
    const target_id = payload[id_start..id_end];

    const type_marker = "\"type\":\"";
    const type_start = std.mem.indexOf(u8, payload, type_marker) orelse return;
    const t_start = type_start + type_marker.len;
    const t_end = std.mem.indexOfPos(u8, payload, t_start, "\"") orelse return;
    const target_type = payload[t_start..t_end];

    if (!std.mem.eql(u8, target_type, "page")) {
        viewer.log("[NEW TARGET] Ignoring non-page target type={s}\n", .{target_type});
        return;
    }

    if (std.mem.indexOf(u8, payload, "\"attached\":true") != null) {
        viewer.log("[NEW TARGET] Ignoring attached target (our page)\n", .{});
        return;
    }

    const url_marker = "\"url\":\"";
    const url_start = std.mem.indexOf(u8, payload, url_marker) orelse return;
    const u_start = url_start + url_marker.len;
    const u_end = std.mem.indexOfPos(u8, payload, u_start, "\"") orelse return;
    const url = payload[u_start..u_end];

    if (std.mem.eql(u8, url, "about:blank") or url.len == 0) {
        viewer.log("[NEW TARGET] Empty URL, tracking target id={s}\n", .{target_id});
        const id_copy = viewer.allocator.dupe(u8, target_id) catch return;
        viewer.pending_new_targets.append(viewer.allocator, id_copy) catch {
            viewer.allocator.free(id_copy);
        };
        return;
    }

    viewer.log("[NEW TARGET] New tab requested: id={s} url={s}\n", .{ target_id, url });

    // In single-tab mode, navigate in same tab instead of creating new tab
    if (viewer.single_tab_mode) {
        viewer.log("[NEW TARGET] Single-tab mode: navigating to {s}\n", .{url});
        // Close the new target and navigate in current tab
        viewer.cdp_client.closeTarget(target_id) catch {};
        _ = screenshot_api.navigateToUrl(viewer.cdp_client, viewer.allocator, url) catch |err| {
            viewer.log("[NEW TARGET] Navigation failed: {}\n", .{err});
        };
        return;
    }

    // Request deferred tab add (processed in main loop to avoid data races)
    viewer.log("[NEW TARGET] Requesting deferred tab add: url={s}\n", .{url});
    viewer.requestTabAdd(target_id, url, "", true); // auto_switch=true
}

/// Handle Target.targetInfoChanged - URL may now be available for pending targets
pub fn handleTargetInfoChanged(viewer: anytype, payload: []const u8) void {
    const target_id_marker = "\"targetId\":\"";
    const target_id_start = std.mem.indexOf(u8, payload, target_id_marker) orelse return;
    const id_start = target_id_start + target_id_marker.len;
    const id_end = std.mem.indexOfPos(u8, payload, id_start, "\"") orelse return;
    const target_id = payload[id_start..id_end];

    const url_marker = "\"url\":\"";
    const url_start = std.mem.indexOf(u8, payload, url_marker) orelse return;
    const u_start = url_start + url_marker.len;
    const u_end = std.mem.indexOfPos(u8, payload, u_start, "\"") orelse return;
    const url = payload[u_start..u_end];

    if (url.len == 0 or std.mem.eql(u8, url, "about:blank")) return;

    for (viewer.tabs.items) |*tab| {
        if (std.mem.eql(u8, tab.target_id, target_id)) {
            if (!std.mem.eql(u8, tab.url, url)) {
                viewer.log("[TARGET INFO CHANGED] Updating tab URL: {s} -> {s}\n", .{ tab.url, url });
                tab.updateUrl(url) catch {};
            }
            return;
        }
    }

    var found_index: ?usize = null;
    for (viewer.pending_new_targets.items, 0..) |pending_id, i| {
        if (std.mem.eql(u8, pending_id, target_id)) {
            found_index = i;
            break;
        }
    }

    if (found_index == null) return;

    viewer.log("[TARGET INFO CHANGED] URL ready for new tab: id={s} url={s}\n", .{ target_id, url });

    const removed_id = viewer.pending_new_targets.orderedRemove(found_index.?);
    viewer.allocator.free(removed_id);

    // In single-tab mode, navigate in same tab instead of creating new tab
    if (viewer.single_tab_mode) {
        viewer.log("[TARGET INFO CHANGED] Single-tab mode: navigating to {s}\n", .{url});
        viewer.cdp_client.closeTarget(target_id) catch {};
        _ = screenshot_api.navigateToUrl(viewer.cdp_client, viewer.allocator, url) catch |err| {
            viewer.log("[TARGET INFO CHANGED] Navigation failed: {}\n", .{err});
        };
        return;
    }

    // Request deferred tab add (processed in main loop to avoid data races)
    viewer.log("[TARGET INFO CHANGED] Requesting deferred tab add: url={s}\n", .{url});
    viewer.requestTabAdd(target_id, url, "", true); // auto_switch=true
}

/// Handle Browser.downloadWillBegin event
pub fn handleDownloadWillBegin(viewer: anytype, payload: []const u8) !void {
    viewer.log("[DOWNLOAD] downloadWillBegin: {s}\n", .{payload[0..@min(payload.len, 500)]});

    if (download_mod.parseDownloadWillBegin(payload)) |info| {
        viewer.log("[DOWNLOAD] guid={s} filename={s}\n", .{ info.guid, info.suggested_filename });
        // Frame dimensions from screencast handle download bar automatically

        try viewer.download_manager.handleDownloadWillBegin(
            info.guid,
            info.url,
            info.suggested_filename,
        );
    }
}

/// Handle Browser.downloadProgress event
pub fn handleDownloadProgress(viewer: anytype, payload: []const u8) !void {
    if (download_mod.parseDownloadProgress(payload)) |info| {
        viewer.log("[DOWNLOAD] progress: guid={s} state={s} {d}/{d} bytes\n", .{
            info.guid, info.state, info.received_bytes, info.total_bytes,
        });
        try viewer.download_manager.handleDownloadProgress(
            info.guid,
            info.state,
            info.received_bytes,
            info.total_bytes,
        );

        if (std.mem.eql(u8, info.state, "completed") or std.mem.eql(u8, info.state, "canceled")) {
            viewer.log("[DOWNLOAD] {s}\n", .{info.state});
        }
    }
}

/// Handle console messages - look for IPC markers
pub fn handleConsoleMessage(viewer: anytype, payload: []const u8) !void {
    // Check for IPC message marker - forward to registered callback (if any)
    const ipc_marker = "__TERMWEB_IPC__:";
    if (std.mem.indexOf(u8, payload, ipc_marker)) |ipc_pos| {
        const message_start = ipc_pos + ipc_marker.len;
        if (message_start < payload.len) {
            // Find end of message (look for closing quote or end of line)
            var message_end = message_start;
            while (message_end < payload.len) : (message_end += 1) {
                const c = payload[message_end];
                if (c == '"' or c == '\n' or c == '\r') break;
            }
            if (message_end > message_start) {
                viewer.log("[CONSOLE MSG] Found IPC marker, forwarding message\n", .{});
                // Call the global IPC callback if registered
                if (ipc_callback) |callback| {
                    callback(payload[message_start..message_end]);
                }
            }
        }
        return;
    }
}

/// Show file chooser dialog - delegates to viewer.showFileChooser
pub fn showFileChooser(viewer: anytype, payload: []const u8) !void {
    // Delegate to the viewer's showFileChooser which handles the OS-native picker
    return viewer.showFileChooser(payload);
}
