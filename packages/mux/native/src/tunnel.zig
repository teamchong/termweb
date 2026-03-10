//! Tunnel provider detection, subprocess management, and connection mode picker.
//!
//! Detects installed tunnel tools (cloudflared) and spawns them
//! to expose the local server publicly, parsing the resulting public URL.
//! Supports both named tunnels (via ~/.cloudflared/config.yml) and quick tunnels.
//!
const std = @import("std");

pub const Provider = enum {
    cloudflared,

    pub fn binary(self: Provider) []const u8 {
        return switch (self) {
            .cloudflared => "cloudflared",
        };
    }

    pub fn label(self: Provider) []const u8 {
        return switch (self) {
            .cloudflared => "Cloudflare Tunnel",
        };
    }

    pub fn cliFlag(self: Provider) []const u8 {
        return switch (self) {
            .cloudflared => "--cloudflare",
        };
    }
};

/// Connection mode selected by user or CLI arg.
pub const Mode = union(enum) {
    interactive,
    local,
    tunnel: Provider,
};

/// All providers in display order.
const all_providers = [_]Provider{.cloudflared};

/// Check if a binary exists in PATH by searching each PATH directory.
pub fn binaryExists(binary_name: []const u8) bool {
    const path_env = std.posix.getenv("PATH") orelse return false;
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, binary_name }) catch continue;
        std.fs.accessAbsolute(full_path, .{}) catch continue;
        return true;
    }
    return false;
}

/// Get the LAN IP address by running `hostname -I` and taking the first result.
pub fn getLanUrl(allocator: std.mem.Allocator, port: u16) ?[]const u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "hostname", "-I" },
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.stdout.len == 0) return null;
    // First IP from hostname -I (space-separated)
    var it = std.mem.splitScalar(u8, result.stdout, ' ');
    const ip = std.mem.trim(u8, it.first(), &[_]u8{ ' ', '\t', '\r', '\n' });
    if (ip.len == 0) return null;

    return std.fmt.allocPrint(allocator, "http://{s}:{}", .{ ip, port }) catch null;
}

/// Auto-detect the best available tunnel provider.
pub fn detectProvider() ?Provider {
    for (all_providers) |provider| {
        if (binaryExists(provider.binary())) return provider;
    }
    return null;
}

/// Show an interactive connection mode picker. Returns the chosen provider or null for local-only.
/// Uses raw terminal mode so a single keypress selects the option (no Enter needed).
pub fn promptConnectionMode() ?Provider {
    std.debug.print("\nConnection mode:\n\n", .{});
    std.debug.print("   1) {s:<23}termweb mux --local\n", .{"Local only"});

    for (all_providers, 0..) |provider, i| {
        const installed = binaryExists(provider.binary());
        const status: []const u8 = if (installed) "installed" else "not found";
        std.debug.print("   {}) {s:<23}termweb mux {s:<14}[{s}]\n", .{
            i + 2,
            provider.label(),
            provider.cliFlag(),
            status,
        });
    }

    std.debug.print("\nChoose [1-2] (default 1): ", .{});

    // Set raw mode: single keypress without Enter
    const old_termios = std.posix.tcgetattr(std.posix.STDIN_FILENO) catch {
        // Fallback to line-buffered read if tcgetattr fails (e.g. piped stdin)
        return promptConnectionModeFallback();
    };
    var raw = old_termios;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, raw) catch {
        return promptConnectionModeFallback();
    };
    defer std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, old_termios) catch {};

    var buf: [1]u8 = undefined;
    const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch return null;
    if (n == 0) return null;

    const ch = buf[0];
    // Echo the choice and newline
    std.debug.print("{c}\n", .{ch});

    // Enter or newline = default (local)
    if (ch == '\r' or ch == '\n') return null;

    const choice = std.fmt.charToDigit(ch, 10) catch {
        std.debug.print("Invalid choice, using local only.\n", .{});
        return null;
    };

    return resolveChoice(choice);
}

/// Fallback for when terminal raw mode is unavailable (piped stdin, etc.)
fn promptConnectionModeFallback() ?Provider {
    var buf: [32]u8 = undefined;
    const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch return null;
    if (n == 0) return null;
    const input = std.mem.trim(u8, buf[0..n], &[_]u8{ ' ', '\t', '\r', '\n' });
    if (input.len == 0) return null;

    const choice = std.fmt.parseInt(u8, input, 10) catch {
        std.debug.print("Invalid choice, using local only.\n", .{});
        return null;
    };

    return resolveChoice(choice);
}

/// Validate a numeric tunnel choice and return the provider (or null for local).
fn resolveChoice(choice: u8) ?Provider {
    if (choice == 1 or choice == 0) return null;
    if (choice == 2) {
        const provider = all_providers[0];
        if (!binaryExists(provider.binary())) {
            std.debug.print("\n'{s}' is not installed. Install it from:\n", .{provider.binary()});
            printInstallUrl(provider);
            std.debug.print("Using local only.\n\n", .{});
            return null;
        }
        return provider;
    }
    std.debug.print("Invalid choice, using local only.\n", .{});
    return null;
}

fn printInstallUrl(provider: Provider) void {
    switch (provider) {
        .cloudflared => std.debug.print("  https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/\n", .{}),
    }
}

/// Print a QR code to the terminal using the best available tool.
/// Tries: qrencode, python3 qrcode module, python3 segno module.
pub fn printQrCode(allocator: std.mem.Allocator, url: []const u8) void {
    // Try qrencode first (fastest, best output)
    if (tryQrencode(allocator, url)) return;
    // Fall back to python3 with segno (pip install segno) or qrcode module
    if (tryPythonQr(allocator, url)) return;
    std.debug.print("\n  (install 'qrencode' for QR code: sudo apt install qrencode)\n", .{});
}

fn tryQrencode(allocator: std.mem.Allocator, url: []const u8) bool {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "qrencode", "-t", "UTF8", "-m", "2", url },
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.stdout.len > 0) {
        printQrOutput(result.stdout);
        return true;
    }
    return false;
}

fn tryPythonQr(allocator: std.mem.Allocator, url: []const u8) bool {
    // Python one-liner using segno (common) or qrcode module
    const script = std.fmt.allocPrint(allocator,
        \\try:
        \\  import segno; segno.make('{s}').terminal(compact=True)
        \\except ImportError:
        \\  try:
        \\    import qrcode; q=qrcode.QRCode(box_size=1,border=2); q.add_data('{s}'); q.make(); q.print_ascii(invert=True)
        \\  except ImportError: exit(1)
    , .{ url, url }) catch return false;
    defer allocator.free(script);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "python3", "-c", script },
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.stdout.len > 0) {
        printQrOutput(result.stdout);
        return true;
    }
    return false;
}

fn printQrOutput(output: []const u8) void {
    std.debug.print("\n", .{});
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| {
        if (line.len > 0) std.debug.print("  {s}\n", .{line});
    }
}

pub const Tunnel = struct {
    process: ?std.process.Child,
    provider: Provider,
    allocator: std.mem.Allocator,
    public_url: [512]u8 = undefined,
    url_len: usize = 0,
    reader_thread: ?std.Thread = null,
    url_ready: std.Thread.ResetEvent = .{},

    /// Check if a named cloudflared tunnel config exists (~/.cloudflared/config.yml).
    fn hasNamedTunnelConfig() bool {
        const home = std.posix.getenv("HOME") orelse return false;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/.cloudflared/config.yml", .{home}) catch return false;
        std.fs.accessAbsolute(path, .{}) catch return false;
        return true;
    }

    /// Read a YAML value by key from ~/.cloudflared/config.yml.
    /// Simple line-by-line parser — handles "key: value" and "- key: value" (ingress).
    fn readConfigValue(allocator: std.mem.Allocator, key: []const u8) ?[]const u8 {
        const home = std.posix.getenv("HOME") orelse return null;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/.cloudflared/config.yml", .{home}) catch return null;
        const file = std.fs.openFileAbsolute(path, .{}) catch return null;
        defer file.close();
        var buf: [4096]u8 = undefined;
        const n = file.readAll(&buf) catch return null;
        const content = buf[0..n];
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &[_]u8{ ' ', '\t', '\r', '-' });
            if (std.mem.startsWith(u8, trimmed, key)) {
                const after_key = trimmed[key.len..];
                if (after_key.len > 0 and after_key[0] == ':') {
                    const value = std.mem.trim(u8, after_key[1..], &[_]u8{ ' ', '\t' });
                    if (value.len > 0) return allocator.dupe(u8, value) catch null;
                }
            }
        }
        return null;
    }

    /// Spawn a tunnel subprocess for the given provider and port.
    /// Uses named tunnel (`cloudflared tunnel run`) if config exists,
    /// otherwise falls back to quick tunnel (`cloudflared tunnel --url`).
    pub fn start(allocator: std.mem.Allocator, provider: Provider, port: u16) !*Tunnel {
        _ = provider;

        var proc: std.process.Child = undefined;

        // Prefer named tunnel if config exists
        const tunnel_name = if (hasNamedTunnelConfig()) readConfigValue(allocator, "tunnel") else null;
        const hostname = if (tunnel_name != null) readConfigValue(allocator, "hostname") else null;

        if (tunnel_name) |name| {
            std.debug.print("Starting named tunnel '{s}'...\n", .{name});
            proc = std.process.Child.init(
                &.{ "cloudflared", "tunnel", "run", name },
                allocator,
            );
        } else {
            // cloudflared quick tunnel: no account needed, generates a trycloudflare.com URL
            var port_buf: [8]u8 = undefined;
            const port_str = std.fmt.bufPrint(&port_buf, "{}", .{port}) catch unreachable;
            var url_buf: [64]u8 = undefined;
            const local_url = std.fmt.bufPrint(&url_buf, "http://localhost:{s}", .{port_str}) catch unreachable;

            proc = std.process.Child.init(
                &.{ "cloudflared", "tunnel", "--url", local_url },
                allocator,
            );
        }

        proc.stderr_behavior = .Pipe;
        proc.stdout_behavior = .Pipe;
        try proc.spawn();

        const tun = try allocator.create(Tunnel);
        tun.* = .{
            .process = proc,
            .provider = .cloudflared,
            .allocator = allocator,
        };

        // For named tunnels, set the URL immediately from config
        if (hostname) |h| {
            var url_buf: [512]u8 = undefined;
            const url = std.fmt.bufPrint(&url_buf, "https://{s}", .{h}) catch null;
            if (url) |u| tun.setPublicUrl(u);
            allocator.free(h);
        }
        if (tunnel_name) |name| allocator.free(name);

        // Read stderr in background thread to parse the public URL (quick tunnel)
        // or capture error output (named tunnel)
        tun.reader_thread = std.Thread.spawn(.{}, Tunnel.readerThread, .{tun}) catch null;

        return tun;
    }

    /// Block until the public URL is available or timeout expires.
    pub fn waitForUrl(self: *Tunnel, timeout_ns: u64) bool {
        self.url_ready.timedWait(timeout_ns) catch return false;
        return self.url_len > 0;
    }

    /// Get the parsed public URL, or null if not yet available.
    pub fn getUrl(self: *Tunnel) ?[]const u8 {
        if (self.url_len == 0) return null;
        return self.public_url[0..self.url_len];
    }

    /// Stop the tunnel subprocess and clean up.
    pub fn stop(self: *Tunnel) void {
        if (self.process) |*proc| {
            _ = proc.kill() catch {};
        }

        if (self.reader_thread) |thread| {
            thread.join();
        }

        if (self.process) |*proc| {
            _ = proc.wait() catch {};
        }

        self.allocator.destroy(self);
    }

    /// Store a URL into the public_url buffer and signal readiness.
    fn setPublicUrl(self: *Tunnel, url: []const u8) void {
        const len = @min(url.len, self.public_url.len);
        @memcpy(self.public_url[0..len], url[0..len]);
        self.url_len = len;
        self.url_ready.set();
    }

    /// Reader thread: reads subprocess stderr line by line, parses URL.
    /// cloudflared outputs the tunnel URL to stderr.
    fn readerThread(self: *Tunnel) void {
        const proc = self.process orelse return;
        const pipe = proc.stderr orelse return;

        const fd = pipe.handle;
        var buf: [4096]u8 = undefined;
        var carry: [4096]u8 = undefined;
        var carry_len: usize = 0;

        while (true) {
            const n = std.posix.read(fd, &buf) catch break;
            if (n == 0) break;

            // Process data with any leftover from previous read
            var data_start: usize = 0;
            for (buf[0..n], 0..) |ch, i| {
                if (ch == '\n') {
                    // Complete line: carry + buf[data_start..i]
                    var line: []const u8 = undefined;
                    if (carry_len > 0) {
                        const remaining = i - data_start;
                        if (carry_len + remaining <= carry.len) {
                            @memcpy(carry[carry_len .. carry_len + remaining], buf[data_start..i]);
                            line = carry[0 .. carry_len + remaining];
                        } else {
                            carry_len = 0;
                            data_start = i + 1;
                            continue;
                        }
                    } else {
                        line = buf[data_start..i];
                    }

                    // Try to extract URL
                    if (self.url_len == 0) {
                        if (extractCloudflaredUrl(line)) |url| {
                            self.setPublicUrl(url);
                        }
                    }

                    // Print error/status lines so user sees tunnel problems
                    if (self.url_len == 0 and line.len > 0) {
                        self.printTunnelLine(line);
                    }

                    carry_len = 0;
                    data_start = i + 1;
                }
            }

            // Save leftover data for next read
            const leftover = n - data_start;
            if (leftover > 0 and leftover <= carry.len) {
                @memcpy(carry[0..leftover], buf[data_start..n]);
                carry_len = leftover;
            }
        }

        // Pipe closed (subprocess exited) — signal url_ready so waitForUrl
        // unblocks immediately instead of waiting the full timeout.
        self.url_ready.set();
    }

    /// Print relevant tunnel output lines to the user.
    fn printTunnelLine(self: *Tunnel, line: []const u8) void {
        _ = self;
        std.debug.print("  cloudflared: {s}\n", .{line});
    }

    /// cloudflared: look for https://*.trycloudflare.com URL in stderr output
    fn extractCloudflaredUrl(line: []const u8) ?[]const u8 {
        // cloudflared quick tunnel outputs lines like:
        //   ... https://random-words.trycloudflare.com ...
        const marker = "https://";
        var search = line;
        while (std.mem.indexOf(u8, search, marker)) |pos| {
            const rest = search[pos..];
            // Find end of URL (whitespace or end of line)
            const end = for (rest, 0..) |ch, i| {
                if (ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n') break i;
            } else rest.len;
            if (end <= marker.len) {
                search = search[pos + marker.len ..];
                continue;
            }
            const url = rest[0..end];
            // Accept .trycloudflare.com (quick tunnel) or any cloudflare tunnel URL
            if (std.mem.indexOf(u8, url, ".trycloudflare.com") != null) return url;
            // Also accept configured tunnel domains (any https:// URL from cloudflared)
            if (std.mem.indexOf(u8, url, "cloudflare") != null) return url;
            search = search[pos + end ..];
        }
        return null;
    }
};


// Tests


test "extractCloudflaredUrl: extracts trycloudflare.com URL" {
    const url = Tunnel.extractCloudflaredUrl("INF |  https://random-words-here.trycloudflare.com");
    try std.testing.expectEqualStrings("https://random-words-here.trycloudflare.com", url.?);
}

test "extractCloudflaredUrl: extracts URL with trailing space" {
    const url = Tunnel.extractCloudflaredUrl("https://my-tunnel.trycloudflare.com some other text");
    try std.testing.expectEqualStrings("https://my-tunnel.trycloudflare.com", url.?);
}

test "extractCloudflaredUrl: returns null for non-cloudflare URL" {
    try std.testing.expect(Tunnel.extractCloudflaredUrl("https://example.com") == null);
}

test "extractCloudflaredUrl: returns null for bare https://" {
    try std.testing.expect(Tunnel.extractCloudflaredUrl("just https:// alone") == null);
}

test "extractCloudflaredUrl: returns null for http (not https)" {
    try std.testing.expect(Tunnel.extractCloudflaredUrl("http://random.trycloudflare.com") == null);
}

test "Provider: only cloudflared exists" {
    const fields = @typeInfo(Provider).@"enum".fields;
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings("cloudflared", fields[0].name);
}

test "Provider: binary returns cloudflared" {
    try std.testing.expectEqualStrings("cloudflared", Provider.cloudflared.binary());
}

test "Provider: cliFlag returns --cloudflare" {
    try std.testing.expectEqualStrings("--cloudflare", Provider.cloudflared.cliFlag());
}

test "all_providers: contains only cloudflared" {
    try std.testing.expectEqual(@as(usize, 1), all_providers.len);
    try std.testing.expectEqual(Provider.cloudflared, all_providers[0]);
}
