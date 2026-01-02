# Keyboard Controls Reference

termweb operates in four distinct modes, each with its own set of keyboard controls. This reference covers all available keyboard shortcuts.

## Modes Overview

- **Normal Mode** - Default browsing and navigation mode
- **URL Prompt Mode** - Activated by pressing `g` to enter a new URL
- **Form Mode** - Activated by pressing `f` to interact with page elements
- **Text Input Mode** - Activated from Form Mode when entering text into form fields

## Normal Mode (Default)

This is the default mode when you first open a page. The status bar will show the current URL and available commands.

### Navigation & Scrolling

| Key | Action |
|-----|--------|
| `j` | Scroll down one line |
| `k` | Scroll up one line |
| `↓` (Down Arrow) | Scroll down one line |
| `↑` (Up Arrow) | Scroll up one line |
| `d` | Scroll down half page |
| `u` | Scroll up half page |
| `Page Down` | Scroll down full page |
| `Page Up` | Scroll up full page |

### Browser Controls

| Key | Action |
|-----|--------|
| `g` or `G` | Go to URL (enters URL Prompt Mode) |
| `b` | Navigate back in history |
| `←` (Left Arrow) | Navigate back in history |
| `→` (Right Arrow) | Navigate forward in history |
| `r` | Refresh screenshot (fast refresh) |
| `R` | Reload page from server (hard reload) |

### Form Interaction

| Key | Action |
|-----|--------|
| `f` | Enter Form Mode (activate element selection) |

### Exit

| Key | Action |
|-----|--------|
| `q` or `Q` | Quit termweb |
| `Ctrl+C` | Force quit |
| `Esc` | Quit termweb |

### Status Bar (Normal Mode)

Example:
```
URL: https://example.com | [q]uit [f]orm [g]oto [↑↓jk]scroll [r]efresh [R]eload [b]ack [←→]nav
```

## URL Prompt Mode

Activated by pressing `g` or `G` in Normal Mode. Used to navigate to a new URL.

### Text Entry

| Key | Action |
|-----|--------|
| `a-z`, `A-Z`, `0-9` | Type URL characters |
| `:`  | Colon (for URLs) |
| `/`  | Forward slash (for URLs) |
| `.`  | Period (for URLs) |
| `-`  | Hyphen (for URLs) |
| `_`  | Underscore (for URLs) |
| Any printable character (ASCII 32-126) | Type into URL field |

### Editing

| Key | Action |
|-----|--------|
| `Backspace` or `Delete` | Delete character to the left of cursor |

### Navigation

| Key | Action |
|-----|--------|
| `Enter` | Navigate to entered URL and return to Normal Mode |
| `Esc` | Cancel URL entry and return to Normal Mode |

### Status Bar (URL Prompt Mode)

Example:
```
Go to URL: https://example.com_ | [Enter] navigate [Esc] cancel
```

## Form Mode

Activated by pressing `f` in Normal Mode. Use this mode to interact with links, buttons, and form elements on the page.

### Element Navigation

| Key | Action |
|-----|--------|
| `Tab` | Cycle to next interactive element |

**Note:** `Shift+Tab` for previous element is planned for future versions.

### Element Activation

| Key | Action | Element Types |
|-----|--------|---------------|
| `Enter` | Activate current element | All interactive elements |
| `Enter` on link (`<a>`) | Navigate to link destination | Links |
| `Enter` on text input | Enter Text Input Mode | `<input type="text">`, `<input type="password">`, `<textarea>` |
| `Enter` on checkbox | Toggle checkbox state | `<input type="checkbox">` |
| `Enter` on radio button | Select radio button | `<input type="radio">` |
| `Enter` on button | Click button | `<button>`, `<input type="submit">` |
| `Enter` on select | Activate dropdown | `<select>` |

### Exit

| Key | Action |
|-----|--------|
| `Esc` | Exit Form Mode and return to Normal Mode |

### Status Bar (Form Mode)

Example when element is selected:
```
FORM [3/15]: Link: Click here | [Tab] next [Enter] activate [Esc] exit
```

Example when no elements found:
```
FORM: No elements | [Esc] exit
```

## Text Input Mode

Activated from Form Mode when you press `Enter` on a text input field, password field, or textarea.

### Text Entry

| Key | Action |
|-----|--------|
| Any printable character (ASCII 32-126) | Type into focused form field |
| `a-z`, `A-Z`, `0-9` | Type alphanumeric characters |
| Space, punctuation, symbols | Type as expected |

### Editing

| Key | Action |
|-----|--------|
| `Backspace` or `Delete` | Delete character to the left of cursor |

### Submit & Exit

| Key | Action |
|-----|--------|
| `Enter` | Submit input, press Enter key in browser, return to Form Mode |
| `Esc` | Cancel input and return to Form Mode (without submitting) |

### Status Bar (Text Input Mode)

Example:
```
Type text: Hello world_ | [Enter] submit [Esc] cancel
```

## Quick Reference Chart

### Mode Transitions

```
Normal Mode
    ↓ (press 'g')
URL Prompt Mode
    ↓ (press Enter or Esc)
Normal Mode
    ↓ (press 'f')
Form Mode
    ↓ (press Enter on text input)
Text Input Mode
    ↓ (press Enter or Esc)
Form Mode
    ↓ (press Esc)
Normal Mode
```

### Common Tasks

| Task | Keys |
|------|------|
| Open a new URL | `g` → type URL → `Enter` |
| Go back | `b` or `←` |
| Scroll down | `j` or `↓` or `d` (half-page) |
| Fill out a form | `f` → `Tab` to element → `Enter` → type text → `Enter` |
| Click a link | `f` → `Tab` to link → `Enter` |
| Quit | `q` or `Ctrl+C` |

## Tips & Tricks

### Vim Users

If you're familiar with Vim, the Normal Mode navigation will feel natural:
- `j`/`k` for line-by-line scrolling
- `d`/`u` for half-page scrolling
- `g` for "goto" (URL navigation)

### Form Navigation

1. Press `f` to see all interactive elements
2. The status bar shows `[1/15]` indicating you're on element 1 of 15
3. Use `Tab` to cycle through all elements
4. The status bar updates to show which element is currently selected
5. Press `Enter` to activate the selected element

### Refreshing

- Use `r` (lowercase) for a quick screenshot refresh - faster but doesn't reload the page from the server
- Use `R` (uppercase) for a full page reload from the server - slower but ensures fresh content

### Debugging

- Use `termweb doctor` before starting to verify your system supports all features
- Check the status bar for current mode and available commands

## Limitations & Known Issues

- No mouse support (keyboard-only navigation)
- Shift+Tab for previous element not yet implemented
- No cursor positioning within text inputs (text is appended)
- No clipboard support for copy/paste
- No support for multi-line text input (textarea has limited support)

## Future Enhancements

Planned keyboard shortcuts for future versions:
- `Shift+Tab` - Previous element in Form Mode
- `/` - Search mode
- `H` - Browser history view
- `Ctrl+L` - Focus URL bar (alternative to `g`)
- Arrow keys for cursor movement in text fields

## See Also

- [Usage Guide](USAGE.md) - Detailed usage examples demonstrating these keyboard controls
- [Troubleshooting](TROUBLESHOOTING.md) - If keyboard input isn't working correctly
- [Installation](INSTALLATION.md) - Setup and installation instructions
