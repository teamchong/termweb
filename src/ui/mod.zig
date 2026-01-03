//! Browser UI module for layered rendering
//!
//! Provides:
//! - Embedded PNG assets for UI chrome
//! - Layout constants for positioning
//! - State management for button interactions

pub const assets = @import("assets.zig");
pub const layout = @import("layout.zig");
pub const state = @import("state.zig");

// Re-export commonly used types
pub const Theme = assets.Theme;
pub const Placement = layout.Placement;
pub const ZIndex = layout.ZIndex;
pub const Dimensions = layout.Dimensions;
pub const ButtonState = state.ButtonState;
pub const UIState = state.UIState;
