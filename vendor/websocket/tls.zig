//! TLS 1.3 Implementation for EdgeBox WASM
//!
//! Adapted from metal0's TLS implementation for use with host socket functions.
//! All crypto runs in WASM using Zig's std.crypto.
//!
//! Key features:
//! - TLS 1.3 only (no legacy TLS versions)
//! - AES-128-GCM and AES-256-GCM
//! - X25519 key exchange
//! - SNI (Server Name Indication)
//! - ALPN for protocol negotiation

const std = @import("std");
const crypto = std.crypto;
const host = @import("host.zig");

const wasm_allocator = std.heap.wasm_allocator;

// ============================================================================
// TLS Constants
// ============================================================================

/// TLS 1.3 Record Types
pub const ContentType = enum(u8) {
    invalid = 0,
    change_cipher_spec = 20,
    alert = 21,
    handshake = 22,
    application_data = 23,
    _,
};

/// TLS 1.3 Handshake Types
pub const HandshakeType = enum(u8) {
    client_hello = 1,
    server_hello = 2,
    new_session_ticket = 4,
    end_of_early_data = 5,
    encrypted_extensions = 8,
    certificate = 11,
    certificate_request = 13,
    certificate_verify = 15,
    finished = 20,
    key_update = 24,
    message_hash = 254,
    _,
};

/// Cipher suites (TLS 1.3 only uses AEAD)
pub const CipherSuite = enum(u16) {
    TLS_AES_128_GCM_SHA256 = 0x1301,
    TLS_AES_256_GCM_SHA384 = 0x1302,
    TLS_CHACHA20_POLY1305_SHA256 = 0x1303,
    _,

    pub fn keyLen(self: CipherSuite) usize {
        return switch (self) {
            .TLS_AES_128_GCM_SHA256 => 16,
            .TLS_AES_256_GCM_SHA384 => 32,
            .TLS_CHACHA20_POLY1305_SHA256 => 32,
            _ => 0,
        };
    }

    pub fn ivLen(_: CipherSuite) usize {
        return 12; // All TLS 1.3 suites use 12-byte IV
    }
};

/// ALPN Protocol IDs
pub const ALPN = struct {
    pub const H2: []const u8 = "h2";
    pub const HTTP11: []const u8 = "http/1.1";
};

/// TLS Record Header (5 bytes)
pub const RecordHeader = struct {
    content_type: ContentType,
    legacy_version: u16,
    length: u16,

    pub const SIZE = 5;
    pub const MAX_PAYLOAD = 16384 + 256;

    pub fn parse(data: []const u8) !RecordHeader {
        if (data.len < SIZE) return error.InsufficientData;
        return .{
            .content_type = @enumFromInt(data[0]),
            .legacy_version = (@as(u16, data[1]) << 8) | data[2],
            .length = (@as(u16, data[3]) << 8) | data[4],
        };
    }

    pub fn serialize(self: RecordHeader, out: *[SIZE]u8) void {
        out[0] = @intFromEnum(self.content_type);
        out[1] = @truncate(self.legacy_version >> 8);
        out[2] = @truncate(self.legacy_version);
        out[3] = @truncate(self.length >> 8);
        out[4] = @truncate(self.length);
    }
};

// ============================================================================
// Crypto Primitives
// ============================================================================

/// AES-GCM wrapper using Zig crypto API
pub const AesGcm = struct {
    const Aes128Gcm = crypto.aead.aes_gcm.Aes128Gcm;
    const Aes256Gcm = crypto.aead.aes_gcm.Aes256Gcm;

    key_128: ?[16]u8,
    key_256: ?[32]u8,

    pub fn init128(key: [16]u8) AesGcm {
        return .{ .key_128 = key, .key_256 = null };
    }

    pub fn init256(key: [32]u8) AesGcm {
        return .{ .key_128 = null, .key_256 = key };
    }

    pub fn encrypt(
        self: *const AesGcm,
        nonce: [12]u8,
        plaintext: []const u8,
        aad: []const u8,
        ciphertext: []u8,
        tag: *[16]u8,
    ) void {
        if (self.key_256) |key| {
            Aes256Gcm.encrypt(ciphertext, tag, plaintext, aad, nonce, key);
        } else if (self.key_128) |key| {
            Aes128Gcm.encrypt(ciphertext, tag, plaintext, aad, nonce, key);
        }
    }

    pub fn decrypt(
        self: *const AesGcm,
        nonce: [12]u8,
        ciphertext: []const u8,
        aad: []const u8,
        tag: [16]u8,
        plaintext: []u8,
    ) !void {
        if (self.key_256) |key| {
            Aes256Gcm.decrypt(plaintext, ciphertext, tag, aad, nonce, key) catch return error.AuthenticationFailed;
        } else if (self.key_128) |key| {
            Aes128Gcm.decrypt(plaintext, ciphertext, tag, aad, nonce, key) catch return error.AuthenticationFailed;
        }
    }
};

/// TLS Key Schedule (TLS 1.3 key derivation)
pub const KeySchedule = struct {
    handshake_secret: [32]u8,
    client_handshake_traffic_secret: [32]u8,
    server_handshake_traffic_secret: [32]u8,
    master_secret: [32]u8,
    client_application_traffic_secret: [32]u8,
    server_application_traffic_secret: [32]u8,

    pub fn deriveHandshakeKeys(self: *KeySchedule, shared_secret: [32]u8, transcript_hash: [32]u8) void {
        const HkdfSha256 = crypto.kdf.hkdf.HkdfSha256;

        // Early Secret (HKDF-Extract with zero salt and zero IKM)
        const early_secret = HkdfSha256.extract(&[_]u8{0} ** 32, &[_]u8{0} ** 32);

        // For TLS 1.3, "derived" uses hash of empty string, not empty context
        var empty_hash: [32]u8 = undefined;
        crypto.hash.sha2.Sha256.hash(&[_]u8{}, &empty_hash, .{});

        // Handshake Secret
        var derived: [32]u8 = undefined;
        hkdfExpandLabel(&derived, early_secret, "derived", &empty_hash);
        self.handshake_secret = HkdfSha256.extract(&derived, &shared_secret);

        // Handshake Traffic Secrets (use transcript up to and including ServerHello)
        hkdfExpandLabel(&self.client_handshake_traffic_secret, self.handshake_secret, "c hs traffic", &transcript_hash);
        hkdfExpandLabel(&self.server_handshake_traffic_secret, self.handshake_secret, "s hs traffic", &transcript_hash);

        // Master Secret - derive now, will use later with app traffic secrets
        hkdfExpandLabel(&derived, self.handshake_secret, "derived", &empty_hash);
        self.master_secret = HkdfSha256.extract(&derived, &[_]u8{0} ** 32);
    }

    /// Derive application traffic secrets (call after receiving server Finished)
    pub fn deriveApplicationKeys(self: *KeySchedule, transcript_hash: [32]u8) void {
        // Application Traffic Secrets (use transcript including server's Finished)
        hkdfExpandLabel(&self.client_application_traffic_secret, self.master_secret, "c ap traffic", &transcript_hash);
        hkdfExpandLabel(&self.server_application_traffic_secret, self.master_secret, "s ap traffic", &transcript_hash);
    }

    pub fn deriveTrafficKey(secret: [32]u8, key_len: usize) struct { key: [32]u8, iv: [12]u8 } {
        var key: [32]u8 = undefined;
        var iv: [12]u8 = undefined;

        hkdfExpandLabel(key[0..key_len], secret, "key", &[_]u8{});
        hkdfExpandLabel(&iv, secret, "iv", &[_]u8{});

        return .{ .key = key, .iv = iv };
    }
};

/// HKDF-Expand-Label (RFC 8446)
fn hkdfExpandLabel(out: []u8, secret: [32]u8, label: []const u8, context: []const u8) void {
    const Hkdf = crypto.kdf.hkdf.HkdfSha256;

    var hkdf_label: [512]u8 = undefined;
    var pos: usize = 0;

    // Length (2 bytes)
    hkdf_label[pos] = @truncate(out.len >> 8);
    hkdf_label[pos + 1] = @truncate(out.len);
    pos += 2;

    // Label with "tls13 " prefix
    const full_label_len = 6 + label.len;
    hkdf_label[pos] = @truncate(full_label_len);
    pos += 1;
    @memcpy(hkdf_label[pos .. pos + 6], "tls13 ");
    pos += 6;
    @memcpy(hkdf_label[pos .. pos + label.len], label);
    pos += label.len;

    // Context
    hkdf_label[pos] = @truncate(context.len);
    pos += 1;
    if (context.len > 0) {
        @memcpy(hkdf_label[pos .. pos + context.len], context);
        pos += context.len;
    }

    Hkdf.expand(out, hkdf_label[0..pos], secret);
}

/// X25519 Key Exchange
pub const X25519 = struct {
    private_key: [32]u8,
    public_key: [32]u8,

    pub fn generate() X25519 {
        var private: [32]u8 = undefined;
        crypto.random.bytes(&private);
        return fromPrivate(private);
    }

    pub fn fromPrivate(private: [32]u8) X25519 {
        const public = crypto.dh.X25519.recoverPublicKey(private) catch unreachable;
        return .{
            .private_key = private,
            .public_key = public,
        };
    }

    pub fn sharedSecret(self: X25519, peer_public: [32]u8) ![32]u8 {
        return crypto.dh.X25519.scalarmult(self.private_key, peer_public) catch error.KeyExchangeFailed;
    }
};

// ============================================================================
// TLS Connection (adapted for host socket functions)
// ============================================================================

pub const TlsConnection = struct {
    fd: i32, // Host socket file descriptor

    cipher_suite: CipherSuite,
    key_schedule: KeySchedule,
    client_cipher: ?AesGcm,
    server_cipher: ?AesGcm,
    client_iv: [12]u8,
    server_iv: [12]u8,
    client_seq: u64,
    server_seq: u64,

    transcript_hash: crypto.hash.sha2.Sha256,
    handshake_complete: bool,
    negotiated_alpn: ?[]const u8,

    read_buffer: []u8,
    read_pos: usize,
    read_len: usize,

    pub fn init(fd: i32) !*TlsConnection {
        const conn = try wasm_allocator.create(TlsConnection);
        errdefer wasm_allocator.destroy(conn);

        conn.* = .{
            .fd = fd,
            .cipher_suite = .TLS_AES_128_GCM_SHA256,
            .key_schedule = undefined,
            .client_cipher = null,
            .server_cipher = null,
            .client_iv = undefined,
            .server_iv = undefined,
            .client_seq = 0,
            .server_seq = 0,
            .transcript_hash = crypto.hash.sha2.Sha256.init(.{}),
            .handshake_complete = false,
            .negotiated_alpn = null,
            .read_buffer = try wasm_allocator.alloc(u8, 32768),
            .read_pos = 0,
            .read_len = 0,
        };

        return conn;
    }

    pub fn deinit(self: *TlsConnection) void {
        wasm_allocator.free(self.read_buffer);
        wasm_allocator.destroy(self);
    }

    // === Socket I/O using host functions ===

    fn hostRead(self: *TlsConnection, buffer: []u8) !usize {
        const n = host.netRecv(self.fd, buffer);
        if (n < 0) return error.ReadFailed;
        return @intCast(n);
    }

    fn hostWriteAll(self: *TlsConnection, data: []const u8) !void {
        var written: usize = 0;
        while (written < data.len) {
            const n = host.netSend(self.fd, data[written..]);
            if (n <= 0) return error.WriteFailed;
            written += @intCast(n);
        }
    }

    /// Perform TLS 1.3 handshake with ALPN
    pub fn handshake(self: *TlsConnection, hostname: []const u8, alpn_protocols: []const []const u8) !void {
        const kex = X25519.generate();
        try self.sendClientHello(hostname, &kex.public_key, alpn_protocols);

        const server_public = try self.receiveServerHello();
        const shared = try kex.sharedSecret(server_public);

        // Copy hash state to get transcript up to ServerHello (without resetting)
        var transcript_copy = self.transcript_hash;
        var transcript: [32]u8 = undefined;
        transcript_copy.final(&transcript);

        // Derive handshake keys using transcript up to ServerHello
        self.key_schedule.deriveHandshakeKeys(shared, transcript);

        // Setup handshake ciphers
        const client_keys = KeySchedule.deriveTrafficKey(
            self.key_schedule.client_handshake_traffic_secret,
            self.cipher_suite.keyLen(),
        );
        const server_keys = KeySchedule.deriveTrafficKey(
            self.key_schedule.server_handshake_traffic_secret,
            self.cipher_suite.keyLen(),
        );

        self.client_iv = client_keys.iv;
        self.server_iv = server_keys.iv;

        if (self.cipher_suite.keyLen() == 16) {
            self.client_cipher = AesGcm.init128(client_keys.key[0..16].*);
            self.server_cipher = AesGcm.init128(server_keys.key[0..16].*);
        } else {
            self.client_cipher = AesGcm.init256(client_keys.key);
            self.server_cipher = AesGcm.init256(server_keys.key);
        }

        // Receive server handshake (EncryptedExtensions, Certificate, CertificateVerify, Finished)
        try self.receiveServerHandshake();

        // Now transcript_hash includes up to server's Finished - get final transcript
        transcript_copy = self.transcript_hash;
        transcript_copy.final(&transcript);

        // Derive application keys using transcript including server Finished
        self.key_schedule.deriveApplicationKeys(transcript);

        // Send client finished (using handshake keys)
        try self.sendClientFinished();

        // Switch to application keys
        const app_client = KeySchedule.deriveTrafficKey(
            self.key_schedule.client_application_traffic_secret,
            self.cipher_suite.keyLen(),
        );
        const app_server = KeySchedule.deriveTrafficKey(
            self.key_schedule.server_application_traffic_secret,
            self.cipher_suite.keyLen(),
        );

        self.client_iv = app_client.iv;
        self.server_iv = app_server.iv;

        if (self.cipher_suite.keyLen() == 16) {
            self.client_cipher = AesGcm.init128(app_client.key[0..16].*);
            self.server_cipher = AesGcm.init128(app_server.key[0..16].*);
        } else {
            self.client_cipher = AesGcm.init256(app_client.key);
            self.server_cipher = AesGcm.init256(app_server.key);
        }

        self.client_seq = 0;
        self.server_seq = 0;
        self.handshake_complete = true;
    }

    fn sendClientHello(self: *TlsConnection, hostname: []const u8, public_key: *const [32]u8, alpn_protocols: []const []const u8) !void {
        var msg: [600]u8 = undefined;
        var pos: usize = 0;

        msg[pos] = @intFromEnum(HandshakeType.client_hello);
        pos += 1;

        const len_pos = pos;
        pos += 3;

        // Client version (TLS 1.2 for compatibility, real version in extension)
        msg[pos] = 0x03;
        msg[pos + 1] = 0x03;
        pos += 2;

        // Random (32 bytes)
        crypto.random.bytes(msg[pos .. pos + 32]);
        pos += 32;

        // Session ID (32 random bytes for middlebox compatibility)
        msg[pos] = 32;
        pos += 1;
        crypto.random.bytes(msg[pos .. pos + 32]);
        pos += 32;

        // Cipher suites (TLS_AES_128_GCM_SHA256, TLS_AES_256_GCM_SHA384)
        msg[pos] = 0;
        msg[pos + 1] = 4;
        pos += 2;
        msg[pos] = 0x13;
        msg[pos + 1] = 0x01;
        msg[pos + 2] = 0x13;
        msg[pos + 3] = 0x02;
        pos += 4;

        // Compression (null only)
        msg[pos] = 1;
        msg[pos + 1] = 0;
        pos += 2;

        // Extensions
        const ext_start = pos;
        pos += 2;

        // 1. server_name (SNI)
        msg[pos] = 0x00;
        msg[pos + 1] = 0x00;
        pos += 2;
        const sni_len: u16 = @intCast(hostname.len + 5);
        msg[pos] = @truncate(sni_len >> 8);
        msg[pos + 1] = @truncate(sni_len);
        pos += 2;
        msg[pos] = @truncate((sni_len - 2) >> 8);
        msg[pos + 1] = @truncate(sni_len - 2);
        pos += 2;
        msg[pos] = 0; // host_name type
        pos += 1;
        msg[pos] = @truncate(hostname.len >> 8);
        msg[pos + 1] = @truncate(hostname.len);
        pos += 2;
        @memcpy(msg[pos .. pos + hostname.len], hostname);
        pos += hostname.len;

        // 2. supported_versions (TLS 1.3 only)
        msg[pos] = 0x00;
        msg[pos + 1] = 0x2b;
        pos += 2;
        msg[pos] = 0x00;
        msg[pos + 1] = 0x03;
        pos += 2;
        msg[pos] = 0x02;
        msg[pos + 1] = 0x03;
        msg[pos + 2] = 0x04; // TLS 1.3
        pos += 3;

        // 3. signature_algorithms
        msg[pos] = 0x00;
        msg[pos + 1] = 0x0d;
        pos += 2;
        msg[pos] = 0x00;
        msg[pos + 1] = 0x08;
        pos += 2;
        msg[pos] = 0x00;
        msg[pos + 1] = 0x06;
        pos += 2;
        // ecdsa_secp256r1_sha256, rsa_pss_rsae_sha256, rsa_pkcs1_sha256
        msg[pos] = 0x04;
        msg[pos + 1] = 0x03;
        msg[pos + 2] = 0x08;
        msg[pos + 3] = 0x04;
        msg[pos + 4] = 0x04;
        msg[pos + 5] = 0x01;
        pos += 6;

        // 4. supported_groups
        msg[pos] = 0x00;
        msg[pos + 1] = 0x0a;
        pos += 2;
        msg[pos] = 0x00;
        msg[pos + 1] = 0x04;
        pos += 2;
        msg[pos] = 0x00;
        msg[pos + 1] = 0x02;
        pos += 2;
        msg[pos] = 0x00;
        msg[pos + 1] = 0x1d; // x25519
        pos += 2;

        // 5. key_share (x25519)
        msg[pos] = 0x00;
        msg[pos + 1] = 0x33;
        pos += 2;
        msg[pos] = 0x00;
        msg[pos + 1] = 0x26;
        pos += 2;
        msg[pos] = 0x00;
        msg[pos + 1] = 0x24;
        pos += 2;
        msg[pos] = 0x00;
        msg[pos + 1] = 0x1d;
        pos += 2;
        msg[pos] = 0x00;
        msg[pos + 1] = 0x20;
        pos += 2;
        @memcpy(msg[pos .. pos + 32], public_key);
        pos += 32;

        // 6. ALPN (if provided)
        if (alpn_protocols.len > 0) {
            msg[pos] = 0x00;
            msg[pos + 1] = 0x10;
            pos += 2;

            var alpn_total: usize = 0;
            for (alpn_protocols) |proto| {
                alpn_total += 1 + proto.len;
            }

            msg[pos] = @truncate((alpn_total + 2) >> 8);
            msg[pos + 1] = @truncate(alpn_total + 2);
            pos += 2;
            msg[pos] = @truncate(alpn_total >> 8);
            msg[pos + 1] = @truncate(alpn_total);
            pos += 2;

            for (alpn_protocols) |proto| {
                msg[pos] = @truncate(proto.len);
                pos += 1;
                @memcpy(msg[pos .. pos + proto.len], proto);
                pos += proto.len;
            }
        }

        // Set extensions length
        const ext_len = pos - ext_start - 2;
        msg[ext_start] = @truncate(ext_len >> 8);
        msg[ext_start + 1] = @truncate(ext_len);

        // Set handshake length
        const hs_len = pos - len_pos - 3;
        msg[len_pos] = @truncate(hs_len >> 16);
        msg[len_pos + 1] = @truncate(hs_len >> 8);
        msg[len_pos + 2] = @truncate(hs_len);

        // Update transcript
        self.transcript_hash.update(msg[0..pos]);

        // Send record
        try self.sendRecord(.handshake, msg[0..pos]);
    }

    fn receiveServerHello(self: *TlsConnection) ![32]u8 {
        const record = try self.receiveRecord();

        if (record.content_type != .handshake) return error.UnexpectedRecord;
        if (record.payload.len < 4) return error.InsufficientData;
        if (record.payload[0] != @intFromEnum(HandshakeType.server_hello)) return error.UnexpectedMessage;

        // Update transcript with full handshake message
        self.transcript_hash.update(record.payload);

        // Parse ServerHello to extract key_share
        var offset: usize = 4 + 2 + 32 + 1; // type(1) + len(3) + version(2) + random(32) + session_id_len(1)
        if (offset >= record.payload.len) return error.InvalidServerHello;

        const session_id_len = record.payload[offset - 1];
        offset += session_id_len;

        if (offset + 3 >= record.payload.len) return error.InvalidServerHello;

        // Parse cipher suite
        const cipher_suite_val = (@as(u16, record.payload[offset]) << 8) | record.payload[offset + 1];
        self.cipher_suite = std.meta.intToEnum(CipherSuite, cipher_suite_val) catch .TLS_AES_128_GCM_SHA256;
        offset += 2;

        // Skip compression
        offset += 1;

        // Parse extensions to find key_share
        if (offset + 2 > record.payload.len) return error.InvalidServerHello;
        const ext_len = (@as(usize, record.payload[offset]) << 8) | record.payload[offset + 1];
        offset += 2;

        const ext_end = offset + ext_len;
        var server_public: [32]u8 = undefined;
        var found_key_share = false;

        while (offset + 4 <= ext_end) {
            const ext_type = (@as(u16, record.payload[offset]) << 8) | record.payload[offset + 1];
            const ext_size = (@as(usize, record.payload[offset + 2]) << 8) | record.payload[offset + 3];
            offset += 4;

            if (ext_type == 0x0033 and ext_size >= 36) { // key_share
                // Skip group (2) + key_len (2)
                if (offset + 4 + 32 <= record.payload.len) {
                    @memcpy(&server_public, record.payload[offset + 4 .. offset + 4 + 32]);
                    found_key_share = true;
                }
            }
            offset += ext_size;
        }

        if (!found_key_share) return error.MissingKeyShare;
        return server_public;
    }

    fn receiveServerHandshake(self: *TlsConnection) !void {
        // Receive and process encrypted handshake messages until Finished
        while (true) {
            const record = try self.receiveEncryptedRecord();
            defer if (record.allocated) wasm_allocator.free(@constCast(record.payload));

            if (record.content_type != .handshake) {
                if (record.content_type == .change_cipher_spec) continue;
                return error.UnexpectedRecord;
            }

            // Update transcript
            self.transcript_hash.update(record.payload);

            if (record.payload.len == 0) continue;
            const msg_type: HandshakeType = @enumFromInt(record.payload[0]);

            switch (msg_type) {
                .encrypted_extensions => continue,
                .certificate => continue,
                .certificate_verify => continue,
                .finished => break, // Server finished - we're done receiving
                else => continue,
            }
        }
    }

    fn sendClientFinished(self: *TlsConnection) !void {
        var finished_key: [32]u8 = undefined;
        hkdfExpandLabel(&finished_key, self.key_schedule.client_handshake_traffic_secret, "finished", &[_]u8{});

        var transcript: [32]u8 = undefined;
        self.transcript_hash.final(&transcript);

        var verify_data: [32]u8 = undefined;
        crypto.auth.hmac.sha2.HmacSha256.create(&verify_data, &transcript, &finished_key);

        var msg: [36]u8 = undefined;
        msg[0] = @intFromEnum(HandshakeType.finished);
        msg[1] = 0;
        msg[2] = 0;
        msg[3] = 32;
        @memcpy(msg[4..36], &verify_data);

        try self.sendEncryptedRecord(.handshake, &msg);
    }

    fn sendRecord(self: *TlsConnection, content_type: ContentType, data: []const u8) !void {
        var header: [RecordHeader.SIZE]u8 = undefined;
        const rec = RecordHeader{
            .content_type = content_type,
            .legacy_version = 0x0301,
            .length = @intCast(data.len),
        };
        rec.serialize(&header);

        try self.hostWriteAll(&header);
        try self.hostWriteAll(data);
    }

    fn sendEncryptedRecord(self: *TlsConnection, content_type: ContentType, data: []const u8) !void {
        const cipher = self.client_cipher orelse return error.NotEncrypted;

        var nonce = self.client_iv;
        const seq_bytes = std.mem.toBytes(std.mem.nativeToBig(u64, self.client_seq));
        for (0..8) |i| {
            nonce[4 + i] ^= seq_bytes[i];
        }
        self.client_seq += 1;

        const plaintext = try wasm_allocator.alloc(u8, data.len + 1);
        defer wasm_allocator.free(plaintext);
        @memcpy(plaintext[0..data.len], data);
        plaintext[data.len] = @intFromEnum(content_type);

        const ciphertext = try wasm_allocator.alloc(u8, plaintext.len);
        defer wasm_allocator.free(ciphertext);
        var tag: [16]u8 = undefined;

        // TLS 1.3 AAD is the record header
        const total_len = plaintext.len + 16;
        var aad: [5]u8 = undefined;
        aad[0] = 0x17; // application_data
        aad[1] = 0x03;
        aad[2] = 0x03;
        aad[3] = @truncate(total_len >> 8);
        aad[4] = @truncate(total_len);

        cipher.encrypt(nonce, plaintext, &aad, ciphertext, &tag);

        var header: [RecordHeader.SIZE]u8 = undefined;
        const rec = RecordHeader{
            .content_type = .application_data,
            .legacy_version = 0x0303,
            .length = @intCast(total_len),
        };
        rec.serialize(&header);

        try self.hostWriteAll(&header);
        try self.hostWriteAll(ciphertext);
        try self.hostWriteAll(&tag);
    }

    fn receiveRecord(self: *TlsConnection) !struct { content_type: ContentType, payload: []const u8 } {
        try self.ensureData(RecordHeader.SIZE);

        const header = try RecordHeader.parse(self.read_buffer[self.read_pos..]);
        self.read_pos += RecordHeader.SIZE;

        try self.ensureData(header.length);

        const payload = self.read_buffer[self.read_pos .. self.read_pos + header.length];
        self.read_pos += header.length;

        return .{ .content_type = header.content_type, .payload = payload };
    }

    fn receiveEncryptedRecord(self: *TlsConnection) !struct { content_type: ContentType, payload: []const u8, allocated: bool } {
        const record = try self.receiveRecord();

        if (record.content_type != .application_data) {
            return .{ .content_type = record.content_type, .payload = record.payload, .allocated = false };
        }

        const cipher = self.server_cipher orelse return error.NotEncrypted;

        if (record.payload.len < 17) return error.RecordTooShort;

        var nonce = self.server_iv;
        const seq_bytes = std.mem.toBytes(std.mem.nativeToBig(u64, self.server_seq));
        for (0..8) |i| {
            nonce[4 + i] ^= seq_bytes[i];
        }
        self.server_seq += 1;

        const ciphertext = record.payload[0 .. record.payload.len - 16];
        const tag = record.payload[record.payload.len - 16 ..][0..16].*;

        const plaintext = try wasm_allocator.alloc(u8, ciphertext.len);
        errdefer wasm_allocator.free(plaintext);

        var aad: [5]u8 = undefined;
        aad[0] = 0x17;
        aad[1] = 0x03;
        aad[2] = 0x03;
        aad[3] = @truncate(record.payload.len >> 8);
        aad[4] = @truncate(record.payload.len);

        try cipher.decrypt(nonce, ciphertext, &aad, tag, plaintext);

        var end = plaintext.len;
        while (end > 0 and plaintext[end - 1] == 0) {
            end -= 1;
        }
        if (end == 0) return error.InvalidRecord;

        const inner_type: ContentType = @enumFromInt(plaintext[end - 1]);

        const result = try wasm_allocator.alloc(u8, end - 1);
        @memcpy(result, plaintext[0 .. end - 1]);
        wasm_allocator.free(plaintext);

        return .{ .content_type = inner_type, .payload = result, .allocated = true };
    }

    fn ensureData(self: *TlsConnection, needed: usize) !void {
        while (self.read_len - self.read_pos < needed) {
            if (self.read_pos > 0) {
                const remaining = self.read_len - self.read_pos;
                std.mem.copyForwards(u8, self.read_buffer[0..remaining], self.read_buffer[self.read_pos..self.read_len]);
                self.read_len = remaining;
                self.read_pos = 0;
            }

            const n = try self.hostRead(self.read_buffer[self.read_len..]);
            if (n == 0) return error.ConnectionClosed;
            self.read_len += n;
        }
    }

    // === Public API ===

    pub fn send(self: *TlsConnection, data: []const u8) !void {
        try self.sendEncryptedRecord(.application_data, data);
    }

    pub fn recv(self: *TlsConnection, buffer: []u8) !usize {
        while (true) {
            const record = try self.receiveEncryptedRecord();
            defer if (record.allocated) wasm_allocator.free(@constCast(record.payload));

            switch (record.content_type) {
                .application_data => {
                    const len = @min(buffer.len, record.payload.len);
                    @memcpy(buffer[0..len], record.payload[0..len]);
                    return len;
                },
                .handshake => {
                    // Skip post-handshake messages like NewSessionTicket
                    if (record.payload.len > 0 and record.payload[0] == @intFromEnum(HandshakeType.new_session_ticket)) {
                        continue;
                    }
                    return error.UnexpectedRecord;
                },
                .alert => {
                    if (record.payload.len >= 2) {
                        if (record.payload[0] == 2) return error.FatalAlert;
                        if (record.payload[1] == 0) return error.CloseNotify;
                    }
                    return error.Alert;
                },
                else => continue,
            }
        }
    }
};
