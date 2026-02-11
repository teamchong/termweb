/// Browser dialog handling for JavaScript dialogs and file chooser
///
/// Provides:
/// - DialogState for managing alert/confirm/prompt dialogs
/// - renderDialog for terminal overlay rendering
/// - Native file picker integration for macOS and Linux
const std = @import("std");
const builtin = @import("builtin");

pub const DialogType = enum {
    alert,
    confirm,
    prompt,
    beforeunload,
    file_chooser,
};

pub const FilePickerMode = enum {
    single,
    multiple,
    folder,
    save, // Save file dialog
};

pub const DialogState = struct {
    allocator: std.mem.Allocator,
    dialog_type: DialogType,
    message: []const u8,
    default_text: []const u8,
    input_buffer: std.ArrayList(u8),
    cursor_pos: usize,

    pub fn init(allocator: std.mem.Allocator, dtype: DialogType, msg: []const u8, default: []const u8) !DialogState {
        var input_buffer = try std.ArrayList(u8).initCapacity(allocator, 256);

        // Pre-fill with default text for prompt dialogs
        if (dtype == .prompt and default.len > 0) {
            try input_buffer.appendSlice(allocator, default);
        }

        return DialogState{
            .allocator = allocator,
            .dialog_type = dtype,
            .message = msg,
            .default_text = default,
            .input_buffer = input_buffer,
            .cursor_pos = if (dtype == .prompt) default.len else 0,
        };
    }

    pub fn deinit(self: *DialogState) void {
        self.input_buffer.deinit(self.allocator);
    }

    pub fn handleChar(self: *DialogState, c: u8) void {
        if (c < 32 or c > 126) return; // Only printable ASCII

        // Insert at cursor position
        if (self.cursor_pos >= self.input_buffer.items.len) {
            self.input_buffer.append(self.allocator, c) catch return;
        } else {
            self.input_buffer.insert(self.allocator, self.cursor_pos, c) catch return;
        }
        self.cursor_pos += 1;
    }

    pub fn handleBackspace(self: *DialogState) void {
        if (self.cursor_pos > 0 and self.input_buffer.items.len > 0) {
            _ = self.input_buffer.orderedRemove(self.cursor_pos - 1);
            self.cursor_pos -= 1;
        }
    }

    pub fn handleLeft(self: *DialogState) void {
        if (self.cursor_pos > 0) self.cursor_pos -= 1;
    }

    pub fn handleRight(self: *DialogState) void {
        if (self.cursor_pos < self.input_buffer.items.len) self.cursor_pos += 1;
    }

    pub fn getText(self: *DialogState) []const u8 {
        return self.input_buffer.items;
    }
};

/// Render dialog box overlay in the terminal
pub fn renderDialog(
    writer: anytype,
    state: *const DialogState,
    terminal_width: u16,
    terminal_height: u16,
) !void {
    // Dialog dimensions
    const dialog_width: u16 = @min(60, terminal_width - 4);
    const dialog_height: u16 = if (state.dialog_type == .prompt) 9 else 7;

    // Center the dialog
    const start_col = (terminal_width - dialog_width) / 2;
    const start_row = (terminal_height - dialog_height) / 2;

    // Colors
    const bg_color = "\x1b[48;2;45;45;48m";      // Dark gray background
    const border_color = "\x1b[38;2;100;100;105m"; // Gray border
    const text_color = "\x1b[38;2;220;220;220m";   // Light text
    const button_color = "\x1b[48;2;59;130;246m\x1b[38;2;255;255;255m"; // Blue button
    const button_dim = "\x1b[48;2;70;70;75m\x1b[38;2;180;180;180m"; // Dim button
    const input_bg = "\x1b[48;2;30;30;32m";       // Input background
    const reset = "\x1b[0m";

    // Draw dialog box
    var row: u16 = 0;
    while (row < dialog_height) : (row += 1) {
        try writer.print("\x1b[{d};{d}H", .{ start_row + row, start_col });

        if (row == 0) {
            // Top border
            try writer.print("{s}{s}╭", .{ bg_color, border_color });
            var i: u16 = 0;
            while (i < dialog_width - 2) : (i += 1) {
                try writer.writeAll("─");
            }
            try writer.print("╮{s}", .{reset});
        } else if (row == dialog_height - 1) {
            // Bottom border
            try writer.print("{s}{s}╰", .{ bg_color, border_color });
            var i: u16 = 0;
            while (i < dialog_width - 2) : (i += 1) {
                try writer.writeAll("─");
            }
            try writer.print("╯{s}", .{reset});
        } else {
            // Content rows
            try writer.print("{s}{s}│{s}", .{ bg_color, border_color, text_color });

            const content_width = dialog_width - 4;

            if (row == 1) {
                // Title based on dialog type
                const title = switch (state.dialog_type) {
                    .alert => "Alert",
                    .confirm => "Confirm",
                    .prompt => "Prompt",
                    .beforeunload => "Leave Page?",
                    .file_chooser => "Select File",
                };
                const padding = (content_width - title.len) / 2;
                var i: usize = 0;
                while (i < padding) : (i += 1) {
                    try writer.writeAll(" ");
                }
                try writer.writeAll(title);
                i = title.len + padding;
                while (i < content_width) : (i += 1) {
                    try writer.writeAll(" ");
                }
            } else if (row == 3) {
                // Message (truncated if too long)
                const msg = state.message;
                const display_len = @min(msg.len, content_width);
                try writer.writeAll(" ");
                try writer.writeAll(msg[0..display_len]);
                var i: usize = display_len + 1;
                while (i < content_width) : (i += 1) {
                    try writer.writeAll(" ");
                }
            } else if (row == 5 and state.dialog_type == .prompt) {
                // Input field for prompt
                try writer.print(" {s}", .{input_bg});
                const text = state.input_buffer.items;
                const field_width = content_width - 4;
                const display_len = @min(text.len, field_width);
                try writer.writeAll(text[0..display_len]);

                // Show cursor
                if (state.cursor_pos == text.len) {
                    try writer.writeAll("▏");
                }

                var i: usize = display_len + 1;
                while (i < field_width) : (i += 1) {
                    try writer.writeAll(" ");
                }
                try writer.print("{s}{s} ", .{ reset, bg_color });
            } else if ((row == 5 and state.dialog_type != .prompt) or
                      (row == 7 and state.dialog_type == .prompt)) {
                // Buttons
                const buttons = switch (state.dialog_type) {
                    .alert => " [Enter] OK ",
                    .confirm, .beforeunload => " [Enter] OK  [Esc] Cancel ",
                    .prompt => " [Enter] OK  [Esc] Cancel ",
                    .file_chooser => " [Enter] Select  [Esc] Cancel ",
                };
                const btn_len = buttons.len;
                const padding = (content_width - btn_len) / 2;

                var i: usize = 0;
                while (i < padding) : (i += 1) {
                    try writer.writeAll(" ");
                }

                // Render OK button highlighted, Cancel dim
                if (state.dialog_type == .alert) {
                    try writer.print("{s} OK {s}{s}", .{ button_color, reset, bg_color });
                } else {
                    try writer.print("{s} OK {s}{s}  {s} Cancel {s}{s}", .{
                        button_color, reset, bg_color,
                        button_dim, reset, bg_color,
                    });
                }

                i = btn_len + padding;
                while (i < content_width) : (i += 1) {
                    try writer.writeAll(" ");
                }
            } else {
                // Empty row
                var i: usize = 0;
                while (i < content_width) : (i += 1) {
                    try writer.writeAll(" ");
                }
            }

            try writer.print(" {s}│{s}", .{ border_color, reset });
        }
    }
}

/// Show native OS file picker dialog
/// Returns the selected file path(s) or null if cancelled
pub fn showNativeFilePicker(
    allocator: std.mem.Allocator,
    mode: FilePickerMode,
) !?[]const u8 {
    return showNativeFilePickerWithName(allocator, mode, null);
}

/// Show native OS file picker dialog with optional default filename (for save dialogs)
/// Returns the selected file path(s) or null if cancelled
pub fn showNativeFilePickerWithName(
    allocator: std.mem.Allocator,
    mode: FilePickerMode,
    default_name: ?[]const u8,
) !?[]const u8 {
    if (builtin.os.tag == .macos) {
        return showMacOSFilePicker(allocator, mode, default_name);
    } else if (builtin.os.tag == .linux) {
        return showLinuxFilePicker(allocator, mode, default_name);
    }
    return null;
}

fn showMacOSFilePicker(allocator: std.mem.Allocator, mode: FilePickerMode, default_name: ?[]const u8) !?[]const u8 {
    // Get frontmost app before showing dialog so we can restore focus
    const front_app_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "osascript", "-e", "tell application \"System Events\" to get name of first application process whose frontmost is true" },
    }) catch null;
    var front_app: ?[]const u8 = null;
    if (front_app_result) |r| {
        defer allocator.free(r.stderr);
        // Check if process exited normally (not killed by signal)
        const exited_ok = switch (r.term) {
            .Exited => |code| code == 0,
            else => false,
        };
        if (exited_ok and r.stdout.len > 0) {
            var end: usize = r.stdout.len;
            while (end > 0 and (r.stdout[end - 1] == '\n' or r.stdout[end - 1] == '\r')) {
                end -= 1;
            }
            if (end > 0) {
                front_app = r.stdout[0..end];
            } else {
                allocator.free(r.stdout);
            }
        } else {
            allocator.free(r.stdout);
        }
    }
    defer if (front_app_result) |r| {
        if (front_app != null) allocator.free(r.stdout);
    };

    // Build script based on mode - use "Finder" to show dialogs (it handles them well and gets focus)
    var script_buf: [512]u8 = undefined;
    const script: []const u8 = switch (mode) {
        .single =>
            \\tell application "Finder"
            \\    activate
            \\    set theFile to choose file
            \\    return POSIX path of (theFile as text)
            \\end tell
        ,
        .folder =>
            \\tell application "Finder"
            \\    activate
            \\    set theFolder to choose folder
            \\    return POSIX path of (theFolder as text)
            \\end tell
        ,
        .multiple =>
            \\tell application "Finder"
            \\    activate
            \\    set f to (choose file with multiple selections allowed)
            \\    set out to ""
            \\    repeat with i in f
            \\        set out to out & POSIX path of (i as text) & "\n"
            \\    end repeat
            \\    return out
            \\end tell
        ,
        .save => blk: {
            if (default_name) |name| {
                break :blk std.fmt.bufPrint(&script_buf,
                    \\tell application "Finder"
                    \\    activate
                    \\    set theFile to choose file name with prompt "Save As" default name "{s}"
                    \\    return POSIX path of (theFile as text)
                    \\end tell
                , .{name}) catch
                    \\tell application "Finder"
                    \\    activate
                    \\    set theFile to choose file name with prompt "Save As"
                    \\    return POSIX path of (theFile as text)
                    \\end tell
                ;
            } else {
                break :blk
                    \\tell application "Finder"
                    \\    activate
                    \\    set theFile to choose file name with prompt "Save As"
                    \\    return POSIX path of (theFile as text)
                    \\end tell
                ;
            }
        },
    };

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "osascript", "-e", script },
    }) catch {
        // Restore focus even on error
        if (front_app) |app| {
            var refocus_buf: [256]u8 = undefined;
            if (std.fmt.bufPrint(&refocus_buf, "tell application \"{s}\" to activate", .{app})) |s| {
                var refocus = std.process.Child.init(&.{ "osascript", "-e", s }, allocator);
                refocus.spawn() catch {};
            } else |_| {}
        }
        return null;
    };
    defer allocator.free(result.stderr);

    // Restore focus to original app after dialog closes
    defer {
        if (front_app) |app| {
            var refocus_buf: [256]u8 = undefined;
            if (std.fmt.bufPrint(&refocus_buf, "tell application \"{s}\" to activate", .{app})) |s| {
                var refocus = std.process.Child.init(&.{ "osascript", "-e", s }, allocator);
                refocus.spawn() catch {};
            } else |_| {}
        }
    }

    // Check if cancelled (non-zero exit or killed by signal)
    const exited_ok = switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
    if (!exited_ok) {
        allocator.free(result.stdout);
        return null;
    }

    if (result.stdout.len == 0) {
        allocator.free(result.stdout);
        return null;
    }

    // Trim trailing newlines
    var end: usize = result.stdout.len;
    while (end > 0 and (result.stdout[end - 1] == '\n' or result.stdout[end - 1] == '\r')) {
        end -= 1;
    }

    if (end == 0) {
        allocator.free(result.stdout);
        return null;
    }

    // Return trimmed result (caller must free)
    if (end < result.stdout.len) {
        const trimmed = try allocator.dupe(u8, result.stdout[0..end]);
        allocator.free(result.stdout);
        return trimmed;
    }

    return result.stdout;
}

fn showLinuxFilePicker(allocator: std.mem.Allocator, mode: FilePickerMode, default_name: ?[]const u8) !?[]const u8 {
    // Try zenity first
    const zenity_result = tryZenity(allocator, mode, default_name) catch null;
    if (zenity_result) |path| return path;

    // Fallback to kdialog
    return tryKdialog(allocator, mode, default_name);
}

fn tryZenity(allocator: std.mem.Allocator, mode: FilePickerMode, default_name: ?[]const u8) !?[]const u8 {
    // Build argv based on mode
    var argv_buf: [8][]const u8 = undefined;
    var argc: usize = 0;

    argv_buf[argc] = "zenity";
    argc += 1;
    argv_buf[argc] = "--file-selection";
    argc += 1;
    // Modal ensures dialog stays on top and grabs focus
    argv_buf[argc] = "--modal";
    argc += 1;

    switch (mode) {
        .single => {},
        .folder => {
            argv_buf[argc] = "--directory";
            argc += 1;
        },
        .multiple => {
            argv_buf[argc] = "--multiple";
            argc += 1;
        },
        .save => {
            argv_buf[argc] = "--save";
            argc += 1;
            if (default_name) |name| {
                argv_buf[argc] = "--filename";
                argc += 1;
                argv_buf[argc] = name;
                argc += 1;
            }
        },
    }

    const argv = argv_buf[0..argc];

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    }) catch return null;
    defer allocator.free(result.stderr);

    const exited_ok = switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
    if (!exited_ok or result.stdout.len == 0) {
        allocator.free(result.stdout);
        return null;
    }

    // Trim newlines
    var end: usize = result.stdout.len;
    while (end > 0 and (result.stdout[end - 1] == '\n' or result.stdout[end - 1] == '\r')) {
        end -= 1;
    }

    if (end == 0) {
        allocator.free(result.stdout);
        return null;
    }

    if (end < result.stdout.len) {
        const trimmed = try allocator.dupe(u8, result.stdout[0..end]);
        allocator.free(result.stdout);
        return trimmed;
    }

    return result.stdout;
}

fn tryKdialog(allocator: std.mem.Allocator, mode: FilePickerMode, default_name: ?[]const u8) !?[]const u8 {
    // Build argv based on mode
    var argv_buf: [4][]const u8 = undefined;
    var argc: usize = 0;

    argv_buf[argc] = "kdialog";
    argc += 1;

    switch (mode) {
        .single => {
            argv_buf[argc] = "--getopenfilename";
            argc += 1;
        },
        .folder => {
            argv_buf[argc] = "--getexistingdirectory";
            argc += 1;
        },
        .multiple => {
            argv_buf[argc] = "--getopenfilename";
            argc += 1;
            argv_buf[argc] = "--multiple";
            argc += 1;
        },
        .save => {
            argv_buf[argc] = "--getsavefilename";
            argc += 1;
            if (default_name) |name| {
                argv_buf[argc] = name;
                argc += 1;
            }
        },
    }

    const argv = argv_buf[0..argc];

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    }) catch return null;
    defer allocator.free(result.stderr);

    const exited_ok = switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
    if (!exited_ok or result.stdout.len == 0) {
        allocator.free(result.stdout);
        return null;
    }

    // Trim newlines
    var end: usize = result.stdout.len;
    while (end > 0 and (result.stdout[end - 1] == '\n' or result.stdout[end - 1] == '\r')) {
        end -= 1;
    }

    if (end == 0) {
        allocator.free(result.stdout);
        return null;
    }

    if (end < result.stdout.len) {
        const trimmed = try allocator.dupe(u8, result.stdout[0..end]);
        allocator.free(result.stdout);
        return trimmed;
    }

    return result.stdout;
}

/// Show native OS list picker dialog
/// Returns the selected item index (0-based) or null if cancelled
/// default_index: pre-select this item (0-based), null for first item
pub fn showNativeListPicker(
    allocator: std.mem.Allocator,
    title: []const u8,
    items: []const []const u8,
    default_index: ?usize,
) !?usize {
    if (builtin.os.tag == .macos) {
        return showMacOSListPicker(allocator, title, items, default_index);
    } else if (builtin.os.tag == .linux) {
        return showLinuxListPicker(allocator, title, items);
    }
    return null;
}

fn showMacOSListPicker(allocator: std.mem.Allocator, title: []const u8, items: []const []const u8, default_index: ?usize) !?usize {
    if (items.len == 0) return null;

    // AppleScript uses 1-based indexing
    const default_item = if (default_index) |idx| idx + 1 else 1;

    // Get frontmost app before showing dialog so we can restore focus
    const front_app_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "osascript", "-e", "tell application \"System Events\" to get name of first application process whose frontmost is true" },
    }) catch null;
    var front_app: ?[]const u8 = null;
    if (front_app_result) |r| {
        defer allocator.free(r.stderr);
        const exited_ok = switch (r.term) {
            .Exited => |code| code == 0,
            else => false,
        };
        if (exited_ok and r.stdout.len > 0) {
            // Trim newline
            var end: usize = r.stdout.len;
            while (end > 0 and (r.stdout[end - 1] == '\n' or r.stdout[end - 1] == '\r')) {
                end -= 1;
            }
            if (end > 0) {
                front_app = r.stdout[0..end];
            } else {
                allocator.free(r.stdout);
            }
        } else {
            allocator.free(r.stdout);
        }
    }
    defer if (front_app_result) |r| {
        if (front_app != null) allocator.free(r.stdout);
    };

    // Build AppleScript list string: {"item1", "item2", ...}
    var list_buf = try std.ArrayList(u8).initCapacity(allocator, 256);
    defer list_buf.deinit(allocator);

    try list_buf.appendSlice(allocator, "{");
    for (items, 0..) |item, i| {
        if (i > 0) try list_buf.appendSlice(allocator, ", ");
        try list_buf.appendSlice(allocator, "\"");
        // Escape quotes in item
        for (item) |c| {
            if (c == '"') {
                try list_buf.appendSlice(allocator, "\\\"");
            } else if (c == '\\') {
                try list_buf.appendSlice(allocator, "\\\\");
            } else {
                try list_buf.append(allocator, c);
            }
        }
        try list_buf.appendSlice(allocator, "\"");
    }
    try list_buf.appendSlice(allocator, "}");

    // Build script - use "System Events" to ensure dialog gets focus
    var script_buf: [4096]u8 = undefined;
    const script = std.fmt.bufPrint(&script_buf,
        \\tell application "System Events"
        \\    activate
        \\    set theList to {s}
        \\    set theChoice to choose from list theList with prompt "{s}" default items {{item {d} of theList}}
        \\    if theChoice is false then
        \\        return ""
        \\    else
        \\        return item 1 of theChoice
        \\    end if
        \\end tell
    , .{ list_buf.items, title, default_item }) catch return null;

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "osascript", "-e", script },
    }) catch return null;
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    // Restore focus to original app
    if (front_app) |app| {
        var refocus_buf: [256]u8 = undefined;
        const refocus_script = std.fmt.bufPrint(&refocus_buf, "tell application \"{s}\" to activate", .{app}) catch null;
        if (refocus_script) |s| {
            var refocus = std.process.Child.init(&.{ "osascript", "-e", s }, allocator);
            refocus.spawn() catch {};
        }
    }

    // Check if cancelled
    const exited_ok = switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
    if (!exited_ok or result.stdout.len == 0) {
        return null;
    }

    // Trim trailing newline
    var selected = result.stdout;
    while (selected.len > 0 and (selected[selected.len - 1] == '\n' or selected[selected.len - 1] == '\r')) {
        selected = selected[0 .. selected.len - 1];
    }

    if (selected.len == 0) return null;

    // Find which item was selected
    for (items, 0..) |item, i| {
        if (std.mem.eql(u8, item, selected)) {
            return i;
        }
    }

    return null;
}

fn showLinuxListPicker(allocator: std.mem.Allocator, title: []const u8, items: []const []const u8) !?usize {
    if (items.len == 0) return null;

    // Try zenity first
    var argv_list = try std.ArrayList([]const u8).initCapacity(allocator, 8 + items.len);
    defer argv_list.deinit(allocator);

    try argv_list.append(allocator, "zenity");
    try argv_list.append(allocator, "--list");
    try argv_list.append(allocator, "--title");
    try argv_list.append(allocator, title);
    try argv_list.append(allocator, "--column");
    try argv_list.append(allocator, "Tab");

    for (items) |item| {
        try argv_list.append(allocator, item);
    }

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv_list.items,
    }) catch return null;
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    const exited_ok = switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
    if (!exited_ok or result.stdout.len == 0) {
        return null;
    }

    // Trim and find index
    var selected = result.stdout;
    while (selected.len > 0 and (selected[selected.len - 1] == '\n' or selected[selected.len - 1] == '\r')) {
        selected = selected[0 .. selected.len - 1];
    }

    for (items, 0..) |item, i| {
        if (std.mem.eql(u8, item, selected)) {
            return i;
        }
    }

    return null;
}
