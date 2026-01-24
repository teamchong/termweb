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

pub const helpers = @import("helpers.zig");
pub const fs_handler = @import("fs_handler.zig");
pub const render = @import("render.zig");
pub const input_handler = @import("input_handler.zig");
pub const mouse_handler = @import("mouse_handler.zig");
pub const cdp_events = @import("cdp_events.zig");
pub const tabs = @import("tabs.zig");

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

// Re-export render functions
pub const tryRenderScreencast = render.tryRenderScreencast;
pub const displayFrame = render.displayFrame;
pub const displayFrameWithDimensions = render.displayFrameWithDimensions;
pub const renderCursor = render.renderCursor;
pub const renderToolbar = render.renderToolbar;
pub const getMaxFpsForResolution = render.getMaxFpsForResolution;
pub const getMinFrameInterval = render.getMinFrameInterval;

// Re-export input handler functions
pub const handleInput = input_handler.handleInput;
pub const executeAppAction = input_handler.executeAppAction;
pub const handleNormalModeKey = input_handler.handleNormalModeKey;
pub const handleUrlPromptKey = input_handler.handleUrlPromptKey;

// Re-export mouse handler functions
pub const handleMouse = mouse_handler.handleMouse;
pub const handleMouseNormal = mouse_handler.handleMouseNormal;
pub const handleTabBarClick = mouse_handler.handleTabBarClick;
pub const mouseToPixels = mouse_handler.mouseToPixels;

// Re-export CDP event handler functions
pub const handleCdpEvent = cdp_events.handleCdpEvent;
pub const handleFrameNavigated = cdp_events.handleFrameNavigated;
pub const handleNavigatedWithinDocument = cdp_events.handleNavigatedWithinDocument;
pub const handleNewTarget = cdp_events.handleNewTarget;
pub const handleTargetInfoChanged = cdp_events.handleTargetInfoChanged;
pub const handleDownloadWillBegin = cdp_events.handleDownloadWillBegin;
pub const handleDownloadProgress = cdp_events.handleDownloadProgress;
pub const handleConsoleMessage = cdp_events.handleConsoleMessage;
pub const showFileChooser = cdp_events.showFileChooser;

// Re-export tab management functions
pub const addTab = tabs.addTab;
pub const showTabPicker = tabs.showTabPicker;
pub const switchToTab = tabs.switchToTab;
pub const launchInNewTerminal = tabs.launchInNewTerminal;
