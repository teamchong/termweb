# Usage Guide

This guide provides detailed examples and workflows for using termweb effectively.

## Table of Contents

- [Quick Start](#quick-start)
- [Command-Line Interface](#command-line-interface)
- [Interactive Usage](#interactive-usage)
- [Advanced Usage](#advanced-usage)
- [Common Workflows](#common-workflows)
- [Limitations and Known Issues](#limitations-and-known-issues)

## Quick Start

### Basic Workflow

1. **Check system capabilities**
   ```bash
   termweb doctor
   ```

2. **Open a URL**
   ```bash
   termweb open https://example.com
   ```

3. **Navigate** using keyboard controls (see [KEYBINDINGS.md](KEYBINDINGS.md))

4. **Quit** by pressing `q`

## Command-Line Interface

termweb provides several commands for different operations.

### `doctor` Command

The `doctor` command checks your system for termweb compatibility.

**Usage:**
```bash
termweb doctor
```

**What it checks:**
- Terminal type and environment variables
- Kitty Graphics Protocol support
- Truecolor support
- Chrome/Chromium installation

**Example output:**
```
termweb doctor - System capability check
========================================

Terminal:
  TERM: xterm-ghostty
  TERM_PROGRAM: ghostty

Kitty Graphics Protocol:
  ✓ Supported (detected: ghostty)

Truecolor:
  ✓ Supported (COLORTERM=truecolor)

Chrome/Chromium:
  ✓ Found: /Applications/Google Chrome.app/Contents/MacOS/Google Chrome

Overall:
  ✓ Ready for termweb
```

**Troubleshooting with doctor:**
- If Kitty Graphics shows ✗, install a supported terminal (Ghostty, Kitty, WezTerm)
- If Chrome shows ✗, install Chrome or set `CHROME_BIN` environment variable
- Run this before reporting issues

### `open` Command

The `open` command launches a browser session with the specified URL.

**Basic usage:**
```bash
termweb open <url>
```

**Options:**
- `--mobile` - Use mobile viewport (smaller width)
- `--scale N` - Set zoom level (default: 1.0)

#### Examples

**Simple page visit:**
```bash
termweb open https://example.com
```

**Mobile viewport testing:**
```bash
termweb open https://example.com --mobile
```
Use this to test how websites look on mobile devices.

**Zoom in for better readability:**
```bash
termweb open https://news.ycombinator.com --scale 1.5
```
Useful for sites with small text.

**Zoom out to see more content:**
```bash
termweb open https://github.com --scale 0.8
```
Useful for wide layouts or dashboards.

**Combined options:**
```bash
termweb open https://twitter.com --mobile --scale 1.2
```

#### How it works

1. termweb detects your terminal size
2. Launches Chrome in headless mode with remote debugging
3. Opens the URL in Chrome
4. Takes a screenshot and displays it via Kitty graphics protocol
5. Enters interactive mode for navigation

### `version` Command

Shows the current version of termweb.

**Usage:**
```bash
termweb --version
# or
termweb version
```

**Output:**
```
termweb version 0.6.0
```

### `help` Command

Shows help text with available commands.

**Usage:**
```bash
termweb --help
# or
termweb help
```

## Interactive Usage

Once you open a URL with `termweb open`, you enter interactive mode.

### Opening a Web Page

**Initial page load:**
```bash
termweb open https://news.ycombinator.com
```

You'll see:
1. `Launching Chrome...` - Chrome starts in background
2. `Chrome launched` - Connection established
3. `Navigating to: https://news.ycombinator.com` - Page loading
4. `Page loaded` - Screenshot captured
5. The page renders in your terminal
6. Status bar at bottom: `URL: https://... | [q]uit [f]orm [g]oto [↑↓jk]scroll...`

### Navigating Content

#### Scrolling Strategies

**Line-by-line scrolling** (`j`/`k` or arrow keys):
```
Press 'j' to scroll down one line
Press 'k' to scroll up one line
```
Best for: Reading articles, precise navigation

**Half-page scrolling** (`d`/`u`):
```
Press 'd' to scroll down half a page
Press 'u' to scroll up half a page
```
Best for: Quickly scanning content

**Full-page scrolling** (Page Up/Page Down):
```
Press Page Down to scroll down a full page
Press Page Up to scroll up a full page
```
Best for: Jumping through long pages

#### Understanding Viewport Boundaries

- termweb captures exactly what fits in your terminal window
- If content is wider than your terminal, it will be truncated
- Use `--scale 0.8` or smaller to fit more content
- Resize your terminal for different viewport sizes

### Entering URLs

To navigate to a new URL without restarting termweb:

1. Press `g` or `G` in Normal Mode
2. The status bar changes to: `Go to URL: _`
3. Type the complete URL (e.g., `https://example.com`)
4. Press `Enter` to navigate
5. Press `Esc` to cancel

**Example workflow:**
```
1. Currently viewing: https://news.ycombinator.com
2. Press 'g'
3. Type: https://github.com/trending
4. Press Enter
5. Page loads and displays
```

**URL requirements:**
- Must include protocol (`https://` or `http://`)
- No autocomplete (type full URL)
- No history suggestions (yet)

### Working with Forms

Form interaction is a powerful feature of termweb. Press `f` to enter Form Mode and interact with page elements.

#### Activating Form Mode

1. Press `f` in Normal Mode
2. termweb queries the page for interactive elements:
   - Links (`<a href="...">`)
   - Buttons (`<button>`, `<input type="submit">`)
   - Text inputs (`<input type="text">`, `<input type="password">`)
   - Checkboxes (`<input type="checkbox">`)
   - Radio buttons (`<input type="radio">`)
   - Select dropdowns (`<select>`)
   - Textareas (`<textarea>`)

3. Status bar shows: `FORM [1/15]: Link: Click here | [Tab] next [Enter] activate [Esc] exit`

#### Understanding Element Selection

The status bar displays:
- `[1/15]` - Currently on element 1 of 15 total elements
- `Link: Click here` - Type and description of current element
- Available actions

**Element types shown:**
- `Link: <text>` - Clickable link
- `Input[text]: <label>` - Text input field
- `Input[password]: <label>` - Password field
- `Input[checkbox]: <label>` - Checkbox
- `Button: <text>` - Button
- `select: <label>` - Dropdown menu
- `textarea: <label>` - Multi-line text input

#### Filling Text Fields

1. In Form Mode, press `Tab` until you reach a text input
2. Status shows: `FORM [3/15]: Input[text]: Username`
3. Press `Enter` to activate the field
4. Mode changes to Text Input Mode
5. Status shows: `Type text: _`
6. Type your text (e.g., `myusername`)
7. Press `Enter` to submit (sends text + presses Enter key)
8. Returns to Form Mode

**Example: Login form**
```
1. Press 'f' to enter Form Mode
2. Tab to username field: FORM [2/8]: Input[text]: Username
3. Press Enter
4. Type: myusername
5. Press Enter (submits and moves focus)
6. Tab to password field: FORM [3/8]: Input[password]: Password
7. Press Enter
8. Type: mypassword
9. Press Enter
10. Tab to submit button: FORM [4/8]: Button: Log in
11. Press Enter (clicks login button)
```

#### Clicking Buttons

1. Tab to a button element
2. Status shows: `FORM [5/8]: Button: Submit`
3. Press `Enter` to click the button
4. Page may navigate or refresh

#### Working with Checkboxes

1. Tab to a checkbox
2. Status shows: `FORM [4/8]: Input[checkbox]: Remember me`
3. Press `Enter` to toggle (check/uncheck)
4. Page refreshes to show new state

#### Clicking Links

1. Tab to a link
2. Status shows: `FORM [1/15]: Link: Documentation`
3. Press `Enter` to navigate to the link
4. Returns to Normal Mode on new page

#### Select Dropdowns

1. Tab to a select dropdown
2. Status shows: `FORM [6/8]: select: Country`
3. Press `Enter` to activate
4. Use browser's native dropdown (limited control)

**Note:** Full dropdown navigation is planned for future versions.

### Browser History

Navigate back and forward through your browsing history.

**Go back:**
- Press `b` or Left Arrow (`←`)
- Navigates to previous page in history
- Page reloads and displays

**Go forward:**
- Press Right Arrow (`→`)
- Navigates to next page in history (if you went back)

**Example navigation flow:**
```
1. Start at https://example.com
2. Press 'g', navigate to https://github.com
3. Press 'g', navigate to https://news.ycombinator.com
4. Press 'b' → back to https://github.com
5. Press 'b' → back to https://example.com
6. Press '→' → forward to https://github.com
```

### Refreshing Pages

termweb offers two types of refresh:

#### Soft Refresh (`r`)

```
Press 'r' (lowercase)
```

**What it does:**
- Re-captures screenshot from current browser state
- Fast (no network request)
- Useful after dynamic page updates

**When to use:**
- After submitting a form to see results
- After clicking a button that changes page content
- To update view after page animations

#### Hard Reload (`R`)

```
Press 'R' (uppercase)
```

**What it does:**
- Reloads page from server (like pressing F5 in a browser)
- Clears cache
- Slower (makes network request)

**When to use:**
- Page content is stale
- Need fresh data from server
- Page didn't load correctly

## Advanced Usage

### Mobile Testing

Test how websites render on mobile devices using the `--mobile` flag.

**Viewport size:**
- Mobile: ~375px wide (typical mobile width)
- Desktop: Full terminal width

**Example workflow:**
```bash
# Test mobile version
termweb open https://github.com --mobile

# Compare with desktop
termweb open https://github.com
```

**Use cases:**
- Test responsive design
- Check mobile-specific features
- Verify mobile navigation menus

### Zoom Control

Adjust page zoom for better readability or to fit more content.

**Zoom levels:**
- `--scale 2.0` - 200% zoom (magnified)
- `--scale 1.5` - 150% zoom (larger text)
- `--scale 1.0` - 100% zoom (default)
- `--scale 0.8` - 80% zoom (more content visible)
- `--scale 0.5` - 50% zoom (wide view)

**Examples:**

**Zoom in for readability:**
```bash
termweb open https://news.ycombinator.com --scale 1.5
```
Text appears larger, easier to read on high-DPI displays.

**Zoom out for dashboards:**
```bash
termweb open https://grafana.example.com --scale 0.7
```
Fits more dashboard widgets on screen.

**Custom zoom for specific sites:**
```bash
# GitHub with slightly zoomed out view
termweb open https://github.com/trending --scale 0.85

# Documentation with zoomed in text
termweb open https://ziglang.org/documentation --scale 1.3
```

### Working with Complex Sites

Some sites require special handling.

#### JavaScript-Heavy Sites

termweb executes JavaScript via Chrome, so most modern sites work:
- ✓ Single Page Applications (React, Vue, Angular)
- ✓ Dynamic content loading
- ✓ AJAX requests
- ⚠ Real-time updates require refresh

**Example: GitHub**
```bash
termweb open https://github.com

# Use 'f' to navigate tabs
# Use 'r' to refresh after interactions
# Use 'R' if content seems stale
```

#### Sites with Many Forms

For pages with extensive forms (like surveys or checkout):

1. Use `f` to enter Form Mode
2. Status shows total elements: `FORM [1/25]`
3. Tab through methodically
4. Use Esc to exit and re-enter if you lose track

**Tip:** Some forms have hidden fields that termweb detects. The count may be higher than visible elements.

#### Dealing with Popups/Modals

termweb doesn't support multiple windows or modal dialogs well.

**Workarounds:**
- Use `R` to reload if a modal is blocking content
- Some modals can be closed via Form Mode if they have a close button

## Common Workflows

### Reading News Sites

**Hacker News:**
```bash
termweb open https://news.ycombinator.com

# Scroll with 'j'/'k' to read headlines
# Press 'f' to enter Form Mode
# Tab to a story link
# Press Enter to open story
# Press 'b' to go back to list
```

**Reddit:**
```bash
termweb open https://old.reddit.com

# Use 'd'/'u' for half-page scrolling
# Press 'f' for links
# Tab to comments link
# Press Enter to read comments
```

### Testing Forms

**Login Form Testing:**
```bash
termweb open https://example.com/login

# Press 'f' to enter Form Mode
# Tab to username field, Enter, type username, Enter
# Tab to password field, Enter, type password, Enter
# Tab to submit button, Enter
# Observe result with 'r' refresh if needed
```

**Survey/Feedback Forms:**
```bash
termweb open https://example.com/survey

# Press 'f'
# Tab through all fields
# Fill text inputs: Enter, type, Enter
# Toggle checkboxes: Enter on checkbox
# Tab to submit, Enter
```

### Mobile Site Testing

**Test responsive breakpoints:**
```bash
# Desktop view
termweb open https://example.com

# Mobile view
termweb open https://example.com --mobile

# Tablet view (approximate with scale)
termweb open https://example.com --scale 0.75
```

**Check mobile navigation:**
```bash
termweb open https://example.com --mobile

# Press 'f' to find hamburger menu
# Tab to menu button
# Press Enter to open menu
# Use 'r' to refresh and see menu state
```

## Limitations and Known Issues

### Current Limitations

**No mouse support:**
- All interaction is keyboard-only
- Cannot click arbitrary page locations
- Must use Form Mode to interact with elements

**Text input limitations:**
- No cursor positioning within text (always appends)
- Backspace only deletes from end
- No copy/paste support
- No multi-line editing in textareas

**Form limitations:**
- Cannot detect all custom form widgets
- JavaScript-rendered forms may have issues
- File upload inputs not supported
- Drag-and-drop not supported

**Display limitations:**
- Content wider than terminal is cut off
- No horizontal scrolling
- Complex CSS layouts may not render perfectly
- Animated content shows as static screenshot

**Navigation limitations:**
- No tabs or multiple windows
- No bookmarks
- No URL autocomplete
- No search within page

### Known Issues

**Page loading:**
- Some pages take 3-4 seconds to load (hard-coded wait)
- No loading progress indicator
- Fast navigation may miss dynamic content

**Form detection:**
- Elements with `display: none` are still detected
- Hidden form fields appear in element count
- Custom widgets (not standard HTML) may not be detected

**Image rendering:**
- Very large pages may have rendering issues
- Some terminals have image size limits
- Images don't update automatically (need refresh)

### Workarounds

**For wide content:**
- Use `--scale 0.7` or smaller to fit more width
- Resize your terminal to be wider
- Rotate terminal to landscape on tablets

**For slow pages:**
- Wait 3-4 seconds after navigation
- Use `R` (hard reload) if page seems incomplete
- Use `r` (soft refresh) to update screenshot

**For complex forms:**
- Tab through all elements to understand structure
- Use Esc to exit Form Mode and start over if confused
- Some forms work better in desktop Chrome (not ideal, but an option)

## Tips & Best Practices

1. **Always run `termweb doctor` first** - Saves debugging time
2. **Use the right scroll mode** - `j`/`k` for reading, `d`/`u` for scanning
3. **Learn the Form Mode flow** - `f` → Tab → Enter becomes muscle memory
4. **Use `r` liberally** - Refresh often to see page updates
5. **Try different scales** - `--scale` is your friend for different site layouts
6. **Resize your terminal** - Bigger terminal = more content visible
7. **Check the status bar** - It always shows current mode and available commands

## Getting Help

If something isn't working:

1. Run `termweb doctor` to check system compatibility
2. Check [Troubleshooting](TROUBLESHOOTING.md) for common issues
3. Review [Keyboard Controls](KEYBINDINGS.md) to verify correct keys
4. Try a simple page like `https://example.com` to isolate the issue
5. File an issue on GitHub with `termweb doctor` output

## Next Steps

- Learn all [Keyboard Controls](KEYBINDINGS.md)
- Understand the [Architecture](ARCHITECTURE.md)
- Report issues or [Contribute](CONTRIBUTING.md)
