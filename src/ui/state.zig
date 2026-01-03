//! UI state management for browser chrome
//!
//! Tracks button states and maps them to the appropriate image assets.

const assets = @import("assets.zig");

pub const ButtonState = enum {
    normal,
    hover,
    active,
    disabled,
    loading, // Only for refresh button
};

pub const UIState = struct {
    // Navigation button states
    back_state: ButtonState = .normal,
    forward_state: ButtonState = .normal,
    refresh_state: ButtonState = .normal,
    close_state: ButtonState = .normal,

    // Navigation capabilities
    can_go_back: bool = false,
    can_go_forward: bool = false,
    is_loading: bool = false,

    // Theme
    theme: assets.Theme = .dark,

    // Dirty flags for selective updates
    back_dirty: bool = true,
    forward_dirty: bool = true,
    refresh_dirty: bool = true,
    close_dirty: bool = true,
    tabbar_dirty: bool = true,
    statusbar_dirty: bool = true,

    /// Get the appropriate back button image for current state
    pub fn getBackImage(self: *const UIState) []const u8 {
        if (!self.can_go_back) {
            return switch (self.theme) {
                .dark => assets.dark.back_disabled,
                .light => assets.light.back_disabled,
            };
        }
        return switch (self.theme) {
            .dark => switch (self.back_state) {
                .normal => assets.dark.back_normal,
                .hover => assets.dark.back_hover,
                .active => assets.dark.back_active,
                .disabled => assets.dark.back_disabled,
                .loading => assets.dark.back_normal,
            },
            .light => switch (self.back_state) {
                .normal => assets.light.back_normal,
                .hover => assets.light.back_hover,
                .active => assets.light.back_active,
                .disabled => assets.light.back_disabled,
                .loading => assets.light.back_normal,
            },
        };
    }

    /// Get the appropriate forward button image for current state
    pub fn getForwardImage(self: *const UIState) []const u8 {
        if (!self.can_go_forward) {
            return switch (self.theme) {
                .dark => assets.dark.forward_disabled,
                .light => assets.light.forward_disabled,
            };
        }
        return switch (self.theme) {
            .dark => switch (self.forward_state) {
                .normal => assets.dark.forward_normal,
                .hover => assets.dark.forward_hover,
                .active => assets.dark.forward_active,
                .disabled => assets.dark.forward_disabled,
                .loading => assets.dark.forward_normal,
            },
            .light => switch (self.forward_state) {
                .normal => assets.light.forward_normal,
                .hover => assets.light.forward_hover,
                .active => assets.light.forward_active,
                .disabled => assets.light.forward_disabled,
                .loading => assets.light.forward_normal,
            },
        };
    }

    /// Get the appropriate refresh button image for current state
    pub fn getRefreshImage(self: *const UIState) []const u8 {
        if (self.is_loading) {
            return switch (self.theme) {
                .dark => assets.dark.refresh_loading,
                .light => assets.light.refresh_loading,
            };
        }
        return switch (self.theme) {
            .dark => switch (self.refresh_state) {
                .normal => assets.dark.refresh_normal,
                .hover => assets.dark.refresh_hover,
                .active => assets.dark.refresh_active,
                .disabled, .loading => assets.dark.refresh_loading,
            },
            .light => switch (self.refresh_state) {
                .normal => assets.light.refresh_normal,
                .hover => assets.light.refresh_hover,
                .active => assets.light.refresh_active,
                .disabled, .loading => assets.light.refresh_loading,
            },
        };
    }

    /// Get the appropriate close button image for current state
    pub fn getCloseImage(self: *const UIState) []const u8 {
        return switch (self.theme) {
            .dark => switch (self.close_state) {
                .normal => assets.dark.close_normal,
                .hover => assets.dark.close_hover,
                .active => assets.dark.close_active,
                .disabled, .loading => assets.dark.close_normal,
            },
            .light => switch (self.close_state) {
                .normal => assets.light.close_normal,
                .hover => assets.light.close_hover,
                .active => assets.light.close_active,
                .disabled, .loading => assets.light.close_normal,
            },
        };
    }

    /// Get tab bar background image
    pub fn getTabbarImage(self: *const UIState) []const u8 {
        return switch (self.theme) {
            .dark => assets.dark.tabbar_normal,
            .light => assets.light.tabbar_normal,
        };
    }

    /// Get status bar background image
    pub fn getStatusbarImage(self: *const UIState) []const u8 {
        return switch (self.theme) {
            .dark => assets.dark.statusbar_normal,
            .light => assets.light.statusbar_normal,
        };
    }

    /// Mark all UI elements as dirty (need redraw)
    pub fn markAllDirty(self: *UIState) void {
        self.back_dirty = true;
        self.forward_dirty = true;
        self.refresh_dirty = true;
        self.close_dirty = true;
        self.tabbar_dirty = true;
        self.statusbar_dirty = true;
    }

    /// Clear all dirty flags
    pub fn clearDirty(self: *UIState) void {
        self.back_dirty = false;
        self.forward_dirty = false;
        self.refresh_dirty = false;
        self.close_dirty = false;
        self.tabbar_dirty = false;
        self.statusbar_dirty = false;
    }
};
