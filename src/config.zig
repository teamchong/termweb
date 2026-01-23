/// Global configuration - single source of truth
pub const Config = struct {
    /// Maximum viewport pixels (controls resolution cap)
    pub const MAX_PIXELS: u64 = 600_000;

    /// Default JPEG quality (used when adaptive not applicable)
    pub const JPEG_QUALITY: u8 = 20;

    /// Calculate adaptive JPEG quality based on pixel count
    /// Smaller screens get higher quality, larger screens get more compression
    pub fn getAdaptiveQuality(total_pixels: u64) u8 {
        if (total_pixels < 200_000) return 60;
        if (total_pixels < 400_000) return 40;
        if (total_pixels < 500_000) return 30;
        return 20;
    }

    /// Mouse event tick rate in milliseconds
    pub const MOUSE_TICK_MS: u64 = 42; // ~24fps (matches screencast)

    /// Screencast frame rate
    pub const SCREENCAST_FPS: u32 = 24;

    /// Double-click detection
    pub const DOUBLE_CLICK_TIME_MS: i64 = 400;
    pub const DOUBLE_CLICK_DISTANCE: u32 = 15;

    /// Kitty graphics chunk size (larger = fewer writes, but more memory)
    pub const KITTY_CHUNK_SIZE: usize = 65536; // 64KB
};
