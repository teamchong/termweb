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

const HmacSha256 = crypto.auth.hmac.sha2.HmacSha256;
const b64url = std.base64.url_safe_no_pad;

/// Constant JWT header: base64url({"alg":"HS256","typ":"JWT"})
const jwt_header_encoded = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";

/// JWT lifetime: 15 minutes
const jwt_expiry_secs: i64 = 900;

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

    // JWT signing secret (32 bytes, persisted in auth.json)
    jwt_secret: [32]u8,

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
            .jwt_secret = undefined,
            .allocator = allocator,
            .config_path = "",
        };

        // Generate random JWT secret (overwritten by load() if config exists)
        crypto.random.bytes(&state.jwt_secret);

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
        for (self.share_links.items) |link| {
            if (link.label) |l| self.allocator.free(l);
        }
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

        // JWT detection: starts with "eyJ" (base64url of '{"')
        if (token.len > 10 and std.mem.startsWith(u8, token, "eyJ")) {
            return self.validateJwt(token) orelse .none;
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

        return .none;
    }

    /// Create a JWT for the given role and session.
    /// Returns the JWT string written into `buf`.
    pub fn createJwt(self: *AuthState, role: Role, session_id: []const u8, buf: *[256]u8) []const u8 {
        const exp = std.time.timestamp() + jwt_expiry_secs;

        // Build payload JSON: {"r":<role>,"s":"<sid>","exp":<exp>}
        var payload_json: [128]u8 = undefined;
        const payload_str = std.fmt.bufPrint(&payload_json, "{{\"r\":{},\"s\":\"{s}\",\"exp\":{}}}", .{
            @intFromEnum(role),
            session_id,
            exp,
        }) catch return buf[0..0];

        // Base64url encode payload
        const payload_b64_len = b64url.Encoder.calcSize(payload_str.len);
        var payload_b64: [172]u8 = undefined;
        _ = b64url.Encoder.encode(payload_b64[0..payload_b64_len], payload_str);

        // Assemble header.payload
        const hp_len = jwt_header_encoded.len + 1 + payload_b64_len;
        @memcpy(buf[0..jwt_header_encoded.len], jwt_header_encoded);
        buf[jwt_header_encoded.len] = '.';
        @memcpy(buf[jwt_header_encoded.len + 1 ..][0..payload_b64_len], payload_b64[0..payload_b64_len]);

        // Sign with HMAC-SHA256
        var mac: [HmacSha256.mac_length]u8 = undefined;
        HmacSha256.create(&mac, buf[0..hp_len], &self.jwt_secret);

        // Base64url encode signature
        const sig_b64_len = b64url.Encoder.calcSize(HmacSha256.mac_length);
        var sig_b64: [44]u8 = undefined;
        _ = b64url.Encoder.encode(sig_b64[0..sig_b64_len], &mac);

        // Append .signature
        buf[hp_len] = '.';
        @memcpy(buf[hp_len + 1 ..][0..sig_b64_len], sig_b64[0..sig_b64_len]);

        return buf[0 .. hp_len + 1 + sig_b64_len];
    }

    /// Validate a JWT: verify HMAC-SHA256 signature and check expiry.
    /// Returns the role if valid, null if invalid or expired.
    pub fn validateJwt(self: *AuthState, token: []const u8) ?Role {
        // Split on dots: header.payload.signature
        const first_dot = std.mem.indexOfScalar(u8, token, '.') orelse return null;
        const rest = token[first_dot + 1 ..];
        const second_dot_rel = std.mem.indexOfScalar(u8, rest, '.') orelse return null;
        const second_dot = first_dot + 1 + second_dot_rel;

        const header_payload = token[0..second_dot];
        const sig_b64 = token[second_dot + 1 ..];

        // Verify signature
        var expected_mac: [HmacSha256.mac_length]u8 = undefined;
        HmacSha256.create(&expected_mac, header_payload, &self.jwt_secret);

        // Decode provided signature
        if (sig_b64.len == 0 or sig_b64.len > 44) return null;
        const sig_decoded_len = b64url.Decoder.calcSizeForSlice(sig_b64) catch return null;
        if (sig_decoded_len != HmacSha256.mac_length) return null;
        var decoded_sig: [HmacSha256.mac_length]u8 = undefined;
        b64url.Decoder.decode(&decoded_sig, sig_b64) catch return null;

        // Constant-time comparison
        if (!constantTimeEql(&expected_mac, &decoded_sig)) return null;

        // Decode payload
        const payload_b64 = token[first_dot + 1 .. second_dot];
        var payload_buf: [128]u8 = undefined;
        const payload_len = b64url.Decoder.calcSizeForSlice(payload_b64) catch return null;
        b64url.Decoder.decode(payload_buf[0..payload_len], payload_b64) catch return null;

        // Parse claims and check expiry
        const claims = parseJwtClaims(payload_buf[0..payload_len]) orelse return null;
        const now = std.time.timestamp();
        if (now > claims.exp) return null;

        return claims.role;
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

        // jwt_secret (as hex)
        try file.writeAll("  \"jwt_secret\": \"");
        {
            var hex_buf_jwt: [2]u8 = undefined;
            for (self.jwt_secret) |b| {
                _ = std.fmt.bufPrint(&hex_buf_jwt, "{x:0>2}", .{b}) catch continue;
                try file.writeAll(&hex_buf_jwt);
            }
        }
        try file.writeAll("\",\n");

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

        // Parse jwt_secret (64 hex chars → 32 bytes)
        if (std.mem.indexOf(u8, content, "\"jwt_secret\": \"")) |marker| {
            const hex_start = marker + 15;
            if (hex_start + 64 <= content.len) {
                var secret: [32]u8 = undefined;
                var valid = true;
                for (0..32) |i| {
                    const hi = hexVal(content[hex_start + i * 2]);
                    const lo = hexVal(content[hex_start + i * 2 + 1]);
                    if (hi != null and lo != null) {
                        secret[i] = (@as(u8, hi.?) << 4) | @as(u8, lo.?);
                    } else {
                        valid = false;
                        break;
                    }
                }
                if (valid) self.jwt_secret = secret;
            }
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

/// Check if a token is a static token (has role prefix adm_, edt_, vwr_).
pub fn isStaticToken(token: []const u8) bool {
    return token.len > 4 and (std.mem.startsWith(u8, token, "adm_") or
        std.mem.startsWith(u8, token, "edt_") or
        std.mem.startsWith(u8, token, "vwr_"));
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

/// Claims extracted from a JWT payload.
pub const JwtClaims = struct {
    role: Role,
    session_id: []const u8, // Points into sid_buf provided by caller
    exp: i64,
};

/// Extract claims from a validated JWT token.
/// The `sid_buf` holds the session_id string (caller-owned).
pub fn getJwtClaims(token: []const u8, sid_buf: *[64]u8) ?JwtClaims {
    const first_dot = std.mem.indexOfScalar(u8, token, '.') orelse return null;
    const rest = token[first_dot + 1 ..];
    const second_dot_rel = std.mem.indexOfScalar(u8, rest, '.') orelse return null;
    const payload_b64 = token[first_dot + 1 .. first_dot + 1 + second_dot_rel];

    var payload_buf: [128]u8 = undefined;
    const payload_len = b64url.Decoder.calcSizeForSlice(payload_b64) catch return null;
    b64url.Decoder.decode(payload_buf[0..payload_len], payload_b64) catch return null;
    const payload = payload_buf[0..payload_len];

    // Parse role
    const basic = parseJwtClaims(payload) orelse return null;

    // Parse session_id: find "s":"<value>"
    if (std.mem.indexOf(u8, payload, "\"s\":\"")) |pos| {
        const val_start = pos + 5;
        if (std.mem.indexOfPos(u8, payload, val_start, "\"")) |val_end| {
            const sid = payload[val_start..val_end];
            if (sid.len <= sid_buf.len) {
                @memcpy(sid_buf[0..sid.len], sid);
                return .{
                    .role = basic.role,
                    .session_id = sid_buf[0..sid.len],
                    .exp = basic.exp,
                };
            }
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
/// Buffer is 256 bytes to accommodate JWTs (~135 chars).
pub fn decodeToken(buf: *[256]u8, encoded: []const u8) []const u8 {
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

/// Constant-time comparison of two byte slices (timing-safe for HMAC verification).
fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| {
        diff |= x ^ y;
    }
    return diff == 0;
}

/// Parse role and expiry from JWT payload JSON: {"r":<role>,"s":"...","exp":<exp>}
const BasicJwtClaims = struct { role: Role, exp: i64 };

fn parseJwtClaims(payload: []const u8) ?BasicJwtClaims {
    var role: ?Role = null;
    var exp: ?i64 = null;

    // Parse "r":
    if (std.mem.indexOf(u8, payload, "\"r\":")) |pos| {
        const val_start = pos + 4;
        if (val_start < payload.len and payload[val_start] >= '0' and payload[val_start] <= '9') {
            role = switch (payload[val_start] - '0') {
                0 => .admin,
                1 => .editor,
                2 => .viewer,
                else => null,
            };
        }
    }

    // Parse "exp":
    if (std.mem.indexOf(u8, payload, "\"exp\":")) |pos| {
        const val_start = pos + 6;
        var end = val_start;
        while (end < payload.len and payload[end] >= '0' and payload[end] <= '9') : (end += 1) {}
        if (end > val_start) {
            exp = std.fmt.parseInt(i64, payload[val_start..end], 10) catch null;
        }
    }

    if (role != null and exp != null) {
        return .{ .role = role.?, .exp = exp.? };
    }
    return null;
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

// --- JWT Tests ---

test "JWT: createJwt produces valid token" {
    // Create a minimal AuthState-like struct for testing
    var secret: [32]u8 = undefined;
    @memset(&secret, 0x42);

    // We need a full AuthState for createJwt — use a test helper
    var state = AuthState{
        .admin_password_hash = null,
        .admin_password_salt = null,
        .passkey_credentials = .{},
        .share_links = .{},
        .sessions = .{},
        .auth_required = false,
        .jwt_secret = secret,
        .allocator = std.testing.allocator,
        .config_path = "",
    };

    var buf: [256]u8 = undefined;
    const jwt = state.createJwt(.editor, "default", &buf);

    // Should start with the constant header
    try std.testing.expect(std.mem.startsWith(u8, jwt, jwt_header_encoded));

    // Should have exactly 2 dots
    var dot_count: usize = 0;
    for (jwt) |c| {
        if (c == '.') dot_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), dot_count);

    // Should be validatable
    const role = state.validateJwt(jwt);
    try std.testing.expect(role != null);
    try std.testing.expectEqual(Role.editor, role.?);
}

test "JWT: validateJwt rejects tampered signature" {
    var secret: [32]u8 = undefined;
    @memset(&secret, 0x42);

    var state = AuthState{
        .admin_password_hash = null,
        .admin_password_salt = null,
        .passkey_credentials = .{},
        .share_links = .{},
        .sessions = .{},
        .auth_required = false,
        .jwt_secret = secret,
        .allocator = std.testing.allocator,
        .config_path = "",
    };

    var buf: [256]u8 = undefined;
    const jwt = state.createJwt(.viewer, "test", &buf);

    // Tamper with the last character of the signature
    var tampered: [256]u8 = undefined;
    @memcpy(tampered[0..jwt.len], jwt);
    tampered[jwt.len - 1] = if (jwt[jwt.len - 1] == 'A') 'B' else 'A';

    const role = state.validateJwt(tampered[0..jwt.len]);
    try std.testing.expect(role == null);
}

test "JWT: validateJwt rejects wrong secret" {
    var secret1: [32]u8 = undefined;
    @memset(&secret1, 0x42);
    var secret2: [32]u8 = undefined;
    @memset(&secret2, 0x99);

    var state1 = AuthState{
        .admin_password_hash = null,
        .admin_password_salt = null,
        .passkey_credentials = .{},
        .share_links = .{},
        .sessions = .{},
        .auth_required = false,
        .jwt_secret = secret1,
        .allocator = std.testing.allocator,
        .config_path = "",
    };

    var state2 = state1;
    state2.jwt_secret = secret2;

    var buf: [256]u8 = undefined;
    const jwt = state1.createJwt(.admin, "default", &buf);

    // Different secret should reject
    try std.testing.expect(state2.validateJwt(jwt) == null);
}

test "JWT: validateToken routes JWT vs static" {
    var secret: [32]u8 = undefined;
    @memset(&secret, 0x42);

    var state = AuthState{
        .admin_password_hash = null,
        .admin_password_salt = null,
        .passkey_credentials = .{},
        .share_links = .{},
        .sessions = .{},
        .auth_required = false,
        .jwt_secret = secret,
        .allocator = std.testing.allocator,
        .config_path = "",
    };

    var buf: [256]u8 = undefined;
    const jwt = state.createJwt(.editor, "default", &buf);

    // JWT should validate
    try std.testing.expectEqual(Role.editor, state.validateToken(jwt));

    // Random garbage should not
    try std.testing.expectEqual(Role.none, state.validateToken("not_a_token"));
}

test "JWT: isStaticToken detects prefixes" {
    try std.testing.expect(isStaticToken("adm_abc123"));
    try std.testing.expect(isStaticToken("edt_abc123"));
    try std.testing.expect(isStaticToken("vwr_abc123"));
    try std.testing.expect(!isStaticToken("eyJhbGciOiJIUzI1NiJ9.payload.sig"));
    try std.testing.expect(!isStaticToken("abc"));
    try std.testing.expect(!isStaticToken(""));
}

test "JWT: getJwtClaims extracts session_id" {
    var secret: [32]u8 = undefined;
    @memset(&secret, 0x42);

    var state = AuthState{
        .admin_password_hash = null,
        .admin_password_salt = null,
        .passkey_credentials = .{},
        .share_links = .{},
        .sessions = .{},
        .auth_required = false,
        .jwt_secret = secret,
        .allocator = std.testing.allocator,
        .config_path = "",
    };

    var jwt_buf: [256]u8 = undefined;
    const jwt = state.createJwt(.viewer, "my-session", &jwt_buf);

    var sid_buf: [64]u8 = undefined;
    const claims = getJwtClaims(jwt, &sid_buf);
    try std.testing.expect(claims != null);
    try std.testing.expectEqual(Role.viewer, claims.?.role);
    try std.testing.expectEqualStrings("my-session", claims.?.session_id);
    try std.testing.expect(claims.?.exp > std.time.timestamp());
}

test "JWT: constantTimeEql" {
    const a = [_]u8{ 1, 2, 3, 4 };
    const b = [_]u8{ 1, 2, 3, 4 };
    const c = [_]u8{ 1, 2, 3, 5 };
    try std.testing.expect(constantTimeEql(&a, &b));
    try std.testing.expect(!constantTimeEql(&a, &c));
}
