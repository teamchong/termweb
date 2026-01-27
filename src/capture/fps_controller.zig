/// Adaptive FPS controller for frame capture
/// Adjusts frame rate based on render throughput to optimize for different conditions:
/// - Ramp up when rendering is fast (local terminal)
/// - Ramp down when rendering is slow (SSH latency, heavy load)
const std = @import("std");

pub const FpsController = struct {
    /// Current target FPS
    target_fps: u32 = 30,

    /// Minimum allowed FPS
    min_fps: u32 = 15,

    /// Maximum allowed FPS
    max_fps: u32 = 120,

    /// How much to increase FPS when fast
    ramp_up_step: u32 = 5,

    /// How much to decrease FPS when slow
    ramp_down_step: u32 = 10,

    /// Target frame time in nanoseconds (derived from target_fps)
    target_frame_time_ns: u64 = 33_333_333, // 30fps default

    /// Sliding window of recent render times
    render_times: [8]u64 = [_]u64{0} ** 8,
    render_time_idx: usize = 0,
    render_time_count: usize = 0,

    /// Last FPS adjustment time
    last_adjust_time: i128 = 0,

    /// Minimum interval between FPS adjustments (nanoseconds)
    adjust_interval_ns: u64 = 500_000_000, // 500ms

    /// Initialize with default settings
    pub fn init() FpsController {
        return .{};
    }

    /// Initialize with custom FPS range
    pub fn initWithRange(min_fps: u32, max_fps: u32, initial_fps: u32) FpsController {
        const clamped_fps = std.math.clamp(initial_fps, min_fps, max_fps);
        return .{
            .min_fps = min_fps,
            .max_fps = max_fps,
            .target_fps = clamped_fps,
            .target_frame_time_ns = 1_000_000_000 / clamped_fps,
        };
    }

    /// Record a render time measurement
    /// render_time_ns: Time taken to render and transmit one frame
    pub fn recordRenderTime(self: *FpsController, render_time_ns: u64) void {
        self.render_times[self.render_time_idx] = render_time_ns;
        self.render_time_idx = (self.render_time_idx + 1) % self.render_times.len;
        if (self.render_time_count < self.render_times.len) {
            self.render_time_count += 1;
        }
    }

    /// Get average render time from sliding window
    fn getAverageRenderTime(self: *const FpsController) ?u64 {
        if (self.render_time_count == 0) return null;

        var sum: u64 = 0;
        for (0..self.render_time_count) |i| {
            sum += self.render_times[i];
        }
        return sum / self.render_time_count;
    }

    /// Adjust FPS based on render throughput
    /// Returns true if FPS was changed
    pub fn adjustFps(self: *FpsController) bool {
        const now = std.time.nanoTimestamp();

        // Rate limit adjustments
        if (self.last_adjust_time != 0) {
            const elapsed = now - self.last_adjust_time;
            if (elapsed < self.adjust_interval_ns) {
                return false;
            }
        }

        const avg_render_time = self.getAverageRenderTime() orelse return false;

        // Calculate what FPS we can actually sustain
        // If render takes 20ms, max sustainable is ~50fps (with some headroom)
        // Guard against division by zero and overflow
        const sustainable_fps = if (avg_render_time > 0 and avg_render_time < 800_000_000)
            @min(self.max_fps, @as(u32, @intCast(800_000_000 / avg_render_time))) // 80% headroom
        else if (avg_render_time == 0)
            self.max_fps
        else
            self.min_fps; // Very slow render, use minimum

        const old_fps = self.target_fps;

        if (sustainable_fps > self.target_fps + self.ramp_up_step) {
            // Can go faster - ramp up
            self.target_fps = @min(self.max_fps, self.target_fps + self.ramp_up_step);
        } else if (sustainable_fps < self.target_fps) {
            // Too slow - ramp down quickly
            self.target_fps = @max(self.min_fps, self.target_fps - self.ramp_down_step);
        }

        if (self.target_fps != old_fps) {
            self.target_frame_time_ns = 1_000_000_000 / self.target_fps;
            self.last_adjust_time = now;
            return true;
        }

        self.last_adjust_time = now;
        return false;
    }

    /// Get current target FPS
    pub fn getTargetFps(self: *const FpsController) u32 {
        return self.target_fps;
    }

    /// Get target frame time in milliseconds
    pub fn getTargetFrameTimeMs(self: *const FpsController) u32 {
        return @intCast(self.target_frame_time_ns / 1_000_000);
    }

    /// Force set FPS (overrides adaptive logic temporarily)
    pub fn setFps(self: *FpsController, fps: u32) void {
        self.target_fps = std.math.clamp(fps, self.min_fps, self.max_fps);
        self.target_frame_time_ns = 1_000_000_000 / self.target_fps;
        // Reset render time history to start fresh
        self.render_time_count = 0;
        self.render_time_idx = 0;
    }

    /// Reset controller state
    pub fn reset(self: *FpsController) void {
        self.render_time_count = 0;
        self.render_time_idx = 0;
        self.last_adjust_time = 0;
    }
};

test "FpsController basic" {
    var controller = FpsController.init();

    // Initial state
    try std.testing.expectEqual(@as(u32, 30), controller.getTargetFps());

    // Record fast render times (10ms)
    for (0..8) |_| {
        controller.recordRenderTime(10_000_000);
    }

    // Should want to ramp up
    _ = controller.adjustFps();
    try std.testing.expect(controller.getTargetFps() >= 30);
}

test "FpsController slow rendering" {
    var controller = FpsController.initWithRange(5, 120, 60);

    // Record slow render times (50ms = 20fps max sustainable)
    for (0..8) |_| {
        controller.recordRenderTime(50_000_000);
    }

    // Force adjustment by setting last_adjust_time to past
    controller.last_adjust_time = 0;

    // Should want to ramp down
    const changed = controller.adjustFps();
    if (changed) {
        try std.testing.expect(controller.getTargetFps() < 60);
    }
}
