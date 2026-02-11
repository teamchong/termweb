// File transfer protocol and handlers
// Uses zstd WASM via dedicated Web Worker (off main thread)
// with synchronous OPFS access for file caching

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
  /** When true, files are being written to OPFS temp for zip creation (multi-file downloads) */
  useZipMode?: boolean;
  /** Count of files written to OPFS temp (for tracking progress) */
  filesCompleted?: number;
  /** True when TRANSFER_COMPLETE received but zip not yet created (waiting for async writes) */
  zipPending?: boolean;
  /** Timeout ID for fallback zip creation when files stop arriving */
  zipFallbackTimer?: ReturnType<typeof setTimeout>;
  /** True when zip creation has started (prevents multiple zip creations) */
  zipCreating?: boolean;
  /** Tracks file paths already marked complete (prevents duplicate completion counting) */
  completedPaths?: Set<string>;
}

export interface TransferOptions {
  dryRun?: boolean;
  excludes?: string[];
  useGitignore?: boolean;
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

  // Worker for off-thread zstd WASM
  private worker: Worker | null = null;
  private opfsAvailable = false;
  private workerInitPromise: Promise<void>;
  private pendingCompression = new Map<number, { resolve: (data: Uint8Array) => void; reject: (err: Error) => void }>();
  private nextCompressionId = 0;

  // OPFS cache for delta sync (created after worker init)
  cache: OPFSCache | null = null;

  onTransferComplete?: (transferId: number, totalBytes: number) => void;
  onTransferError?: (transferId: number, error: string) => void;
  onTransferCancelled?: (transferId: number) => void;
  onDryRunReport?: (transferId: number, report: DryRunReport) => void;
  onTransferStart?: (transferId: number, path: string, direction: 'upload' | 'download', totalFiles: number, totalBytes: number) => void;
  onDownloadProgress?: (transferId: number, filesCompleted: number, totalFiles: number, bytesTransferred: number, totalBytes: number) => void;
  onConnectionShouldClose?: () => void;

  constructor() {
    this.workerInitPromise = this.initWorker();
  }

  private async initWorker(): Promise<void> {
    return new Promise<void>((resolve) => {
      try {
        this.worker = new Worker('/file-worker.js?v=2');
        this.worker.onmessage = (e) => this.handleWorkerMessage(e);
        this.worker.onerror = (event) => {
          console.error('[FT] Worker failed to load:', event);
          this.worker = null;
          resolve();
        };

        this._workerInitResolve = () => { resolve(); };
        this.worker.postMessage({ type: 'init' });

        // Get OPFS root on main thread and send to worker
        console.log('[FT] navigator.storage exists:', !!navigator.storage);
        console.log('[FT] navigator.storage.getDirectory exists:', typeof navigator.storage?.getDirectory);
        if (navigator.storage?.getDirectory) {
          console.log('[FT] Calling navigator.storage.getDirectory()...');
          const opfsPromise = navigator.storage.getDirectory();
          // Detect hang: if getDirectory() doesn't resolve in 3s, log it
          const timeout = setTimeout(() => {
            console.error('[FT] navigator.storage.getDirectory() hung for 3s — OPFS unavailable in this environment');
          }, 3000);
          opfsPromise.then(root => {
            clearTimeout(timeout);
            console.log('[FT] Got OPFS root on main thread, sending to worker');
            this.worker?.postMessage({ type: 'set-opfs-root', opfsRoot: root });
          }).catch(err => {
            clearTimeout(timeout);
            console.warn('[FT] OPFS getDirectory() rejected:', err);
          });
        } else {
          console.warn('[FT] OPFS API not available (no navigator.storage.getDirectory)');
        }
      } catch (err) {
        console.error('[FT] Worker construction failed:', err);
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
        console.log('[FT] Worker WASM initialized');
        if (this.worker) {
          this.worker.onerror = (event) => {
            console.error('[FT] Worker runtime error:', event);
          };
        }
        this._workerInitResolve?.();
        this._workerInitResolve = null;
        break;

      case 'opfs-ready':
        console.log('[FT] Worker OPFS ready');
        this.opfsAvailable = true;
        if (this.worker) {
          this.cache = new OPFSCache(this.worker, true);
        }
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

      case 'file-data':
        this.onFileDataFromOPFS(msg);
        break;

      case 'cleanup-done':
        break;

      case 'metadata-saved':
      case 'metadata-deleted':
        // No action needed — fire-and-forget
        break;

      case 'metadata-loaded':
        // Will be handled by promise resolution
        break;

      case 'interrupted-transfers':
        // Will be handled by promise resolution
        break;

      case 'zip-created':
        console.log('[FT] Received zip-created message from worker');
        this.onZipCreated(msg);
        break;

      case 'error':
        console.error('[FT] Worker error:', msg.message, msg.originalType ? `(during ${msg.originalType})` : '');
        // If init failed inside the worker, resolve the init promise
        // so we don't also hit the timeout
        if (msg.originalType === 'init') {
          this._workerInitResolve?.();
          this._workerInitResolve = null;
        }
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

  /** Resume all interrupted uploads by re-initiating each as a fresh upload.
   *  Slices the file list to only remaining files and sends TRANSFER_INIT.
   *  Called by mux.ts when the file WS reconnects. */
  resumeInterruptedUploads(): void {
    if (!this.canSend()) return;
    for (const [, interrupted] of this.interruptedUploads) {
      if (!interrupted.files || !interrupted.serverPath) continue;

      // Slice file list to only remaining files (skip already-completed ones)
      const startIdx = interrupted.currentFileIndex;
      const remainingFiles = interrupted.files.slice(startIdx);
      if (remainingFiles.length === 0) continue;

      // Build and send a fresh TRANSFER_INIT
      const { dryRun = false, excludes = [], useGitignore = false } = interrupted.options ?? {};
      const pathBytes = sharedTextEncoder.encode(interrupted.serverPath);
      const excludeBytes = excludes.map(p => sharedTextEncoder.encode(p));
      const excludeTotalLen = excludeBytes.reduce((acc, b) => acc + 1 + b.length, 0);
      const msgLen = 1 + 1 + 1 + 1 + 2 + pathBytes.length + excludeTotalLen;
      const msg = new ArrayBuffer(msgLen);
      const view = new DataView(msg);
      const bytes = new Uint8Array(msg);
      let offset = 0;
      view.setUint8(offset, TransferMsgType.TRANSFER_INIT); offset += 1;
      view.setUint8(offset, 0); offset += 1; // direction: upload
      view.setUint8(offset, (dryRun ? 1 : 0) | (useGitignore ? 2 : 0)); offset += 1;
      view.setUint8(offset, excludes.length); offset += 1;
      view.setUint16(offset, pathBytes.length, true); offset += 2;
      bytes.set(pathBytes, offset); offset += pathBytes.length;
      for (const exclude of excludeBytes) {
        view.setUint8(offset, exclude.length); offset += 1;
        bytes.set(exclude, offset); offset += exclude.length;
      }
      this.send(msg);

      // Set as pending transfer — will get new ID from TRANSFER_READY
      this.pendingTransfer = {
        id: 0,
        direction: 'upload',
        files: remainingFiles,
        options: interrupted.options,
        state: 'pending',
        bytesTransferred: 0,
        currentFileIndex: 0,
        currentChunkOffset: 0,
        serverPath: interrupted.serverPath,
      };
    }
    this.interruptedUploads.clear();
  }

  /** Get interrupted downloads from OPFS metadata (persists across page reloads) */
  async getInterruptedDownloads(): Promise<any[]> {
    if (!this.worker) return [];

    return new Promise((resolve) => {
      const handler = (e: MessageEvent) => {
        if (e.data.type === 'interrupted-transfers') {
          this.worker?.removeEventListener('message', handler);
          resolve(e.data.transfers);
        }
      };
      this.worker!.addEventListener('message', handler);
      this.worker!.postMessage({ type: 'get-interrupted-transfers' });
    });
  }

  /** Resume an interrupted download by sending TRANSFER_RESUME */
  async resumeInterruptedDownload(metadata: any): Promise<void> {
    if (!this.canSend()) {
      console.error('[FT] Cannot resume - not connected');
      return;
    }

    console.log(`[FT] Resuming download ${metadata.transferId}: ${metadata.serverPath}`);

    // Restore options from persisted metadata
    const useGitignore = metadata.useGitignore ?? false;
    const excludes: string[] = metadata.excludes ?? [];
    const flagsByte = useGitignore ? 2 : 0; // bit1 = use_gitignore (dry_run is always false for resume)

    // Register as active transfer with restored options
    this.activeTransfers.set(metadata.transferId, {
      id: metadata.transferId,
      direction: 'download',
      totalBytes: metadata.totalBytes,
      bytesTransferred: metadata.bytesTransferred,
      currentFileIndex: metadata.completedFiles.length,
      state: 'pending',
      useZipMode: true,
      filesCompleted: metadata.completedFiles.length,
      serverPath: metadata.serverPath,
      options: { useGitignore, excludes },
    });

    // Build TRANSFER_RESUME with flags + excludes + completed files
    // [0x23][transfer_id:u32][flags:u8][exclude_count:u8][path_len:u16][path]
    // [[exclude_len:u8][exclude]]...[completed_count:u32][[file_path_len:u16][file_path]]...
    const pathBytes = sharedTextEncoder.encode(metadata.serverPath);
    const excludeBytes = excludes.map((p: string) => sharedTextEncoder.encode(p));
    const excludeTotalLen = excludeBytes.reduce((acc: number, b: Uint8Array) => acc + 1 + b.length, 0);
    const completedFilesData = metadata.completedFiles.map((f: string) => sharedTextEncoder.encode(f));
    const completedFilesLen = completedFilesData.reduce((sum: number, b: Uint8Array) => sum + 2 + b.length, 0);

    const msgLen = 1 + 4 + 1 + 1 + 2 + pathBytes.length + excludeTotalLen + 4 + completedFilesLen;
    const msg = new ArrayBuffer(msgLen);
    const view = new DataView(msg);
    const bytes = new Uint8Array(msg);

    let offset = 0;
    view.setUint8(offset, TransferMsgType.TRANSFER_RESUME); offset += 1;
    view.setUint32(offset, metadata.transferId, true); offset += 4;
    view.setUint8(offset, flagsByte); offset += 1;
    view.setUint8(offset, excludes.length); offset += 1;
    view.setUint16(offset, pathBytes.length, true); offset += 2;
    bytes.set(pathBytes, offset); offset += pathBytes.length;
    for (const exclude of excludeBytes) {
      view.setUint8(offset, exclude.length); offset += 1;
      bytes.set(exclude, offset); offset += exclude.length;
    }
    view.setUint32(offset, completedFilesData.length, true); offset += 4;
    for (const fileBytes of completedFilesData) {
      view.setUint16(offset, fileBytes.length, true); offset += 2;
      bytes.set(fileBytes, offset); offset += fileBytes.length;
    }

    this.send(msg);
    console.log(`[FT] Sent TRANSFER_RESUME for ${metadata.transferId} (useGitignore=${useGitignore}, excludes=${excludes.length})`);
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
        this.handleFileRequest(data);
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
        this.handleBatchData(data);
        break;
      case TransferMsgType.SYNC_FILE_LIST:
        this.handleSyncFileList(data);
        break;
      case TransferMsgType.DELTA_DATA:
        this.handleDeltaData(data);
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
    console.log(`[FT] TRANSFER_READY: transferId=${transferId}${isResume ? ` (resume: file=${resumeFileIndex}, offset=${resumeFileOffset}, transferred=${resumeBytesTransferred})` : ''}`);

    // Move pending transfer to active with the server's assigned ID
    if (this.pendingTransfer) {
      console.log(`[FT] Moving pending transfer to active with ID ${transferId}`);
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
        // Send file list to server so it can map file indices to paths
        this.sendUploadFileList(transferId, transfer.files);
        transfer.state = 'transferring';

        // Notify UI that upload has started
        const nonDirFiles = transfer.files.filter(f => !f.isDir);
        const totalBytes = nonDirFiles.reduce((sum, f) => sum + f.size, 0);
        transfer.totalBytes = totalBytes;
        this.onTransferStart?.(transferId, transfer.serverPath ?? '', 'upload', nonDirFiles.length, totalBytes);

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

    console.log(`[FT] FILE_LIST: transferId=${transferId}, fileCount=${fileCount}, totalBytes=${totalBytes}`);

    const files: TransferFile[] = [];
    let dirCount = 0;
    for (let i = 0; i < fileCount; i++) {
      const pathLen = view.getUint16(offset, true); offset += PROTO_SIZE.UINT16;
      const path = sharedTextDecoder.decode(bytes.slice(offset, offset + pathLen)); offset += pathLen;
      const size = Number(view.getBigUint64(offset, true)); offset += PROTO_SIZE.UINT64;
      const mtime = Number(view.getBigUint64(offset, true)); offset += PROTO_SIZE.UINT64;
      const hash = view.getBigUint64(offset, true); offset += PROTO_SIZE.UINT64;
      const isDir = bytes[offset] !== 0; offset += PROTO_SIZE.UINT8;

      if (isDir) dirCount++;
      files.push({ path, size, mtime, hash, isDir });
    }

    const nonDirCount = fileCount - dirCount;
    console.log(`[FT] FILE_LIST parsed: ${fileCount} total entries (${nonDirCount} files, ${dirCount} dirs)`);

    const transfer = this.activeTransfers.get(transferId);
    if (transfer) {
      transfer.files = files;
      transfer.totalBytes = totalBytes;
      transfer.state = 'transferring';

      // Notify that transfer has started with full details
      const nonDirFiles = files.filter(f => !f.isDir);
      console.log(`[FT] Calling onTransferStart: transferId=${transferId}, path=${transfer.serverPath}, files=${nonDirFiles.length}`);
      this.onTransferStart?.(transferId, transfer.serverPath ?? '', transfer.direction as 'upload' | 'download', nonDirFiles.length, totalBytes);

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
        // Enable zip mode for multi-file downloads (stream to OPFS temp)
        const nonDirFiles = files.filter(f => !f.isDir && f.size > 0).length;
        if (nonDirFiles > 1) {
          transfer.useZipMode = true;
          transfer.filesCompleted = 0;
        }

        // Save transfer metadata for resume support (including options)
        if (this.worker && transfer.serverPath) {
          this.worker.postMessage({
            type: 'save-transfer-metadata',
            metadata: {
              transferId,
              direction: 'download',
              serverPath: transfer.serverPath,
              totalFiles: nonDirFiles,
              totalBytes,
              completedFiles: [],
              bytesTransferred: transfer.bytesTransferred,
              startTime: Date.now(),
              lastUpdateTime: Date.now(),
              useGitignore: transfer.options?.useGitignore ?? false,
              excludes: transfer.options?.excludes ?? [],
            },
          });
        }

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
    const uncompressedSize = view.getUint32(PROTO_FILE_REQUEST.UNCOMPRESSED_SIZE, true);
    const compressedData = bytes.slice(PROTO_FILE_REQUEST.DATA);

    console.log(`[FT] FILE_REQUEST: transferId=${transferId}, fileIndex=${fileIndex}, chunkOffset=${chunkOffset}, uncompressedSize=${uncompressedSize}, compressedSize=${compressedData.length}`);

    const transfer = this.activeTransfers.get(transferId);
    if (!transfer || !transfer.files) {
      console.warn(`[FT] FILE_REQUEST: No transfer found for ID ${transferId}`);
      return;
    }
    if (fileIndex >= transfer.files.length) {
      console.warn(`[FT] FILE_REQUEST: Invalid fileIndex ${fileIndex} >= ${transfer.files.length}`);
      return;
    }

    const file = transfer.files[fileIndex];
    console.log(`[FT] FILE_REQUEST: Processing file ${file.path} (${fileIndex}/${transfer.files.length})`);

    // Delegate to Worker for decompression + storage
    const buffer = compressedData.buffer.slice(
      compressedData.byteOffset,
      compressedData.byteOffset + compressedData.byteLength,
    );
    this.worker!.postMessage({
      type: 'decompress-and-write',
      transferId,
      fileIndex,
      filePath: file.path,
      offset: chunkOffset,
      compressedData: buffer,
      fileSize: file.size,
    }, [buffer]);
  }

  /** Handle BATCH_DATA: multiple small files compressed as one block */
  private async handleBatchData(data: ArrayBuffer): Promise<void> {
    const view = new DataView(data);
    const bytes = new Uint8Array(data);

    const transferId = view.getUint32(PROTO_HEADER.TRANSFER_ID, true);
    const uncompressedSize = view.getUint32(PROTO_BATCH_DATA.UNCOMPRESSED_SIZE, true);
    const compressedData = bytes.slice(PROTO_BATCH_DATA.DATA);

    console.log(`[FT] BATCH_DATA: transferId=${transferId}, uncompressedSize=${uncompressedSize}, compressedSize=${compressedData.length}`);

    const transfer = this.activeTransfers.get(transferId);
    if (!transfer || !transfer.files) {
      console.warn(`[FT] BATCH_DATA: No transfer found for ID ${transferId}`);
      return;
    }

    // Save references before async gap — transfer may be deleted by
    // handleTransferComplete during decompression (race condition)
    const files = transfer.files;

    console.log(`[FT] BATCH_DATA: Starting decompression of ${compressedData.length} bytes...`);
    let payload: Uint8Array;
    try {
      const decompressStart = performance.now();
      payload = await this.decompress(compressedData);
      const decompressMs = performance.now() - decompressStart;
      console.log(`[FT] BATCH_DATA: Decompression complete in ${decompressMs.toFixed(0)}ms, payload size=${payload.length}`);
    } catch (err) {
      console.error('[FT] BATCH_DATA: Decompression failed:', err);
      this.failTransfer(transferId, 'Batch decompression failed');
      return;
    }

    if (payload.length !== uncompressedSize) {
      console.warn(`Batch size mismatch: expected ${uncompressedSize}, got ${payload.length}`);
    }

    // Re-fetch transfer after async gap (may have been deleted)
    const currentTransfer = this.activeTransfers.get(transferId);

    // Parse batch payload: [file_count:u16] then per file: [file_index:u32][size:u32][data...]
    const batchView = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
    let offset = 0;
    const fileCount = batchView.getUint16(offset, true); offset += 2;

    console.log(`[FT] BATCH_DATA contains ${fileCount} files`);

    for (let i = 0; i < fileCount; i++) {
      if (offset + 8 > payload.length) break;

      const fileIndex = batchView.getUint32(offset, true); offset += 4;
      const fileSize = batchView.getUint32(offset, true); offset += 4;

      if (offset + fileSize > payload.length) break;
      if (fileIndex >= files.length) {
        offset += fileSize;
        continue;
      }

      const fileData = payload.slice(offset, offset + fileSize);
      offset += fileSize;

      const file = files[fileIndex];
      // Note: bytesTransferred is incremented in handleCompletedFile, don't double-count

      if (currentTransfer) {
        // Transfer still active — normal path
        this.handleCompletedFile(transferId, file.path, fileData);
        this.cacheDownloadedFile(currentTransfer, file.path, fileData);
      } else {
        // Transfer was deleted during decompression (race with TRANSFER_COMPLETE).
        // For non-zip single-file downloads, save the file directly.
        console.log(`[FT] BATCH_DATA: Transfer ${transferId} gone after decompression, saving ${file.path} directly`);
        this.saveFile(file.path, fileData);
        this.cacheDownloadedFile(transfer, file.path, fileData);
      }
    }
  }

  /** Worker callback: chunk decompressed and stored in worker memory */
  private onChunkWrittenToOPFS(msg: { transferId: number; fileIndex: number; filePath: string; bytesWritten: number; complete: boolean }): void {
    const transfer = this.activeTransfers.get(msg.transferId);
    if (!transfer || !transfer.files) return;

    transfer.bytesTransferred += msg.bytesWritten;

    if (msg.complete) {
      if (!transfer.completedPaths) transfer.completedPaths = new Set();
      if (transfer.completedPaths.has(msg.filePath)) return;
      transfer.completedPaths.add(msg.filePath);

      if (transfer.useZipMode) {
        // Worker has the file in memory — just track progress (no get-file round-trip)
        transfer.filesCompleted = (transfer.filesCompleted ?? 0) + 1;
        const totalFiles = transfer.files.filter(f => !f.isDir && f.size > 0).length;
        this.onDownloadProgress?.(msg.transferId, transfer.filesCompleted, totalFiles, transfer.bytesTransferred, transfer.totalBytes ?? 0);

        // If TRANSFER_COMPLETE already received and all files done, create zip
        if (transfer.zipPending && !transfer.zipCreating && transfer.filesCompleted >= totalFiles) {
          if (transfer.zipFallbackTimer) {
            clearTimeout(transfer.zipFallbackTimer);
            transfer.zipFallbackTimer = undefined;
          }
          transfer.zipCreating = true;
          this.createZipFromOPFS(msg.transferId);
        }
      } else {
        // Single file — need data back on main thread for browser download
        this.worker?.postMessage({
          type: 'get-file',
          transferId: msg.transferId,
          filePath: msg.filePath,
        });
      }
      transfer.currentFileIndex++;
    }
  }


  /** Worker callback: file data read from OPFS for browser download */
  private onFileDataFromOPFS(msg: { transferId: number; filePath: string; data: ArrayBuffer }): void {
    console.log(`[FT] ← onFileDataFromOPFS: path=${msg.filePath}, size=${msg.data.byteLength}`);
    const transfer = this.activeTransfers.get(msg.transferId);
    if (!transfer) {
      console.warn(`[FT] onFileDataFromOPFS: No transfer found`);
      return;
    }

    const data = new Uint8Array(msg.data);
    this.handleCompletedFile(msg.transferId, msg.filePath, data);
    this.cacheDownloadedFile(transfer, msg.filePath, data);
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

  /** Clear OPFS cache for a specific server path after successful download */
  private clearCacheForPath(serverPath: string): void {
    if (!this.cache) return;
    // Remove cached files for this path by clearing all files in the cache dir
    this.worker?.postMessage({ type: 'cache-clear-path', serverPath });
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

      // Report upload progress
      if (transfer.direction === 'upload' && transfer.files) {
        const totalFiles = transfer.files.filter(f => !f.isDir).length;
        this.onDownloadProgress?.(transferId, transfer.currentFileIndex, totalFiles, bytesReceived, transfer.totalBytes ?? 0);
      }

      this.sendNextChunk(transferId).catch(err => console.error('Send chunk failed:', err));
    }
  }

  private handleTransferComplete(data: ArrayBuffer): void {
    const view = new DataView(data);
    const transferId = view.getUint32(PROTO_HEADER.TRANSFER_ID, true);
    const totalBytes = Number(view.getBigUint64(PROTO_TRANSFER_COMPLETE.TOTAL_BYTES, true));

    console.log(`[FT] ====== TRANSFER_COMPLETE RECEIVED ======`);
    console.log(`[FT] transferId=${transferId}, totalBytes=${totalBytes}`);

    const transfer = this.activeTransfers.get(transferId);
    if (!transfer) {
      console.error(`[FT] TRANSFER_COMPLETE: No active transfer found for ID ${transferId}`);
      return;
    }

    console.log(`[FT] Transfer state: ${transfer.state}, useZipMode: ${transfer.useZipMode}, direction: ${transfer.direction}`);
    transfer.state = 'complete';

    // Zip mode: check if all files are written to OPFS temp
    if (transfer.useZipMode) {
      const totalFiles = transfer.files?.filter(f => !f.isDir && f.size > 0).length ?? 0;
      const filesCompleted = transfer.filesCompleted ?? 0;
      console.log(`[FT] Zip mode: ${filesCompleted}/${totalFiles} files written to OPFS (totalEntries=${transfer.files?.length})`);
      console.log(`[FT] Checking if ready to create zip: filesCompleted (${filesCompleted}) >= totalFiles (${totalFiles}) = ${filesCompleted >= totalFiles}`);
      if (filesCompleted >= totalFiles) {
        // All files already written — create zip from OPFS now
        console.log('[FT] All files written, creating zip from OPFS...');
        transfer.zipCreating = true; // Prevent multiple zip creations
        this.createZipFromOPFS(transferId);
        return; // Don't delete transfer yet — createZipFromOPFS will handle cleanup
      } else {
        // Files still pending (async writes) — defer zip creation
        console.log('[FT] Files still pending, setting zipPending flag');
        transfer.zipPending = true;

        // Fallback: if no new files complete for 2 seconds, assume all files received and create zip
        // This handles cases where server declares N files but only sends N-1
        transfer.zipFallbackTimer = setTimeout(() => {
          const t = this.activeTransfers.get(transferId);
          if (t?.zipPending && !t.zipCreating) {
            console.log(`[FT] Timeout fallback: creating zip with ${t.filesCompleted}/${totalFiles} files`);
            t.zipCreating = true; // Prevent multiple zip creations
            this.createZipFromOPFS(transferId);
          }
        }, 2000);

        return; // Don't delete transfer yet — handleCompletedFile will finish it
      }
    } else {
      console.log('[FT] Not in zip mode (single file download)');
    }

    this.activeTransfers.delete(transferId);
    this.onTransferComplete?.(transferId, totalBytes);

    // Clean up OPFS temp files for this transfer
    this.worker?.postMessage({ type: 'cleanup', transferId });

    // Delete transfer metadata (resume no longer needed)
    this.worker?.postMessage({ type: 'delete-transfer-metadata', transferId });

    // Clean up OPFS cache after successful download
    if (transfer?.serverPath) {
      this.clearCacheForPath(transfer.serverPath);
    }

    // Close the file WebSocket connection only if no more active transfers
    if (this.activeTransfers.size === 0) {
      this.onConnectionShouldClose?.();
    }
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

    entries.sort((a, b) => a.path.localeCompare(b.path));
    const report = { newCount, updateCount, deleteCount, entries };
    this.onDryRunReport?.(transferId, report);
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

    const { dryRun = false, excludes = [], useGitignore = false } = options;

    let files: Awaited<ReturnType<typeof this.collectFilesFromHandle>>;
    try {
      console.log(`[FT] collectFilesFromHandle: starting, dirHandle.name=${dirHandle.name}`);
      files = await this.collectFilesFromHandle(dirHandle, '');
      const nonDirFiles = files.filter(f => !f.isDir);
      console.log(`[FT] collectFilesFromHandle: done, ${files.length} total entries, ${nonDirFiles.length} files`);
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
    view.setUint8(offset, (dryRun ? 1 : 0) | (useGitignore ? 2 : 0)); offset += 1;
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
      serverPath,
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

    const { dryRun = false, excludes = [], useGitignore = false } = options;

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
    view.setUint8(offset, (dryRun ? 1 : 0) | (useGitignore ? 2 : 0)); offset += 1;
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
      serverPath,
      state: 'pending',
      bytesTransferred: 0,
      currentFileIndex: 0,
    };
  }

  async startFolderDownload(serverPath: string, options: TransferOptions = {}): Promise<void> {
    console.log(`[FT] startFolderDownload: path="${serverPath}", canSend=${this.canSend()}, hasPendingTransfer=${!!this.pendingTransfer}`);

    if (!this.canSend()) {
      console.error('[FT] File transfer not connected - aborting');
      this.onTransferError?.(0, 'File transfer connection not available');
      return;
    }

    // Check if there's already a pending transfer
    if (this.pendingTransfer) {
      console.error('[FT] Already have a pending transfer - cannot start new one');
      this.onTransferError?.(0, 'Transfer already in progress');
      return;
    }

    const { dryRun = false, excludes = [], useGitignore = false } = options;
    const flagsByte = (dryRun ? 1 : 0) | (useGitignore ? 2 : 0);

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
    view.setUint8(offset, flagsByte); offset += 1;
    view.setUint8(offset, excludes.length); offset += 1;
    view.setUint16(offset, pathBytes.length, true); offset += 2;
    bytes.set(pathBytes, offset); offset += pathBytes.length;

    for (const exclude of excludeBytes) {
      view.setUint8(offset, exclude.length); offset += 1;
      bytes.set(exclude, offset); offset += exclude.length;
    }

    console.log(`[FT] Sending TRANSFER_INIT: msgLen=${msgLen}`);
    this.send(msg);
    console.log(`[FT] TRANSFER_INIT sent, now creating pendingTransfer`);


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

  /** Cancel an active transfer */
  cancelTransfer(transferId: number): void {
    const transfer = this.activeTransfers.get(transferId);
    if (transfer) {
      console.log(`Cancelling transfer ${transferId}`);
      transfer.state = 'error';
      transfer.receivedFiles?.clear();
      this.activeTransfers.delete(transferId);
      this.onTransferCancelled?.(transferId);

      // Send TRANSFER_CANCEL message to server
      if (this.canSend()) {
        const msg = new ArrayBuffer(5);
        const view = new DataView(msg);
        view.setUint8(0, TransferMsgType.TRANSFER_CANCEL);
        view.setUint32(1, transferId, true);
        this.send(msg);
        console.log(`[FT] Sent TRANSFER_CANCEL for ${transferId}`);
      }
    }

    // Always clean up OPFS (even if transfer wasn't in activeTransfers,
    // e.g. after onDisconnect cleared it but UI still shows the transfer)
    this.worker?.postMessage({ type: 'cleanup-temp', transferId });
    this.worker?.postMessage({ type: 'delete-transfer-metadata', transferId });
  }

  /** Cancel all active transfers */
  cancelAllTransfers(): void {
    const transferIds = Array.from(this.activeTransfers.keys());
    for (const id of transferIds) {
      this.cancelTransfer(id);
    }
  }

  /** Check if a transfer is currently active */
  isTransferActive(transferId: number): boolean {
    return this.activeTransfers.has(transferId);
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

  /** Send the upload file list to the server so it can map file indices to paths. */
  private sendUploadFileList(transferId: number, files: TransferFile[]): void {
    const totalBytes = files.reduce((sum, f) => sum + (f.isDir ? 0 : f.size), 0);
    const encodedPaths = files.map(f => sharedTextEncoder.encode(f.path));
    // [msg_type:1][transfer_id:4][file_count:4][total_bytes:8][per file: path_len:2 + path + size:8 + is_dir:1]
    const payloadLen = encodedPaths.reduce((sum, p) => sum + 2 + p.length + 8 + 1, 0);
    const msgLen = 1 + 4 + 4 + 8 + payloadLen;
    const msg = new ArrayBuffer(msgLen);
    const view = new DataView(msg);
    const bytes = new Uint8Array(msg);

    let offset = 0;
    view.setUint8(offset, TransferMsgType.UPLOAD_FILE_LIST); offset += 1;
    view.setUint32(offset, transferId, true); offset += 4;
    view.setUint32(offset, files.length, true); offset += 4;
    view.setBigUint64(offset, BigInt(totalBytes), true); offset += 8;

    for (let i = 0; i < files.length; i++) {
      const pathBytes = encodedPaths[i];
      view.setUint16(offset, pathBytes.length, true); offset += 2;
      bytes.set(pathBytes, offset); offset += pathBytes.length;
      view.setBigUint64(offset, BigInt(files[i].size), true); offset += 8;
      view.setUint8(offset, files[i].isDir ? 1 : 0); offset += 1;
    }

    this.send(msg);
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
    return this.compressViaWorker(data, FILE_TRANSFER.COMPRESSION_LEVEL);
  }

  private async decompress(data: Uint8Array): Promise<Uint8Array> {
    return this.decompressViaWorker(data);
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

  /** Either write to OPFS temp for zip (multi-file) or save immediately (single file). */
  private handleCompletedFile(transferId: number, path: string, data: Uint8Array): boolean {
    console.log(`[FT] handleCompletedFile: transferId=${transferId}, path=${path}, size=${data.length}`);
    const transfer = this.activeTransfers.get(transferId);
    if (!transfer) {
      console.error(`[FT] No transfer found for ID ${transferId} in handleCompletedFile`);
      return false;
    }
    if (transfer?.useZipMode) {
      // Write to OPFS temp directory for streaming zip creation
      // IMPORTANT: Clone the data before transferring to keep original intact for caching
      const dataCopy = new Uint8Array(data);
      this.worker?.postMessage({
        type: 'write-temp-file',
        transferId,
        path,
        data: dataCopy.buffer
      }, [dataCopy.buffer]);

      transfer.filesCompleted = (transfer.filesCompleted ?? 0) + 1;
      // Only increment bytesTransferred for small files (from BATCH_DATA)
      // Large files already had bytes counted in onChunkWrittenToOPFS
      const isSmallFile = data.length <= 16 * 1024; // batch_threshold = 16KB
      if (isSmallFile) {
        transfer.bytesTransferred += data.length;
      }
      const totalFiles = transfer.files?.filter(f => !f.isDir && f.size > 0).length ?? 0;
      console.log(`[FT] File completed: ${path} (${transfer.filesCompleted}/${totalFiles}), calling onDownloadProgress with transferId=${transferId}`);
      this.onDownloadProgress?.(transferId, transfer.filesCompleted, totalFiles, transfer.bytesTransferred, transfer.totalBytes ?? 0);

      // If TRANSFER_COMPLETE already received and all files written, create zip
      if (transfer.zipPending && !transfer.zipCreating) {
        if (transfer.filesCompleted >= totalFiles) {
          console.log('All files written after zipPending, creating zip from OPFS...');
          // Clear fallback timer since we're creating zip now
          if (transfer.zipFallbackTimer) {
            clearTimeout(transfer.zipFallbackTimer);
            transfer.zipFallbackTimer = undefined;
          }
          transfer.zipCreating = true; // Prevent multiple zip creations
          this.createZipFromOPFS(transferId);
        } else {
          // Reset timeout on each file completion to give more files a chance to arrive
          console.log(`[FT] zipPending active, ${transfer.filesCompleted}/${totalFiles} files done, resetting timer...`);
          if (transfer.zipFallbackTimer) {
            clearTimeout(transfer.zipFallbackTimer);
          }
          transfer.zipFallbackTimer = setTimeout(() => {
            const t = this.activeTransfers.get(transferId);
            if (t?.zipPending && !t.zipCreating) {
              const tf = t.files?.filter(f => !f.isDir && f.size > 0).length ?? 0;
              console.log(`[FT] Timeout fallback: creating zip with ${t.filesCompleted}/${tf} files`);
              t.zipCreating = true; // Prevent multiple zip creations
              this.createZipFromOPFS(transferId);
            }
          }, 2000);
        }
      }
      return true;
    }
    console.log(`File completed (not in zip mode): ${path}`);
    return this.saveFile(path, data);
  }

  /** Create zip from OPFS temp files and trigger browser download. */
  private async createZipFromOPFS(transferId: number): Promise<void> {
    const transfer = this.activeTransfers.get(transferId);
    if (!transfer) {
      console.error(`[FT] createZipFromOPFS: No transfer found for ID ${transferId}`);
      return;
    }

    console.log(`[FT] createZipFromOPFS: requesting zip from worker, transferId=${transferId}`);

    // Extract folder name from server path for zip filename
    const pathParts = (transfer.serverPath ?? '').split('/').filter((p: string) => p);
    const folderName = pathParts[pathParts.length - 1] || 'download';
    console.log(`[FT] Zip filename will be: ${folderName}.zip`);

    if (!this.worker) {
      console.error('[FT] No worker available for zip creation!');
      this.activeTransfers.delete(transferId);
      this.onTransferError?.(transferId, 'No worker available for zip creation');
      return;
    }

    // Request worker to create zip from temp files
    this.worker.postMessage({ type: 'create-zip-from-temp', transferId, folderName });
    console.log('[FT] Sent create-zip-from-temp message to worker');
    // Worker will send 'zip-created' message with the zip data
  }

  private onZipCreated(msg: { transferId: number; zipData: ArrayBuffer; filename: string }): void {
    console.log(`[FT] onZipCreated: transferId=${msg.transferId}, size=${msg.zipData.byteLength} bytes, filename=${msg.filename}`);

    // Ignore duplicate zip-created messages (happens when multiple files complete after threshold)
    const transfer = this.activeTransfers.get(msg.transferId);
    if (!transfer) {
      console.log(`[FT] Ignoring duplicate zip-created message for transfer ${msg.transferId}`);
      return;
    }

    const blob = new Blob([msg.zipData]);
    const url = URL.createObjectURL(blob);
    try {
      const a = document.createElement('a');
      a.href = url;
      a.download = msg.filename;
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      console.log('[FT] Zip download triggered successfully');
    } catch (err) {
      console.error('[FT] Failed to save zip:', msg.filename, err);
    } finally {
      URL.revokeObjectURL(url);
    }

    // Clean up transfer and temp files
    console.log(`[FT] Cleaning up transfer ${msg.transferId}`);
    this.activeTransfers.delete(msg.transferId);
    this.onTransferComplete?.(msg.transferId, transfer.totalBytes ?? 0);
    console.log(`[FT] Sending cleanup-temp message to worker for transfer ${msg.transferId}`);
    this.worker?.postMessage({ type: 'cleanup-temp', transferId: msg.transferId });

    // Delete transfer metadata (resume no longer needed)
    this.worker?.postMessage({ type: 'delete-transfer-metadata', transferId: msg.transferId });

    // Clean up OPFS cache
    if (transfer.serverPath) {
      this.clearCacheForPath(transfer.serverPath);
    }

    // Close the file WebSocket connection only if no more active transfers
    if (this.activeTransfers.size === 0) {
      this.onConnectionShouldClose?.();
    }
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

// CRC-32 lookup table
const CRC32_TABLE = new Uint32Array(256);
for (let i = 0; i < 256; i++) {
  let c = i;
  for (let j = 0; j < 8; j++) c = (c >>> 1) ^ (c & 1 ? 0xedb88320 : 0);
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
function createZip(files: Map<string, Uint8Array>): Uint8Array {
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
    view.setUint32(pos, entry.data.length, true); pos += 4;
    view.setUint32(pos, entry.data.length, true); pos += 4;
    view.setUint16(pos, entry.name.length, true); pos += 2;
    view.setUint16(pos, 0, true); pos += 2;    // extra field length
    view.setUint16(pos, 0, true); pos += 2;    // file comment length
    view.setUint16(pos, 0, true); pos += 2;    // disk number
    view.setUint16(pos, 0, true); pos += 2;    // internal attrs
    view.setUint32(pos, 0, true); pos += 4;    // external attrs
    view.setUint32(pos, entry.offset, true); pos += 4;
    zip.set(entry.name, pos); pos += entry.name.length;
  }
  const centralDirSize = pos - centralDirOffset;

  // End of central directory
  view.setUint32(pos, 0x06054b50, true); pos += 4;
  view.setUint16(pos, 0, true); pos += 2;      // disk number
  view.setUint16(pos, 0, true); pos += 2;      // central dir disk
  view.setUint16(pos, entries.length, true); pos += 2;
  view.setUint16(pos, entries.length, true); pos += 2;
  view.setUint32(pos, centralDirSize, true); pos += 4;
  view.setUint32(pos, centralDirOffset, true); pos += 4;
  view.setUint16(pos, 0, true); pos += 2;      // comment length

  return zip.slice(0, pos);
}
