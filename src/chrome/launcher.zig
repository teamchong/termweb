const std = @import("std");
const detector = @import("detector.zig");

pub const LaunchError = error{
    ChromeNotFound,
    LaunchFailed,
    TimeoutWaitingForDebugUrl,
    InvalidDebugUrl,
    OutOfMemory,
};

pub const ChromeInstance = struct {
    process: std.process.Child,
    ws_url: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ChromeInstance) void {
        // Terminate Chrome process
        _ = self.process.kill() catch {};
        self.allocator.free(self.ws_url);
    }
};

pub const LaunchOptions = struct {
    headless: bool = true,
    viewport_width: u32 = 1280,
    viewport_height: u32 = 720,
    user_data_dir: ?[]const u8 = null,
    disable_gpu: bool = false,
    /// Specific browser to use by name (e.g., "chrome", "edge", "brave")
    browser: ?[]const u8 = null,
    /// Direct path to browser binary (takes precedence over browser name)
    browser_path: ?[]const u8 = null,
};

/// Launch Chrome with CDP and return WebSocket URL
pub fn launchChrome(
    allocator: std.mem.Allocator,
    options: LaunchOptions,
) !ChromeInstance {
    // 1. Detect browser binary (browser_path takes precedence over browser name)
    var chrome_bin: detector.ChromeBinary = undefined;
    var owns_path = true;

    if (options.browser_path) |path| {
        // Direct path provided - use it directly (no allocation needed)
        chrome_bin = detector.ChromeBinary{
            .path = path,
            .allocator = allocator,
        };
        owns_path = false; // Don't free, we don't own it
    } else if (options.browser) |browser_name| {
        chrome_bin = detector.detectBrowserByName(allocator, browser_name) catch {
            return LaunchError.ChromeNotFound;
        };
    } else {
        chrome_bin = detector.detectChrome(allocator) catch {
            return LaunchError.ChromeNotFound;
        };
    }
    defer if (owns_path) chrome_bin.deinit();

    // 2. Create temporary user data directory if not provided
    var temp_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const user_data_dir = if (options.user_data_dir) |dir|
        dir
    else blk: {
        const temp_dir = std.fmt.bufPrint(&temp_dir_buf, "/tmp/termweb-chrome-{d}", .{
            std.time.timestamp(),
        }) catch return LaunchError.OutOfMemory;

        std.fs.cwd().makeDir(temp_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return LaunchError.LaunchFailed,
        };
        break :blk temp_dir;
    };

    // 3. Build Chrome arguments
    var args = try std.ArrayList([]const u8).initCapacity(allocator, 16);
    defer args.deinit(allocator);

    try args.append(allocator, chrome_bin.path);

    // Headless mode (use new headless as of Chrome 118+)
    if (options.headless) {
        try args.append(allocator, "--headless=new");
    }

    // Remote debugging with auto-assigned port
    try args.append(allocator, "--remote-debugging-port=0");

    // User data directory
    const user_data_arg = try std.fmt.allocPrint(allocator, "--user-data-dir={s}", .{user_data_dir});
    defer allocator.free(user_data_arg);
    try args.append(allocator, user_data_arg);

    // Additional flags for stability and performance
    try args.append(allocator, "--no-first-run");
    try args.append(allocator, "--no-default-browser-check");
    try args.append(allocator, "--allow-file-access-from-files");
    if (options.disable_gpu) {
        try args.append(allocator, "--disable-gpu");
    }

    // Viewport size
    const window_size = try std.fmt.allocPrint(
        allocator,
        "--window-size={d},{d}",
        .{ options.viewport_width, options.viewport_height },
    );
    defer allocator.free(window_size);
    try args.append(allocator, window_size);

    // Blank page (we'll navigate via CDP)
    try args.append(allocator, "about:blank");

    // 4. Spawn Chrome process
    var child = std.process.Child.init(args.items, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    // 5. Extract WebSocket URL from Chrome stderr
    const ws_url = try extractDebugUrl(allocator, child.stderr.?);

    return ChromeInstance{
        .process = child,
        .ws_url = ws_url,
        .allocator = allocator,
    };
}

/// Extract WebSocket URL from Chrome stderr output
/// Reads until it finds "DevTools listening on ws://..." line
fn extractDebugUrl(allocator: std.mem.Allocator, stderr: std.fs.File) ![]const u8 {
    // Read stderr output in chunks
    var output_buf: [8192]u8 = undefined;
    var total_read: usize = 0;

    // Wait up to 10 seconds for Chrome to print debug URL (profiles can be slow)
    const timeout_ns = 10 * std.time.ns_per_s;
    const start_time = std.time.nanoTimestamp();

    while (std.time.nanoTimestamp() - start_time < timeout_ns) {
        const bytes_read = stderr.read(output_buf[total_read..]) catch {
            std.Thread.sleep(100 * std.time.ns_per_ms);
            continue;
        };

        if (bytes_read == 0) {
            std.Thread.sleep(100 * std.time.ns_per_ms);
            continue;
        }

        total_read += bytes_read;

        // Look for "DevTools listening on ws://" in accumulated output
        const output_so_far = output_buf[0..total_read];
        if (std.mem.indexOf(u8, output_so_far, "DevTools listening on ws://")) |idx| {
            const ws_start = idx + "DevTools listening on ".len;
            // Find end of URL (newline or end of buffer)
            const url_end = std.mem.indexOfAnyPos(u8, output_so_far, ws_start, "\r\n") orelse output_so_far.len;
            const url = std.mem.trim(u8, output_so_far[ws_start..url_end], " \r\n\t");

            if (std.mem.startsWith(u8, url, "ws://")) {
                return try allocator.dupe(u8, url);
            }
        }
    }

    // Debug: print what we got from Chrome
    if (total_read > 0) {
        std.debug.print("\n[DEBUG] Chrome stderr output ({} bytes):\n{s}\n", .{ total_read, output_buf[0..total_read] });
    } else {
        std.debug.print("\n[DEBUG] Chrome produced no stderr output\n", .{});
    }

    return LaunchError.TimeoutWaitingForDebugUrl;
}
