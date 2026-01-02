const std = @import("std");

const VERSION = "0.1.0";

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
    _ = allocator;

    if (args.len < 1) {
        std.debug.print("Error: URL required\n", .{});
        std.debug.print("Usage: termweb open <url> [--mobile] [--scale N]\n", .{});
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

    std.debug.print("Opening: {s}\n", .{url});
    std.debug.print("Mobile mode: {}\n", .{mobile});
    std.debug.print("Scale: {d:.2}\n", .{scale});
    std.debug.print("\n[Not implemented yet - M1 milestone]\n", .{});
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

    // Check for Playwright/Node.js
    std.debug.print("\nBrowser automation:\n", .{});
    std.debug.print("  [Not implemented yet - checking for Node.js/Playwright]\n", .{});

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
