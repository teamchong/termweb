const std = @import("std");

pub const Key = union(enum) {
    char: u8,
    escape,
    ctrl_c,
    up,
    down,
    left,
    right,
    enter,
    none, // No key pressed (non-blocking)
};

pub const InputReader = struct {
    fd: std.posix.fd_t,
    buffer: [16]u8,

    pub fn init(fd: std.posix.fd_t) InputReader {
        return .{
            .fd = fd,
            .buffer = undefined,
        };
    }

    /// Read next key (non-blocking)
    pub fn readKey(self: *InputReader) !Key {
        const n = std.posix.read(self.fd, &self.buffer) catch |err| {
            if (err == error.WouldBlock) return .none;
            return err;
        };

        if (n == 0) return .none;

        const c = self.buffer[0];

        // Handle single-byte keys
        switch (c) {
            3 => return .ctrl_c, // Ctrl+C
            27 => {
                // Escape or escape sequence
                if (n == 1) return .escape;

                // Parse escape sequences
                if (n >= 3 and self.buffer[1] == '[') {
                    return switch (self.buffer[2]) {
                        'A' => .up,
                        'B' => .down,
                        'C' => .right,
                        'D' => .left,
                        else => .{ .char = c },
                    };
                }
                return .escape;
            },
            '\r', '\n' => return .enter,
            else => return .{ .char = c },
        }
    }
};
