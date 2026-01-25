/// Extension setup for termweb Chrome bridge.
/// Extracts embedded extension files to a temporary directory at runtime.
const std = @import("std");
const builtin = @import("builtin");

/// Embedded extension files (compile-time)
const manifest_json = @embedFile("extension/manifest.json");
const content_js = @embedFile("extension/content.js");
const bridge_js = @embedFile("extension/termweb-bridge.js");

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

    // Set restrictive permissions (owner only: rwx) - works on both macOS and Linux
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{ext_dir_path}) catch return error.OutOfMemory;
    _ = std.c.chmod(path_z.ptr, 0o700);

    // Open the directory and write extension files
    var dir = try std.fs.cwd().openDir(ext_dir_path, .{});
    defer dir.close();

    try writeFile(dir, "manifest.json", manifest_json);
    try writeFile(dir, "content.js", content_js);
    try writeFile(dir, "termweb-bridge.js", bridge_js);

    if (verbose) {
        std.debug.print("Extension extracted to: {s}\n", .{ext_dir_path});
    }

    return ext_dir_path;
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
