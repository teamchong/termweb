/// Chrome DevTools Protocol (CDP) client implementation.
///
/// Pure pipe architecture using --remote-debugging-pipe:
/// - FD 3: Write commands to Chrome
/// - FD 4: Read responses/events from Chrome
///
/// All CDP communication (commands, events, input) goes through the pipe.
const std = @import("std");
const cdp_pipe = @import("cdp_pipe.zig");
const json = @import("json");
const json_utils = @import("../utils/json.zig");

/// Debug logging - always enabled, appends to cdp_debug.log
fn logToFile(comptime fmt: []const u8, args: anytype) void {
    // Always log to cdp_debug.log
    var buf: [4096]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, fmt, args) catch return;

    const file = std.fs.cwd().openFile("cdp_debug.log", .{ .mode = .read_write }) catch |err| blk: {
        if (err == error.FileNotFound) {
            break :blk std.fs.cwd().createFile("cdp_debug.log", .{ .read = true }) catch return;
        }
        return;
    };
    defer file.close();
    file.seekFromEnd(0) catch return;
    file.writeAll(slice) catch return;
}

pub const CdpError = error{
    ConnectionFailed,
    SendFailed,
    ReceiveFailed,
    InvalidResponse,
    CommandFailed,
    TimeoutWaitingForResponse,
    OutOfMemory,
    NoPageTarget,
};

pub const CdpEvent = struct {
    method: []const u8,
    payload: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CdpEvent) void {
        self.allocator.free(self.method);
        self.allocator.free(self.payload);
    }
};

/// Screencast frame from Page.screencastFrame event
pub const ScreencastFrame = struct {
    data: []const u8, // Base64-encoded image data
    session_id: u32, // Session ID for acknowledgment
    width: u32,
    height: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ScreencastFrame) void {
        self.allocator.free(self.data);
    }
};

/// CDP Client - Pure pipe mode via --remote-debugging-pipe
///
/// All CDP communication goes through the pipe:
/// - Commands: Write to FD 3
/// - Responses/Events: Read from FD 4
pub const CdpClient = struct {
    allocator: std.mem.Allocator,
    pipe_client: *cdp_pipe.PipeCdpClient,
    session_id: ?[]const u8, // Session ID for page-level commands
    current_target_id: ?[]const u8, // Current target ID (for tab switching)
    debug_port: u16, // Chrome's debugging port (for DevTools URL)

    // Async reattach state (prevents blocking during page reload)
    reattach_pending: bool,
    reattach_request_id: u32,
    reattach_started_at: i128,

    // Screencast state
    screencast_active: bool,
    latest_frame: ?ScreencastFrame,
    frame_mutex: std.Thread.Mutex,

    /// Initialize CDP client from pipe file descriptors
    /// read_fd: FD to read from Chrome (Chrome's FD 4)
    /// write_fd: FD to write to Chrome (Chrome's FD 3)
    /// debug_port: Chrome's debugging port (for DevTools URL only)
    pub fn initFromPipe(allocator: std.mem.Allocator, read_fd: std.posix.fd_t, write_fd: std.posix.fd_t, debug_port: u16) !*CdpClient {
        const client = try allocator.create(CdpClient);
        client.* = .{
            .allocator = allocator,
            .pipe_client = try cdp_pipe.PipeCdpClient.init(allocator, read_fd, write_fd),
            .session_id = null,
            .current_target_id = null,
            .debug_port = debug_port,
            .reattach_pending = false,
            .reattach_request_id = 0,
            .reattach_started_at = 0,
            .screencast_active = false,
            .latest_frame = null,
            .frame_mutex = .{},
        };

        // Attach to page target to enable page-level commands
        try client.attachToPageTarget();

        // Start pipe reader thread to receive events (console messages, etc.)
        try client.pipe_client.startReaderThread();

        // Enable domains for consistent event delivery
        const page_enable = try client.sendCommand("Page.enable", null);
        allocator.free(page_enable);
        const network_enable = try client.sendCommand("Network.enable", null);
        allocator.free(network_enable);

        // Intercept file chooser dialogs (CDP-only feature for <input type="file">)
        const intercept_file = try client.sendCommand("Page.setInterceptFileChooserDialog", "{\"enabled\":true}");
        allocator.free(intercept_file);

        // Create downloads directory
        std.fs.makeDirAbsolute("/tmp/termweb-downloads") catch |err| {
            if (err != error.PathAlreadyExists) {
                logToFile("[CDP] Failed to create download dir: {}\n", .{err});
            }
        };

        // Inject File System Access API polyfill with full file system bridge
        // Note: In non-headless mode, the termweb extension handles this instead
        // Security: Only allows access to directories user explicitly selected via picker
        const polyfill_script = @embedFile("fs_polyfill.js");
        var polyfill_json_buf: [65536]u8 = undefined;
        const polyfill_json = json_utils.escapeString(polyfill_script, &polyfill_json_buf) catch return error.OutOfMemory;

        var polyfill_params_buf: [65536]u8 = undefined;
        const polyfill_params = std.fmt.bufPrint(&polyfill_params_buf, "{{\"source\":{s}}}", .{polyfill_json}) catch return error.OutOfMemory;
        const polyfill_result = try client.sendCommand("Page.addScriptToEvaluateOnNewDocument", polyfill_params);
        allocator.free(polyfill_result);

        // Grant clipboard permissions for read/write access
        // This allows navigator.clipboard.readText() to work without user gesture
        const perm_result = client.sendCommand("Browser.grantPermissions", "{\"permissions\":[\"clipboardReadWrite\",\"clipboardSanitizedWrite\"]}") catch null;
        if (perm_result) |r| allocator.free(r);

        // Inject Clipboard interceptor polyfill - runs in all frames (including iframes)
        // Note: In non-headless mode, the termweb extension handles this instead
        // This enables bidirectional clipboard sync between browser and host
        const clipboard_script = @embedFile("clipboard_polyfill.js");
        var clipboard_json_buf: [16384]u8 = undefined;
        const clipboard_json = json_utils.escapeString(clipboard_script, &clipboard_json_buf) catch return error.OutOfMemory;

        var clipboard_params_buf: [32768]u8 = undefined;
        const clipboard_params = std.fmt.bufPrint(&clipboard_params_buf, "{{\"source\":{s}}}", .{clipboard_json}) catch return error.OutOfMemory;
        const clipboard_result = try client.sendCommand("Page.addScriptToEvaluateOnNewDocument", clipboard_params);
        allocator.free(clipboard_result);

        // Enable Runtime to receive console events (for extension signaling)
        const runtime_result = try client.sendCommand("Runtime.enable", null);
        allocator.free(runtime_result);

        // Enable target discovery to detect new tabs/popups
        const target_result = try client.sendCommand("Target.setDiscoverTargets", "{\"discover\":true}");
        allocator.free(target_result);

        // Set up downloads via pipe
        const download_params = "{\"behavior\":\"allowAndName\",\"downloadPath\":\"/tmp/termweb-downloads\",\"eventsEnabled\":true}";
        const download_result = client.sendCommand("Browser.setDownloadBehavior", download_params) catch null;
        if (download_result) |r| allocator.free(r);

        logToFile("[CDP] Pure pipe mode initialized\n", .{});
        return client;
    }

    /// Attach to a page target to enable page-level commands
    fn attachToPageTarget(self: *CdpClient) !void {
        // Step 1: Get list of targets
        const targets_response = try self.pipe_client.sendCommand("Target.getTargets", null);
        defer self.allocator.free(targets_response);

        // Parse targetId from response - look for type "page"
        // Format: {"id":N,"result":{"targetInfos":[{"targetId":"XXX","type":"page",...}]}}
        const target_id = try self.extractPageTargetId(targets_response);
        // Store target_id (don't free - we keep it)
        self.current_target_id = target_id;

        // Step 2: Attach to the page target with flatten mode
        // Escape target_id for JSON (handles any special chars)
        var escape_buf: [512]u8 = undefined;
        const escaped_id = json_utils.escapeContents(target_id, &escape_buf) catch return error.OutOfMemory;
        const params = try std.fmt.allocPrint(
            self.allocator,
            "{{\"targetId\":\"{s}\",\"flatten\":true}}",
            .{escaped_id},
        );
        defer self.allocator.free(params);

        const attach_response = try self.pipe_client.sendCommand("Target.attachToTarget", params);
        defer self.allocator.free(attach_response);

        // Extract sessionId from response
        // Format: {"id":N,"result":{"sessionId":"XXX"}}
        self.session_id = try self.extractSessionId(attach_response);
    }

    /// Refresh the current page target ID from Chrome
    /// Call this before reattach to handle "Process Swap" where old ID becomes invalid
    pub fn refreshPageTarget(self: *CdpClient) !void {
        logToFile("[CDP] Refreshing Page Target...\n", .{});

        // Send synchronous command to get current targets
        const response = try self.pipe_client.sendCommand("Target.getTargets", null);
        defer self.allocator.free(response);

        // Find the first entry with "type":"page"
        if (std.mem.indexOf(u8, response, "\"type\":\"page\"")) |type_pos| {
            // The targetId usually appears BEFORE the type in the JSON object
            // Search backwards from "type":"page" to find the targetId
            const haystack = response[0..type_pos];
            const key = "\"targetId\":\"";

            if (std.mem.lastIndexOf(u8, haystack, key)) |key_pos| {
                const val_start = key_pos + key.len;
                if (std.mem.indexOfPos(u8, haystack, val_start, "\"")) |val_end| {
                    const new_tid = haystack[val_start..val_end];

                    // Check if it changed
                    if (self.current_target_id) |old| {
                        if (!std.mem.eql(u8, old, new_tid)) {
                            logToFile("[CDP] Target ID CHANGED: {s} -> {s}\n", .{ old, new_tid });
                            self.allocator.free(old);
                            self.current_target_id = try self.allocator.dupe(u8, new_tid);
                        } else {
                            logToFile("[CDP] Target ID unchanged: {s}\n", .{new_tid});
                        }
                    } else {
                        self.current_target_id = try self.allocator.dupe(u8, new_tid);
                        logToFile("[CDP] Found Initial Target ID: {s}\n", .{new_tid});
                    }
                    return;
                }
            }
        }

        logToFile("[CDP] CRITICAL: Could not find any 'page' target in response\n", .{});
        return CdpError.NoPageTarget;
    }

    /// Re-attach to the page target to refresh the session ID
    /// Uses SYNCHRONOUS attach to ensure we have a valid session before continuing
    pub fn reattachToTarget(self: *CdpClient) !void {
        logToFile("[CDP] reattachToTarget: START\n", .{});

        // 1. FORCE RESET: Clear all session state and queues
        self.forceResetSession();

        // 2. CRITICAL: Refresh Target ID from Chrome
        // This handles "Process Swap" where old ID becomes invalid during reload
        self.refreshPageTarget() catch |err| {
            logToFile("[CDP] refreshPageTarget failed: {}, falling back to full attach\n", .{err});
            try self.attachToPageTarget();
            return;
        };

        const target_id = self.current_target_id orelse {
            logToFile("[CDP] reattachToTarget: No target ID after refresh, falling back to full attach\n", .{});
            try self.attachToPageTarget();
            return;
        };

        // 3. Send SYNCHRONOUS Target.attachToTarget
        // We use sync here because async was causing race conditions
        var escape_buf: [512]u8 = undefined;
        const escaped_id = json_utils.escapeContents(target_id, &escape_buf) catch return error.OutOfMemory;

        var params_buf: [1024]u8 = undefined;
        const params = std.fmt.bufPrint(&params_buf, "{{\"targetId\":\"{s}\",\"flatten\":true}}", .{escaped_id}) catch return error.OutOfMemory;

        logToFile("[CDP] reattachToTarget: Sending sync attach (tid={s})\n", .{target_id});

        const response = try self.pipe_client.sendCommand("Target.attachToTarget", params);
        defer self.allocator.free(response);

        // 4. Extract session ID from response
        if (self.extractSessionIdFromPayload(response)) |new_sid| {
            self.session_id = new_sid;
            logToFile("[CDP] reattachToTarget: SUCCESS (SID: {s})\n", .{new_sid});
        } else |err| {
            logToFile("[CDP] reattachToTarget: Failed to extract session: {}\n", .{err});
            return err;
        }

        // Clear pending flag (not used anymore but keep for safety)
        self.reattach_pending = false;
    }

    /// Poll for async reattach response (call from main loop)
    /// Returns true if reattach completed (success or timeout), false if still pending
    /// Uses GREEDY matching - any response with sessionId is accepted
    pub fn pollReattachResponse(self: *CdpClient) bool {
        // 1. Check if nextEvent() already caught the attachedToTarget event
        if (!self.reattach_pending) return true;

        // 2. GREEDY response check - don't match ID, just look for sessionId
        // We cleared the queue before starting, so any session response is likely ours
        {
            self.pipe_client.response_mutex.lock();
            defer self.pipe_client.response_mutex.unlock();

            var i: usize = 0;
            while (i < self.pipe_client.response_queue.items.len) {
                const entry = self.pipe_client.response_queue.items[i];

                // GREEDY: Does this response contain a sessionId?
                if (std.mem.indexOf(u8, entry.payload, "\"sessionId\"") != null) {
                    const payload = entry.payload;
                    _ = self.pipe_client.response_queue.swapRemove(i);

                    if (self.extractSessionIdFromPayload(payload)) |new_sid| {
                        if (self.session_id) |old| self.allocator.free(old);
                        self.session_id = new_sid;
                        self.reattach_pending = false;
                        logToFile("[CDP] pollReattachResponse: SUCCESS via GREEDY (SID: {s})\n", .{new_sid});
                        self.allocator.free(payload);
                        return true;
                    } else |_| {
                        // Extraction failed, free and continue
                        self.allocator.free(payload);
                    }
                    // Don't increment i since we removed an element
                    continue;
                }
                i += 1;
            }
        }

        // 3. Check for timeout (5 seconds)
        const elapsed = std.time.nanoTimestamp() - self.reattach_started_at;
        if (elapsed > 5 * std.time.ns_per_s) {
            logToFile("[CDP] pollReattachResponse: TIMEOUT after 5s\n", .{});
            self.reattach_pending = false;
            return true;
        }

        return false; // Still waiting
    }

    /// Check if reattach is in progress (commands should be skipped)
    pub fn isReattaching(self: *CdpClient) bool {
        return self.reattach_pending;
    }

    /// Force reset all session state (nuclear option for stuck states)
    /// Call this when the session is hopelessly confused
    pub fn forceResetSession(self: *CdpClient) void {
        logToFile("[CDP] FORCE RESET SESSION\n", .{});

        // Clear session ID
        if (self.session_id) |sid| {
            self.allocator.free(sid);
            self.session_id = null;
        }

        // Clear reattach state
        self.reattach_pending = false;
        self.reattach_request_id = 0;
        self.reattach_started_at = 0;

        // Clear both queues to remove zombie messages
        self.pipe_client.clearResponseQueue();
        self.pipe_client.clearEventQueue();

        logToFile("[CDP] Session state fully reset\n", .{});
    }

    /// Extract page targetId from Target.getTargets response
    fn extractPageTargetId(self: *CdpClient, response: []const u8) ![]const u8 {
        // Find "type":"page" first
        const type_pos = std.mem.indexOf(u8, response, "\"type\":\"page\"") orelse
            return CdpError.NoPageTarget;

        // Search backwards for targetId
        const search_start = if (type_pos > 200) type_pos - 200 else 0;
        const search_slice = response[search_start..type_pos];

        const target_id_marker = "\"targetId\":\"";
        const target_id_pos = std.mem.lastIndexOf(u8, search_slice, target_id_marker) orelse
            return CdpError.NoPageTarget;

        const id_start = search_start + target_id_pos + target_id_marker.len;
        const id_end_marker = std.mem.indexOfPos(u8, response, id_start, "\"") orelse
            return CdpError.NoPageTarget;

        return try self.allocator.dupe(u8, response[id_start..id_end_marker]);
    }

    /// Extract sessionId from Target.attachToTarget response
    fn extractSessionId(self: *CdpClient, response: []const u8) ![]const u8 {
        const session_marker = "\"sessionId\":\"";
        const session_pos = std.mem.indexOf(u8, response, session_marker) orelse
            return CdpError.InvalidResponse;

        const id_start = session_pos + session_marker.len;
        const id_end = std.mem.indexOfPos(u8, response, id_start, "\"") orelse
            return CdpError.InvalidResponse;

        return try self.allocator.dupe(u8, response[id_start..id_end]);
    }

    pub fn deinit(self: *CdpClient) void {
        if (self.session_id) |sid| self.allocator.free(sid);
        if (self.current_target_id) |tid| self.allocator.free(tid);
        // Clean up screencast frame
        self.frame_mutex.lock();
        if (self.latest_frame) |*frame| {
            frame.deinit();
        }
        self.latest_frame = null;
        self.frame_mutex.unlock();
        self.pipe_client.deinit();
        self.allocator.destroy(self);
    }

    /// Format a command with sessionId for page-level commands
    fn formatSessionCommand(self: *CdpClient, method: []const u8, params: ?[]const u8) ![]const u8 {
        if (self.session_id) |sid| {
            if (params) |p| {
                return try std.fmt.allocPrint(
                    self.allocator,
                    "{{\"sessionId\":\"{s}\",\"method\":\"{s}\",\"params\":{s}}}",
                    .{ sid, method, p },
                );
            } else {
                return try std.fmt.allocPrint(
                    self.allocator,
                    "{{\"sessionId\":\"{s}\",\"method\":\"{s}\"}}",
                    .{ sid, method },
                );
            }
        } else {
            // No session - shouldn't happen after init
            return CdpError.InvalidResponse;
        }
    }

    /// Send mouse command (fire-and-forget via pipe)
    /// Silently ignores errors - safe during shutdown
    pub fn sendMouseCommandAsync(
        self: *CdpClient,
        method: []const u8,
        params: ?[]const u8,
    ) void {
        if (self.session_id) |sid| {
            self.pipe_client.sendSessionCommandAsync(sid, method, params) catch {};
        } else {
            self.pipe_client.sendCommandAsync(method, params) catch {};
        }
    }

    /// Send keyboard command (fire-and-forget via pipe)
    /// Silently ignores errors - safe during shutdown
    pub fn sendKeyboardCommandAsync(
        self: *CdpClient,
        method: []const u8,
        params: ?[]const u8,
    ) void {
        if (self.session_id) |sid| {
            self.pipe_client.sendSessionCommandAsync(sid, method, params) catch {};
        } else {
            self.pipe_client.sendCommandAsync(method, params) catch {};
        }
    }

    /// Send navigation command and wait for response (via pipe)
    pub fn sendNavCommand(
        self: *CdpClient,
        method: []const u8,
        params: ?[]const u8,
    ) ![]u8 {
        return self.sendCommand(method, params);
    }

    /// Send navigation command (fire-and-forget via pipe)
    pub fn sendNavCommandAsync(
        self: *CdpClient,
        method: []const u8,
        params: ?[]const u8,
    ) void {
        self.sendCommandAsync(method, params) catch {};
    }

    /// Send CDP command and wait for response via pipe
    pub fn sendCommand(
        self: *CdpClient,
        method: []const u8,
        params: ?[]const u8,
    ) ![]u8 {
        if (self.session_id) |sid| {
            return self.pipe_client.sendSessionCommand(sid, method, params);
        }
        return self.pipe_client.sendCommand(method, params);
    }

    /// Send CDP command without waiting for response via pipe
    pub fn sendCommandAsync(
        self: *CdpClient,
        method: []const u8,
        params: ?[]const u8,
    ) !void {
        if (self.session_id) |sid| {
            return self.pipe_client.sendSessionCommandAsync(sid, method, params);
        }
        return self.pipe_client.sendCommandAsync(method, params);
    }

    /// Send CDP command async and return command ID for polling
    /// Use pollResponse() to check for the response
    pub fn sendCommandAsyncWithId(
        self: *CdpClient,
        method: []const u8,
        params: ?[]const u8,
    ) !u32 {
        if (self.session_id) |sid| {
            return self.pipe_client.sendSessionCommandAsyncWithId(sid, method, params);
        }
        return self.pipe_client.sendCommandAsyncWithId(method, params);
    }

    /// Poll for response by command ID (non-blocking)
    /// Returns response payload if available, null otherwise
    /// Caller owns the returned memory
    pub fn pollResponse(self: *CdpClient, id: u32) ?[]u8 {
        return self.pipe_client.pollResponse(id);
    }

    /// Check if Chrome closed the pipe (detected by reader thread)
    pub fn isPipeBroken(self: *CdpClient) bool {
        return self.pipe_client.isPipeBroken();
    }

    /// Send browser-level command async (no session ID) and return ID
    pub fn sendBrowserCommandAsyncWithId(
        self: *CdpClient,
        method: []const u8,
        params: ?[]const u8,
    ) !u32 {
        return self.pipe_client.sendCommandAsyncWithId(method, params);
    }

    /// Load unpacked extension via CDP Extensions.loadUnpacked
    /// Requires --enable-unsafe-extension-debugging flag on Chrome launch
    /// Returns the extension ID on success, null on failure
    pub fn loadUnpackedExtension(self: *CdpClient, extension_path: []const u8) ?[]const u8 {
        logToFile("[CDP] Loading unpacked extension from: {s}\n", .{extension_path});

        // Build params JSON with escaped path
        var params_buf: [2048]u8 = undefined;
        const params = std.fmt.bufPrint(&params_buf, "{{\"path\":\"{s}\"}}", .{extension_path}) catch {
            logToFile("[CDP] Failed to build params for Extensions.loadUnpacked\n", .{});
            return null;
        };

        // Send Extensions.loadUnpacked command via pipe
        const result = self.sendCommand("Extensions.loadUnpacked", params) catch |err| {
            logToFile("[CDP] Extensions.loadUnpacked failed: {}\n", .{err});
            return null;
        };
        defer self.allocator.free(result);

        logToFile("[CDP] Extensions.loadUnpacked result: {s}\n", .{result[0..@min(result.len, 500)]});

        // Parse result to get extension ID
        // Response format: {"id":"<message_id>","result":{"id":"extension_id"}}
        const id_marker = "\"id\":\"";
        // Find the second occurrence (first is message id, second is extension id in result)
        var search_start: usize = 0;
        if (std.mem.indexOf(u8, result, id_marker)) |first_pos| {
            search_start = first_pos + id_marker.len;
            // Find closing quote
            if (std.mem.indexOfPos(u8, result, search_start, "\"")) |first_end| {
                search_start = first_end + 1;
            }
        }

        if (std.mem.indexOfPos(u8, result, search_start, id_marker)) |id_start| {
            const ext_id_start = id_start + id_marker.len;
            if (std.mem.indexOfPos(u8, result, ext_id_start, "\"")) |ext_id_end| {
                const extension_id = result[ext_id_start..ext_id_end];
                logToFile("[CDP] Extension loaded with ID: {s}\n", .{extension_id});
                // Duplicate the string since we're freeing result
                return self.allocator.dupe(u8, extension_id) catch null;
            }
        }

        logToFile("[CDP] Could not parse extension ID from response\n", .{});
        return null;
    }

    /// Get next event from pipe's event queue
    /// INTERCEPTS session/target events to fix race conditions
    pub fn nextEvent(self: *CdpClient, allocator: std.mem.Allocator) !?CdpEvent {
        _ = allocator;

        if (self.pipe_client.nextEvent()) |raw| {
            // DEBUG: Log all Target.* events to verify Chrome is sending data
            if (std.mem.startsWith(u8, raw.method, "Target.")) {
                logToFile("[CDP RX] {s}\n", .{raw.method});
            }

            // INTERCEPT: Capture Session ID from attachedToTarget event
            // This fixes the race where viewer.nextEvent() consumes the event
            // before pollReattachResponse() can see it
            if (std.mem.eql(u8, raw.method, "Target.attachedToTarget")) {
                logToFile("[CDP] Intercepted attachedToTarget, payload len={}\n", .{raw.payload.len});
                if (self.extractSessionIdFromPayload(raw.payload)) |new_sid| {
                    if (self.session_id) |old| self.allocator.free(old);
                    self.session_id = new_sid;
                    self.reattach_pending = false; // Unblock immediately
                    logToFile("[CDP] Intercepted attachedToTarget SUCCESS (SID: {s})\n", .{new_sid});
                } else |err| {
                    logToFile("[CDP] Intercepted attachedToTarget PARSE FAILED: {}\n", .{err});
                    // Log first 500 chars of payload for debugging
                    const preview_len = @min(raw.payload.len, 500);
                    logToFile("[CDP] Payload preview: {s}\n", .{raw.payload[0..preview_len]});
                }
            }
            // INTERCEPT: Handle Target ID rotation during site isolation
            else if (std.mem.eql(u8, raw.method, "Target.targetInfoChanged")) {
                self.handleTargetInfoChanged(raw.payload);
            }

            return CdpEvent{
                .method = raw.method,
                .payload = raw.payload,
                .allocator = raw.allocator,
            };
        }
        return null;
    }

    /// Extract sessionId from payload (handles spaces after colon)
    fn extractSessionIdFromPayload(self: *CdpClient, payload: []const u8) ![]const u8 {
        const key = "\"sessionId\"";
        const key_pos = std.mem.indexOf(u8, payload, key) orelse return CdpError.InvalidResponse;

        // Scan forward for the opening quote of the value
        var i = key_pos + key.len;
        var found_quote = false;
        var val_start: usize = 0;

        while (i < payload.len) : (i += 1) {
            const c = payload[i];
            if (!found_quote) {
                if (c == '"') {
                    found_quote = true;
                    val_start = i + 1;
                }
            } else {
                if (c == '"') {
                    // Found closing quote
                    return try self.allocator.dupe(u8, payload[val_start..i]);
                }
            }
        }
        return CdpError.InvalidResponse;
    }

    /// Handle Target.targetInfoChanged - update target ID if it rotated
    fn handleTargetInfoChanged(self: *CdpClient, payload: []const u8) void {
        // Only care about "page" type targets
        if (std.mem.indexOf(u8, payload, "\"type\":\"page\"") == null) return;

        // Extract targetId
        const tid_marker = "\"targetId\":\"";
        const pos = std.mem.indexOf(u8, payload, tid_marker) orelse return;
        const id_start = pos + tid_marker.len;
        const id_end = std.mem.indexOfPos(u8, payload, id_start, "\"") orelse return;
        const new_tid = payload[id_start..id_end];

        // Check if it's different from current
        if (self.current_target_id) |current| {
            if (std.mem.eql(u8, current, new_tid)) return; // Same, no change
            self.allocator.free(current);
        }

        // Update to new target ID
        self.current_target_id = self.allocator.dupe(u8, new_tid) catch return;
        logToFile("[CDP] Intercepted targetInfoChanged (TID: {s})\n", .{new_tid});
    }

    /// Switch to a different target (for tab switching)
    /// Detaches from current session and attaches to new target via pipe
    pub fn switchToTarget(self: *CdpClient, target_id: []const u8) !void {
        logToFile("[CDP switchToTarget] START target={s}\n", .{target_id});

        // Detach from current session first (if any) to allow clean re-attach
        if (self.session_id) |old_sid| {
            logToFile("[CDP switchToTarget] Detaching from session: {s}\n", .{old_sid});
            var detach_buf: [256]u8 = undefined;
            const detach_params = std.fmt.bufPrint(&detach_buf, "{{\"sessionId\":\"{s}\"}}", .{old_sid}) catch "";
            if (detach_params.len > 0) {
                if (self.pipe_client.sendCommand("Target.detachFromTarget", detach_params)) |detach_result| {
                    self.allocator.free(detach_result);
                } else |err| {
                    logToFile("[CDP switchToTarget] Detach failed (continuing): {}\n", .{err});
                }
            }
            logToFile("[CDP switchToTarget] Detach done\n", .{});
        }

        // Activate the target in Chrome (brings it to focus)
        logToFile("[CDP switchToTarget] Activating target...\n", .{});
        var activate_buf: [256]u8 = undefined;
        const activate_params = std.fmt.bufPrint(&activate_buf, "{{\"targetId\":\"{s}\"}}", .{target_id}) catch return error.OutOfMemory;
        const activate_result = self.pipe_client.sendCommand("Target.activateTarget", activate_params) catch |err| {
            logToFile("[CDP switchToTarget] Target.activateTarget FAILED: {}\n", .{err});
            return err;
        };
        self.allocator.free(activate_result);
        logToFile("[CDP switchToTarget] Activate done\n", .{});

        // Attach to the target to get a new session
        logToFile("[CDP switchToTarget] Attaching to target...\n", .{});
        var escape_buf: [512]u8 = undefined;
        const escaped_id = json_utils.escapeContents(target_id, &escape_buf) catch return error.OutOfMemory;
        const params = try std.fmt.allocPrint(
            self.allocator,
            "{{\"targetId\":\"{s}\",\"flatten\":true}}",
            .{escaped_id},
        );
        defer self.allocator.free(params);

        const attach_response = self.pipe_client.sendCommand("Target.attachToTarget", params) catch |err| {
            logToFile("[CDP switchToTarget] Target.attachToTarget FAILED: {}\n", .{err});
            return err;
        };
        defer self.allocator.free(attach_response);
        logToFile("[CDP switchToTarget] Attach done\n", .{});

        // Extract and update session ID
        const new_session_id = self.extractSessionId(attach_response) catch |err| {
            logToFile("[CDP] Could not extract session ID: {}\n", .{err});
            return error.InvalidResponse;
        };

        // Free old session ID and set new one
        if (self.session_id) |old_sid| {
            self.allocator.free(old_sid);
        }
        self.session_id = new_session_id;

        // Update current target ID
        if (self.current_target_id) |old_tid| {
            self.allocator.free(old_tid);
        }
        self.current_target_id = try self.allocator.dupe(u8, target_id);

        logToFile("[CDP switchToTarget] Switched to target, new session: {s}\n", .{new_session_id});

        // Re-enable Page domain on the new session
        logToFile("[CDP switchToTarget] Enabling Page domain...\n", .{});
        const page_result = self.sendCommand("Page.enable", null) catch |err| {
            logToFile("[CDP switchToTarget] Page.enable FAILED: {}\n", .{err});
            return err;
        };
        self.allocator.free(page_result);
        logToFile("[CDP switchToTarget] Page.enable done\n", .{});
        logToFile("[CDP switchToTarget] END success\n", .{});
    }

    /// Get the current target ID
    pub fn getCurrentTargetId(self: *CdpClient) ?[]const u8 {
        return self.current_target_id;
    }

    /// Create a new target (tab) with the given URL
    /// Returns the new target ID
    pub fn createTarget(self: *CdpClient, url: []const u8) ![]const u8 {
        logToFile("[CDP] Creating new target: {s}\n", .{url});

        var buf: [512]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"url\":\"{s}\"}}", .{url}) catch return error.OutOfMemory;

        const result = self.pipe_client.sendCommand("Target.createTarget", params) catch |err| {
            logToFile("[CDP] Target.createTarget failed: {}\n", .{err});
            return err;
        };
        defer self.allocator.free(result);

        // Parse targetId from response: {"result":{"targetId":"..."}}
        const marker = "\"targetId\":\"";
        const start = std.mem.indexOf(u8, result, marker) orelse return error.InvalidResponse;
        const id_start = start + marker.len;
        const id_end = std.mem.indexOfPos(u8, result, id_start, "\"") orelse return error.InvalidResponse;
        return try self.allocator.dupe(u8, result[id_start..id_end]);
    }

    /// Create and immediately attach to a new target (optimized for new tab)
    /// Skips activation step since new targets are already focused
    /// Returns the new target ID (caller owns)
    pub fn createAndAttachTarget(self: *CdpClient, url: []const u8) ![]const u8 {
        logToFile("[CDP createAndAttach] START url={s}\n", .{url});

        // Create target via pipe
        var create_buf: [512]u8 = undefined;
        const create_params = std.fmt.bufPrint(&create_buf, "{{\"url\":\"{s}\"}}", .{url}) catch return error.OutOfMemory;

        const create_result = self.pipe_client.sendCommand("Target.createTarget", create_params) catch |err| {
            logToFile("[CDP createAndAttach] createTarget failed: {}\n", .{err});
            return err;
        };
        defer self.allocator.free(create_result);

        // Parse targetId
        const marker = "\"targetId\":\"";
        const start = std.mem.indexOf(u8, create_result, marker) orelse return error.InvalidResponse;
        const id_start = start + marker.len;
        const id_end = std.mem.indexOfPos(u8, create_result, id_start, "\"") orelse return error.InvalidResponse;
        const target_id = create_result[id_start..id_end];
        logToFile("[CDP createAndAttach] Created target: {s}\n", .{target_id});

        // Detach from current session (if any)
        if (self.session_id) |old_sid| {
            var detach_buf: [256]u8 = undefined;
            const detach_params = std.fmt.bufPrint(&detach_buf, "{{\"sessionId\":\"{s}\"}}", .{old_sid}) catch "";
            if (detach_params.len > 0) {
                if (self.pipe_client.sendCommand("Target.detachFromTarget", detach_params)) |r| {
                    self.allocator.free(r);
                } else |_| {}
            }
            self.allocator.free(old_sid);
            self.session_id = null;
        }

        // Attach to new target (skip activateTarget - new tabs are already focused)
        var escape_buf: [512]u8 = undefined;
        const escaped_id = json_utils.escapeContents(target_id, &escape_buf) catch return error.OutOfMemory;
        const attach_params = try std.fmt.allocPrint(self.allocator, "{{\"targetId\":\"{s}\",\"flatten\":true}}", .{escaped_id});
        defer self.allocator.free(attach_params);

        const attach_response = self.pipe_client.sendCommand("Target.attachToTarget", attach_params) catch |err| {
            logToFile("[CDP createAndAttach] attachToTarget failed: {}\n", .{err});
            return err;
        };
        defer self.allocator.free(attach_response);

        // Extract session ID
        const new_session_id = self.extractSessionId(attach_response) catch |err| {
            logToFile("[CDP createAndAttach] extractSessionId failed: {}\n", .{err});
            return error.InvalidResponse;
        };
        self.session_id = new_session_id;

        // Update current target ID
        if (self.current_target_id) |old_tid| {
            self.allocator.free(old_tid);
        }
        self.current_target_id = try self.allocator.dupe(u8, target_id);

        // Enable Page domain
        const page_result = self.sendCommand("Page.enable", null) catch |err| {
            logToFile("[CDP createAndAttach] Page.enable failed: {}\n", .{err});
            return err;
        };
        self.allocator.free(page_result);

        logToFile("[CDP createAndAttach] END success\n", .{});
        return try self.allocator.dupe(u8, target_id);
    }

    /// Close a target (for single-tab mode - close unwanted popups)
    pub fn closeTarget(self: *CdpClient, target_id: []const u8) !void {
        logToFile("[CDP] Closing target: {s}\n", .{target_id});

        var buf: [256]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"targetId\":\"{s}\"}}", .{target_id}) catch return error.OutOfMemory;

        const result = self.pipe_client.sendCommand("Target.closeTarget", params) catch |err| {
            logToFile("[CDP] Target.closeTarget failed: {}\n", .{err});
            return err;
        };
        self.allocator.free(result);
    }

    /// Get DevTools frontend URL for the current page
    /// Returns URL like: devtools://devtools/bundled/inspector.html?ws=...
    pub fn getDevToolsUrl(self: *CdpClient) ?[]const u8 {
        // Connect to Chrome's /json/list endpoint
        const stream = std.net.tcpConnectToHost(self.allocator, "127.0.0.1", self.debug_port) catch return null;
        defer stream.close();

        var request_buf: [128]u8 = undefined;
        const request = std.fmt.bufPrint(&request_buf, "GET /json/list HTTP/1.1\r\nHost: 127.0.0.1:{}\r\n\r\n", .{self.debug_port}) catch return null;
        _ = stream.write(request) catch return null;

        var buf: [8192]u8 = undefined;
        const n = stream.read(&buf) catch return null;
        const response = buf[0..n];

        // Find devtoolsFrontendUrl in response
        const marker = "\"devtoolsFrontendUrl\":\"";
        const start = std.mem.indexOf(u8, response, marker) orelse return null;
        const url_start = start + marker.len;
        const url_end = std.mem.indexOfPos(u8, response, url_start, "\"") orelse return null;
        const relative_url = response[url_start..url_end];

        // Convert relative URL to absolute
        // Chrome returns: /devtools/inspector.html?ws=...
        // We need: http://127.0.0.1:PORT/devtools/inspector.html?ws=...
        var url_buf: [512]u8 = undefined;
        const full_url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}{s}", .{ self.debug_port, relative_url }) catch return null;
        return self.allocator.dupe(u8, full_url) catch return null;
    }

    /// Start screencast streaming (event-driven frames)
    /// Pass exact viewport dimensions for 1:1 coordinate mapping
    pub fn startScreencast(
        self: *CdpClient,
        format: []const u8,
        quality: u8,
        width: u32,
        height: u32,
        every_nth_frame: u8,
    ) !void {
        var params_buf: [256]u8 = undefined;
        const params = std.fmt.bufPrint(&params_buf, "{{\"format\":\"{s}\",\"quality\":{d},\"maxWidth\":{d},\"maxHeight\":{d},\"everyNthFrame\":{d}}}", .{ format, quality, width, height, every_nth_frame }) catch return error.OutOfMemory;

        const result = try self.sendCommand("Page.startScreencast", params);
        self.allocator.free(result);

        self.screencast_active = true;
        logToFile("[CDP] Screencast started: {}x{} {s} q={}\n", .{ width, height, format, quality });
    }

    /// Stop screencast streaming
    pub fn stopScreencast(self: *CdpClient) !void {
        if (!self.screencast_active) return;

        const result = try self.sendCommand("Page.stopScreencast", null);
        self.allocator.free(result);

        self.screencast_active = false;
        logToFile("[CDP] Screencast stopped\n", .{});
    }

    /// Get latest screencast frame (non-blocking)
    /// Returns null if no new frame available
    /// Caller MUST call frame.deinit() when done to free memory
    pub fn getLatestFrame(self: *CdpClient) ?ScreencastFrame {
        self.frame_mutex.lock();
        defer self.frame_mutex.unlock();

        if (self.latest_frame) |frame| {
            // Move frame out (caller owns it now)
            self.latest_frame = null;
            return frame;
        }
        return null;
    }

    /// Store a new screencast frame (called when processing Page.screencastFrame event)
    pub fn storeScreencastFrame(self: *CdpClient, data: []const u8, session_id: u32, width: u32, height: u32) !void {
        self.frame_mutex.lock();
        defer self.frame_mutex.unlock();

        // Free old frame if any
        if (self.latest_frame) |*old| {
            old.deinit();
        }

        // Store new frame
        self.latest_frame = ScreencastFrame{
            .data = try self.allocator.dupe(u8, data),
            .session_id = session_id,
            .width = width,
            .height = height,
            .allocator = self.allocator,
        };
    }

    /// Acknowledge a screencast frame (must call after receiving)
    pub fn ackScreencastFrame(self: *CdpClient, session_id: u32) void {
        var params_buf: [64]u8 = undefined;
        const params = std.fmt.bufPrint(&params_buf, "{{\"sessionId\":{d}}}", .{session_id}) catch return;
        self.sendCommandAsync("Page.screencastFrameAck", params) catch {};
    }
};
