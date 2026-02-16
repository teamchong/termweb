//! Authentication and authorization system for terminal sharing.
//!
//! Provides role-based access control for shared terminal sessions:
//! - Admin: Full access, can manage sessions and create share links
//! - Editor: Can interact with terminal (input, resize)
//! - Viewer: Read-only access (can only view terminal output)
//!
//! Token model:
//! - Each session has ONE permanent token (256-bit random) and a server-side role.
//! - The permanent token doubles as the HMAC-SHA256 signing key for JWTs.
//! - JWTs contain only session_id + expiry; role is looked up server-side.
//! - Two token types: permanent (identity) and short-lived JWT (proof of auth).
//!
//! Features:
//! - 256-bit entropy permanent tokens (as secure as SSH private keys)
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

/// Token length: 32 bytes (256-bit entropy)
pub const token_len = 32;

/// Hex-encoded token length: 64 chars
pub const token_hex_len = token_len * 2;

pub const Role = enum(u8) {
    admin = 0,    // Full access, can manage sessions and tokens
    editor = 1,   // Can interact with terminal
    viewer = 2,   // Read-only access
    none = 255,   // No access
};


// Share Link


pub const ShareLink = struct {
    token: [token_len]u8,  // 256-bit random token
    role: Role,
    created_at: i64,
    expires_at: ?i64,      // null = never expires
    use_count: u32,
    max_uses: ?u32,        // null = unlimited
    label: ?[]const u8,    // Optional description

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

    /// Single permanent token (256-bit). Doubles as HMAC-SHA256 key for JWTs.
    token: [token_len]u8,

    /// Role granted to users authenticating with this session's token.
    role: Role,

    /// OAuth provider that created this session (null = manual/token-based).
    provider: ?[]const u8 = null,

    /// OAuth provider's user ID (e.g., GitHub user ID, Google sub claim).
    provider_user_id: ?[]const u8 = null,
};

/// OAuth provider configuration (client credentials for GitHub/Google).
pub const OAuthProvider = struct {
    client_id: []const u8,
    client_secret: []const u8,
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

    // OAuth provider configurations (null = not configured)
    github_oauth: ?OAuthProvider = null,
    google_oauth: ?OAuthProvider = null,

    /// Default role assigned to new OAuth users.
    oauth_default_role: Role = .editor,

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
            .github_oauth = null,
            .google_oauth = null,
            .oauth_default_role = .editor,
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
            // No existing state, create default session with editor role
            try state.createSession("default", "Default", .editor);
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
            if (entry.value_ptr.provider) |p| self.allocator.free(p);
            if (entry.value_ptr.provider_user_id) |p| self.allocator.free(p);
        }
        self.sessions.deinit(self.allocator);

        if (self.github_oauth) |oauth| {
            self.allocator.free(oauth.client_id);
            self.allocator.free(oauth.client_secret);
        }
        if (self.google_oauth) |oauth| {
            self.allocator.free(oauth.client_id);
            self.allocator.free(oauth.client_secret);
        }

        self.allocator.free(self.config_path);
        self.allocator.destroy(self);
    }

    
    // Session Management
    

    pub fn createSession(self: *AuthState, id: []const u8, name: []const u8, role: Role) !void {
        const session = Session{
            .id = try self.allocator.dupe(u8, id),
            .name = try self.allocator.dupe(u8, name),
            .created_at = std.time.timestamp(),
            .token = generateToken(),
            .role = role,
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
            if (entry.value.provider) |p| self.allocator.free(p);
            if (entry.value.provider_user_id) |p| self.allocator.free(p);
            try self.save();
        }
    }

    pub fn getSession(self: *AuthState, id: []const u8) ?*Session {
        return self.sessions.getPtr(id);
    }

    /// Find the first session matching a given role.
    /// Used when a share link (which has no session_id) needs a session for JWT exchange.
    pub fn getSessionByRole(self: *AuthState, role: Role) ?*Session {
        var iter = self.sessions.valueIterator();
        while (iter.next()) |session| {
            if (session.role == role) return session;
        }
        return null;
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


    // OAuth Provider Management


    /// Set or update an OAuth provider's credentials.
    pub fn setOAuthProvider(self: *AuthState, provider: []const u8, client_id: []const u8, client_secret: []const u8) !void {
        const new_id = try self.allocator.dupe(u8, client_id);
        errdefer self.allocator.free(new_id);
        const new_secret = try self.allocator.dupe(u8, client_secret);
        errdefer self.allocator.free(new_secret);

        const oauth = OAuthProvider{ .client_id = new_id, .client_secret = new_secret };

        if (std.mem.eql(u8, provider, "github")) {
            if (self.github_oauth) |old| {
                self.allocator.free(old.client_id);
                self.allocator.free(old.client_secret);
            }
            self.github_oauth = oauth;
        } else if (std.mem.eql(u8, provider, "google")) {
            if (self.google_oauth) |old| {
                self.allocator.free(old.client_id);
                self.allocator.free(old.client_secret);
            }
            self.google_oauth = oauth;
        } else {
            self.allocator.free(new_id);
            self.allocator.free(new_secret);
            return;
        }

        try self.save();
    }

    /// Remove an OAuth provider's credentials.
    pub fn removeOAuthProvider(self: *AuthState, provider: []const u8) !void {
        if (std.mem.eql(u8, provider, "github")) {
            if (self.github_oauth) |old| {
                self.allocator.free(old.client_id);
                self.allocator.free(old.client_secret);
                self.github_oauth = null;
            }
        } else if (std.mem.eql(u8, provider, "google")) {
            if (self.google_oauth) |old| {
                self.allocator.free(old.client_id);
                self.allocator.free(old.client_secret);
                self.google_oauth = null;
            }
        }
        try self.save();
    }

    /// Find an existing session for an OAuth user, or create one.
    /// Returns the session's permanent token as hex for JWT creation.
    pub fn findOrCreateOAuthSession(
        self: *AuthState,
        provider: []const u8,
        provider_user_id: []const u8,
        display_name: []const u8,
    ) !*Session {
        // Look for existing session with matching provider + provider_user_id
        var iter = self.sessions.valueIterator();
        while (iter.next()) |session| {
            if (session.provider) |p| {
                if (session.provider_user_id) |puid| {
                    if (std.mem.eql(u8, p, provider) and std.mem.eql(u8, puid, provider_user_id)) {
                        return session;
                    }
                }
            }
        }

        // Create new session for this OAuth user
        const session_id = try std.fmt.allocPrint(self.allocator, "oauth-{s}-{s}", .{ provider, provider_user_id });
        errdefer self.allocator.free(session_id);
        const session_name = try self.allocator.dupe(u8, display_name);
        errdefer self.allocator.free(session_name);
        const prov_dup = try self.allocator.dupe(u8, provider);
        errdefer self.allocator.free(prov_dup);
        const puid_dup = try self.allocator.dupe(u8, provider_user_id);
        errdefer self.allocator.free(puid_dup);

        const session = Session{
            .id = session_id,
            .name = session_name,
            .created_at = std.time.timestamp(),
            .token = generateToken(),
            .role = self.oauth_default_role,
            .provider = prov_dup,
            .provider_user_id = puid_dup,
        };

        const key = try self.allocator.dupe(u8, session_id);
        try self.sessions.put(self.allocator, key, session);
        try self.save();

        return self.sessions.getPtr(session_id).?;
    }


    // Token Management


    /// Generate a 256-bit random token. Used as both identity and HMAC key.
    pub fn generateToken() [token_len]u8 {
        var token: [token_len]u8 = undefined;
        crypto.random.bytes(&token);
        return token;
    }

    /// Result of token validation: the authenticated role and optional session id.
    pub const TokenValidation = struct {
        role: Role,
        session_id: ?[]const u8,
    };

    /// Validate a token (permanent or JWT). Returns the role and session_id if valid.
    /// For permanent tokens, the incoming bytes are hex-decoded and compared constant-time.
    /// For JWTs, two-pass validation: parse session_id, look up key, verify signature.
    pub fn validateToken(self: *AuthState, token: []const u8) TokenValidation {
        if (token.len == 0) return .{ .role = .none, .session_id = null };

        // JWT detection: starts with "eyJ" (base64url of '{"')
        if (token.len > 10 and std.mem.startsWith(u8, token, "eyJ")) {
            if (self.validateJwt(token)) |result| {
                return result;
            }
            return .{ .role = .none, .session_id = null };
        }

        // Hex-decode the incoming token for comparison
        var decoded: [token_len]u8 = undefined;
        const decoded_ok = if (token.len == token_hex_len) blk: {
            for (0..token_len) |i| {
                const hi = hexVal(token[i * 2]) orelse break :blk false;
                const lo = hexVal(token[i * 2 + 1]) orelse break :blk false;
                decoded[i] = (@as(u8, hi) << 4) | @as(u8, lo);
            }
            break :blk true;
        } else false;

        if (decoded_ok) {
            // Check session tokens (constant-time)
            var iter = self.sessions.valueIterator();
            while (iter.next()) |session| {
                if (constantTimeEql(&decoded, &session.token)) {
                    return .{ .role = session.role, .session_id = session.id };
                }
            }

            // Check share links (constant-time)
            for (self.share_links.items) |*link| {
                if (constantTimeEql(&decoded, &link.token) and link.isValid()) {
                    link.use_count += 1;
                    return .{ .role = link.role, .session_id = null };
                }
            }
        }

        return .{ .role = .none, .session_id = null };
    }

    /// Create a JWT for a session. Signed with the session's permanent token.
    /// Payload: {"s":"<session_id>","exp":<timestamp>} — no role (looked up server-side).
    pub fn createJwt(_: *AuthState, session: *const Session, buf: *[256]u8) []const u8 {
        return createJwtWithKey(&session.token, session.id, buf);
    }

    /// Validate a JWT using two-pass validation:
    /// 1. Parse payload (untrusted) to extract session_id
    /// 2. Look up session → get signing key
    /// 3. Verify HMAC-SHA256 signature
    /// 4. Check expiry
    /// Returns TokenValidation with role from session (server-side) if valid.
    pub fn validateJwt(self: *AuthState, token: []const u8) ?TokenValidation {
        // Split on dots: header.payload.signature
        const first_dot = std.mem.indexOfScalar(u8, token, '.') orelse return null;
        const rest = token[first_dot + 1 ..];
        const second_dot_rel = std.mem.indexOfScalar(u8, rest, '.') orelse return null;
        const second_dot = first_dot + 1 + second_dot_rel;

        const header_payload = token[0..second_dot];
        const sig_b64 = token[second_dot + 1 ..];

        // Pass 1: Decode payload to extract session_id (untrusted at this point)
        const payload_b64 = token[first_dot + 1 .. second_dot];
        var payload_buf: [128]u8 = undefined;
        const payload_len = b64url.Decoder.calcSizeForSlice(payload_b64) catch return null;
        b64url.Decoder.decode(payload_buf[0..payload_len], payload_b64) catch return null;
        const payload = payload_buf[0..payload_len];

        // Extract session_id from payload
        const session_id = extractJsonString(payload, "\"s\":\"") orelse return null;

        // Look up session to get signing key
        const session = self.sessions.getPtr(session_id) orelse return null;

        // Pass 2: Verify signature using session's permanent token as HMAC key
        var expected_mac: [HmacSha256.mac_length]u8 = undefined;
        HmacSha256.create(&expected_mac, header_payload, &session.token);

        // Decode provided signature
        if (sig_b64.len == 0 or sig_b64.len > 44) return null;
        const sig_decoded_len = b64url.Decoder.calcSizeForSlice(sig_b64) catch return null;
        if (sig_decoded_len != HmacSha256.mac_length) return null;
        var decoded_sig: [HmacSha256.mac_length]u8 = undefined;
        b64url.Decoder.decode(&decoded_sig, sig_b64) catch return null;

        // Constant-time comparison
        if (!constantTimeEql(&expected_mac, &decoded_sig)) return null;

        // Check expiry
        const claims = parseJwtClaims(payload) orelse return null;
        const now = std.time.timestamp();
        if (now > claims.exp) return null;

        return .{ .role = session.role, .session_id = session.id };
    }

    pub fn regenerateSessionToken(self: *AuthState, session_id: []const u8) !void {
        if (self.sessions.getPtr(session_id)) |session| {
            session.token = generateToken();
            try self.save();
        }
    }

    
    // Share Links
    

    pub fn createShareLink(self: *AuthState, role: Role, expires_in_secs: ?i64, max_uses: ?u32, label: ?[]const u8) !*const [token_len]u8 {
        const now = std.time.timestamp();
        const link = ShareLink{
            .token = generateToken(),
            .role = role,
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

    /// Revoke a share link by hex-encoded token.
    pub fn revokeShareLink(self: *AuthState, token_hex: []const u8) !void {
        if (token_hex.len != token_hex_len) return;
        var decoded: [token_len]u8 = undefined;
        for (0..token_len) |i| {
            const hi = hexVal(token_hex[i * 2]) orelse return;
            const lo = hexVal(token_hex[i * 2 + 1]) orelse return;
            decoded[i] = (@as(u8, hi) << 4) | @as(u8, lo);
        }
        for (self.share_links.items, 0..) |link, i| {
            if (constantTimeEql(&decoded, &link.token)) {
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
    

    /// Write bytes as hex string to a file.
    fn writeHex(file: fs.File, bytes: []const u8) !void {
        var hex_buf: [2]u8 = undefined;
        for (bytes) |b| {
            _ = std.fmt.bufPrint(&hex_buf, "{x:0>2}", .{b}) catch continue;
            try file.writeAll(&hex_buf);
        }
    }

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
            try writeHex(file, &hash);
            try file.writeAll("\",\n");
        }

        // sessions
        try file.writeAll("  \"sessions\": [\n");
        var first = true;
        var iter = self.sessions.valueIterator();
        while (iter.next()) |session| {
            if (!first) try file.writeAll(",\n");
            first = false;

            // Write session JSON with token as hex (64 chars) and role as u8
            try file.writeAll("    {\"id\": \"");
            try file.writeAll(session.id);
            try file.writeAll("\", \"name\": \"");
            try file.writeAll(session.name);
            const created_str = std.fmt.bufPrint(&buf, "\", \"created_at\": {}, \"token\": \"", .{session.created_at}) catch continue;
            try file.writeAll(created_str);
            try writeHex(file, &session.token);
            const role_str = std.fmt.bufPrint(&buf, "\", \"role\": {}", .{@intFromEnum(session.role)}) catch continue;
            try file.writeAll(role_str);
            if (session.provider) |prov| {
                try file.writeAll(", \"provider\": \"");
                try file.writeAll(prov);
                try file.writeAll("\"");
            }
            if (session.provider_user_id) |puid| {
                try file.writeAll(", \"provider_user_id\": \"");
                try file.writeAll(puid);
                try file.writeAll("\"");
            }
            try file.writeAll("}");
        }
        try file.writeAll("\n  ],\n");

        // share_links
        try file.writeAll("  \"share_links\": [\n");
        first = true;
        for (self.share_links.items) |link| {
            if (!first) try file.writeAll(",\n");
            first = false;

            try file.writeAll("    {\"token\": \"");
            try writeHex(file, &link.token);
            const link_str = std.fmt.bufPrint(&buf, "\", \"role\": {}, \"created_at\": {}, \"use_count\": {}", .{
                @intFromEnum(link.role),
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

        // oauth_providers
        try file.writeAll("  \"oauth\": {\n");
        inline for (.{ .{ "github", self.github_oauth }, .{ "google", self.google_oauth } }) |pair| {
            if (pair[1]) |oauth| {
                try file.writeAll("    \"" ++ pair[0] ++ "\": {\"client_id\": \"");
                try file.writeAll(oauth.client_id);
                try file.writeAll("\", \"client_secret\": \"");
                try file.writeAll(oauth.client_secret);
                try file.writeAll("\"},\n");
            }
        }
        const role_str2 = std.fmt.bufPrint(&buf, "    \"default_role\": {}\n", .{@intFromEnum(self.oauth_default_role)}) catch "    \"default_role\": 1\n";
        try file.writeAll(role_str2);
        try file.writeAll("  },\n");

        // passkey_credentials
        try file.writeAll("  \"passkey_credentials\": [\n");
        first = true;
        for (self.passkey_credentials.items) |cred| {
            if (!first) try file.writeAll(",\n");
            first = false;

            try file.writeAll("    {\"id\": \"");
            try writeHex(file, cred.id);
            try file.writeAll("\", \"public_key\": \"");
            try writeHex(file, cred.public_key);
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

        // Detect old format (has editor_token) — incompatible, start fresh
        if (std.mem.indexOf(u8, content, "\"editor_token\"") != null) {
            return error.NoConfig;
        }

        // Parse auth_required
        if (std.mem.indexOf(u8, content, "\"auth_required\": true")) |_| {
            self.auth_required = true;
        }

        // Parse OAuth providers
        if (std.mem.indexOf(u8, content, "\"oauth\":")) |_| {
            self.github_oauth = parseOAuthBlock(self.allocator, content, "github");
            self.google_oauth = parseOAuthBlock(self.allocator, content, "google");
            // default_role
            if (std.mem.indexOf(u8, content, "\"default_role\":")) |dr_pos| {
                const dr_start = dr_pos + 15;
                var dr_end = dr_start;
                while (dr_end < content.len and (content[dr_end] == ' ' or (content[dr_end] >= '0' and content[dr_end] <= '9'))) : (dr_end += 1) {}
                const trimmed = std.mem.trim(u8, content[dr_start..dr_end], " ");
                if (trimmed.len > 0) {
                    const role_byte = trimmed[0] - '0';
                    self.oauth_default_role = switch (role_byte) {
                        0 => .admin,
                        1 => .editor,
                        2 => .viewer,
                        else => .editor,
                    };
                }
            }
        }

        // Parse sessions: look for "token": "<64 hex>" + "role": <u8> within sessions array
        if (std.mem.indexOf(u8, content, "\"sessions\":")) |sessions_start| {
            var pos: usize = sessions_start;
            while (std.mem.indexOfPos(u8, content, pos, "\"id\": \"")) |start| {
                const id_start = start + 7;
                const id_end = std.mem.indexOfPos(u8, content, id_start, "\"") orelse break;
                const id = content[id_start..id_end];

                // Find name
                const name_marker = std.mem.indexOfPos(u8, content, id_end, "\"name\": \"") orelse break;
                const name_start = name_marker + 9;
                const name_end = std.mem.indexOfPos(u8, content, name_start, "\"") orelse break;
                const name = content[name_start..name_end];

                // Find token (64 hex chars)
                const tk_marker = std.mem.indexOfPos(u8, content, name_end, "\"token\": \"") orelse break;
                const tk_start = tk_marker + 10;
                if (tk_start + token_hex_len > content.len) break;

                var session_token: [token_len]u8 = undefined;
                var token_valid = true;
                for (0..token_len) |i| {
                    const hi = hexVal(content[tk_start + i * 2]);
                    const lo = hexVal(content[tk_start + i * 2 + 1]);
                    if (hi != null and lo != null) {
                        session_token[i] = (@as(u8, hi.?) << 4) | @as(u8, lo.?);
                    } else {
                        token_valid = false;
                        break;
                    }
                }
                if (!token_valid) { pos = tk_start + token_hex_len; continue; }

                // Find role
                const role_marker = std.mem.indexOfPos(u8, content, tk_start + token_hex_len, "\"role\": ") orelse break;
                const role_val_start = role_marker + 8;
                const role_byte = if (role_val_start < content.len and content[role_val_start] >= '0' and content[role_val_start] <= '9')
                    content[role_val_start] - '0'
                else
                    break;
                const role: Role = switch (role_byte) {
                    0 => .admin,
                    1 => .editor,
                    2 => .viewer,
                    else => .none,
                };

                // Parse optional provider/provider_user_id fields from the session object
                // Find the closing "}" for this session entry
                const session_end = std.mem.indexOfPos(u8, content, role_val_start, "}") orelse role_val_start + 1;
                const session_slice = content[role_val_start..session_end];

                const prov = if (extractJsonString(session_slice, "\"provider\": \"")) |p|
                    try self.allocator.dupe(u8, p)
                else
                    null;
                const puid = if (extractJsonString(session_slice, "\"provider_user_id\": \"")) |p|
                    try self.allocator.dupe(u8, p)
                else
                    null;

                const session = Session{
                    .id = try self.allocator.dupe(u8, id),
                    .name = try self.allocator.dupe(u8, name),
                    .created_at = std.time.timestamp(),
                    .token = session_token,
                    .role = role,
                    .provider = prov,
                    .provider_user_id = puid,
                };

                const key = try self.allocator.dupe(u8, id);
                try self.sessions.put(self.allocator, key, session);

                pos = role_val_start + 1;
            }
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


pub fn getRoleFromRequest(auth_state: *AuthState, token: ?[]const u8) AuthState.TokenValidation {
    if (token) |t| {
        return auth_state.validateToken(t);
    }
    return .{ .role = .none, .session_id = null };
}

/// Check if a token is a permanent token (64 hex chars) as opposed to a JWT.
pub fn isPermanentToken(token: []const u8) bool {
    if (token.len != token_hex_len) return false;
    for (token) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'))) return false;
    }
    return true;
}

/// Resolve a token to its session ID. Works for both hex-encoded permanent
/// tokens and JWTs (by parsing the payload).
pub fn getSessionIdForToken(auth_state: *AuthState, token: []const u8) ?[]const u8 {
    const result = auth_state.validateToken(token);
    return result.session_id;
}

/// Claims extracted from a JWT payload.
pub const JwtClaims = struct {
    session_id: []const u8, // Points into sid_buf provided by caller
    exp: i64,
};

/// Extract claims from a validated JWT token (without verifying signature).
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

    // Parse expiry
    const basic = parseJwtClaims(payload) orelse return null;

    // Parse session_id
    const sid = extractJsonString(payload, "\"s\":\"") orelse return null;
    if (sid.len <= sid_buf.len) {
        @memcpy(sid_buf[0..sid.len], sid);
        return .{
            .session_id = sid_buf[0..sid.len],
            .exp = basic.exp,
        };
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

/// Parse expiry from JWT payload JSON: {"s":"...","exp":<exp>}
const BasicJwtClaims = struct { exp: i64 };

fn parseJwtClaims(payload: []const u8) ?BasicJwtClaims {
    // Parse "exp":
    if (std.mem.indexOf(u8, payload, "\"exp\":")) |pos| {
        const val_start = pos + 6;
        var end = val_start;
        while (end < payload.len and payload[end] >= '0' and payload[end] <= '9') : (end += 1) {}
        if (end > val_start) {
            const exp = std.fmt.parseInt(i64, payload[val_start..end], 10) catch return null;
            return .{ .exp = exp };
        }
    }
    return null;
}

/// Parse an OAuth provider block from JSON content. Looks for `"<name>": {"client_id": "...", "client_secret": "..."}`.
fn parseOAuthBlock(allocator: Allocator, content: []const u8, name: []const u8) ?OAuthProvider {
    // Build search prefix: "<name>": {"client_id": "
    var prefix_buf: [64]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "\"{s}\": {{\"client_id\": \"", .{name}) catch return null;
    const block_pos = std.mem.indexOf(u8, content, prefix) orelse return null;
    const section = content[block_pos..];
    const raw_id = extractJsonString(section, "\"client_id\": \"") orelse return null;
    const raw_secret = extractJsonString(section, "\"client_secret\": \"") orelse return null;
    const id = allocator.dupe(u8, raw_id) catch return null;
    const secret = allocator.dupe(u8, raw_secret) catch {
        allocator.free(id);
        return null;
    };
    return .{ .client_id = id, .client_secret = secret };
}

/// Extract a JSON string value given a prefix like `"key":"`.
/// Returns the value between the prefix's closing quote and the next quote.
fn extractJsonString(payload: []const u8, prefix: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, payload, prefix)) |pos| {
        const val_start = pos + prefix.len;
        if (std.mem.indexOfPos(u8, payload, val_start, "\"")) |val_end| {
            return payload[val_start..val_end];
        }
    }
    return null;
}

/// Create a JWT signed with an arbitrary key. Used by both AuthState.createJwt
/// and for standalone JWT creation (e.g., for share links).
/// Payload: {"s":"<session_id>","exp":<timestamp>}
pub fn createJwtWithKey(key: *const [token_len]u8, session_id: []const u8, buf: *[256]u8) []const u8 {
    const exp = std.time.timestamp() + jwt_expiry_secs;

    // Build payload JSON: {"s":"<sid>","exp":<exp>}
    var payload_json: [128]u8 = undefined;
    const payload_str = std.fmt.bufPrint(&payload_json, "{{\"s\":\"{s}\",\"exp\":{}}}", .{
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

    // Sign with HMAC-SHA256 using the provided key
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, buf[0..hp_len], key);

    // Base64url encode signature
    const sig_b64_len = b64url.Encoder.calcSize(HmacSha256.mac_length);
    var sig_b64: [44]u8 = undefined;
    _ = b64url.Encoder.encode(sig_b64[0..sig_b64_len], &mac);

    // Append .signature
    buf[hp_len] = '.';
    @memcpy(buf[hp_len + 1 ..][0..sig_b64_len], sig_b64[0..sig_b64_len]);

    return buf[0 .. hp_len + 1 + sig_b64_len];
}

/// Hex-encode a token into a caller-provided buffer.
pub fn hexEncodeToken(out: *[token_hex_len]u8, token: *const [token_len]u8) void {
    const hex_chars = "0123456789abcdef";
    for (0..token_len) |i| {
        out[i * 2] = hex_chars[token[i] >> 4];
        out[i * 2 + 1] = hex_chars[token[i] & 0x0f];
    }
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

/// Helper to create a test AuthState with a session pre-loaded.
fn testStateWithSession(id: []const u8, role: Role, tok: [token_len]u8) AuthState {
    var state = AuthState{
        .admin_password_hash = null,
        .admin_password_salt = null,
        .passkey_credentials = .{},
        .share_links = .{},
        .sessions = .{},
        .auth_required = false,
        .allocator = std.testing.allocator,
        .config_path = "",
    };
    // Insert session directly (no save — no config_path)
    state.sessions.put(std.testing.allocator, @constCast(id), Session{
        .id = @constCast(id),
        .name = @constCast(id),
        .created_at = 0,
        .token = tok,
        .role = role,
    }) catch {};
    return state;
}

test "JWT: createJwt produces valid token" {
    var tok: [token_len]u8 = undefined;
    @memset(&tok, 0x42);
    var state = testStateWithSession("default", .editor, tok);
    defer state.sessions.deinit(std.testing.allocator);

    const session = state.sessions.getPtr("default").?;
    var buf: [256]u8 = undefined;
    const jwt = state.createJwt(session, &buf);

    // Should start with the constant header
    try std.testing.expect(std.mem.startsWith(u8, jwt, jwt_header_encoded));

    // Should have exactly 2 dots
    var dot_count: usize = 0;
    for (jwt) |c| {
        if (c == '.') dot_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), dot_count);

    // Should be validatable — returns editor role from session
    const result = state.validateJwt(jwt);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(Role.editor, result.?.role);
    try std.testing.expectEqualStrings("default", result.?.session_id.?);
}

test "JWT: validateJwt rejects tampered signature" {
    var tok: [token_len]u8 = undefined;
    @memset(&tok, 0x42);
    var state = testStateWithSession("test", .viewer, tok);
    defer state.sessions.deinit(std.testing.allocator);

    const session = state.sessions.getPtr("test").?;
    var buf: [256]u8 = undefined;
    const jwt = state.createJwt(session, &buf);

    // Tamper with the last character of the signature
    var tampered: [256]u8 = undefined;
    @memcpy(tampered[0..jwt.len], jwt);
    tampered[jwt.len - 1] = if (jwt[jwt.len - 1] == 'A') 'B' else 'A';

    const result = state.validateJwt(tampered[0..jwt.len]);
    try std.testing.expect(result == null);
}

test "JWT: validateJwt rejects JWT signed with different session token" {
    var tok1: [token_len]u8 = undefined;
    @memset(&tok1, 0x42);
    var tok2: [token_len]u8 = undefined;
    @memset(&tok2, 0x99);

    // Create JWT with session A's token
    const session_a = Session{
        .id = @constCast("default"),
        .name = @constCast("Default"),
        .created_at = 0,
        .token = tok1,
        .role = .admin,
    };
    var buf: [256]u8 = undefined;
    const jwt = createJwtWithKey(&session_a.token, session_a.id, &buf);

    // State has session "default" with different token (tok2)
    var state = testStateWithSession("default", .admin, tok2);
    defer state.sessions.deinit(std.testing.allocator);

    // Should reject — signature doesn't match
    try std.testing.expect(state.validateJwt(jwt) == null);
}

test "JWT: validateToken routes JWT vs permanent token" {
    var tok: [token_len]u8 = undefined;
    @memset(&tok, 0x42);
    var state = testStateWithSession("default", .editor, tok);
    defer state.sessions.deinit(std.testing.allocator);

    // JWT should validate
    const session = state.sessions.getPtr("default").?;
    var buf: [256]u8 = undefined;
    const jwt = state.createJwt(session, &buf);
    const jwt_result = state.validateToken(jwt);
    try std.testing.expectEqual(Role.editor, jwt_result.role);

    // Hex-encoded permanent token should validate
    var hex_token: [token_hex_len]u8 = undefined;
    hexEncodeToken(&hex_token, &tok);
    const perm_result = state.validateToken(&hex_token);
    try std.testing.expectEqual(Role.editor, perm_result.role);
    try std.testing.expectEqualStrings("default", perm_result.session_id.?);

    // Random garbage should not
    const bad_result = state.validateToken("not_a_token");
    try std.testing.expectEqual(Role.none, bad_result.role);
}

test "JWT: isPermanentToken detects hex tokens" {
    try std.testing.expect(isPermanentToken("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"));
    try std.testing.expect(!isPermanentToken("eyJhbGciOiJIUzI1NiJ9.payload.sig"));
    try std.testing.expect(!isPermanentToken("abc"));
    try std.testing.expect(!isPermanentToken(""));
    try std.testing.expect(!isPermanentToken("zzzz456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"));
}

test "JWT: getJwtClaims extracts session_id" {
    var tok: [token_len]u8 = undefined;
    @memset(&tok, 0x42);

    var jwt_buf: [256]u8 = undefined;
    const jwt = createJwtWithKey(&tok, "my-session", &jwt_buf);

    var sid_buf: [64]u8 = undefined;
    const claims = getJwtClaims(jwt, &sid_buf);
    try std.testing.expect(claims != null);
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
