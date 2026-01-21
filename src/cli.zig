const std = @import("std");

const detector = @import("chrome/detector.zig");
const launcher = @import("chrome/launcher.zig");
const cdp = @import("chrome/cdp_client.zig");
const screenshot_api = @import("chrome/screenshot.zig");
const terminal_mod = @import("terminal/terminal.zig");
const viewer_mod = @import("viewer.zig");
const toolbar_mod = @import("ui/toolbar.zig");

const VERSION = "0.7.0";

const Command = enum {
    open,
    doctor,
    help,
    version,
    unknown,
};

pub fn run(allocator: std.mem.Allocator) !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printHelp();
        return;
    }

    const command = parseCommand(args[1]);

    switch (command) {
        .open => try cmdOpen(allocator, args[2..]),
        .doctor => try cmdDoctor(allocator),
        .version => try cmdVersion(),
        .help => printHelp(),
        .unknown => {
            std.debug.print("Unknown command: {s}\n\n", .{args[1]});
            printHelp();
            std.process.exit(1);
        },
    }
}

fn parseCommand(arg: []const u8) Command {
    if (std.mem.eql(u8, arg, "open")) return .open;
    if (std.mem.eql(u8, arg, "doctor")) return .doctor;
    if (std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return .help;
    if (std.mem.eql(u8, arg, "version") or std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) return .version;
    return .unknown;
}

fn cmdOpen(allocator: std.mem.Allocator, args: []const []const u8) !void {
    // Handle list commands first (they don't need a URL)
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--list-profiles")) {
            const profiles = launcher.listProfiles(allocator) catch |err| {
                std.debug.print("Error listing profiles: {}\n", .{err});
                std.process.exit(1);
            };
            defer {
                for (profiles) |p| allocator.free(p);
                allocator.free(profiles);
            }

            std.debug.print("Available Chrome profiles:\n", .{});
            for (profiles) |profile| {
                std.debug.print("  {s}\n", .{profile});
            }
            if (profiles.len == 0) {
                std.debug.print("  (no profiles found)\n", .{});
            }
            std.debug.print("\nUse --profile <name> to clone a profile.\n", .{});
            return;
        } else if (std.mem.eql(u8, arg, "--list-browsers")) {
            const browsers = detector.listAvailableBrowsers(allocator) catch {
                std.debug.print("Error listing browsers\n", .{});
                std.process.exit(1);
            };
            defer allocator.free(browsers);

            std.debug.print("Available browsers:\n", .{});
            for (browsers) |path| {
                std.debug.print("  {s} ({s})\n", .{ detector.getBrowserName(path), path });
            }
            if (browsers.len == 0) {
                std.debug.print("  (none found)\n", .{});
            }
            std.debug.print("\nUse --browser <name> to select one, or set $CHROME_BIN\n", .{});
            return;
        }
    }

    if (args.len < 1) {
        std.debug.print("Error: URL required\n", .{});
        std.debug.print("Usage: termweb open <url> [--mobile] [--scale N]\n", .{});
        std.process.exit(1);
    }

    // Check terminal support first
    if (!try checkTerminalSupport(allocator)) {
        std.process.exit(1);
    }

    var url = args[0];
    var normalized_url: ?[]const u8 = null;
    defer if (normalized_url) |u| allocator.free(u);

    // Normalize URL
    if (std.mem.startsWith(u8, url, "/")) {
        // Absolute path
        normalized_url = try std.fmt.allocPrint(allocator, "file://{s}", .{url});
        url = normalized_url.?;
    } else if (std.mem.startsWith(u8, url, "./") or std.mem.startsWith(u8, url, "../") or std.mem.eql(u8, url, ".")) {
        // Relative path
        const abs_path = try std.fs.cwd().realpathAlloc(allocator, url);
        defer allocator.free(abs_path);
        normalized_url = try std.fmt.allocPrint(allocator, "file://{s}", .{abs_path});
        url = normalized_url.?;
    } else if (!std.mem.containsAtLeast(u8, url, 1, "://")) {
        // Check if it's a local file that exists even without prefix
        if (std.fs.cwd().access(url, .{})) |_| {
            const abs_path = try std.fs.cwd().realpathAlloc(allocator, url);
            defer allocator.free(abs_path);
            normalized_url = try std.fmt.allocPrint(allocator, "file://{s}", .{abs_path});
            url = normalized_url.?;
        } else |_| {
            // Assume it's a web URL missing protocol
            normalized_url = try std.fmt.allocPrint(allocator, "https://{s}", .{url});
            url = normalized_url.?;
        }
    }
    var mobile = false;
    var scale: f32 = 1.0;
    var clone_profile: ?[]const u8 = null; // null means use default from LaunchOptions
    var no_profile = false;
    var browser_path: ?[]const u8 = null;

    // Parse flags
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--mobile")) {
            mobile = true;
        } else if (std.mem.eql(u8, arg, "--scale")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: --scale requires a value\n", .{});
                std.process.exit(1);
            }
            i += 1;
            scale = try std.fmt.parseFloat(f32, args[i]);
        } else if (std.mem.eql(u8, arg, "--profile")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: --profile requires a profile name (e.g., 'Default', 'Profile 1')\n", .{});
                std.debug.print("Use --list-profiles to see available profiles.\n", .{});
                std.process.exit(1);
            }
            i += 1;
            clone_profile = args[i];
        } else if (std.mem.eql(u8, arg, "--browser-path")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: --browser-path requires a path to browser executable\n", .{});
                std.process.exit(1);
            }
            i += 1;
            browser_path = args[i];
        } else if (std.mem.eql(u8, arg, "--no-profile")) {
            no_profile = true;
        }
        // --list-profiles and --list-browsers are handled at the start of cmdOpen
    }

    // TODO: Implement mobile viewport and scaling
    if (mobile) std.debug.print("Note: --mobile not yet implemented\n", .{});
    if (scale != 1.0) std.debug.print("Note: --scale not yet implemented\n", .{});

    // Get terminal size for viewport
    var term = terminal_mod.Terminal.init();
    const size = term.getSize() catch blk: {
        std.debug.print("Warning: Could not detect terminal size, using defaults\n", .{});
        break :blk terminal_mod.TerminalSize{
            .cols = 80,
            .rows = 24,
            .width_px = 1280,
            .height_px = 720,
        };
    };

    // Calculate viewport size
    const raw_width: u32 = if (size.width_px > 0) size.width_px else @as(u32, size.cols) * 10;

    // Detect High-DPI (Retina) displays
    var dpr: u32 = 1;
    const cell_width: u32 = if (size.width_px > 0 and size.cols > 0)
        size.width_px / size.cols
    else
        14;
    if (cell_width > 14) {
        dpr = 2;
        std.debug.print("Detected High-DPI display ({} px/col), scaling viewport by 0.5\n", .{cell_width});
    }

    // Get actual toolbar height (accounts for DPR)
    const toolbar_height = toolbar_mod.getToolbarHeight(cell_width);

    // Reserve space for toolbar at top
    const available_height: u32 = if (size.height_px > toolbar_height)
        size.height_px - toolbar_height
    else
        size.height_px;

    const viewport_width: u32 = raw_width / dpr;
    const viewport_height: u32 = available_height / dpr;

    std.debug.print("Terminal: {}x{} px ({} cols x {} rows)\n", .{
        size.width_px,
        size.height_px,
        size.cols,
        size.rows,
    });
    std.debug.print("Viewport: {}x{} (DPR={})\n", .{ viewport_width, viewport_height, dpr });

    // Launch Chrome with Pipe transport
    std.debug.print("Launching Chrome (Pipe mode)...\n", .{});

    // Determine profile cloning behavior:
    // - Default: clone "Default" profile (from LaunchOptions default)
    // - --profile X: clone profile X
    // - --no-profile: don't clone any profile (fresh)
    var launch_opts = launcher.LaunchOptions{
        .viewport_width = viewport_width,
        .viewport_height = viewport_height,
        .browser_path = browser_path,
    };

    // Only override clone_profile if explicitly set
    if (no_profile) {
        launch_opts.clone_profile = null;
    } else if (clone_profile) |p| {
        launch_opts.clone_profile = p;
    }

    var chrome_instance = launcher.launchChromePipe(allocator, launch_opts) catch |err| {
        switch (err) {
            error.ChromeNotFound => {
                std.debug.print("\nError: Chrome/Chromium browser not found.\n\n", .{});
                std.debug.print("Options:\n", .{});
                std.debug.print("  1. Install Chrome: https://www.google.com/chrome/\n", .{});
                std.debug.print("  2. Set CHROME_BIN environment variable:\n", .{});
                std.debug.print("     export CHROME_BIN=/path/to/chrome\n", .{});
                std.debug.print("  3. Use --browser-path flag:\n", .{});
                std.debug.print("     termweb open <url> --browser-path /path/to/chrome\n\n", .{});
                std.debug.print("Run 'termweb open --list-browsers' to see detected browsers.\n", .{});
            },
            else => {
                std.debug.print("Error launching Chrome: {}\n", .{err});
            },
        }
        std.process.exit(1);
    };
    defer chrome_instance.deinit();

    std.debug.print("Chrome launched\n", .{});

    // Connect CDP client via Pipe
    var client = cdp.CdpClient.initFromPipe(allocator, chrome_instance.read_fd, chrome_instance.write_fd, chrome_instance.debug_port) catch |err| {
        std.debug.print("Error connecting to Chrome DevTools Protocol: {}\n", .{err});
        std.process.exit(1);
    };
    defer client.deinit();

    std.debug.print("Connected to Chrome via Pipe\n", .{});

    // Set viewport size explicitly (ensures Chrome uses exact dimensions for coordinate mapping)
    screenshot_api.setViewport(client, allocator, viewport_width, viewport_height) catch |err| {
        std.debug.print("Error setting viewport: {}\n", .{err});
        std.process.exit(1);
    };
    std.debug.print("Viewport set to: {}x{}\n", .{ viewport_width, viewport_height });

    std.debug.print("Navigating to: {s}\n", .{url});

    // Navigate to URL
    screenshot_api.navigateToUrl(client, allocator, url) catch |err| {
        std.debug.print("Error navigating to URL: {}\n", .{err});
        std.process.exit(1);
    };

    std.debug.print("Page loaded\n", .{});

    // Run viewer
    var viewer = try viewer_mod.Viewer.init(allocator, client, url, viewport_width, viewport_height);
    defer viewer.deinit();

    try viewer.run();
}

/// Check if terminal supports Kitty graphics protocol
fn checkTerminalSupport(allocator: std.mem.Allocator) !bool {
    const term_program = std.process.getEnvVarOwned(allocator, "TERM_PROGRAM") catch null;
    defer if (term_program) |t| allocator.free(t);

    if (term_program) |tp| {
        if (std.mem.eql(u8, tp, "ghostty") or
            std.mem.eql(u8, tp, "kitty") or
            std.mem.eql(u8, tp, "WezTerm"))
        {
            return true;
        }
    }

    std.debug.print("Error: Unsupported terminal\n", .{});
    std.debug.print("termweb requires a terminal that supports the Kitty graphics protocol.\n\n", .{});
    std.debug.print("Detected terminal: {s}\n\n", .{term_program orelse "unknown"});
    std.debug.print("Supported terminals:\n", .{});
    std.debug.print("  • Ghostty - https://ghostty.org/\n", .{});
    std.debug.print("  • Kitty   - https://sw.kovidgoyal.net/kitty/\n", .{});
    std.debug.print("  • WezTerm - https://wezterm.org/\n\n", .{});
    std.debug.print("Please install one of these terminals and try again.\n", .{});
    std.debug.print("Run 'termweb doctor' to check your system configuration.\n", .{});

    return false;
}

fn cmdDoctor(allocator: std.mem.Allocator) !void {
    std.debug.print("termweb doctor - System capability check\n", .{});
    std.debug.print("========================================\n\n", .{});

    const term_env = std.process.getEnvVarOwned(allocator, "TERM") catch null;
    defer if (term_env) |t| allocator.free(t);

    const term_program = std.process.getEnvVarOwned(allocator, "TERM_PROGRAM") catch null;
    defer if (term_program) |t| allocator.free(t);

    std.debug.print("Terminal:\n", .{});
    std.debug.print("  TERM: {s}\n", .{term_env orelse "not set"});
    std.debug.print("  TERM_PROGRAM: {s}\n", .{term_program orelse "not set"});

    std.debug.print("\nKitty Graphics Protocol:\n", .{});
    const supports_kitty = blk: {
        if (term_program) |tp| {
            if (std.mem.eql(u8, tp, "ghostty") or
                std.mem.eql(u8, tp, "kitty") or
                std.mem.eql(u8, tp, "WezTerm"))
            {
                break :blk true;
            }
        }
        break :blk false;
    };

    if (supports_kitty) {
        std.debug.print("  ✓ Supported (detected: {s})\n", .{term_program.?});
    } else {
        std.debug.print("  ✗ Not detected\n", .{});
        std.debug.print("  Supported terminals: Ghostty, Kitty, WezTerm\n", .{});
    }

    std.debug.print("\nTruecolor:\n", .{});
    const colorterm = std.process.getEnvVarOwned(allocator, "COLORTERM") catch null;
    defer if (colorterm) |c| allocator.free(c);

    const supports_truecolor = blk: {
        if (colorterm) |ct| {
            if (std.mem.eql(u8, ct, "truecolor") or std.mem.eql(u8, ct, "24bit")) {
                break :blk true;
            }
        }
        break :blk false;
    };

    if (supports_truecolor) {
        std.debug.print("  ✓ Supported (COLORTERM={s})\n", .{colorterm.?});
    } else {
        std.debug.print("  ✗ Not detected\n", .{});
    }

    std.debug.print("\nChrome/Chromium:\n", .{});
    if (detector.detectChrome(allocator)) |chrome| {
        defer {
            var mut_chrome = chrome;
            mut_chrome.deinit();
        }
        std.debug.print("  ✓ Found: {s}\n", .{chrome.path});
    } else |_| {
        std.debug.print("  ✗ Not found\n", .{});
        std.debug.print("  Install Chrome or set $CHROME_BIN environment variable\n", .{});
    }

    std.debug.print("\nOverall:\n", .{});
    if (supports_kitty and supports_truecolor) {
        std.debug.print("  ✓ Ready for termweb\n", .{});
    } else {
        std.debug.print("  ✗ Some capabilities missing\n", .{});
        if (!supports_kitty) {
            std.debug.print("  - Use a terminal that supports Kitty graphics protocol\n", .{});
        }
    }
}

fn cmdVersion() !void {
    std.debug.print("termweb version {s}\n", .{VERSION});
}

fn printHelp() void {
    std.debug.print(
        \\termweb - Web browser in your terminal using Kitty graphics
        \\
        \\Usage:
        \\  termweb <command> [options]
        \\
        \\Commands:
        \\  open <url>     Open a URL in the terminal browser
        \\                 Options:
        \\                   --profile <name>      Clone Chrome profile (default: 'Default')
        \\                   --no-profile          Start with fresh profile (no cloning)
        \\                   --browser-path <path> Path to browser executable
        \\                   --list-profiles       Show available Chrome profiles
        \\                   --list-browsers       Show available browsers
        \\                   --mobile              Use mobile viewport
        \\                   --scale N             Set zoom scale (default: 1.0)
        \\  doctor         Check system capabilities
        \\  version        Show version information
        \\  help           Show this help message
        \\
        \\Examples:
        \\  termweb open https://example.com
        \\  termweb open https://github.com --profile Default
        \\  termweb open ./local.html --browser-path /opt/chrome/chrome
        \\
        \\Environment:
        \\  CHROME_BIN     Path to browser executable (overrides auto-detection)
        \\
        \\Supported terminals: Ghostty, Kitty, WezTerm
        \\
    , .{});
}
