const std = @import("std");

pub const PromptBuffer = struct {
    allocator: std.mem.Allocator,
    content: std.ArrayList(u8),
    cursor_pos: usize,

    pub fn init(allocator: std.mem.Allocator) !PromptBuffer {
        return .{
            .allocator = allocator,
            .content = try std.ArrayList(u8).initCapacity(allocator, 0),
            .cursor_pos = 0,
        };
    }

    pub fn deinit(self: *PromptBuffer) void {
        self.content.deinit(self.allocator);
    }

    pub fn insertChar(self: *PromptBuffer, c: u8) !void {
        try self.content.insert(self.allocator, self.cursor_pos, c);
        self.cursor_pos += 1;
    }

    pub fn backspace(self: *PromptBuffer) void {
        if (self.cursor_pos == 0) return;
        _ = self.content.orderedRemove(self.cursor_pos - 1);
        self.cursor_pos -= 1;
    }

    pub fn clear(self: *PromptBuffer) void {
        self.content.clearRetainingCapacity();
        self.cursor_pos = 0;
    }

    pub fn getString(self: *const PromptBuffer) []const u8 {
        return self.content.items;
    }

    pub fn render(self: *const PromptBuffer, writer: anytype, prompt: []const u8) !void {
        try writer.print("{s}{s}", .{ prompt, self.content.items });
    }
};
