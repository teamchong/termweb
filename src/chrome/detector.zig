const std = @import("std");
const builtin = @import("builtin");

pub const ChromeError = error{
    ChromeNotFound,
    InvalidPath,
    OutOfMemory,
};

/// Chrome binary location
pub const ChromeBinary = struct {
    path: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ChromeBinary) void {
        self.allocator.free(self.path);
    }
};

/// Platform-specific Chrome paths in priority order
const CHROME_PATHS = struct {
    const macos = [_][]const u8{
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
        "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
        "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
    };

    const linux = [_][]const u8{
        "/usr/bin/google-chrome",
        "/usr/bin/google-chrome-stable",
        "/usr/bin/chromium",
        "/usr/bin/chromium-browser",
        "/snap/bin/chromium",
        "/usr/bin/microsoft-edge",
        "/usr/bin/brave-browser",
    };
};

/// Detect Chrome binary path with fallback to $CHROME_BIN
pub fn detectChrome(allocator: std.mem.Allocator) ChromeError!ChromeBinary {
    // 1. Try $CHROME_BIN environment variable first
    if (std.process.getEnvVarOwned(allocator, "CHROME_BIN")) |chrome_bin| {
        errdefer allocator.free(chrome_bin);

        // Verify file exists and is executable
        if (isExecutable(chrome_bin)) {
            return ChromeBinary{
                .path = chrome_bin,
                .allocator = allocator,
            };
        } else {
            allocator.free(chrome_bin);
        }
    } else |_| {}

    // 2. Try platform-specific paths
    const paths = switch (builtin.os.tag) {
        .macos => &CHROME_PATHS.macos,
        .linux => &CHROME_PATHS.linux,
        else => return ChromeError.ChromeNotFound,
    };

    for (paths) |path| {
        if (isExecutable(path)) {
            const path_copy = try allocator.dupe(u8, path);
            return ChromeBinary{
                .path = path_copy,
                .allocator = allocator,
            };
        }
    }

    return ChromeError.ChromeNotFound;
}

/// List all available browsers on the system
pub fn listAvailableBrowsers(allocator: std.mem.Allocator) ![]const []const u8 {
    var browsers = try std.ArrayList([]const u8).initCapacity(allocator, 8);
    errdefer browsers.deinit(allocator);

    const paths = switch (builtin.os.tag) {
        .macos => &CHROME_PATHS.macos,
        .linux => &CHROME_PATHS.linux,
        else => return try browsers.toOwnedSlice(allocator),
    };

    for (paths) |path| {
        if (isExecutable(path)) {
            try browsers.append(allocator, path);
        }
    }

    return try browsers.toOwnedSlice(allocator);
}

/// Get browser name from path
pub fn getBrowserName(path: []const u8) []const u8 {
    if (std.mem.indexOf(u8, path, "Google Chrome Canary")) |_| return "Chrome Canary";
    if (std.mem.indexOf(u8, path, "Google Chrome")) |_| return "Google Chrome";
    if (std.mem.indexOf(u8, path, "Chromium")) |_| return "Chromium";
    if (std.mem.indexOf(u8, path, "Microsoft Edge")) |_| return "Microsoft Edge";
    if (std.mem.indexOf(u8, path, "brave")) |_| return "Brave";
    if (std.mem.indexOf(u8, path, "chromium")) |_| return "Chromium";
    if (std.mem.indexOf(u8, path, "google-chrome")) |_| return "Google Chrome";
    return "Unknown Browser";
}

/// Detect specific browser by name
pub fn detectBrowserByName(allocator: std.mem.Allocator, name: []const u8) ChromeError!ChromeBinary {
    const paths = switch (builtin.os.tag) {
        .macos => &CHROME_PATHS.macos,
        .linux => &CHROME_PATHS.linux,
        else => return ChromeError.ChromeNotFound,
    };

    for (paths) |path| {
        const browser_name = getBrowserName(path);
        // Simple case-insensitive substring match
        if (std.ascii.indexOfIgnoreCase(browser_name, name) != null or
            std.ascii.indexOfIgnoreCase(path, name) != null)
        {
            if (isExecutable(path)) {
                const path_copy = try allocator.dupe(u8, path);
                return ChromeBinary{
                    .path = path_copy,
                    .allocator = allocator,
                };
            }
        }
    }

    return ChromeError.ChromeNotFound;
}

/// CDP session info from /json endpoint
pub const CdpSession = struct {
    title: []const u8,
    url: []const u8,
    ws_url: []const u8,
};

/// Discover CDP sessions on a given port
/// Fetches http://localhost:<port>/json and parses the response
pub fn discoverCdpSessions(allocator: std.mem.Allocator, port: u16) ![]CdpSession {
    const net = std.net;
    const posix = std.posix;

    // Connect to Chrome's JSON endpoint
    const addr = net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    var stream = net.tcpConnectToAddress(addr) catch return error.ConnectionFailed;
    defer stream.close();

    // Set read timeout (2 seconds) to avoid hanging
    const timeout = posix.timeval{ .sec = 2, .usec = 0 };
    posix.setsockopt(stream.handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};

    // Send HTTP request
    const request = "GET /json HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    _ = try stream.write(request);

    // Read response
    var buf: [65536]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = stream.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }

    const response = buf[0..total];

    // Find JSON body (after \r\n\r\n)
    const body_start = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return error.InvalidResponse;
    const body = response[body_start + 4 ..];

    // Parse JSON array - simple parsing for [ {...}, {...} ]
    var sessions = try std.ArrayList(CdpSession).initCapacity(allocator, 8);
    errdefer sessions.deinit(allocator);

    // Find each webSocketDebuggerUrl (handles "key": "value" with optional space)
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, body, pos, "\"webSocketDebuggerUrl\":")) |ws_key_pos| {
        // Find the opening quote of the value (skip ": or ":")
        const after_key = ws_key_pos + "\"webSocketDebuggerUrl\":".len;
        const ws_quote_start = std.mem.indexOfPos(u8, body, after_key, "\"") orelse break;
        const ws_start = ws_quote_start + 1;
        const ws_end = std.mem.indexOfPos(u8, body, ws_start, "\"") orelse break;
        const ws_url = body[ws_start..ws_end];

        // Check target type - only include "page" targets, skip service_worker, iframe, etc.
        // Look backwards from ws_key_pos to find the most recent "type":" field
        var is_page = false;
        if (std.mem.lastIndexOf(u8, body[0..ws_key_pos], "\"type\":")) |type_key_pos| {
            const type_after_key = type_key_pos + "\"type\":".len;
            if (std.mem.indexOfPos(u8, body, type_after_key, "\"")) |type_quote_start| {
                const type_start = type_quote_start + 1;
                if (std.mem.indexOfPos(u8, body, type_start, "\"")) |type_end| {
                    const target_type = body[type_start..type_end];
                    is_page = std.mem.eql(u8, target_type, "page");
                }
            }
        }

        // Skip non-page targets
        if (!is_page) {
            pos = ws_end;
            continue;
        }

        // Extract title
        var title: []const u8 = "Untitled";
        if (std.mem.lastIndexOf(u8, body[0..ws_key_pos], "\"title\":")) |t_key_pos| {
            const t_after_key = t_key_pos + "\"title\":".len;
            if (std.mem.indexOfPos(u8, body, t_after_key, "\"")) |t_quote_start| {
                const t_start = t_quote_start + 1;
                if (std.mem.indexOfPos(u8, body, t_start, "\"")) |t_end| {
                    title = body[t_start..t_end];
                }
            }
        }

        // Extract URL
        var page_url: []const u8 = "";
        if (std.mem.lastIndexOf(u8, body[0..ws_key_pos], "\"url\":")) |u_key_pos| {
            const u_after_key = u_key_pos + "\"url\":".len;
            if (std.mem.indexOfPos(u8, body, u_after_key, "\"")) |u_quote_start| {
                const u_start = u_quote_start + 1;
                if (std.mem.indexOfPos(u8, body, u_start, "\"")) |u_end| {
                    page_url = body[u_start..u_end];
                }
            }
        }

        // Dupe strings since buf is stack-allocated and will go out of scope
        try sessions.append(allocator, .{
            .title = try allocator.dupe(u8, title),
            .url = try allocator.dupe(u8, page_url),
            .ws_url = try allocator.dupe(u8, ws_url),
        });

        pos = ws_end;
    }

    return try sessions.toOwnedSlice(allocator);
}

/// Free CdpSession resources
pub fn freeCdpSessions(allocator: std.mem.Allocator, sessions: []CdpSession) void {
    for (sessions) |session| {
        allocator.free(session.title);
        allocator.free(session.url);
        allocator.free(session.ws_url);
    }
    allocator.free(sessions);
}

/// Check if path exists and is executable
fn isExecutable(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;

    // Try to stat the file to check permissions
    const file = std.fs.cwd().openFile(path, .{}) catch return false;
    defer file.close();

    const stat = file.stat() catch return false;

    // Check if it's a regular file (not directory)
    return stat.kind == .file;
}
