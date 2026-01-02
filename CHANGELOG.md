# Changelog

All notable changes to termweb will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.6.0] - 2024-01-02 - M5 Packaging + Documentation

### Added
- Comprehensive documentation suite
  - `INSTALLATION.md` - Installation guide with platform-specific instructions
  - `KEYBINDINGS.md` - Complete keyboard controls reference for all modes
  - `USAGE.md` - Detailed usage guide with workflows and examples
  - `ARCHITECTURE.md` - System architecture and module documentation
  - `CONTRIBUTING.md` - Contribution guidelines and development workflow
  - `TROUBLESHOOTING.md` - Common issues and solutions guide
  - `CHANGELOG.md` - Version history (this file)
- README enhancements
  - Features section highlighting all capabilities
  - Documentation section with links to all guides
  - Updated milestone status showing M1-M4 complete
- Git tags for historical releases (v0.1.0 through v0.5.0)
- Version management strategy documented in CONTRIBUTING.md

### Changed
- Updated version from 0.1.0 to 0.6.0 in src/cli.zig
- Updated README to reflect current status (M5 in progress)
- Improved README overview to mention Chrome DevTools Protocol (not Playwright)

## [0.5.0] - 2024-01-02 - M4 Interactive Inputs

### Added
- **Phase 1: URL Navigation Prompt**
  - Press 'g' or 'G' to enter URL prompt mode
  - Text input buffer for typing URLs
  - URL navigation without restarting termweb
  - Status bar shows URL entry interface
- **Phase 2: Form Mode Foundation**
  - Press 'f' to enter form mode
  - DOM querying via JavaScript injection (`Runtime.evaluate`)
  - Interactive element detection (links, buttons, inputs, textareas, selects)
  - Tab navigation between elements
  - Status bar shows current element (type, text, index)
  - Link clicking functionality
- **Phase 3: Text Input Mode**
  - Text input mode activated from form mode
  - Type into text fields and password fields
  - Submit text with Enter key
  - Text insertion via CDP `Input.insertText`
  - Keyboard event simulation (Enter key press)
- **Phase 4: All Input Types**
  - Checkbox toggling via JavaScript click
  - Radio button support
  - Textarea support (multi-line text input)
  - Select dropdown activation
  - Submit button clicking
  - Complete form interaction workflow
- New modules:
  - `src/terminal/prompt.zig` - Text input buffer (43 lines)
  - `src/chrome/dom.zig` - DOM querying and form context (168 lines)
  - `src/chrome/interact.zig` - Element interaction actions (121 lines)
- ViewerMode enum with four states (Normal, URL Prompt, Form, Text Input)
- FormContext for managing element selection and navigation
- InteractiveElement struct with position, type, and selector information

### Changed
- `src/viewer.zig` - Refactored from single handleKey() to mode-specific handlers (428 lines total)
- Status bar now shows mode-specific information and hints
- Removed 'f' keybinding for forward navigation (conflicts with form mode)

### Fixed
- ArrayList API compatibility with Zig 0.15.2 (use initCapacity with allocator)

## [0.4.0] - 2024-01-01 - M3 Navigation Basics

### Added
- Browser history navigation
  - 'b' key - Navigate back in history
  - Left Arrow - Navigate back
  - Right Arrow - Navigate forward
- Page reload functionality
  - 'r' key - Refresh screenshot (fast, no network request)
  - 'R' key - Hard reload from server (clears cache)
- URL prompting groundwork (completed in M4)
- Keyboard shortcuts for history in status bar

### Changed
- Updated status bar to show navigation commands
- Improved navigation API in screenshot.zig

## [0.3.0] - 2024-01-01 - M2 Scroll + Persistent Page

### Added
- **Real WebSocket CDP Connection**
  - `src/chrome/websocket_cdp.zig` - WebSocket client implementation (305 lines)
  - HTTP → WebSocket upgrade handshake
  - Frame parsing (text, binary, close frames)
  - Message fragmentation handling
  - Persistent browser sessions
- **Scroll Support**
  - `src/chrome/scroll.zig` - Scroll control via CDP (102 lines)
  - Vim-style scrolling: 'j' (down), 'k' (up)
  - Half-page scrolling: 'd' (down), 'u' (up)
  - Arrow key scrolling: Up/Down arrows
  - Page Up/Page Down for full-page scrolling
  - Scroll emulation via `Input.dispatchMouseEvent` (mouse wheel)
- **Viewport Size Detection**
  - Terminal size detection via TIOCGWINSZ ioctl
  - Pixel dimensions (width_px, height_px)
  - Scroll calculations based on viewport height

### Changed
- Switched from HTTP CDP to WebSocket CDP for real-time communication
- Updated CdpClient to use WebSocket instead of HTTP
- Screenshot capture now works with persistent sessions
- Status bar shows scroll keybindings

### Fixed
- Page persistence (pages no longer close after each command)
- Improved screenshot capture performance with WebSocket

## [0.2.0] - 2024-01-01 - M1 Static Render Viewer

### Added
- **Chrome/Chromium Integration**
  - `src/chrome/detector.zig` - Chrome binary detection (89 lines)
  - `src/chrome/launcher.zig` - Chrome process management (153 lines)
  - Platform-specific Chrome paths (macOS, Linux)
  - `CHROME_BIN` environment variable support
  - Headless Chrome launch with `--remote-debugging-port=9222`
- **Chrome DevTools Protocol (CDP)**
  - `src/chrome/cdp_client.zig` - CDP client wrapper (156 lines)
  - HTTP-based CDP commands (later replaced with WebSocket in M2)
  - Message ID tracking
  - Command/response synchronization
- **Screenshot Capture**
  - `src/chrome/screenshot.zig` - Screenshot API (133 lines)
  - `Page.captureScreenshot` command
  - Base64 PNG encoding/decoding
  - Initial navigation (`Page.navigate`)
  - 3-second page load wait (hard-coded delay)
- **Kitty Graphics Protocol**
  - `src/terminal/kitty_graphics.zig` - Kitty protocol implementation (81 lines)
  - Base64 PNG encoding for escape sequences
  - Image placement and sizing
  - Clear images command
- **Keyboard Controls**
  - 'q' or 'Q' - Quit
  - 'r' - Refresh screenshot
  - Ctrl+C - Force quit
  - Esc - Quit
- **Viewer Event Loop**
  - `src/viewer.zig` - Main event loop (initially ~200 lines)
  - Non-blocking keyboard input
  - Screenshot refresh on key press
  - Status bar with keybinding hints
- Viewport size configuration (width, height)
- Terminal size detection with pixel dimensions

### Changed
- Updated CLI to support `open` command with URL parameter
- Added `--mobile` and `--scale` flags (parsed but not fully functional yet)

## [0.1.0] - 2024-01-01 - M0 Project Skeleton

### Added
- **Project Structure**
  - Zig build system (`build.zig`)
  - Source directory structure (`src/`)
  - MIT License
  - Basic README.md
- **CLI Framework**
  - `src/main.zig` - Entry point
  - `src/cli.zig` - Command-line interface (252 lines)
  - Command parsing and dispatch
  - Help text rendering
- **Commands Implemented**
  - `open <url>` - Open URL (skeleton, implemented in M1)
  - `doctor` - System capability check
  - `version` - Show version number
  - `help` - Display help text
- **Doctor Command Features**
  - Terminal type detection (`$TERM`, `$TERM_PROGRAM`)
  - Kitty graphics protocol detection
  - Truecolor support detection (`$COLORTERM`)
  - Chrome/Chromium binary detection
  - Overall system readiness check
- **Terminal Support Detection**
  - Ghostty detection
  - Kitty detection
  - WezTerm detection
  - Environment variable checks
- **Terminal I/O Modules**
  - `src/terminal/terminal.zig` - Terminal control (80 lines)
  - `src/terminal/screen.zig` - Screen manipulation (25 lines)
  - `src/terminal/input.zig` - Keyboard input (71 lines)
  - Raw terminal mode setup
  - Terminal size detection (rows, cols, width_px, height_px)
  - Non-blocking input reading
  - ANSI escape sequence parsing
- **Vendor Dependencies**
  - `vendor/json/` - JSON parsing library
  - `vendor/websocket/` - WebSocket client (used in M2)

[Unreleased]: https://github.com/yourusername/termweb/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/yourusername/termweb/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/yourusername/termweb/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/yourusername/termweb/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/yourusername/termweb/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/yourusername/termweb/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/yourusername/termweb/releases/tag/v0.1.0
