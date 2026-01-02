# termweb

Web browser in your terminal using Kitty graphics protocol.

## Overview

`termweb` renders web pages via Playwright and displays them inside Kitty-graphics-capable terminals (Ghostty, Kitty, WezTerm) using pixel frames.

## Status

**Current version:** 0.1.0 (M0 - Project Skeleton)

### Milestones

- ✅ **M0** - Project skeleton
  - CLI commands: `open`, `doctor`, `version`, `help`
  - Build system with Zig
  - Terminal capability detection

- ⏳ **M1** - Static render viewer (0.2)
  - Playwright integration
  - Screenshot capture
  - Kitty graphics display
  - Basic key controls (q, r, g)

- 🔲 **M2** - Scroll + persistent page (0.3)
- 🔲 **M3** - Navigation basics (0.4)
- 🔲 **M4** - Interactive-lite inputs (0.5)
- 🔲 **M5** - Packaging + docs (0.6)

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
