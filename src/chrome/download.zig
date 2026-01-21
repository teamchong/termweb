/// Download handling for Chrome DevTools Protocol
///
/// Provides:
/// - Enable downloads with Browser.setDownloadBehavior
/// - Handle Page.downloadWillBegin events
/// - Handle Browser.downloadProgress events
/// - Prompt user for save location and copy downloaded file
const std = @import("std");
const cdp = @import("cdp_client.zig");
const dialog = @import("../ui/dialog.zig");

/// Download state tracking
pub const DownloadState = struct {
    guid: []const u8,
    url: []const u8,
    suggested_filename: []const u8,
    state: State,
    received_bytes: u64,
    total_bytes: u64,

    pub const State = enum {
        in_progress,
        completed,
        canceled,
    };
};

/// Active downloads tracking
pub const DownloadManager = struct {
    allocator: std.mem.Allocator,
    downloads: std.StringHashMap(DownloadState),
    download_path: []const u8, // Chrome's temp download directory
    pending_save_path: ?[]const u8, // User-selected save path (for the current download)

    pub fn init(allocator: std.mem.Allocator, download_path: []const u8) DownloadManager {
        return .{
            .allocator = allocator,
            .downloads = std.StringHashMap(DownloadState).init(allocator),
            .download_path = download_path,
            .pending_save_path = null,
        };
    }

    pub fn deinit(self: *DownloadManager) void {
        var iter = self.downloads.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.url);
            self.allocator.free(entry.value_ptr.suggested_filename);
        }
        self.downloads.deinit();
        if (self.pending_save_path) |path| {
            self.allocator.free(path);
        }
    }

    /// Handle downloadWillBegin event - prompt user for save location
    pub fn handleDownloadWillBegin(
        self: *DownloadManager,
        guid: []const u8,
        url: []const u8,
        suggested_filename: []const u8,
    ) !void {
        // Prompt user for save location
        const save_path = try dialog.showNativeFilePickerWithName(
            self.allocator,
            .save,
            suggested_filename,
        );

        if (save_path) |path| {
            // Store the save path for when download completes
            if (self.pending_save_path) |old_path| {
                self.allocator.free(old_path);
            }
            self.pending_save_path = path;

            // Track the download
            const guid_copy = try self.allocator.dupe(u8, guid);
            const url_copy = try self.allocator.dupe(u8, url);
            const filename_copy = try self.allocator.dupe(u8, suggested_filename);

            try self.downloads.put(guid_copy, .{
                .guid = guid_copy,
                .url = url_copy,
                .suggested_filename = filename_copy,
                .state = .in_progress,
                .received_bytes = 0,
                .total_bytes = 0,
            });
        }
        // If user cancelled, download will still happen in temp dir but we won't move it
    }

    /// Handle downloadProgress event - track progress and copy file when complete
    pub fn handleDownloadProgress(
        self: *DownloadManager,
        guid: []const u8,
        state: []const u8,
        received_bytes: u64,
        total_bytes: u64,
    ) !void {
        if (self.downloads.getPtr(guid)) |download| {
            download.received_bytes = received_bytes;
            download.total_bytes = total_bytes;

            if (std.mem.eql(u8, state, "completed")) {
                download.state = .completed;

                // Copy file to user-selected location
                if (self.pending_save_path) |save_path| {
                    const source_path = try std.fmt.allocPrint(
                        self.allocator,
                        "{s}/{s}",
                        .{ self.download_path, download.suggested_filename },
                    );
                    defer self.allocator.free(source_path);

                    // Copy file
                    try copyFile(source_path, save_path);

                    // Clean up temp file
                    std.fs.deleteFileAbsolute(source_path) catch {};

                    self.allocator.free(save_path);
                    self.pending_save_path = null;
                }

                // Remove from tracking (free allocated strings first)
                if (self.downloads.fetchRemove(guid)) |entry| {
                    self.allocator.free(entry.key);
                    self.allocator.free(entry.value.url);
                    self.allocator.free(entry.value.suggested_filename);
                }
            } else if (std.mem.eql(u8, state, "canceled")) {
                download.state = .canceled;
                if (self.downloads.fetchRemove(guid)) |entry| {
                    self.allocator.free(entry.key);
                    self.allocator.free(entry.value.url);
                    self.allocator.free(entry.value.suggested_filename);
                }

                if (self.pending_save_path) |path| {
                    self.allocator.free(path);
                    self.pending_save_path = null;
                }
            }
        }
    }
};

/// Copy a file from source to destination
fn copyFile(source: []const u8, dest: []const u8) !void {
    const source_file = try std.fs.openFileAbsolute(source, .{});
    defer source_file.close();

    const dest_file = try std.fs.createFileAbsolute(dest, .{});
    defer dest_file.close();

    // Copy in chunks
    var buf: [8192]u8 = undefined;
    while (true) {
        const bytes_read = try source_file.read(&buf);
        if (bytes_read == 0) break;
        try dest_file.writeAll(buf[0..bytes_read]);
    }
}

/// Enable downloads in Chrome with a specific download path
pub fn enableDownloads(client: *cdp.CdpClient, allocator: std.mem.Allocator, download_path: []const u8) !void {
    // Browser.setDownloadBehavior
    const params = try std.fmt.allocPrint(
        allocator,
        "{{\"behavior\":\"allow\",\"downloadPath\":\"{s}\",\"eventsEnabled\":true}}",
        .{download_path},
    );
    defer allocator.free(params);

    // Use nav_ws - pipe is for screencast only
    const result = try client.sendNavCommand("Browser.setDownloadBehavior", params);
    defer allocator.free(result);
}

/// Parse downloadWillBegin event
pub fn parseDownloadWillBegin(payload: []const u8) ?struct {
    guid: []const u8,
    url: []const u8,
    suggested_filename: []const u8,
} {
    // Find guid
    const guid_start = std.mem.indexOf(u8, payload, "\"guid\":\"") orelse return null;
    const guid_v_start = guid_start + "\"guid\":\"".len;
    const guid_end = std.mem.indexOfPos(u8, payload, guid_v_start, "\"") orelse return null;
    const guid = payload[guid_v_start..guid_end];

    // Find url
    const url_start = std.mem.indexOf(u8, payload, "\"url\":\"") orelse return null;
    const url_v_start = url_start + "\"url\":\"".len;
    const url_end = std.mem.indexOfPos(u8, payload, url_v_start, "\"") orelse return null;
    const url = payload[url_v_start..url_end];

    // Find suggestedFilename
    const filename_start = std.mem.indexOf(u8, payload, "\"suggestedFilename\":\"") orelse return null;
    const filename_v_start = filename_start + "\"suggestedFilename\":\"".len;
    const filename_end = std.mem.indexOfPos(u8, payload, filename_v_start, "\"") orelse return null;
    const suggested_filename = payload[filename_v_start..filename_end];

    return .{
        .guid = guid,
        .url = url,
        .suggested_filename = suggested_filename,
    };
}

/// Parse downloadProgress event
pub fn parseDownloadProgress(payload: []const u8) ?struct {
    guid: []const u8,
    state: []const u8,
    received_bytes: u64,
    total_bytes: u64,
} {
    // Find guid
    const guid_start = std.mem.indexOf(u8, payload, "\"guid\":\"") orelse return null;
    const guid_v_start = guid_start + "\"guid\":\"".len;
    const guid_end = std.mem.indexOfPos(u8, payload, guid_v_start, "\"") orelse return null;
    const guid = payload[guid_v_start..guid_end];

    // Find state
    const state_start = std.mem.indexOf(u8, payload, "\"state\":\"") orelse return null;
    const state_v_start = state_start + "\"state\":\"".len;
    const state_end = std.mem.indexOfPos(u8, payload, state_v_start, "\"") orelse return null;
    const state = payload[state_v_start..state_end];

    // Find receivedBytes
    var received_bytes: u64 = 0;
    if (std.mem.indexOf(u8, payload, "\"receivedBytes\":")) |rb_start| {
        const rb_v_start = rb_start + "\"receivedBytes\":".len;
        var rb_end = rb_v_start;
        while (rb_end < payload.len and payload[rb_end] >= '0' and payload[rb_end] <= '9') : (rb_end += 1) {}
        received_bytes = std.fmt.parseInt(u64, payload[rb_v_start..rb_end], 10) catch 0;
    }

    // Find totalBytes
    var total_bytes: u64 = 0;
    if (std.mem.indexOf(u8, payload, "\"totalBytes\":")) |tb_start| {
        const tb_v_start = tb_start + "\"totalBytes\":".len;
        var tb_end = tb_v_start;
        while (tb_end < payload.len and payload[tb_end] >= '0' and payload[tb_end] <= '9') : (tb_end += 1) {}
        total_bytes = std.fmt.parseInt(u64, payload[tb_v_start..tb_end], 10) catch 0;
    }

    return .{
        .guid = guid,
        .state = state,
        .received_bytes = received_bytes,
        .total_bytes = total_bytes,
    };
}
