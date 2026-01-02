# termweb

Web browser in your terminal using Kitty graphics protocol.

## Overview

`termweb` renders web pages via Chrome DevTools Protocol and displays them inside Kitty-graphics-capable terminals (Ghostty, Kitty, WezTerm) using pixel frames.

## Features

- 🖼️ **Full Web Rendering** - Display complete web pages with images, CSS, and JavaScript
- ⌨️ **Vim-Style Navigation** - Scroll with j/k, d/u for half-page, Page Up/Down for full page
- 🔗 **Interactive Forms** - Fill text inputs, click links, toggle checkboxes, submit buttons
- 🌐 **URL Navigation** - Press 'g' to enter URLs directly, navigate back/forward through history
- 📱 **Mobile Testing** - Use `--mobile` flag for mobile viewport testing
- 🔍 **Zoom Control** - Adjust page scale with `--scale` option
- 🖱️ **Tab Navigation** - Press 'f' to enter form mode, Tab through interactive elements
- 🔄 **Page Refresh** - 'r' for screenshot refresh, 'R' for full page reload

## Status

**Current version:** 0.6.0 (M5 - Packaging + Documentation)

### Milestones

- ✅ **M0** - Project skeleton (0.1)
  - CLI commands: `open`, `doctor`, `version`, `help`
  - Build system with Zig
  - Terminal capability detection

- ✅ **M1** - Static render viewer (0.2)
  - Chrome/Chromium integration via CDP
  - Screenshot capture and display
  - Kitty graphics protocol
  - Basic key controls (q, r)

- ✅ **M2** - WebSocket CDP + Navigation (0.3)
  - Real-time WebSocket CDP connection
  - Page navigation (back, forward)
  - Persistent browser sessions

- ✅ **M3** - Scroll support (0.4)
  - Vim-style scrolling (j/k, d/u)
  - Arrow key and Page Up/Down scrolling
  - Page reload (r/R)

- ✅ **M4** - Interactive inputs (0.5)
  - URL navigation prompt (g key)
  - Form mode with DOM querying (f key)
  - Full form interaction (text inputs, checkboxes, buttons)
  - Tab navigation between elements

- ⏳ **M5** - Packaging + docs (0.6)
  - Comprehensive documentation suite
  - Installation and usage guides
  - Architecture documentation
  - Git tags and release process

## Documentation

- [Installation Guide](INSTALLATION.md) - Setup instructions and dependencies
- [Keyboard Controls](KEYBINDINGS.md) - Complete keybindings reference
- [Usage Guide](USAGE.md) - Detailed usage examples and workflows
- [Architecture](ARCHITECTURE.md) - System design and module overview
- [Contributing](CONTRIBUTING.md) - Development setup and guidelines
- [Troubleshooting](TROUBLESHOOTING.md) - Common issues and solutions
- [Changelog](CHANGELOG.md) - Version history and release notes

## Requirements

### Supported Terminals
- [Ghostty](https://ghostty.org/)
- [Kitty](https://sw.kovidgoyal.net/kitty/)
- [WezTerm](https://wezfurlong.org/wezterm/)

### System Requirements
- Zig 0.15.2+
- Node.js (for Playwright) - coming in M1
- Truecolor terminal support

## Building

```bash
zig build
```

## Usage

```bash
# Check system capabilities
termweb doctor

# Show version
termweb --version

# Open a URL (not yet implemented)
termweb open https://example.com
termweb open https://example.com --mobile
termweb open https://example.com --scale 0.8
```

## Development

```bash
# Build and run
zig build run -- doctor

# Run tests
zig build test
```

## License

MIT
