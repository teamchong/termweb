/// Extension setup for termweb Chrome bridge.
/// Extracts embedded extension files to a temporary directory at runtime.
const std = @import("std");
const builtin = @import("builtin");

/// Embedded extension files (compile-time)
const manifest_json = @embedFile("extension/manifest.json");
const content_js = @embedFile("extension/content.js");
const bridge_js = @embedFile("extension/termweb-bridge.js");
const background_js = @embedFile("extension/background.js");
const offscreen_html = @embedFile("extension/offscreen.html");
const offscreen_js = @embedFile("extension/offscreen.js");

/// Prefix for temporary extension directories
pub const EXTENSION_DIR_PREFIX = "termweb-ext-";

/// Generate a random hex string for unique directory names
fn randomHex(buf: []u8) void {
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    var rng = std.Random.DefaultPrng.init(seed);
    for (buf) |*c| {
        const val = rng.random().int(u4);
        c.* = "0123456789abcdef"[val];
    }
}

/// Write a file with restricted permissions
fn writeFile(dir: std.fs.Dir, filename: []const u8, content: []const u8) !void {
    var file = try dir.createFile(filename, .{ .mode = 0o644 });
    defer file.close();
    try file.writeAll(content);
}

/// Set up the extension by extracting embedded files to a temporary directory.
/// Returns the path to the extension directory (caller owns the memory).
/// The directory is created with restrictive permissions (0700).
pub fn setupExtension(allocator: std.mem.Allocator, verbose: bool) ![]const u8 {
    // Determine temp directory base
    const tmp_base_raw = if (builtin.os.tag == .macos)
        std.posix.getenv("TMPDIR") orelse "/tmp"
    else
        "/tmp";

    // Convert to slice and strip trailing slash if present (macOS TMPDIR includes it)
    var tmp_base: []const u8 = tmp_base_raw;
    if (tmp_base.len > 0 and tmp_base[tmp_base.len - 1] == '/') {
        tmp_base = tmp_base[0 .. tmp_base.len - 1];
    }

    // Generate unique directory name
    var random_suffix: [16]u8 = undefined;
    randomHex(&random_suffix);

    const ext_dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}{s}", .{
        tmp_base,
        EXTENSION_DIR_PREFIX,
        random_suffix,
    });
    errdefer allocator.free(ext_dir_path);

    // Create directory
    std.fs.cwd().makePath(ext_dir_path) catch |err| {
        if (verbose) {
            std.debug.print("Failed to create extension dir: {}\n", .{err});
        }
        return err;
    };

    // Set permissions to allow Chrome subprocess access (0755)
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{ext_dir_path}) catch return error.OutOfMemory;
    _ = std.c.chmod(path_z.ptr, 0o755);

    // Open the directory and write extension files
    var dir = try std.fs.cwd().openDir(ext_dir_path, .{});
    defer dir.close();

    try writeFile(dir, "manifest.json", manifest_json);
    try writeFile(dir, "content.js", content_js);
    try writeFile(dir, "termweb-bridge.js", bridge_js);
    try writeFile(dir, "background.js", background_js);
    try writeFile(dir, "offscreen.html", offscreen_html);
    try writeFile(dir, "offscreen.js", offscreen_js);

    // Always log extension path and contents to debug file
    if (std.fs.cwd().createFile("extension_debug.log", .{})) |f| {
        defer f.close();
        var buf: [2048]u8 = undefined;

        // Log extension path
        const path_msg = std.fmt.bufPrint(&buf, "Extension extracted to: {s}\n", .{ext_dir_path}) catch "";
        _ = f.write(path_msg) catch {};

        // List files in the extension directory to verify extraction
        _ = f.write("Files in extension directory:\n") catch {};
        var ext_dir = std.fs.cwd().openDir(ext_dir_path, .{ .iterate = true }) catch {
            _ = f.write("  ERROR: Could not open extension directory!\n") catch {};
            return ext_dir_path;
        };
        defer ext_dir.close();

        var iter = ext_dir.iterate();
        while (iter.next() catch null) |entry| {
            const entry_msg = std.fmt.bufPrint(&buf, "  - {s} ({s})\n", .{
                entry.name,
                @tagName(entry.kind),
            }) catch continue;
            _ = f.write(entry_msg) catch {};
        }

        // Also log manifest.json first line to verify content
        _ = f.write("Manifest content (first 200 chars):\n  ") catch {};
        _ = f.write(manifest_json[0..@min(200, manifest_json.len)]) catch {};
        _ = f.write("\n") catch {};
    } else |_| {}

    if (verbose) {
        std.debug.print("Extension extracted to: {s}\n", .{ext_dir_path});
    }

    return ext_dir_path;
}

/// Fixed extension ID for termweb (32 lowercase letters a-p only)
/// Chrome extension IDs use base16 with a-p instead of 0-9a-f
const TERMWEB_EXTENSION_ID = "abcdefghijklmnopabcdefghijklmnop";

/// Install extension directly into Chrome profile directory.
/// This installs into {user_data_dir}/Default/Extensions/{id}/1.0.0/
pub fn installExtensionToProfile(allocator: std.mem.Allocator, user_data_dir: []const u8, verbose: bool) !void {
    // Create extension directory path with proper extension ID
    const ext_dir_path = try std.fmt.allocPrint(allocator, "{s}/Default/Extensions/{s}/1.0.0", .{ user_data_dir, TERMWEB_EXTENSION_ID });
    defer allocator.free(ext_dir_path);

    // Create directory structure
    std.fs.cwd().makePath(ext_dir_path) catch |err| {
        if (verbose) {
            std.debug.print("Failed to create profile extension dir: {}\n", .{err});
        }
        return err;
    };

    // Open the directory and write extension files
    var dir = try std.fs.cwd().openDir(ext_dir_path, .{});
    defer dir.close();

    try writeFile(dir, "manifest.json", manifest_json);
    try writeFile(dir, "content.js", content_js);
    try writeFile(dir, "termweb-bridge.js", bridge_js);
    try writeFile(dir, "background.js", background_js);
    try writeFile(dir, "offscreen.html", offscreen_html);
    try writeFile(dir, "offscreen.js", offscreen_js);

    // Create Secure Preferences file to register the extension
    const prefs_dir = try std.fmt.allocPrint(allocator, "{s}/Default", .{user_data_dir});
    defer allocator.free(prefs_dir);
    std.fs.cwd().makePath(prefs_dir) catch {};

    // Write Preferences file
    const prefs_path = try std.fmt.allocPrint(allocator, "{s}/Preferences", .{prefs_dir});
    defer allocator.free(prefs_path);

    var prefs_buf: [4096]u8 = undefined;
    const prefs_content = std.fmt.bufPrint(&prefs_buf,
        \\{{
        \\  "extensions": {{
        \\    "settings": {{
        \\      "{s}": {{
        \\        "active_permissions": {{
        \\          "api": ["clipboardRead", "clipboardWrite", "tabCapture", "activeTab", "tabs", "offscreen", "scripting"],
        \\          "explicit_host": ["<all_urls>"]
        \\        }},
        \\        "commands": {{}},
        \\        "content_settings": [],
        \\        "creation_flags": 1,
        \\        "events": [],
        \\        "from_webstore": false,
        \\        "granted_permissions": {{
        \\          "api": ["clipboardRead", "clipboardWrite", "tabCapture", "activeTab", "tabs", "offscreen", "scripting"],
        \\          "explicit_host": ["<all_urls>"]
        \\        }},
        \\        "incognito_content_settings": [],
        \\        "incognito_preferences": {{}},
        \\        "location": 4,
        \\        "manifest": {{
        \\          "background": {{"service_worker": "background.js"}},
        \\          "manifest_version": 3,
        \\          "name": "Termweb Bridge",
        \\          "permissions": ["clipboardRead", "clipboardWrite", "tabCapture", "activeTab", "tabs", "offscreen", "scripting"],
        \\          "version": "1.0.0"
        \\        }},
        \\        "path": "{s}/1.0.0",
        \\        "preferences": {{}},
        \\        "regular_only_preferences": {{}},
        \\        "state": 1,
        \\        "was_installed_by_default": false,
        \\        "was_installed_by_oem": false,
        \\        "withholding_permissions": false
        \\      }}
        \\    }}
        \\  }}
        \\}}
    , .{ TERMWEB_EXTENSION_ID, TERMWEB_EXTENSION_ID }) catch return error.OutOfMemory;

    var prefs_file = try std.fs.cwd().createFile(prefs_path, .{});
    defer prefs_file.close();
    try prefs_file.writeAll(prefs_content);

    if (verbose) {
        std.debug.print("Extension installed to profile: {s}\n", .{ext_dir_path});
    }
}

/// Clean up extension directory
pub fn cleanupExtension(path: []const u8) void {
    std.fs.cwd().deleteTree(path) catch {};
}

/// Clean up old extension directories (older than max_age_seconds)
pub fn cleanupOldExtensions(max_age_seconds: i64) void {
    const tmp_dir_path = if (builtin.os.tag == .macos)
        std.posix.getenv("TMPDIR") orelse "/tmp"
    else
        "/tmp";

    var dir = std.fs.cwd().openDir(tmp_dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    const now_ns = std.time.nanoTimestamp();
    var iter = dir.iterate();

    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (!std.mem.startsWith(u8, entry.name, EXTENSION_DIR_PREFIX)) continue;

        // Get directory metadata to check age
        const stat = dir.statFile(entry.name) catch continue;
        const mtime_ns = stat.mtime;
        const age_ns = now_ns - mtime_ns;
        const age_seconds = @divFloor(age_ns, std.time.ns_per_s);

        // Delete if older than max_age
        if (age_seconds > max_age_seconds) {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ tmp_dir_path, entry.name }) catch continue;
            std.fs.cwd().deleteTree(full_path) catch {};
        }
    }
}
