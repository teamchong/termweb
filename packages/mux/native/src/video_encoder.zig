// VideoToolbox H.264 Encoder for macOS
// Zero-latency configuration for real-time terminal streaming
// Optimizations: CVPixelBufferPool, direct IOSurface encoding, Metal GPU sync

const std = @import("std");
const builtin = @import("builtin");

// Enable Metal GPU synchronization for direct IOSurface encoding (macOS only)
pub const use_metal_sync = builtin.os.tag == .macos;

// VideoToolbox and CoreMedia C imports
const c = @cImport({
    @cInclude("VideoToolbox/VideoToolbox.h");
    @cInclude("CoreMedia/CoreMedia.h");
    @cInclude("CoreVideo/CoreVideo.h");
    @cInclude("Accelerate/Accelerate.h");
    @cInclude("IOSurface/IOSurface.h");
});

// Metal imports for GPU synchronization (macOS only)
const metal = if (use_metal_sync) @cImport({
    @cInclude("Metal/Metal.h");
}) else struct {};

// Objective-C runtime for Metal calls
const objc = if (use_metal_sync) @cImport({
    @cInclude("objc/runtime.h");
    @cInclude("objc/message.h");
}) else struct {};

pub const EncodeResult = struct {
    data: []const u8,
    is_keyframe: bool,
};

pub const VideoEncoder = struct {
    session: c.VTCompressionSessionRef,
    // Encode dimensions (may be scaled down from source)
    width: u32,
    height: u32,
    // Source dimensions (original input size)
    source_width: u32,
    source_height: u32,
    frame_count: i64,
    allocator: std.mem.Allocator,

    // Output buffer - filled by callback
    output_buffer: []u8,
    output_len: usize,
    is_keyframe: bool,
    encode_pending: bool,

    // Scale buffer for downscaling (null if no scaling needed)
    scale_buffer: ?[]u8,

    // NV12 buffer for YUV420 conversion (Y plane + UV plane)
    nv12_buffer: []u8,

    // CVPixelBuffer pool for buffer reuse (reduces allocation overhead)
    pixel_buffer_pool: c.CVPixelBufferPoolRef,

    // Adaptive bitrate/FPS
    current_bitrate: u32,
    target_fps: u32,
    quality_level: u8, // 0-4: 0=lowest, 4=highest

    const MAX_OUTPUT_SIZE = 2 * 1024 * 1024; // 2MB max per frame
    const MAX_PIXELS: u64 = 1920 * 1080; // ~2MP, roughly 1080p

    // Quality presets - FPS fixed at 30, only bitrate varies
    const QUALITY_PRESETS = [_]struct { bitrate: u32, fps: u32 }{
        .{ .bitrate = 2_000_000, .fps = 30 }, // Level 0: Low (2 Mbps)
        .{ .bitrate = 3_000_000, .fps = 30 }, // Level 1: Medium (3 Mbps)
        .{ .bitrate = 4_000_000, .fps = 30 }, // Level 2: High (4 Mbps)
        .{ .bitrate = 5_000_000, .fps = 30 }, // Level 3: Very high (5 Mbps)
        .{ .bitrate = 8_000_000, .fps = 30 }, // Level 4: Max (8 Mbps)
    };

    // Calculate scaled dimensions to fit within MAX_PIXELS while keeping aspect ratio
    fn calcScaledDimensions(width: u32, height: u32) struct { w: u32, h: u32 } {
        const pixels: u64 = @as(u64, width) * @as(u64, height);
        if (pixels <= MAX_PIXELS) {
            return .{ .w = width, .h = height };
        }
        // Scale down to fit within MAX_PIXELS
        const scale = @sqrt(@as(f64, @floatFromInt(MAX_PIXELS)) / @as(f64, @floatFromInt(pixels)));
        const new_w: u32 = @intFromFloat(@as(f64, @floatFromInt(width)) * scale);
        const new_h: u32 = @intFromFloat(@as(f64, @floatFromInt(height)) * scale);
        // Round to even numbers (required for H.264)
        return .{ .w = (new_w / 2) * 2, .h = (new_h / 2) * 2 };
    }

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !*VideoEncoder {
        const encoder = try allocator.create(VideoEncoder);
        errdefer allocator.destroy(encoder);

        const output_buffer = try allocator.alloc(u8, MAX_OUTPUT_SIZE);
        errdefer allocator.free(output_buffer);

        // Calculate encode dimensions (may be scaled down)
        const scaled = calcScaledDimensions(width, height);
        const encode_width = scaled.w;
        const encode_height = scaled.h;
        const needs_scaling = (encode_width != width or encode_height != height);

        std.debug.print("ENCODER: source={}x{} encode={}x{} scale={}\n", .{
            width, height, encode_width, encode_height, needs_scaling,
        });

        // Allocate scale buffer if needed
        var scale_buffer: ?[]u8 = null;
        if (needs_scaling) {
            scale_buffer = try allocator.alloc(u8, encode_width * encode_height * 4);
        }
        errdefer if (scale_buffer) |buf| allocator.free(buf);

        var session: c.VTCompressionSessionRef = null;

        // Create encoder specification to require hardware acceleration
        var encoder_spec_keys = [_]c.CFStringRef{
            c.kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder,
        };
        var encoder_spec_values = [_]c.CFTypeRef{
            @ptrCast(c.kCFBooleanTrue),
        };
        const encoder_spec = c.CFDictionaryCreate(
            null,
            @ptrCast(&encoder_spec_keys),
            @ptrCast(&encoder_spec_values),
            1,
            &c.kCFTypeDictionaryKeyCallBacks,
            &c.kCFTypeDictionaryValueCallBacks,
        );
        defer if (encoder_spec != null) c.CFRelease(encoder_spec);

        // Create compression session with SCALED dimensions
        const status = c.VTCompressionSessionCreate(
            null, // allocator
            @intCast(encode_width),
            @intCast(encode_height),
            c.kCMVideoCodecType_H264,
            encoder_spec, // encoder specification (prefer hardware)
            null, // source image buffer attributes
            null, // compressed data allocator
            compressionOutputCallback,
            encoder, // callback context = encoder pointer
            &session,
        );

        if (status != 0) {
            if (scale_buffer) |buf| allocator.free(buf);
            allocator.free(output_buffer);
            return error.EncoderCreationFailed;
        }

        // Allocate NV12 buffer for YUV420 conversion (Y + UV planes = 1.5 bytes per pixel)
        const nv12_size = encode_width * encode_height * 3 / 2;
        const nv12_buffer = try allocator.alloc(u8, nv12_size);
        errdefer allocator.free(nv12_buffer);

        // Create CVPixelBufferPool for efficient buffer reuse (NV12 format)
        const pixel_buffer_pool = createNV12PixelBufferPool(encode_width, encode_height) orelse {
            c.VTCompressionSessionInvalidate(session);
            c.CFRelease(session);
            if (scale_buffer) |buf| allocator.free(buf);
            allocator.free(nv12_buffer);
            allocator.free(output_buffer);
            return error.PixelBufferPoolCreationFailed;
        };

        encoder.* = .{
            .session = session,
            .width = encode_width,
            .height = encode_height,
            .source_width = width,
            .source_height = height,
            .frame_count = 0,
            .allocator = allocator,
            .output_buffer = output_buffer,
            .output_len = 0,
            .is_keyframe = false,
            .encode_pending = false,
            .scale_buffer = scale_buffer,
            .nv12_buffer = nv12_buffer,
            .pixel_buffer_pool = pixel_buffer_pool,
            .current_bitrate = 5_000_000, // Start at high quality
            .target_fps = 30,
            .quality_level = 3, // High
        };

        // Configure for zero latency
        try encoder.configureSession();

        return encoder;
    }

    fn createPixelBufferPool(width: u32, height: u32) ?c.CVPixelBufferPoolRef {
        // Pool attributes
        var pool_keys = [_]c.CFStringRef{
            c.kCVPixelBufferPoolMinimumBufferCountKey,
        };
        var min_count: c.SInt32 = 3; // Keep 3 buffers in pool
        const min_count_num = c.CFNumberCreate(null, c.kCFNumberSInt32Type, &min_count);
        defer if (min_count_num != null) c.CFRelease(min_count_num);

        var pool_values = [_]c.CFTypeRef{
            @ptrCast(min_count_num),
        };

        const pool_attrs = c.CFDictionaryCreate(
            null,
            @ptrCast(&pool_keys),
            @ptrCast(&pool_values),
            1,
            &c.kCFTypeDictionaryKeyCallBacks,
            &c.kCFTypeDictionaryValueCallBacks,
        );
        defer if (pool_attrs != null) c.CFRelease(pool_attrs);

        // Pixel buffer attributes
        var pb_keys = [_]c.CFStringRef{
            c.kCVPixelBufferWidthKey,
            c.kCVPixelBufferHeightKey,
            c.kCVPixelBufferPixelFormatTypeKey,
            c.kCVPixelBufferIOSurfacePropertiesKey,
        };

        var w: c.SInt32 = @intCast(width);
        var h: c.SInt32 = @intCast(height);
        var fmt: c.SInt32 = c.kCVPixelFormatType_32BGRA;

        const w_num = c.CFNumberCreate(null, c.kCFNumberSInt32Type, &w);
        const h_num = c.CFNumberCreate(null, c.kCFNumberSInt32Type, &h);
        const fmt_num = c.CFNumberCreate(null, c.kCFNumberSInt32Type, &fmt);
        const empty_dict = c.CFDictionaryCreate(null, null, null, 0, &c.kCFTypeDictionaryKeyCallBacks, &c.kCFTypeDictionaryValueCallBacks);

        defer {
            if (w_num != null) c.CFRelease(w_num);
            if (h_num != null) c.CFRelease(h_num);
            if (fmt_num != null) c.CFRelease(fmt_num);
            if (empty_dict != null) c.CFRelease(empty_dict);
        }

        var pb_values = [_]c.CFTypeRef{
            @ptrCast(w_num),
            @ptrCast(h_num),
            @ptrCast(fmt_num),
            @ptrCast(empty_dict),
        };

        const pb_attrs = c.CFDictionaryCreate(
            null,
            @ptrCast(&pb_keys),
            @ptrCast(&pb_values),
            4,
            &c.kCFTypeDictionaryKeyCallBacks,
            &c.kCFTypeDictionaryValueCallBacks,
        );
        defer if (pb_attrs != null) c.CFRelease(pb_attrs);

        var pool: c.CVPixelBufferPoolRef = null;
        const status = c.CVPixelBufferPoolCreate(null, pool_attrs, pb_attrs, &pool);
        if (status != 0) return null;

        return pool;
    }

    fn createNV12PixelBufferPool(width: u32, height: u32) ?c.CVPixelBufferPoolRef {
        // Pool attributes
        var pool_keys = [_]c.CFStringRef{
            c.kCVPixelBufferPoolMinimumBufferCountKey,
        };
        var min_count: c.SInt32 = 3;
        const min_count_num = c.CFNumberCreate(null, c.kCFNumberSInt32Type, &min_count);
        defer if (min_count_num != null) c.CFRelease(min_count_num);

        var pool_values = [_]c.CFTypeRef{
            @ptrCast(min_count_num),
        };

        const pool_attrs = c.CFDictionaryCreate(
            null,
            @ptrCast(&pool_keys),
            @ptrCast(&pool_values),
            1,
            &c.kCFTypeDictionaryKeyCallBacks,
            &c.kCFTypeDictionaryValueCallBacks,
        );
        defer if (pool_attrs != null) c.CFRelease(pool_attrs);

        // Pixel buffer attributes - NV12 format (420YpCbCr8BiPlanarVideoRange)
        var pb_keys = [_]c.CFStringRef{
            c.kCVPixelBufferWidthKey,
            c.kCVPixelBufferHeightKey,
            c.kCVPixelBufferPixelFormatTypeKey,
            c.kCVPixelBufferIOSurfacePropertiesKey,
        };

        var w: c.SInt32 = @intCast(width);
        var h: c.SInt32 = @intCast(height);
        var fmt: c.SInt32 = c.kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange; // NV12

        const w_num = c.CFNumberCreate(null, c.kCFNumberSInt32Type, &w);
        const h_num = c.CFNumberCreate(null, c.kCFNumberSInt32Type, &h);
        const fmt_num = c.CFNumberCreate(null, c.kCFNumberSInt32Type, &fmt);
        const empty_dict = c.CFDictionaryCreate(null, null, null, 0, &c.kCFTypeDictionaryKeyCallBacks, &c.kCFTypeDictionaryValueCallBacks);

        defer {
            if (w_num != null) c.CFRelease(w_num);
            if (h_num != null) c.CFRelease(h_num);
            if (fmt_num != null) c.CFRelease(fmt_num);
            if (empty_dict != null) c.CFRelease(empty_dict);
        }

        var pb_values = [_]c.CFTypeRef{
            @ptrCast(w_num),
            @ptrCast(h_num),
            @ptrCast(fmt_num),
            @ptrCast(empty_dict),
        };

        const pb_attrs = c.CFDictionaryCreate(
            null,
            @ptrCast(&pb_keys),
            @ptrCast(&pb_values),
            4,
            &c.kCFTypeDictionaryKeyCallBacks,
            &c.kCFTypeDictionaryValueCallBacks,
        );
        defer if (pb_attrs != null) c.CFRelease(pb_attrs);

        var pool: c.CVPixelBufferPoolRef = null;
        const status = c.CVPixelBufferPoolCreate(null, pool_attrs, pb_attrs, &pool);
        if (status != 0) return null;

        return pool;
    }

    // Convert BGRA to NV12 (YUV420 biplanar) using vImage
    // NV12 has Y plane (full res) followed by interleaved UV plane (half res)
    fn convertBGRAtoNV12(bgra: []const u8, nv12: []u8, width: u32, height: u32) void {
        const y_plane = nv12[0 .. width * height];
        const uv_plane = nv12[width * height ..];

        // Convert BGRA to Y plane (full resolution)
        // Y = 0.299*R + 0.587*G + 0.114*B (BT.601)
        // Using fixed point: Y = (77*R + 150*G + 29*B) >> 8
        var y: u32 = 0;
        while (y < height) : (y += 1) {
            var x: u32 = 0;
            while (x < width) : (x += 1) {
                const i = (y * width + x) * 4;
                const b = @as(u32, bgra[i]);
                const g = @as(u32, bgra[i + 1]);
                const r = @as(u32, bgra[i + 2]);
                // Y with offset 16 for video range
                y_plane[y * width + x] = @intCast(@min(255, 16 + ((66 * r + 129 * g + 25 * b + 128) >> 8)));
            }
        }

        // Convert BGRA to UV plane (half resolution, interleaved)
        // U = -0.169*R - 0.331*G + 0.500*B + 128
        // V = 0.500*R - 0.419*G - 0.081*B + 128
        var uv_y: u32 = 0;
        while (uv_y < height / 2) : (uv_y += 1) {
            var uv_x: u32 = 0;
            while (uv_x < width / 2) : (uv_x += 1) {
                // Sample 2x2 block and average
                const src_y = uv_y * 2;
                const src_x = uv_x * 2;

                var r_sum: u32 = 0;
                var g_sum: u32 = 0;
                var b_sum: u32 = 0;

                // 2x2 block
                inline for ([_]u32{ 0, 1 }) |dy| {
                    inline for ([_]u32{ 0, 1 }) |dx| {
                        const i = ((src_y + dy) * width + (src_x + dx)) * 4;
                        b_sum += bgra[i];
                        g_sum += bgra[i + 1];
                        r_sum += bgra[i + 2];
                    }
                }

                // Average
                const r = r_sum / 4;
                const g = g_sum / 4;
                const b = b_sum / 4;

                // U and V with video range offset
                const u_val: i32 = 128 + @as(i32, @intCast((@as(i32, -38) * @as(i32, @intCast(r)) - 74 * @as(i32, @intCast(g)) + 112 * @as(i32, @intCast(b)) + 128) >> 8));
                const v_val: i32 = 128 + @as(i32, @intCast((112 * @as(i32, @intCast(r)) - 94 * @as(i32, @intCast(g)) - 18 * @as(i32, @intCast(b)) + 128) >> 8));

                const uv_idx = (uv_y * (width / 2) + uv_x) * 2;
                uv_plane[uv_idx] = @intCast(@max(0, @min(255, u_val)));
                uv_plane[uv_idx + 1] = @intCast(@max(0, @min(255, v_val)));
            }
        }
    }

    fn configureSession(self: *VideoEncoder) !void {
        const session = self.session;

        // Real-time encoding (no buffering)
        _ = c.VTSessionSetProperty(session, c.kVTCompressionPropertyKey_RealTime, c.kCFBooleanTrue);

        // Prioritize speed over power efficiency
        _ = c.VTSessionSetProperty(session, c.kVTCompressionPropertyKey_MaximizePowerEfficiency, c.kCFBooleanFalse);

        // Prioritize encoding speed over quality (macOS 13+)
        _ = c.VTSessionSetProperty(session, c.kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, c.kCFBooleanTrue);

        // Disable B-frames (critical for zero latency)
        _ = c.VTSessionSetProperty(session, c.kVTCompressionPropertyKey_AllowFrameReordering, c.kCFBooleanFalse);

        // Set profile to Baseline (no B-frames, widely compatible)
        _ = c.VTSessionSetProperty(session, c.kVTCompressionPropertyKey_ProfileLevel, c.kVTProfileLevel_H264_Baseline_AutoLevel);

        // Keyframe interval (every 120 frames = 4 seconds at 30fps)
        var interval: c.SInt32 = 120;
        const keyframe_interval = c.CFNumberCreate(null, c.kCFNumberSInt32Type, &interval);
        if (keyframe_interval != null) {
            _ = c.VTSessionSetProperty(session, c.kVTCompressionPropertyKey_MaxKeyFrameInterval, keyframe_interval);
            c.CFRelease(keyframe_interval);
        }

        // Expected frame rate (30 fps)
        var fps: f64 = 30.0;
        const fps_number = c.CFNumberCreate(null, c.kCFNumberFloat64Type, &fps);
        if (fps_number != null) {
            _ = c.VTSessionSetProperty(session, c.kVTCompressionPropertyKey_ExpectedFrameRate, fps_number);
            c.CFRelease(fps_number);
        }

        // Lower bitrate for faster encoding (2 Mbps is enough for terminal text)
        var bitrate: c.SInt32 = 2_000_000;
        const bitrate_number = c.CFNumberCreate(null, c.kCFNumberSInt32Type, &bitrate);
        if (bitrate_number != null) {
            _ = c.VTSessionSetProperty(session, c.kVTCompressionPropertyKey_AverageBitRate, bitrate_number);
            c.CFRelease(bitrate_number);
        }

        // Prepare to encode
        _ = c.VTCompressionSessionPrepareToEncodeFrames(session);
    }

    pub fn deinit(self: *VideoEncoder) void {
        if (self.session != null) {
            c.VTCompressionSessionInvalidate(self.session);
            c.CFRelease(self.session);
        }
        if (self.pixel_buffer_pool != null) {
            c.CVPixelBufferPoolRelease(self.pixel_buffer_pool);
        }
        if (self.scale_buffer) |buf| self.allocator.free(buf);
        self.allocator.free(self.nv12_buffer);
        self.allocator.free(self.output_buffer);
        self.allocator.destroy(self);
    }

    // Adjust quality based on client buffer health (0-100)
    pub fn adjustQuality(self: *VideoEncoder, buffer_health: u8) void {
        if (buffer_health == 0) return;

        const new_level: u8 = if (buffer_health < 30)
            if (self.quality_level > 0) self.quality_level - 1 else 0
        else if (buffer_health > 70)
            if (self.quality_level < 4) self.quality_level + 1 else 4
        else
            self.quality_level;

        if (new_level != self.quality_level) {
            std.debug.print("QUALITY: level {d}->{d} (health={d}%)\n", .{
                self.quality_level, new_level, buffer_health,
            });
            self.quality_level = new_level;
            const preset = QUALITY_PRESETS[new_level];
            self.current_bitrate = preset.bitrate;
            self.target_fps = preset.fps;

            var bitrate: c.SInt32 = @intCast(preset.bitrate);
            const bitrate_number = c.CFNumberCreate(null, c.kCFNumberSInt32Type, &bitrate);
            if (bitrate_number != null) {
                _ = c.VTSessionSetProperty(self.session, c.kVTCompressionPropertyKey_AverageBitRate, bitrate_number);
                c.CFRelease(bitrate_number);
            }
        }
    }

    pub fn resize(self: *VideoEncoder, width: u32, height: u32) !void {
        if (self.source_width == width and self.source_height == height) return;

        const scaled = calcScaledDimensions(width, height);
        const encode_width = scaled.w;
        const encode_height = scaled.h;
        const needs_scaling = (encode_width != width or encode_height != height);

        std.debug.print("ENCODER RESIZE: source={}x{} encode={}x{} scale={}\n", .{
            width, height, encode_width, encode_height, needs_scaling,
        });

        // Reallocate scale buffer if needed
        if (self.scale_buffer) |buf| self.allocator.free(buf);
        self.scale_buffer = if (needs_scaling)
            try self.allocator.alloc(u8, encode_width * encode_height * 4)
        else
            null;

        // Reallocate NV12 buffer for new dimensions
        self.allocator.free(self.nv12_buffer);
        const nv12_size = encode_width * encode_height * 3 / 2;
        self.nv12_buffer = try self.allocator.alloc(u8, nv12_size);

        // Need to recreate session for new dimensions
        const old_session = self.session;

        var new_session: c.VTCompressionSessionRef = null;
        const status = c.VTCompressionSessionCreate(
            null,
            @intCast(encode_width),
            @intCast(encode_height),
            c.kCMVideoCodecType_H264,
            null,
            null,
            null,
            compressionOutputCallback,
            self,
            &new_session,
        );

        if (status != 0) return error.EncoderCreationFailed;

        if (old_session != null) {
            c.VTCompressionSessionInvalidate(old_session);
            c.CFRelease(old_session);
        }

        // Recreate pixel buffer pool for new dimensions (NV12 format)
        if (self.pixel_buffer_pool != null) {
            c.CVPixelBufferPoolRelease(self.pixel_buffer_pool);
        }
        self.pixel_buffer_pool = createNV12PixelBufferPool(encode_width, encode_height) orelse
            return error.PixelBufferPoolCreationFailed;

        self.session = new_session;
        self.width = encode_width;
        self.height = encode_height;
        self.source_width = width;
        self.source_height = height;
        self.frame_count = 0;

        try self.configureSession();
    }

    // Fast downscale using Accelerate vImage
    fn scaleDown(src: []const u8, src_w: u32, src_h: u32, dst: []u8, dst_w: u32, dst_h: u32) void {
        var src_buffer = c.vImage_Buffer{
            .data = @constCast(@ptrCast(src.ptr)),
            .height = src_h,
            .width = src_w,
            .rowBytes = src_w * 4,
        };

        var dst_buffer = c.vImage_Buffer{
            .data = @ptrCast(dst.ptr),
            .height = dst_h,
            .width = dst_w,
            .rowBytes = dst_w * 4,
        };

        // Use fast scaling (no high quality resampling - faster for real-time)
        _ = c.vImageScale_ARGB8888(&src_buffer, &dst_buffer, null, 0);
    }

    // Encode a BGRA frame, returns encoded H.264 data
    pub fn encode(self: *VideoEncoder, bgra_data: []const u8, force_keyframe: bool) !?EncodeResult {
        // Reset output
        self.output_len = 0;
        self.is_keyframe = false;
        self.encode_pending = true;

        _ = force_keyframe;

        // Scale down if needed
        const encode_data: []const u8 = if (self.scale_buffer) |scale_buf| blk: {
            scaleDown(bgra_data, self.source_width, self.source_height, scale_buf, self.width, self.height);
            break :blk scale_buf;
        } else bgra_data;

        // Create CVPixelBuffer wrapping BGRA data (hardware encoder converts to YUV internally)
        var pixel_buffer: c.CVPixelBufferRef = null;
        const status = c.CVPixelBufferCreateWithBytes(
            null,
            @intCast(self.width),
            @intCast(self.height),
            c.kCVPixelFormatType_32BGRA,
            @constCast(@ptrCast(encode_data.ptr)),
            self.width * 4,
            null,
            null,
            null,
            &pixel_buffer,
        );

        if (status != 0 or pixel_buffer == null) {
            self.encode_pending = false;
            return error.PixelBufferCreationFailed;
        }
        defer c.CVPixelBufferRelease(pixel_buffer);

        const pts = c.CMTimeMake(self.frame_count, 30);
        self.frame_count += 1;

        const encode_status = c.VTCompressionSessionEncodeFrame(
            self.session,
            pixel_buffer,
            pts,
            c.kCMTimeInvalid,
            null,
            null,
            null,
        );

        if (encode_status != 0) {
            self.encode_pending = false;
            return error.EncodeFailed;
        }

        // Force completion (synchronous output)
        _ = c.VTCompressionSessionCompleteFrames(self.session, c.kCMTimeInvalid);

        self.encode_pending = false;

        if (self.output_len == 0) {
            return null;
        }

        return .{
            .data = self.output_buffer[0..self.output_len],
            .is_keyframe = self.is_keyframe,
        };
    }

    // Check if direct IOSurface encoding is possible (no scaling needed)
    pub fn canEncodeDirectly(self: *VideoEncoder) bool {
        return self.width == self.source_width and self.height == self.source_height;
    }

    // Encode directly from IOSurface - ZERO COPY path (fastest)
    // Only works when no scaling is needed - check canEncodeDirectly() first
    // Uses *anyopaque to avoid cimport module type mismatch
    pub fn encodeFromIOSurface(self: *VideoEncoder, iosurface_ptr: *anyopaque, force_keyframe: bool) !?EncodeResult {
        _ = force_keyframe;
        const iosurface: c.IOSurfaceRef = @ptrCast(iosurface_ptr);

        // Reset output
        self.output_len = 0;
        self.is_keyframe = false;
        self.encode_pending = true;

        // GPU SYNC: Lock IOSurface for the entire encode operation
        // This ensures GPU has finished rendering and prevents modifications during encode
        const lock_status = c.IOSurfaceLock(iosurface, c.kIOSurfaceLockReadOnly, null);
        if (lock_status != 0) {
            self.encode_pending = false;
            return error.IOSurfaceLockFailed;
        }
        defer _ = c.IOSurfaceUnlock(iosurface, c.kIOSurfaceLockReadOnly, null);

        // Create CVPixelBuffer directly from IOSurface (zero-copy)
        var pixel_buffer: c.CVPixelBufferRef = null;

        const status = c.CVPixelBufferCreateWithIOSurface(
            null,
            iosurface,
            null,
            &pixel_buffer,
        );

        if (status != 0 or pixel_buffer == null) {
            self.encode_pending = false;
            return error.PixelBufferCreationFailed;
        }
        defer c.CVPixelBufferRelease(pixel_buffer);

        // Verify dimensions match (caller should have checked canEncodeDirectly)
        const surf_width: u32 = @intCast(c.CVPixelBufferGetWidth(pixel_buffer));
        const surf_height: u32 = @intCast(c.CVPixelBufferGetHeight(pixel_buffer));

        if (surf_width != self.width or surf_height != self.height) {
            // Scaling needed - caller should use regular encode() instead
            self.encode_pending = false;
            return error.ScalingRequired;
        }

        // Direct encode without scaling
        const pts = c.CMTimeMake(self.frame_count, 30);
        self.frame_count += 1;

        const encode_status = c.VTCompressionSessionEncodeFrame(
            self.session,
            pixel_buffer,
            pts,
            c.kCMTimeInvalid,
            null,
            null,
            null,
        );

        if (encode_status != 0) {
            self.encode_pending = false;
            return error.EncodeFailed;
        }

        // Force completion (synchronous output)
        _ = c.VTCompressionSessionCompleteFrames(self.session, c.kCMTimeInvalid);

        self.encode_pending = false;

        if (self.output_len == 0) {
            return null;
        }

        return .{
            .data = self.output_buffer[0..self.output_len],
            .is_keyframe = self.is_keyframe,
        };
    }
};

// Callback when encoded data is ready
fn compressionOutputCallback(
    output_callback_ref_con: ?*anyopaque,
    source_frame_ref_con: ?*anyopaque,
    status: c.OSStatus,
    info_flags: c.VTEncodeInfoFlags,
    sample_buffer: c.CMSampleBufferRef,
) callconv(.c) void {
    _ = source_frame_ref_con;
    _ = info_flags;

    if (status != 0 or sample_buffer == null) return;

    const encoder: *VideoEncoder = @ptrCast(@alignCast(output_callback_ref_con orelse return));
    if (!encoder.encode_pending) return;

    // Check if keyframe
    const attachments = c.CMSampleBufferGetSampleAttachmentsArray(sample_buffer, 0);
    var is_keyframe = false;
    if (attachments != null and c.CFArrayGetCount(attachments) > 0) {
        const dict: c.CFDictionaryRef = @ptrCast(c.CFArrayGetValueAtIndex(attachments, 0));
        if (dict != null) {
            const not_sync = c.CFDictionaryGetValue(dict, c.kCMSampleAttachmentKey_NotSync);
            is_keyframe = (not_sync == null);
        }
    }
    encoder.is_keyframe = is_keyframe;

    // Get format description for parameter sets (SPS/PPS)
    const format_desc = c.CMSampleBufferGetFormatDescription(sample_buffer);

    // For keyframes, prepend SPS and PPS
    if (is_keyframe and format_desc != null) {
        var sps_size: usize = 0;
        var sps_count: usize = 0;
        var sps_ptr: [*c]const u8 = undefined;
        _ = c.CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format_desc, 0, &sps_ptr, &sps_size, &sps_count, null,
        );

        var pps_size: usize = 0;
        var pps_count: usize = 0;
        var pps_ptr: [*c]const u8 = undefined;
        _ = c.CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format_desc, 1, &pps_ptr, &pps_size, &pps_count, null,
        );

        if (sps_size > 0 and encoder.output_len + 4 + sps_size < encoder.output_buffer.len) {
            encoder.output_buffer[encoder.output_len] = 0;
            encoder.output_buffer[encoder.output_len + 1] = 0;
            encoder.output_buffer[encoder.output_len + 2] = 0;
            encoder.output_buffer[encoder.output_len + 3] = 1;
            @memcpy(encoder.output_buffer[encoder.output_len + 4 ..][0..sps_size], sps_ptr[0..sps_size]);
            encoder.output_len += 4 + sps_size;
        }

        if (pps_size > 0 and encoder.output_len + 4 + pps_size < encoder.output_buffer.len) {
            encoder.output_buffer[encoder.output_len] = 0;
            encoder.output_buffer[encoder.output_len + 1] = 0;
            encoder.output_buffer[encoder.output_len + 2] = 0;
            encoder.output_buffer[encoder.output_len + 3] = 1;
            @memcpy(encoder.output_buffer[encoder.output_len + 4 ..][0..pps_size], pps_ptr[0..pps_size]);
            encoder.output_len += 4 + pps_size;
        }
    }

    // Get encoded data
    const data_buffer = c.CMSampleBufferGetDataBuffer(sample_buffer);
    if (data_buffer == null) return;

    var length: usize = 0;
    var data_ptr: [*c]u8 = undefined;
    const data_status = c.CMBlockBufferGetDataPointer(data_buffer, 0, null, &length, &data_ptr);
    if (data_status != 0) return;

    // Convert AVCC format to Annex B
    var offset: usize = 0;
    while (offset < length) {
        if (offset + 4 > length) break;
        const nal_length: u32 = (@as(u32, data_ptr[offset]) << 24) |
            (@as(u32, data_ptr[offset + 1]) << 16) |
            (@as(u32, data_ptr[offset + 2]) << 8) |
            @as(u32, data_ptr[offset + 3]);
        offset += 4;

        if (offset + nal_length > length) break;
        if (encoder.output_len + 4 + nal_length > encoder.output_buffer.len) break;

        encoder.output_buffer[encoder.output_len] = 0;
        encoder.output_buffer[encoder.output_len + 1] = 0;
        encoder.output_buffer[encoder.output_len + 2] = 0;
        encoder.output_buffer[encoder.output_len + 3] = 1;
        @memcpy(encoder.output_buffer[encoder.output_len + 4 ..][0..nal_length], data_ptr[offset..][0..nal_length]);
        encoder.output_len += 4 + nal_length;

        offset += nal_length;
    }
}
