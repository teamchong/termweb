/// CDP Event handlers for the viewer.
/// Handles Chrome DevTools Protocol events like navigation, downloads, console messages.
const std = @import("std");
const builtin = @import("builtin");
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
        // Note: viewport is updated by ResizeObserver polyfill
    } else if (std.mem.eql(u8, event.method, "Page.navigatedWithinDocument")) {
        handleNavigatedWithinDocument(viewer, event.payload);
    } else if (std.mem.eql(u8, event.method, "Target.targetCreated")) {
        handleNewTarget(viewer, event.payload);
    } else if (std.mem.eql(u8, event.method, "Target.targetInfoChanged")) {
        handleTargetInfoChanged(viewer, event.payload);
    }
}

/// Handle Page.frameNavigated - actual page load, show loading for main frame
pub fn handleFrameNavigated(viewer: anytype, payload: []const u8) void {
    const url = extractUrlFromNavEvent(payload) orelse return;
    const is_main_frame = std.mem.indexOf(u8, payload, "\"parentId\"") == null;

    viewer.log("[FRAME NAV] URL: {s} (main_frame={})\n", .{ url, is_main_frame });

    if (!is_main_frame) return;

    // Note: viewport is updated by ResizeObserver polyfill

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

    // Trigger screencast reset - Chrome's screencast often becomes stale after SPA navigation
    viewer.needs_screencast_reset.store(true, .release);
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

/// Handle Browser.downloadWillBegin event — just register, no file picker.
/// The file picker is shown after the download completes (in handleDownloadProgress).
pub fn handleDownloadWillBegin(viewer: anytype, payload: []const u8) !void {
    viewer.log("[DOWNLOAD] downloadWillBegin: {s}\n", .{payload[0..@min(payload.len, 500)]});

    if (download_mod.parseDownloadWillBegin(payload)) |info| {
        viewer.log("[DOWNLOAD] guid={s} filename={s}\n", .{ info.guid, info.suggested_filename });
        try viewer.download_manager.handleDownloadWillBegin(
            info.guid, info.url, info.suggested_filename,
        );
    }
}

/// Handle Browser.downloadProgress event — handle completed downloads
pub fn handleDownloadProgress(viewer: anytype, payload: []const u8) !void {
    if (download_mod.parseDownloadProgress(payload)) |info| {
        viewer.log("[DOWNLOAD] progress: guid={s} state={s} {d}/{d} bytes\n", .{
            info.guid, info.state, info.received_bytes, info.total_bytes,
        });

        const completed = viewer.download_manager.handleDownloadProgress(
            info.guid,
            info.state,
            info.received_bytes,
            info.total_bytes,
        );

        if (completed) |dl| {
            defer viewer.download_manager.allocator.free(dl.suggested_filename);
            defer viewer.download_manager.allocator.free(dl.source_path);

            viewer.log("[DOWNLOAD] completed: temp={s} filename={s}\n", .{ dl.source_path, dl.suggested_filename });

            if (comptime builtin.os.tag == .macos) {
                // macOS: show native osascript save dialog (built-in, no dependency)
                const dialog_mod = @import("../ui/dialog.zig");
                const save_path = dialog_mod.showNativeFilePickerWithName(
                    viewer.download_manager.allocator,
                    .save,
                    dl.suggested_filename,
                ) catch null;

                if (save_path) |path| {
                    defer viewer.download_manager.allocator.free(path);
                    download_mod.copyFile(dl.source_path, path) catch |err| {
                        viewer.log("[DOWNLOAD] copyFile failed: {}\n", .{err});
                    };
                }
                // Always delete temp file
                std.fs.deleteFileAbsolute(dl.source_path) catch {};
            } else {
                // Linux: keep file in temp dir, copy path to clipboard via OSC 52
                copyToClipboardOsc52(dl.source_path);
            }

            // Reset viewport after download to fix Chrome's layout
            screenshot_api.setViewport(viewer.cdp_client, viewer.download_manager.allocator, viewer.viewport_width, viewer.viewport_height, viewer.dpr) catch |err| {
                viewer.log("[DOWNLOAD] Viewport reset failed: {}\n", .{err});
            };
        } else if (std.mem.eql(u8, info.state, "canceled")) {
            viewer.log("[DOWNLOAD] canceled\n", .{});
        }
    }
}

/// Copy text to system clipboard via OSC 52 escape sequence (zero dependency).
/// Works in any terminal that supports OSC 52 (Ghostty, Kitty, iTerm2, etc.)
fn copyToClipboardOsc52(text: []const u8) void {
    const base64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const stdout = std.fs.File.stdout();

    // Write OSC 52 header
    stdout.writeAll("\x1b]52;c;") catch return;

    // Base64 encode the text inline (no allocation needed)
    var i: usize = 0;
    while (i < text.len) {
        const remaining = text.len - i;
        var buf: [4]u8 = undefined;

        if (remaining >= 3) {
            const b0 = text[i];
            const b1 = text[i + 1];
            const b2 = text[i + 2];
            buf[0] = base64_alphabet[b0 >> 2];
            buf[1] = base64_alphabet[((b0 & 0x03) << 4) | (b1 >> 4)];
            buf[2] = base64_alphabet[((b1 & 0x0f) << 2) | (b2 >> 6)];
            buf[3] = base64_alphabet[b2 & 0x3f];
            i += 3;
        } else if (remaining == 2) {
            const b0 = text[i];
            const b1 = text[i + 1];
            buf[0] = base64_alphabet[b0 >> 2];
            buf[1] = base64_alphabet[((b0 & 0x03) << 4) | (b1 >> 4)];
            buf[2] = base64_alphabet[(b1 & 0x0f) << 2];
            buf[3] = '=';
            i += 2;
        } else {
            const b0 = text[i];
            buf[0] = base64_alphabet[b0 >> 2];
            buf[1] = base64_alphabet[(b0 & 0x03) << 4];
            buf[2] = '=';
            buf[3] = '=';
            i += 1;
        }
        stdout.writeAll(&buf) catch return;
    }

    // Write OSC 52 terminator
    stdout.writeAll("\x1b\\") catch return;
}

/// Handle console messages - look for termweb markers
pub fn handleConsoleMessage(viewer: anytype, payload: []const u8) !void {
    // Check for resize marker (from ResizeObserver in isolated world)
    const resize_marker = "__TERMWEB_RESIZE__:";
    if (std.mem.indexOf(u8, payload, resize_marker)) |resize_pos| {
        handleResizeEvent(viewer, payload, resize_pos + resize_marker.len);
        return;
    }

    // Check for clipboard sync marker - browser clipboard → system clipboard
    const clipboard_marker = "__TERMWEB_CLIPBOARD__:";
    if (std.mem.indexOf(u8, payload, clipboard_marker)) |clip_pos| {
        viewer.log("[CONSOLE MSG] Found clipboard marker\n", .{});
        try viewer.handleClipboardSync(payload, clip_pos + clipboard_marker.len);
        return;
    }

    // Check for clipboard read request - browser wants host clipboard
    const clipboard_request = "__TERMWEB_CLIPBOARD_REQUEST__";
    if (std.mem.indexOf(u8, payload, clipboard_request) != null) {
        viewer.log("[CONSOLE MSG] Clipboard read request - syncing from host\n", .{});
        viewer.handleClipboardReadRequest();
        return;
    }

    // Check for File System API marker
    const fs_marker = "__TERMWEB_FS__:";
    if (std.mem.indexOf(u8, payload, fs_marker)) |fs_pos| {
        try viewer.handleFsRequest(payload, fs_pos + fs_marker.len);
        return;
    }

    // Check for file picker marker
    const picker_marker = "__TERMWEB_PICKER__:";
    if (std.mem.indexOf(u8, payload, picker_marker)) |picker_pos| {
        viewer.log("[CONSOLE MSG] Found picker marker\n", .{});
        try viewer.handlePickerRequest(payload, picker_pos + picker_marker.len);
        return;
    }

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

/// Handle resize event from ResizeObserver - format: W:H
fn handleResizeEvent(viewer: anytype, payload: []const u8, start: usize) void {
    // Parse width:height format
    const data_start = start;
    var data_end = start;
    for (payload[start..]) |c| {
        if (c == '"' or c == '\n' or c == '\r' or c == ' ') break;
        data_end += 1;
    }

    if (data_end <= data_start) return;
    const dimensions = payload[data_start..data_end];

    // Split on ':'
    const sep_pos = std.mem.indexOf(u8, dimensions, ":") orelse return;
    const width_str = dimensions[0..sep_pos];
    const height_str = dimensions[sep_pos + 1 ..];

    const width = std.fmt.parseInt(u32, width_str, 10) catch return;
    const height = std.fmt.parseInt(u32, height_str, 10) catch return;

    viewer.log("[RESIZE] ResizeObserver reported viewport: {d}x{d}\n", .{ width, height });

    // Update chrome inner dimensions (used for coordinate mapping)
    viewer.chrome_inner_width = width;
    viewer.chrome_inner_height = height;
}

/// Show file chooser dialog - delegates to viewer.showFileChooser
pub fn showFileChooser(viewer: anytype, payload: []const u8) !void {
    // Delegate to the viewer's showFileChooser which handles the OS-native picker
    return viewer.showFileChooser(payload);
}
