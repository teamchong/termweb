const std = @import("std");

const detector = @import("chrome/detector.zig");
const launcher = @import("chrome/launcher.zig");
const cdp = @import("chrome/cdp_client.zig");
const screenshot_api = @import("chrome/screenshot.zig");
const terminal_mod = @import("terminal/terminal.zig");
const viewer_mod = @import("viewer.zig");

const VERSION = "0.6.0";

const Command = enum {
    open,
    doctor,
    help,
    version,
    unknown,
};

const OpenOptions = struct {
    url: []const u8,
    mobile: bool = false,
    scale: f32 = 1.0,
    headless: bool = false,
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
    if (args.len < 1) {
        std.debug.print("Error: URL required\n", .{});
        std.debug.print("Usage: termweb open <url> [--mobile] [--scale N]\n", .{});
        std.process.exit(1);
    }

    // Check terminal support first
    if (!try checkTerminalSupport(allocator)) {
        std.process.exit(1);
    }

    const url = args[0];
    var mobile = false;
    var scale: f32 = 1.0;

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
        }
    }

    std.debug.print("Launching Chrome...\n", .{});

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

    // Calculate viewport size (use pixel dimensions or estimate from cols/rows)
    // Min size: 800x600 to ensure websites render properly
    // Max size: Use full terminal size, reserving 1 row for status line
    const MIN_WIDTH: u32 = 800;
    const MIN_HEIGHT: u32 = 600;

    const raw_width: u32 = if (size.width_px > 0) size.width_px else @as(u32, size.cols) * 10;

    // Reserve 1 row for tab bar at top (no status bar)
    const row_height: u32 = if (size.height_px > 0 and size.rows > 0)
        @as(u32, size.height_px) / size.rows
    else
        20;
    const content_rows: u32 = if (size.rows > 1) size.rows - 1 else 1;
    const available_height = content_rows * row_height;

    // Apply min constraints to ensure websites render properly
    const viewport_width: u32 = @max(MIN_WIDTH, raw_width);
    const viewport_height: u32 = @max(MIN_HEIGHT, available_height);

    std.debug.print("Terminal: {}x{} ({} cols x {} rows)\n", .{
        size.width_px,
        size.height_px,
        size.cols,
        size.rows,
    });
    std.debug.print("Viewport: {}x{} (min: {}x{})\n", .{
        viewport_width,
        viewport_height,
        MIN_WIDTH,
        MIN_HEIGHT,
    });

    // Launch Chrome
    var chrome_instance = launcher.launchChrome(allocator, .{
        .viewport_width = viewport_width,
        .viewport_height = viewport_height,
    }) catch |err| {
        std.debug.print("Error launching Chrome: {}\n", .{err});
        std.debug.print("Make sure Chrome is installed or set $CHROME_BIN\n", .{});
        std.process.exit(1);
    };
    defer chrome_instance.deinit();

    std.debug.print("Chrome launched\n", .{});

    // Connect CDP client
    var client = cdp.CdpClient.init(allocator, chrome_instance.ws_url) catch |err| {
        std.debug.print("Error connecting to Chrome DevTools Protocol: {}\n", .{err});
        std.process.exit(1);
    };
    defer client.deinit();

    std.debug.print("Connected to Chrome\n", .{});
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

    // Not supported - show helpful error
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

    // Check terminal type
    const term_env = std.process.getEnvVarOwned(allocator, "TERM") catch null;
    defer if (term_env) |t| allocator.free(t);

    const term_program = std.process.getEnvVarOwned(allocator, "TERM_PROGRAM") catch null;
    defer if (term_program) |t| allocator.free(t);

    std.debug.print("Terminal:\n", .{});
    std.debug.print("  TERM: {s}\n", .{term_env orelse "not set"});
    std.debug.print("  TERM_PROGRAM: {s}\n", .{term_program orelse "not set"});

    // Check for Kitty graphics support
    std.debug.print("\nKitty Graphics Protocol:\n", .{});
    const supports_kitty = blk: {
        if (term_program) |tp| {
            if (std.mem.eql(u8, tp, "ghostty") or
                std.mem.eql(u8, tp, "kitty") or
                std.mem.eql(u8, tp, "WezTerm")) {
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

    // Check for truecolor support
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

    // Check for Chrome
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

    // Overall status
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
        \\                   --mobile      Use mobile viewport
        \\                   --scale N     Set zoom scale (default: 1.0)
        \\  doctor         Check system capabilities
        \\  version        Show version information
        \\  help           Show this help message
        \\
        \\Examples:
        \\  termweb open https://example.com
        \\  termweb open https://example.com --mobile
        \\  termweb open https://example.com --scale 0.8
        \\  termweb doctor
        \\
        \\Supported terminals: Ghostty, Kitty, WezTerm
        \\
    , .{});
}
