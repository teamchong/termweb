/// Mouse Event Bus - decouples event recording from dispatch
///
/// Design:
/// - Viewer records all raw mouse events (no filtering at viewer level)
/// - Bus decides what to keep/discard based on priority
/// - Dispatch happens at fixed tick rate (see config.SCREENCAST_FPS)
///
/// Priority (highest to lowest):
/// 1. Click (press/release) - queued, never dropped
/// 2. Wheel - keep latest only, replace on new
/// 3. Move/drag - keep latest only, replace on new
const std = @import("std");
const config = @import("config.zig").Config;
const cdp_mod = @import("chrome/cdp_client.zig");
const interact_mod = @import("chrome/interact.zig");
const scroll_mod = @import("chrome/scroll.zig");
const input_mod = @import("terminal/input.zig");
const coordinates_mod = @import("terminal/coordinates.zig");

const MouseEvent = input_mod.MouseEvent;
const MouseButton = input_mod.MouseButton;
const MouseEventType = input_mod.MouseEventType;
const CoordinateMapper = coordinates_mod.CoordinateMapper;
const CdpClient = cdp_mod.CdpClient;

/// Click event stored in queue (never dropped)
pub const ClickEvent = struct {
    browser_x: u32,
    browser_y: u32,
    button: MouseButton,
    is_press: bool, // true = press, false = release
    buttons_state: u32, // bitmask after this event
    click_count: u32, // 1 for single-click, 2 for double-click, 3 for triple-click
};

/// Wheel event (keep latest only)
pub const WheelEvent = struct {
    delta_y: i16,
    viewport_width: u32,
    viewport_height: u32,
};

/// Move event (keep latest only)
pub const MoveEvent = struct {
    browser_x: u32,
    browser_y: u32,
    buttons_state: u32,
};

/// Fixed-size queue for click events
fn BoundedQueue(comptime T: type, comptime capacity: usize) type {
    return struct {
        items: [capacity]T = undefined,
        head: usize = 0,
        tail: usize = 0,
        count: usize = 0,

        const Self = @This();

        pub fn push(self: *Self, item: T) bool {
            if (self.count >= capacity) return false;
            self.items[self.tail] = item;
            self.tail = (self.tail + 1) % capacity;
            self.count += 1;
            return true;
        }

        pub fn pop(self: *Self) ?T {
            if (self.count == 0) return null;
            const item = self.items[self.head];
            self.head = (self.head + 1) % capacity;
            self.count -= 1;
            return item;
        }

        pub fn clear(self: *Self) void {
            self.head = 0;
            self.tail = 0;
            self.count = 0;
        }
    };
}

pub const MouseEventBus = struct {
    // Pending events (updated by record(), consumed by tick())
    pending_clicks: BoundedQueue(ClickEvent, 8),
    pending_wheel: ?WheelEvent,
    pending_move: ?MoveEvent,

    // Last sent position (skip if unchanged)
    last_sent_x: u32,
    last_sent_y: u32,

    // Mouse button state tracking
    buttons_state: u32,

    // Double-click detection
    last_click_time: i64, // nanoseconds
    last_click_x: u32,
    last_click_y: u32,
    last_click_button: MouseButton,
    current_click_count: u32, // tracks consecutive clicks at same position

    // Timing
    last_tick_time: i128,
    tick_interval_ns: i128,

    // Dependencies
    cdp_client: *CdpClient,
    allocator: std.mem.Allocator,

    // Coordinate mapper (may change on resize)
    coord_mapper: ?*const CoordinateMapper,

    // Scroll settings
    natural_scroll: bool,

    const TICK_INTERVAL_NS = config.MOUSE_TICK_MS * std.time.ns_per_ms;
    const DOUBLE_CLICK_TIME_MS = config.DOUBLE_CLICK_TIME_MS;
    const DOUBLE_CLICK_DISTANCE = config.DOUBLE_CLICK_DISTANCE;

    pub fn init(
        cdp_client: *CdpClient,
        allocator: std.mem.Allocator,
        natural_scroll: bool,
    ) MouseEventBus {
        return .{
            .pending_clicks = .{},
            .pending_wheel = null,
            .pending_move = null,
            .last_sent_x = std.math.maxInt(u32),
            .last_sent_y = std.math.maxInt(u32),
            .buttons_state = 0,
            .last_click_time = 0,
            .last_click_x = 0,
            .last_click_y = 0,
            .last_click_button = .none,
            .current_click_count = 0,
            .last_tick_time = 0,
            .tick_interval_ns = TICK_INTERVAL_NS,
            .cdp_client = cdp_client,
            .allocator = allocator,
            .coord_mapper = null,
            .natural_scroll = natural_scroll,
        };
    }

    /// Update coordinate mapper reference (call on resize)
    pub fn setCoordMapper(self: *MouseEventBus, mapper: ?*const CoordinateMapper) void {
        self.coord_mapper = mapper;
    }

    /// Record a raw mouse event - bus decides what to keep/discard
    /// Returns the current buttons state for caller to track
    pub fn record(
        self: *MouseEventBus,
        mouse: MouseEvent,
        term_x: u16,
        term_y: u16,
        viewport_width: u32,
        viewport_height: u32,
    ) u32 {
        const mapper = self.coord_mapper orelse return self.buttons_state;

        switch (mouse.type) {
            .press => {
                // Update button state
                const mask = buttonMask(mouse.button);
                self.buttons_state |= mask;

                // Convert to browser coords and send immediately (clicks are high priority)
                if (mapper.terminalToBrowser(term_x, term_y)) |coords| {
                    // Detect double/triple click
                    const now = std.time.milliTimestamp();
                    const time_diff = now - self.last_click_time;
                    const dx = if (coords.x >= self.last_click_x) coords.x - self.last_click_x else self.last_click_x - coords.x;
                    const dy = if (coords.y >= self.last_click_y) coords.y - self.last_click_y else self.last_click_y - coords.y;
                    const same_position = dx <= DOUBLE_CLICK_DISTANCE and dy <= DOUBLE_CLICK_DISTANCE;
                    const same_button = mouse.button == self.last_click_button;

                    var click_count: u32 = 1;
                    if (time_diff <= DOUBLE_CLICK_TIME_MS and same_position and same_button) {
                        // Consecutive click at same position - increment count (max 3)
                        self.current_click_count = @min(self.current_click_count + 1, 3);
                        click_count = self.current_click_count;
                    } else {
                        // New click sequence
                        self.current_click_count = 1;
                        click_count = 1;
                    }

                    // Update tracking
                    self.last_click_time = now;
                    self.last_click_x = coords.x;
                    self.last_click_y = coords.y;
                    self.last_click_button = mouse.button;

                    // Send immediately - clicks are highest priority, never queued
                    self.sendClick(ClickEvent{
                        .browser_x = coords.x,
                        .browser_y = coords.y,
                        .button = mouse.button,
                        .is_press = true,
                        .buttons_state = self.buttons_state,
                        .click_count = click_count,
                    });
                }
            },
            .release => {
                // Update button state
                const mask = buttonMask(mouse.button);
                self.buttons_state &= ~mask;

                // Convert to browser coords and send immediately
                if (mapper.terminalToBrowser(term_x, term_y)) |coords| {
                    // Send immediately - releases are highest priority, never queued
                    self.sendClick(ClickEvent{
                        .browser_x = coords.x,
                        .browser_y = coords.y,
                        .button = mouse.button,
                        .is_press = false,
                        .buttons_state = self.buttons_state,
                        .click_count = self.current_click_count,
                    });
                }
            },
            .wheel => {
                // Replace pending wheel with latest
                self.pending_wheel = WheelEvent{
                    .delta_y = mouse.delta_y,
                    .viewport_width = viewport_width,
                    .viewport_height = viewport_height,
                };
            },
            .move, .drag => {
                // Throttle moves - keep latest only, dispatch on tick
                if (mapper.terminalToBrowser(term_x, term_y)) |coords| {
                    self.pending_move = MoveEvent{
                        .browser_x = coords.x,
                        .browser_y = coords.y,
                        .buttons_state = self.buttons_state,
                    };
                }
            },
        }

        return self.buttons_state;
    }

    /// Check if tick is due and dispatch pending events
    /// Call this frequently from event loop (will no-op if not time yet)
    pub fn maybeTick(self: *MouseEventBus) void {
        const now = std.time.nanoTimestamp();
        if (now - self.last_tick_time >= self.tick_interval_ns) {
            self.tick();
            self.last_tick_time = now;
        }
    }

    /// Dispatch pending events (moves and wheel are throttled)
    fn tick(self: *MouseEventBus) void {
        // Dispatch pending move (throttled to match screencast fps)
        if (self.pending_move) |move| {
            self.sendMove(move);
            self.pending_move = null;
        }

        // Dispatch pending wheel
        if (self.pending_wheel) |wheel| {
            self.sendWheel(wheel);
            self.pending_wheel = null;
        }
    }

    fn sendClick(self: *MouseEventBus, click: ClickEvent) void {
        const event_type = if (click.is_press) "mousePressed" else "mouseReleased";
        const button_name = buttonName(click.button);

        interact_mod.sendMouseEvent(
            self.cdp_client,
            self.allocator,
            event_type,
            click.browser_x,
            click.browser_y,
            button_name,
            click.buttons_state,
            click.click_count,
        ) catch {};
    }

    fn sendWheel(self: *MouseEventBus, wheel: WheelEvent) void {
        // Determine scroll direction based on natural_scroll setting
        const scroll_down = if (self.natural_scroll)
            wheel.delta_y < 0
        else
            wheel.delta_y > 0;

        if (wheel.delta_y != 0) {
            if (scroll_down) {
                scroll_mod.scrollLineDown(
                    self.cdp_client,
                    self.allocator,
                    wheel.viewport_width,
                    wheel.viewport_height,
                ) catch {};
            } else {
                scroll_mod.scrollLineUp(
                    self.cdp_client,
                    self.allocator,
                    wheel.viewport_width,
                    wheel.viewport_height,
                ) catch {};
            }
        }
    }

    fn sendMove(self: *MouseEventBus, move: MoveEvent) void {
        // Skip if position unchanged (reduces CDP bandwidth)
        if (move.browser_x == self.last_sent_x and move.browser_y == self.last_sent_y) {
            return;
        }
        self.last_sent_x = move.browser_x;
        self.last_sent_y = move.browser_y;

        interact_mod.sendMouseEvent(
            self.cdp_client,
            self.allocator,
            "mouseMoved",
            move.browser_x,
            move.browser_y,
            "none",
            move.buttons_state,
            0, // clickCount
        ) catch {};
    }

    /// Clear pending events (e.g., on mode change)
    pub fn clear(self: *MouseEventBus) void {
        self.pending_move = null;
        self.pending_wheel = null;
    }

    fn buttonMask(button: MouseButton) u32 {
        return switch (button) {
            .left => 1,
            .right => 2,
            .middle => 4,
            .none => 0,
        };
    }

    fn buttonName(button: MouseButton) []const u8 {
        return switch (button) {
            .left => "left",
            .right => "right",
            .middle => "middle",
            .none => "none",
        };
    }
};
