const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const config = @import("config.zig").Config;

const detector = @import("chrome/detector.zig");
const launcher = @import("chrome/launcher.zig");
const cdp = @import("chrome/cdp_client.zig");
const screenshot_api = @import("chrome/screenshot.zig");
const terminal_mod = @import("terminal/terminal.zig");
const viewer_mod = @import("viewer.zig");
const toolbar_mod = @import("ui/toolbar.zig");
const helpers = @import("viewer/helpers.zig");

// Mux module (only available on macOS/Linux)
const mux = if (builtin.os.tag == .macos or builtin.os.tag == .linux)
    @import("mux")
else
    @compileError("mux not available on this platform");

/// Version from package.json (single source of truth)
const VERSION = build_options.version;

const Command = enum {
    open,
    mux,
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
        .mux => try cmdMux(allocator, args),
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
    if (std.mem.eql(u8, arg, "mux")) return .mux;
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
        std.debug.print("Usage: termweb open <url> [options]\n", .{});
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
    } else if (!std.mem.containsAtLeast(u8, url, 1, "://") and
        !std.mem.startsWith(u8, url, "data:") and
        !std.mem.startsWith(u8, url, "javascript:"))
    {
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
    var clone_profile: ?[]const u8 = null; // Default: no profile cloning
    var no_toolbar = false;
    var disable_hotkeys = false;
    var disable_hints = false;
    var browser_path: ?[]const u8 = null;
    var disable_gpu = false;
    var fps: u32 = config.DEFAULT_FPS;

    // Parse flags
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--profile")) {
            // --profile [name] - name is optional, defaults to "Default"
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                i += 1;
                clone_profile = args[i];
            } else {
                clone_profile = "Default";
            }
        } else if (std.mem.eql(u8, arg, "--browser-path")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: --browser-path requires a path to browser executable\n", .{});
                std.process.exit(1);
            }
            i += 1;
            browser_path = args[i];
        } else if (std.mem.eql(u8, arg, "--no-toolbar")) {
            no_toolbar = true;
        } else if (std.mem.eql(u8, arg, "--disable-hotkeys")) {
            disable_hotkeys = true;
        } else if (std.mem.eql(u8, arg, "--disable-hints")) {
            disable_hints = true;
        } else if (std.mem.eql(u8, arg, "--disable-gpu")) {
            disable_gpu = true;
        } else if (std.mem.eql(u8, arg, "--fps")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: --fps requires a value (e.g., 12, 24, 30)\n", .{});
                std.process.exit(1);
            }
            i += 1;
            fps = std.fmt.parseInt(u32, args[i], 10) catch {
                std.debug.print("Error: Invalid FPS value: {s}\n", .{args[i]});
                std.process.exit(1);
            };
            // Clamp FPS to reasonable range (max 30 for render, input is handled separately)
            if (fps < 1) fps = 1;
            if (fps > 30) fps = 30;
        }
        // --list-profiles and --list-browsers are handled at the start of cmdOpen
    }

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
    const cell_height: u32 = if (size.height_px > 0 and size.rows > 0)
        size.height_px / size.rows
    else
        20;
    if (cell_width > 14) {
        dpr = 2;
    }

    // Get actual toolbar height (accounts for DPR)
    const toolbar_height = toolbar_mod.getToolbarHeight(cell_width);

    // Calculate content area height aligned to cell boundaries
    // This MUST match the content_pixel_height calculation in CoordinateMapper
    const available_height: u32 = if (size.height_px > toolbar_height)
        size.height_px - toolbar_height
    else
        size.height_px;
    const content_rows: u32 = available_height / cell_height;
    const content_pixel_height: u32 = content_rows * cell_height;

    // Original viewport (before any limits) - used for coordinate ratio calculation
    // Use sensible defaults if terminal pixel detection fails (common over SSH)
    const MIN_WIDTH: u32 = 100;
    const MIN_HEIGHT: u32 = 100;
    const original_viewport_width: u32 = @max(raw_width / dpr, MIN_WIDTH);
    const original_viewport_height: u32 = @max(content_pixel_height / dpr, MIN_HEIGHT);

    var viewport_width: u32 = original_viewport_width;
    var viewport_height: u32 = original_viewport_height;

    // Cap total pixels to improve performance on large displays
    // 1.5M pixels ≈ 1920x780 or 1600x937 - good balance of quality and speed
    const MAX_PIXELS = config.MAX_PIXELS;
    const total_pixels: u64 = @as(u64, viewport_width) * @as(u64, viewport_height);
    if (total_pixels > MAX_PIXELS) {
        // Scale down maintaining aspect ratio
        const pixel_scale = @sqrt(@as(f64, @floatFromInt(MAX_PIXELS)) / @as(f64, @floatFromInt(total_pixels)));
        viewport_width = @intFromFloat(@as(f64, @floatFromInt(viewport_width)) * pixel_scale);
        viewport_height = @intFromFloat(@as(f64, @floatFromInt(viewport_height)) * pixel_scale);
        std.debug.print("Viewport reduced: {}x{} -> {}x{} (MAX_PIXELS={})\n", .{
            original_viewport_width, original_viewport_height, viewport_width, viewport_height, MAX_PIXELS,
        });
    }

    // Launch Chrome with Pipe transport
    std.debug.print("Launching browser...\n", .{});

    // Determine profile cloning behavior:
    // Default: fresh profile (no cloning) - avoids Google session logout issues
    // --profile X: clone profile X for logged-in sessions (with extensions enabled)
    const launch_opts = launcher.LaunchOptions{
        .viewport_width = viewport_width,
        .viewport_height = viewport_height,
        .browser_path = browser_path,
        .disable_gpu = disable_gpu,
        .clone_profile = clone_profile,
        .enable_extensions = clone_profile != null,
    };

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

    // Connect CDP client - prefer pipe (faster), fallback to WebSocket
    var client = if (chrome_instance.read_fd >= 0 and chrome_instance.write_fd >= 0)
        cdp.CdpClient.initFromPipe(allocator, chrome_instance.read_fd, chrome_instance.write_fd, chrome_instance.debug_port) catch |err| {
            std.debug.print("Error connecting to Chrome via pipe: {}\n", .{err});
            std.process.exit(1);
        }
    else
        cdp.CdpClient.initFromWebSocket(allocator, chrome_instance.debug_port) catch |err| {
            std.debug.print("Error connecting to Chrome: {}\n", .{err});
            std.process.exit(1);
        };
    defer client.deinit();

    // Set viewport size explicitly (ensures Chrome uses exact dimensions for coordinate mapping)
    // Pass DPR so Chrome's deviceScaleFactor matches our terminal's actual density
    screenshot_api.setViewport(client, allocator, viewport_width, viewport_height, dpr) catch |err| {
        std.debug.print("Error setting viewport: {}\n", .{err});
        std.process.exit(1);
    };

    std.debug.print("Loading: {s}\n", .{url});

    // Navigate to URL
    screenshot_api.navigateToUrl(client, allocator, url) catch |err| {
        std.debug.print("Error navigating to URL: {}\n", .{err});
        std.process.exit(1);
    };

    // Query Chrome's ACTUAL viewport dimensions for coordinate mapping
    // (setDeviceMetricsOverride may not take effect exactly as specified)
    var actual_viewport_width = viewport_width;
    var actual_viewport_height = viewport_height;
    if (screenshot_api.getActualViewport(client, allocator)) |actual_vp| {
        if (actual_vp.width > 0) actual_viewport_width = actual_vp.width;
        if (actual_vp.height > 0) actual_viewport_height = actual_vp.height;
    } else |_| {}

    // Ensure actual viewport also respects pixel limit
    const actual_total_pixels: u64 = @as(u64, actual_viewport_width) * @as(u64, actual_viewport_height);
    if (actual_total_pixels > MAX_PIXELS) {
        const actual_scale = @sqrt(@as(f64, @floatFromInt(MAX_PIXELS)) / @as(f64, @floatFromInt(actual_total_pixels)));
        actual_viewport_width = @intFromFloat(@as(f64, @floatFromInt(actual_viewport_width)) * actual_scale);
        actual_viewport_height = @intFromFloat(@as(f64, @floatFromInt(actual_viewport_height)) * actual_scale);
    }

    // Run viewer with Chrome's actual viewport for accurate coordinate mapping
    // Also pass original (pre-MAX_PIXELS) dimensions for coordinate ratio calculation
    var viewer = try viewer_mod.Viewer.init(allocator, client, url, actual_viewport_width, actual_viewport_height, original_viewport_width, original_viewport_height, @intCast(cell_width), fps);
    defer viewer.deinit();

    // Apply options
    if (no_toolbar) {
        viewer.disableToolbar();
    }
    if (disable_hotkeys) {
        viewer.disableHotkeys();
    }
    if (disable_hints) {
        viewer.disableHints();
    }

    try viewer.run();
}

fn cmdVersion() !void {
    std.debug.print("termweb version {s}\n", .{VERSION});
}

fn printHelp() void {
    std.debug.print(
        \\termweb - Web browser in your terminal using Kitty graphics
        \\
        \\Usage:
        \\  termweb open <url> [options]
        \\
        \\Options:
        \\  --profile [name]      Clone Chrome profile (default: 'Default')
        \\  --no-toolbar          Hide navigation bar (app/kiosk mode)
        \\  --disable-hotkeys     Disable all keyboard shortcuts (except Ctrl+Q)
        \\  --disable-hints       Disable Ctrl+H hint mode
        \\  --browser-path <path> Path to browser executable
        \\  --fps <N>             Set frame rate 1-30 (default: 30, use 12 for SSH)
        \\  --list-profiles       Show available Chrome profiles
        \\  --list-browsers       Show available browsers
        \\
        \\Keyboard (all shortcuts use Ctrl):
        \\  Ctrl+Q                Quit
        \\  Ctrl+L                Focus address bar
        \\  Ctrl+R                Reload page
        \\  Ctrl+[                Go back
        \\  Ctrl+]                Go forward
        \\  Ctrl+.                Stop loading
        \\  Ctrl+N                New tab (about:blank)
        \\  Ctrl+W                Close tab (quit if last tab)
        \\  Ctrl+T                Show tab picker
        \\  Ctrl+H                Enter hint mode (Vimium-style click navigation)
        \\  Ctrl+J                Scroll down
        \\  Ctrl+K                Scroll up
        \\  Ctrl+C                Copy selection
        \\  Ctrl+X                Cut selection
        \\  Ctrl+V                Paste
        \\  Ctrl+A                Select all
        \\
        \\Hint Mode:
        \\  Press Ctrl+H to show clickable element labels.
        \\  Type letters to click. Escape to cancel.
        \\
        \\Mouse:
        \\  Click                 Interact with page elements
        \\  Toolbar               Navigation buttons (back, forward, reload/stop)
        \\
        \\Other commands:
        \\  termweb version       Show version
        \\  termweb mux           Start terminal multiplexer server
        \\  termweb help          Show this help
        \\
        \\Mux options:
        \\  --port, -p PORT       Set HTTP port (default: 8080)
        \\  --local               Local only, skip connection picker
        \\  --cloudflare          Expose via Cloudflare Tunnel
        \\  --ngrok               Expose via ngrok
        \\  --tailscale           Expose via Tailscale Funnel
        \\
        \\Examples:
        \\  termweb open https://example.com
        \\  termweb open https://github.com --profile Default
        \\  termweb mux --port 8080
        \\  termweb mux --local
        \\  termweb mux --cloudflare
        \\
        \\Requirements:
        \\  - Chrome or Chromium (set CHROME_BIN if not auto-detected)
        \\  - Kitty-compatible terminal: Ghostty, Kitty, or WezTerm
        \\
    , .{});
}

fn cmdMux(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var http_port: u16 = 8080;
    var mode: mux.tunnel_mod.Mode = .interactive;

    // Skip "termweb" and "mux" args
    const mux_args = if (args.len > 2) args[2..] else &[_][]const u8{};
    var i: usize = 0;
    while (i < mux_args.len) : (i += 1) {
        const arg = mux_args[i];
        if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            if (i + 1 < mux_args.len) {
                http_port = std.fmt.parseInt(u16, mux_args[i + 1], 10) catch 8080;
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--local")) {
            mode = .local;
        } else if (std.mem.eql(u8, arg, "--cloudflare")) {
            mode = .{ .tunnel = .cloudflare };
        } else if (std.mem.eql(u8, arg, "--ngrok")) {
            mode = .{ .tunnel = .ngrok };
        } else if (std.mem.eql(u8, arg, "--tailscale")) {
            mode = .{ .tunnel = .tailscale };
        }
    }

    try mux.run(allocator, http_port, mode);
}
