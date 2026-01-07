# Troubleshooting Guide

This guide helps you diagnose and fix common issues with termweb.

## Table of Contents

- [Using termweb doctor](#using-termweb-doctor)
- [Installation Issues](#installation-issues)
- [Runtime Issues](#runtime-issues)
- [Performance Issues](#performance-issues)
- [Platform-Specific Issues](#platform-specific-issues)
- [Getting More Help](#getting-more-help)

## Using termweb doctor

The `doctor` command is your first debugging tool. Run it before reporting issues:

```bash
termweb doctor
```

### Understanding Doctor Output

**Terminal Detection:**
```
Terminal:
  TERM: xterm-ghostty
  TERM_PROGRAM: ghostty
```
- Shows environment variables used for terminal detection
- `TERM_PROGRAM` should be `ghostty`, `kitty`, or `WezTerm`

**Kitty Graphics Protocol:**
```
Kitty Graphics Protocol:
  ✓ Supported (detected: ghostty)
```
- ✓ = Terminal supports Kitty graphics
- ✗ = Terminal doesn't support Kitty graphics (termweb won't work)

**Truecolor Support:**
```
Truecolor:
  ✓ Supported (COLORTERM=truecolor)
```
- ✓ = Terminal supports 24-bit color
- ✗ = Limited color support (images may look worse)

**Chrome Detection:**
```
Chrome/Chromium:
  ✓ Found: /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
```
- ✓ = Chrome found at shown path
- ✗ = Chrome not found (need to install or set `CHROME_BIN`)

### How to Fix Doctor Failures

**If Kitty Graphics shows ✗:**
Install a supported terminal:
- [Ghostty](https://ghostty.org/) (recommended)
- [Kitty](https://sw.kovidgoyal.net/kitty/)
- [WezTerm](https://wezfurlong.org/wezterm/)

**If Chrome shows ✗:**
```bash
# Install Chrome (macOS)
brew install --cask google-chrome

# Or set CHROME_BIN to custom location
export CHROME_BIN=/path/to/chrome
```

## Installation Issues

### Zig Build Fails

**Error: `command not found: zig`**

**Cause:** Zig not in PATH

**Fix:**
```bash
# Verify Zig installation
which zig

# If not found, install Zig or add to PATH
export PATH="/usr/local/zig:$PATH"
```

---

**Error: `error: ZigCompilerNotFound`**

**Cause:** Zig version too old or corrupted installation

**Fix:**
```bash
# Check version
zig version

# Should show 0.15.2 or later
# If not, reinstall Zig from ziglang.org
```

---

**Error: `unable to build: build.zig not found`**

**Cause:** Not in project directory

**Fix:**
```bash
# Make sure you're in the termweb directory
cd /path/to/termweb
ls build.zig  # Should exist

# Then build
zig build
```

---

**Error: `error: FileNotFound - unable to find 'vendor/json/json.zig'`**

**Cause:** Incomplete git clone or corrupted checkout

**Fix:**
```bash
# Re-clone repository
cd ..
rm -rf termweb
git clone https://github.com/yourusername/termweb.git
cd termweb
zig build
```

### Chrome Not Detected

**Error: `Chrome not found`**

**Cause 1:** Chrome not installed

**Fix:**
```bash
# macOS
brew install --cask google-chrome

# Linux (Ubuntu/Debian)
wget https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
sudo dpkg -i google-chrome-stable_current_amd64.deb
```

**Cause 2:** Chrome installed in non-standard location

**Fix:**
```bash
# Find Chrome
# macOS
ls "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# Linux
which google-chrome
which chromium-browser

# Set CHROME_BIN
export CHROME_BIN="/path/to/chrome"

# Add to shell config to make permanent
echo 'export CHROME_BIN="/path/to/chrome"' >> ~/.zshrc
```

**Cause 3:** Using Chromium instead of Chrome

**Fix:**
```bash
# Detect Chromium path
which chromium-browser  # Linux
ls /Applications/Chromium.app  # macOS

# Set CHROME_BIN
export CHROME_BIN="/usr/bin/chromium-browser"  # Linux
export CHROME_BIN="/Applications/Chromium.app/Contents/MacOS/Chromium"  # macOS
```

### Terminal Not Supported

**Error: `Kitty Graphics Protocol: ✗ Not detected`**

**Cause:** Using an unsupported terminal (Terminal.app, iTerm2, Alacritty, etc.)

**Fix:** Install a supported terminal:

```bash
# Ghostty (recommended)
# Download from https://ghostty.org/

# Kitty
brew install --cask kitty  # macOS
sudo apt-get install kitty  # Linux

# WezTerm
brew install --cask wezterm  # macOS
```

After installing, **launch the new terminal** and run `termweb doctor` again.

## Runtime Issues

### Chrome Launch Fails

**Error: `Error launching Chrome: FileNotFound`**

**Cause:** Chrome binary not found or wrong path

**Fix:**
```bash
# Run doctor to see detected path
termweb doctor

# If path is wrong, set CHROME_BIN
export CHROME_BIN="/correct/path/to/chrome"
```

---

**Error: `Error launching Chrome: AccessDenied`**

**Cause:** Chrome binary doesn't have execute permissions

**Fix:**
```bash
# macOS
chmod +x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# Linux
sudo chmod +x /usr/bin/google-chrome
```

---

**Error: `Cannot start Chrome debugger on port 9222`**

**Cause:** Port 9222 already in use by another Chrome instance

**Fix:**
```bash
# Find and kill existing Chrome processes
# macOS
pkill -f "Chrome.*--remote-debugging-port"
ps aux | grep "remote-debugging-port"

# Linux
pkill -f "chrome.*--remote-debugging-port"
ps aux | grep "remote-debugging-port"

# Kill specific process
kill <PID>

# Then try again
termweb open https://example.com
```

### WebSocket Connection Fails

**Error: `Error connecting to Chrome DevTools Protocol: ConnectionRefused`**

**Cause:** Chrome didn't start properly or crashed during launch

**Fix:**
```bash
# Kill all Chrome processes
pkill -f Chrome  # macOS
pkill -f chrome  # Linux

# Wait a moment
sleep 2

# Try again
termweb open https://example.com

# If still fails, check Chrome can launch manually
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --version
```

---

**Error: `Error connecting: Timeout`**

**Cause:** Firewall blocking localhost connections or Chrome taking too long

**Fix:**
```bash
# Check if port 9222 is blocked
nc -zv localhost 9222

# If blocked, check firewall rules
# macOS
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate

# Allow Chrome through firewall
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
```

### No Image Displayed

**Error:** Page loads but no image appears, only status bar

**Cause 1:** Terminal doesn't support Kitty graphics

**Fix:**
```bash
# Verify terminal support
termweb doctor

# Check TERM_PROGRAM
echo $TERM_PROGRAM

# Should be: ghostty, kitty, or WezTerm
# If not, switch to supported terminal
```

**Cause 2:** Image too large for terminal

**Fix:**
```bash
# Try smaller zoom
termweb open https://example.com --scale 0.5

# Or resize terminal to be larger
# Then try again
```

**Cause 3:** Terminal image rendering disabled

**Fix (Kitty):**
```bash
# Check Kitty config
cat ~/.config/kitty/kitty.conf | grep allow

# Should NOT have: allow_remote_control no
# If it does, comment it out or set to yes
```

### Keyboard Input Not Working

**Error:** Keys don't respond or produce wrong characters

**Cause 1:** Terminal not in raw mode

**Fix:**
Try restarting termweb. If issue persists:
```bash
# Reset terminal
reset

# Try again
termweb open https://example.com
```

**Cause 2:** Terminal key bindings conflicting

**Fix (varies by terminal):**

Ghostty - Check `~/.config/ghostty/config`
```
# Make sure no conflicting keybindings for j, k, f, g, etc.
```

Kitty - Check `~/.config/kitty/kitty.conf`
```
# Comment out conflicting map commands
# map f ...  <- This would conflict
```

**Cause 3:** SSH session or tmux interfering

**Fix:**
```bash
# Run termweb outside tmux/screen
exit  # Exit tmux

# Or use -CC mode for tmux
tmux -CC attach
```

### Page Not Loading

**Error:** "Page loaded" but content is blank or partial

**Cause 1:** Page needs more time to load (JavaScript-heavy sites)

**Fix:**
```bash
# Wait 3-4 seconds after opening
termweb open https://heavy-js-site.com

# Wait...

# Then press 'r' to refresh screenshot
# Press 'R' if still not loaded (hard reload)
```

**Cause 2:** Network connectivity issues

**Fix:**
```bash
# Test network
ping google.com

# Test URL in regular Chrome first
open "https://example.com"  # macOS
google-chrome "https://example.com"  # Linux

# If works in Chrome but not termweb, try hard reload
# In termweb, press 'R' (uppercase)
```

**Cause 3:** Site blocks headless browsers

**Fix:**
Some sites detect headless Chrome. Not much can be done currently.
Workaround: Use a different site or wait for future anti-detection features.

**Cause 4:** Ghostty does not support Kitty SHM transfers on your build (UI renders but page area is blank)

**Fix:**
```bash
TERMWEB_DISABLE_SHM=1 termweb open https://example.com
# To override auto-disable: TERMWEB_FORCE_SHM=1
```

### Forms Not Working

**Error:** Pressing 'f' shows "No elements"

**Cause 1:** Page has no interactive elements

**Fix:**
This is expected. Try a different page:
```bash
termweb open https://google.com  # Has search form
```

**Cause 2:** Elements are dynamically loaded

**Fix:**
```bash
# Wait for page to fully load
# Press 'r' to refresh screenshot
# Press 'f' again to re-query elements
```

**Cause 3:** Custom form widgets not detected

**Fix:**
termweb only detects standard HTML elements:
- `<a>`, `<button>`, `<input>`, `<select>`, `<textarea>`

Custom React/Vue components may not be detected. No workaround currently.

---

**Error:** Form submission doesn't work

**Cause:** Some forms use JavaScript instead of standard submission

**Fix:**
```bash
# After typing and pressing Enter:
# 1. Press 'r' to refresh and see if form submitted
# 2. If not, try clicking submit button manually:
#    - Press 'f' to enter form mode
#    - Tab to submit button
#    - Press Enter
```

## Performance Issues

### Slow Screenshot Capture

**Symptom:** 3-10 seconds delay after pressing 'r' or navigating

**Cause 1:** Large/complex page

**Fix:**
```bash
# Use smaller scale to render less detail
termweb open https://complex-site.com --scale 0.5

# Or accept the delay (it's Chrome rendering time)
```

**Cause 2:** Slow network

**Fix:**
```bash
# Use 'r' (soft refresh) instead of 'R' (hard reload)
# 'r' doesn't reload from network

# Or wait for better network connection
```

**Cause 3:** Chrome consuming too many resources

**Fix:**
```bash
# Kill other Chrome instances
pkill -f Chrome

# Reduce terminal size (smaller screenshots)
# Resize terminal to be smaller
```

### High Memory Usage

**Symptom:** termweb using >500MB RAM

**Cause:** Chrome process memory (normal for browser engines)

**Fix:**
This is expected. Chrome instances use 200-500MB typically.

```bash
# Check memory
ps aux | grep -i chrome

# If too high, close and reopen
# Press 'q' to quit termweb
# Relaunch
```

### Input Lag

**Symptom:** Keys take >500ms to respond

**Cause 1:** Terminal rendering performance

**Fix:**
```bash
# Try different supported terminal
# Ghostty generally fastest

# Or reduce image size
termweb open https://example.com --scale 0.7
```

**Cause 2:** CPU overloaded

**Fix:**
```bash
# Check CPU usage
top

# Close other applications
# Wait for CPU to be available
```

## Platform-Specific Issues

### macOS

**Issue:** "Chrome is damaged and can't be opened"

**Fix:**
```bash
# Remove quarantine attribute
xattr -d com.apple.quarantine "/Applications/Google Chrome.app"
```

---

**Issue:** Permission denied errors

**Fix:**
```bash
# Grant terminal full disk access
# System Preferences → Security & Privacy → Privacy → Full Disk Access
# Add your terminal (Ghostty, Kitty, etc.)
```

---

**Issue:** Screenshot shows desktop instead of Chrome

**Fix:**
```bash
# Grant Chrome screen recording permission
# System Preferences → Security & Privacy → Privacy → Screen Recording
# Add Google Chrome
```

### Linux

**Issue:** Chrome crashes with "Kernel too old"

**Fix:**
```bash
# Check kernel version
uname -r

# Should be 3.10+
# If not, update system or use Chromium instead
```

---

**Issue:** `libX11.so.6: cannot open shared object file`

**Fix:**
```bash
# Install X11 libraries
# Ubuntu/Debian
sudo apt-get install libx11-6 libxext6

# Fedora
sudo dnf install libX11
```

---

**Issue:** Display not found (headless servers)

**Fix:**
```bash
# Install Xvfb for virtual display
sudo apt-get install xvfb

# Run Chrome with Xvfb
Xvfb :99 -screen 0 1280x1024x24 &
export DISPLAY=:99

# Then use termweb
termweb open https://example.com
```

### Windows

**Note:** Windows is not yet officially supported. Issues are expected.

Common issues:
- Path handling (use Windows paths)
- Terminal emulator compatibility
- ANSI escape sequence support

If you're testing on Windows, please report your findings!

## Getting More Help

### Before Reporting an Issue

1. Run `termweb doctor` and include output
2. Try latest version from main branch
3. Search existing GitHub issues
4. Check this troubleshooting guide thoroughly

### Reporting a Bug

Open a GitHub issue with:

```markdown
**Environment:**
- OS: macOS 13.5 / Ubuntu 22.04 / etc.
- Terminal: Ghostty 0.1.0 / Kitty 0.30.0 / etc.
- Zig version: (output of `zig version`)
- termweb version: (output of `termweb --version`)

**Doctor Output:**
```
[paste output of `termweb doctor`]
```

**Steps to Reproduce:**
1. Run `termweb open https://example.com`
2. Press 'f'
3. Press Tab
4. Observe error

**Expected:**
Should cycle to next element

**Actual:**
Crash with error: ...

**Additional Context:**
- Only happens on certain websites
- Works fine with other URLs
```

### Where to Get Help

- **GitHub Issues** - Bug reports and feature requests
- **GitHub Discussions** - Questions and help
- **Documentation** - Check all docs first:
  - [Installation](INSTALLATION.md)
  - [Usage](USAGE.md)
  - [Keybindings](KEYBINDINGS.md)
  - [Architecture](ARCHITECTURE.md)
  - [Contributing](CONTRIBUTING.md)

### Known Limitations

Some issues are known limitations (not bugs):

- No mouse support
- No horizontal scrolling
- Can't interact with JavaScript-rendered custom widgets
- 3-second page load delay (hard-coded)
- No clipboard support

See [USAGE.md - Limitations](USAGE.md#limitations-and-known-issues) for full list.

---

If none of these solutions work, please open an issue with full debug output!
