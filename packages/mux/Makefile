.PHONY: build web zig clean

build: web zig

web:
	cd web && bun run build

zig:
	cd native && zig build

clean:
	rm -f web/client.js
	rm -rf native/zig-out native/zig-cache
