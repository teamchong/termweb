# Termweb Makefile

.PHONY: all build run test clean gen-ui mux mux-web mux-native mux-deps mux-clean

# Default: build everything (JS must be bundled before Zig embeds it)
all: build-all

# Build main termweb CLI (requires mux-web first for embedding)
build: mux-web
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
mux-web: mux-deps
	@echo "Building mux web client..."
	cd packages/mux/web && bun run build
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
	@echo "  make mux-native   - Build mux native binary (macOS only)"
	@echo "  make mux-run      - Run mux server"
	@echo "  make mux-clean    - Clean mux build artifacts"
	@echo ""
	@echo "Other targets:"
	@echo "  make gen-ui       - Generate UI assets from templates"
	@echo "  make deps         - Install all dependencies"
	@echo "  make build-all    - Build everything"
	@echo "  make clean-all    - Clean all build artifacts"
	@echo ""
	@echo "Variables:"
	@echo "  ARGS=...          - Arguments to pass to run targets"
