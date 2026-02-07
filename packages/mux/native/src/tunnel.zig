//! Tunnel provider detection, subprocess management, and connection mode picker.
//!
//! Detects installed tunnel tools (cloudflared, ngrok, tailscale),
//! spawns them as subprocesses to expose the local server publicly,
//! and parses the resulting public URL from their output.
//!
const std = @import("std");

pub const Provider = enum {
    cloudflare,
    ngrok,
    tailscale,

    pub fn binary(self: Provider) []const u8 {
        return switch (self) {
            .cloudflare => "cloudflared",
            .ngrok => "ngrok",
            .tailscale => "tailscale",
        };
    }

    pub fn label(self: Provider) []const u8 {
        return switch (self) {
            .cloudflare => "Cloudflare Tunnel",
            .ngrok => "ngrok",
            .tailscale => "Tailscale Funnel",
        };
    }

    pub fn cliFlag(self: Provider) []const u8 {
        return switch (self) {
            .cloudflare => "--cloudflare",
            .ngrok => "--ngrok",
            .tailscale => "--tailscale",
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
const all_providers = [_]Provider{ .cloudflare, .ngrok, .tailscale };

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

    std.debug.print("\nChoose [1-4] (default 1): ", .{});

    var buf: [32]u8 = undefined;
    const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch return null;
    if (n == 0) return null;
    const input = std.mem.trim(u8, buf[0..n], &[_]u8{ ' ', '\t', '\r', '\n' });

    if (input.len == 0) return null; // default: local

    const choice = std.fmt.parseInt(u8, input, 10) catch {
        std.debug.print("Invalid choice, using local only.\n", .{});
        return null;
    };

    if (choice == 1 or choice == 0) return null; // local
    if (choice >= 2 and choice <= 4) {
        const provider = all_providers[choice - 2];
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
        .cloudflare => std.debug.print("  https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/\n", .{}),
        .ngrok => std.debug.print("  https://ngrok.com/download\n", .{}),
        .tailscale => std.debug.print("  https://tailscale.com/download\n", .{}),
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
    process: std.process.Child,
    provider: Provider,
    allocator: std.mem.Allocator,
    public_url: [512]u8 = undefined,
    url_len: usize = 0,
    reader_thread: ?std.Thread = null,
    url_ready: std.Thread.ResetEvent = .{},

    /// Spawn a tunnel subprocess for the given provider and port.
    pub fn start(allocator: std.mem.Allocator, provider: Provider, port: u16) !*Tunnel {
        var port_buf: [8]u8 = undefined;
        const port_str = std.fmt.bufPrint(&port_buf, "{}", .{port}) catch unreachable;

        var origin_buf: [64]u8 = undefined;
        const origin_str = std.fmt.bufPrint(&origin_buf, "http://localhost:{}", .{port}) catch unreachable;

        var argv: [8][]const u8 = undefined;
        var argc: usize = 0;

        switch (provider) {
            .cloudflare => {
                argv[0] = "cloudflared";
                argv[1] = "tunnel";
                argv[2] = "--url";
                argv[3] = origin_str;
                argv[4] = "--no-autoupdate";
                argc = 5;
            },
            .ngrok => {
                argv[0] = "ngrok";
                argv[1] = "http";
                argv[2] = port_str;
                argv[3] = "--log";
                argv[4] = "stdout";
                argv[5] = "--log-format";
                argv[6] = "json";
                argc = 7;
            },
            .tailscale => {
                argv[0] = "tailscale";
                argv[1] = "funnel";
                argv[2] = port_str;
                argc = 3;
            },
        }

        var process = std.process.Child.init(argv[0..argc], allocator);

        // Only pipe the stream we parse; ignore the other to prevent deadlock.
        // If the unused pipe fills up, the subprocess blocks forever.
        switch (provider) {
            .cloudflare => {
                process.stderr_behavior = .Pipe;
                process.stdout_behavior = .Ignore;
            },
            .ngrok, .tailscale => {
                process.stdout_behavior = .Pipe;
                process.stderr_behavior = .Ignore;
            },
        }
        try process.spawn();

        const tun = try allocator.create(Tunnel);
        tun.* = .{
            .process = process,
            .provider = provider,
            .allocator = allocator,
        };

        tun.reader_thread = std.Thread.spawn(.{}, readerThread, .{tun}) catch null;

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
        _ = self.process.kill() catch {};

        if (self.reader_thread) |thread| {
            thread.join();
        }

        _ = self.process.wait() catch {};

        self.allocator.destroy(self);
    }

    /// Reader thread: reads subprocess output line by line, parses URL.
    fn readerThread(self: *Tunnel) void {
        const pipe = switch (self.provider) {
            .cloudflare => self.process.stderr,
            .ngrok, .tailscale => self.process.stdout,
        } orelse return;

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
                    if (self.url_len == 0) {
                        if (carry_len > 0) {
                            const remaining = i - data_start;
                            if (carry_len + remaining <= carry.len) {
                                @memcpy(carry[carry_len .. carry_len + remaining], buf[data_start..i]);
                                const line = carry[0 .. carry_len + remaining];
                                if (self.extractUrl(line)) |url| {
                                    const len = @min(url.len, self.public_url.len);
                                    @memcpy(self.public_url[0..len], url[0..len]);
                                    self.url_len = len;
                                    self.url_ready.set();
                                }
                            }
                        } else {
                            const line = buf[data_start..i];
                            if (self.extractUrl(line)) |url| {
                                const len = @min(url.len, self.public_url.len);
                                @memcpy(self.public_url[0..len], url[0..len]);
                                self.url_len = len;
                                self.url_ready.set();
                            }
                        }
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
    }

    fn extractUrl(self: *Tunnel, line: []const u8) ?[]const u8 {
        return switch (self.provider) {
            .cloudflare => extractCloudflareUrl(line),
            .ngrok => extractNgrokUrl(line),
            .tailscale => extractTailscaleUrl(line),
        };
    }

    /// Cloudflare: look for https://*.trycloudflare.com in stderr output
    fn extractCloudflareUrl(line: []const u8) ?[]const u8 {
        const marker = "https://";
        const suffix = ".trycloudflare.com";
        const pos = std.mem.indexOf(u8, line, marker) orelse return null;
        const after = line[pos..];
        const suffix_pos = std.mem.indexOf(u8, after, suffix) orelse return null;
        const end = suffix_pos + suffix.len;
        return after[0..end];
    }

    /// ngrok: parse JSON log line containing "url":"https://..."
    fn extractNgrokUrl(line: []const u8) ?[]const u8 {
        const marker = "\"url\":\"https://";
        const marker_pos = std.mem.indexOf(u8, line, marker) orelse return null;
        const url_offset = marker_pos + ("\"url\":\"").len;
        if (url_offset >= line.len) return null;
        const rest = line[url_offset..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
        return rest[0..end];
    }

    /// Tailscale: look for https:// URL in stdout
    fn extractTailscaleUrl(line: []const u8) ?[]const u8 {
        const marker = "https://";
        const pos = std.mem.indexOf(u8, line, marker) orelse return null;
        const rest = line[pos..];
        const end = for (rest, 0..) |ch, i| {
            if (ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n') break i;
        } else rest.len;
        if (end <= marker.len) return null;
        return rest[0..end];
    }
};
