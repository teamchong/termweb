// File transfer protocol and handlers
// Uses zstd WASM via dedicated Web Worker (off main thread)
// with synchronous OPFS access for file caching

import { getCompressionPool } from './compression-pool';
import { TransferMsgType } from './protocol';
import { sharedTextEncoder, sharedTextDecoder } from './utils';
import { OPFSCache } from './opfs-cache';
import type { CachedFileMeta } from './opfs-cache';
import {
  FILE_TRANSFER,
  PROTO_HEADER,
  PROTO_SIZE,
  PROTO_FILE_LIST,
  PROTO_FILE_REQUEST,
  PROTO_FILE_ACK,
  PROTO_TRANSFER_COMPLETE,
  PROTO_TRANSFER_ERROR,
  PROTO_TRANSFER_READY,
  PROTO_DRY_RUN,
  PROTO_BATCH_DATA,
  PROTO_SYNC_FILE_LIST,
  PROTO_DELTA_DATA,
  PROTO_SYNC_COMPLETE,
  DRY_RUN_ACTION,
} from './constants';
import type { FileSystemDirectoryHandleIterator } from './types';

// Re-export TransferMsgType for backwards compatibility
export { TransferMsgType };

export interface TransferFile {
  path: string;
  size: number;
  mtime?: number;
  hash?: bigint;
  isDir: boolean;
  handle?: FileSystemFileHandle;
  file?: File;
}

export interface TransferState {
  id: number;
  direction: 'upload' | 'download' | 'sync';
  files?: TransferFile[];
  totalBytes?: number;
  bytesTransferred: number;
  currentFileIndex: number;
  currentChunkOffset?: number;
  state: 'pending' | 'ready' | 'transferring' | 'complete' | 'error';
  receivedFiles?: Map<number, Array<{ offset: number; data: Uint8Array }>>;
  dirHandle?: FileSystemDirectoryHandle;
  serverPath?: string;
  options?: TransferOptions;
  /** Number of files that received deltas (for sync progress) */
  syncFilesProcessed?: number;
  /** Resume position from server (set by handleTransferReady, consumed by handleFileList) */
  resumePosition?: { fileIndex: number; fileOffset: number; bytesTransferred: number };
}

export interface TransferOptions {
  deleteExtra?: boolean;
  dryRun?: boolean;
  excludes?: string[];
}

export interface DryRunReport {
  newCount: number;
  updateCount: number;
  deleteCount: number;
  entries: Array<{ action: string; path: string; size: number }>;
}

export class FileTransferHandler {
  private sendFn: ((data: Uint8Array) => void) | null = null;
  private activeTransfers = new Map<number, TransferState>();
  private pendingTransfer: TransferState | null = null;
  private chunkSize = FILE_TRANSFER.CHUNK_SIZE;
  /** Interrupted uploads saved on disconnect for same-page-session resume */
  private interruptedUploads = new Map<number, TransferState>();

  // Worker for off-thread zstd WASM + synchronous OPFS access
  private worker: Worker | null = null;
  private workerReady = false;
  private opfsAvailable = false;
  private workerInitPromise: Promise<void>;
  private pendingCompression = new Map<number, { resolve: (data: Uint8Array) => void; reject: (err: Error) => void }>();
  private nextCompressionId = 0;

  // Fallback: main-thread compression pool (used if Worker unavailable)
  private compressionPool = getCompressionPool();

  // OPFS cache for delta sync (created after worker init)
  cache: OPFSCache | null = null;

  onTransferComplete?: (transferId: number, totalBytes: number) => void;
  onTransferError?: (transferId: number, error: string) => void;
  onDryRunReport?: (transferId: number, report: DryRunReport) => void;

  constructor() {
    this.workerInitPromise = this.initWorker();
  }

  private initWorker(): Promise<void> {
    return new Promise<void>((resolve) => {
      try {
        this.worker = new Worker('/file-worker.js');
        this.worker.onmessage = (e) => this.handleWorkerMessage(e);
        this.worker.onerror = () => {
          this.worker = null;
          resolve();
        };

        const timeout = setTimeout(() => {
          if (!this.workerReady) {
            this.worker = null;
            resolve();
          }
        }, 5000);

        this._workerInitResolve = () => {
          clearTimeout(timeout);
          resolve();
        };

        this.worker.postMessage({ type: 'init' });
      } catch {
        resolve();
      }
    });
  }

  private _workerInitResolve: (() => void) | null = null;

  private handleWorkerMessage(e: MessageEvent): void {
    const msg = e.data;

    // Route cache responses through OPFSCache
    if (this.cache?.handleWorkerMessage(msg)) return;

    switch (msg.type) {
      case 'init-done':
        this.workerReady = true;
        this.opfsAvailable = msg.opfsAvailable;
        if (this.worker && msg.opfsAvailable) {
          this.cache = new OPFSCache(this.worker, true);
        }
        this._workerInitResolve?.();
        this._workerInitResolve = null;
        break;

      case 'compressed': {
        const pending = this.pendingCompression.get(msg.id);
        if (pending) {
          this.pendingCompression.delete(msg.id);
          pending.resolve(new Uint8Array(msg.data));
        }
        break;
      }

      case 'decompressed': {
        const pending = this.pendingCompression.get(msg.id);
        if (pending) {
          this.pendingCompression.delete(msg.id);
          pending.resolve(new Uint8Array(msg.data));
        }
        break;
      }

      case 'chunk-written':
        this.onChunkWrittenToOPFS(msg);
        break;

      case 'chunk-decompressed':
        this.onChunkDecompressedNoOPFS(msg);
        break;

      case 'file-data':
        this.onFileDataFromOPFS(msg);
        break;

      case 'cleanup-done':
        break;

      case 'error':
        console.error('Worker error:', msg.message);
        // Reject any pending compression promise
        if (msg.id !== undefined) {
          const pending = this.pendingCompression.get(msg.id);
          if (pending) {
            this.pendingCompression.delete(msg.id);
            pending.reject(new Error(msg.message));
          }
        }
        break;
    }
  }

  /** Set the send function (injected from MuxClient — sends via control WS) */
  setSend(fn: ((data: Uint8Array) => void) | null): void {
    this.sendFn = fn;
  }

  private canSend(): boolean {
    return this.sendFn !== null;
  }

  private send(data: ArrayBuffer): void {
    this.sendFn?.(new Uint8Array(data));
  }

  /** Called when the file WS connection is lost.
   *  Saves interrupted uploads for resume, fails other transfers. */
  onDisconnect(): void {
    this.sendFn = null;

    for (const [transferId, transfer] of this.activeTransfers) {
      if (transfer.state === 'complete' || transfer.state === 'error') continue;

      if (transfer.direction === 'upload' && (transfer.state === 'transferring' || transfer.state === 'ready')) {
        // Save upload for resume — file handles survive within same page session
        this.interruptedUploads.set(transferId, { ...transfer, state: 'pending', receivedFiles: undefined });
      } else {
        // Non-upload or non-resumable: fail with error
        transfer.state = 'error';
        transfer.receivedFiles?.clear();
        this.onTransferError?.(transferId, 'File transfer connection lost');
      }
    }
    this.activeTransfers.clear();

    if (this.pendingTransfer) {
      this.onTransferError?.(this.pendingTransfer.id, 'File transfer connection lost');
      this.pendingTransfer = null;
    }

    // Reject any pending OPFS cache operations
    this.cache?.rejectAll(new Error('File transfer connection lost'));
  }

  /** Check if any transfers are currently in progress */
  hasActiveTransfers(): boolean {
    if (this.pendingTransfer) return true;
    for (const transfer of this.activeTransfers.values()) {
      if (transfer.state === 'transferring' || transfer.state === 'ready' || transfer.state === 'pending') {
        return true;
      }
    }
    return false;
  }

  /** Send TRANSFER_RESUME for a specific transfer ID */
  sendTransferResume(transferId: number): void {
    if (!this.canSend()) return;
    // TRANSFER_RESUME: [msg_type:1][transfer_id:4]
    const msg = new ArrayBuffer(5);
    const view = new DataView(msg);
    view.setUint8(0, TransferMsgType.TRANSFER_RESUME);
    view.setUint32(1, transferId, true);
    this.send(msg);
  }

  /** Get interrupted uploads that can be resumed */
  getInterruptedUploads(): ReadonlyMap<number, TransferState> {
    return this.interruptedUploads;
  }

  /** Resume all interrupted uploads by sending TRANSFER_RESUME for each.
   *  Called by mux.ts when the file WS reconnects. */
  resumeInterruptedUploads(): void {
    if (!this.canSend()) return;
    for (const [transferId, interrupted] of this.interruptedUploads) {
      // Re-register as active transfer awaiting server's resume response
      this.activeTransfers.set(transferId, { ...interrupted, state: 'pending' });
      this.sendTransferResume(transferId);
    }
    this.interruptedUploads.clear();
  }

  disconnect(): void {
    this.sendFn = null;
    this.activeTransfers.clear();
    this.pendingTransfer = null;
    this.interruptedUploads.clear();
  }

  /** Get cache disk usage (bytes + file count) */
  async getCacheUsage(): Promise<{ totalBytes: number; fileCount: number }> {
    await this.workerInitPromise;
    if (!this.cache?.available) return { totalBytes: 0, fileCount: 0 };
    return this.cache.getUsage();
  }

  /** Clear all cached files */
  async clearCache(): Promise<void> {
    await this.workerInitPromise;
    if (!this.cache?.available) return;
    return this.cache.clearAll();
  }

  /** Handle a server→client file transfer response (routed from control WS) */
  handleServerMessage(data: ArrayBuffer): void {
    const view = new DataView(data);
    const msgType = view.getUint8(0);

    switch (msgType) {
      case TransferMsgType.TRANSFER_READY:
        this.handleTransferReady(data);
        break;
      case TransferMsgType.FILE_LIST:
        this.handleFileList(data);
        break;
      case TransferMsgType.FILE_REQUEST:
        this.handleFileRequest(data).catch(err => console.error('File request handling failed:', err));
        break;
      case TransferMsgType.FILE_ACK:
        this.handleFileAck(data);
        break;
      case TransferMsgType.TRANSFER_COMPLETE:
        this.handleTransferComplete(data);
        break;
      case TransferMsgType.TRANSFER_ERROR:
        this.handleTransferError(data);
        break;
      case TransferMsgType.DRY_RUN_REPORT:
        this.handleDryRunReport(data);
        break;
      case TransferMsgType.BATCH_DATA:
        this.handleBatchData(data).catch(err => console.error('Batch data handling failed:', err));
        break;
      case TransferMsgType.SYNC_FILE_LIST:
        this.handleSyncFileList(data).catch(err => console.error('Sync file list handling failed:', err));
        break;
      case TransferMsgType.DELTA_DATA:
        this.handleDeltaData(data).catch(err => console.error('Delta data handling failed:', err));
        break;
      case TransferMsgType.SYNC_COMPLETE:
        this.handleSyncComplete(data);
        break;
    }
  }

  private handleTransferReady(data: ArrayBuffer): void {
    const view = new DataView(data);
    const transferId = view.getUint32(PROTO_HEADER.TRANSFER_ID, true);

    // Parse resume position from extended format (25 bytes)
    let resumeFileIndex = 0;
    let resumeFileOffset = 0;
    let resumeBytesTransferred = 0;
    if (data.byteLength >= PROTO_TRANSFER_READY.EXTENDED_SIZE) {
      resumeFileIndex = view.getUint32(PROTO_TRANSFER_READY.FILE_INDEX, true);
      resumeFileOffset = Number(view.getBigUint64(PROTO_TRANSFER_READY.FILE_OFFSET, true));
      resumeBytesTransferred = Number(view.getBigUint64(PROTO_TRANSFER_READY.BYTES_TRANSFERRED, true));
    }

    const isResume = resumeFileIndex > 0 || resumeFileOffset > 0 || resumeBytesTransferred > 0;
    console.log(`Transfer ${transferId} ready${isResume ? ` (resume: file=${resumeFileIndex}, offset=${resumeFileOffset}, transferred=${resumeBytesTransferred})` : ''}`);

    // Move pending transfer to active with the server's assigned ID
    if (this.pendingTransfer) {
      this.pendingTransfer.id = transferId;
      this.activeTransfers.set(transferId, this.pendingTransfer);
      this.pendingTransfer = null;
    }

    const transfer = this.activeTransfers.get(transferId);
    if (transfer) {
      transfer.state = 'ready';

      if (isResume) {
        // Store resume position — will be applied when FILE_LIST arrives
        transfer.resumePosition = {
          fileIndex: resumeFileIndex,
          fileOffset: resumeFileOffset,
          bytesTransferred: resumeBytesTransferred,
        };
        // Don't start uploading yet — server sends FILE_LIST next for resumes
      } else if (transfer.direction === 'upload' && transfer.files) {
        // Fresh upload — start sending immediately
        transfer.state = 'transferring';
        this.sendNextChunk(transferId).catch(err => console.error('Send chunk failed:', err));
      }
    }
  }

  private handleFileList(data: ArrayBuffer): void {
    const view = new DataView(data);
    const bytes = new Uint8Array(data);

    const transferId = view.getUint32(PROTO_HEADER.TRANSFER_ID, true);
    const fileCount = view.getUint32(PROTO_FILE_LIST.FILE_COUNT, true);
    const totalBytes = Number(view.getBigUint64(PROTO_FILE_LIST.TOTAL_BYTES, true));
    let offset = PROTO_FILE_LIST.PAYLOAD;

    const files: TransferFile[] = [];
    for (let i = 0; i < fileCount; i++) {
      const pathLen = view.getUint16(offset, true); offset += PROTO_SIZE.UINT16;
      const path = sharedTextDecoder.decode(bytes.slice(offset, offset + pathLen)); offset += pathLen;
      const size = Number(view.getBigUint64(offset, true)); offset += PROTO_SIZE.UINT64;
      const mtime = Number(view.getBigUint64(offset, true)); offset += PROTO_SIZE.UINT64;
      const hash = view.getBigUint64(offset, true); offset += PROTO_SIZE.UINT64;
      const isDir = bytes[offset] !== 0; offset += PROTO_SIZE.UINT8;

      files.push({ path, size, mtime, hash, isDir });
    }

    const transfer = this.activeTransfers.get(transferId);
    if (transfer) {
      transfer.files = files;
      transfer.totalBytes = totalBytes;
      transfer.state = 'transferring';

      // Apply resume position if set (from handleTransferReady during resume)
      if (transfer.resumePosition) {
        transfer.currentFileIndex = transfer.resumePosition.fileIndex;
        transfer.currentChunkOffset = transfer.resumePosition.fileOffset;
        transfer.bytesTransferred = transfer.resumePosition.bytesTransferred;
        transfer.resumePosition = undefined;
      } else {
        transfer.currentFileIndex = 0;
        transfer.bytesTransferred = 0;
      }

      if (transfer.direction === 'download') {
        this.requestNextFile(transferId);
      } else if (transfer.direction === 'upload' && transfer.files) {
        // Resume upload — start sending from resume position
        this.sendNextChunk(transferId).catch(err => console.error('Send chunk failed:', err));
      }
    }
  }

  // For downloads, the server pushes FILE_REQUEST messages
  // This is called after we've fully received a file
  private requestNextFile(_transferId: number): void {
    // No-op - server pushes FILE_REQUEST messages
  }

  private async handleFileRequest(data: ArrayBuffer): Promise<void> {
    const view = new DataView(data);
    const bytes = new Uint8Array(data);

    const transferId = view.getUint32(PROTO_HEADER.TRANSFER_ID, true);
    const fileIndex = view.getUint32(PROTO_FILE_REQUEST.FILE_INDEX, true);
    const chunkOffset = Number(view.getBigUint64(PROTO_FILE_REQUEST.CHUNK_OFFSET, true));
    const compressedData = bytes.slice(PROTO_FILE_REQUEST.DATA);

    const transfer = this.activeTransfers.get(transferId);
    if (!transfer || !transfer.files) return;
    if (fileIndex >= transfer.files.length) return;

    const file = transfer.files[fileIndex];

    if (this.worker && this.workerReady) {
      // Delegate to Worker: decompress + OPFS write (or decompress-only fallback)
      const buffer = compressedData.buffer.slice(
        compressedData.byteOffset,
        compressedData.byteOffset + compressedData.byteLength,
      );
      this.worker.postMessage({
        type: 'decompress-and-write',
        transferId,
        fileIndex,
        filePath: file.path,
        offset: chunkOffset,
        compressedData: buffer,
        fileSize: file.size,
      }, [buffer]);
    } else {
      // Fallback: decompress on main thread, accumulate in memory
      try {
        const fileData = await this.decompress(compressedData);
        this.accumulateAndSave(transferId, fileIndex, chunkOffset, fileData);
      } catch (err) {
        console.error('Decompression failed:', err);
        this.failTransfer(transferId, err instanceof Error ? err.message : 'Decompression failed');
      }
    }
  }

  /** Handle BATCH_DATA: multiple small files compressed as one block */
  private async handleBatchData(data: ArrayBuffer): Promise<void> {
    const view = new DataView(data);
    const bytes = new Uint8Array(data);

    const transferId = view.getUint32(PROTO_HEADER.TRANSFER_ID, true);
    const uncompressedSize = view.getUint32(PROTO_BATCH_DATA.UNCOMPRESSED_SIZE, true);
    const compressedData = bytes.slice(PROTO_BATCH_DATA.DATA);

    const transfer = this.activeTransfers.get(transferId);
    if (!transfer || !transfer.files) return;

    let payload: Uint8Array;
    try {
      payload = await this.decompress(compressedData);
    } catch (err) {
      console.error('Batch decompression failed:', err);
      this.failTransfer(transferId, 'Batch decompression failed');
      return;
    }

    if (payload.length !== uncompressedSize) {
      console.warn(`Batch size mismatch: expected ${uncompressedSize}, got ${payload.length}`);
    }

    // Parse batch payload: [file_count:u16] then per file: [file_index:u32][size:u32][data...]
    const batchView = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
    let offset = 0;
    const fileCount = batchView.getUint16(offset, true); offset += 2;

    for (let i = 0; i < fileCount; i++) {
      if (offset + 8 > payload.length) break;

      const fileIndex = batchView.getUint32(offset, true); offset += 4;
      const fileSize = batchView.getUint32(offset, true); offset += 4;

      if (offset + fileSize > payload.length) break;
      if (fileIndex >= transfer.files.length) {
        offset += fileSize;
        continue;
      }

      const fileData = payload.slice(offset, offset + fileSize);
      offset += fileSize;

      const file = transfer.files[fileIndex];
      transfer.bytesTransferred += fileData.length;

      // Small batched files are always complete — save directly
      this.saveFile(file.path, fileData);
      this.cacheDownloadedFile(transfer, file.path, fileData);
    }
  }

  /** Worker callback: chunk decompressed and written to OPFS */
  private onChunkWrittenToOPFS(msg: { transferId: number; fileIndex: number; filePath: string; bytesWritten: number; complete: boolean }): void {
    const transfer = this.activeTransfers.get(msg.transferId);
    if (!transfer || !transfer.files) return;

    transfer.bytesTransferred += msg.bytesWritten;

    if (msg.complete) {
      // File fully written to OPFS — read it back for browser download
      this.worker!.postMessage({
        type: 'get-file',
        transferId: msg.transferId,
        filePath: msg.filePath,
      });
      transfer.currentFileIndex++;
    }
  }

  /** Worker callback: no OPFS available, decompressed data returned */
  private onChunkDecompressedNoOPFS(msg: { transferId: number; fileIndex: number; filePath: string; offset: number; data: ArrayBuffer; bytesWritten: number }): void {
    this.accumulateAndSave(msg.transferId, msg.fileIndex, msg.offset, new Uint8Array(msg.data));
  }

  /** Worker callback: file data read from OPFS for browser download */
  private onFileDataFromOPFS(msg: { transferId: number; filePath: string; data: ArrayBuffer }): void {
    const transfer = this.activeTransfers.get(msg.transferId);
    if (!transfer) return;

    const data = new Uint8Array(msg.data);
    this.saveFile(msg.filePath, data);
    this.cacheDownloadedFile(transfer, msg.filePath, data);
  }

  /** Accumulate decompressed chunks in memory and save when file is complete */
  private accumulateAndSave(transferId: number, fileIndex: number, chunkOffset: number, fileData: Uint8Array): void {
    const transfer = this.activeTransfers.get(transferId);
    if (!transfer || !transfer.files || transfer.state === 'complete' || transfer.state === 'error') return;
    if (fileIndex >= transfer.files.length) return;

    const file = transfer.files[fileIndex];

    if (!transfer.receivedFiles) transfer.receivedFiles = new Map();
    let fileChunks = transfer.receivedFiles.get(fileIndex);
    if (!fileChunks) {
      fileChunks = [];
      transfer.receivedFiles.set(fileIndex, fileChunks);
    }
    fileChunks.push({ offset: chunkOffset, data: fileData });

    transfer.bytesTransferred += fileData.length;

    // Check per-file completion using accumulated chunk bytes
    const fileBytes = fileChunks.reduce((sum, c) => sum + c.data.length, 0);
    if (fileBytes >= file.size) {
      const chunks = fileChunks;
      chunks.sort((a, b) => a.offset - b.offset);
      const fullData = new Uint8Array(file.size);
      let writeOffset = 0;
      for (const chunk of chunks) {
        fullData.set(chunk.data, writeOffset);
        writeOffset += chunk.data.length;
      }

      if (!this.saveFile(file.path, fullData)) {
        this.failTransfer(transferId, `Failed to save file: ${file.path}`);
        return;
      }
      this.cacheDownloadedFile(transfer, file.path, fullData);
      transfer.receivedFiles.delete(fileIndex);
      transfer.currentFileIndex++;
    }
  }

  /** Cache a downloaded file for future delta sync */
  private cacheDownloadedFile(transfer: TransferState, filePath: string, data: Uint8Array): void {
    if (!this.cache || !transfer.serverPath) return;

    // Find file metadata from the transfer's file list
    const fileEntry = transfer.files?.find(f => f.path === filePath);
    if (!fileEntry) return;

    const buffer = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) as ArrayBuffer;
    this.cache.putFile(transfer.serverPath!, filePath, buffer, {
      size: fileEntry.size,
      mtime: fileEntry.mtime ?? 0,
      hash: fileEntry.hash?.toString() ?? '0',
    }).catch(() => { /* cache is best-effort */ });
  }

  /** Mark a transfer as failed and clean up */
  private failTransfer(transferId: number, message: string): void {
    const transfer = this.activeTransfers.get(transferId);
    if (transfer) {
      transfer.state = 'error';
      transfer.receivedFiles?.clear();
      this.activeTransfers.delete(transferId);
      this.onTransferError?.(transferId, message);
    }
    // Clean up OPFS temp files
    this.worker?.postMessage({ type: 'cleanup', transferId });
  }

  private handleFileAck(data: ArrayBuffer): void {
    const view = new DataView(data);
    const transferId = view.getUint32(PROTO_HEADER.TRANSFER_ID, true);
    const bytesReceived = Number(view.getBigUint64(PROTO_FILE_ACK.BYTES_RECEIVED, true));

    const transfer = this.activeTransfers.get(transferId);
    if (transfer && transfer.state !== 'error' && transfer.state !== 'complete') {
      transfer.bytesTransferred = bytesReceived;
      this.sendNextChunk(transferId).catch(err => console.error('Send chunk failed:', err));
    }
  }

  private handleTransferComplete(data: ArrayBuffer): void {
    const view = new DataView(data);
    const transferId = view.getUint32(PROTO_HEADER.TRANSFER_ID, true);
    const totalBytes = Number(view.getBigUint64(PROTO_TRANSFER_COMPLETE.TOTAL_BYTES, true));

    console.log(`Transfer ${transferId} complete`);

    const transfer = this.activeTransfers.get(transferId);
    if (transfer) {
      transfer.state = 'complete';
    }
    this.activeTransfers.delete(transferId);
    this.onTransferComplete?.(transferId, totalBytes);

    // Clean up OPFS temp files for this transfer
    this.worker?.postMessage({ type: 'cleanup', transferId });
  }

  private handleTransferError(data: ArrayBuffer): void {
    const view = new DataView(data);
    const bytes = new Uint8Array(data);

    const transferId = view.getUint32(PROTO_HEADER.TRANSFER_ID, true);
    const errorLen = view.getUint16(PROTO_TRANSFER_ERROR.ERROR_LEN, true);
    const error = sharedTextDecoder.decode(
      bytes.slice(PROTO_TRANSFER_ERROR.ERROR_MSG, PROTO_TRANSFER_ERROR.ERROR_MSG + errorLen)
    );

    console.error(`Transfer ${transferId} error: ${error}`);
    this.activeTransfers.delete(transferId);
    this.onTransferError?.(transferId, error);
  }

  private handleDryRunReport(data: ArrayBuffer): void {
    const view = new DataView(data);
    const bytes = new Uint8Array(data);

    const transferId = view.getUint32(PROTO_HEADER.TRANSFER_ID, true);
    const newCount = view.getUint32(PROTO_DRY_RUN.NEW_COUNT, true);
    const updateCount = view.getUint32(PROTO_DRY_RUN.UPDATE_COUNT, true);
    const deleteCount = view.getUint32(PROTO_DRY_RUN.DELETE_COUNT, true);
    let offset = PROTO_DRY_RUN.ENTRIES;

    const entries: Array<{ action: string; path: string; size: number }> = [];
    while (offset < data.byteLength) {
      const action = bytes[offset]; offset += PROTO_SIZE.UINT8;
      const pathLen = view.getUint16(offset, true); offset += PROTO_SIZE.UINT16;
      const path = sharedTextDecoder.decode(bytes.slice(offset, offset + pathLen)); offset += pathLen;
      const size = Number(view.getBigUint64(offset, true)); offset += PROTO_SIZE.UINT64;

      entries.push({ action: action < DRY_RUN_ACTION.length ? DRY_RUN_ACTION[action] : 'unknown', path, size });
    }

    this.onDryRunReport?.(transferId, { newCount, updateCount, deleteCount, entries });
  }

  async startFolderUpload(
    dirHandle: FileSystemDirectoryHandle,
    serverPath: string,
    options: TransferOptions = {}
  ): Promise<void> {
    if (!this.canSend()) {
      console.error('File transfer not connected');
      this.onTransferError?.(0, 'File transfer connection not available');
      return;
    }

    const { deleteExtra = false, dryRun = false, excludes = [] } = options;

    let files: Awaited<ReturnType<typeof this.collectFilesFromHandle>>;
    try {
      files = await this.collectFilesFromHandle(dirHandle, '');
    } catch (err) {
      console.error('Failed to collect files:', err);
      this.onTransferError?.(0, err instanceof Error ? err.message : 'Failed to collect files');
      return;
    }

    const pathBytes = sharedTextEncoder.encode(serverPath);
    const excludeBytes = excludes.map(p => sharedTextEncoder.encode(p));
    const excludeTotalLen = excludeBytes.reduce((acc, b) => acc + 1 + b.length, 0);

    const msgLen = 1 + 1 + 1 + 1 + 2 + pathBytes.length + excludeTotalLen;
    const msg = new ArrayBuffer(msgLen);
    const view = new DataView(msg);
    const bytes = new Uint8Array(msg);

    let offset = 0;
    view.setUint8(offset, TransferMsgType.TRANSFER_INIT); offset += 1;
    view.setUint8(offset, 0); offset += 1; // direction: upload
    view.setUint8(offset, (deleteExtra ? 1 : 0) | (dryRun ? 2 : 0)); offset += 1;
    view.setUint8(offset, excludes.length); offset += 1;
    view.setUint16(offset, pathBytes.length, true); offset += 2;
    bytes.set(pathBytes, offset); offset += pathBytes.length;

    for (const exclude of excludeBytes) {
      view.setUint8(offset, exclude.length); offset += 1;
      bytes.set(exclude, offset); offset += exclude.length;
    }

    this.send(msg);

    // Store as pending — server will assign the real ID in TRANSFER_READY
    this.pendingTransfer = {
      id: 0,
      direction: 'upload',
      files,
      dirHandle,
      options,
      state: 'pending',
      bytesTransferred: 0,
      currentFileIndex: 0,
    };
  }

  async startFilesUpload(
    files: File[],
    serverPath: string,
    options: TransferOptions = {}
  ): Promise<void> {
    if (!this.canSend()) {
      console.error('File transfer not connected');
      this.onTransferError?.(0, 'File transfer connection not available');
      return;
    }

    const { deleteExtra = false, dryRun = false, excludes = [] } = options;

    const transferFiles: TransferFile[] = files.map(f => ({
      path: f.name,
      isDir: false,
      size: f.size,
      file: f,
    }));

    const pathBytes = sharedTextEncoder.encode(serverPath);
    const excludeBytes = excludes.map(p => sharedTextEncoder.encode(p));
    const excludeTotalLen = excludeBytes.reduce((acc, b) => acc + 1 + b.length, 0);

    const msgLen = 1 + 1 + 1 + 1 + 2 + pathBytes.length + excludeTotalLen;
    const msg = new ArrayBuffer(msgLen);
    const view = new DataView(msg);
    const bytes = new Uint8Array(msg);

    let offset = 0;
    view.setUint8(offset, TransferMsgType.TRANSFER_INIT); offset += 1;
    view.setUint8(offset, 0); offset += 1; // direction: upload
    view.setUint8(offset, (deleteExtra ? 1 : 0) | (dryRun ? 2 : 0)); offset += 1;
    view.setUint8(offset, excludes.length); offset += 1;
    view.setUint16(offset, pathBytes.length, true); offset += 2;
    bytes.set(pathBytes, offset); offset += pathBytes.length;

    for (const exclude of excludeBytes) {
      view.setUint8(offset, exclude.length); offset += 1;
      bytes.set(exclude, offset); offset += exclude.length;
    }

    this.send(msg);

    // Store as pending — server will assign the real ID in TRANSFER_READY
    this.pendingTransfer = {
      id: 0,
      direction: 'upload',
      files: transferFiles,
      options,
      state: 'pending',
      bytesTransferred: 0,
      currentFileIndex: 0,
    };
  }

  async startFolderDownload(serverPath: string, options: TransferOptions = {}): Promise<void> {
    if (!this.canSend()) {
      console.error('File transfer not connected');
      this.onTransferError?.(0, 'File transfer connection not available');
      return;
    }

    const { deleteExtra = false, dryRun = false, excludes = [] } = options;

    const pathBytes = sharedTextEncoder.encode(serverPath);
    const excludeBytes = excludes.map(p => sharedTextEncoder.encode(p));
    const excludeTotalLen = excludeBytes.reduce((acc, b) => acc + 1 + b.length, 0);

    const msgLen = 1 + 1 + 1 + 1 + 2 + pathBytes.length + excludeTotalLen;
    const msg = new ArrayBuffer(msgLen);
    const view = new DataView(msg);
    const bytes = new Uint8Array(msg);

    let offset = 0;
    view.setUint8(offset, TransferMsgType.TRANSFER_INIT); offset += 1;
    view.setUint8(offset, 1); offset += 1; // direction: download
    view.setUint8(offset, (deleteExtra ? 1 : 0) | (dryRun ? 2 : 0)); offset += 1;
    view.setUint8(offset, excludes.length); offset += 1;
    view.setUint16(offset, pathBytes.length, true); offset += 2;
    bytes.set(pathBytes, offset); offset += pathBytes.length;

    for (const exclude of excludeBytes) {
      view.setUint8(offset, exclude.length); offset += 1;
      bytes.set(exclude, offset); offset += exclude.length;
    }

    this.send(msg);

    // Store as pending — server will assign the real ID in TRANSFER_READY
    this.pendingTransfer = {
      id: 0,
      direction: 'download',
      serverPath,
      options,
      state: 'pending',
      bytesTransferred: 0,
      currentFileIndex: 0,
    };
  }

  private async collectFilesFromHandle(
    dirHandle: FileSystemDirectoryHandle,
    prefix: string
  ): Promise<TransferFile[]> {
    const files: TransferFile[] = [];

    try {
      for await (const [name, handle] of (dirHandle as unknown as FileSystemDirectoryHandleIterator).entries()) {
        const path = prefix ? `${prefix}/${name}` : name;

        if (handle.kind === 'directory') {
          files.push({ path, isDir: true, size: 0 });
          const subFiles = await this.collectFilesFromHandle(handle as FileSystemDirectoryHandle, path);
          files.push(...subFiles);
        } else {
          const fileHandle = handle as FileSystemFileHandle;
          const file = await fileHandle.getFile();
          files.push({
            path,
            isDir: false,
            size: file.size,
            handle: fileHandle,
            file,
          });
        }
      }
    } catch (err) {
      console.error('Failed to collect files from directory:', prefix || '(root)', err);
      throw err; // Re-throw to let caller handle
    }

    return files;
  }

  private async sendNextChunk(transferId: number): Promise<void> {
    const transfer = this.activeTransfers.get(transferId);
    if (!transfer || transfer.direction !== 'upload' || !transfer.files) return;

    // Bounds check before array access
    if (transfer.currentFileIndex >= transfer.files.length) return;

    const file = transfer.files[transfer.currentFileIndex];
    if (!file || file.isDir) {
      transfer.currentFileIndex++;
      if (transfer.currentFileIndex < transfer.files.length) {
        this.sendNextChunk(transferId).catch(err => console.error('Send chunk failed:', err));
      }
      return;
    }

    if (!file.file) return;

    let fileData: ArrayBuffer;
    let compressed: Uint8Array;
    try {
      fileData = await file.file.arrayBuffer();
    } catch (err) {
      console.error('Failed to read file data:', err);
      const failedTransfer = this.activeTransfers.get(transferId);
      if (failedTransfer) failedTransfer.state = 'error';
      this.onTransferError?.(transferId, `Failed to read file: ${file.path}`);
      return;
    }

    const chunkStart = transfer.currentChunkOffset || 0;
    const chunkEnd = Math.min(chunkStart + this.chunkSize, fileData.byteLength);
    const chunk = new Uint8Array(fileData.slice(chunkStart, chunkEnd));

    try {
      compressed = await this.compress(chunk);
    } catch (err) {
      console.error('Compression failed:', err);
      const failedTransfer = this.activeTransfers.get(transferId);
      if (failedTransfer) failedTransfer.state = 'error';
      this.onTransferError?.(transferId, 'Compression failed');
      return;
    }

    // Re-validate transfer still exists after async operations
    const currentTransfer = this.activeTransfers.get(transferId);
    if (!currentTransfer || currentTransfer.state === 'error' || currentTransfer.state === 'complete') {
      return;
    }

    const msgLen = 1 + 4 + 4 + 8 + 4 + compressed.length;
    const msg = new ArrayBuffer(msgLen);
    const view = new DataView(msg);
    const bytes = new Uint8Array(msg);

    let offset = 0;
    view.setUint8(offset, TransferMsgType.FILE_DATA); offset += 1;
    view.setUint32(offset, currentTransfer.id, true); offset += 4;
    view.setUint32(offset, currentTransfer.currentFileIndex, true); offset += 4;
    view.setBigUint64(offset, BigInt(chunkStart), true); offset += 8;
    view.setUint32(offset, chunk.length, true); offset += 4;
    bytes.set(compressed, offset);

    this.send(msg);

    currentTransfer.currentChunkOffset = chunkEnd;
    if (chunkEnd >= fileData.byteLength) {
      currentTransfer.currentFileIndex++;
      currentTransfer.currentChunkOffset = 0;
    }
  }

  private async compress(data: Uint8Array): Promise<Uint8Array> {
    // Prefer Worker for off-thread compression
    if (this.worker && this.workerReady) {
      return this.compressViaWorker(data, FILE_TRANSFER.COMPRESSION_LEVEL);
    }
    if (this.compressionPool) {
      return await this.compressionPool.compress(data, FILE_TRANSFER.COMPRESSION_LEVEL);
    }
    return data;
  }

  private async decompress(data: Uint8Array): Promise<Uint8Array> {
    // Prefer Worker for off-thread decompression
    if (this.worker && this.workerReady) {
      return this.decompressViaWorker(data);
    }
    if (this.compressionPool) {
      return await this.compressionPool.decompress(data);
    }
    throw new Error('Decompression unavailable: zstd WASM not initialized');
  }

  private compressViaWorker(data: Uint8Array, level: number): Promise<Uint8Array> {
    return new Promise((resolve, reject) => {
      const id = this.nextCompressionId++;
      this.pendingCompression.set(id, { resolve, reject });
      const buffer = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
      this.worker!.postMessage({ type: 'compress', id, data: buffer, level }, [buffer]);
    });
  }

  private decompressViaWorker(data: Uint8Array): Promise<Uint8Array> {
    return new Promise((resolve, reject) => {
      const id = this.nextCompressionId++;
      this.pendingCompression.set(id, { resolve, reject });
      const buffer = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
      this.worker!.postMessage({ type: 'decompress', id, data: buffer }, [buffer]);
    });
  }

  // ── Rsync delta sync flow ──

  /** Start an incremental sync for a server path.
   *  Sends SYNC_REQUEST to the server, which replies with SYNC_FILE_LIST. */
  async startSync(serverPath: string, options: TransferOptions = {}): Promise<void> {
    if (!this.canSend()) {
      this.onTransferError?.(0, 'File transfer connection not available');
      return;
    }

    if (!this.cache?.available) {
      // No OPFS cache — fall back to full download
      return this.startFolderDownload(serverPath, options);
    }

    const { excludes = [] } = options;
    const pathBytes = sharedTextEncoder.encode(serverPath);
    const excludeBytes = excludes.map(p => sharedTextEncoder.encode(p));
    const excludeTotalLen = excludeBytes.reduce((acc, b) => acc + 1 + b.length, 0);

    // SYNC_REQUEST: [msg_type:1][flags:1][path_len:2][path][exclude_count:1][excludes...]
    const msgLen = 1 + 1 + 2 + pathBytes.length + 1 + excludeTotalLen;
    const msg = new ArrayBuffer(msgLen);
    const view = new DataView(msg);
    const bytes = new Uint8Array(msg);

    let offset = 0;
    view.setUint8(offset, TransferMsgType.SYNC_REQUEST); offset += 1;
    view.setUint8(offset, 0); offset += 1; // flags: 0 = recursive
    view.setUint16(offset, pathBytes.length, true); offset += 2;
    bytes.set(pathBytes, offset); offset += pathBytes.length;
    view.setUint8(offset, excludes.length); offset += 1;

    for (const exclude of excludeBytes) {
      view.setUint8(offset, exclude.length); offset += 1;
      bytes.set(exclude, offset); offset += exclude.length;
    }

    this.send(msg);

    this.pendingTransfer = {
      id: 0,
      direction: 'sync',
      serverPath,
      options,
      state: 'pending',
      bytesTransferred: 0,
      currentFileIndex: 0,
      syncFilesProcessed: 0,
    };
  }

  /** Handle SYNC_FILE_LIST from server: compare with OPFS cache, send checksums for changed files */
  private async handleSyncFileList(data: ArrayBuffer): Promise<void> {
    const view = new DataView(data);
    const bytes = new Uint8Array(data);

    const transferId = view.getUint32(PROTO_HEADER.TRANSFER_ID, true);
    const fileCount = view.getUint32(PROTO_SYNC_FILE_LIST.FILE_COUNT, true);
    const totalBytes = Number(view.getBigUint64(PROTO_SYNC_FILE_LIST.TOTAL_BYTES, true));
    let offset = PROTO_SYNC_FILE_LIST.PAYLOAD;

    // Parse the server's file list (same format as FILE_LIST)
    const serverFiles: TransferFile[] = [];
    for (let i = 0; i < fileCount; i++) {
      const pathLen = view.getUint16(offset, true); offset += PROTO_SIZE.UINT16;
      const path = sharedTextDecoder.decode(bytes.slice(offset, offset + pathLen)); offset += pathLen;
      const size = Number(view.getBigUint64(offset, true)); offset += PROTO_SIZE.UINT64;
      const mtime = Number(view.getBigUint64(offset, true)); offset += PROTO_SIZE.UINT64;
      const hash = view.getBigUint64(offset, true); offset += PROTO_SIZE.UINT64;
      const isDir = bytes[offset] !== 0; offset += PROTO_SIZE.UINT8;

      serverFiles.push({ path, size, mtime, hash, isDir });
    }

    // Activate the transfer if it's pending
    if (this.pendingTransfer) {
      this.pendingTransfer.id = transferId;
      this.activeTransfers.set(transferId, this.pendingTransfer);
      this.pendingTransfer = null;
    }

    const transfer = this.activeTransfers.get(transferId);
    if (!transfer) return;

    transfer.files = serverFiles;
    transfer.totalBytes = totalBytes;
    transfer.state = 'transferring';

    // Compare with OPFS cache and send block checksums for changed files
    const cachedMeta: Record<string, CachedFileMeta> = await this.cache!.listFiles(transfer.serverPath!).catch(() => ({}));

    for (let i = 0; i < serverFiles.length; i++) {
      const file = serverFiles[i];
      if (file.isDir) continue;

      const cached = cachedMeta[file.path];

      if (cached && cached.size === file.size && cached.mtime === (file.mtime ?? 0)) {
        // Same size + mtime → skip (file unchanged)
        continue;
      }

      if (cached) {
        // File changed — compute block checksums of our cached copy and send to server
        const blockSize = this.computeBlockSize(cached.size);
        try {
          const { rolling, strong } = await this.cache!.computeBlockChecksums(
            transfer.serverPath!,
            file.path,
            blockSize,
          );

          this.sendBlockChecksums(transferId, i, blockSize, rolling, strong);
        } catch {
          // Checksum computation failed — server will send full file as literal-only delta
          this.sendBlockChecksums(transferId, i, blockSize, new Uint32Array(0), new BigUint64Array(0));
        }
      } else {
        // New file — send empty checksums so server sends full content as literal
        this.sendBlockChecksums(transferId, i, 0, new Uint32Array(0), new BigUint64Array(0));
      }
    }
  }

  /** Send BLOCK_CHECKSUMS message to server */
  private sendBlockChecksums(
    transferId: number,
    fileIndex: number,
    blockSize: number,
    rolling: Uint32Array,
    strong: BigUint64Array,
  ): void {
    const count = rolling.length;
    // BLOCK_CHECKSUMS: [msg_type:1][transfer_id:4][file_index:4][block_size:4][count:4]
    //   per entry: [rolling:4][strong:8] = 12 bytes each
    const msgLen = 1 + 4 + 4 + 4 + 4 + (count * 12);
    const msg = new ArrayBuffer(msgLen);
    const view = new DataView(msg);

    let offset = 0;
    view.setUint8(offset, TransferMsgType.BLOCK_CHECKSUMS); offset += 1;
    view.setUint32(offset, transferId, true); offset += 4;
    view.setUint32(offset, fileIndex, true); offset += 4;
    view.setUint32(offset, blockSize, true); offset += 4;
    view.setUint32(offset, count, true); offset += 4;

    // Write interleaved checksums: [rolling:u32][strong:u64] per block
    for (let i = 0; i < count; i++) {
      view.setUint32(offset, rolling[i], true); offset += 4;
      view.setBigUint64(offset, strong[i], true); offset += 8;
    }

    this.send(msg);
  }

  /** Handle DELTA_DATA from server: apply delta to cached file or save new file */
  private async handleDeltaData(data: ArrayBuffer): Promise<void> {
    const view = new DataView(data);
    const bytes = new Uint8Array(data);

    const transferId = view.getUint32(PROTO_HEADER.TRANSFER_ID, true);
    const fileIndex = view.getUint32(PROTO_DELTA_DATA.FILE_INDEX, true);
    const _uncompressedSize = view.getUint32(PROTO_DELTA_DATA.UNCOMPRESSED_SIZE, true);
    const compressedPayload = bytes.slice(PROTO_DELTA_DATA.DATA);

    const transfer = this.activeTransfers.get(transferId);
    if (!transfer || !transfer.files) return;
    if (fileIndex >= transfer.files.length) return;

    const file = transfer.files[fileIndex];

    // Decompress the delta payload
    let decompressedDelta: Uint8Array;
    try {
      decompressedDelta = await this.decompress(compressedPayload);
    } catch {
      // If decompression fails, the payload may be uncompressed
      decompressedDelta = compressedPayload;
    }

    try {
      // Try to apply delta against cached copy
      const resultBuf = await this.cache!.applyDelta(
        transfer.serverPath!,
        file.path,
        decompressedDelta.buffer.slice(
          decompressedDelta.byteOffset,
          decompressedDelta.byteOffset + decompressedDelta.byteLength,
        ) as ArrayBuffer,
      );
      const resultData = new Uint8Array(resultBuf);

      transfer.bytesTransferred += resultData.length;
      transfer.syncFilesProcessed = (transfer.syncFilesProcessed ?? 0) + 1;

      // Update the OPFS cache with the new version
      this.cache!.putFile(transfer.serverPath!, file.path, resultBuf, {
        size: resultData.length,
        mtime: file.mtime ?? 0,
        hash: file.hash?.toString() ?? '0',
      }).catch(() => { /* best-effort */ });

      // Send SYNC_ACK for this file
      this.sendSyncAck(transferId, fileIndex, resultData.length);
    } catch {
      // Delta application failed (no cached copy or corrupt) — treat as error
      transfer.syncFilesProcessed = (transfer.syncFilesProcessed ?? 0) + 1;
      this.sendSyncAck(transferId, fileIndex, 0);
    }
  }

  /** Send SYNC_ACK to server confirming delta was applied */
  private sendSyncAck(transferId: number, fileIndex: number, bytesApplied: number): void {
    // SYNC_ACK: [msg_type:1][transfer_id:4][file_index:4][bytes_applied:8]
    const msg = new ArrayBuffer(1 + 4 + 4 + 8);
    const view = new DataView(msg);
    view.setUint8(0, TransferMsgType.SYNC_ACK);
    view.setUint32(1, transferId, true);
    view.setUint32(5, fileIndex, true);
    view.setBigUint64(9, BigInt(bytesApplied), true);
    this.send(msg);
  }

  /** Handle SYNC_COMPLETE from server */
  private handleSyncComplete(data: ArrayBuffer): void {
    const view = new DataView(data);
    const transferId = view.getUint32(PROTO_HEADER.TRANSFER_ID, true);
    const filesSynced = view.getUint32(PROTO_SYNC_COMPLETE.FILES_SYNCED, true);
    const bytesTransferred = Number(view.getBigUint64(PROTO_SYNC_COMPLETE.BYTES_TRANSFERRED, true));

    console.log(`Sync ${transferId} complete: ${filesSynced} files, ${bytesTransferred} bytes`);

    const transfer = this.activeTransfers.get(transferId);
    if (transfer) {
      transfer.state = 'complete';
    }
    this.activeTransfers.delete(transferId);
    this.onTransferComplete?.(transferId, bytesTransferred);
  }

  /** Compute adaptive block size: sqrt(file_size) clamped to [512, 65536] */
  private computeBlockSize(fileSize: number): number {
    const size = Math.floor(Math.sqrt(fileSize));
    return Math.max(512, Math.min(65536, size));
  }

  private saveFile(path: string, data: Uint8Array): boolean {
    const filename = path.split('/').pop() || path;
    // Ensure data is backed by regular ArrayBuffer (not SharedArrayBuffer)
    const blob = new Blob([new Uint8Array(data)]);
    const url = URL.createObjectURL(blob);
    try {
      const a = document.createElement('a');
      a.href = url;
      a.download = filename;
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      return true;
    } catch (err) {
      console.error('Failed to save file:', filename, err);
      return false;
    } finally {
      URL.revokeObjectURL(url);
    }
  }
}
