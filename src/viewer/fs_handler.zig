/// File System Access API handlers.
/// Implements native file system operations for web applications.
const std = @import("std");
const json = @import("../utils/json.zig");
const helpers = @import("helpers.zig");

/// Context needed for FS operations
pub const FsContext = struct {
    allocator: std.mem.Allocator,
    allowed_roots: []const []const u8,
    /// Callback to send response back to JavaScript
    send_response: *const fn (ctx: *anyopaque, id: u32, success: bool, data: []const u8) void,
    /// Opaque pointer to pass to callback
    callback_ctx: *anyopaque,
};

/// Check if path is within allowed roots
pub fn isPathAllowed(allowed_roots: []const []const u8, path: []const u8) bool {
    for (allowed_roots) |root| {
        if (std.mem.startsWith(u8, path, root)) {
            // Path is within or equal to allowed root
            // Make sure it's not escaping via ..
            if (std.mem.indexOf(u8, path, "..") == null) {
                return true;
            }
        }
    }
    return false;
}

/// Handle file system operation request
/// Format: id:type:path[:data]
pub fn handleFsRequest(
    allocator: std.mem.Allocator,
    allowed_roots: []const []const u8,
    request: []const u8,
    sendResponse: anytype,
) !void {
    // Parse id:type:path[:data]
    var iter = std.mem.splitScalar(u8, request, ':');
    const id_str = iter.next() orelse return;
    const op_type = iter.next() orelse return;
    const path = iter.next() orelse return;
    const data = iter.next(); // optional

    const id = std.fmt.parseInt(u32, id_str, 10) catch return;

    // Security check: path must be within allowed roots
    if (!isPathAllowed(allowed_roots, path)) {
        sendResponse(id, false, "\"Path not allowed\"");
        return;
    }

    // Dispatch to operation handler
    if (std.mem.eql(u8, op_type, "readdir")) {
        try handleReadDir(allocator, id, path, sendResponse);
    } else if (std.mem.eql(u8, op_type, "readfile")) {
        try handleReadFile(allocator, id, path, sendResponse);
    } else if (std.mem.eql(u8, op_type, "writefile")) {
        try handleWriteFile(allocator, id, path, data orelse "", sendResponse);
    } else if (std.mem.eql(u8, op_type, "stat")) {
        try handleStat(id, path, sendResponse);
    } else if (std.mem.eql(u8, op_type, "mkdir")) {
        try handleMkDir(id, path, sendResponse);
    } else if (std.mem.eql(u8, op_type, "remove")) {
        try handleRemove(id, path, data, sendResponse);
    } else if (std.mem.eql(u8, op_type, "createfile")) {
        try handleCreateFile(id, path, sendResponse);
    } else {
        sendResponse(id, false, "\"Unknown operation\"");
    }
}

/// Handle readdir operation
pub fn handleReadDir(
    allocator: std.mem.Allocator,
    id: u32,
    path: []const u8,
    sendResponse: anytype,
) !void {
    var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch {
        sendResponse(id, false, "\"Cannot open directory\"");
        return;
    };
    defer dir.close();

    // Build JSON array of entries
    var result_buf: [65536]u8 = undefined;
    var stream = std.io.fixedBufferStream(&result_buf);
    const writer = stream.writer();

    try writer.writeAll("[");
    var first = true;
    var iter = dir.iterate();
    var escape_buf: [1024]u8 = undefined;
    while (try iter.next()) |entry| {
        if (!first) try writer.writeAll(",");
        first = false;

        const is_dir = entry.kind == .directory;
        // Escape entry name for JSON (handles quotes, backslashes in filenames)
        const escaped_name = json.escapeContents(entry.name, &escape_buf) catch continue;
        try writer.print("{{\"name\":\"{s}\",\"isDirectory\":{s}}}", .{
            escaped_name,
            if (is_dir) "true" else "false",
        });
    }
    try writer.writeAll("]");

    sendResponse(id, true, stream.getWritten());
    _ = allocator;
}

/// Handle readfile operation
pub fn handleReadFile(
    allocator: std.mem.Allocator,
    id: u32,
    path: []const u8,
    sendResponse: anytype,
) !void {
    const file = std.fs.openFileAbsolute(path, .{}) catch {
        sendResponse(id, false, "\"Cannot open file\"");
        return;
    };
    defer file.close();

    const stat = file.stat() catch {
        sendResponse(id, false, "\"Cannot stat file\"");
        return;
    };

    // Read file content
    const content = file.readToEndAlloc(allocator, 100 * 1024 * 1024) catch {
        sendResponse(id, false, "\"File too large or read error\"");
        return;
    };
    defer allocator.free(content);

    // Base64 encode
    const base64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const base64_len = ((content.len + 2) / 3) * 4;
    const base64 = allocator.alloc(u8, base64_len) catch {
        sendResponse(id, false, "\"Out of memory\"");
        return;
    };
    defer allocator.free(base64);

    var i: usize = 0;
    var j: usize = 0;
    while (i < content.len) {
        const b0 = content[i];
        const b1: u8 = if (i + 1 < content.len) content[i + 1] else 0;
        const b2: u8 = if (i + 2 < content.len) content[i + 2] else 0;

        base64[j] = base64_alphabet[b0 >> 2];
        base64[j + 1] = base64_alphabet[((b0 & 0x03) << 4) | (b1 >> 4)];
        base64[j + 2] = if (i + 1 < content.len) base64_alphabet[((b1 & 0x0f) << 2) | (b2 >> 6)] else '=';
        base64[j + 3] = if (i + 2 < content.len) base64_alphabet[b2 & 0x3f] else '=';

        i += 3;
        j += 4;
    }

    // Get MIME type from extension
    const ext = if (std.mem.lastIndexOfScalar(u8, path, '.')) |dot|
        path[dot..]
    else
        "";
    const mime_type = helpers.getMimeType(ext);

    // Build response
    var response_buf: [131072]u8 = undefined;
    const last_modified = @divTrunc(stat.mtime, std.time.ns_per_ms);
    const response = std.fmt.bufPrint(&response_buf, "{{\"content\":\"{s}\",\"size\":{d},\"type\":\"{s}\",\"lastModified\":{d}}}", .{ base64, stat.size, mime_type, last_modified }) catch {
        sendResponse(id, false, "\"Response too large\"");
        return;
    };

    sendResponse(id, true, response);
}

/// Handle writefile operation
pub fn handleWriteFile(
    allocator: std.mem.Allocator,
    id: u32,
    path: []const u8,
    base64_data: []const u8,
    sendResponse: anytype,
) !void {
    // Base64 decode
    const decoded_len = (base64_data.len / 4) * 3;
    const decoded = allocator.alloc(u8, decoded_len) catch {
        sendResponse(id, false, "\"Out of memory\"");
        return;
    };
    defer allocator.free(decoded);

    var actual_len: usize = 0;
    var i: usize = 0;
    while (i + 4 <= base64_data.len) {
        const c0 = helpers.base64Decode(base64_data[i]);
        const c1 = helpers.base64Decode(base64_data[i + 1]);
        const c2 = helpers.base64Decode(base64_data[i + 2]);
        const c3 = helpers.base64Decode(base64_data[i + 3]);

        if (c0 == 255 or c1 == 255) break;

        decoded[actual_len] = (c0 << 2) | (c1 >> 4);
        actual_len += 1;

        if (c2 != 255) {
            decoded[actual_len] = ((c1 & 0x0f) << 4) | (c2 >> 2);
            actual_len += 1;
        }
        if (c3 != 255) {
            decoded[actual_len] = ((c2 & 0x03) << 6) | c3;
            actual_len += 1;
        }

        i += 4;
    }

    // Write to file
    const file = std.fs.createFileAbsolute(path, .{}) catch {
        sendResponse(id, false, "\"Cannot create file\"");
        return;
    };
    defer file.close();

    file.writeAll(decoded[0..actual_len]) catch {
        sendResponse(id, false, "\"Write error\"");
        return;
    };

    sendResponse(id, true, "true");
}

/// Handle stat operation
pub fn handleStat(id: u32, path: []const u8, sendResponse: anytype) !void {
    // Try as directory first
    if (std.fs.openDirAbsolute(path, .{})) |dir| {
        var d = dir;
        d.close();
        sendResponse(id, true, "{\"isDirectory\":true}");
        return;
    } else |_| {}

    // Try as file
    const file = std.fs.openFileAbsolute(path, .{}) catch {
        sendResponse(id, false, "\"Path not found\"");
        return;
    };
    defer file.close();

    const stat = file.stat() catch {
        sendResponse(id, false, "\"Cannot stat\"");
        return;
    };

    var response_buf: [256]u8 = undefined;
    const response = std.fmt.bufPrint(&response_buf, "{{\"isDirectory\":false,\"size\":{d}}}", .{stat.size}) catch return;

    sendResponse(id, true, response);
}

/// Handle mkdir operation
pub fn handleMkDir(id: u32, path: []const u8, sendResponse: anytype) !void {
    std.fs.makeDirAbsolute(path) catch |err| {
        if (err != error.PathAlreadyExists) {
            sendResponse(id, false, "\"Cannot create directory\"");
            return;
        }
    };
    sendResponse(id, true, "true");
}

/// Handle remove operation
pub fn handleRemove(id: u32, path: []const u8, recursive: ?[]const u8, sendResponse: anytype) !void {
    const is_recursive = if (recursive) |r| std.mem.eql(u8, r, "1") else false;

    // Try as directory first
    if (is_recursive) {
        std.fs.deleteTreeAbsolute(path) catch {
            sendResponse(id, false, "\"Cannot remove\"");
            return;
        };
    } else {
        std.fs.deleteDirAbsolute(path) catch {
            // Try as file
            std.fs.deleteFileAbsolute(path) catch {
                sendResponse(id, false, "\"Cannot remove\"");
                return;
            };
        };
    }
    sendResponse(id, true, "true");
}

/// Handle createfile operation
pub fn handleCreateFile(id: u32, path: []const u8, sendResponse: anytype) !void {
    const file = std.fs.createFileAbsolute(path, .{ .exclusive = false }) catch {
        sendResponse(id, false, "\"Cannot create file\"");
        return;
    };
    file.close();
    sendResponse(id, true, "true");
}
