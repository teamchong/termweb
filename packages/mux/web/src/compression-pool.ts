// zstd WASM compression wrapper — initializes on first use

import { initZstd, compressZstd, decompressZstd } from './zstd-wasm';

class CompressionPool {
  private initPromise: Promise<void>;

  constructor() {
    this.initPromise = initZstd();
  }

  async compress(data: Uint8Array, level = 3): Promise<Uint8Array> {
    await this.initPromise;
    return compressZstd(data, level);
  }

  async decompress(data: Uint8Array): Promise<Uint8Array> {
    await this.initPromise;
    return decompressZstd(data);
  }
}

let defaultPool: CompressionPool | null = null;

export function getCompressionPool(): CompressionPool {
  if (!defaultPool) {
    defaultPool = new CompressionPool();
  }
  return defaultPool;
}
