const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");

pub fn main() !void {
    // Ignore SIGPIPE - writing to closed pipe should return error, not kill process
    if (builtin.os.tag != .windows) {
        const act = std.posix.Sigaction{
            .handler = .{ .handler = std.posix.SIG.IGN },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.PIPE, &act, null);
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try cli.run(allocator);
}

test "termweb basic" {
    try std.testing.expect(true);
}
