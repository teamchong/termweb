# Installation Guide

This guide will help you install and set up termweb on your system.

## Prerequisites

### Required Dependencies

1. **Zig 0.15.2 or later** - Programming language and build system
2. **Chrome or Chromium** - Web rendering engine
3. **Kitty Graphics Protocol-compatible terminal** - For image display

### Supported Terminals

termweb requires a terminal that supports the Kitty graphics protocol:

- **[Ghostty](https://ghostty.org/)** (Recommended) - Fast, native terminal with excellent Kitty graphics support
- **[Kitty](https://sw.kovidgoyal.net/kitty/)** - The original terminal with Kitty graphics protocol
- **[WezTerm](https://wezfurlong.org/wezterm/)** - Cross-platform terminal with Kitty graphics support

### Supported Operating Systems

- **macOS** - Fully tested
- **Linux** - Should work (tested on Ubuntu/Debian)
- **Windows** - Not yet tested

## Installing Zig

### macOS

Using Homebrew:
```bash
brew install zig
```

Or download from [ziglang.org](https://ziglang.org/download/):
```bash
# Download and extract
curl -LO https://ziglang.org/download/0.15.2/zig-macos-aarch64-0.15.2.tar.xz
tar -xf zig-macos-aarch64-0.15.2.tar.xz
sudo mv zig-macos-aarch64-0.15.2 /usr/local/zig

# Add to PATH in ~/.zshrc or ~/.bash_profile
export PATH="/usr/local/zig:$PATH"
```

### Linux

Download from [ziglang.org](https://ziglang.org/download/):
```bash
# Download and extract (adjust architecture as needed)
wget https://ziglang.org/download/0.15.2/zig-linux-x86_64-0.15.2.tar.xz
tar -xf zig-linux-x86_64-0.15.2.tar.xz
sudo mv zig-linux-x86_64-0.15.2 /usr/local/zig

# Add to PATH in ~/.bashrc
export PATH="/usr/local/zig:$PATH"
```

### Verify Zig Installation

```bash
zig version
# Should output: 0.15.2 or later
```

## Installing Chrome/Chromium

### macOS

Download from [google.com/chrome](https://www.google.com/chrome/) or use Homebrew:
```bash
brew install --cask google-chrome
```

### Linux

#### Ubuntu/Debian
```bash
wget https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
sudo dpkg -i google-chrome-stable_current_amd64.deb
sudo apt-get install -f
```

#### Fedora/RHEL
```bash
sudo dnf install google-chrome-stable
```

#### Chromium (alternative)
```bash
# Ubuntu/Debian
sudo apt-get install chromium-browser

# Fedora
sudo dnf install chromium
```

### Setting CHROME_BIN (Optional)

If Chrome is installed in a non-standard location, set the `CHROME_BIN` environment variable:
```bash
export CHROME_BIN=/path/to/chrome
```

Add this to your `~/.zshrc` or `~/.bashrc` to make it permanent.

## Installing a Compatible Terminal

### Ghostty (Recommended)

Download from [ghostty.org](https://ghostty.org/)

macOS:
```bash
# Download the .dmg from the website and install
# Or if available via Homebrew:
brew install --cask ghostty
```

### Kitty

macOS:
```bash
brew install --cask kitty
```

Linux:
```bash
# Ubuntu/Debian
sudo apt-get install kitty

# Fedora
sudo dnf install kitty
```

### WezTerm

Download from [wezfurlong.org/wezterm](https://wezfurlong.org/wezterm/)

macOS:
```bash
brew install --cask wezterm
```

Linux:
```bash
# See installation instructions at wezfurlong.org/wezterm/install
```

## Building termweb from Source

### 1. Clone the Repository

```bash
git clone https://github.com/yourusername/termweb.git
cd termweb
```

### 2. Build

```bash
zig build
```

The binary will be created at `./zig-out/bin/termweb`.

### 3. Run Tests (Optional)

```bash
zig build test
```

### 4. Install Binary (Optional)

Copy the binary to a location in your PATH:

```bash
sudo cp ./zig-out/bin/termweb /usr/local/bin/
```

Or add the zig-out/bin directory to your PATH:
```bash
# Add to ~/.zshrc or ~/.bashrc
export PATH="/path/to/termweb/zig-out/bin:$PATH"
```

## Verifying Installation

### Run the Doctor Command

The `doctor` command checks your system capabilities:

```bash
termweb doctor
```

Expected output if everything is set up correctly:
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

### Version Check

```bash
termweb --version
# Should output: termweb version 0.6.0
```

### Test with a Simple URL

```bash
termweb open https://example.com
```

You should see:
1. Chrome launching in the background
2. The example.com page rendered in your terminal
3. A status bar at the bottom with keyboard shortcuts

Press `q` to quit.

## Troubleshooting Installation

### Zig Build Fails

**Error: `zig version mismatch`**
- Make sure you have Zig 0.15.2 or later installed
- Run `zig version` to verify

**Error: `unable to find zig`**
- Ensure Zig is in your PATH
- Run `which zig` to verify the installation

### Chrome Not Detected

**Error: `Chrome not found`**

1. Verify Chrome is installed:
   ```bash
   # macOS
   ls "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

   # Linux
   which google-chrome
   ```

2. Set CHROME_BIN if installed in custom location:
   ```bash
   export CHROME_BIN=/path/to/chrome
   ```

3. Try Chromium instead:
   ```bash
   export CHROME_BIN=/usr/bin/chromium-browser
   ```

### Terminal Not Supported

**Error: `Kitty Graphics Protocol not detected`**

Your terminal doesn't support the Kitty graphics protocol. You must use one of:
- Ghostty
- Kitty
- WezTerm

To verify your terminal:
```bash
echo $TERM_PROGRAM
# Should output: ghostty, kitty, or WezTerm
```

### Permission Errors

**Error: `Permission denied when launching Chrome`**

Give Chrome executable permissions:
```bash
# macOS
chmod +x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# Linux
chmod +x /usr/bin/google-chrome
```

### Port Already in Use

**Error: `Cannot start Chrome debugger on port 9222`**

Kill existing Chrome processes:
```bash
# macOS
pkill -f "Chrome.*--remote-debugging-port"

# Linux
pkill -f "chrome.*--remote-debugging-port"
```

## Next Steps

Once installation is complete:

1. Try `termweb open https://example.com` to test
2. Use mouse to click links and toolbar buttons
3. If you encounter issues, see [Troubleshooting](TROUBLESHOOTING.md)

## Updating termweb

To update to the latest version:

```bash
cd termweb
git pull origin main
zig build
```

## Uninstalling

To remove termweb:

```bash
# Remove binary
sudo rm /usr/local/bin/termweb

# Remove source directory
rm -rf /path/to/termweb
```

## Getting Help

- Check the [Troubleshooting Guide](TROUBLESHOOTING.md)
- Run `termweb doctor` to diagnose system issues
- File an issue on GitHub with `termweb doctor` output
