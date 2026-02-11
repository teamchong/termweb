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
let opfsReady = false;
const opfsQueue: Array<{ msg: any; transfers?: Transferable[] }> = [];
const openHandles = new Map<string, FileSystemSyncAccessHandle>();
// Queue for serializing chunk writes per file (prevents concurrent access handle creation)
const fileQueues = new Map<string, Promise<void>>();
// Track files that have already been reported as complete (prevents duplicate completion)
const completedFiles = new Set<string>();
// Track cancelled transfers so async operations don't re-create deleted metadata
const cancelledTransfers = new Set<number>();
// In-memory temp file storage for zip creation (no OPFS dependency)
const tempFileStore = new Map<number, Map<string, Uint8Array>>();

const MAX_DECOMPRESSED_SIZE = 128 * 1024 * 1024;

function getWorkerAuthQuery(): string {
  const params = new URLSearchParams(self.location.search);
  const token = params.get('token');
  return token ? `?token=${encodeURIComponent(token)}` : '';
}

async function initWasm(): Promise<void> {
  const t0 = performance.now();
  const bytes = await fetch(`/zstd.wasm${getWorkerAuthQuery()}`).then(r => r.arrayBuffer());
  console.log(`[Worker] fetch zstd.wasm: ${(performance.now() - t0).toFixed(0)}ms (${bytes.byteLength} bytes)`);

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

  const t1 = performance.now();
  const { instance } = await WebAssembly.instantiate(bytes, {
    wasi_snapshot_preview1: wasi_stubs,
  });
  mem = instance.exports.memory as WebAssembly.Memory;
  wasm = instance.exports as unknown as ZstdExports;
  console.log(`[Worker] WASM compile: ${(performance.now() - t1).toFixed(0)}ms`);
  console.log(`[Worker] initWasm total: ${(performance.now() - t0).toFixed(0)}ms`);
}

/** Activate OPFS with a root handle received from the main thread */
async function activateOPFS(root: FileSystemDirectoryHandle): Promise<void> {
  opfsRoot = root;
  console.log(`[Worker] OPFS root received from main thread`);

  // Do NOT clear transfer metadata here — it's needed for download resume
  // across page reloads. Metadata is cleaned up per-transfer on completion.

  opfsReady = true;
  console.log(`[Worker] OPFS ready`);

  // Flush queued OPFS-dependent operations
  const queued = opfsQueue.splice(0);
  if (queued.length > 0) {
    console.log(`[Worker] Flushing ${queued.length} queued OPFS operations`);
    for (const item of queued) {
      // Re-dispatch through the message handler
      self.dispatchEvent(new MessageEvent('message', { data: item.msg }));
    }
  }

  (self as unknown as Worker).postMessage({ type: 'opfs-ready' });
}

/** Queue an OPFS-dependent operation if OPFS isn't ready yet. Returns true if queued. */
function queueIfOPFSNotReady(msg: any): boolean {
  if (opfsReady) return false;
  console.log(`[Worker] OPFS not ready, queuing: ${msg.type}`);
  opfsQueue.push({ msg });
  return true;
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

// ── Temp file storage for zip creation (avoids keeping files in memory) ──

const TEMP_ROOT = 'termweb-temp';

async function writeTempFile(transferId: number, path: string, data: ArrayBuffer): Promise<void> {
  if (!opfsRoot) return;

  // Retry up to 3 times if we get access handle conflicts
  let lastError: unknown;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const tempDir = await opfsRoot.getDirectoryHandle(TEMP_ROOT, { create: true });
      const transferDir = await tempDir.getDirectoryHandle(String(transferId), { create: true });

      // Create nested directories for path
      const parts = path.split('/').filter(p => p);
      let dir = transferDir;
      for (let i = 0; i < parts.length - 1; i++) {
        dir = await dir.getDirectoryHandle(parts[i], { create: true });
      }

      // Write file using sync access handle (available in workers)
      const fileName = parts[parts.length - 1];
      const fileHandle = await dir.getFileHandle(fileName, { create: true });

      let accessHandle: any = null;
      try {
        // @ts-ignore - createSyncAccessHandle exists in workers but TypeScript doesn't know
        accessHandle = await fileHandle.createSyncAccessHandle();
        accessHandle.truncate(0);
        accessHandle.write(new Uint8Array(data), { at: 0 });
        accessHandle.flush();
        return; // Success!
      } finally {
        // Ensure handle is closed even if write fails
        if (accessHandle) {
          try {
            accessHandle.close();
          } catch (closeErr) {
            console.warn('Failed to close access handle:', closeErr);
          }
        }
      }
    } catch (err) {
      lastError = err;
      const errMsg = err instanceof Error ? err.message : String(err);

      // If it's an access handle conflict, wait and retry
      if (errMsg.includes('Access Handle') || errMsg.includes('access handle')) {
        console.warn(`Write temp file attempt ${attempt + 1}/3 failed for ${path}, retrying...`, errMsg);
        // Exponential backoff: 10ms, 50ms, 100ms
        await new Promise(resolve => setTimeout(resolve, 10 * Math.pow(5, attempt)));
        continue;
      }

      // For other errors, log and give up
      console.error('Failed to write temp file:', path, err);
      return;
    }
  }

  // All retries exhausted
  console.error('Failed to write temp file after 3 attempts:', path, lastError);
}

async function createZipFromTemp(transferId: number, folderName?: string): Promise<{ zipData: ArrayBuffer; filename: string }> {
  if (!opfsRoot) throw new Error('OPFS not available');

  console.log(`[Worker] createZipFromTemp: Getting temp dir for transfer ${transferId}`);
  const tempDir = await opfsRoot.getDirectoryHandle(TEMP_ROOT);
  const transferDir = await tempDir.getDirectoryHandle(String(transferId));

  // Collect all files recursively
  const files = new Map<string, Uint8Array>();

  async function walkDir(dir: FileSystemDirectoryHandle, prefix: string): Promise<void> {
    for await (const [name, handle] of dir as unknown as AsyncIterable<[string, FileSystemHandle]>) {
      const path = prefix ? `${prefix}/${name}` : name;

      if (handle.kind === 'file') {
        const fileHandle = handle as FileSystemFileHandle;
        const file = await fileHandle.getFile();
        const data = new Uint8Array(await file.arrayBuffer());
        files.set(path, data);
      } else if (handle.kind === 'directory') {
        await walkDir(handle as FileSystemDirectoryHandle, path);
      }
    }
  }

  await walkDir(transferDir, '');
  console.log(`[Worker] Collected ${files.size} files from OPFS temp`);

  // Create zip from collected files
  const zipData = createZipInWorker(files);
  console.log(`[Worker] Created zip: ${zipData.length} bytes`);

  // Use provided folder name or extract from first file path
  const filename = folderName ? `${folderName}.zip` : `${Array.from(files.keys())[0]?.split('/')[0] || 'download'}.zip`;
  console.log(`[Worker] Zip filename: ${filename}`);

  return { zipData: zipData.buffer as ArrayBuffer, filename };
}

async function cleanupTempFiles(transferId: number): Promise<void> {
  if (!opfsRoot) return;

  try {
    const tempDir = await opfsRoot.getDirectoryHandle(TEMP_ROOT);
    await tempDir.removeEntry(String(transferId), { recursive: true });
  } catch {
    // Directory might not exist
  }
}

// CRC32 table for ZIP checksums
const CRC32_TABLE = new Uint32Array(256);
for (let i = 0; i < 256; i++) {
  let c = i;
  for (let k = 0; k < 8; k++) {
    c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  }
  CRC32_TABLE[i] = c;
}

function crc32(data: Uint8Array): number {
  let crc = ~0;
  for (let i = 0; i < data.length; i++) {
    crc = CRC32_TABLE[(crc ^ data[i]) & 0xff] ^ (crc >>> 8);
  }
  return ~crc >>> 0;
}

/** Create a ZIP file from a map of path → data entries (stored, no compression). */
function createZipInWorker(files: Map<string, Uint8Array>): Uint8Array {
  const encoder = new TextEncoder();
  const entries: Array<{ name: Uint8Array; data: Uint8Array; crc: number; offset: number }> = [];

  // Calculate total size
  let totalSize = 22; // end of central directory
  for (const [name, data] of files) {
    const nameBytes = encoder.encode(name);
    totalSize += 30 + nameBytes.length + data.length; // local header + data
    totalSize += 46 + nameBytes.length; // central directory entry
  }

  const zip = new Uint8Array(totalSize);
  const view = new DataView(zip.buffer);
  let pos = 0;

  // Write local file headers + data
  for (const [name, data] of files) {
    const nameBytes = encoder.encode(name);
    const fileCrc = crc32(data);
    const localOffset = pos;

    // Local file header signature
    view.setUint32(pos, 0x04034b50, true); pos += 4;
    view.setUint16(pos, 20, true); pos += 2;   // version needed
    view.setUint16(pos, 0, true); pos += 2;    // flags
    view.setUint16(pos, 0, true); pos += 2;    // compression: stored
    view.setUint16(pos, 0, true); pos += 2;    // mod time
    view.setUint16(pos, 0, true); pos += 2;    // mod date
    view.setUint32(pos, fileCrc, true); pos += 4;
    view.setUint32(pos, data.length, true); pos += 4; // compressed size
    view.setUint32(pos, data.length, true); pos += 4; // uncompressed size
    view.setUint16(pos, nameBytes.length, true); pos += 2;
    view.setUint16(pos, 0, true); pos += 2;    // extra field length
    zip.set(nameBytes, pos); pos += nameBytes.length;
    zip.set(data, pos); pos += data.length;

    entries.push({ name: nameBytes, data, crc: fileCrc, offset: localOffset });
  }

  // Write central directory
  const centralDirOffset = pos;
  for (const entry of entries) {
    view.setUint32(pos, 0x02014b50, true); pos += 4; // signature
    view.setUint16(pos, 20, true); pos += 2;   // version made by
    view.setUint16(pos, 20, true); pos += 2;   // version needed
    view.setUint16(pos, 0, true); pos += 2;    // flags
    view.setUint16(pos, 0, true); pos += 2;    // compression
    view.setUint16(pos, 0, true); pos += 2;    // mod time
    view.setUint16(pos, 0, true); pos += 2;    // mod date
    view.setUint32(pos, entry.crc, true); pos += 4;
    view.setUint32(pos, entry.data.length, true); pos += 4; // compressed size
    view.setUint32(pos, entry.data.length, true); pos += 4; // uncompressed size
    view.setUint16(pos, entry.name.length, true); pos += 2;
    view.setUint16(pos, 0, true); pos += 2;    // extra field length
    view.setUint16(pos, 0, true); pos += 2;    // file comment length
    view.setUint16(pos, 0, true); pos += 2;    // disk number
    view.setUint16(pos, 0, true); pos += 2;    // internal file attributes
    view.setUint32(pos, 0, true); pos += 4;    // external file attributes
    view.setUint32(pos, entry.offset, true); pos += 4; // local header offset
    zip.set(entry.name, pos); pos += entry.name.length;
  }

  // Write end of central directory
  const centralDirSize = pos - centralDirOffset;
  view.setUint32(pos, 0x06054b50, true); pos += 4; // signature
  view.setUint16(pos, 0, true); pos += 2;    // disk number
  view.setUint16(pos, 0, true); pos += 2;    // disk with central dir
  view.setUint16(pos, entries.length, true); pos += 2; // entries on this disk
  view.setUint16(pos, entries.length, true); pos += 2; // total entries
  view.setUint32(pos, centralDirSize, true); pos += 4;
  view.setUint32(pos, centralDirOffset, true); pos += 4;
  view.setUint16(pos, 0, true); // comment length

  return zip;
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

/** Clear cache for a specific server path */
async function cacheClearPath(serverPath: string): Promise<void> {
  if (!opfsRoot) return;
  try {
    const cacheDir = await opfsRoot.getDirectoryHandle(CACHE_ROOT);
    const cleanPath = serverPath.replace(/^\/+/, '');
    if (cleanPath) {
      // Navigate to parent directory and remove the target
      const parts = cleanPath.split('/').filter(p => p);
      if (parts.length === 0) return;

      let dir = cacheDir;
      for (let i = 0; i < parts.length - 1; i++) {
        dir = await dir.getDirectoryHandle(parts[i]);
      }
      await dir.removeEntry(parts[parts.length - 1], { recursive: true });
    }
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

// ── Transfer Metadata for Resume Support ──

interface TransferMetadata {
  transferId: number;
  direction: 'upload' | 'download';
  serverPath: string;
  totalFiles: number;
  totalBytes: number;
  completedFiles: string[]; // File paths that have been fully written
  bytesTransferred: number;
  startTime: number;
  lastUpdateTime: number;
  // Transfer options preserved for resume
  useGitignore?: boolean;
  excludes?: string[];
}

async function saveTransferMetadata(meta: TransferMetadata): Promise<void> {
  if (!opfsRoot) return;
  try {
    const transfersDir = await opfsRoot.getDirectoryHandle('transfers', { create: true });
    const transferDir = await transfersDir.getDirectoryHandle(`${meta.transferId}`, { create: true });
    const metaFile = await transferDir.getFileHandle('metadata.json', { create: true });
    const writable = await metaFile.createWritable();
    await writable.write(JSON.stringify(meta));
    await writable.close();
    console.log(`[Worker] Saved metadata for transfer ${meta.transferId}`);
  } catch (err) {
    console.error('[Worker] Failed to save transfer metadata:', err);
  }
}

async function loadTransferMetadata(transferId: number): Promise<TransferMetadata | null> {
  if (!opfsRoot) return null;
  try {
    const transfersDir = await opfsRoot.getDirectoryHandle('transfers', { create: false });
    const transferDir = await transfersDir.getDirectoryHandle(`${transferId}`, { create: false });
    const metaFile = await transferDir.getFileHandle('metadata.json', { create: false });
    const file = await metaFile.getFile();
    const text = await file.text();
    return JSON.parse(text) as TransferMetadata;
  } catch {
    return null;
  }
}

async function updateTransferProgress(transferId: number, filePath: string, bytesWritten: number): Promise<void> {
  if (cancelledTransfers.has(transferId)) return;
  const meta = await loadTransferMetadata(transferId);
  if (!meta) return;

  if (!meta.completedFiles.includes(filePath)) {
    meta.completedFiles.push(filePath);
  }
  meta.bytesTransferred += bytesWritten;
  meta.lastUpdateTime = Date.now();

  await saveTransferMetadata(meta);
}

async function clearAllTransferMetadata(): Promise<void> {
  if (!opfsRoot) return;
  try {
    await opfsRoot.removeEntry('transfers', { recursive: true });
  } catch {
    // 'transfers' directory doesn't exist — nothing to clear
  }
}

async function deleteTransferMetadata(transferId: number): Promise<void> {
  if (!opfsRoot) return;
  try {
    const transfersDir = await opfsRoot.getDirectoryHandle('transfers', { create: false });
    await transfersDir.removeEntry(`${transferId}`, { recursive: true });
    console.log(`[Worker] Deleted metadata for transfer ${transferId}`);
  } catch (err) {
    console.error('[Worker] Failed to delete transfer metadata:', err);
  }
}

async function getInterruptedTransfers(): Promise<TransferMetadata[]> {
  if (!opfsRoot) return [];
  try {
    const transfersDir = await opfsRoot.getDirectoryHandle('transfers', { create: false });
    const interrupted: TransferMetadata[] = [];

    for await (const entry of transfersDir.values()) {
      if (entry.kind === 'directory') {
        const transferId = parseInt(entry.name);
        const meta = await loadTransferMetadata(transferId);
        if (meta) {
          interrupted.push(meta);
        }
      }
    }

    return interrupted;
  } catch {
    return [];
  }
}

// Message handler
self.onmessage = async (e: MessageEvent) => {
  const msg = e.data;

  try {
    switch (msg.type) {
      case 'init': {
        await initWasm();
        (self as unknown as Worker).postMessage({ type: 'init-done' });
        break;
      }

      case 'set-opfs-root': {
        // Main thread obtained the OPFS root handle and sent it here
        if (msg.opfsRoot) {
          activateOPFS(msg.opfsRoot).catch(err => {
            console.error('[Worker] OPFS activation failed:', err);
          });
        }
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
        const { transferId, fileIndex, filePath, compressedData, fileSize } = msg;

        const fileKey = `${transferId}/${filePath}`;
        const previousOp = fileQueues.get(fileKey) || Promise.resolve();

        const currentOp = previousOp.then(async () => {
          try {
            if (cancelledTransfers.has(transferId)) return;
            if (completedFiles.has(fileKey)) return;

            const decompressed = decompressData(new Uint8Array(compressedData));

            // Accumulate in worker memory
            if (!tempFileStore.has(transferId)) tempFileStore.set(transferId, new Map());
            const store = tempFileStore.get(transferId)!;
            const existing = store.get(filePath);
            if (existing) {
              const merged = new Uint8Array(existing.length + decompressed.length);
              merged.set(existing);
              merged.set(decompressed, existing.length);
              store.set(filePath, merged);
            } else {
              store.set(filePath, decompressed);
            }

            const totalWritten = store.get(filePath)!.length;
            const complete = totalWritten >= fileSize;

            if (complete) {
              completedFiles.add(fileKey);
              fileQueues.delete(fileKey);
              // Persist to OPFS metadata for resume support
              await updateTransferProgress(transferId, filePath, totalWritten);
            }

            (self as unknown as Worker).postMessage({
              type: 'chunk-written',
              transferId,
              fileIndex,
              filePath,
              bytesWritten: decompressed.length,
              complete,
            });
          } catch (err) {
            console.error(`[Worker] ERROR decompress-and-write: idx=${fileIndex}, path=${filePath}`, err);
            (self as unknown as Worker).postMessage({
              type: 'chunk-error',
              transferId,
              fileIndex,
              filePath,
              error: err instanceof Error ? err.message : String(err),
            });
          }
        });

        fileQueues.set(fileKey, currentOp);
        break;
      }

      case 'get-file': {
        const { transferId, filePath } = msg;
        const store = tempFileStore.get(transferId);
        const fileData = store?.get(filePath);
        if (fileData) {
          const buffer = fileData.buffer.slice(fileData.byteOffset, fileData.byteOffset + fileData.byteLength) as ArrayBuffer;
          (self as unknown as Worker).postMessage(
            { type: 'file-data', transferId, filePath, data: buffer },
            [buffer]
          );
        } else {
          console.error(`[Worker] get-file: not found: ${filePath}`);
        }
        break;
      }

      case 'cleanup': {
        tempFileStore.delete(msg.transferId);
        if (opfsReady) await cleanupTransfer(msg.transferId);
        (self as unknown as Worker).postMessage({ type: 'cleanup-done', transferId: msg.transferId });
        break;
      }

      // ── Temp file operations for zip creation ──

      case 'write-temp-file': {
        if (!tempFileStore.has(msg.transferId)) tempFileStore.set(msg.transferId, new Map());
        const fileData = new Uint8Array(msg.data);
        tempFileStore.get(msg.transferId)!.set(msg.path, fileData);
        // Persist to OPFS metadata for resume support
        await updateTransferProgress(msg.transferId, msg.path, fileData.length);
        break;
      }

      case 'create-zip-from-temp': {
        const store = tempFileStore.get(msg.transferId);
        if (!store || store.size === 0) {
          console.error(`[Worker] create-zip-from-temp: No files for transfer ${msg.transferId}`);
          break;
        }
        console.log(`[Worker] Creating zip from ${store.size} in-memory files`);
        const zipData = createZipInWorker(store);
        const folderName = msg.folderName || 'download';
        const filename = `${folderName}.zip`;
        console.log(`[Worker] Zip created: ${zipData.length} bytes, filename: ${filename}`);
        const buffer = zipData.buffer as ArrayBuffer;
        (self as unknown as Worker).postMessage(
          { type: 'zip-created', transferId: msg.transferId, zipData: buffer, filename },
          [buffer]
        );
        break;
      }

      case 'cleanup-temp': {
        tempFileStore.delete(msg.transferId);
        if (opfsReady) await cleanupTempFiles(msg.transferId);
        break;
      }

      // ── Cache operations ──

      case 'cache-put': {
        if (queueIfOPFSNotReady(msg)) break;
        const { id, serverPath, filePath, data, metadata } = msg;
        await cachePut(serverPath, filePath, data, metadata);
        (self as unknown as Worker).postMessage({ type: 'cache-put-done', id, serverPath, filePath });
        break;
      }

      case 'cache-get': {
        if (queueIfOPFSNotReady(msg)) break;
        const { id, serverPath, filePath } = msg;
        const data = await cacheGet(serverPath, filePath);
        (self as unknown as Worker).postMessage(
          { type: 'cache-file', id, serverPath, filePath, data },
          [data]
        );
        break;
      }

      case 'cache-list': {
        if (queueIfOPFSNotReady(msg)) break;
        const { id, serverPath } = msg;
        const files = await readCacheMeta(serverPath);
        (self as unknown as Worker).postMessage({ type: 'cache-list-result', id, serverPath, files });
        break;
      }

      case 'cache-remove': {
        if (queueIfOPFSNotReady(msg)) break;
        const { id, serverPath, filePath } = msg;
        await cacheRemove(serverPath, filePath);
        (self as unknown as Worker).postMessage({ type: 'cache-remove-done', id, serverPath, filePath });
        break;
      }

      case 'cache-clear-all': {
        if (queueIfOPFSNotReady(msg)) break;
        const { id } = msg;
        await cacheClearAll();
        (self as unknown as Worker).postMessage({ type: 'cache-cleared', id });
        break;
      }

      case 'cache-clear-path': {
        if (queueIfOPFSNotReady(msg)) break;
        const { serverPath } = msg;
        await cacheClearPath(serverPath);
        (self as unknown as Worker).postMessage({ type: 'cache-path-cleared', serverPath });
        break;
      }

      case 'cache-usage': {
        if (queueIfOPFSNotReady(msg)) break;
        const { id } = msg;
        const usage = await cacheUsage();
        (self as unknown as Worker).postMessage({ type: 'cache-usage-result', id, ...usage });
        break;
      }

      // ── Rsync delta sync operations ──

      case 'compute-checksums': {
        if (queueIfOPFSNotReady(msg)) break;
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
        if (queueIfOPFSNotReady(msg)) break;
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

      // ── Transfer Metadata for Resume ──

      case 'save-transfer-metadata': {
        if (queueIfOPFSNotReady(msg)) break;
        await saveTransferMetadata(msg.metadata);
        (self as unknown as Worker).postMessage({ type: 'metadata-saved', transferId: msg.metadata.transferId });
        break;
      }

      case 'load-transfer-metadata': {
        if (queueIfOPFSNotReady(msg)) break;
        const meta = await loadTransferMetadata(msg.transferId);
        (self as unknown as Worker).postMessage({ type: 'metadata-loaded', transferId: msg.transferId, metadata: meta });
        break;
      }

      case 'delete-transfer-metadata': {
        if (queueIfOPFSNotReady(msg)) break;
        cancelledTransfers.add(msg.transferId);
        await deleteTransferMetadata(msg.transferId);
        // Re-delete after a delay to catch any in-flight writes that passed the
        // cancelledTransfers guard before the cancel arrived
        setTimeout(() => deleteTransferMetadata(msg.transferId), 2000);
        (self as unknown as Worker).postMessage({ type: 'metadata-deleted', transferId: msg.transferId });
        break;
      }

      case 'get-interrupted-transfers': {
        if (queueIfOPFSNotReady(msg)) break;
        const interrupted = await getInterruptedTransfers();
        (self as unknown as Worker).postMessage({ type: 'interrupted-transfers', transfers: interrupted });
        break;
      }
    }
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : 'Unknown error';
    (self as unknown as Worker).postMessage({ type: 'error', message, originalType: msg.type, ...msg });
  }
};
