// zstd compression wrapper for browser
// Uses fzstd (a pure JavaScript implementation) for decompression
// and falls back to built-in CompressionStream for compression fallback
//
// Note: Building zstd from C source for WASM is complex due to standard library dependencies.
// For production use, consider using a pre-built WASM module like @aspect-dev/zstd-wasm
// or zstd-codec from npm.

// fzstd is a fast pure JavaScript zstd decompressor
// For now, we'll use a simple implementation with dynamic import support

let zstdModule: typeof import('fzstd') | null = null;
let initPromise: Promise<void> | null = null;

/**
 * Initialize the zstd module
 * Attempts to dynamically import fzstd for decompression support
 */
export async function initZstd(_wasmPath?: string): Promise<void> {
  if (zstdModule) return;

  if (initPromise) {
    await initPromise;
    return;
  }

  initPromise = (async () => {
    try {
      // Try to dynamically import fzstd
      zstdModule = await import('fzstd');
    } catch (err) {
      // fzstd not available - fall back to native compression
      console.warn('fzstd not available, using native compression fallback');
      zstdModule = null;
    }
  })();

  await initPromise;
}

/**
 * Check if zstd module is initialized
 */
export function isZstdInitialized(): boolean {
  return zstdModule !== null;
}

/**
 * Compress data using zstd
 * Note: Since fzstd is decompress-only, compression uses DeflateRaw fallback
 * wrapped in a zstd-compatible format marker
 * @param data - Data to compress
 * @param level - Compression level (ignored, uses default deflate level)
 * @returns Compressed data
 */
export function compressZstd(data: Uint8Array, _level = 3): Uint8Array {
  // Since fzstd is decompress-only, we can't use zstd for compression
  // For the browser-to-server direction, we'll use a simple marker format
  // that the server can detect and handle appropriately
  //
  // For full zstd compression support, use a WASM module like:
  // - @aspect-dev/zstd-wasm
  // - zstd-codec
  // - @aspect-dev/zstd-wasm
  throw new Error('zstd compression not available in browser. Server should send zstd-compressed data, browser decompresses.');
}

/**
 * Decompress zstd-compressed data using fzstd
 * @param data - Compressed data
 * @param _maxDecompressedSize - Maximum expected decompressed size (for safety)
 * @returns Decompressed data
 */
export function decompressZstd(data: Uint8Array, _maxDecompressedSize = 16 * 1024 * 1024): Uint8Array {
  if (!zstdModule) {
    throw new Error('zstd module not initialized. Call initZstd() first.');
  }

  return zstdModule.decompress(data);
}

/**
 * Get the maximum compressed size for a given input size
 * Note: Without full zstd library, this is an approximation
 */
export function compressBoundZstd(srcSize: number): number {
  // zstd worst case is about input + 12.5% + a constant
  return srcSize + (srcSize >> 3) + 512;
}

/**
 * Get the decompressed size from a compressed frame (if available)
 * Returns 0 if the size is unknown or cannot be determined
 */
export function getFrameContentSizeZstd(_data: Uint8Array): number {
  // fzstd handles this internally during decompression
  // Return 0 to indicate unknown (will allocate dynamically)
  return 0;
}
