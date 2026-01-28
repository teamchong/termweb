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

**Main view:**
- `c` - CPU details
- `m` - Memory details
- `n` - Network details
- `d` - Disk details
- `p` - Process list

**Disk view:**
- `Tab/Shift+Tab` - Select folder in treemap
- `Enter` - Navigate to path in textbox
- `Ctrl+Enter` - Drill into selected folder
- `Ctrl+Backspace` - Go up one directory level
- `Ctrl+D` - Delete selected folder (with Y/N confirmation)
- `Escape` - Return to main view

**Process view:**
- `Arrow keys` - Select process
- `Tab/Shift+Tab` - Change sort column
- `Ctrl+K` - Kill selected process (with Y/N confirmation)
- Search box filters by name, PID, or port

**General:**
- `Escape` - Return to main view
- `Ctrl+Q` - Quit

## License

MIT
