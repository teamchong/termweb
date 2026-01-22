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
    copy,
    cut,
    paste,
    select_all,
    tab_picker,
};

/// Shortcut definition
pub const ShortcutDef = struct {
    key: u8,
    shortcut_mod: bool = true,
    shift: bool = false,
    alt: bool = false,
    action: AppAction,
};

/// App shortcuts that are intercepted (not sent to browser)
pub const app_shortcuts = [_]ShortcutDef{
    // Quit shortcuts
    .{ .key = 'q', .action = .quit },
    .{ .key = 'w', .action = .quit },

    // Navigation
    .{ .key = 'l', .action = .address_bar },
    .{ .key = 'r', .action = .reload },

    // Clipboard operations (use system clipboard, not browser's)
    .{ .key = 'c', .action = .copy },
    .{ .key = 'x', .action = .cut },
    .{ .key = 'v', .action = .paste },
    .{ .key = 'a', .action = .select_all },

    // Tab management
    .{ .key = 't', .action = .tab_picker },
};

/// Find an app action for a key event.
/// Returns null if the key should be passed to the browser.
pub fn findAppAction(event: NormalizedKeyEvent) ?AppAction {
    // Get the character from the base key
    const char = event.base_key.getChar() orelse return null;
    const lower_char = std.ascii.toLower(char);

    for (app_shortcuts) |shortcut| {
        // Check if shortcut modifier requirement matches
        if (shortcut.shortcut_mod and !event.shortcut_mod) continue;
        if (!shortcut.shortcut_mod and event.shortcut_mod) continue;

        // Check additional modifiers
        if (shortcut.shift != event.shift) continue;
        if (shortcut.alt != event.alt) continue;

        // Check key match (case-insensitive)
        if (std.ascii.toLower(shortcut.key) == lower_char) {
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
