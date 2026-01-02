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
