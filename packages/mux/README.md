# termweb-mux

A high-performance terminal multiplexer for the web, powered by [Ghostty](https://ghostty.org)'s libghostty rendering engine compiled to WebAssembly.

## Features

- **Native Terminal Rendering**: Uses libghostty (Ghostty's core) compiled to WASM for pixel-perfect terminal emulation
- **GPU Acceleration**: WebGPU-based rendering with proper font atlas and ligature support
- **Tab Management**: Multiple tabs with LRU (last recently used) switching on close
- **Split Panes**: Horizontal/vertical splits with draggable dividers
- **Mouse Support**: Full mouse tracking (hover, click, scroll, drag)
- **Keyboard Shortcuts**: macOS-native shortcuts (Cmd+T, Cmd+W, Cmd+1-9, etc.)
- **Per-Panel Inspector**: Alt+Cmd+I to inspect terminal state (dimensions, cell info)
- **Shell Integration**: pwd tracking, running command indicators in tabs/titlebar
- **Binary Protocol**: Efficient binary WebSocket protocol for terminal I/O

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Browser (client.js)                     │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐                      │
│  │  Tab 1  │  │  Tab 2  │  │  Tab 3  │  ← Tab bar           │
│  └────┬────┘  └─────────┘  └─────────┘                      │
│       │                                                      │
│  ┌────┴────────────────────────────────┐                    │
│  │ Panel (canvas + WebSocket)          │                    │
│  │  ┌────────────────────────────────┐ │                    │
│  │  │     WebGPU Terminal Canvas     │ │                    │
│  │  │   (rendered by libghostty)     │ │                    │
│  │  └────────────────────────────────┘ │                    │
│  │  [Inspector: dimensions, cell info] │ ← Alt+Cmd+I        │
│  └─────────────────────────────────────┘                    │
└─────────────────────────────────────────────────────────────┘
                           │
                    WebSocket (binary)
                           │
┌─────────────────────────────────────────────────────────────┐
│                    Server (main.zig)                         │
│  ┌─────────────────────────────────────────────────────┐    │
│  │                 libghostty (C API)                   │    │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐              │    │
│  │  │ Surface │  │ Surface │  │ Surface │  ← Terminals │    │
│  │  └────┬────┘  └─────────┘  └─────────┘              │    │
│  │       │                                              │    │
│  │       ↓                                              │    │
│  │  ┌─────────┐                                         │    │
│  │  │   PTY   │  ← /bin/zsh or $SHELL                  │    │
│  │  └─────────┘                                         │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

## Building

Requires Zig 0.14.0+ and a C compiler for libghostty:

```bash
cd packages/mux
zig build
```

Release build:
```bash
zig build -Doptimize=ReleaseFast
```

## Running

```bash
./zig-out/bin/termweb
```

Then open `http://localhost:7681` in a WebGPU-capable browser (Chrome 113+, Edge 113+, or Firefox Nightly).

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Cmd+T | New tab |
| Cmd+W | Close tab/panel |
| Cmd+1-9 | Switch to tab N |
| Cmd+Shift+] | Next tab |
| Cmd+Shift+[ | Previous tab |
| Cmd+D | Split horizontally |
| Cmd+Shift+D | Split vertically |
| Cmd+Option+Arrow | Move focus between splits |
| Alt+Cmd+I | Toggle inspector |
| Cmd+K | Clear terminal |
| Cmd+, | Open command palette |

## Protocol

### Control WebSocket (JSON)

Used for session management:

```javascript
// Create panel
{ type: 'create_panel' }

// Close panel
{ type: 'close_panel', panel_id: 1 }

// Resize panel
{ type: 'resize_panel', panel_id: 1, width: 800, height: 600 }

// Focus panel
{ type: 'focus_panel', panel_id: 1 }
```

### Panel WebSocket (Binary)

Each panel has a dedicated binary WebSocket for terminal I/O:

**Client → Server:**
- Keyboard input (raw bytes)
- Mouse events (binary: x, y, modifiers, button)

**Server → Client:**
- Frame data (GPU texture updates)
- Cursor position
- Title/pwd updates
- Size changes

## Inspector

Press Alt+Cmd+I to toggle the per-panel inspector. Currently shows:

- **Surface Info**: Grid dimensions, cell size, screen size
- **Terminal IO**: (placeholder for VT sequence logging)

The inspector uses WebSocket push updates (no polling).

## Dependencies

- [Ghostty](https://github.com/ghostty-org/ghostty) - Terminal emulation core (vendored)
- Zig 0.14.0+ - Build system and native code

## License

MIT
