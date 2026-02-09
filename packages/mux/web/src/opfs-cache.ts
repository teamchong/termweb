// OPFS-backed file cache for delta sync
// Communicates with the file-transfer Worker which has sync OPFS access.
// Provides promise-based API for main thread callers.

export interface CachedFileMeta {
  size: number;
  mtime: number;
  hash: string;
}

export class OPFSCache {
  private worker: Worker;
  private pending = new Map<number, { resolve: (val: unknown) => void; reject: (err: Error) => void }>();
  private nextId = 0;
  private _available = false;

  constructor(worker: Worker, opfsAvailable: boolean) {
    this.worker = worker;
    this._available = opfsAvailable;
  }

  get available(): boolean {
    return this._available;
  }

  /** Store a file in the cache with metadata */
  putFile(serverPath: string, filePath: string, data: ArrayBuffer, metadata: CachedFileMeta): Promise<void> {
    if (!this._available) return Promise.resolve();
    return this.request('cache-put', { serverPath, filePath, data, metadata }, [data]) as Promise<void>;
  }

  /** Read a file from the cache */
  getFile(serverPath: string, filePath: string): Promise<ArrayBuffer> {
    return this.request('cache-get', { serverPath, filePath }) as Promise<ArrayBuffer>;
  }

  /** List all cached file metadata for a server path */
  listFiles(serverPath: string): Promise<Record<string, CachedFileMeta>> {
    return this.request('cache-list', { serverPath }) as Promise<Record<string, CachedFileMeta>>;
  }

  /** Remove a file from the cache */
  removeFile(serverPath: string, filePath: string): Promise<void> {
    return this.request('cache-remove', { serverPath, filePath }) as Promise<void>;
  }

  /** Compute block checksums for a cached file (for rsync delta sync) */
  computeBlockChecksums(
    serverPath: string,
    filePath: string,
    blockSize: number,
  ): Promise<{ rolling: Uint32Array; strong: BigUint64Array }> {
    return this.request('compute-checksums', { serverPath, filePath, blockSize }) as Promise<{
      rolling: Uint32Array;
      strong: BigUint64Array;
    }>;
  }

  /** Apply delta commands to a cached file, producing updated data */
  applyDelta(
    serverPath: string,
    filePath: string,
    deltaPayload: ArrayBuffer,
  ): Promise<ArrayBuffer> {
    return this.request('apply-delta', { serverPath, filePath, deltaPayload }, [deltaPayload]) as Promise<ArrayBuffer>;
  }

  /** Delete the entire cache directory */
  clearAll(): Promise<void> {
    if (!this._available) return Promise.resolve();
    return this.request('cache-clear-all', {}) as Promise<void>;
  }

  /** Get total cache disk usage */
  getUsage(): Promise<{ totalBytes: number; fileCount: number }> {
    if (!this._available) return Promise.resolve({ totalBytes: 0, fileCount: 0 });
    return this.request('cache-usage', {}) as Promise<{ totalBytes: number; fileCount: number }>;
  }

  /** Handle Worker response messages. Returns true if the message was a cache response. */
  handleWorkerMessage(msg: Record<string, unknown>): boolean {
    switch (msg.type) {
      case 'cache-put-done': {
        this.resolve(msg.id as number, undefined);
        return true;
      }
      case 'cache-file': {
        this.resolve(msg.id as number, msg.data);
        return true;
      }
      case 'cache-list-result': {
        this.resolve(msg.id as number, msg.files);
        return true;
      }
      case 'cache-remove-done': {
        this.resolve(msg.id as number, undefined);
        return true;
      }
      case 'checksums-computed': {
        this.resolve(msg.id as number, {
          rolling: new Uint32Array(msg.rolling as ArrayBuffer),
          strong: new BigUint64Array(msg.strong as ArrayBuffer),
        });
        return true;
      }
      case 'checksums-error': {
        this.reject(msg.id as number, new Error(msg.message as string));
        return true;
      }
      case 'delta-applied': {
        this.resolve(msg.id as number, msg.data);
        return true;
      }
      case 'delta-error': {
        this.reject(msg.id as number, new Error(msg.message as string));
        return true;
      }
      case 'cache-cleared': {
        this.resolve(msg.id as number, undefined);
        return true;
      }
      case 'cache-usage-result': {
        this.resolve(msg.id as number, { totalBytes: msg.totalBytes, fileCount: msg.fileCount });
        return true;
      }
      default:
        return false;
    }
  }

  private resolve(id: number, value: unknown): void {
    const p = this.pending.get(id);
    if (p) {
      this.pending.delete(id);
      p.resolve(value);
    }
  }

  private reject(id: number, error: Error): void {
    const p = this.pending.get(id);
    if (p) {
      this.pending.delete(id);
      p.reject(error);
    }
  }

  rejectAll(error: Error): void {
    for (const [, p] of this.pending) {
      p.reject(error);
    }
    this.pending.clear();
  }

  private request(type: string, payload: Record<string, unknown>, transfer?: Transferable[]): Promise<unknown> {
    return new Promise((resolve, reject) => {
      const id = this.nextId++;
      this.pending.set(id, { resolve, reject });
      this.worker.postMessage({ type, id, ...payload }, transfer ?? []);
    });
  }
}
