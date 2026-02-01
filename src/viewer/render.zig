/// Rendering functions for the viewer.
/// Handles screencast frames, cursor, and toolbar rendering.
const std = @import("std");
const config = @import("../config.zig").Config;
const kitty_mod = @import("../terminal/kitty_graphics.zig");
const coordinates_mod = @import("../terminal/coordinates.zig");
const screenshot_api = @import("../chrome/screenshot.zig");
const ui_mod = @import("../ui/mod.zig");
const adaptive = @import("adaptive.zig");

const CoordinateMapper = coordinates_mod.CoordinateMapper;
const Placement = ui_mod.Placement;
const ZIndex = ui_mod.ZIndex;
const cursor_asset = ui_mod.assets.cursor;

/// Render a placeholder for blank pages (about:blank, new tab, etc.)
/// Shows centered help with keyboard shortcuts
pub fn renderBlankPage(viewer: anytype) void {
    const stdout = std.fs.File.stdout();
    const size = viewer.terminal.getSize() catch return;

    // Help text - shortcuts aligned in two columns
    const title = "New Tab";
    const help_lines = [_]struct { key: []const u8, desc: []const u8 }{
        .{ .key = "Ctrl+L", .desc = "Address bar" },
        .{ .key = "Ctrl+N", .desc = "New tab" },
        .{ .key = "Ctrl+W", .desc = "Close tab" },
        .{ .key = "Ctrl+T", .desc = "Tab picker" },
        .{ .key = "Ctrl+R", .desc = "Reload" },
        .{ .key = "Ctrl+[", .desc = "Back" },
        .{ .key = "Ctrl+]", .desc = "Forward" },
        .{ .key = "Ctrl+H", .desc = "Link hints" },
        .{ .key = "Ctrl+J/K", .desc = "Scroll" },
        .{ .key = "Ctrl+Q", .desc = "Quit" },
    };

    // Calculate vertical center
    const total_lines = 1 + 1 + help_lines.len; // title + gap + help
    const start_row = if (size.rows > total_lines) (size.rows - @as(u16, @intCast(total_lines))) / 2 else 2;

    var buf: [2048]u8 = undefined;
    var offset: usize = 0;

    // Delete content image by ID=100 (use uppercase I to delete all placements)
    const delete_cmd = "\x1b_Ga=d,d=I,i=100\x1b\\";
    @memcpy(buf[offset..][0..delete_cmd.len], delete_cmd);
    offset += delete_cmd.len;

    // Move to row 2, column 1 and set dark gray background
    const bg_seq = "\x1b[2;1H\x1b[48;5;234m";
    @memcpy(buf[offset..][0..bg_seq.len], bg_seq);
    offset += bg_seq.len;

    // Clear from cursor to end of screen (fills with current background)
    const clear_seq = "\x1b[J";
    @memcpy(buf[offset..][0..clear_seq.len], clear_seq);
    offset += clear_seq.len;

    // Print title (bold white on dark bg)
    const title_col = if (size.cols > title.len) (size.cols - @as(u16, @intCast(title.len))) / 2 else 1;
    const title_seq = std.fmt.bufPrint(buf[offset..], "\x1b[{d};{d}H\x1b[1;97;48;5;234m{s}", .{
        start_row,
        title_col,
        title,
    }) catch return;
    offset += title_seq.len;

    // Print help lines (key in bright white, desc in gray)
    // Format: "Ctrl+L   Address bar" - key padded to 8 chars
    const line_width = 24; // Total line width
    const base_col = if (size.cols > line_width) (size.cols - line_width) / 2 else 1;

    for (help_lines, 0..) |item, i| {
        const row = start_row + 2 + @as(u16, @intCast(i));

        // Format: key (8 chars padded) + "  " + desc
        const line_seq = std.fmt.bufPrint(buf[offset..], "\x1b[{d};{d}H\x1b[1;97;48;5;234m{s: <8}\x1b[0;38;5;250;48;5;234m  {s}", .{
            row,
            base_col,
            item.key,
            item.desc,
        }) catch break;
        offset += line_seq.len;
    }

    // Reset attributes at end
    const reset_seq = "\x1b[0m";
    @memcpy(buf[offset..][0..reset_seq.len], reset_seq);
    offset += reset_seq.len;

    // Write all at once
    _ = stdout.write(buf[0..offset]) catch {};

    viewer.last_content_image_id = null;
    viewer.last_rendered_generation = 0;

    // Mark as showing blank page placeholder to prevent screencast overwrite
    viewer.showing_blank_placeholder = true;
}

/// Get maximum FPS (returns viewer's target_fps)
pub fn getTargetFps(viewer: anytype) u32 {
    return viewer.target_fps;
}

/// Get minimum frame interval based on target FPS
pub fn getMinFrameInterval(viewer: anytype) i128 {
    return @divFloor(std.time.ns_per_s, viewer.target_fps);
}

/// Try to render latest screencast frame (non-blocking)
/// Returns true if frame was rendered, false if no new frame
pub fn tryRenderScreencast(viewer: anytype) !bool {
    // Skip rendering if showing blank page placeholder
    if (viewer.showing_blank_placeholder) {
        // Still consume frames to keep queue clear, but don't render
        if (screenshot_api.getLatestScreencastFrame(viewer.cdp_client)) |f| {
            var frame = f;
            frame.deinit();
        }
        return false;
    }

    const now = std.time.nanoTimestamp();

    // Get frame with proper ownership - MUST call deinit when done
    // This also triggers ACK logic for adaptive throttling
    var frame = screenshot_api.getLatestScreencastFrame(viewer.cdp_client) orelse return false;
    defer frame.deinit(); // Proper cleanup!

    // Set baseline on first frame (expected size without download bar etc)
    if (viewer.baseline_frame_height == 0 and frame.device_height > 0) {
        viewer.baseline_frame_width = frame.device_width;
        viewer.baseline_frame_height = frame.device_height;
        viewer.log("[RENDER] Baseline set: {}x{}\n", .{ viewer.baseline_frame_width, viewer.baseline_frame_height });
    }

    // Detect Chrome viewport change (e.g. download bar appearing)
    if (viewer.last_device_height > 0 and frame.device_height != viewer.last_device_height) {
        viewer.log("[RENDER] Chrome viewport changed: {}x{} -> {}x{}\n", .{
            viewer.last_device_width, viewer.last_device_height, frame.device_width, frame.device_height,
        });
        // Update chrome inner dimensions for coordinate mapping
        viewer.chrome_inner_width = frame.device_width;
        viewer.chrome_inner_height = frame.device_height;
    }
    viewer.last_device_width = frame.device_width;
    viewer.last_device_height = frame.device_height;

    // Calculate vertical offset if viewport shrunk (download bar took space)
    const y_offset: u32 = if (viewer.baseline_frame_height > frame.device_height)
        viewer.baseline_frame_height - frame.device_height
    else
        0;
    if (y_offset > 0) {
        viewer.log("[RENDER] Download bar offset: {}px\n", .{y_offset});
    }

    // Use actual frame dimensions from Chrome (respects viewport changes like download bar)
    const frame_width = if (frame.device_width > 0) frame.device_width else viewer.viewport_width;
    const frame_height = if (frame.device_height > 0) frame.device_height else viewer.viewport_height;

    // Detect frame dimension change and skip first changed frame to avoid visual glitch
    const frame_changed = viewer.last_frame_width > 0 and
        (frame_width != viewer.last_frame_width or frame_height != viewer.last_frame_height);

    // Update stored frame dimensions
    viewer.last_frame_width = frame_width;
    viewer.last_frame_height = frame_height;

    // On dimension change, delete old image to avoid visual artifacts
    if (frame_changed) {
        viewer.log("[RENDER] Frame dimensions changed {}x{} -> {}x{}\n", .{
            viewer.last_frame_width, viewer.last_frame_height, frame_width, frame_height,
        });
        // Delete old content image by ID using escape sequence
        if (viewer.last_content_image_id != null) {
            // Kitty delete image: \x1b_Ga=d,d=I,i=<id>\x1b\\
            const stdout = std.fs.File.stdout();
            _ = stdout.write("\x1b_Ga=d,d=I,i=100\x1b\\") catch {};
            viewer.last_content_image_id = null;
        }
    }

    // Throttle: Don't re-render the same frame multiple times
    if (viewer.last_rendered_generation > 0 and frame.generation <= viewer.last_rendered_generation) {
        return false;
    }

    // Frame skip detection: Check if we skipped frames
    if (viewer.last_rendered_generation > 0 and frame.generation > viewer.last_rendered_generation + 1) {
        const skipped = frame.generation - viewer.last_rendered_generation - 1;
        viewer.frames_skipped += @intCast(skipped);
        viewer.log("[RENDER] Skipped {} frames (gen {} -> {})\n", .{
            skipped,
            viewer.last_rendered_generation,
            frame.generation,
        });
    }
    viewer.last_rendered_generation = frame.generation;

    // Debug: Log frame dimensions (source of truth for coordinates)
    if (viewer.perf_frame_count < 5) {
        viewer.log("[FRAME] frame={}x{} (device={}x{})\n", .{
            frame_width, frame_height, frame.device_width, frame.device_height,
        });
    }

    // Profile render time
    const render_start = std.time.nanoTimestamp();

    // Use stored dimensions (single source of truth, already updated above)
    try displayFrameWithDimensions(viewer, frame.data);

    const render_elapsed = std.time.nanoTimestamp() - render_start;
    viewer.perf_frame_count += 1;
    viewer.perf_total_render_ns += render_elapsed;
    if (render_elapsed > viewer.perf_max_render_ns) {
        viewer.perf_max_render_ns = render_elapsed;
    }

    // Calculate write latency (Zig processing + terminal write)
    const write_latency_ms: f32 = @floatFromInt(@divFloor(render_elapsed, std.time.ns_per_ms));

    // Update adaptive quality controller with latency data (but don't restart - disabled for debugging)
    _ = viewer.adaptive_state.processFrame(frame.chrome_timestamp_ms, write_latency_ms);
    // Adaptive tier restart disabled - was causing display issues

    // Log performance stats every 5 seconds
    if (now - viewer.perf_last_report_time > 5 * std.time.ns_per_s) {
        const avg_ms = if (viewer.perf_frame_count > 0)
            @divFloor(@divFloor(viewer.perf_total_render_ns, @as(i128, viewer.perf_frame_count)), @as(i128, std.time.ns_per_ms))
        else
            0;
        const max_ms = @divFloor(viewer.perf_max_render_ns, @as(i128, std.time.ns_per_ms));

        viewer.log("[PERF] {} frames, avg={}ms, max={}ms, target={}fps, skipped={}, tier={} ({s}), latency_ema={d:.1}ms\n", .{
            viewer.perf_frame_count,
            avg_ms,
            max_ms,
            viewer.target_fps,
            viewer.frames_skipped,
            viewer.adaptive_state.tier,
            viewer.adaptive_state.getName(),
            viewer.adaptive_state.latency_ema_ms,
        });

        // Reset counters
        viewer.perf_frame_count = 0;
        viewer.perf_total_render_ns = 0;
        viewer.perf_max_render_ns = 0;
        viewer.perf_last_report_time = now;
    }

    viewer.last_frame_time = now;
    return true;
}

/// Display a base64 PNG frame using stored dimensions (single source of truth)
pub fn displayFrameWithDimensions(viewer: anytype, base64_png: []const u8) !void {
    const render_t0 = std.time.nanoTimestamp();

    // Use stored frame dimensions (updated in tryRenderScreencast)
    const frame_width = viewer.last_frame_width;
    const frame_height = viewer.last_frame_height;

    // Larger buffer reduces write syscalls (frames can be 300KB+)
    var stdout_buf: [262144]u8 = undefined; // 256KB buffer
    const stdout_file = std.fs.File.stdout();
    var stdout_writer = stdout_file.writer(&stdout_buf);
    const writer = &stdout_writer.interface;

    // Get terminal size
    const size = try viewer.terminal.getSize();
    const display_cols: u16 = if (size.cols > 0) size.cols else 80;

    // Calculate cell dimensions
    const cell_width: u32 = if (size.cols > 0) size.width_px / size.cols else 14;
    const cell_height: u32 = if (size.rows > 0) size.height_px / size.rows else 20;
    const toolbar_h: u32 = if (viewer.toolbar_renderer) |tr| tr.toolbar_height else cell_height;

    // Chrome coords: Use Chrome's actual window.innerWidth/Height
    // Fall back to frame dimensions if not yet set (before ResizeObserver fires)
    const chrome_width: u32 = if (viewer.chrome_inner_width > 0) viewer.chrome_inner_width else frame_width;
    const chrome_height: u32 = if (viewer.chrome_inner_height > 0) viewer.chrome_inner_height else frame_height;

    // Content starts at row 2, with y_offset to align with toolbar bottom
    // This avoids gaps between toolbar and content
    const row_start_pixel = cell_height; // Row 2 starts at 1 * cell_height
    const y_offset: u32 = if (toolbar_h > row_start_pixel) toolbar_h - row_start_pixel else 0;

    // Calculate content rows based on frame aspect ratio (no stretching)
    const display_pixel_width: u32 = @as(u32, display_cols) * cell_width;
    const aspect_pixel_height: u32 = if (frame_width > 0)
        (display_pixel_width * frame_height) / frame_width
    else
        frame_height;

    // Cap to terminal height, preserve aspect ratio
    const max_content_height: u32 = if (size.height_px > toolbar_h)
        size.height_px - @as(u16, @intCast(toolbar_h))
    else
        size.height_px;
    const content_height = @min(aspect_pixel_height, max_content_height);
    const content_rows: u32 = if (cell_height > 0) content_height / cell_height else 1;

    // Update coordinate mapper using DISPLAY dimensions (where content is actually shown)
    // Content width = display_cols * cell_width (may be less than terminal width)
    // Content height = content_rows * cell_height (preserves frame aspect ratio)
    const mapper_content_h: u16 = @intCast(content_rows * cell_height);
    viewer.coord_mapper = CoordinateMapper.initFull(
        @intCast(display_pixel_width), // Display width, not terminal width
        size.height_px,
        size.cols,
        size.rows,
        frame_width,
        frame_height,
        chrome_width,
        chrome_height,
        @intCast(toolbar_h),
        null,
        mapper_content_h, // Pass actual content height instead of calculating from terminal
    );

    viewer.log("[RENDER] displayFrame: base64={} bytes, term={}x{}, display={}x{}, frame={}x{}, chrome={}x{}, y_off={}\n", .{
        base64_png.len, size.cols, size.rows, display_cols, content_rows, frame_width, frame_height, chrome_width, chrome_height, y_offset,
    });

    // Move cursor to row 2
    try writer.writeAll("\x1b[2;1H");

    // Use fixed image_id AND placement_id for content - Kitty replaces in-place (no accumulation)
    // In hint mode, use negative z-index so text hints appear on top
    const z_index: i32 = if (viewer.mode == .hint_mode) -1 else 0;
    const display_opts = kitty_mod.DisplayOptions{
        .rows = content_rows,
        .columns = display_cols,
        .y_offset = @intCast(y_offset),
        .image_id = 100, // Fixed ID for content image data
        .placement_id = 100, // Fixed placement ID to replace (not accumulate)
        .z = z_index,
        // Explicit dimensions for PNG (required for some terminals over SSH)
        .width = frame_width,
        .height = frame_height,
    };

    const render_t1 = std.time.nanoTimestamp();

    // NOTE: Don't delete old image - Kitty replaces it when we use same image_id
    // Deleting first causes flash (white bar) as terminal background shows through

    // Try SHM path first
    var used_shm = false;
    if (viewer.shm_buffer) |*shm| {
        if (viewer.kitty.displayBase64ImageViaSHM(writer, base64_png, shm, display_opts) catch null) |id| {
            viewer.log("[RENDER] displayFrame via SHM complete (id={d})\n", .{id});
            viewer.last_content_image_id = id;
            used_shm = true;
        } else {
            viewer.log("[RENDER] SHM path failed, falling back to base64\n", .{});
        }
    }

    const render_t2 = std.time.nanoTimestamp();

    // Fallback: Display via base64
    if (!used_shm) {
        const id = if (viewer.screencast_format == .png)
            try viewer.kitty.displayBase64PNG(writer, base64_png, display_opts)
        else
            try viewer.kitty.displayBase64Image(writer, base64_png, display_opts);
        viewer.last_content_image_id = id;
        viewer.log("[RENDER] displayFrame via base64 complete (id={d})\n", .{id});
    }

    const render_t3 = std.time.nanoTimestamp();

    try writer.flush();

    const render_t4 = std.time.nanoTimestamp();
    const render_t5 = render_t4;
    const setup_ms = @divFloor(render_t1 - render_t0, std.time.ns_per_ms);
    const shm_ms = @divFloor(render_t2 - render_t1, std.time.ns_per_ms);
    const base64_ms = @divFloor(render_t3 - render_t2, std.time.ns_per_ms);
    const flush_ms = @divFloor(render_t4 - render_t3, std.time.ns_per_ms);
    const cleanup_ms = @divFloor(render_t5 - render_t4, std.time.ns_per_ms);
    const total_ms = @divFloor(render_t5 - render_t0, std.time.ns_per_ms);
    // Always log render timing to debug file
    viewer.log("[RENDER PERF] total={}ms setup={}ms shm={}ms base64={}ms flush={}ms cleanup={}ms\n", .{
        total_ms, setup_ms, shm_ms, base64_ms, flush_ms, cleanup_ms,
    });
}

/// Display a base64 PNG frame (legacy wrapper)
pub fn displayFrame(viewer: anytype, base64_png: []const u8) !void {
    try displayFrameWithDimensions(viewer, base64_png);
}

/// Render mouse cursor at current mouse position
pub fn renderCursor(viewer: anytype, writer: anytype) !void {
    if (!viewer.mouse_visible) return;

    // NOTE: Using fixed image_id=300, so Kitty replaces in-place (no delete needed)

    // With SGR pixel mode (1016h), mouse_x/y are pixel coordinates
    // Convert to cell coordinates for ANSI cursor positioning
    const mapper = viewer.coord_mapper orelse return;
    const cell_width = if (mapper.terminal_cols > 0)
        mapper.terminal_width_px / mapper.terminal_cols
    else
        14;
    const cell_height = mapper.cell_height;

    // Calculate cell position (1-indexed for ANSI)
    const cell_col = if (cell_width > 0) (viewer.mouse_x / cell_width) + 1 else 1;
    const cell_row = if (cell_height > 0) (viewer.mouse_y / cell_height) + 1 else 1;

    // Calculate pixel offset within cell for precise positioning
    const x_offset = if (cell_width > 0) viewer.mouse_x % cell_width else 0;
    const raw_y_offset = if (cell_height > 0) viewer.mouse_y % cell_height else 0;
    const y_offset = if (raw_y_offset > 0) raw_y_offset - 1 else 0; // Adjust for cursor tip alignment

    // Move cursor to cell position
    try writer.print("\x1b[{d};{d}H", .{ cell_row, cell_col });

    // Display cursor PNG with pixel offset for precision
    // Use fixed image_id to replace in-place (no delete needed)
    viewer.cursor_image_id = try viewer.kitty.displayPNG(writer, cursor_asset, .{
        .image_id = 300, // Fixed ID for cursor
        .placement_id = Placement.CURSOR,
        .z = ZIndex.CURSOR,
        .x_offset = x_offset,
        .y_offset = y_offset,
    });
}

/// Render the toolbar using Kitty graphics
pub fn renderToolbar(viewer: anytype, writer: anytype) !void {
    if (viewer.toolbar_renderer) |*renderer| {
        renderer.setNavState(viewer.ui_state.can_go_back, viewer.ui_state.can_go_forward, viewer.ui_state.is_loading);
        renderer.setUrl(viewer.current_url);
        try renderer.render(writer);
    }
}

/// Restart screencast with current adaptive quality tier settings
fn restartScreencastWithTier(viewer: anytype) !void {
    const quality = viewer.adaptive_state.getQuality();
    const every_nth = viewer.adaptive_state.getEveryNth();

    try screenshot_api.startScreencast(viewer.cdp_client, viewer.allocator, .{
        .format = viewer.screencast_format,
        .quality = quality,
        .width = viewer.viewport_width,
        .height = viewer.viewport_height,
        .every_nth_frame = every_nth,
    });
}
