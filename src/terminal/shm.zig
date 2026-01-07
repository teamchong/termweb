/// POSIX Shared Memory for zero-copy Kitty graphics transfer
/// Uses t=s (shared memory) instead of t=d (direct data) for faster rendering
const std = @import("std");

const c = @cImport({
    @cInclude("sys/mman.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

pub const ShmBuffer = struct {
    name: [32]u8,
    name_len: usize,
    fd: c_int,
    ptr: [*]u8,
    size: usize,

    /// Create a new shared memory buffer
    pub fn init(size: usize) !ShmBuffer {
        // Generate unique name: /tw-<pid>-<random>
        var name: [32]u8 = undefined;
        const pid: u32 = @intCast(c.getpid());
        const timestamp: i128 = std.time.nanoTimestamp();
        var prng = std.Random.DefaultPrng.init(@truncate(@as(u128, @bitCast(timestamp))));
        const rand = prng.random().int(u32);
        const name_slice = std.fmt.bufPrint(&name, "/tw-{d}-{x}", .{ pid, rand }) catch return error.NameTooLong;
        const name_len = name_slice.len;
        name[name_len] = 0; // null terminate for C

        // Create shared memory
        const fd = c.shm_open(
            @ptrCast(&name),
            c.O_CREAT | c.O_RDWR,
            @as(c.mode_t, 0o600),
        );
        if (fd < 0) return error.ShmOpenFailed;
        errdefer _ = c.close(fd);

        // Set size
        if (c.ftruncate(fd, @intCast(size)) < 0) {
            return error.FtruncateFailed;
        }

        // Map memory
        const result = c.mmap(
            null,
            size,
            c.PROT_READ | c.PROT_WRITE,
            c.MAP_SHARED,
            fd,
            0,
        );
        if (result == c.MAP_FAILED) return error.MmapFailed;

        return ShmBuffer{
            .name = name,
            .name_len = name_len,
            .fd = fd,
            .ptr = @ptrCast(result),
            .size = size,
        };
    }

    /// Get the SHM name for Kitty (full path including leading /)
    pub fn getName(self: *const ShmBuffer) []const u8 {
        return self.name[0..self.name_len];
    }

    /// Write RGBA data to the buffer
    pub fn write(self: *ShmBuffer, data: []const u8) void {
        const copy_len = @min(data.len, self.size);
        @memcpy(self.ptr[0..copy_len], data[0..copy_len]);
        // Ensure data is visible to other processes (Kitty/Ghostty)
        _ = c.msync(self.ptr, copy_len, c.MS_SYNC);
    }

    /// Get a slice to write directly
    pub fn slice(self: *ShmBuffer) []u8 {
        return self.ptr[0..self.size];
    }

    /// Cleanup
    pub fn deinit(self: *ShmBuffer) void {
        _ = c.munmap(self.ptr, self.size);
        _ = c.close(self.fd);
        var name_z: [32]u8 = undefined;
        @memcpy(name_z[0..self.name_len], self.name[0..self.name_len]);
        name_z[self.name_len] = 0;
        _ = c.shm_unlink(@ptrCast(&name_z));
    }
};

test "ShmBuffer basic" {
    var buf = try ShmBuffer.init(1024);
    defer buf.deinit();

    const data = "hello world";
    buf.write(data);

    const s = buf.slice();
    try std.testing.expectEqualStrings(data, s[0..data.len]);
}
