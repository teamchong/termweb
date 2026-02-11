//! Authentication and authorization system for terminal sharing.
//!
//! Provides role-based access control for shared terminal sessions:
//! - Admin: Full access, can manage sessions and create share links
//! - Editor: Can interact with terminal (input, resize)
//! - Viewer: Read-only access (can only view terminal output)
//!
//! Features:
//! - Cryptographically secure token generation (32-byte random + base64)
//! - Share links with optional expiration and usage limits
//! - Session management with persistent tokens
//! - Password/passkey authentication for admin access
//! - Per-IP rate limiting for failed auth attempts
//!
const std = @import("std");
const fs = std.fs;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const crypto = std.crypto;
const hashmap_helper = @import("hashmap_helper");

pub const Role = enum(u8) {
    admin = 0,    // Full access, can manage sessions and tokens
    editor = 1,   // Can interact with terminal
    viewer = 2,   // Read-only access
    none = 255,   // No access
};


// Token Types


pub const TokenType = enum(u8) {
    admin = 0,    // Admin token (for admin auth after password/passkey set)
    editor = 1,   // Editor share token
    viewer = 2,   // Viewer share token
};

// Token prefix for identification
fn tokenPrefix(token_type: TokenType) []const u8 {
    return switch (token_type) {
        .admin => "adm_",
        .editor => "edt_",
        .viewer => "vwr_",
    };
}


// Share Link


pub const ShareLink = struct {
    token: [44]u8,        // Base64-encoded 32-byte token
    token_type: TokenType,
    created_at: i64,
    expires_at: ?i64,     // null = never expires
    use_count: u32,
    max_uses: ?u32,       // null = unlimited
    label: ?[]const u8,   // Optional description

    pub fn isValid(self: *const ShareLink) bool {
        // Check expiration
        if (self.expires_at) |exp| {
            const now = std.time.timestamp();
            if (now > exp) return false;
        }
        // Check use count
        if (self.max_uses) |max| {
            if (self.use_count >= max) return false;
        }
        return true;
    }
};


// Session


pub const Session = struct {
    id: []const u8,
    name: []const u8,
    created_at: i64,

    // Tokens for this session
    editor_token: [44]u8,
    viewer_token: [44]u8,
};


// Auth State


pub const AuthState = struct {
    // Admin auth (optional - if not set, first connection is admin)
    admin_password_hash: ?[64]u8,  // Argon2 hash
    admin_password_salt: ?[32]u8,

    // Passkey credentials (WebAuthn) - stored as JSON for simplicity
    passkey_credentials: std.ArrayListUnmanaged(PasskeyCredential),

    // Share links
    share_links: std.ArrayListUnmanaged(ShareLink),

    // Sessions
    sessions: std.StringHashMapUnmanaged(Session),

    // Is auth required? (false until admin sets up password/passkey)
    auth_required: bool,

    allocator: Allocator,
    config_path: []const u8,

    pub fn init(allocator: Allocator) !*AuthState {
        const state = try allocator.create(AuthState);
        errdefer allocator.destroy(state);

        state.* = .{
            .admin_password_hash = null,
            .admin_password_salt = null,
            .passkey_credentials = .{},
            .share_links = .{},
            .sessions = .{},
            .auth_required = false,
            .allocator = allocator,
            .config_path = "",
        };

        // Get config path
        const home = posix.getenv("HOME") orelse "/tmp";
        state.config_path = try std.fmt.allocPrint(allocator, "{s}/.termweb/auth.json", .{home});
        errdefer allocator.free(state.config_path);

        // Ensure directory exists
        const dir_path = try std.fmt.allocPrint(allocator, "{s}/.termweb", .{home});
        defer allocator.free(dir_path);
        fs.makeDirAbsolute(dir_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        // Load existing state
        state.load() catch {
            // No existing state, create default session
            try state.createSession("default", "Default");
        };

        return state;
    }

    pub fn deinit(self: *AuthState) void {
        for (self.passkey_credentials.items) |*cred| {
            self.allocator.free(cred.id);
            self.allocator.free(cred.public_key);
            if (cred.name) |n| self.allocator.free(n);
        }
        self.passkey_credentials.deinit(self.allocator);
        self.share_links.deinit(self.allocator);

        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.id);
            self.allocator.free(entry.value_ptr.name);
        }
        self.sessions.deinit(self.allocator);

        self.allocator.free(self.config_path);
        self.allocator.destroy(self);
    }

    
    // Session Management
    

    pub fn createSession(self: *AuthState, id: []const u8, name: []const u8) !void {
        const session = Session{
            .id = try self.allocator.dupe(u8, id),
            .name = try self.allocator.dupe(u8, name),
            .created_at = std.time.timestamp(),
            .editor_token = generateToken(.editor),
            .viewer_token = generateToken(.viewer),
        };

        const key = try self.allocator.dupe(u8, id);
        try self.sessions.put(self.allocator, key, session);
        try self.save();
    }

    pub fn deleteSession(self: *AuthState, id: []const u8) !void {
        if (self.sessions.fetchRemove(id)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value.id);
            self.allocator.free(entry.value.name);
            try self.save();
        }
    }

    pub fn getSession(self: *AuthState, id: []const u8) ?*Session {
        return self.sessions.getPtr(id);
    }

    pub fn listSessions(self: *AuthState) []Session {
        // Return values as slice
        var list = std.ArrayList(Session).init(self.allocator);
        var iter = self.sessions.valueIterator();
        while (iter.next()) |session| {
            list.append(session.*) catch continue;
        }
        return list.toOwnedSlice() catch &[_]Session{};
    }

    
    // Token Management
    

    pub fn generateToken(token_type: TokenType) [44]u8 {
        // 30 random bytes → 40 base64 chars (no padding)
        // 4 byte prefix + 40 base64 = 44 total
        var random_bytes: [30]u8 = undefined;
        crypto.random.bytes(&random_bytes);

        var token: [44]u8 = undefined;
        const prefix = tokenPrefix(token_type);
        @memcpy(token[0..4], prefix);
        _ = std.base64.standard.Encoder.encode(token[4..], &random_bytes);

        return token;
    }

    pub fn validateToken(self: *AuthState, token: []const u8) Role {
        if (token.len < 4) return .none;

        // Check session tokens
        var iter = self.sessions.valueIterator();
        while (iter.next()) |session| {
            if (std.mem.eql(u8, &session.editor_token, token)) {
                return .editor;
            }
            if (std.mem.eql(u8, &session.viewer_token, token)) {
                return .viewer;
            }
        }

        // Check share links
        for (self.share_links.items) |*link| {
            if (std.mem.eql(u8, &link.token, token) and link.isValid()) {
                link.use_count += 1;
                return switch (link.token_type) {
                    .admin => .admin,
                    .editor => .editor,
                    .viewer => .viewer,
                };
            }
        }

        return .none;
    }

    pub fn regenerateSessionToken(self: *AuthState, session_id: []const u8, token_type: TokenType) !void {
        if (self.sessions.getPtr(session_id)) |session| {
            switch (token_type) {
                .editor => session.editor_token = generateToken(.editor),
                .viewer => session.viewer_token = generateToken(.viewer),
                .admin => {},
            }
            try self.save();
        }
    }

    
    // Share Links
    

    pub fn createShareLink(self: *AuthState, token_type: TokenType, expires_in_secs: ?i64, max_uses: ?u32, label: ?[]const u8) ![]const u8 {
        const now = std.time.timestamp();
        const link = ShareLink{
            .token = generateToken(token_type),
            .token_type = token_type,
            .created_at = now,
            .expires_at = if (expires_in_secs) |secs| now + secs else null,
            .use_count = 0,
            .max_uses = max_uses,
            .label = if (label) |l| try self.allocator.dupe(u8, l) else null,
        };

        try self.share_links.append(self.allocator, link);
        try self.save();

        return &self.share_links.items[self.share_links.items.len - 1].token;
    }

    pub fn revokeShareLink(self: *AuthState, token: []const u8) !void {
        for (self.share_links.items, 0..) |link, i| {
            if (std.mem.eql(u8, &link.token, token)) {
                if (link.label) |l| self.allocator.free(l);
                _ = self.share_links.swapRemove(i);
                try self.save();
                return;
            }
        }
    }

    pub fn revokeAllShareLinks(self: *AuthState) !void {
        for (self.share_links.items) |link| {
            if (link.label) |l| self.allocator.free(l);
        }
        self.share_links.clearRetainingCapacity();
        try self.save();
    }

    
    // Admin Password
    

    pub fn setAdminPassword(self: *AuthState, password: []const u8) !void {
        // Generate salt
        var salt: [32]u8 = undefined;
        crypto.random.bytes(&salt);

        // Hash password using SHA-256 (simple for now, could use Argon2)
        var hash: [32]u8 = undefined;
        var hasher = crypto.hash.sha2.Sha256.init(.{});
        hasher.update(&salt);
        hasher.update(password);
        hasher.final(&hash);

        // Store as 64-byte combined salt+hash
        var combined: [64]u8 = undefined;
        @memcpy(combined[0..32], &salt);
        @memcpy(combined[32..64], &hash);

        self.admin_password_hash = combined;
        self.admin_password_salt = salt;
        self.auth_required = true;

        try self.save();
    }

    pub fn verifyAdminPassword(self: *AuthState, password: []const u8) bool {
        const salt = self.admin_password_salt orelse return false;
        const stored_hash = self.admin_password_hash orelse return false;

        var hash: [32]u8 = undefined;
        var hasher = crypto.hash.sha2.Sha256.init(.{});
        hasher.update(&salt);
        hasher.update(password);
        hasher.final(&hash);

        return std.mem.eql(u8, &hash, stored_hash[32..64]);
    }

    pub fn clearAdminPassword(self: *AuthState) !void {
        self.admin_password_hash = null;
        self.admin_password_salt = null;

        // If no passkeys either, disable auth requirement
        if (self.passkey_credentials.items.len == 0) {
            self.auth_required = false;
        }

        try self.save();
    }

    
    // Passkey (WebAuthn) - simplified storage
    

    pub fn addPasskeyCredential(self: *AuthState, id: []const u8, public_key: []const u8, name: ?[]const u8) !void {
        const cred = PasskeyCredential{
            .id = try self.allocator.dupe(u8, id),
            .public_key = try self.allocator.dupe(u8, public_key),
            .name = if (name) |n| try self.allocator.dupe(u8, n) else null,
            .created_at = std.time.timestamp(),
        };

        try self.passkey_credentials.append(self.allocator, cred);
        self.auth_required = true;
        try self.save();
    }

    pub fn removePasskeyCredential(self: *AuthState, id: []const u8) !void {
        for (self.passkey_credentials.items, 0..) |cred, i| {
            if (std.mem.eql(u8, cred.id, id)) {
                self.allocator.free(cred.id);
                self.allocator.free(cred.public_key);
                if (cred.name) |n| self.allocator.free(n);
                _ = self.passkey_credentials.swapRemove(i);

                // If no passkeys and no password, disable auth
                if (self.passkey_credentials.items.len == 0 and self.admin_password_hash == null) {
                    self.auth_required = false;
                }

                try self.save();
                return;
            }
        }
    }

    
    // Persistence
    

    pub fn save(self: *AuthState) !void {
        var file = try fs.createFileAbsolute(self.config_path, .{ .mode = 0o600 });
        defer file.close();

        // Write JSON directly to file
        try file.writeAll("{\n");

        // auth_required
        var buf: [256]u8 = undefined;
        const auth_str = std.fmt.bufPrint(&buf, "  \"auth_required\": {},\n", .{self.auth_required}) catch return;
        try file.writeAll(auth_str);

        // admin_password_hash
        if (self.admin_password_hash) |hash| {
            try file.writeAll("  \"admin_password_hash\": \"");
            var hex_buf: [2]u8 = undefined;
            for (hash) |b| {
                _ = std.fmt.bufPrint(&hex_buf, "{x:0>2}", .{b}) catch continue;
                try file.writeAll(&hex_buf);
            }
            try file.writeAll("\",\n");
        }

        // sessions
        try file.writeAll("  \"sessions\": [\n");
        var first = true;
        var iter = self.sessions.valueIterator();
        while (iter.next()) |session| {
            if (!first) try file.writeAll(",\n");
            first = false;

            // Write session JSON
            try file.writeAll("    {\"id\": \"");
            try file.writeAll(session.id);
            try file.writeAll("\", \"name\": \"");
            try file.writeAll(session.name);
            const created_str = std.fmt.bufPrint(&buf, "\", \"created_at\": {}, \"editor_token\": \"", .{session.created_at}) catch continue;
            try file.writeAll(created_str);
            try file.writeAll(&session.editor_token);
            try file.writeAll("\", \"viewer_token\": \"");
            try file.writeAll(&session.viewer_token);
            try file.writeAll("\"}");
        }
        try file.writeAll("\n  ],\n");

        // share_links
        try file.writeAll("  \"share_links\": [\n");
        first = true;
        for (self.share_links.items) |link| {
            if (!first) try file.writeAll(",\n");
            first = false;

            try file.writeAll("    {\"token\": \"");
            try file.writeAll(&link.token);
            const link_str = std.fmt.bufPrint(&buf, "\", \"type\": {}, \"created_at\": {}, \"use_count\": {}", .{
                @intFromEnum(link.token_type),
                link.created_at,
                link.use_count,
            }) catch continue;
            try file.writeAll(link_str);

            if (link.expires_at) |exp| {
                const exp_str = std.fmt.bufPrint(&buf, ", \"expires_at\": {}", .{exp}) catch continue;
                try file.writeAll(exp_str);
            }
            if (link.max_uses) |max| {
                const max_str = std.fmt.bufPrint(&buf, ", \"max_uses\": {}", .{max}) catch continue;
                try file.writeAll(max_str);
            }
            if (link.label) |l| {
                try file.writeAll(", \"label\": \"");
                try file.writeAll(l);
                try file.writeAll("\"");
            }
            try file.writeAll("}");
        }
        try file.writeAll("\n  ],\n");

        // passkey_credentials
        try file.writeAll("  \"passkey_credentials\": [\n");
        first = true;
        for (self.passkey_credentials.items) |cred| {
            if (!first) try file.writeAll(",\n");
            first = false;

            try file.writeAll("    {\"id\": \"");
            var hex_buf2: [2]u8 = undefined;
            for (cred.id) |b| {
                _ = std.fmt.bufPrint(&hex_buf2, "{x:0>2}", .{b}) catch continue;
                try file.writeAll(&hex_buf2);
            }
            try file.writeAll("\", \"public_key\": \"");
            for (cred.public_key) |b| {
                _ = std.fmt.bufPrint(&hex_buf2, "{x:0>2}", .{b}) catch continue;
                try file.writeAll(&hex_buf2);
            }
            try file.writeAll("\"");
            if (cred.name) |n| {
                try file.writeAll(", \"name\": \"");
                try file.writeAll(n);
                try file.writeAll("\"");
            }
            const created_at_str = std.fmt.bufPrint(&buf, ", \"created_at\": {}}}", .{cred.created_at}) catch continue;
            try file.writeAll(created_at_str);
        }
        try file.writeAll("\n  ]\n");

        try file.writeAll("}\n");
    }

    pub fn load(self: *AuthState) !void {
        const file = fs.openFileAbsolute(self.config_path, .{}) catch |err| {
            if (err == error.FileNotFound) return error.NoConfig;
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        // Parse JSON (simplified parser)
        // For now, just check if auth_required is true
        if (std.mem.indexOf(u8, content, "\"auth_required\": true")) |_| {
            self.auth_required = true;
        }

        // Parse sessions
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, content, pos, "\"id\": \"")) |start| {
            const id_start = start + 7;
            const id_end = std.mem.indexOfPos(u8, content, id_start, "\"") orelse break;
            const id = content[id_start..id_end];

            // Find name
            const name_marker = std.mem.indexOfPos(u8, content, id_end, "\"name\": \"") orelse break;
            const name_start = name_marker + 9;
            const name_end = std.mem.indexOfPos(u8, content, name_start, "\"") orelse break;
            const name = content[name_start..name_end];

            // Find editor_token
            const et_marker = std.mem.indexOfPos(u8, content, name_end, "\"editor_token\": \"") orelse break;
            const et_start = et_marker + 17;
            const et_end = std.mem.indexOfPos(u8, content, et_start, "\"") orelse break;

            // Find viewer_token
            const vt_marker = std.mem.indexOfPos(u8, content, et_end, "\"viewer_token\": \"") orelse break;
            const vt_start = vt_marker + 17;
            const vt_end = std.mem.indexOfPos(u8, content, vt_start, "\"") orelse break;

            // Create session
            var editor_token: [44]u8 = undefined;
            var viewer_token: [44]u8 = undefined;
            if (et_end - et_start == 44) @memcpy(&editor_token, content[et_start..et_end]);
            if (vt_end - vt_start == 44) @memcpy(&viewer_token, content[vt_start..vt_end]);

            const session = Session{
                .id = try self.allocator.dupe(u8, id),
                .name = try self.allocator.dupe(u8, name),
                .created_at = std.time.timestamp(),
                .editor_token = editor_token,
                .viewer_token = viewer_token,
            };

            const key = try self.allocator.dupe(u8, id);
            try self.sessions.put(self.allocator, key, session);

            pos = vt_end;
        }
    }
};


// Passkey Credential


pub const PasskeyCredential = struct {
    id: []const u8,
    public_key: []const u8,
    name: ?[]const u8,
    created_at: i64,
};


// Auth Middleware Helper


pub fn getRoleFromRequest(auth_state: *AuthState, token: ?[]const u8) Role {
    // Check token — all connections must authenticate
    if (token) |t| {
        return auth_state.validateToken(t);
    }

    return .none;
}

/// Resolve a token to its session ID. Returns the session ID if the token
/// matches a session's editor or viewer token, or null otherwise.
pub fn getSessionIdForToken(auth_state: *AuthState, token: []const u8) ?[]const u8 {
    if (token.len < 4) return null;
    var iter = auth_state.sessions.valueIterator();
    while (iter.next()) |session| {
        if (std.mem.eql(u8, &session.editor_token, token) or
            std.mem.eql(u8, &session.viewer_token, token))
        {
            return session.id;
        }
    }
    return null;
}

/// Extract token from query string and percent-decode it into the provided buffer.
/// Tokens may be URL-encoded (e.g. %2F for /) when passed through JS encodeURIComponent.
pub fn extractTokenFromQuery(uri: []const u8) ?[]const u8 {
    // Look for ?token= or &token=
    const token_param = "token=";
    if (std.mem.indexOf(u8, uri, token_param)) |pos| {
        const start = pos + token_param.len;
        // Find end (& or end of string)
        var end = start;
        while (end < uri.len and uri[end] != '&' and uri[end] != ' ') : (end += 1) {}
        if (end > start) {
            return uri[start..end];
        }
    }
    return null;
}

/// Percent-decode a token into a caller-provided buffer. Returns the decoded slice.
/// Handles %XX sequences produced by encodeURIComponent (e.g. %2F → /, %2B → +, %3D → =).
pub fn decodeToken(buf: *[64]u8, encoded: []const u8) []const u8 {
    var out: usize = 0;
    var i: usize = 0;
    while (i < encoded.len and out < buf.len) {
        if (encoded[i] == '%' and i + 2 < encoded.len) {
            const hi = hexVal(encoded[i + 1]);
            const lo = hexVal(encoded[i + 2]);
            if (hi != null and lo != null) {
                buf[out] = (@as(u8, hi.?) << 4) | @as(u8, lo.?);
                out += 1;
                i += 3;
                continue;
            }
        }
        buf[out] = encoded[i];
        out += 1;
        i += 1;
    }
    return buf[0..out];
}

/// Percent-encode a token for safe inclusion in URLs.
/// Encodes +, /, = and other non-unreserved characters.
pub fn percentEncodeToken(out: *[192]u8, token: []const u8) []const u8 {
    var o: usize = 0;
    for (token) |c| {
        if (o + 3 > out.len) break;
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => {
                out[o] = c;
                o += 1;
            },
            else => {
                out[o] = '%';
                out[o + 1] = "0123456789ABCDEF"[c >> 4];
                out[o + 2] = "0123456789ABCDEF"[c & 0x0f];
                o += 3;
            },
        }
    }
    return out[0..o];
}

fn hexVal(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => null,
    };
}

/// Per-IP rate limiter for failed authentication attempts.
/// Blocks IPs that exceed max_failures within window_secs.
pub const RateLimiter = struct {
    entries: hashmap_helper.StringHashMap(Entry),
    allocator: Allocator,
    mutex: std.Thread.Mutex = .{},
    last_cleanup: i64 = 0,

    const max_failures: u32 = 10;
    const window_secs: i64 = 300;
    const lockout_secs: i64 = 300;
    const cleanup_interval: i64 = 60;

    const Entry = struct {
        fail_count: u32,
        window_start: i64,
    };

    pub fn init(allocator: Allocator) RateLimiter {
        return .{
            .entries = hashmap_helper.StringHashMap(Entry).init(allocator),
            .allocator = allocator,
            .last_cleanup = std.time.timestamp(),
        };
    }

    pub fn deinit(self: *RateLimiter) void {
        for (self.entries.keys()) |key| {
            self.allocator.free(key);
        }
        self.entries.deinit();
    }

    /// Returns true if the IP is currently blocked.
    pub fn isBlocked(self: *RateLimiter, ip: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();
        const entry = self.entries.getPtr(ip) orelse return false;

        // Lockout expired — clear entry
        if (now - entry.window_start > lockout_secs) {
            self.removeEntryByKey(ip);
            return false;
        }

        return entry.fail_count >= max_failures;
    }

    /// Record a failed auth attempt.
    pub fn recordFailure(self: *RateLimiter, ip: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();

        if (self.entries.getPtr(ip)) |entry| {
            // Window expired — reset
            if (now - entry.window_start > window_secs) {
                entry.* = .{ .fail_count = 1, .window_start = now };
            } else {
                entry.fail_count += 1;
            }
        } else {
            // New entry — dupe the key string
            const key = self.allocator.dupe(u8, ip) catch return;
            self.entries.put(key, .{
                .fail_count = 1,
                .window_start = now,
            }) catch {
                self.allocator.free(key);
            };
        }
    }

    /// Reset failures on successful auth.
    pub fn recordSuccess(self: *RateLimiter, ip: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.removeEntryByKey(ip);
    }

    /// Remove expired entries. Safe to call frequently (self-throttles to once per minute).
    pub fn cleanup(self: *RateLimiter) void {
        const now = std.time.timestamp();
        if (now - self.last_cleanup < cleanup_interval) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        self.last_cleanup = now;

        // Walk backwards to safely remove during iteration
        const keys = self.entries.keys();
        const values = self.entries.values();
        var i: usize = keys.len;
        while (i > 0) {
            i -= 1;
            if (now - values[i].window_start > lockout_secs) {
                self.allocator.free(keys[i]);
                self.entries.swapRemoveAt(i);
            }
        }
    }

    fn removeEntryByKey(self: *RateLimiter, ip: []const u8) void {
        // fetchSwapRemove returns the removed entry so we can free the key
        if (self.entries.fetchSwapRemove(ip)) |removed| {
            self.allocator.free(removed.key);
        }
    }

    // --- Test helpers (not called in production) ---

    /// Directly set an entry's window_start for testing time-dependent behavior.
    fn testSetWindowStart(self: *RateLimiter, ip: []const u8, window_start: i64) void {
        if (self.entries.getPtr(ip)) |entry| {
            entry.window_start = window_start;
        }
    }
};

test "RateLimiter: not blocked before max_failures" {
    var rl = RateLimiter.init(std.testing.allocator);
    defer rl.deinit();

    const ip = "192.168.1.1";

    // Record 9 failures (below threshold of 10)
    for (0..9) |_| {
        rl.recordFailure(ip);
    }
    try std.testing.expect(!rl.isBlocked(ip));
}

test "RateLimiter: blocked after max_failures" {
    var rl = RateLimiter.init(std.testing.allocator);
    defer rl.deinit();

    const ip = "192.168.1.1";

    // Record 10 failures (at threshold)
    for (0..10) |_| {
        rl.recordFailure(ip);
    }
    try std.testing.expect(rl.isBlocked(ip));
}

test "RateLimiter: success resets counter" {
    var rl = RateLimiter.init(std.testing.allocator);
    defer rl.deinit();

    const ip = "10.0.0.1";

    // Trigger lockout
    for (0..10) |_| {
        rl.recordFailure(ip);
    }
    try std.testing.expect(rl.isBlocked(ip));

    // Successful auth resets counter
    rl.recordSuccess(ip);
    try std.testing.expect(!rl.isBlocked(ip));
}

test "RateLimiter: lockout expires after 5 minutes" {
    var rl = RateLimiter.init(std.testing.allocator);
    defer rl.deinit();

    const ip = "172.16.0.1";

    // Trigger lockout
    for (0..10) |_| {
        rl.recordFailure(ip);
    }
    try std.testing.expect(rl.isBlocked(ip));

    // Simulate time passing: set window_start to 301 seconds ago (> lockout_secs=300)
    const now = std.time.timestamp();
    rl.testSetWindowStart(ip, now - 301);

    // Lockout should have expired
    try std.testing.expect(!rl.isBlocked(ip));

    // Entry should have been cleaned up
    try std.testing.expectEqual(@as(usize, 0), rl.entries.count());
}

test "RateLimiter: window expiry resets failure count" {
    var rl = RateLimiter.init(std.testing.allocator);
    defer rl.deinit();

    const ip = "10.0.0.2";

    // Record 9 failures
    for (0..9) |_| {
        rl.recordFailure(ip);
    }
    try std.testing.expect(!rl.isBlocked(ip));

    // Simulate window expiry (> window_secs=300)
    const now = std.time.timestamp();
    rl.testSetWindowStart(ip, now - 301);

    // Next failure should start a fresh window (count resets to 1)
    rl.recordFailure(ip);
    try std.testing.expect(!rl.isBlocked(ip));

    // Verify count was reset to 1 (not 10)
    if (rl.entries.getPtr(ip)) |entry| {
        try std.testing.expectEqual(@as(u32, 1), entry.fail_count);
    } else {
        return error.TestUnexpectedResult;
    }
}

test "RateLimiter: cleanup removes expired entries" {
    var rl = RateLimiter.init(std.testing.allocator);
    defer rl.deinit();

    const ip1 = "10.0.0.1";
    const ip2 = "10.0.0.2";

    // Create entries for two IPs
    for (0..5) |_| {
        rl.recordFailure(ip1);
        rl.recordFailure(ip2);
    }
    try std.testing.expectEqual(@as(usize, 2), rl.entries.count());

    // Expire ip1's entry, keep ip2 fresh
    const now = std.time.timestamp();
    rl.testSetWindowStart(ip1, now - 301);

    // Force cleanup to run (set last_cleanup far in past)
    rl.last_cleanup = now - 61;
    rl.cleanup();

    // ip1 should be cleaned up, ip2 should remain
    try std.testing.expectEqual(@as(usize, 1), rl.entries.count());
    try std.testing.expect(rl.entries.getPtr(ip1) == null);
    try std.testing.expect(rl.entries.getPtr(ip2) != null);
}

test "RateLimiter: independent per-IP tracking" {
    var rl = RateLimiter.init(std.testing.allocator);
    defer rl.deinit();

    const ip1 = "192.168.1.1";
    const ip2 = "192.168.1.2";

    // Lock out ip1
    for (0..10) |_| {
        rl.recordFailure(ip1);
    }
    try std.testing.expect(rl.isBlocked(ip1));

    // ip2 should not be affected
    try std.testing.expect(!rl.isBlocked(ip2));

    // A few failures on ip2 shouldn't lock it out
    for (0..3) |_| {
        rl.recordFailure(ip2);
    }
    try std.testing.expect(!rl.isBlocked(ip2));
}
