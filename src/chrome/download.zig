/// Download handling for Chrome DevTools Protocol
///
/// Provides:
/// - Enable downloads with Browser.setDownloadBehavior
/// - Handle Page.downloadWillBegin events
/// - Handle Browser.downloadProgress events
/// - Track downloads and signal completion to the viewer for save prompt
const std = @import("std");
const cdp = @import("cdp_client.zig");

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

/// Info about a completed download, returned to the caller for save prompt.
/// The temp file at source_path is owned by the caller — they must either
/// copy it somewhere or delete it.
pub const CompletedDownload = struct {
    source_path: []const u8, // owned, caller must free
    suggested_filename: []const u8, // owned, caller must free
};

/// Active downloads tracking
pub const DownloadManager = struct {
    allocator: std.mem.Allocator,
    downloads: std.StringHashMap(DownloadState),
    download_path: []const u8, // Chrome's temp download directory

    pub fn init(allocator: std.mem.Allocator, download_path: []const u8) DownloadManager {
        return .{
            .allocator = allocator,
            .downloads = std.StringHashMap(DownloadState).init(allocator),
            .download_path = download_path,
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
    }

    /// Register download tracking. No UI is shown here — the viewer handles
    /// the save prompt after the download completes.
    pub fn handleDownloadWillBegin(
        self: *DownloadManager,
        guid: []const u8,
        url: []const u8,
        suggested_filename: []const u8,
    ) !void {
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

    /// Handle downloadProgress event. When completed, returns a CompletedDownload
    /// with the temp file path and suggested filename. The caller owns both strings
    /// and the temp file — they must copy/delete it and free the strings.
    /// Returns null for in-progress or canceled downloads.
    pub fn handleDownloadProgress(
        self: *DownloadManager,
        guid: []const u8,
        state: []const u8,
        received_bytes: u64,
        total_bytes: u64,
    ) ?CompletedDownload {
        const download = self.downloads.getPtr(guid) orelse return null;

        download.received_bytes = received_bytes;
        download.total_bytes = total_bytes;

        if (std.mem.eql(u8, state, "completed")) {
            download.state = .completed;

            // Build temp file path (Chrome saves with GUID as filename)
            const source_path = std.fmt.allocPrint(
                self.allocator,
                "{s}/{s}",
                .{ self.download_path, guid },
            ) catch return null;

            // Copy suggested filename before removing from tracking
            const filename = self.allocator.dupe(u8, download.suggested_filename) catch {
                self.allocator.free(source_path);
                return null;
            };

            // Remove from tracking (frees the tracking copies)
            if (self.downloads.fetchRemove(guid)) |entry| {
                self.allocator.free(entry.key);
                self.allocator.free(entry.value.url);
                self.allocator.free(entry.value.suggested_filename);
            }

            return .{
                .source_path = source_path,
                .suggested_filename = filename,
            };
        } else if (std.mem.eql(u8, state, "canceled")) {
            download.state = .canceled;

            // Delete temp file
            const source_path = std.fmt.allocPrint(
                self.allocator,
                "{s}/{s}",
                .{ self.download_path, guid },
            ) catch {
                self.removeDownload(guid);
                return null;
            };
            defer self.allocator.free(source_path);
            std.fs.deleteFileAbsolute(source_path) catch {};

            self.removeDownload(guid);
        }

        return null;
    }

    fn removeDownload(self: *DownloadManager, guid: []const u8) void {
        if (self.downloads.fetchRemove(guid)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value.url);
            self.allocator.free(entry.value.suggested_filename);
        }
    }
};

/// Copy a file from source to destination
pub fn copyFile(source: []const u8, dest: []const u8) !void {
    const source_file = try std.fs.openFileAbsolute(source, .{});
    defer source_file.close();

    // Ensure parent directory exists
    if (std.mem.lastIndexOfScalar(u8, dest, '/')) |sep| {
        std.fs.makeDirAbsolute(dest[0..sep]) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

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
        "{{\"behavior\":\"allowAndName\",\"downloadPath\":\"{s}\",\"eventsEnabled\":true}}",
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
