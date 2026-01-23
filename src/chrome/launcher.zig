const std = @import("std");
const detector = @import("detector.zig");

pub const LaunchError = error{
    ChromeNotFound,
    LaunchFailed,
    TimeoutWaitingForDebugUrl,
    InvalidDebugUrl,
    OutOfMemory,
    PipeSetupFailed,
};

/// WebSocket-based Chrome instance (legacy, for --connect mode)
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

/// Pipe-based Chrome instance (preferred for new launches)
/// Uses --remote-debugging-pipe for higher throughput
pub const ChromePipeInstance = struct {
    pid: std.posix.pid_t, // Chrome process ID
    read_fd: std.posix.fd_t, // FD to read from Chrome (Chrome's FD 4)
    write_fd: std.posix.fd_t, // FD to write to Chrome (Chrome's FD 3)
    user_data_dir: []const u8, // Path to temporary user data directory
    debug_port: u16, // Random port Chrome is listening on for WebSocket connections
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ChromePipeInstance) void {
        // NOTE: Pipe fds (read_fd, write_fd) are NOT closed here.
        // They are owned by PipeCdpClient which closes them in deinit/stopReaderThread.

        // Send SIGTERM to Chrome and wait for it to exit
        std.posix.kill(self.pid, std.posix.SIG.TERM) catch {};
        _ = std.posix.waitpid(self.pid, 0);

        // Recursively delete temporary user data directory
        std.fs.cwd().deleteTree(self.user_data_dir) catch {};
        self.allocator.free(self.user_data_dir);
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
    /// Clone from an existing Chrome profile (e.g., "Default", "Profile 1")
    /// Copies bookmarks, history, cookies, extensions, etc.
    /// Set to "Default" by default, use empty string "" to skip cloning
    clone_profile: ?[]const u8 = "Default",
};

/// Get Chrome user data directory path for the current platform
pub fn getChromeUserDataDir(allocator: std.mem.Allocator) ![]const u8 {
    const builtin = @import("builtin");
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return error.NoHomeDir;
    defer allocator.free(home);

    return switch (builtin.os.tag) {
        .macos => try std.fmt.allocPrint(allocator, "{s}/Library/Application Support/Google/Chrome", .{home}),
        .linux => try std.fmt.allocPrint(allocator, "{s}/.config/google-chrome", .{home}),
        else => error.UnsupportedPlatform,
    };
}

/// List available Chrome profiles
pub fn listProfiles(allocator: std.mem.Allocator) ![][]const u8 {
    const user_data_dir = try getChromeUserDataDir(allocator);
    defer allocator.free(user_data_dir);

    var profiles = try std.ArrayList([]const u8).initCapacity(allocator, 8);
    errdefer {
        for (profiles.items) |p| allocator.free(p);
        profiles.deinit(allocator);
    }

    var dir = std.fs.cwd().openDir(user_data_dir, .{ .iterate = true }) catch return try profiles.toOwnedSlice(allocator);

    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;

        // Check if this looks like a profile directory
        if (std.mem.eql(u8, entry.name, "Default") or
            std.mem.startsWith(u8, entry.name, "Profile "))
        {
            // Verify it has a Preferences file
            var profile_dir = dir.openDir(entry.name, .{}) catch continue;
            defer profile_dir.close();
            profile_dir.access("Preferences", .{}) catch continue;

            try profiles.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }

    return try profiles.toOwnedSlice(allocator);
}

/// Clone a Chrome profile to a temporary directory
/// Copies: Bookmarks, Cookies, History, Login Data, Preferences, Extensions
/// Skips: Sessions, Current Session, Current Tabs (to avoid lock conflicts)
fn cloneProfile(allocator: std.mem.Allocator, profile_name: []const u8, dest_dir: []const u8) !void {
    const user_data_dir = try getChromeUserDataDir(allocator);
    defer allocator.free(user_data_dir);

    const source_profile = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ user_data_dir, profile_name });
    defer allocator.free(source_profile);

    // Create destination profile directory
    const dest_profile = try std.fmt.allocPrint(allocator, "{s}/Default", .{dest_dir});
    defer allocator.free(dest_profile);

    std.fs.cwd().makePath(dest_profile) catch |err| {
        std.debug.print("Failed to create profile dir: {}\n", .{err});
        return error.CloneFailed;
    };

    // Files to copy (essential for preserving user data)
    const files_to_copy = [_][]const u8{
        "Preferences",
        "Bookmarks",
        "Cookies",
        "History",
        "Login Data",
        "Web Data",
        "Favicons",
        "Top Sites",
        "Shortcuts",
    };

    var source_dir = std.fs.cwd().openDir(source_profile, .{}) catch |err| {
        std.debug.print("Failed to open source profile '{s}': {}\n", .{ profile_name, err });
        return error.ProfileNotFound;
    };
    defer source_dir.close();

    var dest_dir_handle = std.fs.cwd().openDir(dest_profile, .{}) catch return error.CloneFailed;
    defer dest_dir_handle.close();

    var copied: u32 = 0;
    for (files_to_copy) |filename| {
        source_dir.copyFile(filename, dest_dir_handle, filename, .{}) catch continue;
        copied += 1;
    }

    // Copy Extensions directory if it exists
    copyDirRecursive(allocator, source_dir, dest_dir_handle, "Extensions") catch {};

    std.debug.print("Cloned profile '{s}' ({} files copied)\n", .{ profile_name, copied });
}

/// Recursively copy a directory
fn copyDirRecursive(allocator: std.mem.Allocator, source_parent: std.fs.Dir, dest_parent: std.fs.Dir, dir_name: []const u8) !void {
    var source = source_parent.openDir(dir_name, .{ .iterate = true }) catch return error.OpenFailed;
    defer source.close();

    dest_parent.makeDir(dir_name) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var dest = dest_parent.openDir(dir_name, .{}) catch return error.OpenFailed;
    defer dest.close();

    var iter = source.iterate();
    while (try iter.next()) |entry| {
        switch (entry.kind) {
            .file => {
                source.copyFile(entry.name, dest, entry.name, .{}) catch continue;
            },
            .directory => {
                copyDirRecursive(allocator, source, dest, entry.name) catch continue;
            },
            else => {},
        }
    }
}

/// Launch Chrome with Pipe-based CDP (preferred for better throughput)
/// Uses --remote-debugging-pipe which communicates via FD 3/4
/// Note: Uses manual fork/dup2/exec since Zig 0.15 Child doesn't support extra_fds
pub fn launchChromePipe(
    allocator: std.mem.Allocator,
    options: LaunchOptions,
) !ChromePipeInstance {
    // 1. Detect browser binary
    var chrome_bin: detector.ChromeBinary = undefined;
    var owns_path = true;

    if (options.browser_path) |path| {
        chrome_bin = detector.ChromeBinary{
            .path = path,
            .allocator = allocator,
        };
        owns_path = false;
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

    // 2b. Clone profile if requested
    if (options.clone_profile) |profile_name| {
        cloneProfile(allocator, profile_name, user_data_dir) catch |err| {
            std.debug.print("Warning: Could not clone profile '{s}': {}\n", .{ profile_name, err });
            std.debug.print("Starting with fresh profile instead.\n", .{});
        };
    }

    // 3. Create pipes for Chrome communication
    // We need two pipes:
    // - pipe_to_chrome: Parent writes -> Chrome reads (Chrome's FD 3)
    // - pipe_from_chrome: Chrome writes -> Parent reads (Chrome's FD 4)
    const pipe_to_chrome = try std.posix.pipe(); // [0]=read, [1]=write
    const pipe_from_chrome = try std.posix.pipe(); // [0]=read, [1]=write

    // Stderr pipe to capture "DevTools listening on ws://..." for port discovery
    const stderr_pipe = try std.posix.pipe(); // [0]=read (parent), [1]=write (child)

    // 4. Build Chrome arguments
    var args_list = try std.ArrayList([]const u8).initCapacity(allocator, 16);
    defer args_list.deinit(allocator);

    try args_list.append(allocator, chrome_bin.path);

    if (options.headless) {
        try args_list.append(allocator, "--headless=new");
    }

    try args_list.append(allocator, "--remote-debugging-pipe");
    try args_list.append(allocator, "--remote-debugging-port=0"); // Let OS pick random available port
    try args_list.append(allocator, "--remote-allow-origins=*");

    const user_data_arg = try std.fmt.allocPrint(allocator, "--user-data-dir={s}", .{user_data_dir});
    defer allocator.free(user_data_arg);
    try args_list.append(allocator, user_data_arg);

    try args_list.append(allocator, "--no-first-run");
    try args_list.append(allocator, "--no-default-browser-check");
    try args_list.append(allocator, "--allow-file-access-from-files");
    try args_list.append(allocator, "--enable-features=FileSystemAccessAPI,FileSystemAccessLocal");
    try args_list.append(allocator, "--disable-features=FileSystemAccessPermissionPrompts,DownloadBubble,DownloadBubbleV2,TabHoverCardImages,TabSearch,SidePanel");
    try args_list.append(allocator, "--disable-infobars"); // Disable download shelf/bar
    try args_list.append(allocator, "--hide-scrollbars"); // Hide scrollbars in viewport
    try args_list.append(allocator, "--disable-translate"); // Disable translate bar
    try args_list.append(allocator, "--disable-extensions"); // Disable extensions that might add UI
    try args_list.append(allocator, "--disable-component-extensions-with-background-pages"); // Disable background extensions
    try args_list.append(allocator, "--disable-background-networking"); // Prevent background updates
    try args_list.append(allocator, "--enable-features=DownloadShelfInToolbar:hidden/true"); // Hide download shelf

    if (options.disable_gpu) {
        try args_list.append(allocator, "--disable-gpu");
    }

    const window_size = try std.fmt.allocPrint(allocator, "--window-size={d},{d}", .{ options.viewport_width, options.viewport_height });
    defer allocator.free(window_size);
    try args_list.append(allocator, window_size);

    try args_list.append(allocator, "about:blank");

    // Convert to null-terminated pointers
    const argv = try allocator.alloc(?[*:0]const u8, args_list.items.len + 1);
    defer allocator.free(argv);

    for (args_list.items, 0..) |arg, i| {
        argv[i] = try allocator.dupeZ(u8, arg);
    }
    // Defer freeing the individual strings in the parent
    defer {
        for (argv[0..args_list.items.len]) |arg| {
            if (arg) |a| allocator.free(std.mem.span(a));
        }
    }
    argv[args_list.items.len] = null;

    const path_z = try allocator.dupeZ(u8, chrome_bin.path);
    defer allocator.free(path_z);

    // 5. Fork and exec
    const pid = try std.posix.fork();

    if (pid == 0) {
        // === CHILD PROCESS ===

        // Close parent ends of pipes
        std.posix.close(pipe_to_chrome[1]); // Parent's write end
        std.posix.close(pipe_from_chrome[0]); // Parent's read end
        std.posix.close(stderr_pipe[0]); // Parent's read end of stderr

        // Set up FD 3 (Chrome reads commands from us)
        if (pipe_to_chrome[0] != 3) {
            std.posix.dup2(pipe_to_chrome[0], 3) catch std.posix.exit(1);
            std.posix.close(pipe_to_chrome[0]);
        }

        // Set up FD 4 (Chrome writes responses to us)
        if (pipe_from_chrome[1] != 4) {
            std.posix.dup2(pipe_from_chrome[1], 4) catch std.posix.exit(1);
            std.posix.close(pipe_from_chrome[1]);
        }

        // CRITICAL: Clear O_CLOEXEC on FD 3 and 4 so they survive exec
        const fd3_flags = std.posix.fcntl(3, 1, 0) catch 0;
        _ = std.posix.fcntl(3, 2, fd3_flags & ~@as(usize, 1)) catch {};
        const fd4_flags = std.posix.fcntl(4, 1, 0) catch 0;
        _ = std.posix.fcntl(4, 2, fd4_flags & ~@as(usize, 1)) catch {};

        // Redirect stdout to /dev/null
        const dev_null = std.posix.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0) catch std.posix.exit(1);
        std.posix.dup2(dev_null, 1) catch std.posix.exit(1);
        std.posix.close(dev_null);

        // Redirect stderr to pipe (so parent can read "DevTools listening on...")
        std.posix.dup2(stderr_pipe[1], 2) catch std.posix.exit(1);
        std.posix.close(stderr_pipe[1]);

        // Preparation for exec - the strings are on the heap
        const path = path_z;
        const envp = std.c.environ;

        std.posix.execveZ(path, @ptrCast(argv.ptr), envp) catch {
            std.posix.exit(1);
        };
        std.posix.exit(1);
    }

    // === PARENT PROCESS ===

    // Close child ends of pipes
    std.posix.close(pipe_to_chrome[0]); // Chrome's read end
    std.posix.close(pipe_from_chrome[1]); // Chrome's write end
    std.posix.close(stderr_pipe[1]); // Child's write end of stderr

    // Read Chrome's stderr to find "DevTools listening on ws://127.0.0.1:PORT/..."
    const debug_port = extractDebugPort(stderr_pipe[0]) catch |err| {
        std.debug.print("Failed to extract debug port from Chrome: {}\n", .{err});
        // Kill Chrome if we can't get the port
        std.posix.kill(pid, std.posix.SIG.TERM) catch {};
        return LaunchError.TimeoutWaitingForDebugUrl;
    };

    // Close stderr pipe read end (we're done with it)
    std.posix.close(stderr_pipe[0]);

    std.debug.print("Chrome debugging on port {}\n", .{debug_port});

    // Parent uses:
    // - pipe_to_chrome[1] to WRITE to Chrome (Chrome's FD 3)
    // - pipe_from_chrome[0] to READ from Chrome (Chrome's FD 4)
    return ChromePipeInstance{
        .pid = pid,
        .write_fd = pipe_to_chrome[1],
        .read_fd = pipe_from_chrome[0],
        .user_data_dir = try allocator.dupe(u8, user_data_dir),
        .debug_port = debug_port,
        .allocator = allocator,
    };
}


/// Extract debug port from Chrome stderr output (raw FD version)
/// Reads until it finds "DevTools listening on ws://127.0.0.1:PORT/..." line
fn extractDebugPort(stderr_fd: std.posix.fd_t) !u16 {
    var output_buf: [8192]u8 = undefined;
    var total_read: usize = 0;

    // Wait up to 10 seconds for Chrome to print debug URL (profiles can be slow)
    const timeout_ns = 10 * std.time.ns_per_s;
    const start_time = std.time.nanoTimestamp();

    while (std.time.nanoTimestamp() - start_time < timeout_ns) {
        const bytes_read = std.posix.read(stderr_fd, output_buf[total_read..]) catch {
            std.Thread.sleep(100 * std.time.ns_per_ms);
            continue;
        };

        if (bytes_read == 0) {
            std.Thread.sleep(100 * std.time.ns_per_ms);
            continue;
        }

        total_read += bytes_read;

        // Look for "DevTools listening on ws://127.0.0.1:PORT/" in accumulated output
        const output_so_far = output_buf[0..total_read];
        if (std.mem.indexOf(u8, output_so_far, "DevTools listening on ws://")) |idx| {
            // Find the port number after "ws://127.0.0.1:" or "ws://localhost:"
            const ws_start = idx + "DevTools listening on ws://".len;
            // Skip host (127.0.0.1 or localhost)
            const colon_pos = std.mem.indexOfPos(u8, output_so_far, ws_start, ":") orelse continue;
            const port_start = colon_pos + 1;
            // Find end of port (/ or newline)
            var port_end = port_start;
            while (port_end < output_so_far.len and output_so_far[port_end] >= '0' and output_so_far[port_end] <= '9') {
                port_end += 1;
            }
            if (port_end > port_start) {
                return std.fmt.parseInt(u16, output_so_far[port_start..port_end], 10) catch continue;
            }
        }
    }

    return LaunchError.TimeoutWaitingForDebugUrl;
}

/// Launch Chrome with WebSocket-based CDP (legacy, for --connect compatibility)
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

    return LaunchError.TimeoutWaitingForDebugUrl;
}
