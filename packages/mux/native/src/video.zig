//! Cross-platform video encoder selection.
//!
//! Uses comptime to select the appropriate H.264 encoder:
//! - macOS: VideoToolbox hardware encoder (`video_encoder.zig`)
//! - Linux: VA-API hardware encoder (`video_encoder_linux.zig`)
//!
//! Import this module for platform-agnostic video encoding. The encoder
//! API is identical across platforms - only the implementation differs.
//!
const builtin = @import("builtin");

// Select implementation at compile time
const impl = if (builtin.os.tag == .macos)
    @import("video_encoder.zig")
else
    @import("video_encoder_linux.zig");

// Re-export types and functions
pub const VideoEncoder = impl.VideoEncoder;
pub const EncodeResult = impl.EncodeResult;
