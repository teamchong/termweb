/// Viewer module - terminal-based web browser viewer.
///
/// This module implements the interactive browser session with a mode-based state machine.
/// It handles keyboard/mouse input, screenshot rendering, and user interaction modes.
///
/// Sub-modules:
/// - helpers: Utility functions (parsing, MIME types, etc.)
/// - fs_handler: File System Access API handlers
/// - render: Screencast and rendering functions
/// - input_handler: Keyboard input handling
/// - mouse_handler: Mouse event handling
/// - cdp_events: CDP event handling

pub const helpers = @import("helpers.zig");
pub const fs_handler = @import("fs_handler.zig");

// Re-export commonly used types
pub const getMimeType = helpers.getMimeType;
pub const base64Decode = helpers.base64Decode;
pub const isPathAllowed = fs_handler.isPathAllowed;
pub const envVarTruthy = helpers.envVarTruthy;
pub const isGhosttyTerminal = helpers.isGhosttyTerminal;
pub const isNaturalScrollEnabled = helpers.isNaturalScrollEnabled;
pub const parseDialogType = helpers.parseDialogType;
pub const parseDialogMessage = helpers.parseDialogMessage;
pub const parseDefaultPrompt = helpers.parseDefaultPrompt;
pub const parseFileChooserMode = helpers.parseFileChooserMode;
pub const extractUrlFromNavEvent = helpers.extractUrlFromNavEvent;
