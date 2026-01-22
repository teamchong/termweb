# Contributing to termweb

Thank you for your interest in contributing to termweb! This guide will help you get started with development and submitting contributions.

## Table of Contents

- [Welcome](#welcome)
- [Development Setup](#development-setup)
- [Development Workflow](#development-workflow)
- [Code Style](#code-style)
- [Areas for Contribution](#areas-for-contribution)
- [Version Management](#version-management)
- [Pull Request Process](#pull-request-process)
- [Getting Help](#getting-help)

## Welcome

### Types of Contributions

We welcome many types of contributions:

- **Bug fixes** - Fix issues reported in GitHub issues
- **New features** - Implement features from the roadmap
- **Documentation** - Improve guides, fix typos, add examples
- **Tests** - Add unit tests or integration tests
- **Performance** - Optimize slow code paths
- **Platform support** - Test and fix issues on Linux/Windows
- **Refactoring** - Improve code quality and maintainability

### Code of Conduct

- Be respectful and constructive
- Focus on technical merit
- Help newcomers learn
- Keep discussions on-topic

## Development Setup

### Prerequisites

See [INSTALLATION.md](INSTALLATION.md) for full prerequisites. You'll need:

- Zig 0.15.2+
- Chrome/Chromium
- Supported terminal (Ghostty, Kitty, WezTerm)
- Git

### Forking and Cloning

1. **Fork the repository** on GitHub

2. **Clone your fork:**
   ```bash
   git clone https://github.com/YOUR_USERNAME/termweb.git
   cd termweb
   ```

3. **Add upstream remote:**
   ```bash
   git remote add upstream https://github.com/ORIGINAL_OWNER/termweb.git
   ```

### Building

```bash
# Build the project
zig build

# Binary will be at ./zig-out/bin/termweb
```

### Running

```bash
# Run directly
./zig-out/bin/termweb open https://example.com

# Or use zig build run
zig build run -- open https://example.com
```

### Testing

```bash
# Run all tests
zig build test

# Run with output
zig build test 2>&1 | less
```

### Code Organization

Quick overview of the codebase:

- `src/main.zig` - Entry point
- `src/cli.zig` - Command-line interface
- `src/viewer.zig` - Main event loop and mode management
- `src/chrome/` - Browser automation (CDP, WebSocket, screencast, etc.)
- `src/terminal/` - Terminal I/O (Kitty graphics, input, screen control)
- `src/ui/` - UI components (toolbar, tabs, native dialogs)
- `vendor/` - Third-party dependencies

## Development Workflow

### Making Changes

1. **Create a feature branch:**
   ```bash
   git checkout -b feature/my-new-feature
   # or
   git checkout -b fix/issue-123
   ```

2. **Make your changes:**
   - Edit code
   - Add/update tests
   - Update documentation if needed

3. **Test your changes:**
   ```bash
   # Build
   zig build

   # Run tests
   zig build test

   # Manual testing
   ./zig-out/bin/termweb open https://example.com
   ```

4. **Commit your changes:**
   ```bash
   git add .
   git commit -m "feat: add support for Shift+Tab in form mode"
   ```

5. **Push to your fork:**
   ```bash
   git push origin feature/my-new-feature
   ```

6. **Create a Pull Request** on GitHub

### Keeping Your Fork Updated

```bash
# Fetch latest changes from upstream
git fetch upstream

# Merge into your main branch
git checkout main
git merge upstream/main

# Update your feature branch (optional)
git checkout feature/my-new-feature
git rebase main
```

### Commit Message Format

Use conventional commits format:

```
<type>: <description>

[optional body]

[optional footer]
```

**Types:**
- `feat:` - New feature
- `fix:` - Bug fix
- `docs:` - Documentation changes
- `style:` - Code style changes (formatting, no logic change)
- `refactor:` - Code refactoring
- `test:` - Adding or updating tests
- `chore:` - Maintenance tasks (dependencies, build, etc.)

**Examples:**
```
feat: add Shift+Tab for previous element navigation

Implements backward navigation in form mode using Shift+Tab.
Updates status bar to show both Tab and Shift+Tab hints.

Closes #42
```

```
fix: prevent crash when no form elements found

When pressing 'f' on a page with no interactive elements,
the viewer would crash. Now displays "No elements" message.

Fixes #58
```

```
docs: update KEYBINDINGS.md with new shortcuts

Added Shift+Tab documentation.
Fixed typo in URL prompt section.
```

## Code Style

### Zig Style Guidelines

Follow standard Zig conventions:

**Formatting:**
```bash
# Format your code before committing
zig fmt src/
```

**Naming conventions:**
- `snake_case` for functions and variables
- `PascalCase` for types/structs
- `SCREAMING_SNAKE_CASE` for constants
- No Hungarian notation

**Example:**
```zig
const MAX_ELEMENTS = 100;  // Constant

pub const FormContext = struct {  // Type
    allocator: std.mem.Allocator,  // Field
    current_index: usize,  // Field

    pub fn init(allocator: std.mem.Allocator) FormContext {  // Function
        return .{
            .allocator = allocator,
            .current_index = 0,
        };
    }

    pub fn nextElement(self: *FormContext) void {  // Method
        self.current_index += 1;
    }
};
```

### Error Handling

Use Zig's error union types:

```zig
// Return errors explicitly
pub fn doSomething() !void {
    if (condition) return error.SomethingFailed;
    try otherFunction();  // Propagate errors
}

// Handle errors at appropriate level
doSomething() catch |err| {
    std.debug.print("Error: {}\n", .{err});
    return;
};
```

### Memory Management

Always pair allocations with deallocations:

```zig
pub fn example(allocator: std.mem.Allocator) !void {
    const buffer = try allocator.alloc(u8, 100);
    defer allocator.free(buffer);  // Always defer cleanup

    // Use buffer...
}
```

### Documentation

Add docstrings for public functions:

```zig
/// Captures a screenshot from the current browser page.
///
/// Returns base64-encoded PNG data that must be freed by the caller.
///
/// Errors:
/// - error.ConnectionFailed if CDP connection is lost
/// - error.InvalidResponse if Chrome returns malformed data
pub fn captureScreenshot(
    client: *CdpClient,
    allocator: std.mem.Allocator,
    options: CaptureOptions,
) ![]const u8 {
    // Implementation...
}
```

**When to add comments:**
- Public APIs (always)
- Complex algorithms (explain the "why")
- Workarounds or hacks (explain why it's needed)
- Protocol-specific details (CDP, Kitty graphics)

**When NOT to add comments:**
- Obvious code (let the code speak)
- Repeating function names
- Commented-out code (delete it, use git history)

## Areas for Contribution

### High Priority

These contributions would have immediate impact:

1. **Windows Support** ([Issue #X])
   - Test on Windows
   - Fix path handling
   - Fix terminal detection
   - Update documentation

2. **CI/CD Pipeline** ([Issue #Y])
   - GitHub Actions for builds
   - Automated testing
   - Release artifact generation

3. **Comprehensive Tests** ([Issue #Z])
   - Unit tests for CDP client
   - Integration tests for viewer modes
   - Form interaction tests

4. **Performance Optimization**
   - Async CDP event loop
   - Faster screenshot capture
   - Reduce memory allocations

5. **Better Page Load Detection**
   - Use `Page.loadEventFired` instead of 3-second delay
   - Show loading indicator
   - Handle timeouts gracefully

### Medium Priority

Useful features that enhance usability:

1. **Additional Scroll Modes**
   - `gg` - Go to top
   - `G` - Go to bottom
   - `Ctrl+F` / `Ctrl+B` - Forward/backward full page

2. **Better Form Handling**
   - `Shift+Tab` for previous element
   - Arrow keys within select dropdowns
   - Multi-line textarea editing

3. **JavaScript Execution**
   - Execute custom JavaScript on page
   - Helpful for debugging or automation

4. **Search Mode** (`/`)
   - Search within page
   - Highlight matches
   - Navigate between matches

5. **Browser History View**
   - Show list of visited URLs
   - Navigate history with j/k
   - Jump to specific history entry

### Low Priority

Nice-to-have features for the future:

1. **Theming Support**
   - Custom status bar colors
   - Terminal color scheme integration

2. **Configuration Files**
   - `~/.termwebrc` for preferences
   - Custom keybindings
   - Default zoom level

3. **Plugins/Extensions**
   - Custom commands
   - Protocol handlers
   - Scripting support

4. **Bookmarks**
   - Save favorite URLs
   - Organize into folders
   - Quick access with keyboard

## Version Management

termweb follows semantic versioning: `MAJOR.MINOR.PATCH`

- **MAJOR** - Breaking changes
- **MINOR** - New features (backwards compatible)
- **PATCH** - Bug fixes

### Release Process

1. **Update Version**
   - Edit `src/cli.zig` line 10: `const VERSION = "X.Y.Z";`
   - Update README.md milestone status

2. **Update CHANGELOG.md**
   - Document all changes since last release
   - Group by Added, Changed, Fixed, Removed
   - Follow "Keep a Changelog" format

3. **Commit**
   ```bash
   git add src/cli.zig README.md CHANGELOG.md
   git commit -m "chore: bump version to X.Y.Z"
   ```

4. **Tag**
   ```bash
   git tag -a vX.Y.Z -m "Release vX.Y.Z - Description"
   ```

5. **Push**
   ```bash
   git push origin main
   git push origin vX.Y.Z
   ```

6. **Create GitHub Release** (if using GitHub)
   - Draft new release
   - Select tag vX.Y.Z
   - Copy CHANGELOG entry as description
   - Attach binary artifacts

### Milestone Versions

- **M0:** v0.1.0 - Project skeleton
- **M1:** v0.2.0 - Static render viewer
- **M2:** v0.3.0 - WebSocket CDP + Navigation
- **M3:** v0.4.0 - Scroll support
- **M4:** v0.5.0 - Interactive inputs
- **M5:** v0.6.0 - Packaging + documentation
- **M6+:** Future milestones (tabs, search, etc.)

## Pull Request Process

### Before Submitting

- [ ] Code builds without errors (`zig build`)
- [ ] Tests pass (`zig build test`)
- [ ] Code is formatted (`zig fmt src/`)
- [ ] Documentation updated (if adding features)
- [ ] Commit messages follow conventional commits format
- [ ] Changes are focused (one feature/fix per PR)

### Creating a Pull Request

1. **Title:** Use conventional commits format
   ```
   feat: add Shift+Tab navigation
   fix: prevent crash on empty forms
   docs: update installation guide
   ```

2. **Description:** Include:
   - What changes were made
   - Why the changes were needed
   - How to test the changes
   - Screenshots (if UI changes)
   - Related issues (`Fixes #123`)

3. **Example PR template:**
   ```markdown
   ## Changes
   - Added Shift+Tab support for backward navigation in form mode
   - Updated status bar to show Shift+Tab hint
   - Added test case for prev() function

   ## Why
   Users requested the ability to go backward through form elements
   without cycling all the way around.

   ## Testing
   1. Build with `zig build`
   2. Run `termweb open https://example.com/form`
   3. Press 'f' to enter form mode
   4. Press Tab to advance, Shift+Tab to go back
   5. Verify current element decrements

   ## Closes
   Fixes #42
   ```

### Review Process

1. Maintainers will review your PR
2. Address any requested changes
3. Once approved, PR will be merged
4. Your contribution will be included in the next release

### Merge Criteria

PRs are merged when:
- ✓ Code builds and tests pass
- ✓ Code follows style guidelines
- ✓ Changes are focused and well-documented
- ✓ No merge conflicts with main branch
- ✓ At least one maintainer approval

## Getting Help

### Questions

- **General questions:** Open a GitHub Discussion
- **Bug reports:** Open a GitHub Issue with `bug` label
- **Feature requests:** Open a GitHub Issue with `enhancement` label
- **Security issues:** Email maintainers directly (do not open public issue)

### Resources

- [Troubleshooting](TROUBLESHOOTING.md) - Debug common issues
- [Zig Documentation](https://ziglang.org/documentation/) - Learn Zig
- [Chrome DevTools Protocol](https://chromedevtools.github.io/devtools-protocol/) - CDP reference

### Finding Issues to Work On

Look for issues labeled:
- `good first issue` - Good for newcomers
- `help wanted` - Maintainers need help
- `bug` - Something is broken
- `enhancement` - New feature request

### Communication

Be patient and respectful:
- Maintainers are volunteers
- Response times may vary
- Clear, detailed questions get better answers
- Code speaks louder than words (PRs > discussions)

## License

By contributing, you agree that your contributions will be licensed under the MIT License.

---

Thank you for contributing to termweb! 🎉
