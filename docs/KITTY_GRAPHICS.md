# Kitty Graphics Protocol for Terminal Browser UI

## Overview

Kitty graphics protocol allows terminals to display images with precise control over positioning, layering, and updates. This document explores how to leverage these features for building a rich browser UI in the terminal.

## Protocol Features

### Image and Placement IDs

```
i=<id>     Image ID - identifies the image data (1 to 2³²-1)
p=<id>     Placement ID - identifies a specific display instance
```

**Key Concept**: An image can have multiple placements. This enables:
- Reusing the same image data in multiple locations
- Updating specific placements without re-transmitting data
- Efficient caching of frequently used UI elements

**Example**: Display image and replace in-place
```
# First frame
\x1b_Ga=T,f=100,i=1,p=1;<base64_data>\x1b\\

# Replace with new frame (same placement)
\x1b_Ga=T,f=100,i=2,p=1;<new_base64_data>\x1b\\
```

### Positioning Controls

| Parameter | Description | Use Case |
|-----------|-------------|----------|
| `c=<cols>` | Width in terminal columns | Responsive sizing |
| `r=<rows>` | Height in terminal rows | Responsive sizing |
| `x=<px>` | X pixel offset within cell | Sub-cell precision |
| `y=<px>` | Y pixel offset within cell | Sub-cell precision |
| `X=<col>` | Absolute column position | Fixed UI elements |
| `Y=<row>` | Absolute row position | Fixed UI elements |

### Z-Index Layering

```
z=<index>   Stack order (-2³¹ to 2³¹-1)
```

- **Negative z**: Renders behind text
- **Zero**: Default layer
- **Positive z**: Renders in front of text

This enables true UI layering - web content behind, UI chrome in front.

### Transmission Modes

| Action | Code | Description |
|--------|------|-------------|
| Transmit & Display | `a=T` | Send image and show immediately |
| Transmit Only | `a=t` | Cache image for later use |
| Put/Display | `a=p` | Display previously cached image |
| Delete | `a=d` | Remove image(s) |
| Query | `a=q` | Check terminal capabilities |
| Animate | `a=a` | Animation frame control |

### Delete Operations

```
d=a        Delete all images
d=i        Delete by image ID
d=p        Delete by placement ID
d=c        Delete at cursor position
d=z        Delete by z-index
```

### Virtual Placements (Unicode Mode)

```
U=1        Enable Unicode placeholder mode
```

Allows embedding images inline with text using special Unicode characters. Useful for:
- Icons in text
- Inline thumbnails
- Mixed content layouts

---

## UI Architecture Options

### Option 1: Single Image (Current Approach)

```
┌─────────────────────────────────────┐
│                                     │
│         Web Page Screencast         │  p=1, z=0
│         (Full terminal area)        │
│                                     │
├─────────────────────────────────────┤
│ status line (ANSI text)             │  Text overlay
└─────────────────────────────────────┘
```

**Pros:**
- Simple implementation
- Low complexity
- Fast - single image update

**Cons:**
- Status line flickers during updates
- No layered UI elements
- Limited customization

### Option 2: Layered Images

```
┌─────────────────────────────────────┐  z=10, p=3
│ [←][→][↻] https://example.com   [×] │  Tab/Address bar
├─────────────────────────────────────┤
│                                     │
│         Web Page Screencast         │  z=0, p=1
│                                     │
│                                     │
├─────────────────────────────────────┤
│ [f]orm [g]oto [?]help    Loading... │  z=10, p=2
└─────────────────────────────────────┘  Status bar
```

**Implementation:**
```zig
// Web content layer (behind)
kitty.displayPNG(writer, page_data, .{
    .placement_id = 1,
    .z = 0,
    .rows = terminal_rows - 2,  // Leave room for chrome
    .y = 1,  // Start after tab bar
});

// Tab bar layer (front)
kitty.displayPNG(writer, tabbar_data, .{
    .placement_id = 2,
    .z = 10,
    .rows = 1,
    .y = 0,
});

// Status bar layer (front)
kitty.displayPNG(writer, status_data, .{
    .placement_id = 3,
    .z = 10,
    .rows = 1,
    .y = terminal_rows - 1,
});
```

**Pros:**
- True layered UI
- Update layers independently
- No flickering between layers
- Professional appearance

**Cons:**
- More complex implementation
- Need to render UI elements as images
- Higher memory usage (multiple images)
- Need image generation for UI chrome

### Option 3: Hybrid (Text Chrome + Image Content)

```
┌─────────────────────────────────────┐
│ ◀ ▶ ↻ │ https://example.com     │ × │  ANSI text
├─────────────────────────────────────┤
│                                     │
│         Web Page Screencast         │  Kitty image, p=1
│                                     │
│                                     │
├─────────────────────────────────────┤
│ [f]orm [g]oto [?]help    Loading... │  ANSI text
└─────────────────────────────────────┘
```

**Implementation:**
```zig
// Draw text-based tab bar
try writer.writeAll("\x1b[1;1H");  // Move to top
try writer.writeAll("\x1b[44m");   // Blue background
try writer.print(" ◀ ▶ ↻ │ {s} │ × ", .{url});
try writer.writeAll("\x1b[0m");    // Reset

// Draw web content (offset by 1 row)
try writer.writeAll("\x1b[2;1H");  // Row 2
kitty.displayPNG(writer, page_data, .{
    .placement_id = 1,
    .rows = terminal_rows - 2,
});

// Draw text-based status bar
try writer.writeAll("\x1b[{d};1H", .{terminal_rows});
try writer.print("[f]orm [g]oto [?]help", .{});
```

**Pros:**
- Best of both worlds
- Fast text rendering for UI
- Rich image for web content
- Easy to customize UI
- Lower memory usage

**Cons:**
- Text and image coordination required
- Potential alignment issues
- Less visual richness than full image UI

### Option 4: Custom Rendered UI

Render the entire browser UI (including chrome) as a single composited image.

```
┌─────────────────────────────────────┐
│ ┌───┬───┬───┐                       │
│ │ ← │ → │ ↻ │  https://example.com  │  All rendered
│ └───┴───┴───┘                       │  as single
├─────────────────────────────────────┤  image with
│                                     │  custom UI
│         Web Page Content            │  toolkit
│         (embedded in UI)            │
│                                     │
├─────────────────────────────────────┤
│ ▸ Forms: 3  ▸ Links: 12  ▸ 1.2s     │
└─────────────────────────────────────┘
```

**Implementation requires:**
1. UI rendering library (e.g., Cairo, Skia, or custom)
2. Composite web screencast with UI elements
3. Single image output to terminal

**Pros:**
- Complete control over appearance
- Pixel-perfect UI
- Consistent look across terminals
- Can implement complex UI patterns
- Animations and transitions

**Cons:**
- Significant implementation effort
- Need graphics rendering library
- Higher CPU usage for compositing
- Larger binary size
- More complex build process

---

## Comparison Matrix

| Feature | Single Image | Layered | Hybrid | Custom UI |
|---------|-------------|---------|--------|-----------|
| Implementation Complexity | Low | Medium | Medium | High |
| Visual Quality | Basic | Good | Good | Excellent |
| Performance | Excellent | Good | Excellent | Good |
| Customization | Low | Medium | High | Unlimited |
| Memory Usage | Low | Medium | Low | Medium |
| Flicker-free | No | Yes | Partial | Yes |
| Text Selection | No | No | Partial | No |
| Build Complexity | Low | Low | Low | High |

---

## Recommended Approach

### Phase 1: Hybrid (Current + Improvements)
1. Keep screencast for web content
2. Add proper viewport offset for UI chrome
3. Use ANSI text for tab bar, status bar, help overlay
4. Pause screencast during overlays (help, prompts)

### Phase 2: Layered Images
1. Pre-render static UI elements as images
2. Use separate placements with z-index
3. Cache UI images (only re-render on theme/resize)
4. Independent update of content vs chrome

### Phase 3: Custom UI (Future)
1. Integrate lightweight rendering (e.g., tiny-skia)
2. Composite web content with rendered UI
3. Support themes, animations
4. Full browser-like experience

---

## Implementation Notes

### Efficient Updates

```zig
// Only update what changed
pub fn updateWebContent(self: *Viewer, frame: []const u8) !void {
    // Web content placement - always updates
    try self.kitty.displayPNG(writer, frame, .{
        .placement_id = CONTENT_PLACEMENT,
        .z = 0,
    });
}

pub fn updateStatusBar(self: *Viewer) !void {
    // Status bar - only update when state changes
    if (!self.status_dirty) return;
    try self.kitty.displayPNG(writer, self.renderStatus(), .{
        .placement_id = STATUS_PLACEMENT,
        .z = 10,
    });
    self.status_dirty = false;
}
```

### Placement ID Constants

```zig
const CONTENT_PLACEMENT: u32 = 1;   // Web page screencast
const TABBAR_PLACEMENT: u32 = 2;    // Tab/address bar
const STATUS_PLACEMENT: u32 = 3;    // Status bar
const OVERLAY_PLACEMENT: u32 = 10;  // Help, dialogs, etc.
```

### Handling Resize

```zig
pub fn onResize(self: *Viewer) !void {
    // Delete all placements
    try self.kitty.clearAll(writer);

    // Re-render all layers with new dimensions
    try self.renderTabBar();
    try self.renderContent();
    try self.renderStatusBar();
}
```

---

## References

- [Kitty Graphics Protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/)
- [Kitty Keyboard Protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/)
- [Terminal Capabilities](https://sw.kovidgoyal.net/kitty/protocol-extensions/)
