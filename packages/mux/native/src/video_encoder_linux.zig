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

/// Linux video encoder using VA-API (hardware H.264)
/// Matches VideoToolbox interface for cross-platform compatibility
pub const VideoEncoder = struct {
    width: u32,
    height: u32,
    source_width: u32,
    source_height: u32,
    frame_count: i64,
    allocator: std.mem.Allocator,

    // VA-API handles
    drm_fd: c_int,
    owns_drm_fd: bool, // True if we opened the fd and should close it
    va_display: c.VADisplay,
    va_config: c.VAConfigID,
    va_context: c.VAContextID,
    src_surface: c.VASurfaceID,
    ref_surface: c.VASurfaceID,
    recon_surface: c.VASurfaceID,
    coded_buf: c.VABufferID,

    // Output buffer
    output_buffer: []u8,
    output_len: usize,

    // Encoding parameters
    current_bitrate: u32,
    target_fps: u32,
    quality_level: u8,
    keyframe_interval: u32,

    // Cached SPS/PPS for prepending to keyframes
    sps_data: [64]u8,
    sps_len: usize,
    pps_data: [64]u8,
    pps_len: usize,

    // Pipeline state for async encoding
    // We submit frame N and read frame N-1's output, avoiding sync stalls
    pending_frame: bool,
    pending_is_keyframe: bool,

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

    fn calcScaledDimensions(width: u32, height: u32) struct { w: u32, h: u32 } {
        // VA-API hardware encoders require 16-pixel aligned surfaces.
        // We align the destination but handle stride differences in uploadFrame.
        const pixels: u64 = @as(u64, width) * @as(u64, height);
        if (pixels <= MAX_PIXELS) {
            // Round to 16-pixel alignment (required by H.264 hardware encoders)
            return .{
                .w = (width + 15) & ~@as(u32, 15),
                .h = (height + 15) & ~@as(u32, 15),
            };
        }
        const scale = @sqrt(@as(f64, @floatFromInt(MAX_PIXELS)) / @as(f64, @floatFromInt(pixels)));
        var new_w: u32 = @intFromFloat(@as(f64, @floatFromInt(width)) * scale);
        var new_h: u32 = @intFromFloat(@as(f64, @floatFromInt(height)) * scale);
        // Round to 16-pixel alignment
        new_w = (new_w + 15) & ~@as(u32, 15);
        new_h = (new_h + 15) & ~@as(u32, 15);
        return .{ .w = new_w, .h = new_h };
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

        // profile_idc = 77 (Main)
        bs.writeBits(77, 8);
        // constraint_set1_flag=1 (Main compatible), others=0
        bs.writeBits(0x40, 8);
        // level_idc = 41
        bs.writeBits(41, 8);
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
        // bitstream_restriction_flag = 0
        bs.writeBits(0, 1);

        bs.writeTrailingBits();
        self.sps_len = 5 + bs.getLength();
    }

    /// Generate PPS NAL unit for H264 Main profile (Annex B format)
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
        // pic_init_qp_minus26 = 0
        bs.writeSE(0);
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

    /// Initialize encoder, opening our own DRM render node.
    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) CreateError!*VideoEncoder {
        return initWithDrmFd(allocator, width, height, -1);
    }

    /// Initialize encoder with optional external DRM fd.
    /// If external_drm_fd is provided (>= 0), it will be used instead of opening our own.
    /// This enables zero-copy encoding when ghostty and VA-API share the same GPU.
    pub fn initWithDrmFd(allocator: std.mem.Allocator, width: u32, height: u32, external_drm_fd: c_int) CreateError!*VideoEncoder {
        const encoder = try allocator.create(VideoEncoder);
        errdefer allocator.destroy(encoder);

        const output_buffer = try allocator.alloc(u8, MAX_OUTPUT_SIZE);
        errdefer allocator.free(output_buffer);

        const scaled = calcScaledDimensions(width, height);
        const encode_width = scaled.w;
        const encode_height = scaled.h;

        // Use external DRM fd if provided, otherwise open our own
        const owns_drm_fd = external_drm_fd < 0;
        const drm_fd = if (external_drm_fd >= 0) external_drm_fd else blk: {
            const fd = c.open("/dev/dri/renderD128", c.O_RDWR);
            if (fd < 0) {
                std.debug.print("ENCODER: Failed to open /dev/dri/renderD128\n", .{});
                return error.DrmOpenFailed;
            }
            break :blk fd;
        };
        errdefer if (owns_drm_fd) {
            _ = c.close(drm_fd);
        };

        // Get VA display from DRM
        const va_display = c.vaGetDisplayDRM(drm_fd);
        if (va_display == null) {
            std.debug.print("ENCODER: Failed to get VA display\n", .{});
            return error.VaDisplayFailed;
        }

        // Initialize VA-API
        var major: c_int = 0;
        var minor: c_int = 0;
        var status = c.vaInitialize(va_display, &major, &minor);
        if (status != c.VA_STATUS_SUCCESS) {
            std.debug.print("ENCODER: vaInitialize failed: {}\n", .{status});
            return error.VaInitFailed;
        }
        errdefer _ = c.vaTerminate(va_display);


        // Try multiple H.264 profiles - use Main first for better driver support
        const profiles = [_]c_int{
            VAProfileH264Main, // Best driver support
            VAProfileH264High, // Good quality
            VAProfileH264ConstrainedBaseline, // Fallback
        };

        var config: c.VAConfigID = 0;
        var selected_profile: c_int = 0;
        var found_profile = false;

        for (profiles) |profile| {
            var attrib = c.VAConfigAttrib{
                .type = c.VAConfigAttribRTFormat,
                .value = 0,
            };
            status = c.vaGetConfigAttributes(va_display, profile, VAEntrypointEncSlice, &attrib, 1);
            if (status == c.VA_STATUS_SUCCESS and (attrib.value & c.VA_RT_FORMAT_YUV420) != 0) {
                // Try to create config with this profile
                var config_attribs = [_]c.VAConfigAttrib{
                    .{ .type = c.VAConfigAttribRTFormat, .value = c.VA_RT_FORMAT_YUV420 },
                };
                status = c.vaCreateConfig(va_display, profile, VAEntrypointEncSlice, &config_attribs, 1, &config);
                if (status == c.VA_STATUS_SUCCESS) {
                    selected_profile = profile;
                    found_profile = true;
                    break;
                }
            }
        }

        if (!found_profile) {
            std.debug.print("ENCODER: No H.264 encoding profile supported\n", .{});
            return error.H264NotSupported;
        }

        errdefer _ = c.vaDestroyConfig(va_display, config);

        // Create surfaces for encoding
        var surfaces: [3]c.VASurfaceID = undefined;
        status = c.vaCreateSurfaces(
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
            config,
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

        // Create coded buffer for output
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

        encoder.* = .{
            .width = encode_width,
            .height = encode_height,
            .source_width = width,
            .source_height = height,
            .frame_count = 0,
            .allocator = allocator,
            .drm_fd = drm_fd,
            .owns_drm_fd = owns_drm_fd,
            .va_display = va_display,
            .va_config = config,
            .va_context = va_context,
            .src_surface = src_surface,
            .ref_surface = ref_surface,
            .recon_surface = recon_surface,
            .coded_buf = coded_buf,
            .output_buffer = output_buffer,
            .output_len = 0,
            .current_bitrate = 5_000_000,
            .target_fps = 30,
            .quality_level = 3,
            .keyframe_interval = 120, // keyframe every 4 seconds at 30fps
            .sps_data = undefined,
            .sps_len = 0,
            .pps_data = undefined,
            .pps_len = 0,
            .pending_frame = false,
            .pending_is_keyframe = false,
        };

        // Generate SPS/PPS for H264High profile
        encoder.generateSPS();
        encoder.generatePPS();

        return encoder;
    }

    pub fn deinit(self: *VideoEncoder) void {
        var surfaces = [_]c.VASurfaceID{ self.src_surface, self.ref_surface, self.recon_surface };
        _ = vaDestroyBuffer(self.va_display, self.coded_buf);
        _ = c.vaDestroyContext(self.va_display, self.va_context);
        _ = c.vaDestroySurfaces(self.va_display, &surfaces, 3);
        _ = c.vaDestroyConfig(self.va_display, self.va_config);
        _ = c.vaTerminate(self.va_display);

        // Only close DRM fd if we opened it ourselves
        if (self.owns_drm_fd) {
            _ = c.close(self.drm_fd);
        }

        self.allocator.free(self.output_buffer);
        self.allocator.destroy(self);
    }

    pub fn adjustQuality(self: *VideoEncoder, buffer_health: u8) void {
        if (buffer_health == 0) return;

        const new_level: u8 = if (buffer_health < 30)
            if (self.quality_level > 0) self.quality_level - 1 else 0
        else if (buffer_health > 70)
            if (self.quality_level < 4) self.quality_level + 1 else 4
        else
            self.quality_level;

        if (new_level != self.quality_level) {
            self.quality_level = new_level;
            const preset = QUALITY_PRESETS[new_level];
            self.current_bitrate = preset.bitrate;
            self.target_fps = preset.fps;
        }
    }

    pub fn resize(self: *VideoEncoder, width: u32, height: u32) ResizeError!void {
        if (self.source_width == width and self.source_height == height) return;

        const scaled = calcScaledDimensions(width, height);
        const encode_width = scaled.w;
        const encode_height = scaled.h;

        // Destroy old surfaces
        var old_surfaces = [_]c.VASurfaceID{ self.src_surface, self.ref_surface, self.recon_surface };
        _ = vaDestroyBuffer(self.va_display, self.coded_buf);
        _ = c.vaDestroyContext(self.va_display, self.va_context);
        _ = c.vaDestroySurfaces(self.va_display, &old_surfaces, 3);

        // Create new surfaces
        var surfaces: [3]c.VASurfaceID = undefined;
        var status = c.vaCreateSurfaces(
            self.va_display,
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
            self.va_display,
            self.va_config,
            @intCast(encode_width),
            @intCast(encode_height),
            c.VA_PROGRESSIVE,
            &surfaces,
            3,
            &self.va_context,
        );
        if (status != c.VA_STATUS_SUCCESS) {
            _ = c.vaDestroySurfaces(self.va_display, &surfaces, 3);
            return error.VaContextFailed;
        }

        // Create new coded buffer
        status = vaCreateBuffer(
            self.va_display,
            self.va_context,
            VAEncCodedBufferType,
            MAX_OUTPUT_SIZE,
            1,
            null,
            &self.coded_buf,
        );
        if (status != c.VA_STATUS_SUCCESS) {
            _ = c.vaDestroyContext(self.va_display, self.va_context);
            _ = c.vaDestroySurfaces(self.va_display, &surfaces, 3);
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
        // Reset pipeline state - discard any pending frame on resize
        self.pending_frame = false;
        self.pending_is_keyframe = false;

        // Regenerate SPS/PPS for new dimensions
        self.generateSPS();
        self.generatePPS();
    }

    /// Convert RGBA to NV12 and upload to VA surface using vaCreateImage + vaPutImage
    fn uploadFrame(self: *VideoEncoder, rgba_data: []const u8) VaError!void {
        const dst_width = self.width;
        const dst_height = self.height;
        const src_width = self.source_width;
        const src_height = self.source_height;

        // Get supported image formats
        var formats: [64]c.VAImageFormat = undefined;
        var actual_formats: c_int = 0;
        var status = c.vaQueryImageFormats(self.va_display, &formats, &actual_formats);
        if (status != c.VA_STATUS_SUCCESS) {
            std.debug.print("VAAPI: vaQueryImageFormats failed: {}\n", .{status});
            return error.VaImageFailed;
        }

        // Find NV12 format
        var nv12_format: ?c.VAImageFormat = null;
        const num_to_check: usize = @min(@as(usize, @intCast(actual_formats)), 64);
        for (formats[0..num_to_check]) |fmt| {
            if (fmt.fourcc == 0x3231564e) { // "NV12"
                nv12_format = fmt;
                break;
            }
        }

        if (nv12_format == null) {
            std.debug.print("VAAPI: NV12 format not supported\n", .{});
            return error.VaImageFailed;
        }

        // Create an image
        var image: c.VAImage = undefined;
        status = c.vaCreateImage(self.va_display, &nv12_format.?, @intCast(dst_width), @intCast(dst_height), &image);
        if (status != c.VA_STATUS_SUCCESS) {
            std.debug.print("VAAPI: vaCreateImage failed: {}\n", .{status});
            return error.VaImageFailed;
        }
        defer _ = c.vaDestroyImage(self.va_display, image.image_id);

        // Map the image buffer
        var mapped_ptr: ?*anyopaque = null;
        status = c.vaMapBuffer(self.va_display, image.buf, &mapped_ptr);
        if (status != c.VA_STATUS_SUCCESS) {
            std.debug.print("VAAPI: vaMapBuffer failed: status={}\n", .{status});
            return error.VaMapFailed;
        }

        const mapped: [*]u8 = @ptrCast(mapped_ptr);

        // Convert RGBA to NV12
        // NV12 has Y plane followed by interleaved UV plane
        const y_offset = image.offsets[0];
        const uv_offset = image.offsets[1];
        const y_pitch = image.pitches[0]; // Hardware stride (may be > dst_width due to alignment)
        const uv_pitch = image.pitches[1];

        // Scale source to destination using nearest-neighbor sampling
        // When src > dst, we need to downsample; when src < dst, we copy and pad
        // Source: tightly packed at src_width x src_height
        // Destination: aligned surface with y_pitch stride, dst_width x dst_height
        const needs_scale = (src_width > dst_width) or (src_height > dst_height);

        var y: u32 = 0;
        while (y < dst_height) : (y += 1) {
            // Map destination Y to source Y (nearest neighbor)
            const src_y: u32 = if (needs_scale)
                @intFromFloat(@as(f64, @floatFromInt(y)) * @as(f64, @floatFromInt(src_height)) / @as(f64, @floatFromInt(dst_height)))
            else
                y;

            var x: u32 = 0;

            // If source row is beyond source height, fill with black
            if (src_y >= src_height) {
                while (x < dst_width) : (x += 1) {
                    mapped[y_offset + y * y_pitch + x] = 16; // Black in Y
                }
                continue;
            }

            // Sample source pixels (scaled or 1:1)
            const copy_width = if (needs_scale) dst_width else @min(src_width, dst_width);
            while (x < copy_width) : (x += 1) {
                const src_x: u32 = if (needs_scale)
                    @intFromFloat(@as(f64, @floatFromInt(x)) * @as(f64, @floatFromInt(src_width)) / @as(f64, @floatFromInt(dst_width)))
                else
                    x;

                if (src_x >= src_width) {
                    mapped[y_offset + y * y_pitch + x] = 16; // Black
                    continue;
                }

                const src_idx = (src_y * src_width + src_x) * 4;
                const r = @as(u32, rgba_data[src_idx]);
                const g = @as(u32, rgba_data[src_idx + 1]);
                const b = @as(u32, rgba_data[src_idx + 2]);

                // RGB to Y (BT.601)
                const y_val: u8 = @intCast(@min(255, 16 + ((66 * r + 129 * g + 25 * b + 128) >> 8)));
                mapped[y_offset + y * y_pitch + x] = y_val;
            }

            // Fill padding columns with black (Y=16)
            while (x < dst_width) : (x += 1) {
                mapped[y_offset + y * y_pitch + x] = 16; // Black in Y
            }
        }

        // UV plane (half resolution, interleaved)
        // Scale UV plane similarly to Y plane, using nearest neighbor
        const dst_uv_width = dst_width / 2;
        const dst_uv_height = dst_height / 2;

        y = 0;
        while (y < dst_uv_height) : (y += 1) {
            // Map destination UV Y to source Y (at full resolution, then sample 2x2 block)
            const dst_full_y = y * 2;
            const src_full_y: u32 = if (needs_scale)
                @intFromFloat(@as(f64, @floatFromInt(dst_full_y)) * @as(f64, @floatFromInt(src_height)) / @as(f64, @floatFromInt(dst_height)))
            else
                dst_full_y;

            var x: u32 = 0;

            // If source row is beyond source height, fill with neutral
            if (src_full_y >= src_height) {
                while (x < dst_uv_width) : (x += 1) {
                    mapped[uv_offset + y * uv_pitch + x * 2] = 128; // Neutral U
                    mapped[uv_offset + y * uv_pitch + x * 2 + 1] = 128; // Neutral V
                }
                continue;
            }

            // Sample UV from source (scaled or 1:1)
            while (x < dst_uv_width) : (x += 1) {
                const dst_full_x = x * 2;
                const src_full_x: u32 = if (needs_scale)
                    @intFromFloat(@as(f64, @floatFromInt(dst_full_x)) * @as(f64, @floatFromInt(src_width)) / @as(f64, @floatFromInt(dst_width)))
                else
                    dst_full_x;

                if (src_full_x >= src_width) {
                    mapped[uv_offset + y * uv_pitch + x * 2] = 128; // Neutral U
                    mapped[uv_offset + y * uv_pitch + x * 2 + 1] = 128; // Neutral V
                    continue;
                }

                const clamped_src_x = @min(src_full_x, src_width - 1);
                const clamped_src_y = @min(src_full_y, src_height - 1);
                const src_idx = (clamped_src_y * src_width + clamped_src_x) * 4;

                const r = @as(i32, @intCast(rgba_data[src_idx]));
                const g = @as(i32, @intCast(rgba_data[src_idx + 1]));
                const b = @as(i32, @intCast(rgba_data[src_idx + 2]));

                // RGB to U,V (BT.601)
                const u_val: u8 = @intCast(@as(u32, @intCast(@max(0, @min(255, 128 + ((-38 * r - 74 * g + 112 * b + 128) >> 8))))));
                const v_val: u8 = @intCast(@as(u32, @intCast(@max(0, @min(255, 128 + ((112 * r - 94 * g - 18 * b + 128) >> 8))))));

                mapped[uv_offset + y * uv_pitch + x * 2] = u_val;
                mapped[uv_offset + y * uv_pitch + x * 2 + 1] = v_val;
            }
        }

        // Unmap the buffer before putting the image
        status = c.vaUnmapBuffer(self.va_display, image.buf);
        if (status != c.VA_STATUS_SUCCESS) {
            std.debug.print("VAAPI: vaUnmapBuffer failed: {}\n", .{status});
            return error.VaMapFailed;
        }

        // Put the image to the surface
        status = c.vaPutImage(self.va_display, self.src_surface, image.image_id, 0, 0, @intCast(dst_width), @intCast(dst_height), 0, 0, @intCast(dst_width), @intCast(dst_height));
        if (status != c.VA_STATUS_SUCCESS) {
            std.debug.print("VAAPI: vaPutImage failed: {}\n", .{status});
            return error.VaImageFailed;
        }
    }

    /// Encode RGBA frame to H.264
    /// If width/height are provided and differ from source dimensions, auto-resize.
    pub fn encode(self: *VideoEncoder, rgba_data: []const u8, force_keyframe: bool) VaError!?EncodeResult {
        return self.encodeWithDimensions(rgba_data, force_keyframe, null, null);
    }

    /// Encode RGBA frame to H.264 with explicit dimensions
    /// Uses pipelined encoding: submits frame N and returns frame N-1's output.
    /// This avoids blocking on the current frame's GPU encoding.
    pub fn encodeWithDimensions(self: *VideoEncoder, rgba_data: []const u8, force_keyframe: bool, width: ?u32, height: ?u32) VaError!?EncodeResult {
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

        // Result from PREVIOUS frame (if any)
        var result: ?EncodeResult = null;

        // If we have a pending frame from last call, sync and read it now
        // The GPU has had a full frame time to complete encoding
        if (self.pending_frame) {
            // Sync the surface that was encoded last frame (now ref_surface after swap)
            var status = c.vaSyncSurface(self.va_display, self.ref_surface);
            if (status != c.VA_STATUS_SUCCESS) return error.VaSyncFailed;

            // Map coded buffer to get H.264 data from previous frame
            var coded_seg_ptr: ?*anyopaque = null;
            status = c.vaMapBuffer(self.va_display, self.coded_buf, &coded_seg_ptr);
            if (status != c.VA_STATUS_SUCCESS) return error.VaMapCodedFailed;

            // Copy encoded data with SPS/PPS for keyframes
            self.output_len = 0;

            // For keyframes (IDR), prepend SPS and PPS NAL units
            if (self.pending_is_keyframe) {
                @memcpy(self.output_buffer[0..self.sps_len], self.sps_data[0..self.sps_len]);
                self.output_len = self.sps_len;
                @memcpy(self.output_buffer[self.output_len..][0..self.pps_len], self.pps_data[0..self.pps_len]);
                self.output_len += self.pps_len;
            }

            // Copy VA-API encoded slice data
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

            _ = c.vaUnmapBuffer(self.va_display, self.coded_buf);

            if (self.output_len > 0) {
                result = EncodeResult{
                    .data = self.output_buffer[0..self.output_len],
                    .is_keyframe = self.pending_is_keyframe,
                };
            }
        }

        // Now submit the CURRENT frame to encoder (non-blocking)
        const is_keyframe = force_keyframe or (self.frame_count == 0) or
            (@mod(self.frame_count, @as(i64, self.keyframe_interval)) == 0);

        // Upload RGBA data to VA surface
        try self.uploadFrame(rgba_data);

        // Begin picture - use src_surface as both input and reconstruction target
        var status = vaBeginPicture(self.va_display, self.va_context, self.src_surface);
        if (status != c.VA_STATUS_SUCCESS) {
            return error.VaBeginPictureFailed;
        }

        // Create sequence parameter buffer (using raw byte buffer to avoid bitfield union issues)
        var seq_param: [SEQ_PARAM_SIZE]u8 = std.mem.zeroes([SEQ_PARAM_SIZE]u8);
        writeU8(&seq_param, SEQ_seq_parameter_set_id, 0);
        writeU8(&seq_param, SEQ_level_idc, 41);
        writeU32(&seq_param, SEQ_intra_period, self.keyframe_interval);
        writeU32(&seq_param, SEQ_intra_idr_period, self.keyframe_interval);
        writeU32(&seq_param, SEQ_ip_period, 1);
        writeU32(&seq_param, SEQ_bits_per_second, self.current_bitrate);
        writeU32(&seq_param, SEQ_max_num_ref_frames, 1);
        writeU16(&seq_param, SEQ_picture_width_in_mbs, @intCast(self.width / 16));
        writeU16(&seq_param, SEQ_picture_height_in_mbs, @intCast(self.height / 16));
        // seq_fields bitfield for Main/High profile:
        // bits 0-1: chroma_format_idc = 1
        // bit 2: frame_mbs_only_flag = 1
        // bit 5: direct_8x8_inference_flag = 1 (for B-frame direct mode, even if not used)
        // bits 6-9: log2_max_frame_num_minus4 = 0
        // bits 10-11: pic_order_cnt_type = 0
        // bits 12-15: log2_max_pic_order_cnt_lsb_minus4 = 4
        writeU32(&seq_param, SEQ_seq_fields, 0x4025);
        writeU32(&seq_param, SEQ_time_scale, 60);
        writeU32(&seq_param, SEQ_num_units_in_tick, 1);

        var seq_buf: c.VABufferID = 0;
        status = vaCreateBuffer(
            self.va_display,
            self.va_context,
            VAEncSequenceParameterBufferType,
            SEQ_PARAM_SIZE,
            1,
            &seq_param,
            &seq_buf,
        );
        if (status != c.VA_STATUS_SUCCESS) {
            std.debug.print("ENCODER: vaCreateBuffer seq failed: {}\n", .{status});
            _ = vaEndPicture(self.va_display, self.va_context);
            return error.VaSeqBufferFailed;
        }
        defer _ = vaDestroyBuffer(self.va_display, seq_buf);

        // Create picture parameter buffer
        var pic_param: [PIC_PARAM_SIZE]u8 = std.mem.zeroes([PIC_PARAM_SIZE]u8);
        // CurrPic (VAPictureH264 at offset 0) - must match vaBeginPicture surface
        writeU32(&pic_param, PIC_CurrPic + PICH264_picture_id, self.src_surface);
        writeI32(&pic_param, PIC_CurrPic + PICH264_TopFieldOrderCnt, @intCast(self.frame_count * 2));
        // coded_buf
        writeU32(&pic_param, PIC_coded_buf, self.coded_buf);
        writeU8(&pic_param, PIC_pic_parameter_set_id, 0);
        writeU8(&pic_param, PIC_seq_parameter_set_id, 0);
        // frame_num: 0 for IDR, increments for P-frames (mod max_frame_num)
        writeU16(&pic_param, PIC_frame_num, if (is_keyframe) 0 else @intCast(@mod(self.frame_count, 16)));
        // Lower QP = higher quality. 18-22 is high quality for terminal text.
        // Default H.264 is 26, but terminals need sharp text, not smooth video.
        writeU8(&pic_param, PIC_pic_init_qp, 20);
        writeU8(&pic_param, PIC_num_ref_idx_l0_active_minus1, 0);
        // pic_fields bits: idr_pic_flag(0), reference_pic_flag(1), entropy_coding_mode_flag(2)
        // For CAVLC: entropy_coding_mode_flag = 0
        // IDR: idr=1, ref=1, entropy=0 → 0x03
        // P:   idr=0, ref=1, entropy=0 → 0x02
        writeU32(&pic_param, PIC_pic_fields, if (is_keyframe) 0x03 else 0x02);

        // Reference pictures
        if (!is_keyframe) {
            writeU32(&pic_param, PIC_ReferenceFrames + PICH264_picture_id, self.ref_surface);
            writeU32(&pic_param, PIC_ReferenceFrames + PICH264_flags, VA_PICTURE_H264_SHORT_TERM_REFERENCE);
        }
        // Mark rest as invalid
        var i: usize = if (is_keyframe) 0 else 1;
        while (i < 16) : (i += 1) {
            const ref_offset = PIC_ReferenceFrames + i * PICTURE_H264_SIZE;
            writeU32(&pic_param, ref_offset + PICH264_picture_id, c.VA_INVALID_SURFACE);
            writeU32(&pic_param, ref_offset + PICH264_flags, VA_PICTURE_H264_INVALID);
        }

        var pic_buf: c.VABufferID = 0;
        status = vaCreateBuffer(
            self.va_display,
            self.va_context,
            VAEncPictureParameterBufferType,
            PIC_PARAM_SIZE,
            1,
            &pic_param,
            &pic_buf,
        );
        if (status != c.VA_STATUS_SUCCESS) {
            std.debug.print("ENCODER: vaCreateBuffer pic failed: {}\n", .{status});
            _ = vaEndPicture(self.va_display, self.va_context);
            return error.VaPicBufferFailed;
        }
        defer _ = vaDestroyBuffer(self.va_display, pic_buf);

        // Create slice parameter buffer
        var slice_param: [SLICE_PARAM_SIZE]u8 = std.mem.zeroes([SLICE_PARAM_SIZE]u8);
        writeU32(&slice_param, SLICE_macroblock_address, 0);
        writeU32(&slice_param, SLICE_num_macroblocks, (self.width / 16) * (self.height / 16));
        writeU32(&slice_param, SLICE_macroblock_info, c.VA_INVALID_ID); // No macroblock info buffer
        writeU8(&slice_param, SLICE_slice_type, if (is_keyframe) 2 else 0); // I=2, P=0
        writeU8(&slice_param, SLICE_pic_parameter_set_id, 0);
        writeU16(&slice_param, SLICE_idr_pic_id, if (is_keyframe) @intCast(@mod(self.frame_count, 256)) else 0);
        writeU16(&slice_param, SLICE_pic_order_cnt_lsb, @intCast(@mod(self.frame_count * 2, 256)));
        writeU8(&slice_param, SLICE_num_ref_idx_l0_active_minus1, 0);
        writeU8(&slice_param, SLICE_num_ref_idx_l1_active_minus1, 0);

        // Initialize RefPicList0 and RefPicList1 - all entries must be marked invalid
        var j: usize = 0;
        while (j < 32) : (j += 1) {
            // RefPicList0[j]
            const ref0_offset = SLICE_RefPicList0 + j * PICTURE_H264_SIZE;
            writeU32(&slice_param, ref0_offset + PICH264_picture_id, c.VA_INVALID_SURFACE);
            writeU32(&slice_param, ref0_offset + PICH264_flags, VA_PICTURE_H264_INVALID);
            // RefPicList1[j]
            const ref1_offset = SLICE_RefPicList1 + j * PICTURE_H264_SIZE;
            writeU32(&slice_param, ref1_offset + PICH264_picture_id, c.VA_INVALID_SURFACE);
            writeU32(&slice_param, ref1_offset + PICH264_flags, VA_PICTURE_H264_INVALID);
        }

        // For P-frames, set up reference in RefPicList0[0]
        if (!is_keyframe) {
            writeU32(&slice_param, SLICE_RefPicList0 + PICH264_picture_id, self.ref_surface);
            writeU32(&slice_param, SLICE_RefPicList0 + PICH264_flags, VA_PICTURE_H264_SHORT_TERM_REFERENCE);
        }

        writeU8(&slice_param, SLICE_cabac_init_idc, 0);
        writeI8(&slice_param, SLICE_slice_qp_delta, 0);
        writeU8(&slice_param, SLICE_disable_deblocking_filter_idc, 0);

        var slice_buf: c.VABufferID = 0;
        status = vaCreateBuffer(
            self.va_display,
            self.va_context,
            VAEncSliceParameterBufferType,
            SLICE_PARAM_SIZE,
            1,
            &slice_param,
            &slice_buf,
        );
        if (status != c.VA_STATUS_SUCCESS) {
            std.debug.print("ENCODER: vaCreateBuffer slice failed: {}\n", .{status});
            _ = vaEndPicture(self.va_display, self.va_context);
            return error.VaSliceBufferFailed;
        }
        defer _ = vaDestroyBuffer(self.va_display, slice_buf);

        // Render all buffers
        var render_bufs = [_]c.VABufferID{ seq_buf, pic_buf, slice_buf };
        status = vaRenderPicture(self.va_display, self.va_context, &render_bufs, 3);
        if (status != c.VA_STATUS_SUCCESS) {
            _ = vaEndPicture(self.va_display, self.va_context);
            return error.VaRenderFailed;
        }

        // End picture - this kicks off async encoding, does NOT wait
        status = vaEndPicture(self.va_display, self.va_context);
        if (status != c.VA_STATUS_SUCCESS) {
            return error.VaEndPictureFailed;
        }

        // Swap surfaces: current frame becomes reference for next P-frame
        const tmp = self.ref_surface;
        self.ref_surface = self.src_surface;
        self.src_surface = tmp;

        // Mark this frame as pending - we'll read its output on NEXT encode call
        self.pending_frame = true;
        self.pending_is_keyframe = is_keyframe;

        self.frame_count += 1;

        // Return PREVIOUS frame's result (or null if this was first frame)
        return result;
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
};
