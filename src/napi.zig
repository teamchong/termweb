const std = @import("std");
const build_options = @import("build_options");
const config = @import("config.zig").Config;

const detector = @import("chrome/detector.zig");
const launcher = @import("chrome/launcher.zig");
const cdp = @import("chrome/cdp_client.zig");
const screenshot_api = @import("chrome/screenshot.zig");
const terminal_mod = @import("terminal/terminal.zig");
const viewer_mod = @import("viewer.zig");
const toolbar_mod = @import("ui/toolbar.zig");
const cdp_events = @import("viewer/cdp_events.zig");

const VERSION = build_options.version;

// Node-API types
const napi_env = *opaque {};
const napi_value = *opaque {};
const napi_callback_info = *opaque {};
const napi_async_work = *opaque {};
const napi_threadsafe_function = *opaque {};
const napi_ref = *opaque {};

const napi_status = enum(c_int) {
    ok = 0,
    invalid_arg = 1,
    object_expected = 2,
    string_expected = 3,
    name_expected = 4,
    function_expected = 5,
    number_expected = 6,
    boolean_expected = 7,
    array_expected = 8,
    generic_failure = 9,
    pending_exception = 10,
    cancelled = 11,
    escape_called_twice = 12,
    handle_scope_mismatch = 13,
    callback_scope_mismatch = 14,
    queue_full = 15,
    closing = 16,
    bigint_expected = 17,
    date_expected = 18,
    arraybuffer_expected = 19,
    detachable_arraybuffer_expected = 20,
    would_deadlock = 21,
};

// Node-API function declarations
extern fn napi_create_string_utf8(env: napi_env, str: [*]const u8, length: usize, result: *napi_value) napi_status;
extern fn napi_create_int32(env: napi_env, value: i32, result: *napi_value) napi_status;
extern fn napi_create_uint32(env: napi_env, value: u32, result: *napi_value) napi_status;
extern fn napi_create_double(env: napi_env, value: f64, result: *napi_value) napi_status;
extern fn napi_create_object(env: napi_env, result: *napi_value) napi_status;
extern fn napi_create_function(env: napi_env, utf8name: ?[*:0]const u8, length: usize, cb: *const fn (napi_env, napi_callback_info) callconv(.c) napi_value, data: ?*anyopaque, result: *napi_value) napi_status;
extern fn napi_set_named_property(env: napi_env, object: napi_value, utf8name: [*:0]const u8, value: napi_value) napi_status;
extern fn napi_get_cb_info(env: napi_env, cbinfo: napi_callback_info, argc: *usize, argv: ?[*]napi_value, this_arg: ?*napi_value, data: ?*?*anyopaque) napi_status;
extern fn napi_get_value_string_utf8(env: napi_env, value: napi_value, buf: ?[*]u8, bufsize: usize, result: *usize) napi_status;
extern fn napi_get_value_bool(env: napi_env, value: napi_value, result: *bool) napi_status;
extern fn napi_get_value_double(env: napi_env, value: napi_value, result: *f64) napi_status;
extern fn napi_get_named_property(env: napi_env, object: napi_value, utf8name: [*:0]const u8, result: *napi_value) napi_status;
extern fn napi_is_array(env: napi_env, value: napi_value, result: *bool) napi_status;
extern fn napi_get_array_length(env: napi_env, value: napi_value, result: *u32) napi_status;
extern fn napi_get_element(env: napi_env, object: napi_value, index: u32, result: *napi_value) napi_status;
extern fn napi_typeof(env: napi_env, value: napi_value, result: *c_uint) napi_status;
extern fn napi_get_undefined(env: napi_env, result: *napi_value) napi_status;
extern fn napi_get_boolean(env: napi_env, value: bool, result: *napi_value) napi_status;
extern fn napi_throw_error(env: napi_env, code: ?[*:0]const u8, msg: [*:0]const u8) napi_status;

// Async work APIs
extern fn napi_create_async_work(env: napi_env, async_resource: ?napi_value, async_resource_name: napi_value, execute: *const fn (?napi_env, ?*anyopaque) callconv(.c) void, complete: *const fn (napi_env, napi_status, ?*anyopaque) callconv(.c) void, data: ?*anyopaque, result: *napi_async_work) napi_status;
extern fn napi_delete_async_work(env: napi_env, work: napi_async_work) napi_status;
extern fn napi_queue_async_work(env: napi_env, work: napi_async_work) napi_status;

// Threadsafe function APIs
const napi_threadsafe_function_call_mode = enum(c_int) { nonblocking = 0, blocking = 1 };
extern fn napi_create_threadsafe_function(env: napi_env, func: ?napi_value, async_resource: ?napi_value, async_resource_name: napi_value, max_queue_size: usize, initial_thread_count: usize, thread_finalize_data: ?*anyopaque, thread_finalize_cb: ?*const fn (napi_env, ?*anyopaque, ?*anyopaque) callconv(.c) void, context: ?*anyopaque, call_js_cb: ?*const fn (napi_env, napi_value, ?*anyopaque, ?*anyopaque) callconv(.c) void, result: *napi_threadsafe_function) napi_status;
extern fn napi_call_threadsafe_function(func: napi_threadsafe_function, data: ?*anyopaque, mode: napi_threadsafe_function_call_mode) napi_status;
extern fn napi_release_threadsafe_function(func: napi_threadsafe_function, mode: c_int) napi_status;
extern fn napi_acquire_threadsafe_function(func: napi_threadsafe_function) napi_status;

// Reference APIs
extern fn napi_create_reference(env: napi_env, value: napi_value, initial_refcount: u32, result: *napi_ref) napi_status;
extern fn napi_delete_reference(env: napi_env, ref: napi_ref) napi_status;
extern fn napi_get_reference_value(env: napi_env, ref: napi_ref, result: *napi_value) napi_status;

const napi_valuetype = enum(c_uint) {
    undefined = 0,
    null = 1,
    boolean = 2,
    number = 3,
    string = 4,
    symbol = 5,
    object = 6,
    function = 7,
    external = 8,
    bigint = 9,
};

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

// Global viewer instance for async mode (only one viewer at a time)
var active_viewer: ?*viewer_mod.Viewer = null;
var viewer_mutex = std.Thread.Mutex{};
var console_callback: ?napi_threadsafe_function = null;
var close_callback: ?napi_threadsafe_function = null;
var message_callback: ?napi_threadsafe_function = null;
var keybind_callback: ?napi_threadsafe_function = null;

// Message callback data for IPC
const MessageCallbackData = struct {
    message: []u8,
    allocator: std.mem.Allocator,
};

// Keybind callback data
const KeybindCallbackData = struct {
    key: u8,
    action: []u8,
    allocator: std.mem.Allocator,
};

// Internal IPC handler called by cdp_events
fn ipcMessageHandler(message: []const u8) void {
    if (message_callback) |cb| {
        const allocator = gpa.allocator();
        const data = allocator.create(MessageCallbackData) catch return;
        data.* = .{
            .message = allocator.dupe(u8, message) catch {
                allocator.destroy(data);
                return;
            },
            .allocator = allocator,
        };
        _ = napi_call_threadsafe_function(cb, data, .nonblocking);
    }
}

// Internal keybind handler called by input_handler
pub fn keybindHandler(key: u8, action: []const u8) void {
    if (keybind_callback) |cb| {
        const allocator = gpa.allocator();
        const data = allocator.create(KeybindCallbackData) catch return;
        data.* = .{
            .key = key,
            .action = allocator.dupe(u8, action) catch {
                allocator.destroy(data);
                return;
            },
            .allocator = allocator,
        };
        _ = napi_call_threadsafe_function(cb, data, .nonblocking);
    }
}

// Public function to register the IPC callback with cdp_events
pub fn registerIpcCallback() void {
    cdp_events.setIpcCallback(&ipcMessageHandler);
}

// Public function to unregister the IPC callback
pub fn unregisterIpcCallback() void {
    cdp_events.setIpcCallback(null);
}

// JS callback for message
fn messageJsCallback(env: napi_env, js_callback: napi_value, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const msg_data: *MessageCallbackData = @ptrCast(@alignCast(data orelse return));
    defer {
        msg_data.allocator.free(msg_data.message);
        msg_data.allocator.destroy(msg_data);
    }

    // Create string argument
    var msg_str: napi_value = undefined;
    if (napi_create_string_utf8(env, msg_data.message.ptr, msg_data.message.len, &msg_str) != .ok) {
        return;
    }

    // Call the JS callback with the message
    var global: napi_value = undefined;
    _ = napi_get_undefined(env, &global);

    var args = [_]napi_value{msg_str};
    _ = napi_call_function(env, global, js_callback, 1, &args, null);
}

// External N-API function declaration
extern fn napi_call_function(env: napi_env, recv: napi_value, func: napi_value, argc: usize, argv: [*]const napi_value, result: ?*napi_value) napi_status;

// JS callback for keybind - calls Node.js with (key, action)
fn keybindJsCallback(env: napi_env, js_callback: napi_value, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const kb_data: *KeybindCallbackData = @ptrCast(@alignCast(data orelse return));
    defer {
        kb_data.allocator.free(kb_data.action);
        kb_data.allocator.destroy(kb_data);
    }

    // Create key string (single char)
    var key_str: napi_value = undefined;
    const key_char = [_]u8{kb_data.key};
    if (napi_create_string_utf8(env, &key_char, 1, &key_str) != .ok) {
        return;
    }

    // Create action string
    var action_str: napi_value = undefined;
    if (napi_create_string_utf8(env, kb_data.action.ptr, kb_data.action.len, &action_str) != .ok) {
        return;
    }

    // Call the JS callback with (key, action)
    var global: napi_value = undefined;
    _ = napi_get_undefined(env, &global);

    var args = [_]napi_value{ key_str, action_str };
    _ = napi_call_function(env, global, js_callback, 2, &args, null);
}

/// Key bindings storage - maps a-z to action strings (static to persist across calls)
var key_bindings_storage: [26]?[]const u8 = [_]?[]const u8{null} ** 26;
var key_bindings_buffers: [26][256]u8 = undefined;

/// Data for async open operation
const AsyncOpenData = struct {
    allocator: std.mem.Allocator,
    url: []u8,
    no_toolbar: bool,
    disable_hotkeys: bool,
    allowed_hotkeys: ?u32, // Bitmask of allowed actions (null = all allowed)
    has_key_bindings: bool,
    disable_hints: bool,
    mobile: bool,
    scale: f32,
    no_profile: bool,
    verbose: bool,
    allowed_path: ?[]u8,
    work: napi_async_work,
    error_msg: ?[]u8,
    viewer: ?*viewer_mod.Viewer,

    fn deinit(self: *AsyncOpenData) void {
        self.allocator.free(self.url);
        if (self.allowed_path) |p| self.allocator.free(p);
        if (self.error_msg) |e| self.allocator.free(e);
    }
};

/// Convert action name string to bitmask bit
fn actionNameToBit(name: []const u8) ?u32 {
    const app_shortcuts = @import("app_shortcuts.zig");
    const AppAction = app_shortcuts.AppAction;

    const action: ?AppAction = if (std.mem.eql(u8, name, "quit")) .quit
        else if (std.mem.eql(u8, name, "address_bar")) .address_bar
        else if (std.mem.eql(u8, name, "reload")) .reload
        else if (std.mem.eql(u8, name, "go_back")) .go_back
        else if (std.mem.eql(u8, name, "go_forward")) .go_forward
        else if (std.mem.eql(u8, name, "stop_loading")) .stop_loading
        else if (std.mem.eql(u8, name, "copy")) .copy
        else if (std.mem.eql(u8, name, "cut")) .cut
        else if (std.mem.eql(u8, name, "paste")) .paste
        else if (std.mem.eql(u8, name, "select_all")) .select_all
        else if (std.mem.eql(u8, name, "tab_picker")) .tab_picker
        else if (std.mem.eql(u8, name, "enter_hint_mode")) .enter_hint_mode
        else if (std.mem.eql(u8, name, "scroll_down")) .scroll_down
        else if (std.mem.eql(u8, name, "scroll_up")) .scroll_up
        else if (std.mem.eql(u8, name, "new_tab")) .new_tab
        else if (std.mem.eql(u8, name, "close_tab")) .close_tab
        else null;

    if (action) |a| {
        return @as(u32, 1) << @intFromEnum(a);
    }
    return null;
}

/// Parse allowedHotkeys array from N-API and return bitmask
fn parseAllowedHotkeys(env: napi_env, arr_val: napi_value) ?u32 {
    var is_array: bool = false;
    if (napi_is_array(env, arr_val, &is_array) != .ok or !is_array) {
        return null;
    }

    var length: u32 = 0;
    if (napi_get_array_length(env, arr_val, &length) != .ok) {
        return null;
    }

    var mask: u32 = 0;
    var i: u32 = 0;
    while (i < length) : (i += 1) {
        var elem: napi_value = undefined;
        if (napi_get_element(env, arr_val, i, &elem) != .ok) continue;

        var name_buf: [64]u8 = undefined;
        var name_len: usize = 0;
        if (napi_get_value_string_utf8(env, elem, &name_buf, name_buf.len, &name_len) != .ok) continue;

        if (actionNameToBit(name_buf[0..name_len])) |bit| {
            mask |= bit;
        }
    }

    return if (mask > 0) mask else null;
}

/// Parse keyBindings object from N-API: { f: 'jsCode', g: 'jsCode' }
/// Stores bindings in static buffers and returns true if any bindings were set
fn parseKeyBindings(env: napi_env, obj_val: napi_value) bool {
    var val_type: c_uint = 0;
    if (napi_typeof(env, obj_val, &val_type) != .ok) return false;
    if (val_type != @intFromEnum(napi_valuetype.object)) return false;

    // Clear previous bindings
    for (0..26) |i| {
        key_bindings_storage[i] = null;
    }

    var found_any = false;
    // Check each letter a-z
    var letter: u8 = 'a';
    while (letter <= 'z') : (letter += 1) {
        const key_name: [2]u8 = .{ letter, 0 };
        var prop_val: napi_value = undefined;
        if (napi_get_named_property(env, obj_val, @ptrCast(&key_name), &prop_val) == .ok) {
            var prop_type: c_uint = 0;
            if (napi_typeof(env, prop_val, &prop_type) == .ok and prop_type == @intFromEnum(napi_valuetype.string)) {
                const idx = letter - 'a';
                var js_len: usize = 0;
                if (napi_get_value_string_utf8(env, prop_val, &key_bindings_buffers[idx], key_bindings_buffers[idx].len, &js_len) == .ok) {
                    key_bindings_storage[idx] = key_bindings_buffers[idx][0..js_len];
                    found_any = true;
                }
            }
        }
    }

    return found_any;
}

/// Console message callback data
const ConsoleCallbackData = struct {
    message: [4096]u8,
    len: usize,
};

/// Execute async work (runs on worker thread)
fn asyncOpenExecute(_: ?napi_env, data: ?*anyopaque) callconv(.c) void {
    const async_data: *AsyncOpenData = @ptrCast(@alignCast(data orelse return));

    // Run the viewer (this blocks until viewer closes)
    runBrowserAsync(async_data) catch |err| {
        var err_buf: [256]u8 = undefined;
        const err_msg = std.fmt.bufPrint(&err_buf, "{}", .{err}) catch "Unknown error";
        async_data.error_msg = async_data.allocator.dupe(u8, err_msg) catch null;
    };
}

/// Complete async work (runs on main thread)
fn asyncOpenComplete(env: napi_env, status: napi_status, data: ?*anyopaque) callconv(.c) void {
    _ = status;
    const async_data: *AsyncOpenData = @ptrCast(@alignCast(data orelse return));

    // Clean up viewer reference
    viewer_mutex.lock();
    active_viewer = null;
    viewer_mutex.unlock();

    // Call close callback if registered
    if (close_callback) |cb| {
        _ = napi_call_threadsafe_function(cb, null, .nonblocking);
    }

    // Clean up async work
    _ = napi_delete_async_work(env, async_data.work);
    async_data.deinit();
    async_data.allocator.destroy(async_data);
}

/// Run browser with async support (can be interrupted)
fn runBrowserAsync(async_data: *AsyncOpenData) !void {
    const allocator = async_data.allocator;

    // Get terminal size
    var term = terminal_mod.Terminal.init();
    const size = term.getSize() catch terminal_mod.TerminalSize{
        .cols = 80,
        .rows = 24,
        .width_px = 1280,
        .height_px = 720,
    };

    const raw_width: u32 = if (size.width_px > 0) size.width_px else @as(u32, size.cols) * 10;

    var dpr: u32 = 1;
    const cell_width: u32 = if (size.width_px > 0 and size.cols > 0)
        size.width_px / size.cols
    else
        14;
    const cell_height: u32 = if (size.height_px > 0 and size.rows > 0)
        size.height_px / size.rows
    else
        20;
    if (cell_width > 14) {
        dpr = 2;
    }

    const toolbar_height = toolbar_mod.getToolbarHeight(cell_width);
    const available_height: u32 = if (size.height_px > toolbar_height)
        size.height_px - toolbar_height
    else
        size.height_px;
    const content_rows: u32 = available_height / cell_height;
    const content_pixel_height: u32 = content_rows * cell_height;

    const original_viewport_width: u32 = raw_width / dpr;
    const original_viewport_height: u32 = content_pixel_height / dpr;

    var viewport_width: u32 = original_viewport_width;
    var viewport_height: u32 = original_viewport_height;

    const MAX_PIXELS = config.MAX_PIXELS;
    const total_pixels: u64 = @as(u64, viewport_width) * @as(u64, viewport_height);
    if (total_pixels > MAX_PIXELS) {
        const pixel_scale = @sqrt(@as(f64, @floatFromInt(MAX_PIXELS)) / @as(f64, @floatFromInt(total_pixels)));
        viewport_width = @intFromFloat(@as(f64, @floatFromInt(viewport_width)) * pixel_scale);
        viewport_height = @intFromFloat(@as(f64, @floatFromInt(viewport_height)) * pixel_scale);
    }

    // Launch Chrome
    var launch_opts = launcher.LaunchOptions{
        .viewport_width = viewport_width,
        .viewport_height = viewport_height,
        .verbose = async_data.verbose,
    };
    if (async_data.no_profile) {
        launch_opts.clone_profile = null;
    }

    var chrome_instance = try launcher.launchChromePipe(allocator, launch_opts);
    defer chrome_instance.deinit();

    // Use pipe if available, otherwise WebSocket
    var client = if (chrome_instance.read_fd >= 0 and chrome_instance.write_fd >= 0)
        try cdp.CdpClient.initFromPipe(allocator, chrome_instance.read_fd, chrome_instance.write_fd, chrome_instance.debug_port)
    else
        try cdp.CdpClient.initFromWebSocket(allocator, chrome_instance.debug_port);
    defer client.deinit();

    try screenshot_api.setViewport(client, allocator, viewport_width, viewport_height, dpr);
    try screenshot_api.navigateToUrl(client, allocator, async_data.url);

    var actual_viewport_width = viewport_width;
    var actual_viewport_height = viewport_height;
    if (screenshot_api.getActualViewport(client, allocator)) |actual_vp| {
        if (actual_vp.width > 0) actual_viewport_width = actual_vp.width;
        if (actual_vp.height > 0) actual_viewport_height = actual_vp.height;
    } else |_| {}

    var viewer = try viewer_mod.Viewer.init(allocator, client, async_data.url, actual_viewport_width, actual_viewport_height, original_viewport_width, original_viewport_height, @intCast(cell_width), config.DEFAULT_FPS);
    defer viewer.deinit();

    if (async_data.no_toolbar) {
        viewer.disableToolbar();
    }
    if (async_data.disable_hotkeys) {
        viewer.disableHotkeys();
    }
    if (async_data.allowed_hotkeys) |mask| {
        viewer.setAllowedHotkeys(mask);
    }
    if (async_data.has_key_bindings) {
        viewer.setKeyBindings(&key_bindings_storage);
        viewer.setKeybindCallback(&keybindHandler);
    }
    if (async_data.disable_hints) {
        viewer.disableHints();
    }

    if (async_data.allowed_path) |path| {
        try viewer.addAllowedPath(path);
    }

    // Store viewer reference for external access
    viewer_mutex.lock();
    active_viewer = &viewer;
    async_data.viewer = &viewer;
    viewer_mutex.unlock();

    // Register IPC callback for this session
    registerIpcCallback();
    defer unregisterIpcCallback();

    try viewer.run();
}

/// napi_open(url: string, options?: { toolbar?: boolean, mobile?: boolean, scale?: number, ... }) -> void
fn napi_open(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    const allocator = gpa.allocator();

    var argc: usize = 2;
    var argv: [2]napi_value = undefined;
    _ = napi_get_cb_info(env, info, &argc, &argv, null, null);

    if (argc < 1) {
        _ = napi_throw_error(env, null, "URL argument required");
        var undef: napi_value = undefined;
        _ = napi_get_undefined(env, &undef);
        return undef;
    }

    // Get URL string
    var url_len: usize = 0;
    _ = napi_get_value_string_utf8(env, argv[0], null, 0, &url_len);
    const url_buf = allocator.alloc(u8, url_len + 1) catch {
        _ = napi_throw_error(env, null, "Memory allocation failed");
        var undef: napi_value = undefined;
        _ = napi_get_undefined(env, &undef);
        return undef;
    };
    defer allocator.free(url_buf);
    _ = napi_get_value_string_utf8(env, argv[0], url_buf.ptr, url_len + 1, &url_len);
    const url = url_buf[0..url_len];

    // Parse options
    var no_toolbar = false;
    var disable_hotkeys = false;
    var allowed_hotkeys: ?u32 = null;
    var has_key_bindings = false;
    var disable_hints = false;
    var mobile = false;
    var scale: f32 = 1.0;
    var no_profile = false;
    var verbose = false;

    if (argc >= 2) {
        var val_type: c_uint = 0;
        _ = napi_typeof(env, argv[1], &val_type);
        if (val_type == @intFromEnum(napi_valuetype.object)) {
            // toolbar option
            var toolbar_val: napi_value = undefined;
            if (napi_get_named_property(env, argv[1], "toolbar", &toolbar_val) == .ok) {
                var toolbar_type: c_uint = 0;
                _ = napi_typeof(env, toolbar_val, &toolbar_type);
                if (toolbar_type == @intFromEnum(napi_valuetype.boolean)) {
                    var toolbar: bool = true;
                    _ = napi_get_value_bool(env, toolbar_val, &toolbar);
                    no_toolbar = !toolbar;
                }
            }

            // hotkeys option (default: true)
            var hotkeys_val: napi_value = undefined;
            if (napi_get_named_property(env, argv[1], "hotkeys", &hotkeys_val) == .ok) {
                var hotkeys_type: c_uint = 0;
                _ = napi_typeof(env, hotkeys_val, &hotkeys_type);
                if (hotkeys_type == @intFromEnum(napi_valuetype.boolean)) {
                    var hotkeys: bool = true;
                    _ = napi_get_value_bool(env, hotkeys_val, &hotkeys);
                    disable_hotkeys = !hotkeys;
                }
            }

            // hints option (default: true)
            var hints_val: napi_value = undefined;
            if (napi_get_named_property(env, argv[1], "hints", &hints_val) == .ok) {
                var hints_type: c_uint = 0;
                _ = napi_typeof(env, hints_val, &hints_type);
                if (hints_type == @intFromEnum(napi_valuetype.boolean)) {
                    var hints: bool = true;
                    _ = napi_get_value_bool(env, hints_val, &hints);
                    disable_hints = !hints;
                }
            }

            // mobile option
            var mobile_val: napi_value = undefined;
            if (napi_get_named_property(env, argv[1], "mobile", &mobile_val) == .ok) {
                var mobile_type: c_uint = 0;
                _ = napi_typeof(env, mobile_val, &mobile_type);
                if (mobile_type == @intFromEnum(napi_valuetype.boolean)) {
                    _ = napi_get_value_bool(env, mobile_val, &mobile);
                }
            }

            // scale option
            var scale_val: napi_value = undefined;
            if (napi_get_named_property(env, argv[1], "scale", &scale_val) == .ok) {
                var scale_type: c_uint = 0;
                _ = napi_typeof(env, scale_val, &scale_type);
                if (scale_type == @intFromEnum(napi_valuetype.number)) {
                    var scale_f64: f64 = 1.0;
                    _ = napi_get_value_double(env, scale_val, &scale_f64);
                    scale = @floatCast(scale_f64);
                }
            }

            // noProfile option
            var no_profile_val: napi_value = undefined;
            if (napi_get_named_property(env, argv[1], "noProfile", &no_profile_val) == .ok) {
                var no_profile_type: c_uint = 0;
                _ = napi_typeof(env, no_profile_val, &no_profile_type);
                if (no_profile_type == @intFromEnum(napi_valuetype.boolean)) {
                    _ = napi_get_value_bool(env, no_profile_val, &no_profile);
                }
            }

            // verbose option
            var verbose_val: napi_value = undefined;
            if (napi_get_named_property(env, argv[1], "verbose", &verbose_val) == .ok) {
                var verbose_type: c_uint = 0;
                _ = napi_typeof(env, verbose_val, &verbose_type);
                if (verbose_type == @intFromEnum(napi_valuetype.boolean)) {
                    _ = napi_get_value_bool(env, verbose_val, &verbose);
                }
            }

            // allowedHotkeys option - array of action names like ['quit', 'copy']
            var allowed_hotkeys_val: napi_value = undefined;
            if (napi_get_named_property(env, argv[1], "allowedHotkeys", &allowed_hotkeys_val) == .ok) {
                allowed_hotkeys = parseAllowedHotkeys(env, allowed_hotkeys_val);
            }

            // keyBindings option - object like { f: 'jsCode()', g: 'jsCode()' }
            var key_bindings_val: napi_value = undefined;
            if (napi_get_named_property(env, argv[1], "keyBindings", &key_bindings_val) == .ok) {
                has_key_bindings = parseKeyBindings(env, key_bindings_val);
            }
        }
    }

    // Extract allowed path from URL query param if present
    // We add the parent directory to allow browsing
    var allowed_path: ?[]const u8 = null;
    if (std.mem.indexOf(u8, url, "path=")) |start| {
        const path_start = start + 5;
        var path_end = path_start;
        while (path_end < url.len and url[path_end] != '&') : (path_end += 1) {}
        if (path_end > path_start) {
            // URL decode the path
            const encoded = url[path_start..path_end];
            const decode_buf = allocator.alloc(u8, encoded.len) catch null;
            if (decode_buf) |buf| {
                const decoded = std.Uri.percentDecodeBackwards(buf, encoded);
                // Get parent directory for FS access
                if (std.mem.lastIndexOf(u8, decoded, "/")) |last_slash| {
                    if (last_slash > 0) {
                        allowed_path = allocator.dupe(u8, decoded[0..last_slash]) catch null;
                    } else {
                        allowed_path = allocator.dupe(u8, "/") catch null;
                    }
                } else {
                    allowed_path = allocator.dupe(u8, decoded) catch null;
                }
                allocator.free(buf);
            }
        }
    }

    // Run browser (blocking)
    runBrowser(allocator, url, no_toolbar, disable_hotkeys, allowed_hotkeys, has_key_bindings, disable_hints, mobile, scale, no_profile, verbose, allowed_path) catch |err| {
        // Format error name for debugging
        var err_buf: [256]u8 = undefined;
        const err_msg = std.fmt.bufPrint(&err_buf, "{}", .{err}) catch "Unknown error";
        // Null-terminate for C string
        var c_err: [257]u8 = undefined;
        @memcpy(c_err[0..err_msg.len], err_msg);
        c_err[err_msg.len] = 0;
        _ = napi_throw_error(env, null, @ptrCast(&c_err));
    };

    var undef: napi_value = undefined;
    _ = napi_get_undefined(env, &undef);
    return undef;
}

fn runBrowser(allocator: std.mem.Allocator, url: []const u8, no_toolbar: bool, disable_hotkeys: bool, allowed_hotkeys: ?u32, has_key_bindings: bool, disable_hints: bool, mobile: bool, scale: f32, no_profile: bool, verbose: bool, allowed_path: ?[]const u8) !void {
    _ = mobile;
    _ = scale;

    // Get terminal size
    var term = terminal_mod.Terminal.init();
    const size = term.getSize() catch terminal_mod.TerminalSize{
        .cols = 80,
        .rows = 24,
        .width_px = 1280,
        .height_px = 720,
    };

    const raw_width: u32 = if (size.width_px > 0) size.width_px else @as(u32, size.cols) * 10;

    var dpr: u32 = 1;
    const cell_width: u32 = if (size.width_px > 0 and size.cols > 0)
        size.width_px / size.cols
    else
        14;
    const cell_height: u32 = if (size.height_px > 0 and size.rows > 0)
        size.height_px / size.rows
    else
        20;
    if (cell_width > 14) {
        dpr = 2;
    }

    const toolbar_height = toolbar_mod.getToolbarHeight(cell_width);
    const available_height: u32 = if (size.height_px > toolbar_height)
        size.height_px - toolbar_height
    else
        size.height_px;
    const content_rows: u32 = available_height / cell_height;
    const content_pixel_height: u32 = content_rows * cell_height;

    // Original viewport (before any limits) - used for coordinate ratio calculation
    const original_viewport_width: u32 = raw_width / dpr;
    const original_viewport_height: u32 = content_pixel_height / dpr;

    var viewport_width: u32 = original_viewport_width;
    var viewport_height: u32 = original_viewport_height;

    const MAX_PIXELS = config.MAX_PIXELS;
    const total_pixels: u64 = @as(u64, viewport_width) * @as(u64, viewport_height);
    if (total_pixels > MAX_PIXELS) {
        const pixel_scale = @sqrt(@as(f64, @floatFromInt(MAX_PIXELS)) / @as(f64, @floatFromInt(total_pixels)));
        viewport_width = @intFromFloat(@as(f64, @floatFromInt(viewport_width)) * pixel_scale);
        viewport_height = @intFromFloat(@as(f64, @floatFromInt(viewport_height)) * pixel_scale);
    }

    // Launch Chrome
    var launch_opts = launcher.LaunchOptions{
        .viewport_width = viewport_width,
        .viewport_height = viewport_height,
        .verbose = verbose,
    };
    if (no_profile) {
        launch_opts.clone_profile = null;
    }

    var chrome_instance = try launcher.launchChromePipe(allocator, launch_opts);
    defer chrome_instance.deinit();

    // Use pipe if available, otherwise WebSocket
    var client = if (chrome_instance.read_fd >= 0 and chrome_instance.write_fd >= 0)
        try cdp.CdpClient.initFromPipe(allocator, chrome_instance.read_fd, chrome_instance.write_fd, chrome_instance.debug_port)
    else
        try cdp.CdpClient.initFromWebSocket(allocator, chrome_instance.debug_port);
    defer client.deinit();

    // Set viewport with matching DPR
    try screenshot_api.setViewport(client, allocator, viewport_width, viewport_height, dpr);

    // Navigate
    try screenshot_api.navigateToUrl(client, allocator, url);

    // Get actual viewport
    var actual_viewport_width = viewport_width;
    var actual_viewport_height = viewport_height;
    if (screenshot_api.getActualViewport(client, allocator)) |actual_vp| {
        if (actual_vp.width > 0) actual_viewport_width = actual_vp.width;
        if (actual_vp.height > 0) actual_viewport_height = actual_vp.height;
    } else |_| {}

    // Run viewer with original (pre-MAX_PIXELS) dimensions for coordinate ratio
    var viewer = try viewer_mod.Viewer.init(allocator, client, url, actual_viewport_width, actual_viewport_height, original_viewport_width, original_viewport_height, @intCast(cell_width), config.DEFAULT_FPS);
    defer viewer.deinit();

    if (no_toolbar) {
        viewer.disableToolbar();
    }
    if (disable_hotkeys) {
        viewer.disableHotkeys();
    }
    if (allowed_hotkeys) |mask| {
        viewer.setAllowedHotkeys(mask);
    }
    if (has_key_bindings) {
        viewer.setKeyBindings(&key_bindings_storage);
        viewer.setKeybindCallback(&keybindHandler);
    }
    if (disable_hints) {
        viewer.disableHints();
    }

    // Add allowed FS path if specified
    if (allowed_path) |path| {
        try viewer.addAllowedPath(path);
    }

    try viewer.run();
}

/// napi_version() -> string
fn napi_version(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    _ = info;
    var result: napi_value = undefined;
    _ = napi_create_string_utf8(env, VERSION.ptr, VERSION.len, &result);
    return result;
}

/// napi_isSupported() -> boolean
fn napi_isSupported(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    _ = info;
    const allocator = gpa.allocator();

    const term_program = std.process.getEnvVarOwned(allocator, "TERM_PROGRAM") catch null;
    defer if (term_program) |t| allocator.free(t);

    var supported = false;
    if (term_program) |tp| {
        if (std.mem.eql(u8, tp, "ghostty") or
            std.mem.eql(u8, tp, "kitty") or
            std.mem.eql(u8, tp, "WezTerm"))
        {
            supported = true;
        }
    }

    var result: napi_value = undefined;
    _ = napi_get_boolean(env, supported, &result);
    return result;
}

/// napi_openAsync(url: string, options?: { toolbar?: boolean, ... }) -> void
/// Non-blocking version of open - returns immediately, viewer runs in background
fn napi_openAsync(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    const allocator = gpa.allocator();

    var argc: usize = 2;
    var argv: [2]napi_value = undefined;
    _ = napi_get_cb_info(env, info, &argc, &argv, null, null);

    if (argc < 1) {
        _ = napi_throw_error(env, null, "URL argument required");
        var undef: napi_value = undefined;
        _ = napi_get_undefined(env, &undef);
        return undef;
    }

    // Get URL string
    var url_len: usize = 0;
    _ = napi_get_value_string_utf8(env, argv[0], null, 0, &url_len);
    const url_buf = allocator.alloc(u8, url_len) catch {
        _ = napi_throw_error(env, null, "Memory allocation failed");
        var undef: napi_value = undefined;
        _ = napi_get_undefined(env, &undef);
        return undef;
    };
    var actual_len: usize = 0;
    _ = napi_get_value_string_utf8(env, argv[0], url_buf.ptr, url_len + 1, &actual_len);

    // Parse options (same as sync version)
    var no_toolbar = false;
    var disable_hotkeys = false;
    var allowed_hotkeys: ?u32 = null;
    var has_key_bindings = false;
    var disable_hints = false;
    var mobile = false;
    var scale: f32 = 1.0;
    var no_profile = false;
    var verbose = false;

    if (argc >= 2) {
        var val_type: c_uint = 0;
        _ = napi_typeof(env, argv[1], &val_type);
        if (val_type == @intFromEnum(napi_valuetype.object)) {
            // toolbar option
            var toolbar_val: napi_value = undefined;
            if (napi_get_named_property(env, argv[1], "toolbar", &toolbar_val) == .ok) {
                var toolbar_type: c_uint = 0;
                _ = napi_typeof(env, toolbar_val, &toolbar_type);
                if (toolbar_type == @intFromEnum(napi_valuetype.boolean)) {
                    var toolbar: bool = true;
                    _ = napi_get_value_bool(env, toolbar_val, &toolbar);
                    no_toolbar = !toolbar;
                }
            }

            // hotkeys option
            var hotkeys_val: napi_value = undefined;
            if (napi_get_named_property(env, argv[1], "hotkeys", &hotkeys_val) == .ok) {
                var hotkeys_type: c_uint = 0;
                _ = napi_typeof(env, hotkeys_val, &hotkeys_type);
                if (hotkeys_type == @intFromEnum(napi_valuetype.boolean)) {
                    var hotkeys: bool = true;
                    _ = napi_get_value_bool(env, hotkeys_val, &hotkeys);
                    disable_hotkeys = !hotkeys;
                }
            }

            // hints option
            var hints_val: napi_value = undefined;
            if (napi_get_named_property(env, argv[1], "hints", &hints_val) == .ok) {
                var hints_type: c_uint = 0;
                _ = napi_typeof(env, hints_val, &hints_type);
                if (hints_type == @intFromEnum(napi_valuetype.boolean)) {
                    var hints: bool = true;
                    _ = napi_get_value_bool(env, hints_val, &hints);
                    disable_hints = !hints;
                }
            }

            // mobile option
            var mobile_val: napi_value = undefined;
            if (napi_get_named_property(env, argv[1], "mobile", &mobile_val) == .ok) {
                var mobile_type: c_uint = 0;
                _ = napi_typeof(env, mobile_val, &mobile_type);
                if (mobile_type == @intFromEnum(napi_valuetype.boolean)) {
                    _ = napi_get_value_bool(env, mobile_val, &mobile);
                }
            }

            // scale option
            var scale_val: napi_value = undefined;
            if (napi_get_named_property(env, argv[1], "scale", &scale_val) == .ok) {
                var scale_type: c_uint = 0;
                _ = napi_typeof(env, scale_val, &scale_type);
                if (scale_type == @intFromEnum(napi_valuetype.number)) {
                    var scale_f64: f64 = 1.0;
                    _ = napi_get_value_double(env, scale_val, &scale_f64);
                    scale = @floatCast(scale_f64);
                }
            }

            // noProfile option
            var no_profile_val: napi_value = undefined;
            if (napi_get_named_property(env, argv[1], "noProfile", &no_profile_val) == .ok) {
                var no_profile_type: c_uint = 0;
                _ = napi_typeof(env, no_profile_val, &no_profile_type);
                if (no_profile_type == @intFromEnum(napi_valuetype.boolean)) {
                    _ = napi_get_value_bool(env, no_profile_val, &no_profile);
                }
            }

            // verbose option
            var verbose_val: napi_value = undefined;
            if (napi_get_named_property(env, argv[1], "verbose", &verbose_val) == .ok) {
                var verbose_type: c_uint = 0;
                _ = napi_typeof(env, verbose_val, &verbose_type);
                if (verbose_type == @intFromEnum(napi_valuetype.boolean)) {
                    _ = napi_get_value_bool(env, verbose_val, &verbose);
                }
            }

            // allowedHotkeys option - array of action names like ['quit', 'copy']
            var allowed_hotkeys_val: napi_value = undefined;
            if (napi_get_named_property(env, argv[1], "allowedHotkeys", &allowed_hotkeys_val) == .ok) {
                allowed_hotkeys = parseAllowedHotkeys(env, allowed_hotkeys_val);
            }

            // keyBindings option - object like { f: 'jsCode()', g: 'jsCode()' }
            var key_bindings_val: napi_value = undefined;
            if (napi_get_named_property(env, argv[1], "keyBindings", &key_bindings_val) == .ok) {
                has_key_bindings = parseKeyBindings(env, key_bindings_val);
            }
        }
    }

    // Create async data
    const async_data = allocator.create(AsyncOpenData) catch {
        allocator.free(url_buf);
        _ = napi_throw_error(env, null, "Memory allocation failed");
        var undef: napi_value = undefined;
        _ = napi_get_undefined(env, &undef);
        return undef;
    };
    async_data.* = .{
        .allocator = allocator,
        .url = url_buf,
        .no_toolbar = no_toolbar,
        .disable_hotkeys = disable_hotkeys,
        .allowed_hotkeys = allowed_hotkeys,
        .has_key_bindings = has_key_bindings,
        .disable_hints = disable_hints,
        .mobile = mobile,
        .scale = scale,
        .no_profile = no_profile,
        .verbose = verbose,
        .allowed_path = null,
        .work = undefined,
        .error_msg = null,
        .viewer = null,
    };

    // Create async resource name
    var resource_name: napi_value = undefined;
    _ = napi_create_string_utf8(env, "termweb:open", 12, &resource_name);

    // Create and queue async work
    var work: napi_async_work = undefined;
    if (napi_create_async_work(env, null, resource_name, &asyncOpenExecute, &asyncOpenComplete, async_data, &work) != .ok) {
        async_data.deinit();
        allocator.destroy(async_data);
        _ = napi_throw_error(env, null, "Failed to create async work");
        var undef: napi_value = undefined;
        _ = napi_get_undefined(env, &undef);
        return undef;
    }
    async_data.work = work;

    if (napi_queue_async_work(env, work) != .ok) {
        _ = napi_delete_async_work(env, work);
        async_data.deinit();
        allocator.destroy(async_data);
        _ = napi_throw_error(env, null, "Failed to queue async work");
        var undef: napi_value = undefined;
        _ = napi_get_undefined(env, &undef);
        return undef;
    }

    var undef: napi_value = undefined;
    _ = napi_get_undefined(env, &undef);
    return undef;
}

/// napi_evalJS(script: string) -> boolean
/// Evaluate JavaScript in the active viewer. Returns true if successful.
fn napi_evalJS(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    const allocator = gpa.allocator();

    var argc: usize = 1;
    var argv: [1]napi_value = undefined;
    _ = napi_get_cb_info(env, info, &argc, &argv, null, null);

    if (argc < 1) {
        var result: napi_value = undefined;
        _ = napi_get_boolean(env, false, &result);
        return result;
    }

    // Get script string
    var script_len: usize = 0;
    _ = napi_get_value_string_utf8(env, argv[0], null, 0, &script_len);
    const script_buf = allocator.alloc(u8, script_len + 1) catch {
        var result: napi_value = undefined;
        _ = napi_get_boolean(env, false, &result);
        return result;
    };
    defer allocator.free(script_buf);
    _ = napi_get_value_string_utf8(env, argv[0], script_buf.ptr, script_len + 1, &script_len);
    const script = script_buf[0..script_len];

    // Try to eval on the active viewer
    viewer_mutex.lock();
    defer viewer_mutex.unlock();

    if (active_viewer) |viewer| {
        viewer.evalJavaScript(script) catch {
            var result: napi_value = undefined;
            _ = napi_get_boolean(env, false, &result);
            return result;
        };
        var result: napi_value = undefined;
        _ = napi_get_boolean(env, true, &result);
        return result;
    }

    var result: napi_value = undefined;
    _ = napi_get_boolean(env, false, &result);
    return result;
}

/// napi_close() -> boolean
/// Close the active viewer. Returns true if there was a viewer to close.
fn napi_close(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    _ = info;

    viewer_mutex.lock();
    defer viewer_mutex.unlock();

    if (active_viewer) |viewer| {
        viewer.requestQuit();
        var result: napi_value = undefined;
        _ = napi_get_boolean(env, true, &result);
        return result;
    }

    var result: napi_value = undefined;
    _ = napi_get_boolean(env, false, &result);
    return result;
}

/// napi_isOpen() -> boolean
/// Check if a viewer is currently open.
fn napi_isOpen(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    _ = info;

    viewer_mutex.lock();
    defer viewer_mutex.unlock();

    var result: napi_value = undefined;
    _ = napi_get_boolean(env, active_viewer != null, &result);
    return result;
}

/// napi_onClose(callback: function) -> void
/// Register a callback to be called when the viewer closes.
fn napi_onClose(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    var argc: usize = 1;
    var argv: [1]napi_value = undefined;
    _ = napi_get_cb_info(env, info, &argc, &argv, null, null);

    if (argc < 1) {
        var undef: napi_value = undefined;
        _ = napi_get_undefined(env, &undef);
        return undef;
    }

    // Check if it's a function
    var val_type: c_uint = 0;
    _ = napi_typeof(env, argv[0], &val_type);
    if (val_type != @intFromEnum(napi_valuetype.function)) {
        _ = napi_throw_error(env, null, "Callback must be a function");
        var undef: napi_value = undefined;
        _ = napi_get_undefined(env, &undef);
        return undef;
    }

    // Release old callback if exists
    if (close_callback) |cb| {
        _ = napi_release_threadsafe_function(cb, 0);
        close_callback = null;
    }

    // Create async resource name
    var resource_name: napi_value = undefined;
    _ = napi_create_string_utf8(env, "termweb:onClose", 15, &resource_name);

    // Create threadsafe function for callback
    var tsfn: napi_threadsafe_function = undefined;
    if (napi_create_threadsafe_function(env, argv[0], null, resource_name, 0, 1, null, null, null, null, &tsfn) == .ok) {
        close_callback = tsfn;
    }

    var undef: napi_value = undefined;
    _ = napi_get_undefined(env, &undef);
    return undef;
}

/// napi_onKeyBinding(callback: function) -> void
/// Register a callback to receive key binding events.
/// Callback receives (key: string, action: string) when a bound key is pressed.
fn napi_onKeyBinding(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    var argc: usize = 1;
    var argv: [1]napi_value = undefined;
    _ = napi_get_cb_info(env, info, &argc, &argv, null, null);

    if (argc < 1) {
        var undef: napi_value = undefined;
        _ = napi_get_undefined(env, &undef);
        return undef;
    }

    // Check if it's a function
    var val_type: c_uint = 0;
    _ = napi_typeof(env, argv[0], &val_type);
    if (val_type != @intFromEnum(napi_valuetype.function)) {
        _ = napi_throw_error(env, null, "Callback must be a function");
        var undef: napi_value = undefined;
        _ = napi_get_undefined(env, &undef);
        return undef;
    }

    // Release old callback if exists
    if (keybind_callback) |cb| {
        _ = napi_release_threadsafe_function(cb, 0);
        keybind_callback = null;
    }

    // Create async resource name
    var resource_name: napi_value = undefined;
    _ = napi_create_string_utf8(env, "termweb:onKeyBinding", 20, &resource_name);

    // Create threadsafe function for callback with custom JS callback handler
    var tsfn: napi_threadsafe_function = undefined;
    if (napi_create_threadsafe_function(env, argv[0], null, resource_name, 0, 1, null, null, null, &keybindJsCallback, &tsfn) == .ok) {
        keybind_callback = tsfn;
    }

    var undef: napi_value = undefined;
    _ = napi_get_undefined(env, &undef);
    return undef;
}

/// napi_addKeyBinding(key: string, action: string) -> boolean
/// Add a key binding dynamically
fn napi_addKeyBinding(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    var argc: usize = 2;
    var argv: [2]napi_value = undefined;
    _ = napi_get_cb_info(env, info, &argc, &argv, null, null);

    if (argc < 2) {
        var result: napi_value = undefined;
        _ = napi_get_boolean(env, false, &result);
        return result;
    }

    // Get key (single char)
    var key_buf: [2]u8 = undefined;
    var key_len: usize = 0;
    if (napi_get_value_string_utf8(env, argv[0], &key_buf, 2, &key_len) != .ok or key_len != 1) {
        var result: napi_value = undefined;
        _ = napi_get_boolean(env, false, &result);
        return result;
    }
    const key = key_buf[0];
    if (key < 'a' or key > 'z') {
        var result: napi_value = undefined;
        _ = napi_get_boolean(env, false, &result);
        return result;
    }

    // Get action string
    const idx = key - 'a';
    var action_len: usize = 0;
    if (napi_get_value_string_utf8(env, argv[1], &key_bindings_buffers[idx], key_bindings_buffers[idx].len, &action_len) != .ok) {
        var result: napi_value = undefined;
        _ = napi_get_boolean(env, false, &result);
        return result;
    }

    key_bindings_storage[idx] = key_bindings_buffers[idx][0..action_len];

    var result: napi_value = undefined;
    _ = napi_get_boolean(env, true, &result);
    return result;
}

/// napi_removeKeyBinding(key: string) -> boolean
/// Remove a key binding dynamically
fn napi_removeKeyBinding(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    var argc: usize = 1;
    var argv: [1]napi_value = undefined;
    _ = napi_get_cb_info(env, info, &argc, &argv, null, null);

    if (argc < 1) {
        var result: napi_value = undefined;
        _ = napi_get_boolean(env, false, &result);
        return result;
    }

    // Get key (single char)
    var key_buf: [2]u8 = undefined;
    var key_len: usize = 0;
    if (napi_get_value_string_utf8(env, argv[0], &key_buf, 2, &key_len) != .ok or key_len != 1) {
        var result: napi_value = undefined;
        _ = napi_get_boolean(env, false, &result);
        return result;
    }
    const key = key_buf[0];
    if (key < 'a' or key > 'z') {
        var result: napi_value = undefined;
        _ = napi_get_boolean(env, false, &result);
        return result;
    }

    const idx = key - 'a';
    key_bindings_storage[idx] = null;

    var result: napi_value = undefined;
    _ = napi_get_boolean(env, true, &result);
    return result;
}

/// napi_onMessage(callback: function) -> void
/// Register a callback to receive IPC messages from the browser.
/// Messages with __TERMWEB_IPC__: prefix will trigger this callback.
fn napi_onMessage(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    var argc: usize = 1;
    var argv: [1]napi_value = undefined;
    _ = napi_get_cb_info(env, info, &argc, &argv, null, null);

    if (argc < 1) {
        var undef: napi_value = undefined;
        _ = napi_get_undefined(env, &undef);
        return undef;
    }

    // Check if it's a function
    var val_type: c_uint = 0;
    _ = napi_typeof(env, argv[0], &val_type);
    if (val_type != @intFromEnum(napi_valuetype.function)) {
        _ = napi_throw_error(env, null, "Callback must be a function");
        var undef: napi_value = undefined;
        _ = napi_get_undefined(env, &undef);
        return undef;
    }

    // Release old callback if exists
    if (message_callback) |cb| {
        _ = napi_release_threadsafe_function(cb, 0);
        message_callback = null;
    }

    // Create async resource name
    var resource_name: napi_value = undefined;
    _ = napi_create_string_utf8(env, "termweb:onMessage", 17, &resource_name);

    // Create threadsafe function for callback with custom JS callback handler
    var tsfn: napi_threadsafe_function = undefined;
    if (napi_create_threadsafe_function(env, argv[0], null, resource_name, 0, 1, null, null, null, &messageJsCallback, &tsfn) == .ok) {
        message_callback = tsfn;
    }

    var undef: napi_value = undefined;
    _ = napi_get_undefined(env, &undef);
    return undef;
}

/// Module initialization
export fn napi_register_module_v1(env: napi_env, exports: napi_value) napi_value {
    // open function (blocking)
    var open_fn: napi_value = undefined;
    _ = napi_create_function(env, "open", 4, &napi_open, null, &open_fn);
    _ = napi_set_named_property(env, exports, "open", open_fn);

    // openAsync function (non-blocking)
    var open_async_fn: napi_value = undefined;
    _ = napi_create_function(env, "openAsync", 9, &napi_openAsync, null, &open_async_fn);
    _ = napi_set_named_property(env, exports, "openAsync", open_async_fn);

    // evalJS function
    var eval_js_fn: napi_value = undefined;
    _ = napi_create_function(env, "evalJS", 6, &napi_evalJS, null, &eval_js_fn);
    _ = napi_set_named_property(env, exports, "evalJS", eval_js_fn);

    // close function
    var close_fn: napi_value = undefined;
    _ = napi_create_function(env, "close", 5, &napi_close, null, &close_fn);
    _ = napi_set_named_property(env, exports, "close", close_fn);

    // isOpen function
    var is_open_fn: napi_value = undefined;
    _ = napi_create_function(env, "isOpen", 6, &napi_isOpen, null, &is_open_fn);
    _ = napi_set_named_property(env, exports, "isOpen", is_open_fn);

    // onClose function
    var on_close_fn: napi_value = undefined;
    _ = napi_create_function(env, "onClose", 7, &napi_onClose, null, &on_close_fn);
    _ = napi_set_named_property(env, exports, "onClose", on_close_fn);

    // onMessage function
    var on_message_fn: napi_value = undefined;
    _ = napi_create_function(env, "onMessage", 9, &napi_onMessage, null, &on_message_fn);
    _ = napi_set_named_property(env, exports, "onMessage", on_message_fn);

    // onKeyBinding function
    var on_keybind_fn: napi_value = undefined;
    _ = napi_create_function(env, "onKeyBinding", 12, &napi_onKeyBinding, null, &on_keybind_fn);
    _ = napi_set_named_property(env, exports, "onKeyBinding", on_keybind_fn);

    // addKeyBinding function
    var add_keybind_fn: napi_value = undefined;
    _ = napi_create_function(env, "addKeyBinding", 13, &napi_addKeyBinding, null, &add_keybind_fn);
    _ = napi_set_named_property(env, exports, "addKeyBinding", add_keybind_fn);

    // removeKeyBinding function
    var remove_keybind_fn: napi_value = undefined;
    _ = napi_create_function(env, "removeKeyBinding", 16, &napi_removeKeyBinding, null, &remove_keybind_fn);
    _ = napi_set_named_property(env, exports, "removeKeyBinding", remove_keybind_fn);

    // version function
    var version_fn: napi_value = undefined;
    _ = napi_create_function(env, "version", 7, &napi_version, null, &version_fn);
    _ = napi_set_named_property(env, exports, "version", version_fn);

    // isSupported function
    var is_supported_fn: napi_value = undefined;
    _ = napi_create_function(env, "isSupported", 11, &napi_isSupported, null, &is_supported_fn);
    _ = napi_set_named_property(env, exports, "isSupported", is_supported_fn);

    return exports;
}
