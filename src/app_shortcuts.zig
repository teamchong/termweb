/// App Shortcuts - Registry of application-level keyboard shortcuts.
///
/// These shortcuts are intercepted by termweb and NOT sent to the browser.
/// Everything else passes through to the browser with correct CDP modifiers.
///
/// Examples:
/// - Cmd+Q/W: Quit termweb (intercepted)
/// - Cmd+L: Focus address bar (intercepted)
/// - Cmd+R: Reload page (intercepted)
/// - Cmd+C/V/X/A: Clipboard operations (intercepted, use system clipboard)
/// - Cmd+Z: Undo (passed to browser)
/// - Cmd+F: Find (passed to browser)
/// - Cmd+S: Save (passed to browser)
const std = @import("std");
const key_normalizer = @import("terminal/key_normalizer.zig");
const NormalizedKeyEvent = key_normalizer.NormalizedKeyEvent;
const BaseKey = key_normalizer.BaseKey;

/// Actions that termweb handles at the app level
pub const AppAction = enum {
    quit,
    address_bar,
    reload,
    go_back,
    go_forward,
    stop_loading,
    copy,
    cut,
    paste,
    select_all,
    tab_picker,
};

/// Key type for shortcuts - can be a character or special key
pub const ShortcutKey = union(enum) {
    char: u8,
    left,
    right,
};

/// Shortcut definition
pub const ShortcutDef = struct {
    key: ShortcutKey,
    shortcut_mod: bool = true,  // Cmd on macOS, Ctrl on Linux
    ctrl: bool = false,          // Explicit Ctrl (cross-platform)
    shift: bool = false,
    alt: bool = false,
    action: AppAction,
};

/// App shortcuts that are intercepted (not sent to browser)
/// All shortcuts use Ctrl for cross-platform consistency
pub const app_shortcuts = [_]ShortcutDef{
    // Quit shortcuts
    .{ .key = .{ .char = 'q' }, .shortcut_mod = false, .ctrl = true, .action = .quit },
    .{ .key = .{ .char = 'w' }, .shortcut_mod = false, .ctrl = true, .action = .quit },

    // Navigation
    .{ .key = .{ .char = 'l' }, .shortcut_mod = false, .ctrl = true, .action = .address_bar },
    .{ .key = .{ .char = 'r' }, .shortcut_mod = false, .ctrl = true, .action = .reload },
    .{ .key = .{ .char = '[' }, .shortcut_mod = false, .ctrl = true, .action = .go_back },
    .{ .key = .{ .char = ']' }, .shortcut_mod = false, .ctrl = true, .action = .go_forward },
    .{ .key = .{ .char = '.' }, .shortcut_mod = false, .ctrl = true, .action = .stop_loading },

    // Clipboard operations (use system clipboard, not browser's)
    .{ .key = .{ .char = 'c' }, .shortcut_mod = false, .ctrl = true, .action = .copy },
    .{ .key = .{ .char = 'x' }, .shortcut_mod = false, .ctrl = true, .action = .cut },
    .{ .key = .{ .char = 'v' }, .shortcut_mod = false, .ctrl = true, .action = .paste },
    .{ .key = .{ .char = 'a' }, .shortcut_mod = false, .ctrl = true, .action = .select_all },

    // Tab management
    .{ .key = .{ .char = 't' }, .shortcut_mod = false, .ctrl = true, .action = .tab_picker },
};

/// Find an app action for a key event.
/// Returns null if the key should be passed to the browser.
pub fn findAppAction(event: NormalizedKeyEvent) ?AppAction {
    for (app_shortcuts) |shortcut| {
        // Check modifier requirements
        if (shortcut.shortcut_mod and !event.shortcut_mod) continue;
        if (!shortcut.shortcut_mod and event.shortcut_mod) continue;
        if (shortcut.ctrl and !event.ctrl) continue;
        if (!shortcut.ctrl and !shortcut.shortcut_mod and event.ctrl) continue;
        if (shortcut.shift != event.shift) continue;
        if (shortcut.alt != event.alt) continue;

        // Check key match
        const matches = switch (shortcut.key) {
            .char => |c| blk: {
                const event_char = event.base_key.getChar() orelse break :blk false;
                break :blk std.ascii.toLower(c) == std.ascii.toLower(event_char);
            },
            .left => event.base_key == .left,
            .right => event.base_key == .right,
        };

        if (matches) {
            return shortcut.action;
        }
    }

    return null;
}

/// Check if a key event is an app shortcut (should not be sent to browser)
pub fn isAppShortcut(event: NormalizedKeyEvent) bool {
    return findAppAction(event) != null;
}

// Tests
test "findAppAction quit" {
    // Simulate Cmd+Q
    const event = NormalizedKeyEvent{
        .base_key = .{ .char = 'q' },
        .shortcut_mod = true,
        .meta = true,
        .cdp_modifiers = 4,
    };
    try std.testing.expectEqual(AppAction.quit, findAppAction(event).?);
}

test "findAppAction copy" {
    // Simulate Cmd+C
    const event = NormalizedKeyEvent{
        .base_key = .{ .char = 'c' },
        .shortcut_mod = true,
        .meta = true,
        .cdp_modifiers = 4,
    };
    try std.testing.expectEqual(AppAction.copy, findAppAction(event).?);
}

test "findAppAction pass through Cmd+Z" {
    // Cmd+Z should pass through to browser (undo)
    const event = NormalizedKeyEvent{
        .base_key = .{ .char = 'z' },
        .shortcut_mod = true,
        .meta = true,
        .cdp_modifiers = 4,
    };
    try std.testing.expectEqual(null, findAppAction(event));
}

test "findAppAction pass through regular char" {
    // Regular 'a' without modifiers should pass through
    const event = NormalizedKeyEvent{
        .base_key = .{ .char = 'a' },
        .shortcut_mod = false,
        .cdp_modifiers = 0,
    };
    try std.testing.expectEqual(null, findAppAction(event));
}

test "findAppAction Cmd+Shift+C is not copy" {
    // Cmd+Shift+C should pass through (not plain copy)
    const event = NormalizedKeyEvent{
        .base_key = .{ .char = 'c' },
        .shortcut_mod = true,
        .shift = true,
        .meta = true,
        .cdp_modifiers = 4 | 8,
    };
    try std.testing.expectEqual(null, findAppAction(event));
}
