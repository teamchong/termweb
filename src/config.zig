/// Global configuration - single source of truth
pub const Config = struct {
    /// Maximum viewport pixels (controls resolution cap)
    pub const MAX_PIXELS: u64 = 2_000_000;

    /// Default JPEG quality (higher since we have adaptive control)
    pub const JPEG_QUALITY: u8 = 35;

    /// Default quality tier (0=fallback, 1=normal, 2=good, 3=excellent)
    pub const DEFAULT_QUALITY_TIER: u8 = 1;

    /// Calculate adaptive JPEG quality based on pixel count (fallback when latency-based not ready)
    /// Smaller screens get higher quality, larger screens get more compression
    pub fn getAdaptiveQuality(total_pixels: u64) u8 {
        if (total_pixels < 200_000) return 70;   // Small: high quality
        if (total_pixels < 500_000) return 50;   // Medium: good quality
        if (total_pixels < 1_000_000) return 40; // Large: balanced
        if (total_pixels < 1_500_000) return 35; // HD: moderate compression
        return 30;                                // Full HD+: more compression
    }

    /// Quality tiers for latency-based adaptive control
    const quality_tiers = [_]u8{ 25, 35, 50, 70 };
    const every_nth_tiers = [_]u8{ 3, 2, 2, 1 };

    /// Get quality for a tier (0-3)
    pub fn getTierQuality(tier: u8) u8 {
        if (tier < quality_tiers.len) return quality_tiers[tier];
        return quality_tiers[quality_tiers.len - 1];
    }

    /// Get everyNthFrame for a tier (0-3)
    pub fn getTierEveryNth(tier: u8) u8 {
        if (tier < every_nth_tiers.len) return every_nth_tiers[tier];
        return every_nth_tiers[every_nth_tiers.len - 1];
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
