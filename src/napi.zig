const std = @import("std");
const build_options = @import("build_options");

const detector = @import("chrome/detector.zig");
const launcher = @import("chrome/launcher.zig");
const cdp = @import("chrome/cdp_client.zig");
const screenshot_api = @import("chrome/screenshot.zig");
const terminal_mod = @import("terminal/terminal.zig");
const viewer_mod = @import("viewer.zig");
const toolbar_mod = @import("ui/toolbar.zig");

const VERSION = build_options.version;

// Node-API types
const napi_env = *opaque {};
const napi_value = *opaque {};
const napi_callback_info = *opaque {};

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
extern fn napi_typeof(env: napi_env, value: napi_value, result: *c_uint) napi_status;
extern fn napi_get_undefined(env: napi_env, result: *napi_value) napi_status;
extern fn napi_get_boolean(env: napi_env, value: bool, result: *napi_value) napi_status;
extern fn napi_throw_error(env: napi_env, code: ?[*:0]const u8, msg: [*:0]const u8) napi_status;

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
    var mobile = false;
    var scale: f32 = 1.0;
    var no_profile = false;

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
        }
    }

    // Run browser (blocking)
    runBrowser(allocator, url, no_toolbar, mobile, scale, no_profile) catch |err| {
        std.debug.print("Error: {}\n", .{err});
    };

    var undef: napi_value = undefined;
    _ = napi_get_undefined(env, &undef);
    return undef;
}

fn runBrowser(allocator: std.mem.Allocator, url: []const u8, no_toolbar: bool, mobile: bool, scale: f32, no_profile: bool) !void {
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

    var viewport_width: u32 = raw_width / dpr;
    var viewport_height: u32 = content_pixel_height / dpr;

    const MAX_PIXELS: u64 = 1_500_000;
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
    };
    if (no_profile) {
        launch_opts.clone_profile = null;
    }

    var chrome_instance = try launcher.launchChromePipe(allocator, launch_opts);
    defer chrome_instance.deinit();

    // Connect CDP
    var client = try cdp.CdpClient.initFromPipe(allocator, chrome_instance.read_fd, chrome_instance.write_fd, chrome_instance.debug_port);
    defer client.deinit();

    // Set viewport
    try screenshot_api.setViewport(client, allocator, viewport_width, viewport_height);

    // Navigate
    try screenshot_api.navigateToUrl(client, allocator, url);

    // Get actual viewport
    var actual_viewport_width = viewport_width;
    var actual_viewport_height = viewport_height;
    if (screenshot_api.getActualViewport(client, allocator)) |actual_vp| {
        if (actual_vp.width > 0) actual_viewport_width = actual_vp.width;
        if (actual_vp.height > 0) actual_viewport_height = actual_vp.height;
    } else |_| {}

    // Run viewer
    var viewer = try viewer_mod.Viewer.init(allocator, client, url, actual_viewport_width, actual_viewport_height);
    defer viewer.deinit();

    if (no_toolbar) {
        viewer.disableToolbar();
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

/// Module initialization
export fn napi_register_module_v1(env: napi_env, exports: napi_value) napi_value {
    // open function
    var open_fn: napi_value = undefined;
    _ = napi_create_function(env, "open", 4, &napi_open, null, &open_fn);
    _ = napi_set_named_property(env, exports, "open", open_fn);

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
