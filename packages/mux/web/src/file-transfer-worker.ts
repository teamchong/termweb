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
    }
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : 'Unknown error';
    (self as unknown as Worker).postMessage({ type: 'error', message, originalType: msg.type, ...msg });
  }
};
