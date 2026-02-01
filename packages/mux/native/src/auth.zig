const std = @import("std");
const fs = std.fs;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const crypto = std.crypto;

// ============================================================================
// Access Roles
// ============================================================================

pub const Role = enum(u8) {
    admin = 0,    // Full access, can manage sessions and tokens
    editor = 1,   // Can interact with terminal
    viewer = 2,   // Read-only access
    none = 255,   // No access
};

// ============================================================================
// Token Types
// ============================================================================

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

// ============================================================================
// Share Link
// ============================================================================

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

// ============================================================================
// Session
// ============================================================================

pub const Session = struct {
    id: []const u8,
    name: []const u8,
    created_at: i64,

    // Tokens for this session
    editor_token: [44]u8,
    viewer_token: [44]u8,
};

// ============================================================================
// Auth State
// ============================================================================

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

    // ========================================================================
    // Session Management
    // ========================================================================

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

    // ========================================================================
    // Token Management
    // ========================================================================

    pub fn generateToken(token_type: TokenType) [44]u8 {
        var random_bytes: [32]u8 = undefined;
        crypto.random.bytes(&random_bytes);

        var token: [44]u8 = undefined;
        const prefix = tokenPrefix(token_type);
        @memcpy(token[0..4], prefix);
        _ = std.base64.standard.Encoder.encode(token[4..], &random_bytes);

        return token;
    }

    pub fn validateToken(self: *AuthState, token: []const u8) Role {
        if (token.len < 4) return .none;

        // Check token prefix
        const prefix = token[0..4];

        // Check admin token (if auth not required, no admin token needed)
        if (!self.auth_required) {
            // No auth set up, everyone is admin
            return .admin;
        }

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

        _ = prefix;
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

    // ========================================================================
    // Share Links
    // ========================================================================

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

    // ========================================================================
    // Admin Password
    // ========================================================================

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

    // ========================================================================
    // Passkey (WebAuthn) - simplified storage
    // ========================================================================

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

    // ========================================================================
    // Persistence
    // ========================================================================

    pub fn save(self: *AuthState) !void {
        var file = try fs.createFileAbsolute(self.config_path, .{});
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

// ============================================================================
// Passkey Credential
// ============================================================================

pub const PasskeyCredential = struct {
    id: []const u8,
    public_key: []const u8,
    name: ?[]const u8,
    created_at: i64,
};

// ============================================================================
// Auth Middleware Helper
// ============================================================================

pub fn getRoleFromRequest(auth_state: *AuthState, token: ?[]const u8) Role {
    // If no auth required, everyone is admin
    if (!auth_state.auth_required) {
        return .admin;
    }

    // Check token
    if (token) |t| {
        return auth_state.validateToken(t);
    }

    return .none;
}

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
