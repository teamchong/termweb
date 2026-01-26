# termweb-dashboard

Terminal-based system monitoring dashboard powered by [termweb](https://github.com/teamchong/termweb).

## Installation

```bash
npm install -g termweb-dashboard
```

## Usage

```bash
termweb-dashboard
```

Opens a real-time system monitoring dashboard in your terminal with:

- **CPU** - Per-core usage with live chart
- **Memory** - RAM and swap usage
- **Disk** - Storage usage with folder treemap (keyboard navigable)
- **Network** - Traffic by remote host with DNS lookup
- **Processes** - Top processes by CPU/memory

## Requirements

- Terminal with [Kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/) support (Kitty, WezTerm, etc.)
- macOS or Linux

## Keyboard Controls

**Disk view:**
- `Arrow keys` - Navigate folders
- `Enter` - Drill into folder
- `Backspace` - Go up one level

**Process view:**
- `Arrow keys` - Select process
- `Tab` - Change sort column
- `Ctrl+K` - Kill selected process

**General:**
- `Escape` - Return to main view
- `Ctrl+Q` - Quit

## License

MIT
