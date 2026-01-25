/// Keyboard input handling for the viewer.
/// Handles key events in normal and URL prompt modes.
const std = @import("std");
const builtin = @import("builtin");
const input_mod = @import("../terminal/input.zig");
const key_normalizer = @import("../terminal/key_normalizer.zig");
const app_shortcuts = @import("../app_shortcuts.zig");
const interact_mod = @import("../chrome/interact.zig");
const screenshot_api = @import("../chrome/screenshot.zig");
const prompt_mod = @import("../terminal/prompt.zig");
const mouse_handler = @import("mouse_handler.zig");

const Input = input_mod.Input;
const NormalizedKeyEvent = key_normalizer.NormalizedKeyEvent;
const AppAction = app_shortcuts.AppAction;
const PromptBuffer = prompt_mod.PromptBuffer;

/// Handle input event - dispatches to key or mouse handlers
pub fn handleInput(viewer: anytype, input: Input) !void {
    switch (input) {
        .key => |key_input| {
            // 1. Normalize the key input to unified representation
            const event = key_normalizer.normalize(key_input);

            // Debug log (if enabled)
            if (viewer.debug_input) {
                if (event.base_key.getChar()) |c| {
                    viewer.log("[KEY] char='{c}' shift={} ctrl={} alt={} meta={} shortcut={} cdp={d}\n", .{
                        c, event.shift, event.ctrl, event.alt, event.meta, event.shortcut_mod, event.cdp_modifiers,
                    });
                } else {
                    viewer.log("[KEY] special={} shift={} ctrl={} alt={} meta={} shortcut={} cdp={d}\n", .{
                        event.base_key, event.shift, event.ctrl, event.alt, event.meta, event.shortcut_mod, event.cdp_modifiers,
                    });
                }
            }

            // 2. Check for global app shortcuts (work from ANY mode)
            if (app_shortcuts.findAppAction(event)) |action| {
                // Check if action is disabled
                if (isActionDisabled(viewer, action)) {
                    viewer.log("[SHORTCUT] Action disabled: {s}\n", .{@tagName(action)});
                    // Pass key through to browser if not quit
                    if (action != .quit) {
                        try handleNormalModeKey(viewer, event);
                    }
                    return;
                }
                viewer.log("[SHORTCUT] Matched action: {s}\n", .{@tagName(action)});
                try executeAppAction(viewer, action, event);
                return;
            } else if (event.shortcut_mod) {
                // Log unmatched shortcut keys for debugging
                if (event.base_key.getChar()) |c| {
                    viewer.log("[SHORTCUT] Unmatched: char='{c}' shift={} alt={}\n", .{ c, event.shift, event.alt });
                }
            }

            // 3. Mode-specific handling
            switch (viewer.mode) {
                .normal => try handleNormalModeKey(viewer, event),
                .url_prompt => try handleUrlPromptKey(viewer, event),
                .hint_mode => try handleHintModeKey(viewer, event),
            }
        },
        .mouse => |mouse| try mouse_handler.handleMouse(viewer, mouse),
        .paste => |text| {
            defer viewer.allocator.free(text);
            // Terminal sent bracketed paste (Cmd+V intercepted by terminal)
            if (viewer.mode == .normal) {
                // Use typeText for reliable direct text insertion (works with Monaco)
                interact_mod.typeText(viewer.cdp_client, viewer.allocator, text) catch {};
            } else if (viewer.mode == .url_prompt) {
                // Paste into URL bar
                if (viewer.toolbar_renderer) |*renderer| {
                    // Insert text at cursor (filter non-printable chars)
                    for (text) |c| {
                        if (c >= 32 and c <= 126 and c != '\n' and c != '\r') {
                            renderer.handleChar(c);
                        }
                    }
                    viewer.ui_dirty = true;
                }
            }
        },
        .none => {},
    }
}

/// Execute an app-level action (shortcuts intercepted by termweb)
pub fn executeAppAction(viewer: anytype, action: AppAction, event: NormalizedKeyEvent) !void {
    _ = event;
    const toolbar = @import("../ui/toolbar.zig");

    switch (action) {
        .quit => {
            viewer.running = false;
        },
        .address_bar => {
            viewer.mode = .url_prompt;
            if (viewer.toolbar_renderer) |*renderer| {
                renderer.setUrl(viewer.current_url);
                renderer.focusUrl();
            } else {
                viewer.prompt_buffer = try PromptBuffer.init(viewer.allocator);
            }
            viewer.ui_dirty = true;
        },
        .reload => {
            // Reset screencast to recover from any broken state
            viewer.resetScreencast();
            try screenshot_api.reload(viewer.cdp_client, viewer.allocator, false);
            viewer.ui_state.is_loading = true;
            if (viewer.toolbar_renderer) |*tr| {
                tr.is_loading = true;
            }
            viewer.loading_started_at = std.time.nanoTimestamp();
            viewer.ui_dirty = true;
        },
        .copy => {
            if (viewer.mode == .url_prompt) {
                if (viewer.toolbar_renderer) |*renderer| {
                    renderer.handleCopy(viewer.allocator);
                }
            } else {
                // Use execCommand('copy') - same as menu copy, triggers polyfill
                interact_mod.execCopy(viewer.cdp_client);
            }
        },
        .cut => {
            if (viewer.mode == .url_prompt) {
                if (viewer.toolbar_renderer) |*renderer| {
                    renderer.handleCut(viewer.allocator);
                    viewer.ui_dirty = true;
                }
            } else {
                // Dispatch Cmd+X event + execCommand('cut')
                interact_mod.execCut(viewer.cdp_client);
            }
        },
        .paste => {
            if (viewer.mode == .url_prompt) {
                if (viewer.toolbar_renderer) |*renderer| {
                    renderer.handlePaste(viewer.allocator);
                    viewer.ui_dirty = true;
                }
            } else {
                // Get system clipboard and insert via synthetic ClipboardEvent
                // typeText clears _termwebClipboardData atomically before dispatch
                if (toolbar.pasteFromClipboard(viewer.allocator)) |clipboard| {
                    defer viewer.allocator.free(clipboard);
                    viewer.log("[PASTE] Direct insert: {d} bytes\n", .{clipboard.len});
                    interact_mod.typeText(viewer.cdp_client, viewer.allocator, clipboard) catch {};
                }
            }
        },
        .select_all => {
            if (viewer.mode == .url_prompt) {
                if (viewer.toolbar_renderer) |*renderer| {
                    renderer.handleSelectAll();
                    viewer.ui_dirty = true;
                }
            } else {
                // Send Cmd+A to browser for select-all
                viewer.log("[SELECT_ALL] Sending Cmd+A to browser\n", .{});
                interact_mod.sendCharWithModifiers(viewer.cdp_client, viewer.allocator, 'a', 4); // 4 = meta
            }
        },
        .tab_picker => {
            viewer.showTabPicker() catch |err| {
                viewer.log("[TAB_PICKER] Failed: {}\n", .{err});
            };
        },
        .enter_hint_mode => {
            viewer.enterHintMode() catch |err| {
                viewer.log("[HINT] Failed to enter hint mode: {}\n", .{err});
            };
        },
        .go_back => {
            viewer.log("[NAV] Go back (Cmd+[)\n", .{});
            _ = screenshot_api.goBack(viewer.cdp_client, viewer.allocator) catch |err| {
                viewer.log("[NAV] Back failed: {}\n", .{err});
            };
            viewer.ui_state.is_loading = true;
            if (viewer.toolbar_renderer) |*tr| {
                tr.is_loading = true;
            }
            viewer.loading_started_at = std.time.nanoTimestamp();
            viewer.ui_dirty = true;
        },
        .go_forward => {
            viewer.log("[NAV] Go forward (Cmd+])\n", .{});
            _ = screenshot_api.goForward(viewer.cdp_client, viewer.allocator) catch |err| {
                viewer.log("[NAV] Forward failed: {}\n", .{err});
            };
            viewer.ui_state.is_loading = true;
            if (viewer.toolbar_renderer) |*tr| {
                tr.is_loading = true;
            }
            viewer.loading_started_at = std.time.nanoTimestamp();
            viewer.ui_dirty = true;
        },
        .stop_loading => {
            viewer.log("[NAV] Stop loading (Ctrl+.)\n", .{});
            screenshot_api.stopLoading(viewer.cdp_client, viewer.allocator) catch |err| {
                viewer.log("[NAV] Stop failed: {}\n", .{err});
            };
            // Reset screencast to recover from any broken state (like reload)
            viewer.resetScreencast();
            viewer.ui_state.is_loading = false;
            if (viewer.toolbar_renderer) |*tr| {
                tr.is_loading = false;
            }
            viewer.ui_dirty = true;
        },
        .scroll_down => {
            // Scroll down by ~150 pixels (instant for fast hold-to-scroll)
            interact_mod.scroll(viewer.cdp_client, viewer.allocator, 0, 150) catch |err| {
                viewer.log("[SCROLL] Down failed: {}\n", .{err});
            };
        },
        .scroll_up => {
            // Scroll up by ~150 pixels (instant for fast hold-to-scroll)
            interact_mod.scroll(viewer.cdp_client, viewer.allocator, 0, -150) catch |err| {
                viewer.log("[SCROLL] Up failed: {}\n", .{err});
            };
        },
        .dev_console => {
            // Send F12 to Chrome to toggle DevTools
            viewer.log("[DEV] Opening DevTools (F12)\n", .{});
            interact_mod.sendSpecialKeyWithModifiers(viewer.cdp_client, "F12", 123, 0);
        },
    }
}

/// Handle key in normal mode - pass to browser with correct modifiers
pub fn handleNormalModeKey(viewer: anytype, event: NormalizedKeyEvent) !void {
    const mods = event.cdp_modifiers;

    switch (event.base_key) {
        .char => |c| {
            // Translate Ctrl+Shift+P to Cmd+Shift+P for VSCode command palette
            if (event.ctrl and event.shift and (c == 'p' or c == 'P')) {
                const new_mods = (mods & ~@as(u8, 2)) | 4; // remove ctrl, add meta
                interact_mod.sendCharWithModifiers(viewer.cdp_client, viewer.allocator, 'p', new_mods);
            } else {
                // Pass to browser with original modifiers
                interact_mod.sendCharWithModifiers(viewer.cdp_client, viewer.allocator, c, mods);
            }
        },
        .escape => interact_mod.sendSpecialKeyWithModifiers(viewer.cdp_client, "Escape", 27, mods),
        .enter => interact_mod.sendEnterKey(viewer.cdp_client, mods),
        .backspace => interact_mod.sendSpecialKeyWithModifiers(viewer.cdp_client, "Backspace", 8, mods),
        .tab => interact_mod.sendSpecialKeyWithModifiers(viewer.cdp_client, "Tab", 9, mods),
        .delete => interact_mod.sendSpecialKeyWithModifiers(viewer.cdp_client, "Delete", 46, mods),
        .left => interact_mod.sendSpecialKeyWithModifiers(viewer.cdp_client, "ArrowLeft", 37, mods),
        .right => interact_mod.sendSpecialKeyWithModifiers(viewer.cdp_client, "ArrowRight", 39, mods),
        .up => interact_mod.sendSpecialKeyWithModifiers(viewer.cdp_client, "ArrowUp", 38, mods),
        .down => interact_mod.sendSpecialKeyWithModifiers(viewer.cdp_client, "ArrowDown", 40, mods),
        .home => interact_mod.sendSpecialKeyWithModifiers(viewer.cdp_client, "Home", 36, mods),
        .end => interact_mod.sendSpecialKeyWithModifiers(viewer.cdp_client, "End", 35, mods),
        .page_up => interact_mod.sendSpecialKeyWithModifiers(viewer.cdp_client, "PageUp", 33, mods),
        .page_down => interact_mod.sendSpecialKeyWithModifiers(viewer.cdp_client, "PageDown", 34, mods),
        .insert => interact_mod.sendSpecialKeyWithModifiers(viewer.cdp_client, "Insert", 45, mods),
        .f1 => interact_mod.sendSpecialKeyWithModifiers(viewer.cdp_client, "F1", 112, mods),
        .f2 => interact_mod.sendSpecialKeyWithModifiers(viewer.cdp_client, "F2", 113, mods),
        .f3 => interact_mod.sendSpecialKeyWithModifiers(viewer.cdp_client, "F3", 114, mods),
        .f4 => interact_mod.sendSpecialKeyWithModifiers(viewer.cdp_client, "F4", 115, mods),
        .f5 => interact_mod.sendSpecialKeyWithModifiers(viewer.cdp_client, "F5", 116, mods),
        .f6 => interact_mod.sendSpecialKeyWithModifiers(viewer.cdp_client, "F6", 117, mods),
        .f7 => interact_mod.sendSpecialKeyWithModifiers(viewer.cdp_client, "F7", 118, mods),
        .f8 => interact_mod.sendSpecialKeyWithModifiers(viewer.cdp_client, "F8", 119, mods),
        .f9 => interact_mod.sendSpecialKeyWithModifiers(viewer.cdp_client, "F9", 120, mods),
        .f10 => interact_mod.sendSpecialKeyWithModifiers(viewer.cdp_client, "F10", 121, mods),
        .f11 => interact_mod.sendSpecialKeyWithModifiers(viewer.cdp_client, "F11", 122, mods),
        .f12 => interact_mod.sendSpecialKeyWithModifiers(viewer.cdp_client, "F12", 123, mods),
        .none => {},
    }
}

/// Handle key in URL prompt mode - text editing
pub fn handleUrlPromptKey(viewer: anytype, event: NormalizedKeyEvent) !void {
    const renderer = if (viewer.toolbar_renderer) |*r| r else return;

    // Word navigation: Ctrl+arrow (or Alt+arrow on macOS for compatibility)
    // Line navigation: Cmd+arrow on macOS
    const is_macos = comptime builtin.os.tag == .macos;
    const word_nav = event.ctrl or (is_macos and event.alt);
    const line_nav = if (is_macos) event.meta else false;

    // Debug: log arrow key with modifiers
    if (event.base_key == .left or event.base_key == .right) {
        viewer.log("[URL KEY] arrow={s} ctrl={} alt={} shift={} word_nav={}\n", .{
            @tagName(event.base_key), event.ctrl, event.alt, event.shift, word_nav,
        });
    }

    switch (event.base_key) {
        .char => |c| {
            // macOS sends ESC+b/f for Alt+Left/Right (readline-style word navigation)
            if (event.alt) {
                switch (c) {
                    'b', 'B' => {
                        if (event.shift) {
                            renderer.handleSelectWordLeft();
                        } else {
                            renderer.handleWordLeft();
                        }
                        viewer.ui_dirty = true;
                        return;
                    },
                    'f', 'F' => {
                        if (event.shift) {
                            renderer.handleSelectWordRight();
                        } else {
                            renderer.handleWordRight();
                        }
                        viewer.ui_dirty = true;
                        return;
                    },
                    else => {},
                }
            }
            renderer.handleChar(c);
            viewer.ui_dirty = true;
        },
        .backspace => {
            renderer.handleBackspace();
            viewer.ui_dirty = true;
        },
        .delete => {
            renderer.handleDelete();
            viewer.ui_dirty = true;
        },
        .left => {
            if (event.shift and word_nav) {
                renderer.handleSelectWordLeft();
            } else if (event.shift) {
                renderer.handleSelectLeft();
            } else if (line_nav) {
                renderer.handleHome();
            } else if (word_nav) {
                renderer.handleWordLeft();
            } else {
                renderer.handleLeft();
            }
            viewer.ui_dirty = true;
        },
        .right => {
            if (event.shift and word_nav) {
                renderer.handleSelectWordRight();
            } else if (event.shift) {
                renderer.handleSelectRight();
            } else if (line_nav) {
                renderer.handleEnd();
            } else if (word_nav) {
                renderer.handleWordRight();
            } else {
                renderer.handleRight();
            }
            viewer.ui_dirty = true;
        },
        .home => {
            if (event.shift) {
                renderer.handleSelectHome();
            } else {
                renderer.handleHome();
            }
            viewer.ui_dirty = true;
        },
        .end => {
            if (event.shift) {
                renderer.handleSelectEnd();
            } else {
                renderer.handleEnd();
            }
            viewer.ui_dirty = true;
        },
        .enter => {
            const url = renderer.getUrlText();
            viewer.log("[URL] Enter pressed, url_len={}, url='{s}'\n", .{ url.len, url });
            if (url.len > 0) {
                // Copy URL before blurring (blur may clear the buffer)
                const url_copy = viewer.allocator.dupe(u8, url) catch {
                    viewer.log("[URL] Failed to allocate URL copy\n", .{});
                    renderer.blurUrl();
                    viewer.mode = .normal;
                    viewer.ui_dirty = true;
                    return;
                };

                // Blur first to exit URL mode
                renderer.blurUrl();
                viewer.mode = .normal;

                // Show loading indicator immediately
                viewer.ui_state.is_loading = true;
                if (viewer.toolbar_renderer) |*tr| {
                    tr.is_loading = true;
                }
                viewer.loading_started_at = std.time.nanoTimestamp();
                viewer.ui_dirty = true;

                viewer.log("[URL] Navigating to: {s}\n", .{url_copy});
                screenshot_api.navigateToUrl(viewer.cdp_client, viewer.allocator, url_copy) catch |err| {
                    viewer.log("[URL] Navigation failed: {}\n", .{err});
                    viewer.allocator.free(url_copy);
                    return;
                };

                // Update viewer's current URL
                viewer.allocator.free(viewer.current_url);
                viewer.current_url = url_copy;

                // Update active tab's URL
                if (viewer.active_tab_index < viewer.tabs.items.len) {
                    viewer.tabs.items[viewer.active_tab_index].updateUrl(url_copy) catch {};
                }

                viewer.forceUpdateNavigationState();
            } else {
                renderer.blurUrl();
                viewer.mode = .normal;
                viewer.ui_dirty = true;
            }
        },
        .escape => {
            renderer.blurUrl();
            viewer.mode = .normal;
            viewer.ui_dirty = true;
        },
        else => {},
    }
}

/// Handle key in hint mode - type letters to click at hint location
pub fn handleHintModeKey(viewer: anytype, event: NormalizedKeyEvent) !void {
    switch (event.base_key) {
        .escape => {
            viewer.exitHintMode();
        },
        .char => |c| {
            if (std.ascii.isAlphabetic(c)) {
                const lower = std.ascii.toLower(c);
                if (viewer.hint_grid) |grid| {
                    // Record input time for timeout-based auto-selection
                    viewer.hint_last_input_time = std.time.nanoTimestamp();

                    if (grid.addChar(lower)) |hint| {
                        // Found a unique match - click at hint location
                        viewer.log("[HINT] Clicking at ({}, {})\n", .{ hint.browser_x, hint.browser_y });
                        try interact_mod.clickAt(
                            viewer.cdp_client,
                            viewer.allocator,
                            hint.browser_x,
                            hint.browser_y,
                        );
                        viewer.exitHintMode();
                    } else {
                        // Partial match - re-render badges via background thread
                        viewer.ui_dirty = true;
                        viewer.requestHintRender();
                    }
                }
            }
        },
        else => {},
    }
}

/// Check if an app action is disabled based on viewer settings
fn isActionDisabled(viewer: anytype, action: AppAction) bool {
    // Quit is always allowed
    if (action == .quit) return false;

    // If hotkeys are disabled, block all shortcuts except quit
    if (viewer.hotkeys_disabled) return true;

    // If hints are disabled, block hint mode
    if (viewer.hints_disabled and action == .enter_hint_mode) return true;

    // If devtools is disabled, block dev_console
    if (viewer.devtools_disabled and action == .dev_console) return true;

    // If toolbar is disabled, block navigation actions
    if (viewer.toolbar_disabled) {
        switch (action) {
            .address_bar, .go_back, .go_forward, .stop_loading, .reload => return true,
            else => {},
        }
    }

    return false;
}
