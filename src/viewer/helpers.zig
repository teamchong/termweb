/// Utility functions for the viewer module.
/// Contains parsing helpers, MIME type detection, base64 decoding, etc.
const std = @import("std");
const ui_mod = @import("../ui/mod.zig");
const DialogType = ui_mod.DialogType;
const FilePickerMode = ui_mod.FilePickerMode;

/// Extract URL from navigation event payload
/// Page.frameNavigated: {"frame":{"id":"...","url":"https://example.com",...}}
/// Page.navigatedWithinDocument: {"frameId":"...","url":"https://example.com"}
pub fn extractUrlFromNavEvent(payload: []const u8) ?[]const u8 {
    // Try to find "url":" pattern
    const url_marker = "\"url\":\"";
    const url_start_idx = std.mem.indexOf(u8, payload, url_marker) orelse return null;
    const url_value_start = url_start_idx + url_marker.len;

    // Find the closing quote
    const url_end_idx = std.mem.indexOfPos(u8, payload, url_value_start, "\"") orelse return null;

    const url = payload[url_value_start..url_end_idx];

    // Skip about:blank and empty URLs
    if (url.len == 0 or std.mem.eql(u8, url, "about:blank")) return null;

    return url;
}

/// Parse dialog type from CDP event payload
pub fn parseDialogType(payload: []const u8) DialogType {
    // Look for "type":"alert"|"confirm"|"prompt"|"beforeunload"
    if (std.mem.indexOf(u8, payload, "\"type\":\"alert\"") != null) return .alert;
    if (std.mem.indexOf(u8, payload, "\"type\":\"confirm\"") != null) return .confirm;
    if (std.mem.indexOf(u8, payload, "\"type\":\"prompt\"") != null) return .prompt;
    if (std.mem.indexOf(u8, payload, "\"type\":\"beforeunload\"") != null) return .beforeunload;
    return .alert; // Default
}

/// Parse dialog message from CDP event payload
pub fn parseDialogMessage(allocator: std.mem.Allocator, payload: []const u8) ![]const u8 {
    // Look for "message":"..."
    const marker = "\"message\":\"";
    const start = std.mem.indexOf(u8, payload, marker) orelse return error.NotFound;
    const msg_start = start + marker.len;

    // Find closing quote (handle escaped quotes)
    var end = msg_start;
    while (end < payload.len) : (end += 1) {
        if (payload[end] == '"' and (end == msg_start or payload[end - 1] != '\\')) {
            break;
        }
    }

    if (end <= msg_start) return error.NotFound;

    return try allocator.dupe(u8, payload[msg_start..end]);
}

/// Parse default prompt text from CDP event payload
pub fn parseDefaultPrompt(allocator: std.mem.Allocator, payload: []const u8) ![]const u8 {
    // Look for "defaultPrompt":"..."
    const marker = "\"defaultPrompt\":\"";
    const start = std.mem.indexOf(u8, payload, marker) orelse return try allocator.dupe(u8, "");
    const text_start = start + marker.len;

    // Find closing quote
    var end = text_start;
    while (end < payload.len) : (end += 1) {
        if (payload[end] == '"' and (end == text_start or payload[end - 1] != '\\')) {
            break;
        }
    }

    if (end <= text_start) return try allocator.dupe(u8, "");

    return try allocator.dupe(u8, payload[text_start..end]);
}

/// Parse file chooser mode from CDP event payload
pub fn parseFileChooserMode(payload: []const u8) FilePickerMode {
    // Look for "mode":"selectSingle"|"selectMultiple"|"uploadFolder"
    if (std.mem.indexOf(u8, payload, "\"mode\":\"selectMultiple\"") != null) return .multiple;
    if (std.mem.indexOf(u8, payload, "\"mode\":\"uploadFolder\"") != null) return .folder;
    return .single; // Default
}

/// Get MIME type from file extension
pub fn getMimeType(ext: []const u8) []const u8 {
    const extensions = [_]struct { ext: []const u8, mime: []const u8 }{
        .{ .ext = ".html", .mime = "text/html" },
        .{ .ext = ".htm", .mime = "text/html" },
        .{ .ext = ".css", .mime = "text/css" },
        .{ .ext = ".js", .mime = "application/javascript" },
        .{ .ext = ".mjs", .mime = "application/javascript" },
        .{ .ext = ".json", .mime = "application/json" },
        .{ .ext = ".xml", .mime = "application/xml" },
        .{ .ext = ".txt", .mime = "text/plain" },
        .{ .ext = ".md", .mime = "text/markdown" },
        .{ .ext = ".png", .mime = "image/png" },
        .{ .ext = ".jpg", .mime = "image/jpeg" },
        .{ .ext = ".jpeg", .mime = "image/jpeg" },
        .{ .ext = ".gif", .mime = "image/gif" },
        .{ .ext = ".svg", .mime = "image/svg+xml" },
        .{ .ext = ".ico", .mime = "image/x-icon" },
        .{ .ext = ".webp", .mime = "image/webp" },
        .{ .ext = ".pdf", .mime = "application/pdf" },
        .{ .ext = ".zip", .mime = "application/zip" },
        .{ .ext = ".tar", .mime = "application/x-tar" },
        .{ .ext = ".gz", .mime = "application/gzip" },
        .{ .ext = ".wasm", .mime = "application/wasm" },
        .{ .ext = ".ts", .mime = "application/typescript" },
        .{ .ext = ".tsx", .mime = "application/typescript" },
        .{ .ext = ".jsx", .mime = "application/javascript" },
        .{ .ext = ".py", .mime = "text/x-python" },
        .{ .ext = ".rs", .mime = "text/x-rust" },
        .{ .ext = ".go", .mime = "text/x-go" },
        .{ .ext = ".zig", .mime = "text/x-zig" },
        .{ .ext = ".c", .mime = "text/x-c" },
        .{ .ext = ".cpp", .mime = "text/x-c++" },
        .{ .ext = ".h", .mime = "text/x-c" },
        .{ .ext = ".hpp", .mime = "text/x-c++" },
    };

    for (extensions) |e| {
        if (std.mem.eql(u8, ext, e.ext)) {
            return e.mime;
        }
    }
    return "application/octet-stream";
}

/// Decode a single base64 character
pub fn base64Decode(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c - 'A';
    if (c >= 'a' and c <= 'z') return c - 'a' + 26;
    if (c >= '0' and c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return 255; // Invalid or padding ('=')
}

/// Check if an environment variable is truthy (1, true, yes)
pub fn envVarTruthy(allocator: std.mem.Allocator, name: []const u8) bool {
    const value = std.process.getEnvVarOwned(allocator, name) catch return false;
    defer allocator.free(value);

    return std.mem.eql(u8, value, "1") or
        std.mem.eql(u8, value, "true") or
        std.mem.eql(u8, value, "yes");
}

/// Detect if macOS natural scrolling is enabled
/// Returns true if natural scrolling is ON (default on macOS)
pub fn isNaturalScrollEnabled() bool {
    // Check override env var first
    const override = std.process.getEnvVarOwned(std.heap.page_allocator, "TERMWEB_NATURAL_SCROLL") catch null;
    if (override) |val| {
        defer std.heap.page_allocator.free(val);
        if (std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false")) return false;
        if (std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true")) return true;
    }

    // On macOS, read system preference
    // `defaults read NSGlobalDomain com.apple.swipescrolldirection` returns 1 for natural
    const result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &[_][]const u8{
            "defaults", "read", "NSGlobalDomain", "com.apple.swipescrolldirection",
        },
    }) catch return true; // Default to natural scroll if can't detect
    defer std.heap.page_allocator.free(result.stdout);
    defer std.heap.page_allocator.free(result.stderr);

    // Trim whitespace and check value
    const trimmed = std.mem.trim(u8, result.stdout, " \t\n\r");
    return !std.mem.eql(u8, trimmed, "0"); // 1 or missing = natural scroll
}
