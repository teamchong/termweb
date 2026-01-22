//! UI state management for browser chrome
//!
//! Tracks button states for the notcurses-based toolbar.

const std = @import("std");
const assets = @import("assets.zig");

/// Represents a browser tab
pub const Tab = struct {
    target_id: []const u8,
    url: []const u8,
    title: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, target_id: []const u8, url: []const u8, title: []const u8) !Tab {
        return .{
            .target_id = try allocator.dupe(u8, target_id),
            .url = try allocator.dupe(u8, url),
            .title = try allocator.dupe(u8, title),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Tab) void {
        self.allocator.free(self.target_id);
        self.allocator.free(self.url);
        self.allocator.free(self.title);
    }

    pub fn updateUrl(self: *Tab, new_url: []const u8) !void {
        self.allocator.free(self.url);
        self.url = try self.allocator.dupe(u8, new_url);
    }

    pub fn updateTitle(self: *Tab, new_title: []const u8) !void {
        self.allocator.free(self.title);
        self.title = try self.allocator.dupe(u8, new_title);
    }
};

pub const ButtonState = enum {
    normal,
    hover,
    active,
    disabled,
    loading, // Only for refresh button
};

pub const HoverItem = enum {
    none,
    back,
    forward,
    refresh,
    close,
    address_bar,
};

pub const UIState = struct {
    // Navigation button states
    back_state: ButtonState = .normal,
    forward_state: ButtonState = .normal,
    refresh_state: ButtonState = .normal,
    close_state: ButtonState = .normal,

    // Interaction state
    hover_item: HoverItem = .none,

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
