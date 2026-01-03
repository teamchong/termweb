//! UI layout constants for layered rendering
//!
//! Kitty graphics uses placement IDs to identify and update images.
//! Z-index controls layer ordering (negative = behind text, positive = in front).

/// Placement ID constants for UI elements
pub const Placement = struct {
    /// Main web page content (z=0)
    pub const CONTENT: u32 = 1;

    /// Tab bar background (z=5)
    pub const TABBAR: u32 = 2;

    /// Status bar background (z=5)
    pub const STATUSBAR: u32 = 3;

    /// Navigation buttons (z=10)
    pub const BUTTON_BACK: u32 = 10;
    pub const BUTTON_FORWARD: u32 = 11;
    pub const BUTTON_REFRESH: u32 = 12;
    pub const BUTTON_CLOSE: u32 = 13;

    /// Mouse cursor (z=20)
    pub const CURSOR: u32 = 50;

    /// Overlays: help, dialogs, prompts (z=100)
    pub const OVERLAY: u32 = 100;
};

/// Z-index layers
pub const ZIndex = struct {
    /// Web page content (behind UI chrome)
    pub const CONTENT: i32 = 0;

    /// UI chrome background (tab bar, status bar)
    pub const CHROME_BG: i32 = 5;

    /// UI chrome foreground (buttons)
    pub const CHROME_FG: i32 = 10;

    /// Mouse cursor (above content, below overlays)
    pub const CURSOR: i32 = 20;

    /// Modal overlays (help, dialogs)
    pub const OVERLAY: i32 = 100;
};

/// UI dimensions (in terminal rows/columns)
pub const Dimensions = struct {
    /// Tab bar height in rows
    pub const TABBAR_ROWS: u32 = 1;

    /// Status bar height in rows
    pub const STATUSBAR_ROWS: u32 = 1;

    /// Button dimensions in pixels
    pub const BUTTON_SIZE: u32 = 32;

    /// Button spacing in pixels
    pub const BUTTON_GAP: u32 = 4;

    /// Tab bar padding in pixels
    pub const TABBAR_PADDING: u32 = 8;
};
