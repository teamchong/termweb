//! Browser UI module for layered rendering
//!
//! Provides:
//! - Embedded PNG assets for UI chrome
//! - Layout constants for positioning
//! - State management for button interactions
//! - Toolbar rendering via Kitty graphics
//! - Dialog handling for JavaScript alerts/confirms/prompts

pub const assets = @import("assets.zig");
pub const layout = @import("layout.zig");
pub const state = @import("state.zig");
pub const toolbar = @import("toolbar.zig");
pub const svg = @import("svg.zig");
pub const font = @import("font.zig");
pub const dialog = @import("dialog.zig");
pub const hints = @import("hints.zig");

// Re-export commonly used types
pub const Theme = assets.Theme;
pub const Placement = layout.Placement;
pub const ImageId = layout.ImageId;
pub const ZIndex = layout.ZIndex;
pub const Dimensions = layout.Dimensions;
pub const ButtonState = state.ButtonState;
pub const UIState = state.UIState;
pub const Tab = state.Tab;
pub const ToolbarRenderer = toolbar.ToolbarRenderer;
pub const DialogType = dialog.DialogType;
pub const DialogState = dialog.DialogState;
pub const FilePickerMode = dialog.FilePickerMode;
pub const HintGrid = hints.HintGrid;
pub const Hint = hints.Hint;
pub const renderHints = hints.renderHints;
