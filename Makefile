# Termweb Makefile

.PHONY: all build run test clean gen-ui

all: build

build:
	zig build

run:
	zig build run -- $(ARGS)

test:
	zig build test

clean:
	rm -rf zig-out zig-cache

# Generate UI assets from HTML templates using Chrome headless
# Requires: Google Chrome installed
gen-ui:
	@echo "Generating UI assets..."
	@mkdir -p assets/dark assets/light
	@./tools/gen-ui.sh
	@echo "Done! Assets saved to assets/"
