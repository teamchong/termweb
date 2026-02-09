# termweb

Stream [Ghostty](https://ghostty.org) to any browser. A headless terminal multiplexer that runs Ghostty on your server and streams pixel-perfect H.264 video to web clients over WebSocket.

## Demo

https://github.com/user-attachments/assets/70b86b29-19b4-458b-8d5d-683f5e139908

## Why

Ghostty is a fantastic terminal emulator, but it's a native desktop app. termweb turns it into a streaming service — run Ghostty headlessly on a server, and connect from any device with a browser: laptop, iPad, phone. No native app install required.

- **One server, many clients** — multiple users can connect to the same session simultaneously
- **Access from anywhere** — any device with a browser becomes a Ghostty terminal
- **Native rendering quality** — libghostty renders to GPU, hardware-encodes to H.264, streams pixels (not text)
- **Real terminal** — full mouse tracking, shell integration, split panes, tabs — not a web terminal approximation

## How It Works

```
┌─────────────────────────────────────────────────────────────┐
│                    Browser / Any Client                     │
│                                                             │
│  WebSocket ──→ Zstd decompress ──→ WebCodecs H.264 decode   │
│  ──→ WebGPU / Canvas 2D render                              │
│                                                             │
│  Keyboard/Mouse ──→ WebSocket ──→ Server                    │
└─────────────────────────────────────────────────────────────┘
                      │ WebSocket (single port)
                      ↓
┌─────────────────────────────────────────────────────────────┐
│                    Server (Zig + libghostty)                │
│                                                             │
│  libghostty ──→ GPU surface ──→ Hardware H.264 encode       │
│  ──→ Zstd compress ──→ WebSocket broadcast                  │
│                                                             │
│  macOS:  IOSurface → VideoToolbox                           │
│  Linux:  EGL → VA-API                                       │
└─────────────────────────────────────────────────────────────┘
```

## Features

### Streaming
- **Hardware H.264 encoding** — VideoToolbox (macOS) / VA-API (Linux), not software encode
- **Low latency** — WebCodecs decodes directly to canvas, no MSE buffering
- **Adaptive quality** — AIMD algorithm adjusts quality per-panel based on available bandwidth
- **WebGPU rendering** — GPU-accelerated frame display with Canvas 2D fallback for iOS Safari
- **Zstd compression** — all WebSocket frames compressed for lower bandwidth

### Multiplexer
- **Tabs** — multiple tabs with LRU switching on close
- **Split panes** — horizontal/vertical splits with draggable dividers, zoom to maximize
- **Quick terminal** — dropdown terminal overlay
- **Shell integration** — pwd tracking, running command indicators
- **Scale to zero** — Ghostty initializes on first panel, frees resources when last one closes

### Input
- **Full mouse support** — hover, click, scroll, drag with modifier keys
- **Mobile touch** — tap, drag, two-finger scroll, pinch-to-zoom on iOS/Android
- **Virtual keyboard** — on-screen accessory bar with Esc, Tab, Ctrl, Alt, Cmd, arrow keys
- **Keyboard shortcuts** — native-feeling key bindings (see below)

### Collaboration
- **Multi-client sessions** — multiple browsers connect to the same session
- **Access control** — session management with share links and viewer/editor roles
- **File transfer** — upload/download with rsync-like options (exclude patterns, delete, preview)

## Quick Start

```bash
# Build (requires Zig 0.14.0+)
make

# Run
./zig-out/bin/termweb mux
```

Open `http://localhost:8080` in any modern browser.

**Browser support:** Chrome, Edge, Safari (including iOS), Firefox — requires WebCodecs.

## Building

### From Source

```bash
git clone https://github.com/nichochar/termweb
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

See [packages/mux/README.md](packages/mux/README.md) for detailed protocol and architecture documentation.

## License

MIT
