#!/bin/bash
# Build termweb binaries for all supported platforms
# Output: binaries/termweb-{platform}-{arch}

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BINARIES_DIR="$PROJECT_DIR/binaries"

# Clean and create binaries directory
rm -rf "$BINARIES_DIR"
mkdir -p "$BINARIES_DIR"

cd "$PROJECT_DIR"

# Build targets: zig target -> output name
declare -A TARGETS=(
  ["aarch64-macos"]="termweb-macos-aarch64"
  ["x86_64-macos"]="termweb-macos-x86_64"
  ["x86_64-linux-gnu"]="termweb-linux-x86_64"
  ["aarch64-linux-gnu"]="termweb-linux-aarch64"
)

echo "Building termweb for all platforms..."
echo ""

for target in "${!TARGETS[@]}"; do
  output_name="${TARGETS[$target]}"
  echo "Building for $target -> $output_name"

  zig build -Dtarget="$target" -Doptimize=ReleaseFast

  # Copy binary to binaries directory
  cp "zig-out/bin/termweb" "$BINARIES_DIR/$output_name"

  echo "  Done: $BINARIES_DIR/$output_name"
done

echo ""
echo "All builds complete!"
echo ""
ls -lh "$BINARIES_DIR"
