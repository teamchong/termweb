/// Global configuration - single source of truth
pub const Config = struct {
    /// Maximum viewport pixels (controls resolution cap)
    pub const MAX_PIXELS: u64 = 2_000_000;

    /// Default JPEG quality (used when adaptive not applicable)
    pub const JPEG_QUALITY: u8 = 20;

    /// Calculate adaptive JPEG quality based on pixel count
    /// Smaller screens get higher quality, larger screens get more compression
    pub fn getAdaptiveQuality(total_pixels: u64) u8 {
        if (total_pixels < 200_000) return 80;   // Small: high quality
        if (total_pixels < 500_000) return 60;   // Medium: good quality
        if (total_pixels < 1_000_000) return 45; // Large: balanced
        if (total_pixels < 1_500_000) return 35; // HD: more compression
        return 25;                                // Full HD+: max compression
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
