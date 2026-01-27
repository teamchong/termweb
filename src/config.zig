/// Global configuration - single source of truth
pub const Config = struct {
    /// Default JPEG quality (used when adaptive not applicable)
    pub const JPEG_QUALITY: u8 = 60;

    /// Frame server port (for extension tabCapture WebSocket connection)
    pub const FRAME_SERVER_PORT: u16 = 9223;

    /// FPS configuration for adaptive frame rate
    pub const MIN_FPS: u32 = 5;
    pub const MAX_FPS: u32 = 120;
    pub const FPS_RAMP_UP: u32 = 5; // Increase per adjustment
    pub const FPS_RAMP_DOWN: u32 = 10; // Decrease per adjustment (faster ramp down)

    /// Calculate adaptive JPEG quality based on pixel count
    /// Smaller screens get higher quality, larger screens get more compression
    pub fn getAdaptiveQuality(total_pixels: u64) u8 {
        if (total_pixels < 200_000) return 80;   // Small: high quality
        if (total_pixels < 500_000) return 60;   // Medium: good quality
        if (total_pixels < 1_000_000) return 45; // Large: balanced
        if (total_pixels < 1_500_000) return 35; // HD: more compression
        return 25;                                // Full HD+: max compression
    }

    /// Speed-based adaptive quality thresholds
    pub const QUALITY_MIN: u8 = 30;
    pub const QUALITY_MAX: u8 = 90;
    pub const QUALITY_STEP: u8 = 10;
    pub const FRAME_TIME_FAST_MS: u64 = 20;  // Below this = increase quality
    pub const FRAME_TIME_SLOW_MS: u64 = 50;  // Above this = decrease quality

    /// Adjust quality based on frame time
    pub fn adjustQualityForSpeed(current: u8, frame_time_ms: u64) u8 {
        if (frame_time_ms < FRAME_TIME_FAST_MS and current < QUALITY_MAX) {
            return current + QUALITY_STEP;
        } else if (frame_time_ms > FRAME_TIME_SLOW_MS and current > QUALITY_MIN) {
            return current - QUALITY_STEP;
        }
        return current;
    }

    /// Default screencast frame rate
    pub const DEFAULT_FPS: u32 = 30;

    /// Calculate mouse tick interval from FPS
    pub fn getMouseTickMs(fps: u32) u64 {
        return if (fps > 0) 1000 / fps else 33;
    }

    /// Calculate everyNthFrame for Chrome screencast (Chrome renders at 60fps internally)
    pub fn getEveryNthFrame(fps: u32) u8 {
        return if (fps > 0) @intCast(60 / fps) else 2;
    }

    /// Double-click detection
    pub const DOUBLE_CLICK_TIME_MS: i64 = 400;
    pub const DOUBLE_CLICK_DISTANCE: u32 = 15;

    /// Kitty graphics chunk size (larger = fewer writes, but more memory)
    pub const KITTY_CHUNK_SIZE: usize = 65536; // 64KB
};
