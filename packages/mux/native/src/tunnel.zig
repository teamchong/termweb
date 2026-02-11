//! Tunnel provider detection, subprocess management, and connection mode picker.
//!
//! Detects installed tunnel tools (cloudflared, ngrok, tailscale),
//! spawns them as subprocesses to expose the local server publicly,
//! and parses the resulting public URL from their output.
//!
const std = @import("std");

pub const Provider = enum {
    tailscale,
    cloudflare,
    ngrok,

    pub fn binary(self: Provider) []const u8 {
        return switch (self) {
            .tailscale => "tailscale",
            .cloudflare => "cloudflared",
            .ngrok => "ngrok",
        };
    }

    pub fn label(self: Provider) []const u8 {
        return switch (self) {
            .tailscale => "Tailscale Serve (VPN)",
            .cloudflare => "Cloudflare Tunnel (Public)",
            .ngrok => "ngrok (Public)",
        };
    }

    pub fn cliFlag(self: Provider) []const u8 {
        return switch (self) {
            .tailscale => "--tailscale",
            .cloudflare => "--cloudflare",
            .ngrok => "--ngrok",
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
const all_providers = [_]Provider{ .tailscale, .cloudflare, .ngrok };

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

    std.debug.print("\nChoose [1-4] (default 1): ", .{});

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

    if (choice == 1 or choice == 0) return null;
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

/// Get the tailscale serve URL from `tailscale serve status`.
/// Returns an allocated string or null.
fn getTailscaleStatusUrl(allocator: std.mem.Allocator) ?[]const u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "tailscale", "serve", "status" },
    }) catch return null;
    defer allocator.free(result.stderr);
    // tailscale serve status outputs to stdout: "https://hostname.ts.net (tailnet only)\n|-- ..."
    defer allocator.free(result.stdout);
    if (result.stdout.len == 0) return null;

    // Parse first line for https:// URL
    var it = std.mem.splitScalar(u8, result.stdout, '\n');
    const first_line = it.first();
    const marker = "https://";
    const pos = std.mem.indexOf(u8, first_line, marker) orelse return null;
    const rest = first_line[pos..];
    // Stop at whitespace or parenthesis
    const end = for (rest, 0..) |ch, i| {
        if (ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n' or ch == '(') break i;
    } else rest.len;
    if (end <= marker.len) return null;

    return allocator.dupe(u8, rest[0..end]) catch null;
}

/// Validate that the tailscale serve proxy port matches the expected server port.
/// Warns the user if there's a stale config pointing to the wrong port.
fn validateTailscaleFunnelPort(allocator: std.mem.Allocator, expected_port: u16) void {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "tailscale", "serve", "status" },
    }) catch return;
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    // Look for "proxy http://localhost:<port>" in the output
    const proxy_marker = "proxy http://localhost:";
    const pos = std.mem.indexOf(u8, result.stdout, proxy_marker) orelse return;
    const num_start = pos + proxy_marker.len;
    var num_end = num_start;
    while (num_end < result.stdout.len and result.stdout[num_end] >= '0' and result.stdout[num_end] <= '9') : (num_end += 1) {}
    if (num_end == num_start) return;
    const configured_port = std.fmt.parseInt(u16, result.stdout[num_start..num_end], 10) catch return;

    if (configured_port != expected_port) {
        std.debug.print(
            "\n  WARNING: Tailscale serve is proxying to port {}, but server is on port {}.\n" ++
            "  The tunnel URL will NOT work until this is fixed.\n" ++
            "  Fix: sudo tailscale serve reset && sudo tailscale up --operator=$USER\n" ++
            "  Then restart termweb.\n\n",
            .{ configured_port, expected_port },
        );
    }
}

/// Print a JSON error string, replacing literal \n with real newlines and trimming \r.
fn printCleanError(provider_name: []const u8, msg: []const u8) void {
    std.debug.print("  {s}: ", .{provider_name});
    var i: usize = 0;
    while (i < msg.len) {
        if (i + 1 < msg.len and msg[i] == '\\' and msg[i + 1] == 'n') {
            std.debug.print("\n  {s}  ", .{provider_name});
            i += 2;
        } else if (i + 1 < msg.len and msg[i] == '\\' and msg[i + 1] == 'r') {
            i += 2;
        } else {
            std.debug.print("{c}", .{msg[i]});
            i += 1;
        }
    }
    std.debug.print("\n", .{});
}

fn printInstallUrl(provider: Provider) void {
    switch (provider) {
        .tailscale => std.debug.print("  https://tailscale.com/download\n", .{}),
        .cloudflare => std.debug.print("  https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/\n", .{}),
        .ngrok => std.debug.print("  https://ngrok.com/download\n", .{}),
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
    error_shown: bool = false,

    /// Spawn a tunnel subprocess for the given provider and port.
    pub fn start(allocator: std.mem.Allocator, provider: Provider, port: u16) !*Tunnel {
        var port_buf: [8]u8 = undefined;
        const port_str = std.fmt.bufPrint(&port_buf, "{}", .{port}) catch unreachable;

        var origin_buf: [64]u8 = undefined;
        const origin_str = std.fmt.bufPrint(&origin_buf, "http://localhost:{}", .{port}) catch unreachable;

        var argv: [8][]const u8 = undefined;
        var argc: usize = 0;

        // Tailscale uses --bg (daemon-managed, no subprocess needed).
        // Cloudflare and ngrok run as long-lived subprocesses.
        if (provider == .tailscale) {
            // Reset stale config, then configure via --bg (runs in tailscale daemon)
            _ = std.process.Child.run(.{
                .allocator = allocator,
                .argv = &.{ "tailscale", "serve", "reset" },
            }) catch {};
            const bg_result = std.process.Child.run(.{
                .allocator = allocator,
                .argv = &.{ "tailscale", "serve", "--bg", port_str },
            }) catch |err| {
                std.debug.print("  tailscale serve --bg failed: {}\n", .{err});
                return error.TunnelFailed;
            };
            defer allocator.free(bg_result.stdout);
            defer allocator.free(bg_result.stderr);
            if (bg_result.stderr.len > 0) {
                printCleanError("tailscale", bg_result.stderr);
            }

            const tun = try allocator.create(Tunnel);
            tun.* = .{
                .process = null,
                .provider = provider,
                .allocator = allocator,
            };

            // Get URL from `tailscale serve status` (config is now applied)
            if (getTailscaleStatusUrl(allocator)) |url| {
                const len = @min(url.len, tun.public_url.len);
                @memcpy(tun.public_url[0..len], url[0..len]);
                tun.url_len = len;
                tun.url_ready.set();
                allocator.free(url);
            }

            return tun;
        }

        switch (provider) {
            .tailscale => unreachable,
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
        }

        var process = std.process.Child.init(argv[0..argc], allocator);

        // Put child in its own process group so Ctrl+C (SIGINT) doesn't reach it.
        // We kill it explicitly during shutdown instead.
        process.pgid = 0;

        // Only pipe the stream we parse; ignore the other to prevent deadlock.
        // If the unused pipe fills up, the subprocess blocks forever.
        switch (provider) {
            .cloudflare => {
                process.stderr_behavior = .Pipe;
                process.stdout_behavior = .Ignore;
            },
            .ngrok => {
                process.stdout_behavior = .Pipe;
                process.stderr_behavior = .Ignore;
            },
            .tailscale => unreachable,
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
        if (self.process) |*proc| {
            _ = proc.kill() catch {};
        }

        if (self.reader_thread) |thread| {
            thread.join();
        }

        if (self.process) |*proc| {
            _ = proc.wait() catch {};
        }

        // Reset tailscale serve config (daemon-managed, no subprocess to kill)
        if (self.provider == .tailscale) {
            _ = std.process.Child.run(.{
                .allocator = self.allocator,
                .argv = &.{ "tailscale", "serve", "reset" },
            }) catch {};
        }

        self.allocator.destroy(self);
    }

    /// Reader thread: reads subprocess output line by line, parses URL.
    /// Also prints error/status lines from the tunnel subprocess so the user
    /// can see authentication errors, config issues, etc.
    fn readerThread(self: *Tunnel) void {
        const proc = self.process orelse return;
        const pipe = switch (self.provider) {
            .ngrok => proc.stdout,
            .cloudflare => proc.stderr,
            .tailscale => return, // tailscale uses --bg, no subprocess to read
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
                        if (self.extractUrl(line)) |url| {
                            const len = @min(url.len, self.public_url.len);
                            @memcpy(self.public_url[0..len], url[0..len]);
                            self.url_len = len;
                            self.url_ready.set();
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
    /// Filters out noise (cloudflared INFO spam) and shows errors.
    fn printTunnelLine(self: *Tunnel, line: []const u8) void {
        switch (self.provider) {
            .cloudflare => {
                // Show cloudflared errors, skip verbose INFO lines
                if (std.mem.indexOf(u8, line, "ERR") != null or
                    std.mem.indexOf(u8, line, "error") != null or
                    std.mem.indexOf(u8, line, "failed") != null)
                {
                    std.debug.print("  cloudflared: {s}\n", .{line});
                }
            },
            .ngrok => {
                // ngrok outputs JSON - show first error only (avoids spam from retries)
                if (self.error_shown) return;
                if (std.mem.indexOf(u8, line, "\"lvl\":\"eror\"") != null or
                    std.mem.indexOf(u8, line, "\"lvl\":\"crit\"") != null)
                {
                    self.error_shown = true;
                    // Extract and clean error message from JSON
                    if (extractJsonField(line, "err")) |err_msg| {
                        printCleanError("ngrok", err_msg);
                    } else if (extractJsonField(line, "msg")) |msg| {
                        printCleanError("ngrok", msg);
                    }
                }
            },
            .tailscale => {
                // Tailscale outputs plain text - show everything before URL is found
                std.debug.print("  tailscale: {s}\n", .{line});
            },
        }
    }

    fn extractUrl(self: *Tunnel, line: []const u8) ?[]const u8 {
        return switch (self.provider) {
            .tailscale => extractTailscaleUrl(line),
            .cloudflare => extractCloudflareUrl(line),
            .ngrok => extractNgrokUrl(line),
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

    /// ngrok: parse JSON log line containing "url":"https://..." or "url": "https://..."
    fn extractNgrokUrl(line: []const u8) ?[]const u8 {
        // Find "url" key in JSON (handles optional spaces: "url":"..." or "url": "...")
        const key = "\"url\"";
        const key_pos = std.mem.indexOf(u8, line, key) orelse return null;
        var i = key_pos + key.len;
        // Skip : and optional whitespace
        while (i < line.len and (line[i] == ':' or line[i] == ' ')) : (i += 1) {}
        // Expect opening quote
        if (i >= line.len or line[i] != '"') return null;
        i += 1;
        // Find URL start
        const url_start = i;
        // Find closing quote
        const end = std.mem.indexOfScalar(u8, line[url_start..], '"') orelse return null;
        const url = line[url_start .. url_start + end];
        // Must be https://
        if (!std.mem.startsWith(u8, url, "https://")) return null;
        return url;
    }

    /// Extract a string field value from a JSON line: "key":"value" or "key": "value"
    fn extractJsonField(line: []const u8, key: []const u8) ?[]const u8 {
        // Build search pattern: "key"
        var pattern_buf: [64]u8 = undefined;
        const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\"", .{key}) catch return null;
        const key_pos = std.mem.indexOf(u8, line, pattern) orelse return null;
        var i = key_pos + pattern.len;
        // Skip : and optional whitespace
        while (i < line.len and (line[i] == ':' or line[i] == ' ')) : (i += 1) {}
        // Expect opening quote
        if (i >= line.len or line[i] != '"') return null;
        i += 1;
        const val_start = i;
        // Find closing quote (handle escaped quotes)
        while (i < line.len) : (i += 1) {
            if (line[i] == '"' and (i == val_start or line[i - 1] != '\\')) break;
        }
        if (i >= line.len) return null;
        return line[val_start..i];
    }

    /// Tailscale: look for https:// URL in stderr output
    fn extractTailscaleUrl(line: []const u8) ?[]const u8 {
        const marker = "https://";
        const pos = std.mem.indexOf(u8, line, marker) orelse return null;
        const rest = line[pos..];
        // Stop at whitespace or parenthesis (e.g., "https://host.ts.net (tailnet only)")
        const end = for (rest, 0..) |ch, i| {
            if (ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n' or ch == '(') break i;
        } else rest.len;
        if (end <= marker.len) return null;
        return rest[0..end];
    }
};
