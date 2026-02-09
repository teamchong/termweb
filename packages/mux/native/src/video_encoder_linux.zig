//! VA-API H.264 hardware encoder for Linux.
//!
//! Equivalent to macOS VideoToolbox - uses GPU for hardware-accelerated encoding.
//! Provides real H.264 output matching what the WebCodecs client expects.
//!
//! Supports Intel (i915/xe), AMD (radeonsi), and NVIDIA GPUs via VA-API
//! (Video Acceleration API). The encoder outputs H.264 Constrained Baseline
//! or Main profile NAL units compatible with WebCodecs VideoDecoder.
//!
//! Implementation note: VA-API structures are manually defined to work around
//! Zig's cImport limitations with C bitfield unions.
//!
//! For macOS, see `video_encoder.zig` which uses VideoToolbox.
//!
const std = @import("std");
const builtin = @import("builtin");

// VA-API C imports (base types only, not encoder structs with bitfield unions)
const c = @cImport({
    @cInclude("va/va.h");
    @cInclude("va/va_vpp.h");
    @cInclude("va/va_drm.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

// VA-API constants for H.264 encoding
const VAProfileH264Main: c_int = 6;
const VAProfileH264High: c_int = 7;
const VAProfileH264ConstrainedBaseline: c_int = 18;
const VAEntrypointEncSlice: c_int = 6;


// Buffer types (from va.h VABufferType enum)
const VAEncCodedBufferType: c_int = 21;
const VAEncSequenceParameterBufferType: c_int = 22;
const VAEncPictureParameterBufferType: c_int = 23;
const VAEncSliceParameterBufferType: c_int = 24;
const VAEncPackedHeaderParameterBufferType: c_int = 25;
const VAEncPackedHeaderDataBufferType: c_int = 26;

// Packed header types
const VAEncPackedHeaderSequence: c_int = 1;
const VAEncPackedHeaderPicture: c_int = 2;

// Struct sizes (from offsetof dump)
const SEQ_PARAM_SIZE: usize = 1132;
const PIC_PARAM_SIZE: usize = 648;
const SLICE_PARAM_SIZE: usize = 3140;
const PICTURE_H264_SIZE: usize = 36;

// Struct field offsets for VAEncSequenceParameterBufferH264
const SEQ_seq_parameter_set_id: usize = 0; // u8
const SEQ_level_idc: usize = 1; // u8
const SEQ_intra_period: usize = 4; // u32
const SEQ_intra_idr_period: usize = 8; // u32
const SEQ_ip_period: usize = 12; // u32
const SEQ_bits_per_second: usize = 16; // u32
const SEQ_max_num_ref_frames: usize = 20; // u32
const SEQ_picture_width_in_mbs: usize = 24; // u16
const SEQ_picture_height_in_mbs: usize = 26; // u16
const SEQ_seq_fields: usize = 28; // u32
const SEQ_time_scale: usize = 1112; // u32
const SEQ_num_units_in_tick: usize = 1108; // u32

// Struct field offsets for VAEncPictureParameterBufferH264
const PIC_CurrPic: usize = 0; // VAPictureH264 (36 bytes)
const PIC_ReferenceFrames: usize = 36; // 16 * VAPictureH264
const PIC_coded_buf: usize = 612; // u32
const PIC_pic_parameter_set_id: usize = 616; // u8
const PIC_seq_parameter_set_id: usize = 617; // u8
const PIC_frame_num: usize = 620; // u16
const PIC_pic_init_qp: usize = 622; // u8
const PIC_num_ref_idx_l0_active_minus1: usize = 623; // u8
const PIC_pic_fields: usize = 628; // u32

// Struct field offsets for VAEncSliceParameterBufferH264
const SLICE_macroblock_address: usize = 0; // u32
const SLICE_num_macroblocks: usize = 4; // u32
const SLICE_macroblock_info: usize = 8; // u32 (VABufferID)
const SLICE_slice_type: usize = 12; // u8
const SLICE_pic_parameter_set_id: usize = 13; // u8
const SLICE_idr_pic_id: usize = 14; // u16
const SLICE_pic_order_cnt_lsb: usize = 16; // u16
const SLICE_num_ref_idx_l0_active_minus1: usize = 34; // u8
const SLICE_num_ref_idx_l1_active_minus1: usize = 35; // u8
const SLICE_RefPicList0: usize = 36; // 32 * VAPictureH264 (36 bytes each)
const SLICE_RefPicList1: usize = 1188; // 32 * VAPictureH264
const SLICE_cabac_init_idc: usize = 3118; // u8
const SLICE_slice_qp_delta: usize = 3119; // i8
const SLICE_disable_deblocking_filter_idc: usize = 3120; // u8
const SLICE_slice_alpha_c0_offset_div2: usize = 3121; // i8
const SLICE_slice_beta_offset_div2: usize = 3122; // i8

// Struct field offsets for VAPictureH264
const PICH264_picture_id: usize = 0; // u32
const PICH264_frame_idx: usize = 4; // u32
const PICH264_flags: usize = 8; // u32
const PICH264_TopFieldOrderCnt: usize = 12; // i32

// Picture flags
const VA_PICTURE_H264_INVALID: u32 = 0x00000001;
const VA_PICTURE_H264_SHORT_TERM_REFERENCE: u32 = 0x00000008;

// Helper functions to write values to byte buffers
fn writeU8(buf: []u8, offset: usize, val: u8) void {
    buf[offset] = val;
}
fn writeI8(buf: []u8, offset: usize, val: i8) void {
    buf[offset] = @bitCast(val);
}
fn writeU16(buf: []u8, offset: usize, val: u16) void {
    const bytes = std.mem.toBytes(val);
    buf[offset] = bytes[0];
    buf[offset + 1] = bytes[1];
}
fn writeU32(buf: []u8, offset: usize, val: u32) void {
    const bytes = std.mem.toBytes(val);
    @memcpy(buf[offset..][0..4], &bytes);
}
fn writeI32(buf: []u8, offset: usize, val: i32) void {
    const bytes = std.mem.toBytes(val);
    @memcpy(buf[offset..][0..4], &bytes);
}

/// Errors that can occur during VA-API encoder operations.
pub const VaError = error{
    /// Failed to open DRM device for VA-API.
    DrmOpenFailed,
    /// Failed to get VA display from DRM fd.
    VaDisplayFailed,
    /// VA-API initialization failed.
    VaInitFailed,
    /// H.264 encoding not supported by this GPU.
    H264NotSupported,
    /// Failed to create VA surfaces.
    VaSurfacesFailed,
    /// Failed to create VA context.
    VaContextFailed,
    /// Failed to create VA buffer.
    VaBufferFailed,
    /// Failed to create/derive VA image.
    VaImageFailed,
    /// Failed to map VA buffer/image.
    VaMapFailed,
    /// vaBeginPicture failed.
    VaBeginPictureFailed,
    /// Failed to create sequence parameter buffer.
    VaSeqBufferFailed,
    /// Failed to create picture parameter buffer.
    VaPicBufferFailed,
    /// Failed to create slice parameter buffer.
    VaSliceBufferFailed,
    /// vaRenderPicture failed.
    VaRenderFailed,
    /// vaEndPicture failed.
    VaEndPictureFailed,
    /// vaSyncSurface failed.
    VaSyncFailed,
    /// Failed to map coded buffer.
    VaMapCodedFailed,
    /// Operation not supported.
    NotSupported,
};

/// Combined error type for encoder creation.
pub const CreateError = VaError || std.mem.Allocator.Error;

/// Error type for resize operations.
pub const ResizeError = VaError;

const VACodedBufferSegment = extern struct {
    size: u32,
    bit_offset: u32,
    status: u32,
    reserved: u32,
    buf: ?*anyopaque,
    next: ?*VACodedBufferSegment,
};

const VAEncPackedHeaderParameterBuffer = extern struct {
    type: u32,
    bit_length: u32,
    has_emulation_bytes: u8,
};

// External VA-API functions for buffer creation
extern fn vaCreateBuffer(
    dpy: c.VADisplay,
    context: c.VAContextID,
    type: c_int,
    size: c_uint,
    num_elements: c_uint,
    data: ?*anyopaque,
    buf_id: *c.VABufferID,
) c.VAStatus;

extern fn vaDestroyBuffer(dpy: c.VADisplay, buf_id: c.VABufferID) c.VAStatus;
extern fn vaBeginPicture(dpy: c.VADisplay, context: c.VAContextID, render_target: c.VASurfaceID) c.VAStatus;
extern fn vaRenderPicture(dpy: c.VADisplay, context: c.VAContextID, buffers: [*]c.VABufferID, num_buffers: c_int) c.VAStatus;
extern fn vaEndPicture(dpy: c.VADisplay, context: c.VAContextID) c.VAStatus;

pub const EncodeResult = struct {
    data: []const u8,
    is_keyframe: bool,
};

/// Shared VA-API context for all encoders.
/// Holds the expensive-to-create DRM fd, VA display, and VA config.
/// Initialize once at server startup, pass to each VideoEncoder.
pub const SharedVaContext = struct {
    drm_fd: c_int,
    va_display: c.VADisplay,
    va_config: c.VAConfigID,
    vpp_config: c.VAConfigID,
    has_vpp: bool,

    /// Initialize the shared VA-API context (open DRM, vaInitialize, create config).
    /// Call once at server startup. All VideoEncoders share this context.
    pub fn init() VaError!SharedVaContext {
        const drm_fd = c.open("/dev/dri/renderD128", c.O_RDWR);
        if (drm_fd < 0) {
            std.debug.print("VAAPI: Failed to open /dev/dri/renderD128\n", .{});
            return error.DrmOpenFailed;
        }
        errdefer _ = c.close(drm_fd);

        const va_display = c.vaGetDisplayDRM(drm_fd);
        if (va_display == null) {
            std.debug.print("VAAPI: Failed to get VA display\n", .{});
            return error.VaDisplayFailed;
        }

        var major: c_int = 0;
        var minor: c_int = 0;
        var status = c.vaInitialize(va_display, &major, &minor);
        if (status != c.VA_STATUS_SUCCESS) {
            std.debug.print("VAAPI: vaInitialize failed: {}\n", .{status});
            return error.VaInitFailed;
        }
        errdefer _ = c.vaTerminate(va_display);

        // Find a supported H.264 encoding profile.
        // Use Main/High for VAAPI encoding (Constrained Baseline reports
        // support but fails or is extremely slow on many GPUs). The SPS
        // advertises Constrained Baseline to the decoder — this is safe
        // because we use CAVLC, no B-frames, 1 ref frame (all CB-compatible).
        const profiles = [_]c_int{
            VAProfileH264Main,
            VAProfileH264High,
            VAProfileH264ConstrainedBaseline,
        };

        var config: c.VAConfigID = 0;
        var found_profile = false;

        for (profiles) |profile| {
            var attrib = c.VAConfigAttrib{
                .type = c.VAConfigAttribRTFormat,
                .value = 0,
            };
            status = c.vaGetConfigAttributes(va_display, profile, VAEntrypointEncSlice, &attrib, 1);
            if (status == c.VA_STATUS_SUCCESS and (attrib.value & c.VA_RT_FORMAT_YUV420) != 0) {
                var config_attribs = [_]c.VAConfigAttrib{
                    .{ .type = c.VAConfigAttribRTFormat, .value = c.VA_RT_FORMAT_YUV420 },
                };
                status = c.vaCreateConfig(va_display, profile, VAEntrypointEncSlice, &config_attribs, 1, &config);
                if (status == c.VA_STATUS_SUCCESS) {
                    found_profile = true;
                    break;
                }
            }
        }

        if (!found_profile) {
            std.debug.print("VAAPI: No H.264 encoding profile supported\n", .{});
            return error.H264NotSupported;
        }

        // Try to create VPP config for GPU color space conversion (RGBA→NV12)
        var vpp_config: c.VAConfigID = 0;
        var has_vpp = false;
        var vpp_attrib = c.VAConfigAttrib{
            .type = c.VAConfigAttribRTFormat,
            .value = 0,
        };
        status = c.vaGetConfigAttributes(va_display, c.VAProfileNone, c.VAEntrypointVideoProc, &vpp_attrib, 1);
        if (status == c.VA_STATUS_SUCCESS and vpp_attrib.value != 0) {
            var vpp_attribs = [_]c.VAConfigAttrib{
                .{ .type = c.VAConfigAttribRTFormat, .value = c.VA_RT_FORMAT_YUV420 },
            };
            status = c.vaCreateConfig(va_display, c.VAProfileNone, c.VAEntrypointVideoProc, &vpp_attribs, 1, &vpp_config);
            if (status == c.VA_STATUS_SUCCESS) {
                has_vpp = true;
                std.debug.print("VAAPI: VPP enabled (GPU color conversion)\n", .{});
            }
        }
        if (!has_vpp) {
            std.debug.print("VAAPI: VPP not available, using CPU color conversion\n", .{});
        }

        return .{
            .drm_fd = drm_fd,
            .va_display = va_display,
            .va_config = config,
            .vpp_config = vpp_config,
            .has_vpp = has_vpp,
        };
    }

    pub fn deinit(self: *SharedVaContext) void {
        if (self.has_vpp) _ = c.vaDestroyConfig(self.va_display, self.vpp_config);
        _ = c.vaDestroyConfig(self.va_display, self.va_config);
        _ = c.vaTerminate(self.va_display);
        _ = c.close(self.drm_fd);
    }
};

/// Linux video encoder using VA-API (hardware H.264)
/// Matches VideoToolbox interface for cross-platform compatibility
pub const VideoEncoder = struct {
    width: u32,
    height: u32,
    source_width: u32,
    source_height: u32,
    frame_count: i64,
    allocator: std.mem.Allocator,

    // Shared VA-API context (owned by Server, not this encoder)
    shared: *SharedVaContext,

    // Per-encoder VA-API handles (surfaces + context are per-resolution)
    va_context: c.VAContextID,
    src_surface: c.VASurfaceID,
    ref_surface: c.VASurfaceID,
    recon_surface: c.VASurfaceID,

    // Coded buffer for encoder output
    coded_buf: c.VABufferID,

    // Output buffer
    output_buffer: []u8,
    output_len: usize,

    // Encoding parameters
    current_bitrate: u32,
    target_fps: u32,
    quality_level: u8,
    keyframe_interval: u32,
    active_max_pixels: u64,

    // AIMD adaptive quality state
    frames_at_current_level: u32,
    consecutive_bad: u8,
    consecutive_good: u8,

    // Cached SPS/PPS for prepending to keyframes
    sps_data: [64]u8,
    sps_len: usize,
    pps_data: [64]u8,
    pps_len: usize,

    // VPP (GPU color conversion + scaling) resources
    vpp_context: c.VAContextID,
    rgba_surface: c.VASurfaceID,
    rgba_width: u32, // RGBA surface dimensions (source-aligned, may differ from encode dims)
    rgba_height: u32,
    has_vpp: bool,

    const MAX_OUTPUT_SIZE = 16 * 1024 * 1024; // 16MB max per frame (low QP keyframes can be large)

    /// Hardware safety limit per axis — most VA-API encoders max at 4096.
    const HW_MAX_DIM: u32 = 4096;

    /// Quality tiers for adaptive streaming (AIMD pattern).
    /// Ordered lowest-to-highest. Resolution changes trigger encoder resize + keyframe.
    /// For terminals: text sharpness (resolution) is most important, so we reduce
    /// fps first, then bitrate, then resolution as a last resort.
    const QualityTier = struct { bitrate: u32, max_pixels: u64, fps: u32 };
    const QUALITY_TIERS = [_]QualityTier{
        .{ .bitrate = 1_000_000, .max_pixels = 1024 * 768, .fps = 15 },   // 0: Emergency
        .{ .bitrate = 2_000_000, .max_pixels = 1280 * 1024, .fps = 24 },  // 1: Low
        .{ .bitrate = 3_000_000, .max_pixels = 1920 * 1080, .fps = 30 },  // 2: Medium
        .{ .bitrate = 5_000_000, .max_pixels = 2048 * 2048, .fps = 30 },  // 3: High (default)
        .{ .bitrate = 8_000_000, .max_pixels = 3840 * 2160, .fps = 30 },  // 4: Max (4K)
    };
    const DEFAULT_TIER: u8 = 3;

    /// AIMD stability constants — prevent oscillation between tiers.
    const HEALTH_BAD: u8 = 30; // Below this: client is starving
    const HEALTH_GOOD: u8 = 70; // Above this: client is healthy
    const DOWNGRADE_STREAK: u8 = 2; // Consecutive bad reports before dropping (2s)
    const UPGRADE_STREAK: u8 = 3; // Consecutive good reports before upgrading (3s)
    const MIN_STABLE_FRAMES: u32 = 150; // Frames at current tier before upgrade (~5s at 30fps)

    fn calcAlignedDimensions(width: u32, height: u32, max_pixels: u64) struct { w: u32, h: u32 } {
        // VA-API hardware encoders require 16-pixel aligned surfaces.
        // We also enforce per-dimension caps (GPU H.264 encode typically maxes at 4096).
        var w = width;
        var h = height;

        // Enforce per-dimension hardware limit first
        if (w > HW_MAX_DIM or h > HW_MAX_DIM) {
            const scale_w = @as(f64, @floatFromInt(HW_MAX_DIM)) / @as(f64, @floatFromInt(w));
            const scale_h = @as(f64, @floatFromInt(HW_MAX_DIM)) / @as(f64, @floatFromInt(h));
            const scale = @min(scale_w, scale_h);
            w = @intFromFloat(@as(f64, @floatFromInt(w)) * scale);
            h = @intFromFloat(@as(f64, @floatFromInt(h)) * scale);
        }

        // Enforce quality-tier pixel count cap
        const pixels: u64 = @as(u64, w) * @as(u64, h);
        if (pixels > max_pixels) {
            const scale = @sqrt(@as(f64, @floatFromInt(max_pixels)) / @as(f64, @floatFromInt(pixels)));
            w = @intFromFloat(@as(f64, @floatFromInt(w)) * scale);
            h = @intFromFloat(@as(f64, @floatFromInt(h)) * scale);
        }

        // Round to 16-pixel alignment (required by H.264 hardware encoders)
        return .{
            .w = (w + 15) & ~@as(u32, 15),
            .h = (h + 15) & ~@as(u32, 15),
        };
    }

    // Bitstream writer for NAL unit generation
    const BitstreamWriter = struct {
        data: []u8,
        byte_pos: usize = 0,
        bit_pos: u4 = 0, // 0-7

        fn init(buffer: []u8) BitstreamWriter {
            return .{ .data = buffer };
        }

        fn writeBits(self: *BitstreamWriter, value: u32, num_bits: u5) void {
            var bits_left: u5 = num_bits;
            var val = value;
            while (bits_left > 0) {
                const bits_in_byte: u5 = 8 - @as(u5, self.bit_pos);
                const bits_to_write: u5 = if (bits_left < bits_in_byte) bits_left else bits_in_byte;
                const shift: u5 = bits_left - bits_to_write;
                const mask = (@as(u32, 1) << bits_to_write) - 1;
                const byte_val: u8 = @intCast((val >> shift) & mask);
                const shift_amt: u3 = @intCast(8 - @as(u5, self.bit_pos) - bits_to_write);
                self.data[self.byte_pos] |= byte_val << shift_amt;
                self.bit_pos += @intCast(bits_to_write);
                if (self.bit_pos >= 8) {
                    self.bit_pos = 0;
                    self.byte_pos += 1;
                }
                bits_left -= bits_to_write;
                val &= (@as(u32, 1) << shift) - 1;
            }
        }

        fn writeUE(self: *BitstreamWriter, value: u32) void {
            // Exp-Golomb unsigned: value+1 as binary, prefixed by (bit_length-1) zeros
            const val_plus_1 = value + 1;
            var n: u5 = 0;
            var temp = val_plus_1;
            while (temp > 1) : (temp >>= 1) n += 1;
            // Write n zeros
            var i: u5 = 0;
            while (i < n) : (i += 1) self.writeBits(0, 1);
            // Write 1 followed by n low bits
            self.writeBits(val_plus_1, n + 1);
        }

        fn writeSE(self: *BitstreamWriter, value: i32) void {
            // Exp-Golomb signed: positive->odd, negative/zero->even
            const mapped: u32 = if (value <= 0) @intCast(-value * 2) else @intCast(value * 2 - 1);
            self.writeUE(mapped);
        }

        fn writeTrailingBits(self: *BitstreamWriter) void {
            self.writeBits(1, 1); // rbsp_stop_one_bit
            while (self.bit_pos != 0) self.writeBits(0, 1); // byte alignment
        }

        fn getLength(self: *BitstreamWriter) usize {
            return if (self.bit_pos == 0) self.byte_pos else self.byte_pos + 1;
        }
    };

    /// Generate SPS NAL unit for H264 Main profile (Annex B format)
    fn generateSPS(self: *VideoEncoder) void {
        const width_mbs = self.width / 16;
        const height_mbs = self.height / 16;

        // Clear buffer
        @memset(&self.sps_data, 0);

        // Start code
        self.sps_data[0] = 0;
        self.sps_data[1] = 0;
        self.sps_data[2] = 0;
        self.sps_data[3] = 1;

        // NAL header: nal_ref_idc=3, nal_unit_type=7 (SPS)
        self.sps_data[4] = 0x67;

        var bs = BitstreamWriter.init(self.sps_data[5..]);

        // profile_idc = 66 (Baseline)
        bs.writeBits(66, 8);
        // constraint_set0_flag=1, constraint_set1_flag=1 → Constrained Baseline
        // This guarantees no B-frames and no reorder buffer, so WebCodecs
        // hardware decoders emit frames immediately.
        bs.writeBits(0xC0, 8);
        // level_idc = 52 (Level 5.2 for large frame support)
        bs.writeBits(52, 8);
        // seq_parameter_set_id = 0
        bs.writeUE(0);
        // log2_max_frame_num_minus4 = 0
        bs.writeUE(0);
        // pic_order_cnt_type = 0
        bs.writeUE(0);
        // log2_max_pic_order_cnt_lsb_minus4 = 4
        bs.writeUE(4);
        // max_num_ref_frames = 1
        bs.writeUE(1);
        // gaps_in_frame_num_value_allowed_flag = 0
        bs.writeBits(0, 1);
        // pic_width_in_mbs_minus1
        bs.writeUE(width_mbs - 1);
        // pic_height_in_map_units_minus1
        bs.writeUE(height_mbs - 1);
        // frame_mbs_only_flag = 1
        bs.writeBits(1, 1);
        // direct_8x8_inference_flag = 1 (required for Baseline)
        bs.writeBits(1, 1);
        // frame_cropping_flag = 0
        bs.writeBits(0, 1);
        // vui_parameters_present_flag = 1 (enable VUI for full color range)
        bs.writeBits(1, 1);

        // === VUI Parameters ===
        // aspect_ratio_info_present_flag = 0
        bs.writeBits(0, 1);
        // overscan_info_present_flag = 0
        bs.writeBits(0, 1);
        // video_signal_type_present_flag = 1 (needed for full range)
        bs.writeBits(1, 1);
        // video_format = 5 (unspecified)
        bs.writeBits(5, 3);
        // video_full_range_flag = 1 (FULL RANGE 0-255, not limited 16-235)
        bs.writeBits(1, 1);
        // colour_description_present_flag = 1
        bs.writeBits(1, 1);
        // colour_primaries = 1 (BT.709)
        bs.writeBits(1, 8);
        // transfer_characteristics = 1 (BT.709)
        bs.writeBits(1, 8);
        // matrix_coefficients = 1 (BT.709)
        bs.writeBits(1, 8);
        // chroma_loc_info_present_flag = 0
        bs.writeBits(0, 1);
        // timing_info_present_flag = 0
        bs.writeBits(0, 1);
        // nal_hrd_parameters_present_flag = 0
        bs.writeBits(0, 1);
        // vcl_hrd_parameters_present_flag = 0
        bs.writeBits(0, 1);
        // pic_struct_present_flag = 0
        bs.writeBits(0, 1);
        // bitstream_restriction_flag = 1 (tell decoder: no reordering needed)
        bs.writeBits(1, 1);
        // motion_vectors_over_pic_boundaries_flag = 1
        bs.writeBits(1, 1);
        // max_bytes_per_pic_denom = 0 (no limit)
        bs.writeUE(0);
        // max_bits_per_mb_denom = 0 (no limit)
        bs.writeUE(0);
        // log2_max_mv_length_horizontal = 16
        bs.writeUE(16);
        // log2_max_mv_length_vertical = 16
        bs.writeUE(16);
        // max_num_reorder_frames = 0 (critical: forces immediate output)
        bs.writeUE(0);
        // max_dec_frame_buffering = 1 (only 1 ref frame needed)
        bs.writeUE(1);

        bs.writeTrailingBits();
        self.sps_len = 5 + bs.getLength();
    }

    /// Generate PPS NAL unit for H264 Constrained Baseline profile (Annex B format)
    fn generatePPS(self: *VideoEncoder) void {
        // Clear buffer
        @memset(&self.pps_data, 0);

        // Start code
        self.pps_data[0] = 0;
        self.pps_data[1] = 0;
        self.pps_data[2] = 0;
        self.pps_data[3] = 1;

        // NAL header: nal_ref_idc=3, nal_unit_type=8 (PPS)
        self.pps_data[4] = 0x68;

        var bs = BitstreamWriter.init(self.pps_data[5..]);

        // pic_parameter_set_id = 0
        bs.writeUE(0);
        // seq_parameter_set_id = 0
        bs.writeUE(0);
        // entropy_coding_mode_flag = 0 (CAVLC - simpler, works with all browsers)
        bs.writeBits(0, 1);
        // bottom_field_pic_order_in_frame_present_flag = 0
        bs.writeBits(0, 1);
        // num_slice_groups_minus1 = 0
        bs.writeUE(0);
        // num_ref_idx_l0_default_active_minus1 = 0
        bs.writeUE(0);
        // num_ref_idx_l1_default_active_minus1 = 0
        bs.writeUE(0);
        // weighted_pred_flag = 0
        bs.writeBits(0, 1);
        // weighted_bipred_idc = 0
        bs.writeBits(0, 2);
        // pic_init_qp_minus26 = -6 (so pic_init_qp = 20, matching encoder param)
        bs.writeSE(-6);
        // pic_init_qs_minus26 = 0
        bs.writeSE(0);
        // chroma_qp_index_offset = 0
        bs.writeSE(0);
        // deblocking_filter_control_present_flag = 1
        bs.writeBits(1, 1);
        // constrained_intra_pred_flag = 0
        bs.writeBits(0, 1);
        // redundant_pic_cnt_present_flag = 0
        bs.writeBits(0, 1);

        bs.writeTrailingBits();
        self.pps_len = 5 + bs.getLength();
    }

    /// Initialize encoder using a shared VA context.
    /// Only creates per-encoder resources (surfaces, context, coded buffer).
    pub fn init(_: std.mem.Allocator, _: u32, _: u32) CreateError!*VideoEncoder {
        // Must use initWithShared() with a SharedVaContext instead
        return error.VaDisplayFailed;
    }

    /// Initialize encoder with a shared VA-API context (fast path).
    /// The shared context owns the DRM fd, VA display, and VA config.
    /// This encoder only creates surfaces + encoding context (~20-50ms vs ~400ms).
    pub fn initWithShared(allocator: std.mem.Allocator, shared: *SharedVaContext, width: u32, height: u32) CreateError!*VideoEncoder {
        // Reject zero dimensions — VA-API cannot create context for 0x0
        if (width == 0 or height == 0) {
            return error.VaContextFailed;
        }

        const encoder = try allocator.create(VideoEncoder);
        errdefer allocator.destroy(encoder);

        const output_buffer = try allocator.alloc(u8, MAX_OUTPUT_SIZE);
        errdefer allocator.free(output_buffer);

        const default_tier = QUALITY_TIERS[DEFAULT_TIER];
        const scaled = calcAlignedDimensions(width, height, default_tier.max_pixels);
        const encode_width = scaled.w;
        const encode_height = scaled.h;

        const va_display = shared.va_display;

        // Create surfaces for encoding
        var surfaces: [3]c.VASurfaceID = undefined;
        var status = c.vaCreateSurfaces(
            va_display,
            c.VA_RT_FORMAT_YUV420,
            encode_width,
            encode_height,
            &surfaces,
            3,
            null,
            0,
        );
        if (status != c.VA_STATUS_SUCCESS) {
            std.debug.print("ENCODER: vaCreateSurfaces failed: {}\n", .{status});
            return error.VaSurfacesFailed;
        }
        const src_surface = surfaces[0];
        const ref_surface = surfaces[1];
        const recon_surface = surfaces[2];
        errdefer _ = c.vaDestroySurfaces(va_display, &surfaces, 3);

        // Create VA context
        var va_context: c.VAContextID = 0;
        status = c.vaCreateContext(
            va_display,
            shared.va_config,
            @intCast(encode_width),
            @intCast(encode_height),
            c.VA_PROGRESSIVE,
            &surfaces,
            3,
            &va_context,
        );
        if (status != c.VA_STATUS_SUCCESS) {
            std.debug.print("ENCODER: vaCreateContext failed: {}\n", .{status});
            return error.VaContextFailed;
        }
        errdefer _ = c.vaDestroyContext(va_display, va_context);

        // Create coded buffer for encoder output
        var coded_buf: c.VABufferID = 0;
        status = vaCreateBuffer(
            va_display,
            va_context,
            VAEncCodedBufferType,
            MAX_OUTPUT_SIZE,
            1,
            null,
            &coded_buf,
        );
        if (status != c.VA_STATUS_SUCCESS) {
            std.debug.print("ENCODER: vaCreateBuffer (coded) failed: {}\n", .{status});
            return error.VaBufferFailed;
        }

        // Set up VPP (GPU color conversion BGRX→NV12) if available.
        // BGRX surface at encode resolution — CPU does R↔B swap + downscale,
        // VPP only converts BGRX→NV12 on GPU (no scaling, fast).
        var vpp_context: c.VAContextID = 0;
        var rgba_surface: c.VASurfaceID = c.VA_INVALID_SURFACE;
        var actual_rgba_w: u32 = 0;
        var actual_rgba_h: u32 = 0;
        const has_vpp = shared.has_vpp;
        if (has_vpp) vpp_blk: {
            // Create BGRX surface at encode resolution. CPU does R↔B swap +
            // downscale in one pass over 2.3M dst pixels (fast), VPP does color convert only.
            var rgba_attribs = [_]c.VASurfaceAttrib{
                .{
                    .type = c.VASurfaceAttribPixelFormat,
                    .flags = c.VA_SURFACE_ATTRIB_SETTABLE,
                    .value = .{ .type = c.VAGenericValueTypeInteger, .value = .{ .i = @as(c_int, @bitCast(@as(u32, c.VA_FOURCC_BGRX))) } },
                },
            };
            status = c.vaCreateSurfaces(
                va_display,
                c.VA_RT_FORMAT_RGB32,
                encode_width,
                encode_height,
                @ptrCast(&rgba_surface),
                1,
                &rgba_attribs,
                1,
            );
            if (status != c.VA_STATUS_SUCCESS) {
                std.debug.print("ENCODER: VPP BGRX surface failed: {}, falling back to CPU\n", .{status});
                break :vpp_blk;
            }
            actual_rgba_w = encode_width;
            actual_rgba_h = encode_height;

            // Create VPP context at encode resolution (no scaling needed).
            status = c.vaCreateContext(
                va_display,
                shared.vpp_config,
                @intCast(encode_width),
                @intCast(encode_height),
                c.VA_PROGRESSIVE,
                @ptrCast(&rgba_surface),
                1,
                &vpp_context,
            );
            if (status != c.VA_STATUS_SUCCESS) {
                std.debug.print("ENCODER: VPP context failed: {}, falling back to CPU\n", .{status});
                _ = c.vaDestroySurfaces(va_display, @ptrCast(&rgba_surface), 1);
                rgba_surface = c.VA_INVALID_SURFACE;
                actual_rgba_w = 0;
                actual_rgba_h = 0;
                break :vpp_blk;
            }
        }

        encoder.* = .{
            .width = encode_width,
            .height = encode_height,
            .source_width = width,
            .source_height = height,
            .frame_count = 0,
            .allocator = allocator,
            .shared = shared,
            .va_context = va_context,
            .src_surface = src_surface,
            .ref_surface = ref_surface,
            .recon_surface = recon_surface,
            .coded_buf = coded_buf,
            .output_buffer = output_buffer,
            .output_len = 0,
            .current_bitrate = default_tier.bitrate,
            .target_fps = default_tier.fps,
            .quality_level = DEFAULT_TIER,
            .keyframe_interval = 600, // keyframe every 20 seconds at 30fps
            .active_max_pixels = default_tier.max_pixels,
            .frames_at_current_level = 0,
            .consecutive_bad = 0,
            .consecutive_good = 0,
            .sps_data = undefined,
            .sps_len = 0,
            .pps_data = undefined,
            .pps_len = 0,
            .vpp_context = vpp_context,
            .rgba_surface = rgba_surface,
            .rgba_width = actual_rgba_w,
            .rgba_height = actual_rgba_h,
            .has_vpp = has_vpp and rgba_surface != c.VA_INVALID_SURFACE,
        };

        // Generate SPS/PPS for H264High profile
        encoder.generateSPS();
        encoder.generatePPS();

        return encoder;
    }

    pub fn deinit(self: *VideoEncoder) void {
        const va_display = self.shared.va_display;
        if (self.has_vpp) {
            _ = c.vaDestroyContext(va_display, self.vpp_context);
            _ = c.vaDestroySurfaces(va_display, @ptrCast(&self.rgba_surface), 1);
        }
        var surfaces = [_]c.VASurfaceID{ self.src_surface, self.ref_surface, self.recon_surface };
        _ = vaDestroyBuffer(va_display, self.coded_buf);
        _ = c.vaDestroyContext(va_display, self.va_context);
        _ = c.vaDestroySurfaces(va_display, &surfaces, 3);
        self.allocator.free(self.output_buffer);
        self.allocator.destroy(self);
    }

    /// Adaptive quality adjustment using AIMD (Additive Increase, Multiplicative Decrease).
    /// Called once per second from client buffer health reports.
    /// - Bad health (<30): fast drop — 2 tiers after 2 consecutive bad reports
    /// - Good health (>70): slow recovery — 1 tier after 3 good reports AND 5s stability
    /// - Dead zone (30-70): no change, reset streaks
    pub fn adjustQuality(self: *VideoEncoder, buffer_health: u8) void {
        if (buffer_health == 0) return;

        self.frames_at_current_level +|= 30; // ~1 second worth of frames per report

        if (buffer_health < HEALTH_BAD) {
            self.consecutive_good = 0;
            self.consecutive_bad +|= 1;

            if (self.consecutive_bad >= DOWNGRADE_STREAK) {
                // Multiplicative decrease: drop 2 tiers at once
                const drop = @min(@as(u8, 2), self.quality_level);
                if (drop > 0) {
                    self.applyTier(self.quality_level - drop);
                }
                self.consecutive_bad = 0;
            }
        } else if (buffer_health > HEALTH_GOOD) {
            self.consecutive_bad = 0;
            self.consecutive_good +|= 1;

            // Additive increase: 1 tier, only after stability at current level
            if (self.consecutive_good >= UPGRADE_STREAK and
                self.frames_at_current_level >= MIN_STABLE_FRAMES)
            {
                if (self.quality_level < QUALITY_TIERS.len - 1) {
                    self.applyTier(self.quality_level + 1);
                    self.consecutive_good = 0;
                }
            }
        } else {
            // Dead zone: network is adequate, don't oscillate
            self.consecutive_bad = 0;
            self.consecutive_good = 0;
        }
    }

    /// Apply a new quality tier. Updates bitrate and fps only.
    /// Resolution is managed by the server via setPixelBudget() based on
    /// total budget divided by active panel count.
    fn applyTier(self: *VideoEncoder, level: u8) void {
        if (level == self.quality_level) return;

        const old_level = self.quality_level;
        const tier = QUALITY_TIERS[level];

        std.debug.print("QUALITY: tier {d}->{d} bitrate={d} fps={d}\n", .{
            old_level, level, tier.bitrate, tier.fps,
        });

        self.quality_level = level;
        self.frames_at_current_level = 0;
        self.current_bitrate = tier.bitrate;
        self.target_fps = tier.fps;
    }

    /// Returns the current tier's max pixel budget (before per-panel division).
    pub fn tierMaxPixels(self: *const VideoEncoder) u64 {
        return QUALITY_TIERS[self.quality_level].max_pixels;
    }

    /// Set the per-panel pixel budget. Called by server when panel count changes
    /// or quality tier changes. May trigger encoder resize + keyframe.
    pub fn setPixelBudget(self: *VideoEncoder, budget: u64) void {
        if (budget == self.active_max_pixels) return;
        self.active_max_pixels = budget;

        // Check if encode dimensions changed with new budget
        const new_dims = calcAlignedDimensions(self.source_width, self.source_height, budget);
        if (new_dims.w != self.width or new_dims.h != self.height) {
            self.resizeForTier() catch |err| {
                std.debug.print("BUDGET: resize failed: {}\n", .{err});
            };
        }
    }

    /// Resize encoder for pixel budget / quality tier change (same source dims, different resolution cap).
    /// Unlike resize(), this doesn't check source_width/source_height equality.
    fn resizeForTier(self: *VideoEncoder) ResizeError!void {
        const scaled = calcAlignedDimensions(self.source_width, self.source_height, self.active_max_pixels);
        const encode_width = scaled.w;
        const encode_height = scaled.h;

        if (encode_width == self.width and encode_height == self.height) return;

        const va_display = self.shared.va_display;

        // Destroy old VPP resources
        if (self.has_vpp) {
            _ = c.vaDestroyContext(va_display, self.vpp_context);
            _ = c.vaDestroySurfaces(va_display, @ptrCast(&self.rgba_surface), 1);
            self.has_vpp = false;
        }

        // Destroy old resources
        var old_surfaces = [_]c.VASurfaceID{ self.src_surface, self.ref_surface, self.recon_surface };
        _ = vaDestroyBuffer(va_display, self.coded_buf);
        _ = c.vaDestroyContext(va_display, self.va_context);
        _ = c.vaDestroySurfaces(va_display, &old_surfaces, 3);

        // Create new surfaces
        var surfaces: [3]c.VASurfaceID = undefined;
        var status = c.vaCreateSurfaces(
            va_display,
            c.VA_RT_FORMAT_YUV420,
            encode_width,
            encode_height,
            &surfaces,
            3,
            null,
            0,
        );
        if (status != c.VA_STATUS_SUCCESS) return error.VaSurfacesFailed;

        // Create new context
        status = c.vaCreateContext(
            va_display,
            self.shared.va_config,
            @intCast(encode_width),
            @intCast(encode_height),
            c.VA_PROGRESSIVE,
            &surfaces,
            3,
            &self.va_context,
        );
        if (status != c.VA_STATUS_SUCCESS) {
            _ = c.vaDestroySurfaces(va_display, &surfaces, 3);
            return error.VaContextFailed;
        }

        // Create new coded buffer
        status = vaCreateBuffer(
            va_display,
            self.va_context,
            VAEncCodedBufferType,
            MAX_OUTPUT_SIZE,
            1,
            null,
            &self.coded_buf,
        );
        if (status != c.VA_STATUS_SUCCESS) {
            _ = c.vaDestroyContext(va_display, self.va_context);
            _ = c.vaDestroySurfaces(va_display, &surfaces, 3);
            return error.VaBufferFailed;
        }

        self.src_surface = surfaces[0];
        self.ref_surface = surfaces[1];
        self.recon_surface = surfaces[2];
        self.width = encode_width;
        self.height = encode_height;
        self.frame_count = 0;

        // Recreate VPP resources at new encode resolution
        if (self.shared.has_vpp) vpp_blk: {
            var rgba_attribs = [_]c.VASurfaceAttrib{
                .{
                    .type = c.VASurfaceAttribPixelFormat,
                    .flags = c.VA_SURFACE_ATTRIB_SETTABLE,
                    .value = .{ .type = c.VAGenericValueTypeInteger, .value = .{ .i = @as(c_int, @bitCast(@as(u32, c.VA_FOURCC_BGRX))) } },
                },
            };
            status = c.vaCreateSurfaces(va_display, c.VA_RT_FORMAT_RGB32, encode_width, encode_height, @ptrCast(&self.rgba_surface), 1, &rgba_attribs, 1);
            if (status != c.VA_STATUS_SUCCESS) break :vpp_blk;
            status = c.vaCreateContext(va_display, self.shared.vpp_config, @intCast(encode_width), @intCast(encode_height), c.VA_PROGRESSIVE, @ptrCast(&self.rgba_surface), 1, &self.vpp_context);
            if (status != c.VA_STATUS_SUCCESS) {
                _ = c.vaDestroySurfaces(va_display, @ptrCast(&self.rgba_surface), 1);
                break :vpp_blk;
            }
            self.rgba_width = encode_width;
            self.rgba_height = encode_height;
            self.has_vpp = true;
        }

        // Regenerate SPS/PPS for new dimensions
        self.generateSPS();
        self.generatePPS();
    }

    pub fn resize(self: *VideoEncoder, width: u32, height: u32) ResizeError!void {
        if (self.source_width == width and self.source_height == height) return;

        const scaled = calcAlignedDimensions(width, height, self.active_max_pixels);
        const encode_width = scaled.w;
        const encode_height = scaled.h;

        const va_display = self.shared.va_display;

        // Destroy old VPP resources
        if (self.has_vpp) {
            _ = c.vaDestroyContext(va_display, self.vpp_context);
            _ = c.vaDestroySurfaces(va_display, @ptrCast(&self.rgba_surface), 1);
            self.has_vpp = false;
        }

        // Destroy old resources
        var old_surfaces = [_]c.VASurfaceID{ self.src_surface, self.ref_surface, self.recon_surface };
        _ = vaDestroyBuffer(va_display, self.coded_buf);
        _ = c.vaDestroyContext(va_display, self.va_context);
        _ = c.vaDestroySurfaces(va_display, &old_surfaces, 3);

        // Create new surfaces
        var surfaces: [3]c.VASurfaceID = undefined;
        var status = c.vaCreateSurfaces(
            va_display,
            c.VA_RT_FORMAT_YUV420,
            encode_width,
            encode_height,
            &surfaces,
            3,
            null,
            0,
        );
        if (status != c.VA_STATUS_SUCCESS) return error.VaSurfacesFailed;

        // Create new context
        status = c.vaCreateContext(
            va_display,
            self.shared.va_config,
            @intCast(encode_width),
            @intCast(encode_height),
            c.VA_PROGRESSIVE,
            &surfaces,
            3,
            &self.va_context,
        );
        if (status != c.VA_STATUS_SUCCESS) {
            _ = c.vaDestroySurfaces(va_display, &surfaces, 3);
            return error.VaContextFailed;
        }

        // Create new double-buffered coded buffers
        status = vaCreateBuffer(
            va_display,
            self.va_context,
            VAEncCodedBufferType,
            MAX_OUTPUT_SIZE,
            1,
            null,
            &self.coded_buf,
        );
        if (status != c.VA_STATUS_SUCCESS) {
            _ = c.vaDestroyContext(va_display, self.va_context);
            _ = c.vaDestroySurfaces(va_display, &surfaces, 3);
            return error.VaBufferFailed;
        }

        self.src_surface = surfaces[0];
        self.ref_surface = surfaces[1];
        self.recon_surface = surfaces[2];
        self.width = encode_width;
        self.height = encode_height;
        self.source_width = width;
        self.source_height = height;
        self.frame_count = 0;

        // Recreate VPP resources at encode resolution
        if (self.shared.has_vpp) vpp_blk: {
            var rgba_attribs = [_]c.VASurfaceAttrib{
                .{
                    .type = c.VASurfaceAttribPixelFormat,
                    .flags = c.VA_SURFACE_ATTRIB_SETTABLE,
                    .value = .{ .type = c.VAGenericValueTypeInteger, .value = .{ .i = @as(c_int, @bitCast(@as(u32, c.VA_FOURCC_BGRX))) } },
                },
            };
            status = c.vaCreateSurfaces(va_display, c.VA_RT_FORMAT_RGB32, encode_width, encode_height, @ptrCast(&self.rgba_surface), 1, &rgba_attribs, 1);
            if (status != c.VA_STATUS_SUCCESS) break :vpp_blk;
            status = c.vaCreateContext(va_display, self.shared.vpp_config, @intCast(encode_width), @intCast(encode_height), c.VA_PROGRESSIVE, @ptrCast(&self.rgba_surface), 1, &self.vpp_context);
            if (status != c.VA_STATUS_SUCCESS) {
                _ = c.vaDestroySurfaces(va_display, @ptrCast(&self.rgba_surface), 1);
                break :vpp_blk;
            }
            self.rgba_width = encode_width;
            self.rgba_height = encode_height;
            self.has_vpp = true;
        }

        // Regenerate SPS/PPS for new dimensions
        self.generateSPS();
        self.generatePPS();
    }

    /// Upload RGBA frame to VA-API NV12 surface.
    /// Uses GPU VPP color conversion when available, falls back to CPU.
    fn uploadFrame(self: *VideoEncoder, rgba_data: []const u8) VaError!void {
        if (self.has_vpp) {
            return self.uploadFrameGpu(rgba_data);
        }
        return self.uploadFrameCpu(rgba_data);
    }

    /// GPU path: CPU does R↔B swap + nearest-neighbor downscale to BGRX at
    /// encode resolution (2.3M pixels), then VPP converts BGRX→NV12 on GPU.
    fn uploadFrameGpu(self: *VideoEncoder, rgba_data: []const u8) VaError!void {
        const va_display = self.shared.va_display;
        const dst_width = self.width;
        const dst_height = self.height;
        const src_width = self.source_width;
        const src_height = self.source_height;

        // Derive image from BGRX surface (encode resolution) for direct memory write
        var image: c.VAImage = undefined;
        var status = c.vaDeriveImage(va_display, self.rgba_surface, &image);
        if (status != c.VA_STATUS_SUCCESS) {
            std.debug.print("ENCODER: vaDeriveImage failed: {}, falling back to CPU\n", .{status});
            return self.uploadFrameCpu(rgba_data);
        }
        defer _ = c.vaDestroyImage(va_display, image.image_id);

        var mapped_ptr: ?*anyopaque = null;
        status = c.vaMapBuffer(va_display, image.buf, &mapped_ptr);
        if (status != c.VA_STATUS_SUCCESS) return error.VaMapFailed;

        const mapped: [*]u8 = @ptrCast(mapped_ptr);
        const pitch = image.pitches[0];
        const offset = image.offsets[0];

        // Source is BGRA from glReadPixels (Intel native format), destination is BGRX.
        // No R↔B swap needed — BGRA layout matches BGRX (alpha byte becomes X).
        const src_pixels: [*]align(1) const u32 = @ptrCast(rgba_data.ptr);
        const dst_pixels: [*]align(1) u32 = @ptrCast(mapped + offset);
        const dst_stride_px = @as(usize, pitch) / 4;
        const src_stride_px = @as(usize, src_width);

        // Fast path: no downscale needed (common case)
        if (src_width == dst_width and src_height <= dst_height) {
            var y: u32 = 0;
            while (y < src_height) : (y += 1) {
                const src_row = @as(usize, y) * src_stride_px;
                const dst_row = @as(usize, y) * dst_stride_px;
                // Direct copy — BGRA pixels to BGRX surface (alpha=X, ignored)
                @memcpy(
                    @as([*]u8, @ptrCast(&dst_pixels[dst_row]))[0 .. dst_width * 4],
                    @as([*]const u8, @ptrCast(&src_pixels[src_row]))[0 .. dst_width * 4],
                );
            }
            // Pad remaining rows (16-pixel alignment padding) with black
            var y2: u32 = src_height;
            while (y2 < dst_height) : (y2 += 1) {
                const dst_row = @as(usize, y2) * dst_stride_px;
                @memset(@as([*]u8, @ptrCast(&dst_pixels[dst_row]))[0 .. dst_width * 4], 0);
            }
        } else {
            // Downscale path with nearest-neighbor sampling
            const fp_shift = 16;
            const fp_scale_x = (@as(u64, src_width) << fp_shift) / @as(u64, dst_width);
            const fp_scale_y = (@as(u64, src_height) << fp_shift) / @as(u64, dst_height);
            const src_max_x = src_width - 1;
            const src_max_y = src_height - 1;

            var y: u32 = 0;
            while (y < dst_height) : (y += 1) {
                const sy: u32 = @intCast(@min(@as(u64, y) * fp_scale_y >> fp_shift, src_max_y));
                const src_row = @as(usize, sy) * src_stride_px;
                const dst_row = @as(usize, y) * dst_stride_px;
                var x: u32 = 0;
                while (x < dst_width) : (x += 1) {
                    const sx: u32 = @intCast(@min(@as(u64, x) * fp_scale_x >> fp_shift, src_max_x));
                    // Direct copy — no R↔B swap needed (BGRA→BGRX)
                    dst_pixels[dst_row + x] = src_pixels[src_row + sx] | 0xFF000000;
                }
            }
        }

        status = c.vaUnmapBuffer(va_display, image.buf);
        if (status != c.VA_STATUS_SUCCESS) return error.VaMapFailed;

        // VPP: convert BGRX → NV12 on GPU (same resolution, no scaling).
        var pipeline_param = std.mem.zeroes(c.VAProcPipelineParameterBuffer);
        pipeline_param.surface = self.rgba_surface;
        pipeline_param.surface_color_standard = c.VAProcColorStandardNone;
        pipeline_param.output_color_standard = c.VAProcColorStandardBT601;

        var pipeline_buf: c.VABufferID = 0;
        status = vaCreateBuffer(
            va_display,
            self.vpp_context,
            c.VAProcPipelineParameterBufferType,
            @sizeOf(c.VAProcPipelineParameterBuffer),
            1,
            &pipeline_param,
            &pipeline_buf,
        );
        if (status != c.VA_STATUS_SUCCESS) {
            std.debug.print("ENCODER: VPP buffer failed: {}\n", .{status});
            return self.uploadFrameCpu(rgba_data);
        }
        defer _ = vaDestroyBuffer(va_display, pipeline_buf);

        status = vaBeginPicture(va_display, self.vpp_context, self.src_surface);
        if (status != c.VA_STATUS_SUCCESS) return self.uploadFrameCpu(rgba_data);

        var bufs = [_]c.VABufferID{pipeline_buf};
        status = vaRenderPicture(va_display, self.vpp_context, &bufs, 1);
        if (status != c.VA_STATUS_SUCCESS) {
            _ = vaEndPicture(va_display, self.vpp_context);
            return self.uploadFrameCpu(rgba_data);
        }

        status = vaEndPicture(va_display, self.vpp_context);
        if (status != c.VA_STATUS_SUCCESS) return self.uploadFrameCpu(rgba_data);

        // Sync VPP output — cross-context synchronization is NOT implicit in VA-API.
        // The VPP context and encoder context are separate, so we must explicitly
        // wait for VPP to finish writing to src_surface before the encoder reads it.
        status = c.vaSyncSurface(va_display, self.src_surface);
        if (status != c.VA_STATUS_SUCCESS) return self.uploadFrameCpu(rgba_data);
    }

    /// CPU fallback: RGBA → NV12 conversion with nearest-neighbor downscaling.
    fn uploadFrameCpu(self: *VideoEncoder, rgba_data: []const u8) VaError!void {
        const va_display = self.shared.va_display;
        const dst_width = self.width;
        const dst_height = self.height;
        const src_width = self.source_width;
        const src_height = self.source_height;

        // Scale factors for downscaling
        const scale_x = @as(f64, @floatFromInt(src_width)) / @as(f64, @floatFromInt(dst_width));
        const scale_y = @as(f64, @floatFromInt(src_height)) / @as(f64, @floatFromInt(dst_height));

        // Derive image from surface for direct access (avoid vaCreateImage + vaPutImage overhead)
        var image: c.VAImage = undefined;
        var status = c.vaDeriveImage(va_display, self.src_surface, &image);
        var use_derive = true;
        if (status != c.VA_STATUS_SUCCESS) {
            // Fall back to vaCreateImage + vaPutImage
            use_derive = false;
            var formats: [64]c.VAImageFormat = undefined;
            var actual_formats: c_int = 0;
            status = c.vaQueryImageFormats(va_display, &formats, &actual_formats);
            if (status != c.VA_STATUS_SUCCESS) return error.VaImageFailed;

            var nv12_format: ?c.VAImageFormat = null;
            const num: usize = @min(@as(usize, @intCast(actual_formats)), 64);
            for (formats[0..num]) |fmt| {
                if (fmt.fourcc == 0x3231564e) { // "NV12"
                    nv12_format = fmt;
                    break;
                }
            }
            if (nv12_format == null) return error.VaImageFailed;
            status = c.vaCreateImage(va_display, &nv12_format.?, @intCast(dst_width), @intCast(dst_height), &image);
            if (status != c.VA_STATUS_SUCCESS) return error.VaImageFailed;
        }
        defer _ = c.vaDestroyImage(va_display, image.image_id);

        var mapped_ptr: ?*anyopaque = null;
        status = c.vaMapBuffer(va_display, image.buf, &mapped_ptr);
        if (status != c.VA_STATUS_SUCCESS) return error.VaMapFailed;

        const mapped: [*]u8 = @ptrCast(mapped_ptr);
        const y_offset = image.offsets[0];
        const uv_offset = image.offsets[1];
        const y_pitch = image.pitches[0];
        const uv_pitch = image.pitches[1];

        // Y plane with downscaling (input is BGRA: byte 0=B, 1=G, 2=R, 3=A)
        var y: u32 = 0;
        while (y < dst_height) : (y += 1) {
            const src_y = @min(@as(u32, @intFromFloat(@as(f64, @floatFromInt(y)) * scale_y)), src_height - 1);
            var x: u32 = 0;
            while (x < dst_width) : (x += 1) {
                const src_x = @min(@as(u32, @intFromFloat(@as(f64, @floatFromInt(x)) * scale_x)), src_width - 1);
                const src_idx = (src_y * src_width + src_x) * 4;
                const b = @as(u32, rgba_data[src_idx]);
                const g = @as(u32, rgba_data[src_idx + 1]);
                const r = @as(u32, rgba_data[src_idx + 2]);
                mapped[y_offset + y * y_pitch + x] = @intCast(@min(255, 16 + ((66 * r + 129 * g + 25 * b + 128) >> 8)));
            }
        }

        // UV plane with downscaling (input is BGRA: byte 0=B, 1=G, 2=R, 3=A)
        const dst_uv_width = dst_width / 2;
        const dst_uv_height = dst_height / 2;
        y = 0;
        while (y < dst_uv_height) : (y += 1) {
            const src_y = @min(@as(u32, @intFromFloat(@as(f64, @floatFromInt(y * 2)) * scale_y)), src_height - 1);
            var x: u32 = 0;
            while (x < dst_uv_width) : (x += 1) {
                const src_x = @min(@as(u32, @intFromFloat(@as(f64, @floatFromInt(x * 2)) * scale_x)), src_width - 1);
                const src_idx = (src_y * src_width + src_x) * 4;
                const b = @as(i32, @intCast(rgba_data[src_idx]));
                const g = @as(i32, @intCast(rgba_data[src_idx + 1]));
                const r = @as(i32, @intCast(rgba_data[src_idx + 2]));
                mapped[uv_offset + y * uv_pitch + x * 2] = @intCast(@as(u32, @intCast(@max(0, @min(255, 128 + ((-38 * r - 74 * g + 112 * b + 128) >> 8))))));
                mapped[uv_offset + y * uv_pitch + x * 2 + 1] = @intCast(@as(u32, @intCast(@max(0, @min(255, 128 + ((112 * r - 94 * g - 18 * b + 128) >> 8))))));
            }
        }

        status = c.vaUnmapBuffer(va_display, image.buf);
        if (status != c.VA_STATUS_SUCCESS) return error.VaMapFailed;

        // If we used vaCreateImage (not derive), need vaPutImage to transfer
        if (!use_derive) {
            status = c.vaPutImage(va_display, self.src_surface, image.image_id, 0, 0, @intCast(dst_width), @intCast(dst_height), 0, 0, @intCast(dst_width), @intCast(dst_height));
            if (status != c.VA_STATUS_SUCCESS) return error.VaImageFailed;
        }
    }

    /// Encode RGBA frame to H.264
    /// If width/height are provided and differ from source dimensions, auto-resize.
    pub fn encode(self: *VideoEncoder, rgba_data: []const u8, force_keyframe: bool) VaError!?EncodeResult {
        return self.encodeWithDimensions(rgba_data, force_keyframe, null, null);
    }

    /// Encode BGRA frame to H.264 with explicit dimensions.
    /// Synchronous: upload, encode, sync, read output all in one call.
    /// No pipeline latency — the frame you encode is the frame you get back.
    pub fn encodeWithDimensions(self: *VideoEncoder, rgba_data: []const u8, force_keyframe: bool, width: ?u32, height: ?u32) VaError!?EncodeResult {
        const va_display = self.shared.va_display;
        const t0 = std.time.nanoTimestamp();

        // Auto-resize if explicit dimensions provided and differ from source
        if (width != null and height != null) {
            const w = width.?;
            const h = height.?;
            if (w != self.source_width or h != self.source_height) {
                self.resize(w, h) catch |err| {
                    std.debug.print("ENCODER: auto-resize failed: {}\n", .{err});
                    return error.VaSurfacesFailed;
                };
            }
        }

        const is_keyframe = force_keyframe or (self.frame_count == 0) or
            (@mod(self.frame_count, @as(i64, self.keyframe_interval)) == 0);

        // IDR resets the H.264 frame numbering sequence. Without this,
        // frame_num has gaps after forced keyframes (e.g., IDR frame_num=0
        // followed by P-frame frame_num=3), violating the spec when
        // gaps_in_frame_num_value_allowed_flag=0 in SPS. Decoders silently
        // drop P-frames with invalid frame_num gaps.
        if (is_keyframe) {
            self.frame_count = 0;
        }

        // Upload frame (CPU copy + VPP color conversion)
        try self.uploadFrame(rgba_data);
        const t1 = std.time.nanoTimestamp();

        // Submit encode to GPU
        var status = vaBeginPicture(va_display, self.va_context, self.src_surface);
        if (status != c.VA_STATUS_SUCCESS) {
            return error.VaBeginPictureFailed;
        }

        // Create sequence parameter buffer
        var seq_param: [SEQ_PARAM_SIZE]u8 = std.mem.zeroes([SEQ_PARAM_SIZE]u8);
        writeU8(&seq_param, SEQ_seq_parameter_set_id, 0);
        writeU8(&seq_param, SEQ_level_idc, 52);
        writeU32(&seq_param, SEQ_intra_period, self.keyframe_interval);
        writeU32(&seq_param, SEQ_intra_idr_period, self.keyframe_interval);
        writeU32(&seq_param, SEQ_ip_period, 1);
        writeU32(&seq_param, SEQ_bits_per_second, self.current_bitrate);
        writeU32(&seq_param, SEQ_max_num_ref_frames, 1);
        writeU16(&seq_param, SEQ_picture_width_in_mbs, @intCast(self.width / 16));
        writeU16(&seq_param, SEQ_picture_height_in_mbs, @intCast(self.height / 16));
        writeU32(&seq_param, SEQ_seq_fields, 0x4025);
        writeU32(&seq_param, SEQ_time_scale, 60);
        writeU32(&seq_param, SEQ_num_units_in_tick, 1);

        var seq_buf: c.VABufferID = 0;
        status = vaCreateBuffer(
            va_display,
            self.va_context,
            VAEncSequenceParameterBufferType,
            SEQ_PARAM_SIZE,
            1,
            &seq_param,
            &seq_buf,
        );
        if (status != c.VA_STATUS_SUCCESS) {
            std.debug.print("ENCODER: vaCreateBuffer seq failed: {}\n", .{status});
            _ = vaEndPicture(va_display, self.va_context);
            return error.VaSeqBufferFailed;
        }
        defer _ = vaDestroyBuffer(va_display, seq_buf);

        // Create picture parameter buffer
        var pic_param: [PIC_PARAM_SIZE]u8 = std.mem.zeroes([PIC_PARAM_SIZE]u8);
        writeU32(&pic_param, PIC_CurrPic + PICH264_picture_id, self.src_surface);
        writeI32(&pic_param, PIC_CurrPic + PICH264_TopFieldOrderCnt, @intCast(self.frame_count * 2));
        writeU32(&pic_param, PIC_coded_buf, self.coded_buf);
        writeU8(&pic_param, PIC_pic_parameter_set_id, 0);
        writeU8(&pic_param, PIC_seq_parameter_set_id, 0);
        writeU16(&pic_param, PIC_frame_num, if (is_keyframe) 0 else @intCast(@mod(self.frame_count, 16)));
        writeU8(&pic_param, PIC_pic_init_qp, 20);
        writeU8(&pic_param, PIC_num_ref_idx_l0_active_minus1, 0);
        writeU32(&pic_param, PIC_pic_fields, if (is_keyframe) 0x03 else 0x02);

        if (!is_keyframe) {
            writeU32(&pic_param, PIC_ReferenceFrames + PICH264_picture_id, self.ref_surface);
            writeU32(&pic_param, PIC_ReferenceFrames + PICH264_flags, VA_PICTURE_H264_SHORT_TERM_REFERENCE);
        }
        var i: usize = if (is_keyframe) 0 else 1;
        while (i < 16) : (i += 1) {
            const ref_offset = PIC_ReferenceFrames + i * PICTURE_H264_SIZE;
            writeU32(&pic_param, ref_offset + PICH264_picture_id, c.VA_INVALID_SURFACE);
            writeU32(&pic_param, ref_offset + PICH264_flags, VA_PICTURE_H264_INVALID);
        }

        var pic_buf: c.VABufferID = 0;
        status = vaCreateBuffer(
            va_display,
            self.va_context,
            VAEncPictureParameterBufferType,
            PIC_PARAM_SIZE,
            1,
            &pic_param,
            &pic_buf,
        );
        if (status != c.VA_STATUS_SUCCESS) {
            std.debug.print("ENCODER: vaCreateBuffer pic failed: {}\n", .{status});
            _ = vaEndPicture(va_display, self.va_context);
            return error.VaPicBufferFailed;
        }
        defer _ = vaDestroyBuffer(va_display, pic_buf);

        // Create slice parameter buffer
        var slice_param: [SLICE_PARAM_SIZE]u8 = std.mem.zeroes([SLICE_PARAM_SIZE]u8);
        writeU32(&slice_param, SLICE_macroblock_address, 0);
        writeU32(&slice_param, SLICE_num_macroblocks, (self.width / 16) * (self.height / 16));
        writeU32(&slice_param, SLICE_macroblock_info, c.VA_INVALID_ID);
        writeU8(&slice_param, SLICE_slice_type, if (is_keyframe) 2 else 0);
        writeU8(&slice_param, SLICE_pic_parameter_set_id, 0);
        writeU16(&slice_param, SLICE_idr_pic_id, if (is_keyframe) @intCast(@mod(self.frame_count, 256)) else 0);
        writeU16(&slice_param, SLICE_pic_order_cnt_lsb, @intCast(@mod(self.frame_count * 2, 256)));
        writeU8(&slice_param, SLICE_num_ref_idx_l0_active_minus1, 0);
        writeU8(&slice_param, SLICE_num_ref_idx_l1_active_minus1, 0);

        var j: usize = 0;
        while (j < 32) : (j += 1) {
            const ref0_offset = SLICE_RefPicList0 + j * PICTURE_H264_SIZE;
            writeU32(&slice_param, ref0_offset + PICH264_picture_id, c.VA_INVALID_SURFACE);
            writeU32(&slice_param, ref0_offset + PICH264_flags, VA_PICTURE_H264_INVALID);
            const ref1_offset = SLICE_RefPicList1 + j * PICTURE_H264_SIZE;
            writeU32(&slice_param, ref1_offset + PICH264_picture_id, c.VA_INVALID_SURFACE);
            writeU32(&slice_param, ref1_offset + PICH264_flags, VA_PICTURE_H264_INVALID);
        }

        if (!is_keyframe) {
            writeU32(&slice_param, SLICE_RefPicList0 + PICH264_picture_id, self.ref_surface);
            writeU32(&slice_param, SLICE_RefPicList0 + PICH264_flags, VA_PICTURE_H264_SHORT_TERM_REFERENCE);
        }

        writeU8(&slice_param, SLICE_cabac_init_idc, 0);
        writeI8(&slice_param, SLICE_slice_qp_delta, -4);
        writeU8(&slice_param, SLICE_disable_deblocking_filter_idc, 0);
        writeI8(&slice_param, SLICE_slice_alpha_c0_offset_div2, 3);
        writeI8(&slice_param, SLICE_slice_beta_offset_div2, 3);

        var slice_buf: c.VABufferID = 0;
        status = vaCreateBuffer(
            va_display,
            self.va_context,
            VAEncSliceParameterBufferType,
            SLICE_PARAM_SIZE,
            1,
            &slice_param,
            &slice_buf,
        );
        if (status != c.VA_STATUS_SUCCESS) {
            std.debug.print("ENCODER: vaCreateBuffer slice failed: {}\n", .{status});
            _ = vaEndPicture(va_display, self.va_context);
            return error.VaSliceBufferFailed;
        }
        defer _ = vaDestroyBuffer(va_display, slice_buf);

        var render_bufs = [_]c.VABufferID{ seq_buf, pic_buf, slice_buf };
        status = vaRenderPicture(va_display, self.va_context, &render_bufs, 3);
        if (status != c.VA_STATUS_SUCCESS) {
            _ = vaEndPicture(va_display, self.va_context);
            return error.VaRenderFailed;
        }

        status = vaEndPicture(va_display, self.va_context);
        if (status != c.VA_STATUS_SUCCESS) {
            return error.VaEndPictureFailed;
        }

        // Sync — wait for GPU encode to complete
        status = c.vaSyncSurface(va_display, self.src_surface);
        if (status != c.VA_STATUS_SUCCESS) return error.VaSyncFailed;
        const t2 = std.time.nanoTimestamp();

        // Read encoded output
        var coded_seg_ptr: ?*anyopaque = null;
        status = c.vaMapBuffer(va_display, self.coded_buf, &coded_seg_ptr);
        if (status != c.VA_STATUS_SUCCESS) return error.VaMapCodedFailed;

        self.output_len = 0;
        if (is_keyframe) {
            @memcpy(self.output_buffer[0..self.sps_len], self.sps_data[0..self.sps_len]);
            self.output_len = self.sps_len;
            @memcpy(self.output_buffer[self.output_len..][0..self.pps_len], self.pps_data[0..self.pps_len]);
            self.output_len += self.pps_len;
        }

        if (coded_seg_ptr) |ptr| {
            const coded_seg: *VACodedBufferSegment = @ptrCast(@alignCast(ptr));
            var current_seg: ?*VACodedBufferSegment = coded_seg;
            while (current_seg) |seg| {
                const seg_size = seg.size;
                if (self.output_len + seg_size <= self.output_buffer.len) {
                    if (seg.buf) |buf| {
                        const src_data: [*]const u8 = @ptrCast(buf);
                        @memcpy(self.output_buffer[self.output_len..][0..seg_size], src_data[0..seg_size]);
                        self.output_len += seg_size;
                    }
                }
                current_seg = seg.next;
            }
        }

        _ = c.vaUnmapBuffer(va_display, self.coded_buf);

        // Swap surfaces for reference frame tracking
        const tmp = self.ref_surface;
        self.ref_surface = self.src_surface;
        self.src_surface = tmp;
        self.frame_count += 1;

        // Log timing breakdown every 30 frames (~1s)
        if (@mod(self.frame_count, 30) == 0) {
            const ns = std.time.ns_per_ms;
            logEncTiming(0, @divFloor(t1 - t0, ns), @divFloor(t2 - t1, ns), self.width, self.height);
        }

        if (self.output_len > 0) {
            return EncodeResult{
                .data = self.output_buffer[0..self.output_len],
                .is_keyframe = is_keyframe,
            };
        }
        return null;
    }

    pub fn canEncodeDirectly(self: *VideoEncoder) bool {
        _ = self;
        return false; // No IOSurface on Linux
    }

    /// Not applicable on Linux (no IOSurface)
    pub fn encodeFromIOSurface(self: *VideoEncoder, iosurface_ptr: *anyopaque, force_keyframe: bool) !?EncodeResult {
        _ = self;
        _ = iosurface_ptr;
        _ = force_keyframe;
        return error.NotSupported;
    }

    fn logEncTiming(sync_ms: i128, upload_ms: i128, submit_ms: i128, w: u32, h: u32) void {
        const f = std.fs.openFileAbsolute("/tmp/termweb-enc.log", .{ .mode = .write_only }) catch
            std.fs.createFileAbsolute("/tmp/termweb-enc.log", .{}) catch return;
        defer f.close();
        f.seekFromEnd(0) catch return;
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "sync={d}ms upload={d}ms submit={d}ms total={d}ms {d}x{d}\n", .{
            sync_ms, upload_ms, submit_ms, sync_ms + upload_ms + submit_ms, w, h,
        }) catch return;
        _ = f.write(line) catch {};
    }
};
