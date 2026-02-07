# termweb

A next-generation terminal multiplexer for the web, powered by [Ghostty](https://ghostty.org)'s libghostty rendering engine with H.264 video streaming.

## Demo

https://github.com/user-attachments/assets/70b86b29-19b4-458b-8d5d-683f5e139908

## Features

- **Cross-Platform**: macOS (VideoToolbox) and Linux (VA-API hardware H.264)
- **H.264 Video Streaming**: libghostty renders to GPU, hardware-encoded H.264, WebCodecs decodes in browser
- **Low Latency**: Direct WebCodecs decoding to canvas (no MSE buffering)
- **Tab Management**: Multiple tabs with LRU switching on close
- **Split Panes**: Horizontal/vertical splits with draggable dividers, zoom to maximize
- **Mouse Support**: Full mouse tracking (hover, click, scroll, drag)
- **File Transfer**: Upload/download with rsync-like options (exclude, delete, preview)
- **Shell Integration**: pwd tracking, running command indicators
- **Scale to Zero**: Ghostty initializes on first panel, frees when last closes

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Browser (WebCodecs)                      │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐                      │
│  │  Tab 1  │  │  Tab 2  │  │  Tab 3  │  ← Tab bar           │
│  └────┬────┘  └─────────┘  └─────────┘                      │
│       │                                                     │
│  ┌────┴────────────────────────────────┐                    │
│  │ Panel: H.264 → WebCodecs → Canvas   │                    │
│  └─────────────────────────────────────┘                    │
└─────────────────────────────────────────────────────────────┘
                      │ WebSocket (single port)
                      ↓
┌─────────────────────────────────────────────────────────────┐
│                    Server (Zig)                             │
│                                                             │
│  macOS:  libghostty → IOSurface → VideoToolbox (H.264)      │
│  Linux:  libghostty → EGL → VA-API (H.264)                  │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## Quick Start

```bash
# Build (requires Zig 0.14.0+)
make

# Run
./zig-out/bin/termweb mux
```

Open `http://localhost:8080` in Chrome/Edge (WebCodecs required).

## Building

### From Source

```bash
git clone https://github.com/anthropics/termweb
cd termweb
make
./zig-out/bin/termweb mux
```

### Linux Dependencies

```bash
# VA-API for hardware H.264 encoding
sudo apt-get install libva-dev

# Intel GPU driver (if using Intel graphics)
sudo apt-get install intel-media-va-driver
```

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd+/` | New Tab |
| `Cmd+.` | Close Tab |
| `Cmd+D` | Split Right |
| `Cmd+Shift+D` | Split Down |
| `Cmd+[` / `Cmd+]` | Select Previous/Next Split |
| `Cmd+Shift+Enter` | Zoom Split (maximize) |
| `Cmd+1-9` | Switch to Tab 1-9 |
| `Cmd+Shift+F` | Toggle Full Screen |
| `Cmd+U` | Upload Files |
| `Cmd+Shift+S` | Download Files |

## Other Commands

termweb also includes a web browser for terminals:

```bash
# Browse the web in your terminal (Kitty graphics protocol)
termweb open https://example.com
```

See [packages/mux/README.md](packages/mux/README.md) for detailed multiplexer documentation.

## License

MIT
