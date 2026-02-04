# Termweb Makefile

.PHONY: all build run test clean gen-ui mux mux-web mux-native mux-deps mux-clean vendor-reset vendor-patch vendor-sync vendor-build-ghostty vendor-generate-patch

# Default: build everything (JS must be bundled before Zig embeds it)
all: build-all

# Build main termweb CLI (requires mux-web first for embedding)
build: vendor-sync mux-web
	zig build

# Run main termweb CLI
run:
	zig build run -- $(ARGS)

# Run tests
test:
	zig build test

# Clean build artifacts
clean:
	rm -rf zig-out zig-cache

# =============================================================================
# Mux Package (terminal multiplexer for browser)
# =============================================================================

# Build mux: web client first, then native binary
mux: mux-web mux-native

# Install mux web dependencies (bun packages)
mux-deps:
	@echo "Installing mux web dependencies..."
	cd packages/mux/web && bun install

# Build mux web client (TypeScript -> bundled JS)
# Requires: bun (https://bun.sh)
# Note: Uses fzstd (pure JS) for zstd decompression in browser
mux-web: mux-deps
	@echo "Building mux web client..."
	cd packages/mux/web && bun run build
	@# Touch assets.zig to force zig to re-embed (zig doesn't detect @embedFile changes)
	@touch packages/mux/web/assets.zig
	@echo "Web client built: packages/mux/web/client.js"

# Build mux web client in dev mode (unminified, with sourcemaps)
mux-web-dev: mux-deps
	@echo "Building mux web client (dev)..."
	cd packages/mux/web && bun run build:dev

# Watch mux web client for changes (development)
mux-web-watch: mux-deps
	@echo "Watching mux web client..."
	cd packages/mux/web && bun run dev

# Build mux native binary (macOS only - requires ghostty, VideoToolbox)
# Note: On Linux, this will be skipped by zig build
mux-native:
	@echo "Building mux native binary..."
	zig build
	@if [ -f zig-out/bin/termweb-mux ]; then \
		echo "Mux binary built: zig-out/bin/termweb-mux"; \
	else \
		echo "Note: termweb-mux is only built on macOS"; \
	fi

# Run mux server
mux-run:
	zig build mux -- $(ARGS)

# Clean mux build artifacts
mux-clean:
	rm -f packages/mux/web/client.js
	rm -rf packages/mux/native/zig-out packages/mux/native/zig-cache

# =============================================================================
# Vendor Management (submodules + patches)
# =============================================================================

# Upstream commit for ghostty (BEFORE our patches)
# IMPORTANT: This must be an upstream commit, NOT a local patch commit
GHOSTTY_UPSTREAM_COMMIT := 1b7a15899

# Reset all submodules to pinned commits
vendor-reset:
	@echo "Resetting vendor submodules..."
	git submodule update --init --recursive --force
	@echo "Checking out ghostty upstream commit $(GHOSTTY_UPSTREAM_COMMIT)..."
	cd vendor/ghostty && git checkout $(GHOSTTY_UPSTREAM_COMMIT) && git clean -fd

# Apply patches to vendor submodules
vendor-patch:
	@echo "Applying patches to vendor/ghostty..."
	@for patch in patches/ghostty/*.patch; do \
		if [ -f "$$patch" ]; then \
			echo "Applying $$patch..."; \
			cd vendor/ghostty && git apply "../../$$patch" && cd ../..; \
		fi \
	done
	@echo "Patches applied."

# Full vendor sync: reset + patch
vendor-sync: vendor-reset vendor-patch
	@echo "Vendor sync complete."

# Build libghostty from patched source (Linux)
vendor-build-ghostty:
	@echo "Building libghostty..."
	cd vendor/ghostty && zig build -Doptimize=ReleaseFast -Dapp-runtime=none
	@echo "libghostty built."

# Detect platform for library paths
UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)
ifeq ($(UNAME_S),Darwin)
    ifeq ($(UNAME_M),arm64)
        LIBGHOSTTY_DIR := vendor/libs/darwin-arm64
    else
        LIBGHOSTTY_DIR := vendor/libs/darwin-x86_64
    endif
else
    ifeq ($(UNAME_M),aarch64)
        LIBGHOSTTY_DIR := vendor/libs/linux-aarch64
    else
        LIBGHOSTTY_DIR := vendor/libs/linux-x86_64
    endif
endif

# Generate patch from current vendor changes (use after editing vendor files)
# Usage: edit vendor/ghostty files, then run `make vendor-generate-patch`
# This generates a unified diff patch (no commits needed)
# After generating, it syncs, rebuilds libghostty.a, and copies to platform-specific dir
vendor-generate-patch:
	@echo "Generating patch from changes in vendor/ghostty (since $(GHOSTTY_UPSTREAM_COMMIT))..."
	@cd vendor/ghostty && \
		git add -A && \
		git diff --cached $(GHOSTTY_UPSTREAM_COMMIT) > ../../patches/ghostty/001-linux-egl-headless.patch && \
		git reset HEAD
	@echo "Patch saved to patches/ghostty/001-linux-egl-headless.patch"
	@echo ""
	@echo "Syncing vendor and rebuilding libghostty.a..."
	@$(MAKE) vendor-sync
	@$(MAKE) vendor-build-ghostty
	@mkdir -p $(LIBGHOSTTY_DIR)
	@cp vendor/ghostty/zig-out/lib/libghostty.a $(LIBGHOSTTY_DIR)/
	@echo ""
	@echo "Done! Library updated at $(LIBGHOSTTY_DIR)/libghostty.a"
	@echo "Now run 'zig build' to build with the updated library."

# =============================================================================
# UI Asset Generation
# =============================================================================

# Generate UI assets from HTML templates using Chrome headless
# Requires: Google Chrome installed
gen-ui:
	@echo "Generating UI assets..."
	@mkdir -p assets/dark assets/light
	@./tools/gen-ui.sh
	@echo "Done! Assets saved to assets/"

# =============================================================================
# Development Helpers
# =============================================================================

# Full clean (all packages)
clean-all: clean mux-clean
	rm -rf node_modules packages/*/node_modules

# Install all dependencies
deps: mux-deps
	@echo "All dependencies installed"

# Build everything (build already includes mux-web)
build-all: build

# Type check mux web client
mux-typecheck:
	cd packages/mux/web && bun run typecheck

# =============================================================================
# Help
# =============================================================================

help:
	@echo "Termweb Makefile"
	@echo ""
	@echo "Main targets:"
	@echo "  make build        - Build main termweb CLI"
	@echo "  make run          - Run termweb CLI"
	@echo "  make test         - Run tests"
	@echo "  make clean        - Clean build artifacts"
	@echo ""
	@echo "Mux package (terminal multiplexer):"
	@echo "  make mux          - Build mux (web + native)"
	@echo "  make mux-deps     - Install mux dependencies (bun packages)"
	@echo "  make mux-web      - Build mux web client only"
	@echo "  make mux-web-dev  - Build mux web client (dev mode)"
	@echo "  make mux-web-watch- Watch mux web client for changes"
	@echo "  make mux-native   - Build mux native binary"
	@echo "  make mux-run      - Run mux server"
	@echo "  make mux-clean    - Clean mux build artifacts"
	@echo ""
	@echo "Vendor management:"
	@echo "  make vendor-sync  - Reset submodules and apply patches"
	@echo "  make vendor-generate-patch - Generate patch, rebuild lib, and copy to vendor/libs/"
	@echo "  make vendor-build-ghostty - Build libghostty from source only"
	@echo ""
	@echo "Other targets:"
	@echo "  make gen-ui       - Generate UI assets from templates"
	@echo "  make deps         - Install all dependencies"
	@echo "  make build-all    - Build everything"
	@echo "  make clean-all    - Clean all build artifacts"
	@echo ""
	@echo "Variables:"
	@echo "  ARGS=...          - Arguments to pass to run targets"
