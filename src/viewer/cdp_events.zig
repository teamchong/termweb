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
        // Page fully loaded - update navigation state (history is now available)
        viewer.forceUpdateNavigationState();
        viewer.ui_state.is_loading = false;
        viewer.ui_dirty = true;
        // Reset baseline - next frame will set it for this page
        viewer.baseline_frame_width = 0;
        viewer.baseline_frame_height = 0;
        // Query Chrome's actual viewport now that page is fully loaded
        // This is the authoritative value - different pages may have different viewports
        if (screenshot_api.getActualViewport(viewer.cdp_client, viewer.allocator)) |vp| {
            if (vp.width > 0 and vp.height > 0) {
                viewer.chrome_inner_width = vp.width;
                viewer.chrome_inner_height = vp.height;
                viewer.log("[NAV] Chrome viewport after load: {}x{}\n", .{ vp.width, vp.height });
            }
        } else |_| {
            // Query failed - reset to 0 so it will be re-queried on next frame
            viewer.chrome_inner_width = 0;
            viewer.chrome_inner_height = 0;
            viewer.chrome_inner_frame_width = 0;
            viewer.chrome_inner_frame_height = 0;
        }
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

    viewer.forceUpdateNavigationState();
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

    viewer.forceUpdateNavigationState();
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

    viewer.addTab(target_id, url, "") catch |err| {
        viewer.log("[NEW TARGET] Failed to add tab: {}\n", .{err});
        return;
    };

    // Auto-switch to the new tab
    const new_tab_index = viewer.tabs.items.len - 1;
    viewer.log("[NEW TARGET] Auto-switching to new tab index={}\n", .{new_tab_index});
    tabs_mod.switchToTab(viewer, new_tab_index) catch |err| {
        viewer.log("[NEW TARGET] switchToTab failed: {}\n", .{err});
    };
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

    viewer.addTab(target_id, url, "") catch |err| {
        viewer.log("[TARGET INFO CHANGED] Failed to add tab: {}\n", .{err});
    };
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

/// Handle console messages - look for special markers
pub fn handleConsoleMessage(viewer: anytype, payload: []const u8) !void {
    // Check for clipboard marker
    const clipboard_marker = "__TERMWEB_CLIPBOARD__:";
    if (std.mem.indexOf(u8, payload, clipboard_marker)) |clip_pos| {
        viewer.log("[CONSOLE MSG] Found clipboard marker\n", .{});
        try handleClipboardSync(viewer, payload, clip_pos + clipboard_marker.len);
        return;
    }

    // Check for clipboard read request
    const clipboard_request = "__TERMWEB_CLIPBOARD_REQUEST__";
    if (std.mem.indexOf(u8, payload, clipboard_request) != null) {
        viewer.log("[CONSOLE MSG] Clipboard read request - syncing from host\n", .{});
        handleClipboardReadRequest(viewer);
        return;
    }

    // Check for file system operation marker
    const fs_marker = "__TERMWEB_FS__:";
    if (std.mem.indexOf(u8, payload, fs_marker)) |fs_pos| {
        viewer.log("[CONSOLE MSG] Found FS marker at {d}\n", .{fs_pos});
        try handleFsRequest(viewer, payload, fs_pos + fs_marker.len);
        return;
    }

    // Check for picker marker
    const picker_marker = "__TERMWEB_PICKER__:";
    if (std.mem.indexOf(u8, payload, picker_marker)) |picker_pos| {
        viewer.log("[CONSOLE MSG] Found picker marker\n", .{});
        try handlePickerRequest(viewer, payload, picker_pos + picker_marker.len);
        return;
    }
}

/// Handle clipboard sync from browser to system
fn handleClipboardSync(viewer: anytype, payload: []const u8, start: usize) !void {
    // Find the end of the clipboard data (end of JSON string)
    var end = start;
    var in_escape = false;
    for (payload[start..]) |c| {
        if (in_escape) {
            in_escape = false;
            end += 1;
            continue;
        }
        if (c == '\\') {
            in_escape = true;
            end += 1;
            continue;
        }
        if (c == '"') break;
        end += 1;
    }

    if (end <= start) return;

    const clipboard_data = payload[start..end];
    viewer.log("[CLIPBOARD] Syncing {d} bytes to system clipboard\n", .{clipboard_data.len});

    // Unescape JSON string
    const unescaped = unescapeJsonString(viewer, clipboard_data) orelse return;
    defer viewer.allocator.free(unescaped);

    // Write to system clipboard via pbcopy
    const argv = [_][]const u8{"pbcopy"};
    var child = std.process.Child.init(&argv, viewer.allocator);
    child.stdin_behavior = .Pipe;
    child.spawn() catch return;

    if (child.stdin) |stdin| {
        stdin.writeAll(unescaped) catch {};
        stdin.close();
        child.stdin = null;
    }
    _ = child.wait() catch {};
}

/// Unescape JSON string (handle \n, \t, \\, \", etc.)
fn unescapeJsonString(viewer: anytype, input: []const u8) ?[]u8 {
    var result = viewer.allocator.alloc(u8, input.len) catch return null;
    var out_idx: usize = 0;
    var i: usize = 0;

    while (i < input.len) {
        if (input[i] == '\\' and i + 1 < input.len) {
            const next = input[i + 1];
            switch (next) {
                'n' => {
                    result[out_idx] = '\n';
                    out_idx += 1;
                    i += 2;
                },
                't' => {
                    result[out_idx] = '\t';
                    out_idx += 1;
                    i += 2;
                },
                'r' => {
                    result[out_idx] = '\r';
                    out_idx += 1;
                    i += 2;
                },
                '\\' => {
                    result[out_idx] = '\\';
                    out_idx += 1;
                    i += 2;
                },
                '"' => {
                    result[out_idx] = '"';
                    out_idx += 1;
                    i += 2;
                },
                '/' => {
                    result[out_idx] = '/';
                    out_idx += 1;
                    i += 2;
                },
                'u' => {
                    // Unicode escape \uXXXX
                    if (i + 5 < input.len) {
                        const hex = input[i + 2 .. i + 6];
                        const codepoint = std.fmt.parseInt(u21, hex, 16) catch {
                            result[out_idx] = input[i];
                            out_idx += 1;
                            i += 1;
                            continue;
                        };
                        // Encode as UTF-8
                        const len = std.unicode.utf8Encode(codepoint, result[out_idx..]) catch {
                            result[out_idx] = '?';
                            out_idx += 1;
                            i += 6;
                            continue;
                        };
                        out_idx += len;
                        i += 6;
                    } else {
                        result[out_idx] = input[i];
                        out_idx += 1;
                        i += 1;
                    }
                },
                else => {
                    result[out_idx] = input[i];
                    out_idx += 1;
                    i += 1;
                },
            }
        } else {
            result[out_idx] = input[i];
            out_idx += 1;
            i += 1;
        }
    }

    // Shrink to actual size
    const final = viewer.allocator.realloc(result, out_idx) catch {
        return result[0..out_idx];
    };
    return final[0..out_idx];
}

/// Handle clipboard read request - sync host clipboard to browser
fn handleClipboardReadRequest(viewer: anytype) void {
    const toolbar = @import("../ui/toolbar.zig");
    const clipboard = toolbar.pasteFromClipboard(viewer.allocator) orelse return;
    defer viewer.allocator.free(clipboard);

    // Escape for JavaScript string
    var escaped_size: usize = 0;
    for (clipboard) |c| {
        escaped_size += switch (c) {
            '\n', '\r', '\t', '\\', '"', '\'' => 2,
            else => 1,
        };
    }

    var escaped = viewer.allocator.alloc(u8, escaped_size) catch return;
    defer viewer.allocator.free(escaped);

    var out_idx: usize = 0;
    for (clipboard) |c| {
        switch (c) {
            '\n' => {
                escaped[out_idx] = '\\';
                escaped[out_idx + 1] = 'n';
                out_idx += 2;
            },
            '\r' => {
                escaped[out_idx] = '\\';
                escaped[out_idx + 1] = 'r';
                out_idx += 2;
            },
            '\t' => {
                escaped[out_idx] = '\\';
                escaped[out_idx + 1] = 't';
                out_idx += 2;
            },
            '\\' => {
                escaped[out_idx] = '\\';
                escaped[out_idx + 1] = '\\';
                out_idx += 2;
            },
            '"' => {
                escaped[out_idx] = '\\';
                escaped[out_idx + 1] = '"';
                out_idx += 2;
            },
            '\'' => {
                escaped[out_idx] = '\\';
                escaped[out_idx + 1] = '\'';
                out_idx += 2;
            },
            else => {
                escaped[out_idx] = c;
                out_idx += 1;
            },
        }
    }

    // Inject into browser
    const script = std.fmt.allocPrint(viewer.allocator, "window._termwebClipboardData = \"{s}\";", .{escaped[0..out_idx]}) catch return;
    defer viewer.allocator.free(script);

    viewer.evalJavaScript(script) catch {};
}

/// Handle file system operation request - delegates to viewer
fn handleFsRequest(viewer: anytype, payload: []const u8, start: usize) !void {
    // Delegate to viewer's handleFsRequest
    return viewer.handleFsRequest(payload, start);
}

/// Handle picker request from browser
fn handlePickerRequest(viewer: anytype, payload: []const u8, start: usize) !void {
    _ = viewer;
    _ = payload;
    _ = start;
    // Picker handling - can be expanded later
}

/// Show file chooser dialog - delegates to viewer.showFileChooser
pub fn showFileChooser(viewer: anytype, payload: []const u8) !void {
    // Delegate to the viewer's showFileChooser which handles the OS-native picker
    return viewer.showFileChooser(payload);
}
