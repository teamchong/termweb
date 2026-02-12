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
    token,
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
        .token => try cmdToken(allocator, args),
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
    if (std.mem.eql(u8, arg, "token")) return .token;
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
    var clone_profile: ?[]const u8 = "Default"; // Default: use Default Chrome profile
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
        } else if (std.mem.eql(u8, arg, "--no-profile")) {
            clone_profile = null;
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
        \\  --profile [name]      Clone Chrome profile (default: 'Default', used by default)
        \\  --no-profile          Don't clone any Chrome profile
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
        \\  termweb token         Manage auth tokens and share links
        \\  termweb help          Show this help
        \\
        \\Mux options:
        \\
    ++ std.fmt.comptimePrint(
        "  --port, -p PORT       Set HTTP port (default: {d})\n",
        .{mux.default_http_port},
    ) ++
        \\  --local               Local only, skip connection picker
        \\  --tailscale           Expose via Tailscale Serve (VPN)
        \\  --cloudflare          Expose via Cloudflare Tunnel (Public)
        \\  --ngrok               Expose via ngrok (Public)
        \\
        \\Token commands:
        \\  termweb token                              List sessions and tokens
        \\  termweb token regenerate [session-id]      Regenerate tokens (default session)
        \\  termweb token share --role editor           Create share link
        \\    [--expires 1h] [--max-uses 10] [--label "Demo"]
        \\  termweb token revoke <token>               Revoke a share link
        \\  termweb token revoke --all                 Revoke all share links
        \\
        \\Examples:
        \\  termweb open https://example.com
        \\  termweb open https://github.com --profile Default
        \\
    ++ std.fmt.comptimePrint(
        "  termweb mux --port {d}\n",
        .{mux.default_http_port},
    ) ++
        \\  termweb mux --local
        \\  termweb mux --tailscale
        \\
        \\Requirements:
        \\  - Chrome or Chromium (set CHROME_BIN if not auto-detected)
        \\  - Kitty-compatible terminal: Ghostty, Kitty, or WezTerm
        \\
    , .{});
}

const auth = mux.auth;

fn cmdToken(allocator: std.mem.Allocator, args: []const []const u8) !void {
    // Load auth state from ~/.termweb/auth.json
    var state = auth.AuthState.init(allocator) catch |err| {
        std.debug.print("Error loading auth state: {}\n", .{err});
        std.process.exit(1);
    };
    defer state.deinit();

    const sub_args = if (args.len > 2) args[2..] else &[_][]const u8{};

    if (sub_args.len == 0) {
        // Default: list sessions and tokens
        tokenList(state);
        return;
    }

    const subcmd = sub_args[0];

    if (std.mem.eql(u8, subcmd, "list")) {
        tokenList(state);
    } else if (std.mem.eql(u8, subcmd, "regenerate")) {
        const session_id = if (sub_args.len > 1) sub_args[1] else "default";
        tokenRegenerate(state, session_id);
    } else if (std.mem.eql(u8, subcmd, "share")) {
        tokenShare(state, sub_args[1..]);
    } else if (std.mem.eql(u8, subcmd, "revoke")) {
        tokenRevoke(state, sub_args[1..]);
    } else {
        std.debug.print("Unknown token subcommand: {s}\n\n", .{subcmd});
        std.debug.print("Usage: termweb token [list|regenerate|share|revoke]\n", .{});
        std.process.exit(1);
    }
}

fn tokenList(state: *auth.AuthState) void {
    std.debug.print("Sessions:\n", .{});
    var iter = state.sessions.iterator();
    var has_sessions = false;
    while (iter.next()) |entry| {
        has_sessions = true;
        const session = entry.value_ptr;
        std.debug.print("  {s} ({s})\n", .{ session.id, session.name });

        var enc_buf: [192]u8 = undefined;
        const editor_enc = auth.percentEncodeToken(&enc_buf, &session.editor_token);
        std.debug.print("    Editor: http://localhost:{d}/?token={s}\n", .{ mux.default_http_port, editor_enc });

        const viewer_enc = auth.percentEncodeToken(&enc_buf, &session.viewer_token);
        std.debug.print("    Viewer: http://localhost:{d}/?token={s}\n", .{ mux.default_http_port, viewer_enc });
    }
    if (!has_sessions) {
        std.debug.print("  (no sessions)\n", .{});
    }

    // Share links
    if (state.share_links.items.len > 0) {
        std.debug.print("\nShare links: {d} active\n", .{state.share_links.items.len});
        for (state.share_links.items) |link| {
            var enc_buf2: [192]u8 = undefined;
            const tok_enc = auth.percentEncodeToken(&enc_buf2, &link.token);

            const role_str: []const u8 = switch (link.token_type) {
                .admin => "admin",
                .editor => "editor",
                .viewer => "viewer",
            };

            std.debug.print("  {s}  {s}", .{ tok_enc[0..@min(tok_enc.len, 12)], role_str });

            // Expiry info
            if (link.expires_at) |exp| {
                const now = std.time.timestamp();
                const remaining = exp - now;
                if (remaining <= 0) {
                    std.debug.print("  expires: expired", .{});
                } else if (remaining < 3600) {
                    std.debug.print("  expires: {d}m left", .{@divTrunc(remaining, 60)});
                } else {
                    std.debug.print("  expires: {d}h left", .{@divTrunc(remaining, 3600)});
                }
            } else {
                std.debug.print("  expires: never", .{});
            }

            // Usage info
            if (link.max_uses) |max| {
                std.debug.print("  uses: {d}/{d}", .{ link.use_count, max });
            } else {
                std.debug.print("  uses: {d}/\xe2\x88\x9e", .{link.use_count}); // ∞ in UTF-8
            }

            // Label
            if (link.label) |l| {
                std.debug.print("  \"{s}\"", .{l});
            }
            std.debug.print("\n", .{});
        }
    }
}

fn tokenRegenerate(state: *auth.AuthState, session_id: []const u8) void {
    if (state.getSession(session_id) == null) {
        std.debug.print("Session not found: {s}\n", .{session_id});
        std.process.exit(1);
    }

    state.regenerateSessionToken(session_id, .editor) catch {
        std.debug.print("Error regenerating editor token\n", .{});
        std.process.exit(1);
    };
    state.regenerateSessionToken(session_id, .viewer) catch {
        std.debug.print("Error regenerating viewer token\n", .{});
        std.process.exit(1);
    };

    std.debug.print("Tokens regenerated for session: {s}\n\n", .{session_id});

    // Print new tokens
    if (state.getSession(session_id)) |session| {
        var enc_buf: [192]u8 = undefined;
        const editor_enc = auth.percentEncodeToken(&enc_buf, &session.editor_token);
        std.debug.print("  Editor: http://localhost:{d}/?token={s}\n", .{ mux.default_http_port, editor_enc });

        const viewer_enc = auth.percentEncodeToken(&enc_buf, &session.viewer_token);
        std.debug.print("  Viewer: http://localhost:{d}/?token={s}\n", .{ mux.default_http_port, viewer_enc });
    }
}

fn tokenShare(state: *auth.AuthState, args: []const []const u8) void {
    var role: auth.TokenType = .viewer;
    var expires_secs: ?i64 = null;
    var max_uses: ?u32 = null;
    var label: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--role")) {
            if (i + 1 < args.len) {
                i += 1;
                if (std.mem.eql(u8, args[i], "admin")) {
                    role = .admin;
                } else if (std.mem.eql(u8, args[i], "editor")) {
                    role = .editor;
                } else if (std.mem.eql(u8, args[i], "viewer")) {
                    role = .viewer;
                } else {
                    std.debug.print("Invalid role: {s} (use admin, editor, or viewer)\n", .{args[i]});
                    std.process.exit(1);
                }
            }
        } else if (std.mem.eql(u8, arg, "--expires")) {
            if (i + 1 < args.len) {
                i += 1;
                expires_secs = parseDuration(args[i]);
                if (expires_secs == null) {
                    std.debug.print("Invalid duration: {s} (use e.g. 1h, 30m, 7d)\n", .{args[i]});
                    std.process.exit(1);
                }
            }
        } else if (std.mem.eql(u8, arg, "--max-uses")) {
            if (i + 1 < args.len) {
                i += 1;
                max_uses = std.fmt.parseInt(u32, args[i], 10) catch {
                    std.debug.print("Invalid max-uses: {s}\n", .{args[i]});
                    std.process.exit(1);
                };
            }
        } else if (std.mem.eql(u8, arg, "--label")) {
            if (i + 1 < args.len) {
                i += 1;
                label = args[i];
            }
        }
    }

    const token = state.createShareLink(role, expires_secs, max_uses, label) catch {
        std.debug.print("Error creating share link\n", .{});
        std.process.exit(1);
    };

    var enc_buf: [192]u8 = undefined;
    const tok_enc = auth.percentEncodeToken(&enc_buf, token);

    const role_str: []const u8 = switch (role) {
        .admin => "admin",
        .editor => "editor",
        .viewer => "viewer",
    };

    std.debug.print("Share link created ({s}):\n", .{role_str});
    std.debug.print("  http://localhost:{d}/?token={s}\n", .{ mux.default_http_port, tok_enc });
}

fn tokenRevoke(state: *auth.AuthState, args: []const []const u8) void {
    if (args.len == 0) {
        std.debug.print("Usage: termweb token revoke <token>\n", .{});
        std.debug.print("       termweb token revoke --all\n", .{});
        std.process.exit(1);
    }

    if (std.mem.eql(u8, args[0], "--all")) {
        state.revokeAllShareLinks() catch {
            std.debug.print("Error revoking share links\n", .{});
            std.process.exit(1);
        };
        std.debug.print("All share links revoked.\n", .{});
        return;
    }

    state.revokeShareLink(args[0]) catch {
        std.debug.print("Error revoking share link\n", .{});
        std.process.exit(1);
    };
    std.debug.print("Share link revoked.\n", .{});
}

/// Parse a duration string like "1h", "30m", "7d" into seconds.
fn parseDuration(s: []const u8) ?i64 {
    if (s.len < 2) return null;
    const unit = s[s.len - 1];
    const num_str = s[0 .. s.len - 1];
    const num = std.fmt.parseInt(i64, num_str, 10) catch return null;
    if (num <= 0) return null;
    return switch (unit) {
        'm' => num * 60,
        'h' => num * 3600,
        'd' => num * 86400,
        else => null,
    };
}

fn cmdMux(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var http_port: u16 = mux.default_http_port;
    var mode: mux.tunnel_mod.Mode = .interactive;

    // Skip "termweb" and "mux" args
    const mux_args = if (args.len > 2) args[2..] else &[_][]const u8{};
    var i: usize = 0;
    while (i < mux_args.len) : (i += 1) {
        const arg = mux_args[i];
        if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            if (i + 1 < mux_args.len) {
                http_port = std.fmt.parseInt(u16, mux_args[i + 1], 10) catch mux.default_http_port;
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--local")) {
            mode = .local;
        } else if (std.mem.eql(u8, arg, "--tailscale")) {
            mode = .{ .tunnel = .tailscale };
        } else if (std.mem.eql(u8, arg, "--cloudflare")) {
            mode = .{ .tunnel = .cloudflare };
        } else if (std.mem.eql(u8, arg, "--ngrok")) {
            mode = .{ .tunnel = .ngrok };
        }
    }

    try mux.run(allocator, http_port, mode);
}
