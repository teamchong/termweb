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
            try screenshot_api.reload(viewer.cdp_client, viewer.allocator, false);
            // Screencast mode: frames arrive automatically after reload
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

    // Platform-specific navigation modifiers
    const is_macos = comptime builtin.os.tag == .macos;
    const word_nav = if (is_macos) event.alt else event.ctrl;
    const line_nav = if (is_macos) event.meta else false;

    switch (event.base_key) {
        .char => |c| {
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
            if (event.shift) {
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
            if (event.shift) {
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

                // Show loading indicator
                if (viewer.toolbar_renderer) |*tr| {
                    tr.is_loading = true;
                }

                viewer.log("[URL] Navigating to: {s}\n", .{url_copy});
                screenshot_api.navigateToUrl(viewer.cdp_client, viewer.allocator, url_copy) catch |err| {
                    viewer.log("[URL] Navigation failed: {}\n", .{err});
                    viewer.allocator.free(url_copy);
                    viewer.ui_dirty = true;
                    return;
                };

                // Update viewer's current URL
                viewer.allocator.free(viewer.current_url);
                viewer.current_url = url_copy;

                // Update active tab's URL
                if (viewer.active_tab_index < viewer.tabs.items.len) {
                    viewer.tabs.items[viewer.active_tab_index].updateUrl(url_copy) catch {};
                }

                viewer.updateNavigationState();
            } else {
                renderer.blurUrl();
                viewer.mode = .normal;
            }
            viewer.ui_dirty = true;
        },
        .escape => {
            renderer.blurUrl();
            viewer.mode = .normal;
            viewer.ui_dirty = true;
        },
        else => {},
    }
}
