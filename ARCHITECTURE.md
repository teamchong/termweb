# Architecture Overview

This document provides a comprehensive overview of termweb's architecture, module organization, and design decisions.

## Table of Contents

- [System Design](#system-design)
- [Module Organization](#module-organization)
- [Data Flow](#data-flow)
- [Protocol Details](#protocol-details)
- [State Management](#state-management)
- [Error Handling](#error-handling)
- [Performance Considerations](#performance-considerations)
- [Design Decisions](#design-decisions)

## System Design

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────┐
│                     User Terminal                        │
│              (Ghostty / Kitty / WezTerm)                 │
└────────────────────┬────────────────────────────────────┘
                     │ Kitty Graphics Protocol
                     │ (PNG images via escape sequences)
                     ↓
┌─────────────────────────────────────────────────────────┐
│                   termweb (Zig CLI)                      │
│                                                           │
│  ┌─────────────┐  ┌──────────────┐  ┌────────────────┐  │
│  │   CLI       │  │   Viewer     │  │   Terminal     │  │
│  │  Parser     │→│  Event Loop  │←│   I/O Layer    │  │
│  └─────────────┘  └──────┬───────┘  └────────────────┘  │
│                          │                               │
│                          ↓                               │
│  ┌─────────────────────────────────────────────────┐    │
│  │           Chrome Automation Layer                │    │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────────┐   │    │
│  │  │   CDP    │  │   DOM    │  │  Interact    │   │    │
│  │  │  Client  │  │ Querying │  │  Actions     │   │    │
│  │  └──────────┘  └──────────┘  └──────────────┘   │    │
│  └─────────────────────────────────────────────────┘    │
└────────────────────┬────────────────────────────────────┘
                     │ WebSocket (CDP)
                     │ JSON-RPC commands
                     ↓
┌─────────────────────────────────────────────────────────┐
│            Chrome/Chromium (Headless)                    │
│                                                           │
│  ┌──────────────┐  ┌─────────────┐  ┌───────────────┐   │
│  │   Renderer   │  │  JavaScript │  │   Network     │   │
│  │   Engine     │  │   Engine    │  │   Stack       │   │
│  └──────────────┘  └─────────────┘  └───────────────┘   │
└─────────────────────────────────────────────────────────┘
```

### Technology Stack

- **Language:** Zig 0.15.2
- **Browser Engine:** Chrome/Chromium via Chrome DevTools Protocol (CDP)
- **Communication:** WebSocket (JSON-RPC over WS)
- **Graphics:** Kitty Graphics Protocol (PNG images via terminal escape sequences)
- **Terminal I/O:** POSIX raw terminal mode, non-blocking I/O

## Module Organization

termweb is organized into three main subsystems:

### `src/` - Core Application

**`main.zig`** (15 lines)
- Entry point for the application
- Delegates to CLI runner

**`cli.zig`** (252 lines)
- Command-line argument parsing
- Command dispatch (`open`, `doctor`, `version`, `help`)
- Doctor diagnostic checks
- Help text rendering

**`viewer.zig`** (428 lines)
- Main event loop and mode state machine
- Keyboard input handling
- Mode-specific handlers (Normal, URL Prompt, Form, Text Input)
- Screenshot refresh coordination
- Status bar rendering

### `src/chrome/` - Browser Automation

**`detector.zig`** (89 lines)
- Chrome/Chromium binary detection
- Platform-specific search paths (macOS, Linux)
- `CHROME_BIN` environment variable support

**`launcher.zig`** (153 lines)
- Chrome process management
- Headless launch with remote debugging
- WebSocket URL extraction from temp file
- Viewport size configuration

**`cdp_client.zig`** (156 lines)
- Chrome DevTools Protocol client wrapper
- Synchronous command/response pattern
- Message ID tracking
- Basic error handling

**`websocket_cdp.zig`** (305 lines)
- WebSocket client implementation over TCP
- HTTP upgrade handshake
- Frame parsing (text, binary, close)
- Message fragmentation handling

**`screenshot.zig`** (133 lines)
- Screenshot capture via `Page.captureScreenshot`
- Navigation commands (`Page.navigate`, `Page.reload`)
- History navigation (`Page.goBack`, `Page.goForward`)
- 3-second page load wait (TODO: use `Page.loadEventFired`)

**`scroll.zig`** (102 lines)
- Scroll emulation via `Input.dispatchMouseEvent` (mouse wheel)
- Line scrolling (~20px increments)
- Half-page scrolling (viewport_height / 2)
- Full-page scrolling (viewport_height - 40px overlap)

**`dom.zig`** (168 lines)
- DOM querying via JavaScript injection (`Runtime.evaluate`)
- `InteractiveElement` struct (tag, type, text, position, selector)
- `FormContext` for Tab navigation state
- JSON parsing of query results

**`interact.zig`** (121 lines)
- Element interaction via CDP Input domain
- Mouse click simulation (press + release)
- Keyboard event dispatch (Enter key)
- Text insertion (`Input.insertText`)
- JavaScript-based actions (focus, checkbox toggle)

### `src/terminal/` - Terminal I/O

**`terminal.zig`** (80 lines)
- Terminal size detection (`TIOCGWINSZ` ioctl)
- Raw mode setup (`termios` configuration)
- Terminal state restoration

**`kitty_graphics.zig`** (81 lines)
- Kitty graphics protocol implementation
- Base64 PNG encoding
- Escape sequence generation
- Image placement and sizing
- Clear all images command

**`screen.zig`** (25 lines)
- Screen control escape sequences
- Cursor show/hide
- Screen clear
- Line clear
- Cursor positioning

**`input.zig`** (71 lines)
- Non-blocking keyboard input reading
- Escape sequence parsing
- Key enum (char, arrow keys, special keys)
- ANSI escape code handling

**`prompt.zig`** (43 lines)
- Text input buffer for URL and form text entry
- Character insertion at cursor
- Backspace handling
- Rendering helper

### `vendor/` - Third-Party Dependencies

**`json/`** (~2000 lines)
- JSON parsing library for CDP responses

**`websocket/`** (~1000 lines)
- Low-level WebSocket frame handling

## Data Flow

### Startup Flow

1. **CLI Parsing** (`cli.zig:run()`)
   - Parse command-line arguments
   - Determine command (open, doctor, version, help)

2. **Chrome Detection** (`detector.detectChrome()`)
   - Search standard paths for Chrome binary
   - Check `$CHROME_BIN` environment variable
   - Return path or error

3. **Chrome Launch** (`launcher.launchChrome()`)
   - Spawn Chrome process with `--headless --remote-debugging-port=9222`
   - Wait for Chrome to write WebSocket URL to temp file
   - Parse WebSocket URL from `DevToolsActivePort` file

4. **CDP Connection** (`cdp_client.CdpClient.init()`)
   - Connect TCP socket to `localhost:9222`
   - Perform HTTP → WebSocket upgrade handshake
   - Initialize message ID counter

5. **Initial Navigation** (`screenshot_api.navigateToUrl()`)
   - Send `Page.navigate` command with URL
   - Wait 3 seconds for page load (hard-coded delay)

6. **Viewer Loop** (`viewer.Viewer.run()`)
   - Enter raw terminal mode
   - Hide cursor
   - Capture initial screenshot and render
   - Enter main event loop

### Render Loop

```
┌─────────────────────────────────────┐
│  User Action (key press, mode      │
│  change, navigation)                │
└──────────┬──────────────────────────┘
           │
           ↓
┌─────────────────────────────────────┐
│  viewer.refresh()                   │
│  ├─ Clear screen (ANSI codes)       │
│  ├─ Clear Kitty images              │
│  └─ Request new screenshot          │
└──────────┬──────────────────────────┘
           │
           ↓
┌─────────────────────────────────────┐
│  screenshot_api.captureScreenshot() │
│  ├─ Send Page.captureScreenshot     │
│  ├─ Receive base64 PNG response     │
│  └─ Return base64 data              │
└──────────┬──────────────────────────┘
           │
           ↓
┌─────────────────────────────────────┐
│  Base64 Decode                      │
│  ├─ std.base64.standard.Decoder     │
│  └─ Allocate PNG byte array         │
└──────────┬──────────────────────────┘
           │
           ↓
┌─────────────────────────────────────┐
│  kitty.displayPNG()                 │
│  ├─ Encode PNG as base64 chunks     │
│  ├─ Generate Kitty escape sequences │
│  └─ Write to stdout                 │
└──────────┬──────────────────────────┘
           │
           ↓
┌─────────────────────────────────────┐
│  drawStatus()                       │
│  ├─ Position cursor at last row     │
│  ├─ Clear line                      │
│  ├─ Render mode-specific status     │
│  └─ Show keybinding hints           │
└─────────────────────────────────────┘
```

### Input Handling Flow

```
┌─────────────────────────────────────┐
│  stdin (non-blocking read)          │
│  ├─ input.readKey()                 │
│  ├─ Parse escape sequences          │
│  └─ Return Key enum                 │
└──────────┬──────────────────────────┘
           │
           ↓
┌─────────────────────────────────────┐
│  viewer.handleKey(key)              │
│  └─ Dispatch to mode handler        │
└──────────┬──────────────────────────┘
           │
           ↓
┌──────────┴──────────────────────────┐
│  Mode-Specific Handlers              │
├──────────────────────────────────────┤
│  handleNormalMode()                  │
│  ├─ Scroll: Call scroll_api          │
│  ├─ Navigate: Call screenshot_api    │
│  ├─ 'g': Enter URL Prompt Mode       │
│  └─ 'f': Enter Form Mode             │
├──────────────────────────────────────┤
│  handleUrlPromptMode()               │
│  ├─ Char: Insert into prompt buffer  │
│  ├─ Backspace: Remove from buffer    │
│  ├─ Enter: Navigate to URL           │
│  └─ Esc: Cancel, return to Normal    │
├──────────────────────────────────────┤
│  handleFormMode()                    │
│  ├─ Tab: Cycle to next element       │
│  ├─ Enter: Activate element          │
│  └─ Esc: Exit to Normal Mode         │
├──────────────────────────────────────┤
│  handleTextInputMode()               │
│  ├─ Char: Insert into prompt buffer  │
│  ├─ Backspace: Remove from buffer    │
│  ├─ Enter: Submit text               │
│  └─ Esc: Cancel, return to Form      │
└─────────────────────────────────────┘
```

### Form Interaction Flow

```
┌─────────────────────────────────────┐
│  User presses 'f' in Normal Mode    │
└──────────┬──────────────────────────┘
           │
           ↓
┌─────────────────────────────────────┐
│  dom.queryElements()                │
│  ├─ Inject JavaScript query         │
│  ├─ Runtime.evaluate command         │
│  ├─ Receive JSON array response     │
│  └─ Parse into InteractiveElement[] │
└──────────┬──────────────────────────┘
           │
           ↓
┌─────────────────────────────────────┐
│  FormContext initialization         │
│  ├─ Store elements array            │
│  ├─ Set current_index = 0           │
│  └─ Enter Form Mode                 │
└──────────┬──────────────────────────┘
           │
           ↓
┌─────────────────────────────────────┐
│  User presses Tab                   │
│  ├─ FormContext.next()              │
│  ├─ Increment current_index         │
│  └─ Wrap around at end              │
└──────────┬──────────────────────────┘
           │
           ↓
┌─────────────────────────────────────┐
│  User presses Enter on element      │
│  └─ Dispatch based on element type  │
└──────────┬──────────────────────────┘
           │
           ↓
┌──────────┴──────────────────────────┐
│  Element-Specific Actions            │
├──────────────────────────────────────┤
│  Link (<a>)                          │
│  └─ interact.clickElement()          │
│      └─ Click at center coordinates  │
├──────────────────────────────────────┤
│  Text Input (<input type="text">)   │
│  ├─ interact.focusElement()          │
│  ├─ Enter Text Input Mode            │
│  ├─ User types text                  │
│  ├─ interact.typeText()              │
│  └─ interact.pressEnter()            │
├──────────────────────────────────────┤
│  Checkbox (<input type="checkbox">) │
│  └─ interact.toggleCheckbox()        │
│      └─ JavaScript .click()          │
├──────────────────────────────────────┤
│  Button (<button>)                   │
│  └─ interact.clickElement()          │
│      └─ Click at center coordinates  │
└─────────────────────────────────────┘
```

## Protocol Details

### Chrome DevTools Protocol (CDP)

**Overview:**
- JSON-RPC 2.0 protocol over WebSocket
- Bidirectional communication (commands & events)
- Domain-based API organization (Page, Runtime, Input, etc.)

**Message Format:**

Request:
```json
{
  "id": 1,
  "method": "Page.navigate",
  "params": {
    "url": "https://example.com"
  }
}
```

Response:
```json
{
  "id": 1,
  "result": {
    "frameId": "...",
    "loaderId": "..."
  }
}
```

**Key Domains Used:**

- `Page` - Navigation, reload, screenshot capture
- `Runtime` - JavaScript execution (for DOM querying)
- `Input` - Keyboard and mouse event simulation

**Implementation Notes:**
- Currently synchronous (blocking on response)
- Message IDs tracked per-connection
- No event subscription (TODO for `Page.loadEventFired`)

### Kitty Graphics Protocol

**Overview:**
- Terminal escape sequence extension for image display
- Supports PNG, JPEG, and raw RGB formats
- Base64-encoded image data in escape sequences
- Images are placed at cursor position

**Escape Sequence Format:**
```
\x1b_G<control_data>;<base64_data>\x1b\\
```

**Control Data:**
- `a=T` - Transmission medium (T = direct, f = file)
- `f=100` - Format (100 = PNG)
- `t=d` - Transmission type (d = direct)
- `r=<rows>` - Number of rows to occupy
- `c=<cols>` - Number of columns to occupy

**Example:**
```
\x1b_Ga=T,f=100,t=d,r=24,c=80;iVBORw0KGgoAAAANSUhEUgA...\x1b\\
```

**Implementation:**
- PNG data is base64-encoded in chunks
- termweb uses direct transmission (`a=T`)
- Images are sized to fit terminal (rows - 1 for status bar)
- Clear command: `\x1b_Ga=d\x1b\\`

## State Management

### ViewerMode Enum

```zig
pub const ViewerMode = enum {
    normal,       // Default browsing mode
    url_prompt,   // Entering new URL (g key)
    form_mode,    // Selecting form elements (f key)
    text_input,   // Typing into form field
};
```

### Mode Transitions

```
     ┌──────────────┐
     │ Normal Mode  │
     └───┬──────┬───┘
         │      │
      'g'│      │'f'
         │      │
         ↓      ↓
┌──────────────┐ ┌──────────────┐
│ URL Prompt   │ │  Form Mode   │
└──────────────┘ └───┬──────────┘
   │      ↑           │Enter on
Enter│   Esc│          │text input
   │      │           ↓
   ↓      │     ┌──────────────┐
┌──────────────┐│  Text Input  │
│ (Navigate)   ││   Mode       │
│ Normal Mode  │└───┬──────────┘
└──────────────┘  Enter│   Esc│
                    │      │
                    ↓      ↓
                  ┌──────────────┐
                  │  Form Mode   │
                  └──────────────┘
```

### State Fields

**Viewer struct:**
```zig
pub const Viewer = struct {
    allocator: std.mem.Allocator,
    terminal: Terminal,
    kitty: KittyGraphics,
    cdp_client: *cdp.CdpClient,
    input: InputReader,
    current_url: []const u8,
    running: bool,
    mode: ViewerMode,                    // Current mode
    prompt_buffer: ?PromptBuffer,        // URL/text input buffer
    form_context: ?*FormContext,         // Form navigation state
};
```

## Error Handling

termweb uses Zig's error union types for explicit error propagation.

**Common Error Types:**
- `error.ChromeNotFound` - Chrome binary not detected
- `error.ConnectionFailed` - CDP WebSocket connection failed
- `error.InvalidResponse` - Malformed CDP response
- `error.TerminalNotSupported` - Terminal doesn't support Kitty graphics

**Error Propagation:**
```zig
try screenshot_api.captureScreenshot(client, allocator, .{});
// Errors bubble up to main() where they're handled
```

**User-Facing Errors:**
- CLI prints diagnostic messages with `std.debug.print`
- Doctor command provides detailed capability checks
- Exit codes indicate success (0) or failure (1)

## Performance Considerations

### Screenshot Capture Latency

**Bottlenecks:**
1. Network round-trip to Chrome (WebSocket)
2. Chrome rendering pipeline
3. PNG encoding by Chrome
4. Base64 decode in termweb
5. Terminal rendering (Kitty graphics)

**Typical latency:** 100-300ms per refresh

**Optimizations:**
- Use `r` (soft refresh) instead of `R` (hard reload) when possible
- Avoid unnecessary refreshes

### WebSocket Message Overhead

**Current implementation:**
- Synchronous blocking on response
- No message batching
- Full JSON parse per message

**Future improvements:**
- Async event loop
- Message batching for multiple commands
- Streaming JSON parser

### Memory Management

**Allocations:**
- Screenshots: ~1-5MB PNG data (transient)
- FormContext: ~100 bytes per element
- PromptBuffer: <1KB

**Deallocation:**
- All buffers properly freed via `defer`
- FormContext elements cleaned up in `deinit()`
- No known memory leaks

### Terminal Rendering Speed

**Factors:**
- Kitty graphics protocol is fast (native terminal support)
- Base64 encoding adds ~33% size overhead
- Terminal emulator rendering performance varies

**Tested terminals:**
- Ghostty: Excellent performance
- Kitty: Excellent performance
- WezTerm: Good performance

## Design Decisions

### Why Chrome CDP?

**Alternatives considered:**
- Playwright/Puppeteer (Node.js)
- WebKit directly

**Reasons for CDP:**
- Direct protocol access (no Node.js dependency)
- Full web platform support (JavaScript, CSS, modern APIs)
- Mature, stable protocol
- Widely used and documented

### Why Kitty Graphics Protocol?

**Alternatives considered:**
- Sixel graphics
- iTerm2 inline images
- ASCII art rendering

**Reasons for Kitty:**
- Modern terminals support it (Ghostty, Kitty, WezTerm)
- PNG support (no quality loss)
- Efficient (no re-encoding)
- Active development and support

### Why Zig?

**Alternatives considered:**
- Go (for simplicity)
- Rust (for safety)
- C (for performance)

**Reasons for Zig:**
- Manual memory management (no GC pauses)
- Excellent C interop (terminal I/O, ioctl)
- Compile-time safety
- Simple, readable code
- Fast compile times
- Single binary output (no runtime dependencies)

### Why Synchronous CDP?

**Current:** Blocking request/response

**Why not async:**
- Simpler initial implementation
- Adequate performance for human interaction
- Easier error handling

**Future:** Async event loop planned for:
- `Page.loadEventFired` events
- Parallel command execution
- Better responsiveness

## Extension Points

### Adding New Commands

1. Add command to `Command` enum in `cli.zig`
2. Implement `cmdYourCommand()` function
3. Add case in `run()` switch statement
4. Update help text in `printHelp()`

### Adding New CDP Features

1. Create new module in `src/chrome/`
2. Import `cdp_client.zig`
3. Implement wrapper functions:
   ```zig
   pub fn yourFeature(client: *CdpClient, allocator: std.mem.Allocator) !void {
       const params = try std.fmt.allocPrint(allocator, "{{...}}", .{});
       defer allocator.free(params);
       const result = try client.sendCommand("Domain.method", params);
       defer allocator.free(result);
       // Parse result...
   }
   ```

### Supporting New Terminal Protocols

1. Create new module in `src/terminal/`
2. Implement protocol-specific escape sequences
3. Add detection in `cli.cmdDoctor()`
4. Update viewer to use new protocol conditionally

## Future Architecture Changes

### Planned Improvements

1. **Async Event Loop** - Non-blocking CDP communication
2. **Tab Support** - Multiple browser tabs
3. **Better Page Load Detection** - Use `Page.loadEventFired` instead of hard-coded delay
4. **Plugin System** - Extensible command/feature architecture
5. **Configuration Files** - User preferences (default scale, keybindings)

### Scalability Considerations

Current architecture is single-threaded and synchronous, which is:
- ✓ Simple and maintainable
- ✓ Sufficient for terminal UI (human speed)
- ✗ Blocks on network I/O
- ✗ Can't handle real-time updates

For future versions with tabs or real-time updates, consider:
- Event loop with async CDP
- Multi-threaded rendering
- Separate UI and network threads

## See Also

- [Usage Guide](USAGE.md) - How to use termweb features
- [Contributing](CONTRIBUTING.md) - How to contribute code
- [Troubleshooting](TROUBLESHOOTING.md) - Common issues and debugging
