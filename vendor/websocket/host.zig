//! Minimal Host Imports for EdgeBox ABI
//!
//! These are the ONLY functions the host needs to provide.
//! All complex logic (HTTP parsing, crypto, etc.) runs in WASM.
//!
//! Design principle: Host provides raw I/O primitives only.
//! - No parsing
//! - No validation
//! - No complex logic
//! - Just raw bytes in/out
//!
//! Total: ~12 host functions (down from 30+)

const std = @import("std");

// ============================================================================
// Random Bytes (required for crypto)
// ============================================================================

/// Fill buffer with cryptographically secure random bytes.
/// This is the ONLY crypto operation the host needs to provide.
/// All hash/hmac/etc. operations run in WASM using std.crypto.
extern "edgebox_host" fn host_random_get(ptr: [*]u8, len: u32) void;

/// Wrapper for Zig code to call
pub fn randomGet(buf: []u8) void {
    host_random_get(buf.ptr, @intCast(buf.len));
}

// ============================================================================
// Network I/O (raw sockets)
// ============================================================================

/// TCP connect to host:port, returns fd or -1 on error.
/// Host does NOT parse the address - WASM does DNS/URL parsing.
extern "edgebox_host" fn host_net_connect(host_ptr: [*]const u8, host_len: u32, port: u16) i32;

/// Send raw bytes to socket, returns bytes sent or -1.
/// Host does NOT know about HTTP - just raw bytes.
extern "edgebox_host" fn host_net_send(fd: i32, ptr: [*]const u8, len: u32) i32;

/// Receive raw bytes from socket, returns bytes received or -1.
/// Host does NOT parse HTTP responses - just raw bytes.
extern "edgebox_host" fn host_net_recv(fd: i32, ptr: [*]u8, len: u32) i32;

/// Close socket.
extern "edgebox_host" fn host_net_close(fd: i32) void;

/// Wrappers for Zig code
pub fn netConnect(host: []const u8, port: u16) i32 {
    return host_net_connect(host.ptr, @intCast(host.len), port);
}

pub fn netSend(fd: i32, data: []const u8) i32 {
    return host_net_send(fd, data.ptr, @intCast(data.len));
}

pub fn netRecv(fd: i32, buf: []u8) i32 {
    return host_net_recv(fd, buf.ptr, @intCast(buf.len));
}

pub fn netClose(fd: i32) void {
    host_net_close(fd);
}

// ============================================================================
// Process Spawning (raw fd operations)
// ============================================================================

/// Spawn a process, returns pid or -1.
/// stdin/stdout/stderr fds are written to the provided pointers.
/// Host does NOT parse arguments - WASM builds the command line.
extern "edgebox_host" fn host_proc_spawn(
    cmd_ptr: [*]const u8,
    cmd_len: u32,
    stdin_fd: *i32,
    stdout_fd: *i32,
    stderr_fd: *i32,
) i32;

/// Wait for process to exit, returns exit code.
extern "edgebox_host" fn host_proc_wait(pid: i32) i32;

/// Wait for process with timeout (ms). Returns exit code, or -2 if killed due to timeout.
extern "edgebox_host" fn host_proc_wait_timeout(pid: i32, timeout_ms: u32) i32;

/// Kill a process.
extern "edgebox_host" fn host_proc_kill(pid: i32, signal: i32) i32;

/// Wrappers
pub const SpawnResult = struct {
    pid: i32,
    stdin_fd: i32,
    stdout_fd: i32,
    stderr_fd: i32,
};

pub fn procSpawn(cmd: []const u8) ?SpawnResult {
    var result: SpawnResult = undefined;
    result.pid = host_proc_spawn(
        cmd.ptr,
        @intCast(cmd.len),
        &result.stdin_fd,
        &result.stdout_fd,
        &result.stderr_fd,
    );
    if (result.pid < 0) return null;
    return result;
}

pub fn procWait(pid: i32) i32 {
    return host_proc_wait(pid);
}

pub fn procWaitTimeout(pid: i32, timeout_ms: u32) i32 {
    return host_proc_wait_timeout(pid, timeout_ms);
}

pub fn procKill(pid: i32, signal: i32) i32 {
    return host_proc_kill(pid, signal);
}

// ============================================================================
// Filesystem (raw fd operations)
// ============================================================================

/// Open flags
pub const O_RDONLY: u32 = 0;
pub const O_WRONLY: u32 = 1;
pub const O_RDWR: u32 = 2;
pub const O_CREAT: u32 = 0x40;
pub const O_TRUNC: u32 = 0x200;
pub const O_APPEND: u32 = 0x400;

/// Open file, returns fd or -1.
/// Host does NOT validate paths - WASM does path validation.
extern "edgebox_host" fn host_fs_open(path_ptr: [*]const u8, path_len: u32, flags: u32) i32;

/// Read from fd, returns bytes read or -1.
extern "edgebox_host" fn host_fs_read(fd: i32, buf: [*]u8, len: u32) i32;

/// Write to fd, returns bytes written or -1.
extern "edgebox_host" fn host_fs_write(fd: i32, buf: [*]const u8, len: u32) i32;

/// Close fd.
extern "edgebox_host" fn host_fs_close(fd: i32) void;

/// Stat file, writes stat info to buffer, returns 0 or -1.
/// Buffer format: [size:u64][mtime:i64][mode:u32][is_dir:u8]
extern "edgebox_host" fn host_fs_stat(path_ptr: [*]const u8, path_len: u32, stat_buf: [*]u8) i32;

/// Read directory entries, returns count or -1.
/// Writes null-separated names to buffer.
extern "edgebox_host" fn host_fs_readdir(path_ptr: [*]const u8, path_len: u32, buf: [*]u8, buf_len: u32) i32;

/// Wrappers
pub fn fsOpen(path: []const u8, flags: u32) i32 {
    return host_fs_open(path.ptr, @intCast(path.len), flags);
}

pub fn fsRead(fd: i32, buf: []u8) i32 {
    return host_fs_read(fd, buf.ptr, @intCast(buf.len));
}

pub fn fsWrite(fd: i32, data: []const u8) i32 {
    return host_fs_write(fd, data.ptr, @intCast(data.len));
}

pub fn fsClose(fd: i32) void {
    host_fs_close(fd);
}

pub const FileStat = struct {
    size: u64,
    mtime: i64,
    mode: u32,
    is_dir: bool,
};

pub fn fsStat(path: []const u8) ?FileStat {
    var buf: [21]u8 = undefined; // u64 + i64 + u32 + u8
    if (host_fs_stat(path.ptr, @intCast(path.len), &buf) < 0) return null;
    return FileStat{
        .size = std.mem.readInt(u64, buf[0..8], .little),
        .mtime = std.mem.readInt(i64, buf[8..16], .little),
        .mode = std.mem.readInt(u32, buf[16..20], .little),
        .is_dir = buf[20] != 0,
    };
}

pub fn fsReaddir(path: []const u8, buf: []u8) i32 {
    return host_fs_readdir(path.ptr, @intCast(path.len), buf.ptr, @intCast(buf.len));
}

// ============================================================================
// Time (optional, can use WASI)
// ============================================================================

/// Get current time in milliseconds since epoch.
extern "edgebox_host" fn host_time_now() i64;

pub fn timeNow() i64 {
    return host_time_now();
}

// ============================================================================
// Summary: Total Host Functions = 13
// ============================================================================
//
// Random:     host_random_get
// Network:    host_net_connect, host_net_send, host_net_recv, host_net_close
// Process:    host_proc_spawn, host_proc_wait, host_proc_kill
// Filesystem: host_fs_open, host_fs_read, host_fs_write, host_fs_close, host_fs_stat, host_fs_readdir
// Time:       host_time_now
//
// Everything else (HTTP parsing, crypto hash/hmac, URL parsing, JSON, etc.)
// runs in WASM using Zig standard library.
