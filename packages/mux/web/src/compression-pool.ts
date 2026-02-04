// Compression Pool for zstd compression/decompression
// Uses fzstd (pure JS) for decompression and native deflate for compression
// Note: zstd compression in browser is not available without a full WASM module

import { initZstd, decompressZstd } from './zstd-wasm';

interface PendingRequest {
  resolve: (data: Uint8Array) => void;
  reject: (error: Error) => void;
}

/**
 * Compression pool using main thread
 * Uses zstd for decompression (via fzstd), deflate for compression
 */
export class CompressionPool {
  private destroyed = false;
  private initialized = false;
  private initPromise: Promise<void> | null = null;

  /**
   * Check if SharedArrayBuffer is available
   */
  static get sharedArrayBufferAvailable(): boolean {
    return typeof SharedArrayBuffer !== 'undefined';
  }

  /**
   * Create a new compression pool
   */
  constructor(_workerCount = 1, _workerUrl?: string) {
    // Initialize fzstd asynchronously
    this.initPromise = this.initialize();
  }

  private async initialize(): Promise<void> {
    if (this.initialized) return;

    try {
      await initZstd();
      this.initialized = true;
    } catch (err) {
      console.warn('Failed to initialize zstd, using deflate fallback:', err);
    }
  }

  /**
   * Compress data using native deflate
   * Note: zstd compression is not available in browser without full WASM module
   * Server will need to handle deflate-compressed data from browser
   * @param data - Data to compress
   * @param _level - Compression level (ignored, uses default deflate)
   * @returns Compressed data
   */
  async compress(data: Uint8Array, _level = 3): Promise<Uint8Array> {
    if (this.destroyed) {
      throw new Error('CompressionPool has been destroyed');
    }

    // Use native CompressionStream with deflate-raw
    const cs = new CompressionStream('deflate-raw');
    const writer = cs.writable.getWriter();
    const reader = cs.readable.getReader();

    try {
      writer.write(data as Uint8Array<ArrayBuffer>);
      await writer.close();

      const chunks: Uint8Array[] = [];
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        chunks.push(value);
      }

      const totalLength = chunks.reduce((acc, chunk) => acc + chunk.length, 0);
      const result = new Uint8Array(totalLength);
      let offset = 0;
      for (const chunk of chunks) {
        result.set(chunk, offset);
        offset += chunk.length;
      }
      return result;
    } finally {
      reader.releaseLock();
    }
  }

  /**
   * Decompress zstd-compressed data using fzstd
   * @param data - Compressed data
   * @returns Decompressed data
   */
  async decompress(data: Uint8Array): Promise<Uint8Array> {
    if (this.destroyed) {
      throw new Error('CompressionPool has been destroyed');
    }

    // Wait for initialization
    if (this.initPromise) {
      await this.initPromise;
    }

    // Try zstd decompression first
    if (this.initialized) {
      try {
        return decompressZstd(data);
      } catch (err) {
        // If zstd fails, try deflate fallback
        console.warn('zstd decompression failed, trying deflate fallback:', err);
      }
    }

    // Fallback to native DecompressionStream
    const ds = new DecompressionStream('deflate-raw');
    const writer = ds.writable.getWriter();
    const reader = ds.readable.getReader();

    try {
      writer.write(data as Uint8Array<ArrayBuffer>);
      await writer.close();

      const chunks: Uint8Array[] = [];
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        chunks.push(value);
      }

      const totalLength = chunks.reduce((acc, chunk) => acc + chunk.length, 0);
      const result = new Uint8Array(totalLength);
      let offset = 0;
      for (const chunk of chunks) {
        result.set(chunk, offset);
        offset += chunk.length;
      }
      return result;
    } finally {
      reader.releaseLock();
    }
  }

  /**
   * Compress data using SharedArrayBuffer (zero-copy)
   * Falls back to regular compress since we're using main thread
   */
  async compressShared(buffer: SharedArrayBuffer, offset: number, length: number, level = 3): Promise<Uint8Array> {
    const data = new Uint8Array(buffer, offset, length);
    return this.compress(data, level);
  }

  /**
   * Get the number of workers (always 0 for main-thread implementation)
   */
  get workerCount(): number {
    return 0;
  }

  /**
   * Get the number of ready workers
   */
  get readyWorkerCount(): number {
    return this.initialized ? 1 : 0;
  }

  /**
   * Get the number of busy workers
   */
  get busyWorkerCount(): number {
    return 0;
  }

  /**
   * Get the queue length
   */
  get queueLength(): number {
    return 0;
  }

  /**
   * Destroy the pool
   */
  destroy(): void {
    this.destroyed = true;
  }
}

// Singleton instance for convenience
let defaultPool: CompressionPool | null = null;

/**
 * Get the default compression pool (creates one if needed)
 */
export function getCompressionPool(): CompressionPool {
  if (!defaultPool) {
    defaultPool = new CompressionPool();
  }
  return defaultPool;
}

/**
 * Destroy the default compression pool
 */
export function destroyCompressionPool(): void {
  if (defaultPool) {
    defaultPool.destroy();
    defaultPool = null;
  }
}
