/// Key Normalizer - Unified keyboard event representation.
///
/// Problem: Same key combo can arrive in two forms:
/// 1. `.char => 'c'` with meta modifier (4) - from Kitty keyboard protocol
/// 2. `.ctrl_c` - terminal sends control character (Cmd on macOS = Ctrl)
///
/// Solution: Normalize both forms to a unified NormalizedKeyEvent that:
/// - Extracts the base key (character or special key)
/// - Tracks all modifiers (shift, ctrl, alt, meta)
/// - Provides `shortcut_mod` for cross-platform shortcuts (Cmd on macOS, Ctrl on Linux)
/// - Preserves CDP modifiers for browser dispatch
const std = @import("std");
const builtin = @import("builtin");
const input_mod = @import("input.zig");

const Key = input_mod.Key;
const KeyInput = input_mod.KeyInput;

/// Base key without modifiers - the actual key pressed
pub const BaseKey = union(enum) {
    char: u8,
    escape,
    enter,
    tab,
    backspace,
    delete,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    insert,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    none,

    /// Get the character if this is a char key
    pub fn getChar(self: BaseKey) ?u8 {
        return switch (self) {
            .char => |c| c,
            else => null,
        };
    }

    /// Check if this matches a character (case-insensitive)
    pub fn isChar(self: BaseKey, c: u8) bool {
        return switch (self) {
            .char => |ch| std.ascii.toLower(ch) == std.ascii.toLower(c),
            else => false,
        };
    }
};

/// Normalized key event with all modifier information
pub const NormalizedKeyEvent = struct {
    base_key: BaseKey,
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    meta: bool = false,
    /// Cross-platform shortcut modifier: Cmd on macOS, Ctrl on Linux/Windows
    /// Use this for app shortcuts like Cmd+Q, Cmd+C, Cmd+V
    shortcut_mod: bool = false,
    /// Raw CDP modifiers for browser dispatch (1=alt, 2=ctrl, 4=meta, 8=shift)
    cdp_modifiers: u8 = 0,

    /// Check if this event matches a shortcut (shortcut_mod + key)
    pub fn isShortcut(self: NormalizedKeyEvent, key: u8) bool {
        return self.shortcut_mod and self.base_key.isChar(key);
    }

    /// Check if this event matches a shortcut with shift
    pub fn isShiftShortcut(self: NormalizedKeyEvent, key: u8) bool {
        return self.shortcut_mod and self.shift and self.base_key.isChar(key);
    }

    /// Check if only the shortcut modifier is pressed (no shift/alt)
    pub fn isPlainShortcut(self: NormalizedKeyEvent, key: u8) bool {
        return self.shortcut_mod and !self.shift and !self.alt and self.base_key.isChar(key);
    }

    /// Get CDP modifiers with shortcut_mod translated appropriately
    /// On macOS: shortcut_mod = meta (4)
    /// On Linux: shortcut_mod = ctrl (2)
    pub fn getCdpModifiers(self: NormalizedKeyEvent) u8 {
        return self.cdp_modifiers;
    }
};

/// Normalize a KeyInput to a unified NormalizedKeyEvent
pub fn normalize(key_input: KeyInput) NormalizedKeyEvent {
    const key = key_input.key;
    const mods = key_input.modifiers; // CDP format: 1=alt, 2=ctrl, 4=meta, 8=shift

    // Extract modifier flags from CDP modifiers
    const alt = (mods & 1) != 0;
    const ctrl = (mods & 2) != 0;
    const meta = (mods & 4) != 0;
    const shift = (mods & 8) != 0;

    // Platform-specific shortcut modifier
    const is_macos = comptime builtin.os.tag == .macos;
    const shortcut_from_mods = if (is_macos) meta else ctrl;

    // Handle different key types
    return switch (key) {
        // Regular character with modifiers from Kitty protocol
        .char => |c| .{
            .base_key = .{ .char = c },
            .shift = shift,
            .ctrl = ctrl,
            .alt = alt,
            .meta = meta,
            .shortcut_mod = shortcut_from_mods,
            .cdp_modifiers = mods,
        },

        // Control characters - these come from terminal interpreting Cmd as Ctrl
        // On macOS, Cmd+C sends ctrl_c, so we need to reconstruct the modifier
        .ctrl_a => normalizeCtrlKey('a', mods),
        .ctrl_b => normalizeCtrlKey('b', mods),
        .ctrl_c => normalizeCtrlKey('c', mods),
        .ctrl_d => normalizeCtrlKey('d', mods),
        .ctrl_e => normalizeCtrlKey('e', mods),
        .ctrl_f => normalizeCtrlKey('f', mods),
        .ctrl_g => normalizeCtrlKey('g', mods),
        .ctrl_h => normalizeCtrlKey('h', mods),
        .ctrl_i => normalizeCtrlKey('i', mods),
        .ctrl_j => normalizeCtrlKey('j', mods),
        .ctrl_k => normalizeCtrlKey('k', mods),
        .ctrl_l => normalizeCtrlKey('l', mods),
        .ctrl_m => normalizeCtrlKey('m', mods),
        .ctrl_n => normalizeCtrlKey('n', mods),
        .ctrl_o => normalizeCtrlKey('o', mods),
        .ctrl_p => normalizeCtrlKey('p', mods),
        .ctrl_q => normalizeCtrlKey('q', mods),
        .ctrl_r => normalizeCtrlKey('r', mods),
        .ctrl_s => normalizeCtrlKey('s', mods),
        .ctrl_t => normalizeCtrlKey('t', mods),
        .ctrl_u => normalizeCtrlKey('u', mods),
        .ctrl_v => normalizeCtrlKey('v', mods),
        .ctrl_w => normalizeCtrlKey('w', mods),
        .ctrl_x => normalizeCtrlKey('x', mods),
        .ctrl_y => normalizeCtrlKey('y', mods),
        .ctrl_z => normalizeCtrlKey('z', mods),

        // Alt+char combinations
        .alt_char => |c| .{
            .base_key = .{ .char = c },
            .shift = shift,
            .ctrl = ctrl,
            .alt = true,
            .meta = meta,
            .shortcut_mod = shortcut_from_mods,
            .cdp_modifiers = mods | 1, // Ensure alt bit is set
        },

        // Special keys - preserve modifiers
        .escape => specialKey(.escape, mods),
        .enter => specialKey(.enter, mods),
        .tab => specialKey(.tab, mods),
        .shift_tab => .{
            .base_key = .tab,
            .shift = true,
            .ctrl = ctrl,
            .alt = alt,
            .meta = meta,
            .shortcut_mod = shortcut_from_mods,
            .cdp_modifiers = mods | 8, // Ensure shift bit is set
        },
        .backspace => specialKey(.backspace, mods),
        .delete => specialKey(.delete, mods),
        .up => specialKey(.up, mods),
        .down => specialKey(.down, mods),
        .left => specialKey(.left, mods),
        .right => specialKey(.right, mods),
        .home => specialKey(.home, mods),
        .end => specialKey(.end, mods),
        .page_up => specialKey(.page_up, mods),
        .page_down => specialKey(.page_down, mods),
        .insert => specialKey(.insert, mods),
        .f1 => specialKey(.f1, mods),
        .f2 => specialKey(.f2, mods),
        .f3 => specialKey(.f3, mods),
        .f4 => specialKey(.f4, mods),
        .f5 => specialKey(.f5, mods),
        .f6 => specialKey(.f6, mods),
        .f7 => specialKey(.f7, mods),
        .f8 => specialKey(.f8, mods),
        .f9 => specialKey(.f9, mods),
        .f10 => specialKey(.f10, mods),
        .f11 => specialKey(.f11, mods),
        .f12 => specialKey(.f12, mods),
        .none => .{ .base_key = .none },
    };
}

/// Normalize a ctrl+key combination
/// On macOS, terminal sends Cmd+X as ctrl_x, so we treat it as shortcut_mod
fn normalizeCtrlKey(char: u8, additional_mods: u8) NormalizedKeyEvent {
    const is_macos = comptime builtin.os.tag == .macos;

    // Extract additional modifiers
    const alt = (additional_mods & 1) != 0;
    const meta = (additional_mods & 4) != 0;
    const shift = (additional_mods & 8) != 0;

    // On macOS: ctrl_x from terminal = user pressed Cmd+X or Ctrl+X
    // The terminal sends the control character either way
    // Set ctrl=true so app shortcuts match, and shortcut_mod=true for cross-platform
    if (is_macos) {
        return .{
            .base_key = .{ .char = char },
            .shift = shift,
            .ctrl = true, // Control character was sent
            .alt = alt,
            .meta = true, // Treat as Cmd on macOS for browser
            .shortcut_mod = true,
            .cdp_modifiers = 4 | additional_mods, // Set meta bit for browser
        };
    } else {
        // On Linux: ctrl_x = Ctrl+X, which is the shortcut modifier
        return .{
            .base_key = .{ .char = char },
            .shift = shift,
            .ctrl = true,
            .alt = alt,
            .meta = meta,
            .shortcut_mod = true,
            .cdp_modifiers = 2 | additional_mods, // Set ctrl bit for browser
        };
    }
}

/// Create a normalized event for a special key with modifiers
fn specialKey(base: BaseKey, mods: u8) NormalizedKeyEvent {
    const is_macos = comptime builtin.os.tag == .macos;
    const alt = (mods & 1) != 0;
    const ctrl = (mods & 2) != 0;
    const meta = (mods & 4) != 0;
    const shift = (mods & 8) != 0;
    const shortcut_mod = if (is_macos) meta else ctrl;

    return .{
        .base_key = base,
        .shift = shift,
        .ctrl = ctrl,
        .alt = alt,
        .meta = meta,
        .shortcut_mod = shortcut_mod,
        .cdp_modifiers = mods,
    };
}

// Tests
test "normalize char with meta modifier" {
    const event = normalize(.{ .key = .{ .char = 'c' }, .modifiers = 4 }); // meta=4
    try std.testing.expect(event.base_key.isChar('c'));
    try std.testing.expect(event.meta);
    try std.testing.expect(event.shortcut_mod); // On macOS
}

test "normalize ctrl_c" {
    const event = normalize(.{ .key = .ctrl_c, .modifiers = 0 });
    try std.testing.expect(event.base_key.isChar('c'));
    try std.testing.expect(event.shortcut_mod);
}

test "isShortcut" {
    const event = normalize(.{ .key = .ctrl_c, .modifiers = 0 });
    try std.testing.expect(event.isShortcut('c'));
    try std.testing.expect(event.isShortcut('C'));
    try std.testing.expect(!event.isShortcut('v'));
}

test "normalize with shift" {
    const event = normalize(.{ .key = .{ .char = 'c' }, .modifiers = 4 | 8 }); // meta+shift
    try std.testing.expect(event.base_key.isChar('c'));
    try std.testing.expect(event.shift);
    try std.testing.expect(event.meta);
    try std.testing.expect(event.shortcut_mod);
    try std.testing.expect(event.isShiftShortcut('c'));
}
