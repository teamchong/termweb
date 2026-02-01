// File transfer protocol and handlers

export const TransferMsgType = {
  // Client -> Server
  TRANSFER_INIT: 0x20,
  FILE_LIST_REQUEST: 0x21,
  FILE_DATA: 0x22,
  TRANSFER_RESUME: 0x23,
  TRANSFER_CANCEL: 0x24,
  // Server -> Client
  TRANSFER_READY: 0x30,
  FILE_LIST: 0x31,
  FILE_REQUEST: 0x32,
  FILE_ACK: 0x33,
  TRANSFER_COMPLETE: 0x34,
  TRANSFER_ERROR: 0x35,
  DRY_RUN_REPORT: 0x36,
} as const;

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
  private ws: WebSocket | null = null;
  private activeTransfers = new Map<number, TransferState>();
  private chunkSize = 256 * 1024; // 256KB chunks

  onTransferComplete?: (transferId: number, totalBytes: number) => void;
  onTransferError?: (transferId: number, error: string) => void;
  onDryRunReport?: (transferId: number, report: DryRunReport) => void;

  connect(host: string, port: number): void {
    this.ws = new WebSocket(`ws://${host}:${port}`);
    this.ws.binaryType = 'arraybuffer';

    this.ws.onopen = () => {
      console.log('File transfer channel connected');
    };

    this.ws.onmessage = (event) => {
      if (event.data instanceof ArrayBuffer) {
        this.handleMessage(event.data);
      }
    };

    this.ws.onclose = () => {
      console.log('File transfer channel disconnected');
    };
  }

  disconnect(): void {
    this.ws?.close();
    this.ws = null;
  }

  private handleMessage(data: ArrayBuffer): void {
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
    }
  }

  private handleTransferReady(data: ArrayBuffer): void {
    const view = new DataView(data);
    const transferId = view.getUint32(1, true);
    console.log(`Transfer ${transferId} ready`);

    const transfer = this.activeTransfers.get(transferId);
    if (transfer) {
      transfer.state = 'ready';
    }
  }

  private handleFileList(data: ArrayBuffer): void {
    const view = new DataView(data);
    const bytes = new Uint8Array(data);

    let offset = 1;
    const transferId = view.getUint32(offset, true); offset += 4;
    const fileCount = view.getUint32(offset, true); offset += 4;
    const totalBytes = Number(view.getBigUint64(offset, true)); offset += 8;

    const files: TransferFile[] = [];
    for (let i = 0; i < fileCount; i++) {
      const pathLen = view.getUint16(offset, true); offset += 2;
      const path = new TextDecoder().decode(bytes.slice(offset, offset + pathLen)); offset += pathLen;
      const size = Number(view.getBigUint64(offset, true)); offset += 8;
      const mtime = Number(view.getBigUint64(offset, true)); offset += 8;
      const hash = view.getBigUint64(offset, true); offset += 8;
      const isDir = bytes[offset] !== 0; offset += 1;

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

    let offset = 1;
    const transferId = view.getUint32(offset, true); offset += 4;
    const fileIndex = view.getUint32(offset, true); offset += 4;
    const chunkOffset = Number(view.getBigUint64(offset, true)); offset += 8;
    offset += 4; // uncompressedSize
    const compressedData = bytes.slice(offset);

    const transfer = this.activeTransfers.get(transferId);
    if (!transfer || !transfer.files) return;

    try {
      const fileData = await this.decompress(compressedData);

      // Re-check transfer state after async operation
      const currentTransfer = this.activeTransfers.get(transferId);
      if (!currentTransfer || currentTransfer.state === 'complete' || currentTransfer.state === 'error') {
        return;
      }

      const file = currentTransfer.files![fileIndex];
      if (!file) return;

      if (!currentTransfer.receivedFiles) currentTransfer.receivedFiles = new Map();
      if (!currentTransfer.receivedFiles.has(fileIndex)) {
        currentTransfer.receivedFiles.set(fileIndex, []);
      }
      currentTransfer.receivedFiles.get(fileIndex)!.push({ offset: chunkOffset, data: fileData });

      currentTransfer.bytesTransferred += fileData.length;

      if (currentTransfer.bytesTransferred >= file.size) {
        const chunks = currentTransfer.receivedFiles.get(fileIndex)!;
        chunks.sort((a, b) => a.offset - b.offset);
        const fullData = new Uint8Array(file.size);
        let writeOffset = 0;
        for (const chunk of chunks) {
          fullData.set(chunk.data, writeOffset);
          writeOffset += chunk.data.length;
        }

        this.saveFile(file.path, fullData);
        currentTransfer.receivedFiles.delete(fileIndex);
        currentTransfer.currentFileIndex++;
      }
    } catch (err) {
      console.error('Decompression failed:', err);
    }
  }

  private handleFileAck(data: ArrayBuffer): void {
    const view = new DataView(data);
    const transferId = view.getUint32(1, true);
    const bytesReceived = Number(view.getBigUint64(9, true));

    const transfer = this.activeTransfers.get(transferId);
    if (transfer) {
      transfer.bytesTransferred = bytesReceived;
      this.sendNextChunk(transferId);
    }
  }

  private handleTransferComplete(data: ArrayBuffer): void {
    const view = new DataView(data);
    const transferId = view.getUint32(1, true);
    const totalBytes = Number(view.getBigUint64(5, true));

    console.log(`Transfer ${transferId} complete`);

    const transfer = this.activeTransfers.get(transferId);
    if (transfer) {
      transfer.state = 'complete';
    }
    this.activeTransfers.delete(transferId);
    this.onTransferComplete?.(transferId, totalBytes);
  }

  private handleTransferError(data: ArrayBuffer): void {
    const view = new DataView(data);
    const bytes = new Uint8Array(data);

    const transferId = view.getUint32(1, true);
    const errorLen = view.getUint16(5, true);
    const error = new TextDecoder().decode(bytes.slice(7, 7 + errorLen));

    console.error(`Transfer ${transferId} error: ${error}`);
    this.activeTransfers.delete(transferId);
    this.onTransferError?.(transferId, error);
  }

  private handleDryRunReport(data: ArrayBuffer): void {
    const view = new DataView(data);
    const bytes = new Uint8Array(data);

    let offset = 1;
    const transferId = view.getUint32(offset, true); offset += 4;
    const newCount = view.getUint32(offset, true); offset += 4;
    const updateCount = view.getUint32(offset, true); offset += 4;
    const deleteCount = view.getUint32(offset, true); offset += 4;

    const entries: Array<{ action: string; path: string; size: number }> = [];
    while (offset < data.byteLength) {
      const action = bytes[offset]; offset += 1;
      const pathLen = view.getUint16(offset, true); offset += 2;
      const path = new TextDecoder().decode(bytes.slice(offset, offset + pathLen)); offset += pathLen;
      const size = Number(view.getBigUint64(offset, true)); offset += 8;

      entries.push({ action: ['create', 'update', 'delete'][action], path, size });
    }

    this.onDryRunReport?.(transferId, { newCount, updateCount, deleteCount, entries });
  }

  async startFolderUpload(
    dirHandle: FileSystemDirectoryHandle,
    serverPath: string,
    options: TransferOptions = {}
  ): Promise<void> {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      console.error('File transfer WebSocket not connected');
      return;
    }

    const { deleteExtra = false, dryRun = false, excludes = [] } = options;
    const files = await this.collectFilesFromHandle(dirHandle, '');

    const pathBytes = new TextEncoder().encode(serverPath);
    const excludeBytes = excludes.map(p => new TextEncoder().encode(p));
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

    this.ws.send(msg);

    const transferId = Date.now();
    this.activeTransfers.set(transferId, {
      id: transferId,
      direction: 'upload',
      files,
      dirHandle,
      options,
      state: 'pending',
      bytesTransferred: 0,
      currentFileIndex: 0,
    });
  }

  async startFolderDownload(serverPath: string, options: TransferOptions = {}): Promise<void> {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      console.error('File transfer WebSocket not connected');
      return;
    }

    const { deleteExtra = false, dryRun = false, excludes = [] } = options;

    const pathBytes = new TextEncoder().encode(serverPath);
    const excludeBytes = excludes.map(p => new TextEncoder().encode(p));
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

    this.ws.send(msg);

    const transferId = Date.now();
    this.activeTransfers.set(transferId, {
      id: transferId,
      direction: 'download',
      serverPath,
      options,
      state: 'pending',
      bytesTransferred: 0,
      currentFileIndex: 0,
    });
  }

  private async collectFilesFromHandle(
    dirHandle: FileSystemDirectoryHandle,
    prefix: string
  ): Promise<TransferFile[]> {
    const files: TransferFile[] = [];

    for await (const [name, handle] of (dirHandle as any).entries()) {
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

    return files;
  }

  private async sendNextChunk(transferId: number): Promise<void> {
    const transfer = this.activeTransfers.get(transferId);
    if (!transfer || transfer.direction !== 'upload' || !transfer.files) return;

    const file = transfer.files[transfer.currentFileIndex];
    if (!file || file.isDir) {
      transfer.currentFileIndex++;
      if (transfer.currentFileIndex < transfer.files.length) {
        this.sendNextChunk(transferId);
      }
      return;
    }

    if (!file.file) return;

    const fileData = await file.file.arrayBuffer();
    const chunkStart = transfer.currentChunkOffset || 0;
    const chunkEnd = Math.min(chunkStart + this.chunkSize, fileData.byteLength);
    const chunk = new Uint8Array(fileData.slice(chunkStart, chunkEnd));

    const compressed = await this.compress(chunk);

    const msgLen = 1 + 4 + 4 + 8 + 4 + compressed.length;
    const msg = new ArrayBuffer(msgLen);
    const view = new DataView(msg);
    const bytes = new Uint8Array(msg);

    let offset = 0;
    view.setUint8(offset, TransferMsgType.FILE_DATA); offset += 1;
    view.setUint32(offset, transfer.id, true); offset += 4;
    view.setUint32(offset, transfer.currentFileIndex, true); offset += 4;
    view.setBigUint64(offset, BigInt(chunkStart), true); offset += 8;
    view.setUint32(offset, chunk.length, true); offset += 4;
    bytes.set(compressed, offset);

    this.ws?.send(msg);

    transfer.currentChunkOffset = chunkEnd;
    if (chunkEnd >= fileData.byteLength) {
      transfer.currentFileIndex++;
      transfer.currentChunkOffset = 0;
    }
  }

  private async compress(data: Uint8Array): Promise<Uint8Array> {
    const cs = new CompressionStream('deflate-raw');
    const writer = cs.writable.getWriter();
    writer.write(data as Uint8Array<ArrayBuffer>);
    writer.close();

    const chunks: Uint8Array[] = [];
    const reader = cs.readable.getReader();
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
  }

  private async decompress(data: Uint8Array): Promise<Uint8Array> {
    const ds = new DecompressionStream('deflate-raw');
    const writer = ds.writable.getWriter();
    writer.write(data as Uint8Array<ArrayBuffer>);
    writer.close();

    const chunks: Uint8Array[] = [];
    const reader = ds.readable.getReader();
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
  }

  private saveFile(path: string, data: Uint8Array): void {
    const filename = path.split('/').pop() || path;
    const blob = new Blob([data as Uint8Array<ArrayBuffer>]);
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  }
}
