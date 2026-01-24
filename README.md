# termweb

Web browser in your terminal using Kitty graphics protocol.

## Overview

`termweb` renders web pages via Chrome DevTools Protocol and displays them inside Kitty-graphics-capable terminals (Ghostty, Kitty, WezTerm) using real-time pixel screencasts.

## Demo: CLI - browsing the web in terminal

https://github.com/user-attachments/assets/f2782ae1-831e-4153-8c54-60dfd5942ab8

## Demo: SDK: building apps with termweb as render engine

https://github.com/user-attachments/assets/806cac11-3348-48b7-95a0-0c98fd61c873


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
- Chrome or Chromium browser
- macOS or Linux

## Installation

### Using npm (recommended)

```bash
# Run directly with npx
npx termweb@latest open https://example.com

# Or install globally
npm install -g termweb
termweb open https://example.com
```

### Building from source

```bash
# Requires Zig 0.15.2+
git clone https://github.com/teamchong/termweb
cd termweb
zig build
./zig-out/bin/termweb open https://example.com
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

## SDK Usage

Use termweb as a library in your Node.js applications:

```javascript
const termweb = require('termweb');

// Open a URL
termweb.open('https://example.com');

// With options
termweb.open('https://vscode.dev', {
  mobile: false,    // Mobile viewport
  toolbar: false,   // Hide navigation toolbar
  scale: 0.8,       // Page zoom
});

// Check availability
if (termweb.isAvailable()) {
  termweb.open('https://example.com');
}

// Load a Chrome extension
termweb.open('https://example.com', {
  extensionPath: '/path/to/unpacked/extension',
});
```

### Chrome Extensions

You can inject unpacked Chrome extensions to extend browser capabilities:

```javascript
// Ad blocker extension
termweb.open('https://example.com', {
  extensionPath: '/path/to/ublock-origin',
});

// Custom content scripts
termweb.open('https://myapp.com', {
  extensionPath: './extensions/custom-injector',
});
```

Extensions can provide:
- **Content Scripts** - Inject custom JS/CSS into pages
- **Ad Blocking** - Block ads and trackers
- **Authentication** - Auto-fill credentials or handle OAuth
- **Page Manipulation** - Modify DOM, intercept requests
- **Custom APIs** - Expose additional functionality to pages

> **Note:** termweb creates a temporary Chrome profile in `/tmp/termweb-profile-*` that is cleaned up on each launch. Extensions are loaded fresh each session via the `--load-extension` flag, so extension state (settings, data) does not persist between sessions.

## Controls

### Keyboard

> **Note:** On macOS use `Cmd`, on Linux use `Ctrl`

| Key | Action |
|-----|--------|
| `Cmd/Ctrl+Q` | Quit |
| `Cmd/Ctrl+L` | Focus address bar |
| `Cmd/Ctrl+R` | Reload page |
| `Cmd/Ctrl+[` | Go back |
| `Cmd/Ctrl+]` | Go forward |
| `Cmd/Ctrl+.` | Stop loading |
| `Cmd/Ctrl+T` | Show tab picker |
| `Cmd/Ctrl+C` | Copy selection |
| `Cmd/Ctrl+X` | Cut selection |
| `Cmd/Ctrl+V` | Paste |
| `Cmd/Ctrl+A` | Select all |

### Mouse
- **Click** - Interact with page elements (links, buttons, inputs)
- **Toolbar** - Click navigation buttons (back, forward, reload, tabs)
- **Tab Button** - Open tab picker to switch between tabs

### Tabs
- Links that open new windows are captured as tabs
- Click the tab button in toolbar (shows tab count)
- Native OS dialog appears to select tabs (AppleScript on macOS, zenity on Linux)

## Terminal Apps

Pre-built terminal applications powered by termweb:

### @termweb/code

Full-featured code editor with syntax highlighting for 20+ languages.

```bash
npx @termweb/code ./src/index.js
npx @termweb/code ~/projects/app/main.py
```

### @termweb/markdown

Markdown editor with live preview pane.

```bash
npx @termweb/markdown ./README.md
npx @termweb/markdown ~/docs/notes.md
```

### @termweb/json

JSON editor with validation, formatting, and key sorting.

```bash
npx @termweb/json ./package.json
npx @termweb/json ~/config/settings.json
```

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
