//! Browser UI module for layered rendering
//!
//! Provides:
//! - Embedded PNG assets for UI chrome
//! - Layout constants for positioning
//! - State management for button interactions
//! - Toolbar rendering via Kitty graphics

pub const assets = @import("assets.zig");
pub const layout = @import("layout.zig");
pub const state = @import("state.zig");
pub const toolbar = @import("toolbar.zig");
pub const svg = @import("svg.zig");
pub const font = @import("font.zig");

// Re-export commonly used types
pub const Theme = assets.Theme;
pub const Placement = layout.Placement;
pub const ZIndex = layout.ZIndex;
pub const Dimensions = layout.Dimensions;
pub const ButtonState = state.ButtonState;
pub const UIState = state.UIState;
pub const ToolbarRenderer = toolbar.ToolbarRenderer;
