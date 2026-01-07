const std = @import("std");

pub const Key = union(enum) {
    char: u8,

    // Control keys
    escape,
    tab,
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
    key: Key,
    mouse: MouseEvent,
    none,
};

pub const InputReader = struct {
    fd: std.posix.fd_t,
    buffer: [256]u8,  // Increased for accumulation
    buffer_len: usize,  // Track accumulated bytes
    mouse_enabled: bool,
    debug_input: bool,

    // State for multi-byte sequences
    in_escape: bool,
    escape_buffer: [64]u8,
    escape_len: usize,

    pub fn init(fd: std.posix.fd_t, debug_input: bool) InputReader {
        return .{
            .fd = fd,
            .buffer = undefined,
            .buffer_len = 0,
            .mouse_enabled = false,
            .debug_input = debug_input,
            .in_escape = false,
            .escape_buffer = undefined,
            .escape_len = 0,
        };
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

        // Simple cursor keys: ESC [ A/B/C/D
        if (self.escape_len == 3) {
            return switch (self.escape_buffer[2]) {
                'A' => .{ .key = .up },
                'B' => .{ .key = .down },
                'C' => .{ .key = .right },
                'D' => .{ .key = .left },
                else => null,
            };
        }

        // Mouse: ESC [ < ... M/m
        if (self.escape_buffer[2] == '<') {
            if (self.mouse_enabled) {
                return try self.parseMouseCSI();
            }
            return null;
        }

        // Function/nav keys: ESC [ N ~
        // Look for terminating ~
        if (self.escape_buffer[self.escape_len - 1] == '~') {
            const num_start = 2;
            const num_end = self.escape_len - 1;
            const num_str = self.escape_buffer[num_start..num_end];
            const num = std.fmt.parseInt(u8, num_str, 10) catch return null;

            return switch (num) {
                1 => .{ .key = .home },
                2 => .{ .key = .insert },
                3 => .{ .key = .delete },
                4 => .{ .key = .end },
                5 => .{ .key = .page_up },
                6 => .{ .key = .page_down },
                11 => .{ .key = .f1 },
                12 => .{ .key = .f2 },
                13 => .{ .key = .f3 },
                14 => .{ .key = .f4 },
                15 => .{ .key = .f5 },
                17 => .{ .key = .f6 },
                18 => .{ .key = .f7 },
                19 => .{ .key = .f8 },
                20 => .{ .key = .f9 },
                21 => .{ .key = .f10 },
                23 => .{ .key = .f11 },
                24 => .{ .key = .f12 },
                else => null,
            };
        }

        // Kitty keyboard protocol: ESC [ code u or ESC [ code ; modifiers u
        if (self.escape_buffer[self.escape_len - 1] == 'u') {
            return try self.parseKittyKeyboard();
        }

        return null; // Incomplete
    }

    /// Parse Kitty keyboard protocol sequence (ESC [ code u or ESC [ code ; modifiers u)
    fn parseKittyKeyboard(self: *InputReader) !?Input {
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
        if (event_type == 3) return .{ .key = .none }; // Ignore release events

        // Map unicode codepoint to Key
        return .{ .key = self.unicodeToKey(code, modifiers) };
    }

    /// Convert unicode codepoint and modifiers to Key enum
    fn unicodeToKey(self: *InputReader, code: u32, modifiers: u8) Key {
        _ = self;
        const shift = (modifiers & 2) != 0;
        const ctrl = (modifiers & 4) != 0;
        const alt = (modifiers & 8) != 0;
        _ = shift;

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
                'P' => .{ .key = .f1 },
                'Q' => .{ .key = .f2 },
                'R' => .{ .key = .f3 },
                'S' => .{ .key = .f4 },
                else => null,
            };
        }

        return null;
    }

    /// Parse mouse CSI sequence (ESC [ < button ; x ; y M/m)
    fn parseMouseCSI(self: *InputReader) !?Input {
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

        if (term_idx == null) return null; // Incomplete

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

        const semi1 = first_semi orelse return null;
        const semi2 = second_semi orelse return null;

        // Parse button;x;y
        const button_str = self.escape_buffer[3..semi1];
        const button_code = std.fmt.parseInt(u16, button_str, 10) catch return null;

        const x_str = self.escape_buffer[semi1 + 1 .. semi2];
        const x = std.fmt.parseInt(u16, x_str, 10) catch return null;

        const y_str = self.escape_buffer[semi2 + 1 .. term_idx.?];
        const y = std.fmt.parseInt(u16, y_str, 10) catch return null;

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
                return .{ .key = .{ .alt_char = c } };
            }
            if (c >= 'A' and c <= 'Z') {
                return .{ .key = .{ .alt_char = c } };
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
            return .{ .key = .escape };
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
                        return .{ .key = .escape };
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

            // Regular character or control code
            const key = try self.parseSingleByte(c);
            self.debugLog("[INPUT] Parsed single byte to key, returning\n", .{});

            // Remove from buffer
            if (self.buffer_len > 1) {
                std.mem.copyForwards(u8, self.buffer[0..self.buffer_len - 1], self.buffer[1..self.buffer_len]);
            }
            self.buffer_len -= 1;
            self.debugLog("[INPUT] After return, buffer_len={d}\n", .{self.buffer_len});

            return .{ .key = key };
        }

        // Processed all bytes but no complete input (accumulating escape)
        self.debugLog("[INPUT] Processed all bytes, returning .none\n", .{});
        return .none;
    }

};
