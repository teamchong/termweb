# termweb-mux

A high-performance terminal multiplexer for the web, powered by [Ghostty](https://ghostty.org)'s libghostty rendering engine with H.264 video streaming.

## Features

- **Cross-Platform**: macOS (VideoToolbox) and Linux (VA-API hardware H.264)
- **H.264 Video Streaming**: libghostty renders to GPU surface, encoded to H.264, WebCodecs decodes in browser
- **Low Latency**: Direct WebCodecs decoding to canvas (no MSE buffering)
- **Tab Management**: Multiple tabs with LRU (last recently used) switching on close
- **Split Panes**: Horizontal/vertical splits with draggable dividers, zoom split to maximize active panel
- **Mouse Support**: Full mouse tracking (hover, click, scroll, drag)
- **Keyboard Shortcuts**: macOS-native shortcuts (Cmd+T, Cmd+W, Cmd+1-9, etc.)
- **Per-Panel Inspector**: Alt+Cmd+I to inspect terminal state (dimensions, cell info)
- **Shell Integration**: pwd tracking, running command indicators in tabs/titlebar
- **File Transfer**: Upload/download files with rsync-like options (exclude patterns, delete extra, preview)
- **Access Control**: Session management, share links, viewer/editor roles
- **Full Screen Mode**: Hide title/tab bar for maximum terminal space (Cmd+Shift+F)

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Browser (client.js)                      │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐                      │
│  │  Tab 1  │  │  Tab 2  │  │  Tab 3  │  ← Tab bar           │
│  └────┬────┘  └─────────┘  └─────────┘                      │
│       │                                                     │
│  ┌────┴────────────────────────────────┐                    │
│  │ Panel (canvas + WebSocket)          │                    │
│  │  ┌────────────────────────────────┐ │                    │
│  │  │   WebCodecs H.264 → Canvas     │ │                    │
│  │  └────────────────────────────────┘ │                    │
│  │  [Inspector: cols, rows, cell size] │ ← Alt+Cmd+I        │
│  └─────────────────────────────────────┘                    │
└─────────────────────────────────────────────────────────────┘
                      │ WebSocket
                      ↓
┌─────────────────────────────────────────────────────────────┐
│                    Server (main.zig)                        │
│                                                             │
│  macOS:  libghostty → IOSurface → VideoToolbox (H.264)      │
│  Linux:  libghostty → EGL → VA-API (H.264)                  │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## Building

### Server (Zig)

Requires Zig 0.14.0+ (0.15.0 recommended):

```bash
cd packages/mux/native
zig build
```

Release build:
```bash
zig build -Doptimize=ReleaseFast
```

### Web Client (TypeScript)

Requires pnpm and Bun:

```bash
cd packages/mux/web
pnpm install
pnpm build
```

## Running

```bash
./zig-out/bin/termweb-mux
```

Then open `http://localhost:8080` in a browser with WebCodecs support (Chrome 94+, Edge 94+).

## Menus

### File Menu
- New Tab (⌘/)
- Upload... (⌘U)
- Download... (⌘⇧S)
- Split Right/Down/Left/Up (⌘D, ⌘⇧D)
- Close Tab (⌘.)

### Edit Menu
- Copy (⌘C)
- Paste (⌘V)
- Paste Selection (⌘⇧V)
- Select All (⌘A)

### View Menu
- Show All Tabs (⌘⇧A)
- Increase/Decrease/Reset Font (⌘=, ⌘-, ⌘0)
- Command Palette (⌘⇧P)
- Quick Terminal
- Toggle Inspector (⌥⌘I)

### Window Menu
- Toggle Full Screen (⌘⇧F) - Hide title/tab bar
- Show Previous/Next Tab (⌃⇧Tab, ⌃Tab)
- Zoom Split (⌘⇧↵) - Maximize active panel
- Select Previous/Next Split (⌘[, ⌘])
- Select Split (⌘⇧↑↓←→)
- Resize Split (equalize, move dividers)
- Tab list (⌘1-9)

## Protocol

### Control WebSocket (Port 8081)

Mixed JSON and binary messages for session management:

```javascript
// Create panel
{ type: 'create_panel' }

// Close panel (binary: 0x81 + panel_id)
// Resize panel (binary: 0x82 + panel_id + width + height)
// Focus panel (binary: 0x83 + panel_id)
```

### Panel WebSocket (Port 8080)

Binary protocol for terminal I/O:

**Client → Server:**
- `0x01` KEY_INPUT: keycode, modifiers
- `0x02` MOUSE_INPUT: button, x, y, modifiers
- `0x03` MOUSE_MOVE: x, y
- `0x04` MOUSE_SCROLL: delta_x, delta_y
- `0x05` TEXT_INPUT: UTF-8 text
- `0x10` RESIZE: width, height
- `0x11` REQUEST_KEYFRAME

**Server → Client:**
- `0x01` KEYFRAME: H.264 IDR frame
- `0x02` DELTA: H.264 P-frame
- Title/pwd updates (JSON)
- Bell notification

## Inspector

Press Alt+Cmd+I to toggle the per-panel inspector showing:

- **Terminal Size**: Columns × Rows
- **Screen Size**: Width × Height in pixels
- **Cell Size**: Cell width × height in pixels

The inspector uses WebSocket push updates (no polling).

## File Transfer

Upload and download files with rsync-like features:

- **Exclude patterns**: Skip files matching patterns (e.g., `node_modules,.git`)
- **Delete extra**: Remove files on destination not in source
- **Preview**: Dry-run to see changes before applying

## Debug Mode

Add `#debug` or `?debug=1` to URL to show FPS/latency overlay in bottom-right corner.

## Dependencies

### All Platforms
- [Ghostty](https://github.com/ghostty-org/ghostty) - Terminal emulation core (vendored)
- Zig 0.14.0+ (0.15.0 recommended) - Server and native code
- Bun - TypeScript bundling

### macOS
- VideoToolbox - H.264 hardware encoding
- IOSurface - GPU buffer for rendering
- Metal - GPU rendering

### Linux (Ubuntu/Debian)

**Required system packages:**

```bash
# VA-API for hardware H.264 encoding (Intel/AMD GPUs)
sudo apt-get install libva-dev

# Intel GPU driver (if using Intel graphics)
sudo apt-get install intel-media-va-driver
```

The vendored static libraries in `vendor/libs/` include:
- fontconfig, freetype, harfbuzz (font rendering)
- oniguruma (regex for highlighting)
- glslang, spirv-cross (shader compilation)
- simdutf, highway (SIMD acceleration)
- dcimgui (inspector UI)
- libpng, libz, libxml2 (supporting libraries)

Build with Zig:

```bash
zig build
```

## License

MIT
