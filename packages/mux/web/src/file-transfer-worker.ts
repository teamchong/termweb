// Web Worker for file transfer operations:
// - zstd decompression/compression via WASM (off main thread)
// - OPFS synchronous file access for cached storage

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
let opfsRoot: FileSystemDirectoryHandle | null = null;
const openHandles = new Map<string, FileSystemSyncAccessHandle>();

const MAX_DECOMPRESSED_SIZE = 16 * 1024 * 1024;

async function initWasm(): Promise<void> {
  const response = await fetch('/zstd.wasm');
  const bytes = await response.arrayBuffer();

  let mem: WebAssembly.Memory | null = null;
  const wasi_stubs = {
    args_sizes_get: (argc_ptr: number, buf_size_ptr: number) => {
      const v = new DataView(mem!.buffer);
      v.setUint32(argc_ptr, 0, true);
      v.setUint32(buf_size_ptr, 0, true);
      return 0;
    },
    args_get: () => 0,
    environ_sizes_get: (count_ptr: number, buf_size_ptr: number) => {
      const v = new DataView(mem!.buffer);
      v.setUint32(count_ptr, 0, true);
      v.setUint32(buf_size_ptr, 0, true);
      return 0;
    },
    environ_get: () => 0,
    clock_time_get: () => 0,
    fd_close: () => 0,
    fd_fdstat_get: () => 0,
    fd_prestat_get: () => 8,
    fd_prestat_dir_name: () => 8,
    fd_read: () => 0,
    fd_seek: () => 0,
    fd_write: () => 0,
    proc_exit: () => {},
    random_get: () => 0,
  };

  const { instance } = await WebAssembly.instantiate(bytes, {
    wasi_snapshot_preview1: wasi_stubs,
  });
  mem = instance.exports.memory as WebAssembly.Memory;
  wasm = instance.exports as unknown as ZstdExports;

  try {
    opfsRoot = await navigator.storage.getDirectory();
  } catch {
    // OPFS not available
  }
}

function decompressData(data: Uint8Array): Uint8Array {
  if (!wasm) throw new Error('WASM not initialized');

  const srcSize = data.length;
  const srcPtr = wasm.zstd_alloc(srcSize);
  if (srcPtr === 0) throw new Error('zstd alloc failed');

  new Uint8Array(wasm.memory.buffer, srcPtr, srcSize).set(data);

  let dstCap = wasm.zstd_frame_content_size(srcPtr, srcSize);
  if (dstCap === 0 || dstCap > MAX_DECOMPRESSED_SIZE) {
    dstCap = Math.min(srcSize * 8, MAX_DECOMPRESSED_SIZE);
  }

  const dstPtr = wasm.zstd_alloc(dstCap);
  if (dstPtr === 0) {
    wasm.zstd_free(srcPtr, srcSize);
    throw new Error('zstd alloc failed');
  }

  try {
    const size = wasm.zstd_decompress(dstPtr, dstCap, srcPtr, srcSize);
    if (size === 0) throw new Error('zstd decompression failed');
    return new Uint8Array(wasm.memory.buffer.slice(dstPtr, dstPtr + size));
  } finally {
    wasm.zstd_free(srcPtr, srcSize);
    wasm.zstd_free(dstPtr, dstCap);
  }
}

function compressData(data: Uint8Array, level: number): Uint8Array {
  if (!wasm) throw new Error('WASM not initialized');

  const srcSize = data.length;
  const dstCap = wasm.zstd_compress_bound(srcSize);
  const srcPtr = wasm.zstd_alloc(srcSize);
  const dstPtr = wasm.zstd_alloc(dstCap);
  if (srcPtr === 0 || dstPtr === 0) {
    if (srcPtr) wasm.zstd_free(srcPtr, srcSize);
    if (dstPtr) wasm.zstd_free(dstPtr, dstCap);
    throw new Error('zstd alloc failed');
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

// OPFS directory helper
async function ensureDir(parent: FileSystemDirectoryHandle, name: string): Promise<FileSystemDirectoryHandle> {
  return parent.getDirectoryHandle(name, { create: true });
}

// Get or create a sync access handle for writing to OPFS
async function getOPFSHandle(transferId: number, filePath: string): Promise<FileSystemSyncAccessHandle> {
  const key = `${transferId}/${filePath}`;
  const existing = openHandles.get(key);
  if (existing) return existing;

  if (!opfsRoot) throw new Error('OPFS not available');

  let dir = await ensureDir(opfsRoot, 'termweb-transfers');
  dir = await ensureDir(dir, String(transferId));

  const parts = filePath.split('/');
  for (let i = 0; i < parts.length - 1; i++) {
    dir = await ensureDir(dir, parts[i]);
  }

  const fileName = parts[parts.length - 1];
  const fileHandle = await dir.getFileHandle(fileName, { create: true });
  const accessHandle = await fileHandle.createSyncAccessHandle();
  openHandles.set(key, accessHandle);
  return accessHandle;
}

function closeHandle(transferId: number, filePath: string): void {
  const key = `${transferId}/${filePath}`;
  const handle = openHandles.get(key);
  if (handle) {
    try { handle.flush(); } catch { /* ignore */ }
    try { handle.close(); } catch { /* ignore */ }
    openHandles.delete(key);
  }
}

async function readFileFromOPFS(transferId: number, filePath: string): Promise<ArrayBuffer> {
  if (!opfsRoot) throw new Error('OPFS not available');

  let dir = await opfsRoot.getDirectoryHandle('termweb-transfers');
  dir = await dir.getDirectoryHandle(String(transferId));

  const parts = filePath.split('/');
  for (let i = 0; i < parts.length - 1; i++) {
    dir = await dir.getDirectoryHandle(parts[i]);
  }

  const fileHandle = await dir.getFileHandle(parts[parts.length - 1]);
  const file = await fileHandle.getFile();
  return file.arrayBuffer();
}

async function cleanupTransfer(transferId: number): Promise<void> {
  if (!opfsRoot) return;

  // Close any open handles for this transfer
  for (const [key, handle] of openHandles) {
    if (key.startsWith(`${transferId}/`)) {
      try { handle.flush(); } catch { /* ignore */ }
      try { handle.close(); } catch { /* ignore */ }
      openHandles.delete(key);
    }
  }

  try {
    const dir = await opfsRoot.getDirectoryHandle('termweb-transfers');
    await dir.removeEntry(String(transferId), { recursive: true });
  } catch {
    // Directory might not exist
  }
}

// ── OPFS Cache (persistent storage for delta sync) ──

const CACHE_ROOT = 'termweb-cache';

interface CacheFilesMeta {
  [filePath: string]: { size: number; mtime: number; hash: string };
}

async function getCacheDir(serverPath: string): Promise<FileSystemDirectoryHandle> {
  if (!opfsRoot) throw new Error('OPFS not available');
  let dir = await ensureDir(opfsRoot, CACHE_ROOT);

  // Use server path segments as nested OPFS directories
  const cleanPath = serverPath.replace(/^\/+/, '');
  if (cleanPath) {
    for (const part of cleanPath.split('/')) {
      if (part) dir = await ensureDir(dir, part);
    }
  }
  return dir;
}

async function getCacheFilesDir(serverPath: string): Promise<FileSystemDirectoryHandle> {
  const cacheDir = await getCacheDir(serverPath);
  return ensureDir(cacheDir, 'files');
}

async function readCacheMeta(serverPath: string): Promise<CacheFilesMeta> {
  try {
    const cacheDir = await getCacheDir(serverPath);
    const metaHandle = await cacheDir.getFileHandle('.termweb-meta');
    const file = await metaHandle.getFile();
    const text = await file.text();
    return JSON.parse(text);
  } catch {
    return {};
  }
}

async function writeCacheMeta(serverPath: string, meta: CacheFilesMeta): Promise<void> {
  const cacheDir = await getCacheDir(serverPath);
  const metaHandle = await cacheDir.getFileHandle('.termweb-meta', { create: true });
  const accessHandle = await metaHandle.createSyncAccessHandle();
  try {
    const encoded = new TextEncoder().encode(JSON.stringify(meta));
    accessHandle.truncate(0);
    accessHandle.write(encoded, { at: 0 });
    accessHandle.flush();
  } finally {
    accessHandle.close();
  }
}

async function cachePut(serverPath: string, filePath: string, data: ArrayBuffer, metadata: { size: number; mtime: number; hash: string }): Promise<void> {
  const filesDir = await getCacheFilesDir(serverPath);

  // Create subdirectories for the file path
  const parts = filePath.split('/');
  let dir = filesDir;
  for (let i = 0; i < parts.length - 1; i++) {
    dir = await ensureDir(dir, parts[i]);
  }

  // Write file data using sync access handle
  const fileHandle = await dir.getFileHandle(parts[parts.length - 1], { create: true });
  const accessHandle = await fileHandle.createSyncAccessHandle();
  try {
    accessHandle.truncate(0);
    accessHandle.write(new Uint8Array(data), { at: 0 });
    accessHandle.flush();
  } finally {
    accessHandle.close();
  }

  // Update metadata
  const meta = await readCacheMeta(serverPath);
  meta[filePath] = metadata;
  await writeCacheMeta(serverPath, meta);
}

async function cacheGet(serverPath: string, filePath: string): Promise<ArrayBuffer> {
  const filesDir = await getCacheFilesDir(serverPath);

  const parts = filePath.split('/');
  let dir = filesDir;
  for (let i = 0; i < parts.length - 1; i++) {
    dir = await dir.getDirectoryHandle(parts[i]);
  }

  const fileHandle = await dir.getFileHandle(parts[parts.length - 1]);
  const file = await fileHandle.getFile();
  return file.arrayBuffer();
}

async function cacheRemove(serverPath: string, filePath: string): Promise<void> {
  // Remove from metadata
  const meta = await readCacheMeta(serverPath);
  delete meta[filePath];
  await writeCacheMeta(serverPath, meta);

  // Remove file
  try {
    const filesDir = await getCacheFilesDir(serverPath);
    const parts = filePath.split('/');
    let dir = filesDir;
    for (let i = 0; i < parts.length - 1; i++) {
      dir = await dir.getDirectoryHandle(parts[i]);
    }
    await dir.removeEntry(parts[parts.length - 1]);
  } catch {
    // File might not exist
  }
}

/** Remove the entire termweb-cache directory tree */
async function cacheClearAll(): Promise<void> {
  if (!opfsRoot) return;
  try {
    await opfsRoot.removeEntry(CACHE_ROOT, { recursive: true });
  } catch {
    // Directory might not exist
  }
}

/** Walk the cache directory and sum file sizes */
async function cacheUsage(): Promise<{ totalBytes: number; fileCount: number }> {
  if (!opfsRoot) return { totalBytes: 0, fileCount: 0 };

  let totalBytes = 0;
  let fileCount = 0;

  async function walkDir(dir: FileSystemDirectoryHandle): Promise<void> {
    for await (const [, handle] of dir as unknown as AsyncIterable<[string, FileSystemHandle]>) {
      if (handle.kind === 'file') {
        const file = await (handle as FileSystemFileHandle).getFile();
        totalBytes += file.size;
        fileCount++;
      } else {
        await walkDir(handle as FileSystemDirectoryHandle);
      }
    }
  }

  try {
    const cacheDir = await opfsRoot.getDirectoryHandle(CACHE_ROOT);
    await walkDir(cacheDir);
  } catch {
    // Cache directory doesn't exist yet
  }

  return { totalBytes, fileCount };
}

// ── Block checksum computation (for rsync delta sync) ──

/** Rsync-style rolling checksum (Adler32 variant) */
function rollingChecksum(data: Uint8Array): number {
  let a = 0, b = 0;
  for (let i = 0; i < data.length; i++) {
    a = (a + data[i]) & 0xFFFF;
    b = (b + a) & 0xFFFF;
  }
  return ((b << 16) | a) >>> 0;
}

/** Strong checksum: use zstd WASM's memory to compute XXH3 via a simple hash.
 *  Since we don't have direct XXH3 in JS, use a FNV-1a 64-bit variant. */
function strongChecksum(data: Uint8Array): bigint {
  // FNV-1a 64-bit - fast and collision-resistant for our use case
  let hash = 0xcbf29ce484222325n;
  const prime = 0x100000001b3n;
  for (let i = 0; i < data.length; i++) {
    hash ^= BigInt(data[i]);
    hash = (hash * prime) & 0xFFFFFFFFFFFFFFFFn;
  }
  return hash;
}

/** Compute block checksums for a cached file */
async function computeBlockChecksums(
  serverPath: string,
  filePath: string,
  blockSize: number
): Promise<{ rolling: Uint32Array; strong: BigUint64Array }> {
  const data = new Uint8Array(await cacheGet(serverPath, filePath));
  const blockCount = Math.ceil(data.length / blockSize);
  const rolling = new Uint32Array(blockCount);
  const strong = new BigUint64Array(blockCount);

  for (let i = 0; i < blockCount; i++) {
    const start = i * blockSize;
    const end = Math.min(start + blockSize, data.length);
    const block = data.subarray(start, end);
    rolling[i] = rollingChecksum(block);
    strong[i] = strongChecksum(block);
  }

  return { rolling, strong };
}

/** Apply delta commands to a cached file, producing a new file.
 *  Commands: COPY [offset:u64][length:u32] | LITERAL [length:u32][data...] */
function applyDelta(cachedData: Uint8Array, deltaPayload: Uint8Array): Uint8Array {
  const view = new DataView(deltaPayload.buffer, deltaPayload.byteOffset, deltaPayload.byteLength);
  const parts: Uint8Array[] = [];
  let totalSize = 0;
  let offset = 0;

  while (offset < deltaPayload.length) {
    const cmd = deltaPayload[offset]; offset += 1;

    if (cmd === 0x00) {
      // COPY: [offset:u64][length:u32]
      const copyOffset = Number(view.getBigUint64(offset, true)); offset += 8;
      const copyLen = view.getUint32(offset, true); offset += 4;
      const slice = cachedData.slice(copyOffset, copyOffset + copyLen);
      parts.push(slice);
      totalSize += slice.length;
    } else if (cmd === 0x01) {
      // LITERAL: [length:u32][data...]
      const litLen = view.getUint32(offset, true); offset += 4;
      const slice = deltaPayload.slice(offset, offset + litLen);
      parts.push(slice);
      totalSize += litLen;
      offset += litLen;
    } else {
      break; // Unknown command
    }
  }

  // Assemble result
  const result = new Uint8Array(totalSize);
  let writeOffset = 0;
  for (const part of parts) {
    result.set(part, writeOffset);
    writeOffset += part.length;
  }
  return result;
}

// Message handler
self.onmessage = async (e: MessageEvent) => {
  const msg = e.data;

  try {
    switch (msg.type) {
      case 'init': {
        await initWasm();
        (self as unknown as Worker).postMessage({ type: 'init-done', opfsAvailable: opfsRoot !== null });
        break;
      }

      case 'decompress': {
        const decompressed = decompressData(new Uint8Array(msg.data));
        const buffer = decompressed.buffer as ArrayBuffer;
        (self as unknown as Worker).postMessage(
          { type: 'decompressed', id: msg.id, data: buffer },
          [buffer]
        );
        break;
      }

      case 'compress': {
        const compressed = compressData(new Uint8Array(msg.data), msg.level || 3);
        const buffer = compressed.buffer as ArrayBuffer;
        (self as unknown as Worker).postMessage(
          { type: 'compressed', id: msg.id, data: buffer },
          [buffer]
        );
        break;
      }

      case 'decompress-and-write': {
        const { transferId, filePath, offset, compressedData, fileSize } = msg;
        const decompressed = decompressData(new Uint8Array(compressedData));

        if (opfsRoot) {
          const handle = await getOPFSHandle(transferId, filePath);
          handle.write(decompressed, { at: offset });

          const written = handle.getSize();
          const complete = written >= fileSize;
          if (complete) {
            closeHandle(transferId, filePath);
          }

          (self as unknown as Worker).postMessage({
            type: 'chunk-written',
            transferId,
            filePath,
            bytesWritten: decompressed.length,
            complete,
          });
        } else {
          // No OPFS — return decompressed data to main thread
          const buffer = decompressed.buffer as ArrayBuffer;
          (self as unknown as Worker).postMessage(
            { type: 'chunk-decompressed', transferId, filePath, offset, data: buffer, bytesWritten: decompressed.length },
            [buffer]
          );
        }
        break;
      }

      case 'get-file': {
        const { transferId, filePath } = msg;
        const data = await readFileFromOPFS(transferId, filePath);
        (self as unknown as Worker).postMessage(
          { type: 'file-data', transferId, filePath, data },
          [data]
        );
        break;
      }

      case 'cleanup': {
        await cleanupTransfer(msg.transferId);
        (self as unknown as Worker).postMessage({ type: 'cleanup-done', transferId: msg.transferId });
        break;
      }

      // ── Cache operations ──

      case 'cache-put': {
        const { id, serverPath, filePath, data, metadata } = msg;
        await cachePut(serverPath, filePath, data, metadata);
        (self as unknown as Worker).postMessage({ type: 'cache-put-done', id, serverPath, filePath });
        break;
      }

      case 'cache-get': {
        const { id, serverPath, filePath } = msg;
        const data = await cacheGet(serverPath, filePath);
        (self as unknown as Worker).postMessage(
          { type: 'cache-file', id, serverPath, filePath, data },
          [data]
        );
        break;
      }

      case 'cache-list': {
        const { id, serverPath } = msg;
        const files = await readCacheMeta(serverPath);
        (self as unknown as Worker).postMessage({ type: 'cache-list-result', id, serverPath, files });
        break;
      }

      case 'cache-remove': {
        const { id, serverPath, filePath } = msg;
        await cacheRemove(serverPath, filePath);
        (self as unknown as Worker).postMessage({ type: 'cache-remove-done', id, serverPath, filePath });
        break;
      }

      case 'cache-clear-all': {
        const { id } = msg;
        await cacheClearAll();
        (self as unknown as Worker).postMessage({ type: 'cache-cleared', id });
        break;
      }

      case 'cache-usage': {
        const { id } = msg;
        const usage = await cacheUsage();
        (self as unknown as Worker).postMessage({ type: 'cache-usage-result', id, ...usage });
        break;
      }

      // ── Rsync delta sync operations ──

      case 'compute-checksums': {
        const { id, serverPath, filePath, blockSize } = msg;
        try {
          const { rolling, strong } = await computeBlockChecksums(serverPath, filePath, blockSize);
          const rollingBuf = rolling.buffer as ArrayBuffer;
          const strongBuf = strong.buffer as ArrayBuffer;
          (self as unknown as Worker).postMessage(
            { type: 'checksums-computed', id, rolling: rollingBuf, strong: strongBuf },
            [rollingBuf, strongBuf]
          );
        } catch (err: unknown) {
          const message = err instanceof Error ? err.message : 'Checksum computation failed';
          (self as unknown as Worker).postMessage({ type: 'checksums-error', id, message });
        }
        break;
      }

      case 'apply-delta': {
        const { id, serverPath, filePath, deltaPayload } = msg;
        try {
          const cachedData = new Uint8Array(await cacheGet(serverPath, filePath));
          const result = applyDelta(cachedData, new Uint8Array(deltaPayload));
          const buffer = result.buffer as ArrayBuffer;
          (self as unknown as Worker).postMessage(
            { type: 'delta-applied', id, data: buffer },
            [buffer]
          );
        } catch (err: unknown) {
          const message = err instanceof Error ? err.message : 'Delta application failed';
          (self as unknown as Worker).postMessage({ type: 'delta-error', id, message });
        }
        break;
      }
    }
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : 'Unknown error';
    (self as unknown as Worker).postMessage({ type: 'error', message, originalType: msg.type, ...msg });
  }
};
