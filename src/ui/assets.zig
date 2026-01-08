//! UI assets - minimal version for notcurses-based rendering
//!
//! The toolbar is now rendered using notcurses TUI library.
//! Only the cursor asset is embedded for mouse pointer rendering.

pub const Theme = enum {
    dark,
    light,
};

/// Mouse cursor (16x16 white arrow with black outline)
pub const cursor = @embedFile("assets/cursor.png");
