const std = @import("std");

// File-based debug logging (always on for debugging)
var input_debug_file: ?std.fs.File = null;

fn inputDebugLog(comptime fmt: []const u8, args: anytype) void {
    if (input_debug_file == null) {
        input_debug_file = std.fs.cwd().createFile("/tmp/input_debug.log", .{ .truncate = true }) catch return;
    }
    if (input_debug_file) |f| {
        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
        _ = f.write(msg) catch {};
    }
}

pub const Key = union(enum) {
    char: u8,

    // Control keys
    escape,
    tab,
    shift_tab,
    backspace,
    enter,

    // Ctrl combinations (Ctrl+A=1 through Ctrl+Z=26)
    ctrl_a, ctrl_b, ctrl_c, ctrl_d, ctrl_e, ctrl_f, ctrl_g,
    ctrl_h, ctrl_i, ctrl_j, ctrl_k, ctrl_l, ctrl_m, ctrl_n,
    ctrl_o, ctrl_p, ctrl_q, ctrl_r, ctrl_s, ctrl_t, ctrl_u,
    ctrl_v, ctrl_w, ctrl_x, ctrl_y, ctrl_z,

    // Alt combinations
    alt_char: u8,  // Alt+letter

    // Arrow keys
    up, down, left, right,

    // Navigation
    home, end, insert, delete,
    page_up, page_down,

    // Function keys
    f1, f2, f3, f4, f5, f6,
    f7, f8, f9, f10, f11, f12,

    none, // No key pressed (non-blocking)
};

pub const MouseButton = enum {
    left,
    right,
    middle,
    none,
};

pub const MouseEventType = enum {
    press,
    release,
    move,
    drag,
    wheel,
};

pub const MouseEvent = struct {
    type: MouseEventType,
    button: MouseButton,
    x: u16, // Terminal pixel coordinates
    y: u16,
    delta_y: i16, // For wheel events

    // Modifiers (for future extension)
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
};

pub const Input = union(enum) {
    key: KeyInput,
    mouse: MouseEvent,
    paste: []const u8, // Bracketed paste content (caller must free)
    none,
};

pub const KeyInput = struct {
    key: Key,
    modifiers: u8 = 0, // CDP modifiers: 1=alt, 2=ctrl, 4=meta, 8=shift
};

pub const InputReader = struct {
    fd: std.posix.fd_t,
    buffer: [256]u8,  // Increased for accumulation
    buffer_len: usize,  // Track accumulated bytes
    mouse_enabled: bool,
    debug_input: bool,
    allocator: std.mem.Allocator,

    // State for multi-byte sequences
    in_escape: bool,
    escape_buffer: [64]u8,
    escape_len: usize,

    // State for bracketed paste
    in_paste: bool,
    paste_buffer: std.ArrayList(u8),

    pub fn init(fd: std.posix.fd_t, debug_input: bool, allocator: std.mem.Allocator) InputReader {
        return .{
            .fd = fd,
            .buffer = undefined,
            .buffer_len = 0,
            .mouse_enabled = false,
            .debug_input = debug_input,
            .allocator = allocator,
            .in_escape = false,
            .escape_buffer = undefined,
            .escape_len = 0,
            .in_paste = false,
            .paste_buffer = .{},
        };
    }

    pub fn deinit(self: *InputReader) void {
        self.paste_buffer.deinit(self.allocator);
    }

    fn debugLog(self: *InputReader, comptime fmt: []const u8, args: anytype) void {
        if (self.debug_input) {
            std.debug.print(fmt, args);
        }
    }

    /// Parse single byte into Key (regular chars and control codes)
    fn parseSingleByte(_: *InputReader, c: u8) !Key {
        return switch (c) {
            1 => .ctrl_a,
            2 => .ctrl_b,
            3 => .ctrl_c,
            4 => .ctrl_d,
            5 => .ctrl_e,
            6 => .ctrl_f,
            7 => .ctrl_g,
            8 => .backspace,  // Ctrl+H or Backspace
            9 => .tab,        // Ctrl+I or Tab
            10, 13 => .enter, // Ctrl+J (LF) or Ctrl+M (CR)
            11 => .ctrl_k,
            12 => .ctrl_l,
            14 => .ctrl_n,
            15 => .ctrl_o,
            16 => .ctrl_p,
            17 => .ctrl_q,
            18 => .ctrl_r,
            19 => .ctrl_s,
            20 => .ctrl_t,
            21 => .ctrl_u,
            22 => .ctrl_v,
            23 => .ctrl_w,
            24 => .ctrl_x,
            25 => .ctrl_y,
            26 => .ctrl_z,
            127 => .backspace, // DEL
            else => .{ .char = c },
        };
    }

    /// Parse CSI sequence (ESC [ ...)
    fn parseCSI(self: *InputReader) !?Input {
        // Need at least ESC [ X (3 bytes)
        if (self.escape_len < 3) return null;

        // DEBUG: Log escape buffer contents
        self.debugLog("[CSI] escape_len={d} buf[2]='{c}'(0x{x}) mouse_enabled={}\n", .{
            self.escape_len,
            if (self.escape_buffer[2] >= 32 and self.escape_buffer[2] < 127) self.escape_buffer[2] else '.',
            self.escape_buffer[2],
            self.mouse_enabled,
        });

        // Simple cursor keys: ESC [ A/B/C/D
        if (self.escape_len == 3) {
            return switch (self.escape_buffer[2]) {
                'A' => .{ .key = .{ .key = .up } },
                'B' => .{ .key = .{ .key = .down } },
                'C' => .{ .key = .{ .key = .right } },
                'D' => .{ .key = .{ .key = .left } },
                else => null,
            };
        }

        // xterm-style modified cursor keys: ESC [ 1 ; mod A/B/C/D/H/F
        // Also handles: ESC [ 1 ; mod : event A/B/C/D/H/F (Kitty extended)
        // H = Home, F = End (in application cursor mode)
        const last_char = self.escape_buffer[self.escape_len - 1];
        if (last_char == 'A' or last_char == 'B' or last_char == 'C' or last_char == 'D' or
            last_char == 'H' or last_char == 'F')
        {
            // Parse the key
            const key: Key = switch (last_char) {
                'A' => .up,
                'B' => .down,
                'C' => .right,
                'D' => .left,
                'H' => .home,
                'F' => .end,
                else => unreachable,
            };

            // Try to extract modifiers from the sequence
            // Format: ESC [ 1 ; mod A  or  ESC [ 1 ; mod : event A
            var cdp_mods: u8 = 0;
            if (self.escape_len > 3) {
                // Find semicolon position
                var semi_pos: ?usize = null;
                var colon_pos: ?usize = null;
                for (self.escape_buffer[2 .. self.escape_len - 1], 0..) |byte, i| {
                    if (byte == ';' and semi_pos == null) {
                        semi_pos = i + 2;
                    } else if (byte == ':' and colon_pos == null) {
                        colon_pos = i + 2;
                    }
                }

                if (semi_pos) |sp| {
                    // Parse modifier number after semicolon
                    const mod_end = colon_pos orelse (self.escape_len - 1);
                    if (mod_end > sp + 1) {
                        const mod_str = self.escape_buffer[sp + 1 .. mod_end];
                        const raw_mod = std.fmt.parseInt(u16, mod_str, 10) catch 1;

                        // Kitty protocol: modifier bits are (raw_mod - 1)
                        // Kitty bits: 1=shift, 2=alt, 4=ctrl, 8=super, 16=hyper, 32=meta, 64=caps_lock
                        // xterm style: 2=shift, 3=alt, 5=ctrl, etc (value = 1 + sum of bits)
                        // Both use offset-by-1 encoding, so we subtract 1 to get the actual bits
                        const mod_bits = if (raw_mod > 0) raw_mod - 1 else 0;

                        // Extract modifier flags (Kitty-style bit positions)
                        const shift = (mod_bits & 1) != 0;
                        const alt = (mod_bits & 2) != 0;
                        const ctrl = (mod_bits & 4) != 0;
                        const super = (mod_bits & 8) != 0; // Cmd on macOS

                        // Convert to CDP: 8=shift, 2=ctrl, 1=alt, 4=meta
                        cdp_mods = (if (shift) @as(u8, 8) else 0) |
                            (if (ctrl) @as(u8, 2) else 0) |
                            (if (alt) @as(u8, 1) else 0) |
                            (if (super) @as(u8, 4) else 0);
                    }
                }
            }

            return .{ .key = .{ .key = key, .modifiers = cdp_mods } };
        }

        // Mouse: ESC [ < ... M/m
        // Always try to parse mouse sequences to consume them properly
        // (even when disabled, we need to find the terminator)
        if (self.escape_buffer[2] == '<') {
            inputDebugLog("[MOUSE] Detected mouse CSI, escape_len={d}, mouse_enabled={}", .{ self.escape_len, self.mouse_enabled });

            // Check if sequence is complete by looking for M/m terminator
            var has_terminator = false;
            var term_pos: usize = 0;
            for (self.escape_buffer[0..self.escape_len], 0..) |byte, i| {
                if (byte == 'M' or byte == 'm') {
                    has_terminator = true;
                    term_pos = i;
                    break;
                }
            }

            if (!has_terminator) {
                inputDebugLog("[MOUSE] No terminator yet, returning null", .{});
                return null; // Incomplete - need more bytes
            }

            inputDebugLog("[MOUSE] Found terminator at pos {d}", .{term_pos});

            // Sequence is complete - parse it
            if (self.mouse_enabled) {
                inputDebugLog("[MOUSE] Parsing mouse event (enabled)", .{});
                return try self.parseMouseCSI();
            } else {
                inputDebugLog("[MOUSE] Discarding mouse event (disabled)", .{});
                // Mouse disabled - discard the sequence by returning none
                return .none;
            }
        }

        // Function/nav keys: ESC [ N ~ or ESC [ N ; mod ~
        // Also handles bracketed paste: ESC [ 200 ~ (start) and ESC [ 201 ~ (end)
        // Look for terminating ~
        if (self.escape_buffer[self.escape_len - 1] == '~') {
            // Find semicolon to separate key code from modifiers
            var semi_pos: ?usize = null;
            for (self.escape_buffer[2 .. self.escape_len - 1], 0..) |byte, i| {
                if (byte == ';') {
                    semi_pos = i + 2;
                    break;
                }
            }

            const num_end = semi_pos orelse (self.escape_len - 1);
            const num_str = self.escape_buffer[2..num_end];
            const num = std.fmt.parseInt(u16, num_str, 10) catch return null;

            // Handle bracketed paste sequences
            if (num == 200) {
                // Start of bracketed paste
                inputDebugLog("[PASTE] Start bracketed paste (ESC[200~)", .{});
                self.in_paste = true;
                self.paste_buffer.clearRetainingCapacity();
                return .none; // Signal handled, continue reading
            } else if (num == 201) {
                // End of bracketed paste - return accumulated content
                inputDebugLog("[PASTE] End bracketed paste (ESC[201~), len={d}", .{self.paste_buffer.items.len});
                self.in_paste = false;
                if (self.paste_buffer.items.len > 0) {
                    // Clone the content for the caller (they own it)
                    const content = self.allocator.dupe(u8, self.paste_buffer.items) catch return .none;
                    self.paste_buffer.clearRetainingCapacity();
                    return .{ .paste = content };
                }
                return .none;
            }

            // Parse modifiers if present
            var cdp_mods: u8 = 0;
            if (semi_pos) |sp| {
                const mod_str = self.escape_buffer[sp + 1 .. self.escape_len - 1];
                const raw_mod = std.fmt.parseInt(u16, mod_str, 10) catch 1;
                const mod_bits = if (raw_mod > 0) raw_mod - 1 else 0;
                const shift = (mod_bits & 1) != 0;
                const alt = (mod_bits & 2) != 0;
                const ctrl = (mod_bits & 4) != 0;
                const super = (mod_bits & 8) != 0; // Cmd on macOS
                cdp_mods = (if (shift) @as(u8, 8) else 0) |
                    (if (ctrl) @as(u8, 2) else 0) |
                    (if (alt) @as(u8, 1) else 0) |
                    (if (super) @as(u8, 4) else 0);
            }

            const key: ?Key = switch (num) {
                1 => .home,
                2 => .insert,
                3 => .delete,
                4 => .end,
                5 => .page_up,
                6 => .page_down,
                11 => .f1,
                12 => .f2,
                13 => .f3,
                14 => .f4,
                15 => .f5,
                17 => .f6,
                18 => .f7,
                19 => .f8,
                20 => .f9,
                21 => .f10,
                23 => .f11,
                24 => .f12,
                else => null,
            };

            if (key) |k| {
                return .{ .key = .{ .key = k, .modifiers = cdp_mods } };
            }
            return null;
        }

        // Kitty keyboard protocol: ESC [ code u or ESC [ code ; modifiers u
        if (self.escape_buffer[self.escape_len - 1] == 'u') {
            return try self.parseKittyKeyboard();
        }

        return null; // Incomplete
    }

    /// Parse Kitty keyboard protocol sequence (ESC [ code u or ESC [ code ; modifiers u)
    fn parseKittyKeyboard(self: *InputReader) !?Input {
        // Log the raw escape sequence for debugging
        inputDebugLog("[KITTY] Parsing: len={d} buf='{s}'", .{ self.escape_len, self.escape_buffer[0..self.escape_len] });

        // Format: ESC [ code u  or  ESC [ code ; modifiers u  or  ESC [ code ; modifiers : event-type u
        // Find semicolons and colons
        var semi_idx: ?usize = null;
        var colon_idx: ?usize = null;
        const term_idx = self.escape_len - 1; // 'u' position

        for (self.escape_buffer[2..term_idx], 0..) |byte, i| {
            if (byte == ';' and semi_idx == null) {
                semi_idx = i + 2;
            } else if (byte == ':' and colon_idx == null) {
                colon_idx = i + 2;
            }
        }

        // Parse the unicode codepoint
        const code_end = semi_idx orelse term_idx;
        const code_str = self.escape_buffer[2..code_end];
        const code = std.fmt.parseInt(u32, code_str, 10) catch return null;

        // Parse modifiers if present (1=none, 2=shift, 4=ctrl, 8=alt, etc.)
        var modifiers: u8 = 1;
        if (semi_idx) |si| {
            const mod_end = colon_idx orelse term_idx;
            const mod_str = self.escape_buffer[si + 1 .. mod_end];
            modifiers = std.fmt.parseInt(u8, mod_str, 10) catch 1;
        }

        // Parse event type if present (1=press, 2=repeat, 3=release)
        var event_type: u8 = 1; // Default: press
        if (colon_idx) |ci| {
            const event_str = self.escape_buffer[ci + 1 .. term_idx];
            event_type = std.fmt.parseInt(u8, event_str, 10) catch 1;
        }

        // Only handle key press events (event_type 1) and repeat (event_type 2)
        if (event_type == 3) return .{ .key = .{ .key = .none } }; // Ignore release events

        // Kitty protocol: raw modifier value = 1 + modifier_bits
        // Bits: 1=shift, 2=alt, 4=ctrl, 8=super (Cmd on macOS)
        const mod_bits = if (modifiers > 0) modifiers - 1 else 0;
        const shift = (mod_bits & 1) != 0;
        const alt = (mod_bits & 2) != 0;
        const ctrl = (mod_bits & 4) != 0;
        const super = (mod_bits & 8) != 0; // Cmd on macOS

        // Convert to CDP modifiers (8=shift, 2=ctrl, 1=alt, 4=meta)
        const cdp_mods: u8 = (if (shift) @as(u8, 8) else 0) |
            (if (ctrl) @as(u8, 2) else 0) |
            (if (alt) @as(u8, 1) else 0) |
            (if (super) @as(u8, 4) else 0);

        inputDebugLog("[KITTY] Parsed: code={d} char='{c}' raw_mod={d} mod_bits={d} cdp_mods={d} super={}", .{
            code,
            if (code >= 32 and code < 127) @as(u8, @intCast(code)) else '.',
            modifiers,
            mod_bits,
            cdp_mods,
            super,
        });
        return .{ .key = .{ .key = self.unicodeToKey(code, mod_bits), .modifiers = cdp_mods } };
    }

    /// Convert unicode codepoint and modifiers to Key enum
    /// modifiers should be the already-adjusted bits (raw value - 1)
    fn unicodeToKey(self: *InputReader, code: u32, mod_bits: u8) Key {
        _ = self;
        // Kitty bits: 1=shift, 2=alt, 4=ctrl, 8=super
        const shift = (mod_bits & 1) != 0;
        const alt = (mod_bits & 2) != 0;
        const ctrl = (mod_bits & 4) != 0;

        // Handle shift+tab specifically
        if (shift and code == 9) {
            return .shift_tab;
        }

        // Handle ctrl+key combinations
        if (ctrl and !alt) {
            return switch (code) {
                'a', 'A' => .ctrl_a,
                'b', 'B' => .ctrl_b,
                'c', 'C' => .ctrl_c,
                'd', 'D' => .ctrl_d,
                'e', 'E' => .ctrl_e,
                'f', 'F' => .ctrl_f,
                'g', 'G' => .ctrl_g,
                'h', 'H' => .ctrl_h,
                'i', 'I' => .ctrl_i,
                'j', 'J' => .ctrl_j,
                'k', 'K' => .ctrl_k,
                'l', 'L' => .ctrl_l,
                'm', 'M' => .ctrl_m,
                'n', 'N' => .ctrl_n,
                'o', 'O' => .ctrl_o,
                'p', 'P' => .ctrl_p,
                'q', 'Q' => .ctrl_q,
                'r', 'R' => .ctrl_r,
                's', 'S' => .ctrl_s,
                't', 'T' => .ctrl_t,
                'u', 'U' => .ctrl_u,
                'v', 'V' => .ctrl_v,
                'w', 'W' => .ctrl_w,
                'x', 'X' => .ctrl_x,
                'y', 'Y' => .ctrl_y,
                'z', 'Z' => .ctrl_z,
                else => .none,
            };
        }

        // Handle alt+key combinations
        if (alt and !ctrl) {
            if (code >= 'a' and code <= 'z') {
                return .{ .alt_char = @intCast(code) };
            }
            if (code >= 'A' and code <= 'Z') {
                return .{ .alt_char = @intCast(code + 32) }; // lowercase
            }
        }

        // Special keys
        return switch (code) {
            27 => .escape,
            9 => .tab,
            13 => .enter,
            127 => .backspace,
            8 => .backspace,
            // Arrow keys (kitty sends these as special codes)
            57416 => .up,
            57417 => .left,
            57418 => .down,
            57419 => .right,
            57423 => .home,
            57424 => .insert,
            57425 => .delete,
            57426 => .end,
            57427 => .page_up,
            57428 => .page_down,
            // Function keys
            57364 => .f1,
            57365 => .f2,
            57366 => .f3,
            57367 => .f4,
            57368 => .f5,
            57369 => .f6,
            57370 => .f7,
            57371 => .f8,
            57372 => .f9,
            57373 => .f10,
            57374 => .f11,
            57375 => .f12,
            // Regular printable characters
            else => if (code >= 32 and code <= 126)
                .{ .char = @intCast(code) }
            else
                .none,
        };
    }

    /// Parse SS3 sequence (ESC O ...)
    fn parseSS3(self: *InputReader) !?Input {
        // Need at least ESC O X (3 bytes)
        if (self.escape_len < 3) return null;

        if (self.escape_len == 3) {
            return switch (self.escape_buffer[2]) {
                'P' => .{ .key = .{ .key = .f1 } },
                'Q' => .{ .key = .{ .key = .f2 } },
                'R' => .{ .key = .{ .key = .f3 } },
                'S' => .{ .key = .{ .key = .f4 } },
                else => null,
            };
        }

        return null;
    }

    /// Parse mouse CSI sequence (ESC [ < button ; x ; y M/m)
    fn parseMouseCSI(self: *InputReader) !?Input {
        inputDebugLog("[PARSE_MOUSE] Start, escape_len={d}", .{self.escape_len});

        // Look for terminator M or m
        var term_idx: ?usize = null;
        var terminator: u8 = 0;
        for (self.escape_buffer[0..self.escape_len], 0..) |byte, i| {
            if (byte == 'M' or byte == 'm') {
                term_idx = i;
                terminator = byte;
                break;
            }
        }

        if (term_idx == null) {
            inputDebugLog("[PARSE_MOUSE] No terminator, returning null", .{});
            return null; // Incomplete
        }

        inputDebugLog("[PARSE_MOUSE] terminator at {d}", .{term_idx.?});

        // Find semicolons
        var first_semi: ?usize = null;
        var second_semi: ?usize = null;
        for (self.escape_buffer[3..term_idx.?], 0..) |byte, i| {
            if (byte == ';') {
                if (first_semi == null) {
                    first_semi = i + 3;
                } else if (second_semi == null) {
                    second_semi = i + 3;
                    break;
                }
            }
        }

        if (first_semi == null or second_semi == null) {
            inputDebugLog("[PARSE_MOUSE] Missing semicolons: semi1={?}, semi2={?}", .{ first_semi, second_semi });
            return null;
        }
        const semi1 = first_semi.?;
        const semi2 = second_semi.?;

        // Parse button;x;y (use i32 to handle negative coords near window edges)
        const button_str = self.escape_buffer[3..semi1];
        const button_code = std.fmt.parseInt(u16, button_str, 10) catch {
            inputDebugLog("[PARSE_MOUSE] Failed to parse button_code from '{s}'", .{button_str});
            return null;
        };

        const x_str = self.escape_buffer[semi1 + 1 .. semi2];
        const x_signed = std.fmt.parseInt(i32, x_str, 10) catch {
            inputDebugLog("[PARSE_MOUSE] Failed to parse x from '{s}'", .{x_str});
            return null;
        };
        // Clamp negative coordinates to 0
        const x: u16 = if (x_signed < 0) 0 else @intCast(@min(x_signed, 65535));

        const y_str = self.escape_buffer[semi2 + 1 .. term_idx.?];
        const y_signed = std.fmt.parseInt(i32, y_str, 10) catch {
            inputDebugLog("[PARSE_MOUSE] Failed to parse y from '{s}'", .{y_str});
            return null;
        };
        // Clamp negative coordinates to 0
        const y: u16 = if (y_signed < 0) 0 else @intCast(@min(y_signed, 65535));

        // Determine button and event type
        // SGR mouse protocol button_code:
        // - bits 0-1: button (0=left, 1=middle, 2=right, 3=none/release)
        // - bit 5 (32): motion flag
        // - bits 6-7 (64, 128): scroll wheel
        var button: MouseButton = .none;
        var event_type: MouseEventType = .press;
        var delta_y: i16 = 0;

        const motion_flag = (button_code & 32) != 0;
        const base_button = button_code & 3;

        // Handle wheel events (bit 6 set)
        if ((button_code & 64) != 0) {
            button = .none;
            event_type = .wheel;
            // 64 = scroll up, 65 = scroll down
            delta_y = if ((button_code & 1) == 0) -120 else 120;
        } else if (motion_flag) {
            // Motion event (bit 5 set)
            event_type = if (base_button == 3) .move else .drag;
            button = switch (base_button) {
                0 => .left,
                1 => .middle,
                2 => .right,
                else => .none,
            };
        } else {
            // Press or release
            event_type = if (terminator == 'M') .press else .release;
            button = switch (base_button) {
                0 => .left,
                1 => .middle,
                2 => .right,
                else => .none,
            };
        }

        return .{ .mouse = MouseEvent{
            .type = event_type,
            .button = button,
            .x = x,
            .y = y,
            .delta_y = delta_y,
        } };
    }

    /// Parse accumulated escape sequence
    fn parseEscapeSequence(self: *InputReader) !?Input {
        if (self.escape_len < 2) return null; // Need at least ESC + 1 char

        // Check for Alt+letter: ESC followed by single printable char
        if (self.escape_len == 2) {
            const c = self.escape_buffer[1];
            if (c >= 'a' and c <= 'z') {
                return .{ .key = .{ .key = .{ .alt_char = c } } };
            }
            if (c >= 'A' and c <= 'Z') {
                return .{ .key = .{ .key = .{ .alt_char = c } } };
            }
        }

        // Check for CSI sequences: ESC [
        if (self.escape_buffer[1] == '[') {
            return try self.parseCSI();
        }

        // Check for SS3 sequences: ESC O
        if (self.escape_buffer[1] == 'O') {
            return try self.parseSS3();
        }

        // Plain ESC key (timeout waiting for rest of sequence)
        if (self.escape_len == 1) {
            return .{ .key = .{ .key = .escape } };
        }

        return null; // Incomplete or unknown
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
            3 => return .ctrl_c,  // Ctrl+C
            6 => return .ctrl_f,  // Ctrl+F
            12 => return .ctrl_l, // Ctrl+L
            17 => return .ctrl_q, // Ctrl+Q
            18 => return .ctrl_r, // Ctrl+R
            23 => return .ctrl_w, // Ctrl+W
            27 => {
                // Escape or escape sequence
                if (n == 1) return .escape;

                // Parse escape sequences
                if (n >= 3 and self.buffer[1] == '[') {
                    // Multi-byte sequences: ESC [ N ~
                    if (n >= 4 and self.buffer[3] == '~') {
                        return switch (self.buffer[2]) {
                            '5' => .page_up,
                            '6' => .page_down,
                            else => .{ .char = c },
                        };
                    }
                    // Single-char sequences: ESC [ X
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

    /// Read next input event (keyboard or mouse) with byte accumulation
    pub fn readInput(self: *InputReader) !Input {
        // Only read new bytes if buffer is empty or we're not in the middle of processing
        if (self.buffer_len == 0) {
            // Read available bytes into buffer
            const n = std.posix.read(self.fd, self.buffer[self.buffer_len..]) catch |err| {
                if (err == error.WouldBlock) {
                    // No new data, but check if we have buffered escape sequence
                    if (self.in_escape and self.escape_len > 0) {
                        // Timeout waiting for rest of sequence - treat as ESC key
                        self.in_escape = false;
                        self.escape_len = 0;
                        return .{ .key = .{ .key = .escape } };
                    }
                    return .none;
                }
                // DEBUG LOG ERROR
                std.debug.print("[INPUT ERROR] read failed: {}\n", .{err});
                return err;
            };

            if (n == 0) return .none;

            self.buffer_len += n;

            // DEBUG LOG
            self.debugLog("[INPUT] Read {d} bytes, buffer_len now {d}, in_escape={}, escape_len={d}\n", .{n, self.buffer_len, self.in_escape, self.escape_len});
        } else {
            // We have buffered bytes, process them first
            self.debugLog("[INPUT] Processing buffered bytes, buffer_len={d}\n", .{self.buffer_len});
        }

        // Process one byte at a time from the buffer
        while (self.buffer_len > 0) {
            const c = self.buffer[0];
            self.debugLog("[INPUT] Processing byte: {d} ('{c}'), buffer_len={d}\n", .{c, if (c >= 32 and c <= 126) c else '.', self.buffer_len});

            if (self.in_escape) {
                // Accumulating escape sequence
                if (self.escape_len >= self.escape_buffer.len) {
                    // Buffer overflow - reset and skip
                    self.in_escape = false;
                    self.escape_len = 0;
                    if (self.buffer_len > 1) {
                        std.mem.copyForwards(u8, self.buffer[0..self.buffer_len - 1], self.buffer[1..self.buffer_len]);
                    }
                    self.buffer_len -= 1;
                    continue;
                }

                // Add byte to escape sequence
                self.escape_buffer[self.escape_len] = c;
                self.escape_len += 1;

                // Remove from main buffer
                if (self.buffer_len > 1) {
                    std.mem.copyForwards(u8, self.buffer[0..self.buffer_len - 1], self.buffer[1..self.buffer_len]);
                }
                self.buffer_len -= 1;

                // Try to parse what we have
                if (try self.parseEscapeSequence()) |input| {
                    // Complete sequence parsed
                    inputDebugLog("[RESET] Parsed input, resetting escape_len from {d} to 0", .{self.escape_len});
                    self.in_escape = false;
                    self.escape_len = 0;
                    return input;
                }

                // Incomplete - continue accumulating
                continue;
            }

            // Not in escape sequence
            if (c == 27) {
                // Start of escape sequence
                self.in_escape = true;
                self.escape_buffer[0] = 27;
                self.escape_len = 1;

                // Remove from main buffer
                if (self.buffer_len > 1) {
                    std.mem.copyForwards(u8, self.buffer[0..self.buffer_len - 1], self.buffer[1..self.buffer_len]);
                }
                self.buffer_len -= 1;
                continue;
            }

            // If in paste mode, accumulate bytes instead of processing them
            if (self.in_paste) {
                self.paste_buffer.append(self.allocator, c) catch {};
                // Remove from main buffer
                if (self.buffer_len > 1) {
                    std.mem.copyForwards(u8, self.buffer[0..self.buffer_len - 1], self.buffer[1..self.buffer_len]);
                }
                self.buffer_len -= 1;
                continue; // Keep accumulating
            }

            // Regular character or control code
            inputDebugLog("[KEY] Single byte: 0x{x} ('{c}')", .{ c, if (c >= 32 and c < 127) c else '.' });
            const key = try self.parseSingleByte(c);
            self.debugLog("[INPUT] Parsed single byte to key, returning\n", .{});
            // Log any printable chars being output (potential mouse leak)
            if (c >= '0' and c <= '9') {
                inputDebugLog("[LEAK?] Digit char: '{c}' (0x{x})", .{ c, c });
            } else if (c == ';') {
                inputDebugLog("[LEAK?] Semicolon char", .{});
            } else if (c == 'M' or c == 'm') {
                inputDebugLog("[LEAK?] M/m char", .{});
            }

            // Remove from buffer
            if (self.buffer_len > 1) {
                std.mem.copyForwards(u8, self.buffer[0..self.buffer_len - 1], self.buffer[1..self.buffer_len]);
            }
            self.buffer_len -= 1;
            self.debugLog("[INPUT] After return, buffer_len={d}\n", .{self.buffer_len});

            return .{ .key = .{ .key = key } };
        }

        // Processed all bytes but no complete input (accumulating escape)
        self.debugLog("[INPUT] Processed all bytes, returning .none\n", .{});
        return .none;
    }

};
