// zstd compression/decompression via Zig WASM module
// Both compress and decompress are available (no JS fallback needed)

interface ZstdExports {
  memory: WebAssembly.Memory;
  zstd_alloc(size: number): number;
  zstd_free(ptr: number, size: number): void;
  zstd_compress(dst: number, dstCap: number, src: number, srcSize: number, level: number): number;
  zstd_decompress(dst: number, dstCap: number, src: number, srcSize: number): number;
  zstd_compress_bound(srcSize: number): number;
  zstd_frame_content_size(src: number, srcSize: number): number;
}

let wasm: ZstdExports | null = null;
let initPromise: Promise<void> | null = null;

/**
 * Initialize the zstd WASM module.
 * Loads zstd.wasm from the server and instantiates it.
 */
export async function initZstd(wasmPath = '/zstd.wasm'): Promise<void> {
  if (wasm) return;

  if (initPromise) {
    await initPromise;
    return;
  }

  initPromise = (async () => {
    try {
      const response = await fetch(wasmPath);
      const bytes = await response.arrayBuffer();
      const { instance } = await WebAssembly.instantiate(bytes, {
        wasi_snapshot_preview1: {
          // Stubs for WASI imports (zstd doesn't use I/O)
          fd_write: () => 0,
          fd_close: () => 0,
          fd_seek: () => 0,
          proc_exit: () => {},
        },
      });
      wasm = instance.exports as unknown as ZstdExports;
    } catch (err) {
      // Reset so a retry is possible
      initPromise = null;
      throw err;
    }
  })();

  await initPromise;
}

/**
 * Compress data using zstd WASM
 */
export function compressZstd(data: Uint8Array, level = 3): Uint8Array {
  if (!wasm) throw new Error('zstd WASM not initialized. Call initZstd() first.');

  const srcSize = data.length;
  const dstCap = wasm.zstd_compress_bound(srcSize);

  const srcPtr = wasm.zstd_alloc(srcSize);
  const dstPtr = wasm.zstd_alloc(dstCap);
  if (srcPtr === 0 || dstPtr === 0) {
    if (srcPtr) wasm.zstd_free(srcPtr, srcSize);
    if (dstPtr) wasm.zstd_free(dstPtr, dstCap);
    throw new Error('zstd WASM alloc failed');
  }

  try {
    new Uint8Array(wasm.memory.buffer, srcPtr, srcSize).set(data);
    const compressedSize = wasm.zstd_compress(dstPtr, dstCap, srcPtr, srcSize, level);
    if (compressedSize === 0) throw new Error('zstd compression failed');
    return new Uint8Array(wasm.memory.buffer.slice(dstPtr, dstPtr + compressedSize));
  } finally {
    wasm.zstd_free(srcPtr, srcSize);
    wasm.zstd_free(dstPtr, dstCap);
  }
}

/**
 * Decompress zstd-compressed data using WASM
 */
export function decompressZstd(data: Uint8Array, maxDecompressedSize = 16 * 1024 * 1024): Uint8Array {
  if (!wasm) throw new Error('zstd WASM not initialized. Call initZstd() first.');

  const srcSize = data.length;

  // Try to get frame content size for precise allocation
  const srcPtr = wasm.zstd_alloc(srcSize);
  if (srcPtr === 0) throw new Error('zstd WASM alloc failed');

  new Uint8Array(wasm.memory.buffer, srcPtr, srcSize).set(data);

  let dstCap = wasm.zstd_frame_content_size(srcPtr, srcSize);
  if (dstCap === 0 || dstCap > maxDecompressedSize) {
    // Unknown size or too large - use conservative estimate
    dstCap = Math.min(srcSize * 8, maxDecompressedSize);
  }

  const dstPtr = wasm.zstd_alloc(dstCap);
  if (dstPtr === 0) {
    wasm.zstd_free(srcPtr, srcSize);
    throw new Error('zstd WASM alloc failed');
  }

  try {
    const decompressedSize = wasm.zstd_decompress(dstPtr, dstCap, srcPtr, srcSize);
    if (decompressedSize === 0) throw new Error('zstd decompression failed');
    return new Uint8Array(wasm.memory.buffer.slice(dstPtr, dstPtr + decompressedSize));
  } finally {
    wasm.zstd_free(srcPtr, srcSize);
    wasm.zstd_free(dstPtr, dstCap);
  }
}
