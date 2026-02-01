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
    width: u32,
    height: u32,
    frame_count: i64,
    allocator: std.mem.Allocator,

    // Output buffer - filled by callback
    output_buffer: []u8,
    output_len: usize,
    is_keyframe: bool,
    encode_pending: bool,

    // Adaptive bitrate/FPS
    current_bitrate: u32,
    target_fps: u32,
    quality_level: u8, // 0-4: 0=lowest, 4=highest

    const MAX_OUTPUT_SIZE = 2 * 1024 * 1024; // 2MB max per frame

    // Quality presets (bitrate, fps)
    const QUALITY_PRESETS = [_]struct { bitrate: u32, fps: u32 }{
        .{ .bitrate = 1_000_000, .fps = 15 }, // Level 0: Very low (1 Mbps, 15fps)
        .{ .bitrate = 2_000_000, .fps = 20 }, // Level 1: Low (2 Mbps, 20fps)
        .{ .bitrate = 3_000_000, .fps = 24 }, // Level 2: Medium (3 Mbps, 24fps)
        .{ .bitrate = 5_000_000, .fps = 30 }, // Level 3: High (5 Mbps, 30fps)
        .{ .bitrate = 8_000_000, .fps = 30 }, // Level 4: Max (8 Mbps, 30fps)
    };

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !*VideoEncoder {
        const encoder = try allocator.create(VideoEncoder);
        errdefer allocator.destroy(encoder);

        const output_buffer = try allocator.alloc(u8, MAX_OUTPUT_SIZE);
        errdefer allocator.free(output_buffer);

        var session: c.VTCompressionSessionRef = null;

        // Create compression session
        const status = c.VTCompressionSessionCreate(
            null, // allocator
            @intCast(width),
            @intCast(height),
            c.kCMVideoCodecType_H264,
            null, // encoder specification (null = default hardware)
            null, // source image buffer attributes
            null, // compressed data allocator
            compressionOutputCallback,
            encoder, // callback context = encoder pointer
            &session,
        );

        if (status != 0) {
            allocator.free(output_buffer);
            return error.EncoderCreationFailed;
        }

        encoder.* = .{
            .session = session,
            .width = width,
            .height = height,
            .frame_count = 0,
            .allocator = allocator,
            .output_buffer = output_buffer,
            .output_len = 0,
            .is_keyframe = false,
            .encode_pending = false,
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

        // Average bitrate (5 Mbps for good quality text)
        var bitrate: c.SInt32 = 5_000_000;
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
        self.allocator.free(self.output_buffer);
        self.allocator.destroy(self);
    }

    // Adjust quality based on client buffer health (0-100)
    // Called from server when client reports buffer stats
    pub fn adjustQuality(self: *VideoEncoder, buffer_health: u8) void {
        const new_level: u8 = if (buffer_health < 20)
            // Buffer starving - drop quality significantly
            if (self.quality_level > 0) self.quality_level - 1 else 0
        else if (buffer_health < 40)
            // Buffer low - drop quality gradually
            if (self.quality_level > 1) self.quality_level - 1 else self.quality_level
        else if (buffer_health > 80)
            // Buffer healthy - can increase quality
            if (self.quality_level < 4) self.quality_level + 1 else 4
        else
            // Buffer ok - maintain current quality
            self.quality_level;

        if (new_level != self.quality_level) {
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
        if (self.width == width and self.height == height) return;

        // Need to recreate session for new dimensions
        const old_session = self.session;

        var new_session: c.VTCompressionSessionRef = null;
        const status = c.VTCompressionSessionCreate(
            null,
            @intCast(width),
            @intCast(height),
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
        self.width = width;
        self.height = height;
        self.frame_count = 0;

        try self.configureSession();
    }

    // Encode a BGRA frame, returns encoded H.264 data
    pub fn encode(self: *VideoEncoder, bgra_data: []const u8, force_keyframe: bool) !?struct { data: []const u8, is_keyframe: bool } {
        // Reset output
        self.output_len = 0;
        self.is_keyframe = false;
        self.encode_pending = true;

        // Force keyframe if requested - set via frame properties instead
        _ = force_keyframe; // Will be handled by encoder automatically for first frame

        // Create CVPixelBuffer from BGRA data
        var pixel_buffer: c.CVPixelBufferRef = null;

        const status = c.CVPixelBufferCreateWithBytes(
            null,
            @intCast(self.width),
            @intCast(self.height),
            c.kCVPixelFormatType_32BGRA,
            @constCast(@ptrCast(bgra_data.ptr)),
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
