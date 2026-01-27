const std = @import("std");
const builtin = @import("builtin");
const detector = @import("detector.zig");
const extension = @import("extension.zig");

/// Prefix for temporary Chrome profile directories
pub const TEMP_PROFILE_PREFIX = "termweb-";

/// Clean up old termweb-* directories from /tmp
/// Removes directories older than max_age_seconds (default: 1 hour)
/// Uses filesystem metadata (mtime) to determine age, not directory name
pub fn cleanupOldProfiles(max_age_seconds: i64) void {
    const tmp_dir = if (builtin.os.tag == .macos)
        std.posix.getenv("TMPDIR") orelse "/tmp"
    else
        "/tmp";

    var dir = std.fs.cwd().openDir(tmp_dir, .{ .iterate = true }) catch return;
    defer dir.close();

    const now_ns = std.time.nanoTimestamp();
    var iter = dir.iterate();

    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (!std.mem.startsWith(u8, entry.name, TEMP_PROFILE_PREFIX)) continue;

        // Get directory metadata to check age
        const stat = dir.statFile(entry.name) catch continue;
        const mtime_ns = stat.mtime;
        const age_ns = now_ns - mtime_ns;
        const age_seconds = @divFloor(age_ns, std.time.ns_per_s);

        // Delete if older than max_age
        if (age_seconds > max_age_seconds) {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ tmp_dir, entry.name }) catch continue;
            std.fs.cwd().deleteTree(full_path) catch {};
        }
    }
}

/// Generate a random hex string for unique directory names
fn randomHex(buf: []u8) void {
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    var rng = std.Random.DefaultPrng.init(seed);
    for (buf) |*c| {
        const val = rng.random().int(u4);
        c.* = "0123456789abcdef"[val];
    }
}

pub const LaunchError = error{
    ChromeNotFound,
    LaunchFailed,
    TimeoutWaitingForDebugUrl,
    InvalidDebugUrl,
    OutOfMemory,
    PipeSetupFailed,
};

/// Pipe-based Chrome instance (preferred for new launches)
/// Uses --remote-debugging-pipe for higher throughput
pub const ChromePipeInstance = struct {
    pid: std.posix.pid_t, // Chrome process ID
    read_fd: std.posix.fd_t, // FD to read from Chrome (Chrome's FD 4)
    write_fd: std.posix.fd_t, // FD to write to Chrome (Chrome's FD 3)
    user_data_dir: []const u8, // Path to temporary user data directory
    extension_dir: ?[]const u8, // Path to temporary extension directory (if using built-in)
    debug_port: u16, // Not used in pipe mode (set to 0)
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

        // Clean up extension directory if we created one
        if (self.extension_dir) |ext_dir| {
            std.fs.cwd().deleteTree(ext_dir) catch {};
            self.allocator.free(ext_dir);
        }
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
    clone_profile: ?[]const u8 = null, // Default: fresh profile (no cloning)
    /// Path to unpacked extension directory to load
    /// SDK users can provide custom extensions for additional functionality
    extension_path: ?[]const u8 = null,
    /// Print debug messages (default: true for CLI, false for SDK)
    verbose: bool = true,
};

/// Get Chrome user data directory path for the current platform
pub fn getChromeUserDataDir(allocator: std.mem.Allocator) ![]const u8 {
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

/// Clone a Chrome profile to a temporary directory (minimal for fast startup)
/// Copies only essential session data: Cookies, Local Storage, IndexedDB
/// Skips: Extensions, History, Bookmarks, etc. (not needed for session auth)
/// Uses COW (copy-on-write) cloning on macOS APFS for instant copies
fn cloneProfile(allocator: std.mem.Allocator, profile_name: []const u8, dest_dir: []const u8, verbose: bool) !void {
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

    // Try fast COW clone first (instant on APFS/Btrfs)
    if (tryFastClone(allocator, source_profile, dest_profile, verbose)) {
        return;
    }

    // Fallback: manual file-by-file copy
    if (verbose) {
        std.debug.print("Fast clone unavailable, using file copy...\n", .{});
    }

    // Minimal files to copy (only what's needed for login sessions)
    const files_to_copy = [_][]const u8{
        "Cookies", // Session cookies for auth
        "Login Data", // Saved passwords
        "Preferences", // Basic settings (minimal, fast to copy)
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

    // Copy directories for web app data (Local Storage, IndexedDB)
    const dirs_to_copy = [_][]const u8{
        "Local Storage", // localStorage API data
        "IndexedDB", // IndexedDB data
        "File System", // OPFS data
    };

    for (dirs_to_copy) |dir_name| {
        copyDirRecursive(allocator, source_dir, dest_dir_handle, dir_name) catch continue;
    }

    if (verbose) {
        std.debug.print("Cloned profile '{s}' ({} files copied)\n", .{ profile_name, copied });
    }
}

/// Try fast COW (copy-on-write) clone using system commands
/// Returns true if successful, false to fall back to manual copy
fn tryFastClone(allocator: std.mem.Allocator, source: []const u8, dest: []const u8, verbose: bool) bool {
    // Items to clone (files and directories)
    const items_to_clone = [_][]const u8{
        "Cookies",
        "Login Data",
        "Preferences",
        "Local Storage",
        "IndexedDB",
        "File System",
    };

    var cloned: u32 = 0;

    for (items_to_clone) |item| {
        var src_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        var dst_path_buf: [std.fs.max_path_bytes]u8 = undefined;

        const src_path = std.fmt.bufPrint(&src_path_buf, "{s}/{s}", .{ source, item }) catch continue;
        const dst_path = std.fmt.bufPrint(&dst_path_buf, "{s}/{s}", .{ dest, item }) catch continue;

        // Check if source exists
        std.fs.cwd().access(src_path, .{}) catch continue;

        // Use cp -c (clone) on macOS, cp --reflink=auto on Linux
        const argv = if (builtin.os.tag == .macos)
            [_][]const u8{ "cp", "-cR", src_path, dst_path }
        else
            [_][]const u8{ "cp", "-r", "--reflink=auto", src_path, dst_path };

        var child = std.process.Child.init(&argv, allocator);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        child.spawn() catch continue;
        const result = child.wait() catch continue;

        if (result.Exited == 0) {
            cloned += 1;
        }
    }

    if (cloned > 0 and verbose) {
        std.debug.print("Fast-cloned profile ({} items via COW)\n", .{cloned});
    }

    return cloned > 0;
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

    // 2. Clean up old crashed profiles (older than 1 hour)
    cleanupOldProfiles(3600);

    // 3. Create temporary user data directory if not provided
    var temp_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const user_data_dir = if (options.user_data_dir) |dir|
        dir
    else blk: {
        const tmp_base = if (builtin.os.tag == .macos)
            std.posix.getenv("TMPDIR") orelse "/tmp"
        else
            "/tmp";

        // Use random hex suffix for security (unpredictable directory name)
        var random_suffix: [16]u8 = undefined;
        randomHex(&random_suffix);

        const temp_dir = std.fmt.bufPrint(&temp_dir_buf, "{s}/{s}{s}", .{
            tmp_base,
            TEMP_PROFILE_PREFIX,
            random_suffix,
        }) catch return LaunchError.OutOfMemory;

        // Create with restricted permissions (owner only)
        std.fs.cwd().makePath(temp_dir) catch return LaunchError.LaunchFailed;
        break :blk temp_dir;
    };

    // 3b. Clone profile if requested
    if (options.clone_profile) |profile_name| {
        cloneProfile(allocator, profile_name, user_data_dir, options.verbose) catch |err| {
            if (options.verbose) {
                std.debug.print("Warning: Could not clone profile '{s}': {}\n", .{ profile_name, err });
                std.debug.print("Starting with fresh profile instead.\n", .{});
            }
        };
    }

    // 3. Create pipes for Chrome communication
    // We need two pipes:
    // - pipe_to_chrome: Parent writes -> Chrome reads (Chrome's FD 3)
    // - pipe_from_chrome: Chrome writes -> Parent reads (Chrome's FD 4)
    const pipe_to_chrome = try std.posix.pipe(); // [0]=read, [1]=write
    const pipe_from_chrome = try std.posix.pipe(); // [0]=read, [1]=write


    // 4. Build Chrome arguments
    var args_list = try std.ArrayList([]const u8).initCapacity(allocator, 16);
    defer args_list.deinit(allocator);

    try args_list.append(allocator, chrome_bin.path);

    if (options.headless) {
        // On Linux via SSH, skip headless mode and use the desktop's display instead
        // Chrome headless on Linux doesn't support screencast
        const is_ssh = std.posix.getenv("SSH_CONNECTION") != null or std.posix.getenv("SSH_CLIENT") != null;
        const has_display = std.posix.getenv("DISPLAY") != null;

        if (builtin.os.tag == .linux and is_ssh and has_display) {
            // SSH with display available - don't use headless, Chrome will use DISPLAY
            // This allows screencast to work over SSH when desktop is running
        } else if (builtin.os.tag == .linux and is_ssh) {
            // SSH without display - set DISPLAY=:0 to use desktop's display
            const setenv = @extern(*const fn ([*:0]const u8, [*:0]const u8, c_int) callconv(.c) c_int, .{ .name = "setenv" });
            _ = setenv("DISPLAY", ":0", 1);
        } else {
            try args_list.append(allocator, "--headless=new");
        }
    }

    // Use pipe mode for CDP
    try args_list.append(allocator, "--remote-debugging-pipe");

    const user_data_arg = try std.fmt.allocPrint(allocator, "--user-data-dir={s}", .{user_data_dir});
    defer allocator.free(user_data_arg);
    try args_list.append(allocator, user_data_arg);

    try args_list.append(allocator, "--no-first-run");
    try args_list.append(allocator, "--no-default-browser-check");
    try args_list.append(allocator, "--allow-file-access-from-files");
    try args_list.append(allocator, "--enable-features=FileSystemAccessAPI,FileSystemAccessLocal");
    try args_list.append(allocator, "--disable-features=FileSystemAccessPermissionPrompts,DownloadBubble,DownloadBubbleV2");
    try args_list.append(allocator, "--disable-infobars");
    try args_list.append(allocator, "--hide-scrollbars");
    try args_list.append(allocator, "--disable-translate");
    try args_list.append(allocator, "--disable-sync");
    try args_list.append(allocator, "--disable-background-timer-throttling");
    try args_list.append(allocator, "--disable-client-side-phishing-detection");
    try args_list.append(allocator, "--disable-component-update");
    try args_list.append(allocator, "--disable-extensions");

    if (options.disable_gpu) {
        try args_list.append(allocator, "--disable-gpu");
        // Headless-friendly flags for server/SSH environments (only with --disable-gpu)
        try args_list.append(allocator, "--no-sandbox");
        try args_list.append(allocator, "--disable-software-rasterizer");
    }

    // Linux headless: minimal flags (avoid --disable-gpu which blocks screencast)
    if (builtin.os.tag == .linux and options.headless) {
        try args_list.append(allocator, "--disable-dev-shm-usage");
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

        // Set up FD 3 and 4 for Chrome's --remote-debugging-pipe
        if (pipe_to_chrome[0] != 3) {
            std.posix.dup2(pipe_to_chrome[0], 3) catch std.posix.exit(1);
            std.posix.close(pipe_to_chrome[0]);
        }
        if (pipe_from_chrome[1] != 4) {
            std.posix.dup2(pipe_from_chrome[1], 4) catch std.posix.exit(1);
            std.posix.close(pipe_from_chrome[1]);
        }

        // Redirect stdout and stderr to /dev/null
        const dev_null = std.posix.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0) catch std.posix.exit(1);
        std.posix.dup2(dev_null, 1) catch std.posix.exit(1);
        std.posix.dup2(dev_null, 2) catch std.posix.exit(1);
        std.posix.close(dev_null);

        // Preparation for exec - the strings are on the heap
        const path = path_z;

        // Unset DISPLAY to prevent X11 connection attempts in headless mode
        // But keep DISPLAY on Linux via SSH so Chrome can use the desktop's display
        const is_ssh_child = std.posix.getenv("SSH_CONNECTION") != null or std.posix.getenv("SSH_CLIENT") != null;
        if (!(builtin.os.tag == .linux and is_ssh_child)) {
            const unsetenv = @extern(*const fn ([*:0]const u8) callconv(.c) c_int, .{ .name = "unsetenv" });
            _ = unsetenv("DISPLAY");
        }

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

    // Keep pipe FDs for CDP communication
    const write_fd = pipe_to_chrome[1];
    const read_fd = pipe_from_chrome[0];

    // Give Chrome a moment to start
    std.Thread.sleep(100 * std.time.ns_per_ms);

    return ChromePipeInstance{
        .pid = pid,
        .write_fd = write_fd,
        .read_fd = read_fd,
        .user_data_dir = try allocator.dupe(u8, user_data_dir),
        .extension_dir = null,
        .debug_port = 0,
        .allocator = allocator,
    };
}


