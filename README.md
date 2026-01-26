# termweb

Web browser in your terminal using Kitty graphics protocol.

## Overview

`termweb` renders web pages via Chrome DevTools Protocol and displays them inside Kitty-graphics-capable terminals (Ghostty, Kitty, WezTerm) using real-time pixel screencasts.

## Demo: CLI - browsing the web in terminal

https://github.com/user-attachments/assets/70b86b29-19b4-458b-8d5d-683f5e139908


## Demo: SDK: building apps with termweb as render engine

https://github.com/user-attachments/assets/12183bb7-de8b-4e44-b884-216e304ab8ce

## Features

- **Real-time Screencast** - Live page rendering with smooth updates
- **Mouse Support** - Click links, buttons, and interact directly with the page
- **Clickable Toolbar** - Navigation buttons (back, forward, reload) and tab management
- **Tab Management** - Multiple tabs with native OS dialog picker (Cmd+click or Tab button)
- **Clipboard Integration** - Ctrl+C/X/V for copy/cut/paste (uses system clipboard)
- **URL Navigation** - Press Ctrl+L to focus address bar
- **Hint Mode** - Vimium-style keyboard navigation (Ctrl+H)

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

# Clone Chrome profile (use existing logins, extensions, settings)
termweb open https://example.com --profile Default

# App mode (hide navigation bar)
termweb open https://example.com --no-toolbar

# SSH-optimized (lower frame rate)
termweb open https://example.com --fps 12

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
  toolbar: false,   // Hide navigation toolbar
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

> **Note:** All shortcuts use `Ctrl` on both macOS and Linux

| Key | Action |
|-----|--------|
| `Ctrl+Q` | Quit |
| `Ctrl+L` | Focus address bar |
| `Ctrl+R` | Reload page |
| `Ctrl+[` | Go back |
| `Ctrl+]` | Go forward |
| `Ctrl+.` | Stop loading |
| `Ctrl+N` | New tab (about:blank) |
| `Ctrl+W` | Close tab (quit if last tab) |
| `Ctrl+T` | Show tab picker |
| `Ctrl+C` | Copy selection |
| `Ctrl+X` | Cut selection |
| `Ctrl+V` | Paste |
| `Ctrl+A` | Select all |
| `Ctrl+H` | Hint mode (Vimium-style click navigation) |
| `Ctrl+J` | Scroll down |
| `Ctrl+K` | Scroll up |

### Hint Mode (Vimium-style)

Press `Ctrl+H` to enter hint mode. Yellow labels appear on all clickable elements (links, buttons, inputs). Type the label letters to click that element. Press `Escape` to cancel.

- Labels are sequential: a-z, then aa-zz, then aaa-zzz
- Type partial labels to filter visible hints
- After 300ms pause with an exact match, auto-clicks

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
