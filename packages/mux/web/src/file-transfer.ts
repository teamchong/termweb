// File transfer protocol and handlers
// Uses zstd WASM via dedicated Web Worker (off main thread)
// with synchronous OPFS access for file caching

import { getCompressionPool } from './compression-pool';
import { TransferMsgType } from './protocol';
import { sharedTextEncoder, sharedTextDecoder } from './utils';
import {
  FILE_TRANSFER,
  PROTO_HEADER,
  PROTO_SIZE,
  PROTO_FILE_LIST,
  PROTO_FILE_REQUEST,
  PROTO_FILE_ACK,
  PROTO_TRANSFER_COMPLETE,
  PROTO_TRANSFER_ERROR,
  PROTO_DRY_RUN,
  PROTO_BATCH_DATA,
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
  direction: 'upload' | 'download';
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

  // Worker for off-thread zstd WASM + synchronous OPFS access
  private worker: Worker | null = null;
  private workerReady = false;
  private opfsAvailable = false;
  private workerInitPromise: Promise<void>;
  private pendingCompression = new Map<number, { resolve: (data: Uint8Array) => void; reject: (err: Error) => void }>();
  private nextCompressionId = 0;

  // Fallback: main-thread compression pool (used if Worker unavailable)
  private compressionPool = getCompressionPool();

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
    switch (msg.type) {
      case 'init-done':
        this.workerReady = true;
        this.opfsAvailable = msg.opfsAvailable;
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

  disconnect(): void {
    this.sendFn = null;
    this.activeTransfers.clear();
    this.pendingTransfer = null;
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
    }
  }

  private handleTransferReady(data: ArrayBuffer): void {
    const view = new DataView(data);
    const transferId = view.getUint32(PROTO_HEADER.TRANSFER_ID, true);
    console.log(`Transfer ${transferId} ready`);

    // Move pending transfer to active with the server's assigned ID
    if (this.pendingTransfer) {
      this.pendingTransfer.id = transferId;
      this.activeTransfers.set(transferId, this.pendingTransfer);
      this.pendingTransfer = null;
    }

    const transfer = this.activeTransfers.get(transferId);
    if (transfer) {
      transfer.state = 'ready';

      // For uploads, start sending file data immediately
      if (transfer.direction === 'upload' && transfer.files) {
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
      transfer.currentFileIndex = 0;
      transfer.bytesTransferred = 0;
      transfer.state = 'transferring';

      // If this is a download, start requesting files
      if (transfer.direction === 'download') {
        this.requestNextFile(transferId);
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

    this.saveFile(msg.filePath, new Uint8Array(msg.data));
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
      transfer.receivedFiles.delete(fileIndex);
      transfer.currentFileIndex++;
    }
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
