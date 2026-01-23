/// Rendering functions for the viewer.
/// Handles screencast frames, cursor, and toolbar rendering.
const std = @import("std");
const kitty_mod = @import("../terminal/kitty_graphics.zig");
const coordinates_mod = @import("../terminal/coordinates.zig");
const screenshot_api = @import("../chrome/screenshot.zig");
const ui_mod = @import("../ui/mod.zig");

const CoordinateMapper = coordinates_mod.CoordinateMapper;
const Placement = ui_mod.Placement;
const ZIndex = ui_mod.ZIndex;
const cursor_asset = ui_mod.assets.cursor;

/// Get maximum FPS based on viewport resolution
pub fn getMaxFpsForResolution(viewport_width: u32, viewport_height: u32) u32 {
    _ = viewport_width;
    _ = viewport_height;
    return 24; // Fixed 24 FPS
}

/// Get minimum frame interval based on resolution
pub fn getMinFrameInterval(viewport_width: u32, viewport_height: u32) i128 {
    const target_fps = getMaxFpsForResolution(viewport_width, viewport_height);
    return @divFloor(std.time.ns_per_s, target_fps);
}

/// Try to render latest screencast frame (non-blocking)
/// Returns true if frame was rendered, false if no new frame
pub fn tryRenderScreencast(viewer: anytype) !bool {
    const now = std.time.nanoTimestamp();

    // Get frame with proper ownership - MUST call deinit when done
    // This also triggers ACK logic for adaptive throttling
    var frame = screenshot_api.getLatestScreencastFrame(viewer.cdp_client) orelse return false;
    defer frame.deinit(); // Proper cleanup!

    // Resolution-based FPS limiting (check AFTER getting frame to ensure ACKs flow)
    const min_interval = getMinFrameInterval(viewer.viewport_width, viewer.viewport_height);
    if (viewer.last_frame_time > 0 and (now - viewer.last_frame_time) < min_interval) {
        viewer.log("[RENDER] FPS throttle: skipping frame gen={} (too soon)\n", .{frame.generation});
        return false; // Too soon, skip render but frame was ACKed
    }

    // Throttle: Don't re-render the same frame multiple times
    if (viewer.last_rendered_generation > 0 and frame.generation <= viewer.last_rendered_generation) {
        viewer.log("[RENDER] Gen throttle: skipping frame gen={} (already rendered {})\n", .{ frame.generation, viewer.last_rendered_generation });
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

    // Use ACTUAL frame dimensions from CDP metadata for coordinate mapping
    // Chrome may send different size than requested viewport
    const frame_width = if (frame.device_width > 0) frame.device_width else viewer.viewport_width;
    const frame_height = if (frame.device_height > 0) frame.device_height else viewer.viewport_height;

    // NOTE: Do NOT use frame dimensions for coordinate mapping!
    // Screencast frames may be smaller than Chrome's actual viewport due to DPI scaling.
    // Mouse events must map to Chrome's window.innerWidth/Height (from refreshChromeViewport).
    // Frame: 886x980 (what we display) vs Chrome viewport: 984x1088 (where clicks go)

    // Debug: Log actual frame dimensions from Chrome
    if (viewer.perf_frame_count < 5) {
        viewer.log("[FRAME] device={}x{} (raw={}x{}), chrome={}x{}\n", .{
            frame_width, frame_height, frame.device_width, frame.device_height,
            viewer.chrome_actual_width, viewer.chrome_actual_height,
        });
    }

    // Profile render time
    const render_start = std.time.nanoTimestamp();

    try displayFrameWithDimensions(viewer, frame.data, frame_width, frame_height);

    const render_elapsed = std.time.nanoTimestamp() - render_start;
    viewer.perf_frame_count += 1;
    viewer.perf_total_render_ns += render_elapsed;
    if (render_elapsed > viewer.perf_max_render_ns) {
        viewer.perf_max_render_ns = render_elapsed;
    }

    // Log performance stats every 5 seconds
    if (now - viewer.perf_last_report_time > 5 * std.time.ns_per_s) {
        const avg_ms = if (viewer.perf_frame_count > 0)
            @divFloor(@divFloor(viewer.perf_total_render_ns, @as(i128, viewer.perf_frame_count)), @as(i128, std.time.ns_per_ms))
        else
            0;
        const max_ms = @divFloor(viewer.perf_max_render_ns, @as(i128, std.time.ns_per_ms));
        const target_fps = getMaxFpsForResolution(viewer.viewport_width, viewer.viewport_height);

        viewer.log("[PERF] {} frames, avg={}ms, max={}ms, target={}fps, skipped={}, content_id={?}, cursor_id={?}, gen={}\n", .{
            viewer.perf_frame_count, avg_ms, max_ms, target_fps, viewer.frames_skipped,
            viewer.last_content_image_id, viewer.cursor_image_id, viewer.last_rendered_generation,
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

/// Display a base64 PNG frame with specific dimensions for coordinate mapping
pub fn displayFrameWithDimensions(viewer: anytype, base64_png: []const u8, frame_width: u32, frame_height: u32) !void {
    const render_t0 = std.time.nanoTimestamp();

    // Larger buffer reduces write syscalls (frames can be 300KB+)
    var stdout_buf: [65536]u8 = undefined; // 64KB buffer
    const stdout_file = std.fs.File.stdout();
    var stdout_writer = stdout_file.writer(&stdout_buf);
    const writer = &stdout_writer.interface;

    // Get terminal size
    const size = try viewer.terminal.getSize();
    const display_cols: u16 = if (size.cols > 0) size.cols else 80;

    // Calculate cell height and toolbar rows
    const cell_height: u32 = if (size.rows > 0) size.height_px / size.rows else 20;
    const toolbar_h: u32 = if (viewer.toolbar_renderer) |tr| tr.toolbar_height else cell_height;

    // Content starts at row 2, with y_offset to align with toolbar bottom
    // This avoids gaps between toolbar and content
    const row_start_pixel = cell_height; // Row 2 starts at 1 * cell_height
    const y_offset: u32 = if (toolbar_h > row_start_pixel) toolbar_h - row_start_pixel else 0;

    // Calculate content rows (account for toolbar pixel height, not row count)
    const content_pixel_start = row_start_pixel + y_offset; // = toolbar_h
    const content_pixel_height = if (size.height_px > content_pixel_start)
        size.height_px - content_pixel_start
    else
        size.height_px;
    const content_rows: u32 = content_pixel_height / cell_height;

    // Update coordinate mapper with Chrome's ACTUAL viewport (source of truth)
    // Chrome's window.innerWidth/Height is where mouse events are dispatched
    viewer.coord_mapper = CoordinateMapper.initWithToolbar(
        size.width_px,
        size.height_px,
        size.cols,
        size.rows,
        viewer.chrome_actual_width, // Chrome's actual viewport, not frame size
        viewer.chrome_actual_height,
        @intCast(toolbar_h),
        null, // auto-detect pixel mode
    );

    viewer.log("[RENDER] displayFrame: base64={} bytes, term={}x{}, display={}x{}, frame={}x{}, chrome={}x{}, y_off={}\n", .{
        base64_png.len, size.cols, size.rows, display_cols, content_rows, frame_width, frame_height,
        viewer.chrome_actual_width, viewer.chrome_actual_height, y_offset,
    });

    // Move cursor to row 2
    try writer.writeAll("\x1b[2;1H");

    // Like awrit: first frame gets auto-increment ID, subsequent frames reuse it
    // No z-index needed now that SHM write pattern is correct
    const display_opts = kitty_mod.DisplayOptions{
        .rows = content_rows,
        .columns = display_cols,
        .y_offset = @intCast(y_offset),
        .image_id = viewer.last_content_image_id,
    };

    const render_t1 = std.time.nanoTimestamp();

    // Delete old image before reusing ID (Kitty requires this for replacement)
    if (viewer.last_content_image_id) |old_id| {
        viewer.kitty.deleteImage(writer, old_id) catch {};
    }

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

/// Display a base64 PNG frame (legacy, uses viewport dimensions)
pub fn displayFrame(viewer: anytype, base64_png: []const u8) !void {
    try displayFrameWithDimensions(viewer, base64_png, viewer.viewport_width, viewer.viewport_height);
}

/// Render mouse cursor at current mouse position
pub fn renderCursor(viewer: anytype, writer: anytype) !void {
    if (!viewer.mouse_visible) return;

    // Delete old cursor image to prevent trailing
    if (viewer.cursor_image_id) |old_id| {
        try viewer.kitty.deleteImage(writer, old_id);
    }

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
    viewer.cursor_image_id = try viewer.kitty.displayPNG(writer, cursor_asset, .{
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
