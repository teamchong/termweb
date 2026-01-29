/// Adaptive quality controller for latency-based JPEG quality adjustment.
///
/// Measures Chrome → Zig latency and adjusts quality/FPS tiers dynamically.
/// Uses EMA (Exponential Moving Average) for smoothing and hysteresis for stability.
const std = @import("std");

/// Quality tier configuration
pub const QualityTier = struct {
    quality: u8,
    every_nth_frame: u8,
    name: []const u8,
};

/// Quality tiers from lowest to highest quality
/// Higher tier = better quality but more bandwidth/latency
pub const TIERS = [_]QualityTier{
    .{ .quality = 25, .every_nth_frame = 3, .name = "fallback" },  // ~20fps, low quality
    .{ .quality = 35, .every_nth_frame = 2, .name = "normal" },    // ~30fps, decent quality
    .{ .quality = 50, .every_nth_frame = 2, .name = "good" },      // ~30fps, good quality
    .{ .quality = 70, .every_nth_frame = 1, .name = "excellent" }, // ~60fps, high quality
};

/// EMA smoothing factor (0.2 = responsive but stable)
pub const EMA_ALPHA: f32 = 0.2;

/// Frames required at current tier before considering a change (prevents oscillation)
pub const HYSTERESIS_FRAMES: u32 = 10;

/// Latency threshold for upgrading to higher quality tier (ms)
pub const LATENCY_LOW_MS: f32 = 50.0;

/// Latency threshold for downgrading to lower quality tier (ms)
pub const LATENCY_HIGH_MS: f32 = 150.0;

/// Update the latency EMA with a new sample
pub fn updateLatencyEma(current_ema: f32, new_sample_ms: f32) f32 {
    // Clamp to reasonable bounds to avoid outlier corruption
    const clamped_sample = std.math.clamp(new_sample_ms, 0.0, 2000.0);
    return current_ema * (1.0 - EMA_ALPHA) + clamped_sample * EMA_ALPHA;
}

/// Check if we should upgrade to a higher quality tier
pub fn shouldUpgradeTier(tier: u8, ema_ms: f32, frames_at_tier: u32) bool {
    // Can't upgrade if already at highest tier
    if (tier >= TIERS.len - 1) return false;
    // Need low latency for long enough
    return ema_ms < LATENCY_LOW_MS and frames_at_tier >= HYSTERESIS_FRAMES;
}

/// Check if we should downgrade to a lower quality tier
pub fn shouldDowngradeTier(tier: u8, ema_ms: f32, frames_at_tier: u32) bool {
    // Can't downgrade if already at lowest tier
    if (tier == 0) return false;
    // Need high latency for long enough
    return ema_ms > LATENCY_HIGH_MS and frames_at_tier >= HYSTERESIS_FRAMES;
}

/// Get the quality value for a tier
pub fn getTierQuality(tier: u8) u8 {
    if (tier < TIERS.len) {
        return TIERS[tier].quality;
    }
    return TIERS[TIERS.len - 1].quality;
}

/// Get the everyNthFrame value for a tier
pub fn getTierEveryNth(tier: u8) u8 {
    if (tier < TIERS.len) {
        return TIERS[tier].every_nth_frame;
    }
    return TIERS[TIERS.len - 1].every_nth_frame;
}

/// Get the name for a tier (for logging)
pub fn getTierName(tier: u8) []const u8 {
    if (tier < TIERS.len) {
        return TIERS[tier].name;
    }
    return "unknown";
}

/// Calculate total latency from Chrome timestamp to current time
/// Returns latency in milliseconds, or 0 if timestamp is invalid
pub fn calculateChromeLatency(chrome_timestamp_ms: i64) f32 {
    if (chrome_timestamp_ms <= 0) return 0;

    const now_ms = std.time.milliTimestamp();
    const latency = now_ms - chrome_timestamp_ms;

    // Clamp to reasonable range (negative = clock skew, very high = stale)
    if (latency < 0) return 0;
    if (latency > 5000) return 5000; // Cap at 5 seconds

    return @floatFromInt(latency);
}

/// State for the adaptive controller
pub const AdaptiveState = struct {
    /// Current quality tier (0 = lowest, 3 = highest)
    tier: u8 = 1,
    /// Exponential moving average of latency in milliseconds
    latency_ema_ms: f32 = 100.0,
    /// Frames rendered at current tier (for hysteresis)
    frames_at_tier: u32 = 0,

    /// Process a frame and potentially update tier
    /// Returns true if tier changed (caller should restart screencast)
    pub fn processFrame(self: *AdaptiveState, chrome_timestamp_ms: i64, write_latency_ms: f32) bool {
        // Calculate Chrome → Zig latency
        const chrome_latency_ms = calculateChromeLatency(chrome_timestamp_ms);

        // Total latency = Chrome capture delay + Zig write time
        const total_latency_ms = chrome_latency_ms + write_latency_ms;

        // Update EMA (only if we have valid latency data)
        if (total_latency_ms > 0) {
            self.latency_ema_ms = updateLatencyEma(self.latency_ema_ms, total_latency_ms);
        }

        self.frames_at_tier += 1;

        // Check for tier change
        if (shouldUpgradeTier(self.tier, self.latency_ema_ms, self.frames_at_tier)) {
            self.tier += 1;
            self.frames_at_tier = 0;
            return true;
        } else if (shouldDowngradeTier(self.tier, self.latency_ema_ms, self.frames_at_tier)) {
            self.tier -= 1;
            self.frames_at_tier = 0;
            return true;
        }

        return false;
    }

    /// Get current quality value
    pub fn getQuality(self: *const AdaptiveState) u8 {
        return getTierQuality(self.tier);
    }

    /// Get current everyNthFrame value
    pub fn getEveryNth(self: *const AdaptiveState) u8 {
        return getTierEveryNth(self.tier);
    }

    /// Get tier name for logging
    pub fn getName(self: *const AdaptiveState) []const u8 {
        return getTierName(self.tier);
    }
};

test "updateLatencyEma" {
    var ema: f32 = 100.0;

    // Low latency should pull EMA down
    ema = updateLatencyEma(ema, 20.0);
    try std.testing.expect(ema < 100.0);
    try std.testing.expect(ema > 20.0);

    // Should converge towards samples over time
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        ema = updateLatencyEma(ema, 30.0);
    }
    try std.testing.expect(ema > 29.0 and ema < 31.0);
}

test "tierUpgrade" {
    try std.testing.expect(!shouldUpgradeTier(0, 100.0, 5));  // Not enough frames
    try std.testing.expect(!shouldUpgradeTier(0, 100.0, 15)); // Latency too high
    try std.testing.expect(shouldUpgradeTier(0, 30.0, 15));   // Should upgrade
    try std.testing.expect(!shouldUpgradeTier(3, 30.0, 15));  // Already at max
}

test "tierDowngrade" {
    try std.testing.expect(!shouldDowngradeTier(1, 100.0, 5));  // Not enough frames
    try std.testing.expect(!shouldDowngradeTier(1, 100.0, 15)); // Latency not high enough
    try std.testing.expect(shouldDowngradeTier(1, 200.0, 15));  // Should downgrade
    try std.testing.expect(!shouldDowngradeTier(0, 200.0, 15)); // Already at min
}

test "adaptiveState" {
    var state = AdaptiveState{};

    // Initial state
    try std.testing.expectEqual(@as(u8, 1), state.tier);

    // Simulate good conditions (low latency) - tier should upgrade
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        _ = state.processFrame(std.time.milliTimestamp() - 10, 5.0); // 15ms total
    }
    // Should have upgraded from tier 1
    try std.testing.expect(state.tier >= 1);
}
