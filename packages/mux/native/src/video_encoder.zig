// VideoToolbox H.264 Encoder for macOS
// Zero-latency configuration for real-time terminal streaming

const std = @import("std");

// VideoToolbox and CoreMedia C imports
const c = @cImport({
    @cInclude("VideoToolbox/VideoToolbox.h");
    @cInclude("CoreMedia/CoreMedia.h");
    @cInclude("CoreVideo/CoreVideo.h");
});

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

    // Adaptive bitrate/FPS
    current_bitrate: u32,
    target_fps: u32,
    quality_level: u8, // 0-4: 0=lowest, 4=highest

    const MAX_OUTPUT_SIZE = 2 * 1024 * 1024; // 2MB max per frame
    const MAX_PIXELS: u64 = 1920 * 1080; // ~2MP, roughly 1080p

    // Quality presets - FPS fixed at 30, only bitrate varies
    // Minimum 2 Mbps to keep encode time under 20ms for stable FPS
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
            .current_bitrate = 5_000_000, // Start at high quality
            .target_fps = 30,
            .quality_level = 3, // High
        };

        // Configure for zero latency
        try encoder.configureSession();

        return encoder;
    }

    fn configureSession(self: *VideoEncoder) !void {
        const session = self.session;

        // Real-time encoding (no buffering)
        _ = c.VTSessionSetProperty(session, c.kVTCompressionPropertyKey_RealTime, c.kCFBooleanTrue);

        // Prioritize speed over power efficiency
        _ = c.VTSessionSetProperty(session, c.kVTCompressionPropertyKey_MaximizePowerEfficiency, c.kCFBooleanFalse);

        // Disable B-frames (critical for zero latency)
        _ = c.VTSessionSetProperty(session, c.kVTCompressionPropertyKey_AllowFrameReordering, c.kCFBooleanFalse);

        // Set profile to Baseline (no B-frames, widely compatible)
        _ = c.VTSessionSetProperty(session, c.kVTCompressionPropertyKey_ProfileLevel, c.kVTProfileLevel_H264_Baseline_AutoLevel);

        // Keyframe interval (every 60 frames = 2 seconds at 30fps)
        var interval: c.SInt32 = 60;
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
        if (self.scale_buffer) |buf| self.allocator.free(buf);
        self.allocator.free(self.output_buffer);
        self.allocator.destroy(self);
    }

    // Adjust quality based on client buffer health (0-100)
    // Called from server when client reports buffer stats
    pub fn adjustQuality(self: *VideoEncoder, buffer_health: u8) void {
        // Ignore 0% health - usually means client is still loading
        if (buffer_health == 0) return;

        const new_level: u8 = if (buffer_health < 30)
            // Buffer starving - drop quality by 1
            if (self.quality_level > 0) self.quality_level - 1 else 0
        else if (buffer_health > 70)
            // Buffer healthy - increase quality by 1
            if (self.quality_level < 4) self.quality_level + 1 else 4
        else
            // Buffer ok - maintain current quality
            self.quality_level;

        if (new_level != self.quality_level) {
            std.debug.print("QUALITY: level {d}->{d} (health={d}%) fps={d} bitrate={d}\n", .{
                self.quality_level, new_level, buffer_health,
                QUALITY_PRESETS[new_level].fps, QUALITY_PRESETS[new_level].bitrate,
            });
            self.quality_level = new_level;
            const preset = QUALITY_PRESETS[new_level];
            self.current_bitrate = preset.bitrate;
            self.target_fps = preset.fps;

            // Update encoder bitrate
            var bitrate: c.SInt32 = @intCast(preset.bitrate);
            const bitrate_number = c.CFNumberCreate(null, c.kCFNumberSInt32Type, &bitrate);
            if (bitrate_number != null) {
                _ = c.VTSessionSetProperty(self.session, c.kVTCompressionPropertyKey_AverageBitRate, bitrate_number);
                c.CFRelease(bitrate_number);
            }

            // Update expected frame rate
            var fps: f64 = @floatFromInt(preset.fps);
            const fps_number = c.CFNumberCreate(null, c.kCFNumberFloat64Type, &fps);
            if (fps_number != null) {
                _ = c.VTSessionSetProperty(self.session, c.kVTCompressionPropertyKey_ExpectedFrameRate, fps_number);
                c.CFRelease(fps_number);
            }
        }
    }

    pub fn resize(self: *VideoEncoder, width: u32, height: u32) !void {
        if (self.source_width == width and self.source_height == height) return;

        // Calculate new encode dimensions
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

        // Clean up old session
        if (old_session != null) {
            c.VTCompressionSessionInvalidate(old_session);
            c.CFRelease(old_session);
        }

        self.session = new_session;
        self.width = encode_width;
        self.height = encode_height;
        self.source_width = width;
        self.source_height = height;
        self.frame_count = 0;

        try self.configureSession();
    }

    // Fast bilinear-ish downscale (point sample with offset for speed)
    fn scaleDown(src: []const u8, src_w: u32, src_h: u32, dst: []u8, dst_w: u32, dst_h: u32) void {
        const x_ratio: u32 = (src_w << 16) / dst_w;
        const y_ratio: u32 = (src_h << 16) / dst_h;

        var dst_offset: usize = 0;
        var y: u32 = 0;
        while (y < dst_h) : (y += 1) {
            const src_y = (y * y_ratio) >> 16;
            const src_row_offset = src_y * src_w * 4;

            var x: u32 = 0;
            while (x < dst_w) : (x += 1) {
                const src_x = (x * x_ratio) >> 16;
                const src_offset = src_row_offset + src_x * 4;

                // Copy BGRA pixel
                dst[dst_offset] = src[src_offset];
                dst[dst_offset + 1] = src[src_offset + 1];
                dst[dst_offset + 2] = src[src_offset + 2];
                dst[dst_offset + 3] = src[src_offset + 3];
                dst_offset += 4;
            }
        }
    }

    // Encode a BGRA frame, returns encoded H.264 data
    pub fn encode(self: *VideoEncoder, bgra_data: []const u8, force_keyframe: bool) !?struct { data: []const u8, is_keyframe: bool } {
        // Reset output
        self.output_len = 0;
        self.is_keyframe = false;
        self.encode_pending = true;

        // Force keyframe if requested - set via frame properties instead
        _ = force_keyframe; // Will be handled by encoder automatically for first frame

        // Scale down if needed
        const encode_data: []const u8 = if (self.scale_buffer) |scale_buf| blk: {
            scaleDown(bgra_data, self.source_width, self.source_height, scale_buf, self.width, self.height);
            break :blk scale_buf;
        } else bgra_data;

        // Create CVPixelBuffer from BGRA data
        var pixel_buffer: c.CVPixelBufferRef = null;

        const status = c.CVPixelBufferCreateWithBytes(
            null,
            @intCast(self.width),
            @intCast(self.height),
            c.kCVPixelFormatType_32BGRA,
            @constCast(@ptrCast(encode_data.ptr)),
            self.width * 4, // bytes per row
            null, // release callback
            null, // release callback context
            null, // pixel buffer attributes
            &pixel_buffer,
        );

        if (status != 0 or pixel_buffer == null) {
            self.encode_pending = false;
            return error.PixelBufferCreationFailed;
        }
        defer c.CVPixelBufferRelease(pixel_buffer);

        // Create presentation timestamp
        const pts = c.CMTimeMake(self.frame_count, 30); // 30 fps timebase
        self.frame_count += 1;

        // Encode frame
        const encode_status = c.VTCompressionSessionEncodeFrame(
            self.session,
            pixel_buffer,
            pts,
            c.kCMTimeInvalid, // duration
            null, // frame properties
            null, // source frame context
            null, // info flags out
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
        // Get SPS
        var sps_size: usize = 0;
        var sps_count: usize = 0;
        var sps_ptr: [*c]const u8 = undefined;
        _ = c.CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format_desc, 0, &sps_ptr, &sps_size, &sps_count, null,
        );

        // Get PPS
        var pps_size: usize = 0;
        var pps_count: usize = 0;
        var pps_ptr: [*c]const u8 = undefined;
        _ = c.CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format_desc, 1, &pps_ptr, &pps_size, &pps_count, null,
        );

        // Write SPS with Annex B start code
        if (sps_size > 0 and encoder.output_len + 4 + sps_size < encoder.output_buffer.len) {
            encoder.output_buffer[encoder.output_len] = 0;
            encoder.output_buffer[encoder.output_len + 1] = 0;
            encoder.output_buffer[encoder.output_len + 2] = 0;
            encoder.output_buffer[encoder.output_len + 3] = 1;
            @memcpy(encoder.output_buffer[encoder.output_len + 4 ..][0..sps_size], sps_ptr[0..sps_size]);
            encoder.output_len += 4 + sps_size;
        }

        // Write PPS with Annex B start code
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

    // Convert AVCC format (length-prefixed) to Annex B (start code prefixed)
    var offset: usize = 0;
    while (offset < length) {
        // Read 4-byte length prefix (big endian)
        if (offset + 4 > length) break;
        const nal_length: u32 = (@as(u32, data_ptr[offset]) << 24) |
            (@as(u32, data_ptr[offset + 1]) << 16) |
            (@as(u32, data_ptr[offset + 2]) << 8) |
            @as(u32, data_ptr[offset + 3]);
        offset += 4;

        if (offset + nal_length > length) break;
        if (encoder.output_len + 4 + nal_length > encoder.output_buffer.len) break;

        // Write NAL with Annex B start code
        encoder.output_buffer[encoder.output_len] = 0;
        encoder.output_buffer[encoder.output_len + 1] = 0;
        encoder.output_buffer[encoder.output_len + 2] = 0;
        encoder.output_buffer[encoder.output_len + 3] = 1;
        @memcpy(encoder.output_buffer[encoder.output_len + 4 ..][0..nal_length], data_ptr[offset..][0..nal_length]);
        encoder.output_len += 4 + nal_length;

        offset += nal_length;
    }
}
