// Cross-platform video encoder
// Uses comptime to select platform-specific implementation:
// - macOS: VideoToolbox hardware encoder
// - Linux: Software x264 encoder (stub for now)

const builtin = @import("builtin");

// Select implementation at compile time
const impl = if (builtin.os.tag == .macos)
    @import("video_encoder.zig")
else
    @import("video_encoder_linux.zig");

// Re-export types and functions
pub const VideoEncoder = impl.VideoEncoder;
pub const EncodeResult = impl.EncodeResult;
