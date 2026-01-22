# termweb

Web browser in your terminal using Kitty graphics protocol.

## Overview

`termweb` renders web pages via Chrome DevTools Protocol and displays them inside Kitty-graphics-capable terminals (Ghostty, Kitty, WezTerm) using real-time pixel screencasts.

## Demo

https://github.com/user-attachments/assets/192411f7-ac5e-44b1-a09c-1d070ef85c3f


## Features

- **Real-time Screencast** - Live page rendering with smooth updates
- **Mouse Support** - Click links, buttons, and interact directly with the page
- **Clickable Toolbar** - Navigation buttons (back, forward, reload) and tab management
- **Tab Management** - Multiple tabs with native OS dialog picker (Cmd+click or Tab button)
- **Clipboard Integration** - Ctrl+C/X/V for copy/cut/paste (uses system clipboard)
- **URL Navigation** - Press Ctrl+L to focus address bar
- **Mobile Testing** - Use `--mobile` flag for mobile viewport
- **Zoom Control** - Adjust page scale with `--scale` option

## Requirements

### Supported Terminals
- [Ghostty](https://ghostty.org/) (Recommended)
- [Kitty](https://sw.kovidgoyal.net/kitty/)
- [WezTerm](https://wezfurlong.org/wezterm/)

### System Requirements
- Zig 0.15.2+
- Chrome or Chromium browser
- macOS or Linux

## Building

```bash
zig build
```

## Usage

```bash
# Open a URL
termweb open https://example.com

# Mobile viewport
termweb open https://example.com --mobile

# Custom zoom
termweb open https://example.com --scale 0.8

# Show help
termweb help
```

## Controls

### Keyboard
| Key | Action |
|-----|--------|
| `Ctrl+Q` / `Ctrl+W` | Quit |
| `Ctrl+L` | Focus address bar |
| `Ctrl+R` | Reload page |
| `Ctrl+T` | Show tab picker |
| `Ctrl+C` | Copy selection |
| `Ctrl+X` | Cut selection |
| `Ctrl+V` | Paste |
| `Ctrl+A` | Select all |

### Mouse
- **Click** - Interact with page elements (links, buttons, inputs)
- **Toolbar** - Click navigation buttons (back, forward, reload, tabs)
- **Tab Button** - Open tab picker to switch between tabs

### Tabs
- Links that open new windows are captured as tabs
- Click the tab button in toolbar (shows tab count)
- Native OS dialog appears to select tabs (AppleScript on macOS, zenity on Linux)

## Documentation

- [Installation Guide](INSTALLATION.md) - Setup instructions and dependencies
- [Contributing](CONTRIBUTING.md) - Development setup and guidelines
- [Troubleshooting](TROUBLESHOOTING.md) - Common issues and solutions
- [Changelog](CHANGELOG.md) - Version history

## Development

```bash
# Build
zig build

# Run tests
zig build test
```

## License

MIT
