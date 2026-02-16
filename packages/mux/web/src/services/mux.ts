/**
 * Mux Client Service
 * Centralized WebSocket and state management using Svelte stores
 */
import { writable, get } from 'svelte/store';
import { mount, unmount } from 'svelte';
import { tabs, activeTabId as activeTabIdStore, panels, activePanelId, ui, sessions, keybindings, createPanelInfo, createTabInfo } from '../stores/index';
import PanelComponent from '../components/Panel.svelte';
import { SplitContainer, type PanelLike } from '../split-container';
import { FileTransferHandler } from '../file-transfer';
import type { DryRunReport, TransferOptions } from '../file-transfer';
import type { AppConfig, LayoutData, LayoutNode, LayoutTab } from '../types';
import type { PanelStatus } from '../stores/types';
import { applyColors, generateId, getWsUrl, sharedTextEncoder, sharedTextDecoder } from '../utils';
import { TIMING, WS_PATHS, SERVER_MSG, UI } from '../constants';
import { BinaryCtrlMsg, Role } from '../protocol';
import { initZstd, compressZstd, decompressZstd } from '../zstd-wasm';

// Extended panel interface with all methods
interface PanelInstance extends PanelLike {
  component: ReturnType<typeof mount>;
  connect: () => void;
  focus: () => void;
  toggleInspector: (visible?: boolean) => void;
  isInspectorOpen: () => boolean;
  hide: () => void;
  show: () => void;
  sendKeyInput: (e: KeyboardEvent, action: number) => void;
  sendTextInput: (text: string) => void;
  setControlWsSend: (fn: ((msg: ArrayBuffer | ArrayBufferView) => void) | null, immediateFn?: ((msg: ArrayBuffer | ArrayBufferView) => void) | null) => void;
  decodePreviewFrame: (frameData: Uint8Array) => void;
  handleInspectorState: (state: unknown) => void;
  getStatus: () => PanelStatus;
  getPwd: () => string;
  setPwd: (pwd: string) => void;
  getSnapshotCanvas: () => HTMLCanvasElement | undefined;
  updateCursorState: (x: number, y: number, w: number, h: number, style: number, visible: boolean, totalW: number, totalH: number) => void;
}

// Type guard for validating LayoutData structure from server
function isValidLayoutData(data: unknown): data is LayoutData {
  if (!data || typeof data !== 'object') return false;
  const layout = data as Record<string, unknown>;
  if (!Array.isArray(layout.tabs)) return false;
  for (const tab of layout.tabs) {
    if (!tab || typeof tab !== 'object') return false;
    const t = tab as Record<string, unknown>;
    if (typeof t.id !== 'number' || !t.root) return false;
  }
  return true;
}

// Connection status store
export const connectionStatus = writable<'connected' | 'disconnected' | 'error'>('disconnected');

// Initial layout loaded store - true once we've received the initial panel list from server
export const initialLayoutLoaded = writable<boolean>(false);

// Auth state store
export const authState = writable<{
  role: number;
  authRequired: boolean;
  hasPassword: boolean;
  passkeyCount: number;
  githubConfigured: boolean;
  googleConfigured: boolean;
}>({
  role: 0,
  authRequired: false,
  hasPassword: false,
  passkeyCount: 0,
  githubConfigured: false,
  googleConfigured: false,
});

// Internal tab info with DOM references
interface InternalTabInfo {
  id: string;
  title: string;
  root: SplitContainer;
  element: HTMLElement;
}

/**
 * MuxClient - manages WebSocket connections and application state
 */
export class MuxClient {
  private controlWs: WebSocket | null = null;
  private fileWs: WebSocket | null = null;
  private fileWsReady: Promise<void> | null = null;
  private fileWsReadyResolve: (() => void) | null = null;
  private fileWsIdleTimer: ReturnType<typeof setTimeout> | null = null;
  private fileTransfer: FileTransferHandler;
  private panelInstances = new Map<string, PanelInstance>();
  private panelsByServerId = new Map<number, PanelInstance>();
  private tabInstances = new Map<string, InternalTabInfo>();
  private tabHistory: string[] = [];
  private nextTabId = 1;
  private destroyed = false;
  private reconnectTimeoutId: ReturnType<typeof setTimeout> | null = null;
  private reconnectDelay: number = TIMING.WS_RECONNECT_INITIAL;
  private currentActivePanel: PanelInstance | null = null;
  private quickTerminalPanel: PanelInstance | null = null;
  private previousActivePanel: PanelInstance | null = null;
  private bellTimeouts = new Map<number, ReturnType<typeof setTimeout>>();
  private closeInProgress = false;
  private panelsEl: HTMLElement | null = null;
  private initialPanelListResolve: (() => void) | null = null;
  private h264Ws: WebSocket | null = null;
  private surfaceDims = new Map<number, { w: number; h: number }>();
  private isViewer = false;
  private dpiMediaQuery: MediaQueryList | null = null;
  private dpiChangeHandler: (() => void) | null = null;
  private zstdReady = false;
  private h264PendingFrames = new Map<number, Uint8Array[]>();
  private controlPendingByPanel = new Map<number, ArrayBuffer[]>();

  // Callbacks for transfer dialog UI (set by App.svelte)
  onUploadRequest?: () => void;
  onDownloadRequest?: () => void;
  onConfigContent?: (path: string, content: string) => void;
  onFileDropRequest?: (panel: PanelInstance, files: File[], dirHandle?: FileSystemDirectoryHandle) => void;
  onDownloadProgress?: (transferId: number, filesCompleted: number, totalFiles: number, bytesTransferred: number, totalBytes: number) => void;

  constructor() {
    this.fileTransfer = new FileTransferHandler();
    this.fileTransfer.onTransferComplete = (transferId, totalBytes) => {
      console.log(`Transfer ${transferId} completed: ${totalBytes} bytes`);
      this.resetFileWsIdleTimer();
    };
    this.fileTransfer.onTransferError = (transferId, error) => {
      console.error(`Transfer ${transferId} failed: ${error}`);
      this.resetFileWsIdleTimer();
    };
    this.fileTransfer.onDryRunReport = (transferId, report) => {
      console.log(`Transfer ${transferId} dry run: ${report.newCount} new, ${report.updateCount} update, ${report.deleteCount} delete`);
      this.resetFileWsIdleTimer();
    };
    this.fileTransfer.onDownloadProgress = (transferId, filesCompleted, totalFiles, bytesTransferred, totalBytes) => {
      console.log(`[MuxClient] onDownloadProgress wrapper: transferId=${transferId}, filesCompleted=${filesCompleted}, callback=${this.onDownloadProgress ? 'defined' : 'undefined'}`);
      this.onDownloadProgress?.(transferId, filesCompleted, totalFiles, bytesTransferred, totalBytes);
    };
    // Don't immediately close file WS on transfer complete - rely on idle timer instead
    // this.fileTransfer.onConnectionShouldClose = () => {
    //   console.log('[MuxClient] Transfer complete, closing file WebSocket to prevent zombie state');
    //   this.closeFileWs();
    // };
  }

  getFileTransfer(): FileTransferHandler {
    return this.fileTransfer;
  }

  /** Run a dry-run transfer and return the report.
   *  Temporarily captures the onDryRunReport callback to resolve a Promise. */
  async requestDryRun(
    mode: 'upload' | 'download',
    serverPath: string,
    options: TransferOptions,
    dirHandle?: FileSystemDirectoryHandle,
    droppedFiles?: File[],
  ): Promise<DryRunReport | null> {
    await this.ensureFileWs();

    const dryRunOptions: TransferOptions = { ...options, dryRun: true };

    return new Promise<DryRunReport | null>((resolve) => {
      const prevDryRunCb = this.fileTransfer.onDryRunReport;
      const prevErrorCb = this.fileTransfer.onTransferError;

      const cleanup = () => {
        this.fileTransfer.onDryRunReport = prevDryRunCb;
        this.fileTransfer.onTransferError = prevErrorCb;
        clearTimeout(timeout);
      };

      const timeout = setTimeout(() => {
        console.warn('[DryRun] Timeout — no response in 120s');
        cleanup();
        resolve(null);
      }, 120000);

      this.fileTransfer.onDryRunReport = (_transferId, report) => {
        cleanup();
        this.resetFileWsIdleTimer();
        resolve(report);
      };

      this.fileTransfer.onTransferError = (transferId, error) => {
        cleanup();
        console.error(`[DryRun] Failed (transfer ${transferId}): ${error}`);
        this.resetFileWsIdleTimer();
        resolve(null);
      };

      if (mode === 'upload') {
        if (dirHandle) {
          this.fileTransfer.startFolderUpload(dirHandle, serverPath, dryRunOptions);
        } else if (droppedFiles) {
          this.fileTransfer.startFilesUpload(droppedFiles, serverPath, dryRunOptions);
        } else {
          cleanup();
          resolve(null);
        }
      } else {
        this.fileTransfer.startFolderDownload(serverPath, dryRunOptions);
      }
    });
  }

  private static checkWebCodecsSupport(): boolean {
    return typeof VideoDecoder !== 'undefined' && typeof VideoDecoder.isConfigSupported === 'function';
  }

  private isControlWsOpen(): boolean {
    return this.controlWs !== null && this.controlWs.readyState === WebSocket.OPEN;
  }

  /** Lazy file WS — connects on first transfer, not on page load.
   *  Returns a promise that resolves when the WS is open and ready to send. */
  ensureFileWs(): Promise<void> {
    console.log(`[ensureFileWs] Called, fileWs exists: ${!!this.fileWs}, readyState: ${this.fileWs?.readyState}`);

    // Already open — just reset idle timer
    if (this.fileWs && this.fileWs.readyState === WebSocket.OPEN) {
      console.log('[ensureFileWs] WS already OPEN, resetting idle timer');
      this.resetFileWsIdleTimer();
      return Promise.resolve();
    }
    // Already connecting — return the existing ready promise
    if (this.fileWs && this.fileWs.readyState === WebSocket.CONNECTING && this.fileWsReady) {
      console.log('[ensureFileWs] WS already CONNECTING, returning existing promise');
      return this.fileWsReady;
    }

    // Clean up any stale WS in CLOSING/CLOSED state
    console.log('[ensureFileWs] Cleaning up stale WS and creating new connection');
    this.closeFileWs();

    const wsUrl = getWsUrl(WS_PATHS.FILE);
    this.fileWs = new WebSocket(wsUrl);
    this.fileWs.binaryType = 'arraybuffer';

    this.fileWsReady = new Promise<void>((resolve, reject) => {
      this.fileWsReadyResolve = resolve;
      const ws = this.fileWs!;

      ws.onopen = () => {
        console.log('File transfer channel connected');
        this.fileTransfer.setSend((data) => {
          if (this.fileWs && this.fileWs.readyState === WebSocket.OPEN) {
            try {
              // File data is already zstd-compressed at the application level
              this.fileWs.send(MuxClient.frameWithFlag(0x00, data));
              this.resetFileWsIdleTimer();
            } catch (err) {
              console.error('[FileWS] Send failed, connection is dead:', err);
              // Connection is broken - close and force reconnection
              this.closeFileWs();
            }
          } else {
            console.warn('[FileWS] Cannot send - WebSocket not open, readyState:', this.fileWs?.readyState);
          }
        });
        this.resetFileWsIdleTimer();
        this.fileWsReadyResolve = null;
        resolve();

        // Auto-resume interrupted uploads from previous connection
        const interrupted = this.fileTransfer.getInterruptedUploads();
        if (interrupted.size > 0) {
          console.log(`Resuming ${interrupted.size} interrupted upload(s)`);
          this.fileTransfer.resumeInterruptedUploads();
        }

        // Auto-resume interrupted downloads from OPFS (persists across page reloads)
        this.fileTransfer.getInterruptedDownloads().then(async (downloads) => {
          if (downloads.length > 0) {
            console.log(`[MuxClient] Found ${downloads.length} interrupted download(s), checking which need resume...`);
            for (const download of downloads) {
              // Skip if already active (prevents duplicate transfers on rapid reconnects)
              if (this.fileTransfer.isTransferActive(download.transferId)) {
                console.log(`[MuxClient] Skipping resume for ${download.transferId} - already active`);
                continue;
              }
              try {
                await this.fileTransfer.resumeInterruptedDownload(download);
              } catch (err) {
                console.error(`[MuxClient] Failed to resume download ${download.transferId}:`, err);
              }
            }
          }
        });
      };

      ws.onmessage = (event) => {
        if (this.destroyed) return;
        this.resetFileWsIdleTimer();
        if (event.data instanceof ArrayBuffer) {
          // Strip zstd compression flag byte (same framing as control WS)
          const raw = new Uint8Array(event.data);
          if (raw.length < 2) return;
          const flag = raw[0];
          if (flag === 0x01) {
            try {
              const decompressed = decompressZstd(raw.subarray(1));
              this.fileTransfer.handleServerMessage(decompressed.buffer as ArrayBuffer);
            } catch (err) {
              console.error('File WS zstd decompress failed:', err);
            }
          } else if (flag === 0x00) {
            this.fileTransfer.handleServerMessage(raw.buffer.slice(1));
          }
        }
      };

      ws.onclose = () => {
        console.log('File transfer channel disconnected');
        this.fileTransfer.onDisconnect();
        this.clearFileWsIdleTimer();
        this.fileWs = null;
        this.fileWsReady = null;
        // Reject if we were still connecting
        if (this.fileWsReadyResolve) {
          this.fileWsReadyResolve = null;
          reject(new Error('File transfer channel closed before open'));
        }
      };

      ws.onerror = (err) => {
        console.error('File transfer channel error:', err);
      };
    });

    return this.fileWsReady;
  }

  /** Close file WS and clean up all associated state */
  private closeFileWs(): void {
    this.clearFileWsIdleTimer();
    if (this.fileWs) {
      this.fileWs.onclose = null;
      this.fileWs.onerror = null;
      this.fileWs.onmessage = null;
      this.fileWs.onopen = null;
      this.fileWs.close();
      this.fileWs = null;
    }
    this.fileTransfer.onDisconnect();
    this.fileWsReady = null;
    if (this.fileWsReadyResolve) {
      this.fileWsReadyResolve = null;
    }
  }

  /** Reset the idle timer — closes file WS after FILE_WS_IDLE_TIMEOUT of inactivity */
  private resetFileWsIdleTimer(): void {
    this.clearFileWsIdleTimer();
    // Don't close while transfers are in progress
    if (this.fileTransfer.hasActiveTransfers()) return;
    this.fileWsIdleTimer = setTimeout(() => {
      if (this.fileWs && !this.fileTransfer.hasActiveTransfers()) {
        console.log('File transfer channel idle — closing');
        this.closeFileWs();
      }
    }, TIMING.FILE_WS_IDLE_TIMEOUT);
  }

  /** Clear the idle timer */
  private clearFileWsIdleTimer(): void {
    if (this.fileWsIdleTimer) {
      clearTimeout(this.fileWsIdleTimer);
      this.fileWsIdleTimer = null;
    }
  }

  // --- Outgoing message batching (60fps bus) ---
  private controlOutQueue: Uint8Array[] = [];
  private controlFlushScheduled = false;

  /** Queue binary data for the next batch flush (once per microtask) */
  private sendControlBinary(data: Uint8Array): void {
    if (!this.isControlWsOpen()) return;
    this.controlOutQueue.push(data);
    if (!this.controlFlushScheduled) {
      this.controlFlushScheduled = true;
      queueMicrotask(() => this.flushControlBatch());
    }
  }

  /** Send binary data immediately on the control WS, bypassing rAF batching.
   *  Used for latency-sensitive input (keystrokes, mouse clicks). */
  private sendControlImmediate(data: Uint8Array): void {
    if (!this.isControlWsOpen()) return;
    // Small messages (keystrokes ~5-15 bytes): skip zstd overhead
    if (data.length < 32) {
      this.controlWs!.send(MuxClient.frameWithFlag(0x00, data));
      return;
    }
    this.sendRawCompressed(data);
  }

  /** Flush all queued messages as one zstd-compressed batch */
  private flushControlBatch(): void {
    this.controlFlushScheduled = false;
    if (!this.isControlWsOpen() || !this.zstdReady || this.controlOutQueue.length === 0) {
      // zstd not ready or WS not open — keep messages queued, reschedule
      if (this.controlOutQueue.length > 0 && !this.controlFlushScheduled) {
        this.controlFlushScheduled = true;
        requestAnimationFrame(() => this.flushControlBatch());
      }
      return;
    }

    const queue = this.controlOutQueue;
    this.controlOutQueue = [];

    // Single message — skip batch envelope overhead
    if (queue.length === 1) {
      this.sendRawCompressed(queue[0]);
      return;
    }

    // Build batch: [0xFE][count:u16_le][len1:u16_le][msg1...][len2:u16_le][msg2...]...
    let totalPayload = 3; // type + count
    for (const msg of queue) totalPayload += 2 + msg.length;
    const batch = new Uint8Array(totalPayload);
    const bv = new DataView(batch.buffer);
    batch[0] = 0xFE;
    bv.setUint16(1, queue.length, true);
    let offset = 3;
    for (const msg of queue) {
      bv.setUint16(offset, msg.length, true);
      offset += 2;
      batch.set(msg, offset);
      offset += msg.length;
    }
    this.sendRawCompressed(batch);
  }

  /** Encode a uint32 as a 4-byte little-endian Uint8Array */
  private static u32Bytes(value: number): Uint8Array {
    const buf = new Uint8Array(4);
    new DataView(buf.buffer).setUint32(0, value, true);
    return buf;
  }

  // Reusable frame buffer for frameWithFlag — safe because output is always
  // immediately consumed by WebSocket.send() which copies before returning.
  private static frameBuf = new Uint8Array(256);

  /** Prepend a 1-byte flag to data: 0x00=uncompressed, 0x01=zstd-compressed */
  private static frameWithFlag(flag: number, data: Uint8Array): Uint8Array {
    const needed = 1 + data.length;
    if (needed > MuxClient.frameBuf.length) {
      MuxClient.frameBuf = new Uint8Array(Math.max(needed, MuxClient.frameBuf.length * 2));
    }
    MuxClient.frameBuf[0] = flag;
    MuxClient.frameBuf.set(data, 1);
    return MuxClient.frameBuf.subarray(0, needed);
  }

  /** Compress and send a single zstd-framed message on the control WS */
  private sendRawCompressed(data: Uint8Array): void {
    try {
      const compressed = compressZstd(data);
      if (compressed.length < data.length) {
        this.controlWs!.send(MuxClient.frameWithFlag(0x01, compressed));
        return;
      }
    } catch { /* compression didn't shrink — send uncompressed */ }
    this.controlWs!.send(MuxClient.frameWithFlag(0x00, data));
  }

  /** Send control WS resize (0x82) with scale for a single panel */
  private sendResizePanelWithScale(serverId: number, width: number, height: number, scale: number): void {
    const buf = new Uint8Array(13);
    const view = new DataView(buf.buffer);
    view.setUint8(0, BinaryCtrlMsg.RESIZE_PANEL);
    view.setUint32(1, serverId, true);
    view.setUint16(5, width, true);
    view.setUint16(7, height, true);
    view.setFloat32(9, scale, true);
    this.sendControlBinary(buf);
  }

  /** Detect devicePixelRatio changes (screen move, zoom) and notify server */
  private setupDpiDetection(): void {
    const listen = () => {
      this.dpiMediaQuery = matchMedia(`(resolution: ${devicePixelRatio}dppx)`);
      this.dpiChangeHandler = () => {
        const newScale = devicePixelRatio || 1;
        // Send resize with new scale for every active panel
        for (const [serverId, panel] of this.panelsByServerId) {
          const rect = panel.element.getBoundingClientRect();
          const w = Math.floor(rect.width);
          const h = Math.floor(rect.height);
          if (w > 0 && h > 0) {
            this.sendResizePanelWithScale(serverId, w, h, newScale);
          }
        }
        // Re-listen for the next change (new dppx value)
        listen();
      };
      this.dpiMediaQuery.addEventListener('change', this.dpiChangeHandler, { once: true });
    };
    listen();
  }

  /** Remove DPI change listener */
  private teardownDpiDetection(): void {
    if (this.dpiMediaQuery && this.dpiChangeHandler) {
      this.dpiMediaQuery.removeEventListener('change', this.dpiChangeHandler);
    }
    this.dpiMediaQuery = null;
    this.dpiChangeHandler = null;
  }

  async init(panelsEl: HTMLElement): Promise<void> {
    if (!MuxClient.checkWebCodecsSupport()) {
      const error = 'WebCodecs API not supported. Please use a modern browser (Chrome 94+, Edge 94+, or Safari 16.4+).';
      console.error(error);
      connectionStatus.set('error');
      throw new Error(error);
    }

    this.panelsEl = panelsEl;

    // Init zstd WASM for control WS compression
    await initZstd();
    this.zstdReady = true;

    const config: AppConfig = (window as any).__TERMWEB_CONFIG__ || {};
    this.applyConfig(config);

    const initialPanelListPromise = new Promise<void>((resolve) => {
      this.initialPanelListResolve = resolve;
    });

    this.connectControl();
    this.connectH264();
    this.setupDpiDetection();

    await Promise.race([
      initialPanelListPromise,
      new Promise<void>(resolve => setTimeout(resolve, 3000)),
    ]);
  }

  destroy(): void {
    this.destroyed = true;
    initialLayoutLoaded.set(false);
    this.teardownDpiDetection();
    if (this.initialPanelListResolve) {
      this.initialPanelListResolve();
      this.initialPanelListResolve = null;
    }
    if (this.reconnectTimeoutId) {
      clearTimeout(this.reconnectTimeoutId);
      this.reconnectTimeoutId = null;
    }
    for (const timeoutId of this.bellTimeouts.values()) {
      clearTimeout(timeoutId);
    }
    this.bellTimeouts.clear();
    if (this.controlWs) {
      this.controlWs.close();
      this.controlWs = null;
    }
    if (this.h264Ws) {
      this.h264Ws.close();
      this.h264Ws = null;
    }
    this.closeFileWs();
    this.fileTransfer.disconnect();
    for (const panel of this.panelInstances.values()) {
      panel.destroy();
    }
    this.panelInstances.clear();
    this.panelsByServerId.clear();
    this.h264PendingFrames.clear();
    this.controlPendingByPanel.clear();
    panels.clear();
    for (const tab of this.tabInstances.values()) {
      tab.root.destroy();
    }
    this.tabInstances.clear();
    tabs.clear();
    this.currentActivePanel = null;
    this.quickTerminalPanel = null;
    this.previousActivePanel = null;
  }

  private applyConfig(config: AppConfig): void {
    if (config.colors) applyColors(config.colors);
    if (config.keybindings) keybindings.set(config.keybindings);
  }

  private connectControl(): void {
    if (this.destroyed) return;
    const wsUrl = getWsUrl(WS_PATHS.CONTROL);
    this.controlWs = new WebSocket(wsUrl);
    this.controlWs.binaryType = 'arraybuffer';

    this.controlWs.onopen = () => {
      console.log('Control channel connected');
      connectionStatus.set('connected');
      this.reconnectDelay = TIMING.WS_RECONNECT_INITIAL;
    };

    this.controlWs.onmessage = (event) => {
      if (this.destroyed) return;
      if (typeof event.data === 'string') {
        try {
          this.handleJsonMessage(JSON.parse(event.data));
        } catch (err) {
          console.error('Failed to parse JSON message:', err);
        }
      } else if (event.data instanceof ArrayBuffer) {
        // Server sends [compression_flag:u8][data...] — zstd framed, no exceptions
        const raw = new Uint8Array(event.data);
        if (raw.length < 2) return;
        const flag = raw[0];
        if (flag === 0x01) {
          // zstd compressed — decompress and pass inner data
          try {
            const decompressed = decompressZstd(raw.subarray(1));
            this.handleBinaryMessage(decompressed.buffer as ArrayBuffer);
          } catch (err) {
            console.error('zstd decompress failed:', err);
          }
        } else if (flag === 0x00) {
          // Uncompressed — strip flag byte
          this.handleBinaryMessage(raw.buffer.slice(1));
        }
      }
    };

    this.controlWs.onclose = () => {
      console.log('[MUX] Control channel disconnected');
      connectionStatus.set('disconnected');
      if (!this.destroyed) {
        const jitter = Math.random() * 0.3 * this.reconnectDelay;
        const delay = Math.min(this.reconnectDelay + jitter, TIMING.WS_RECONNECT_MAX);
        if (this.reconnectTimeoutId) clearTimeout(this.reconnectTimeoutId);
        this.reconnectTimeoutId = setTimeout(() => this.connectControl(), delay);
        this.reconnectDelay = Math.min(this.reconnectDelay * 2, TIMING.WS_RECONNECT_MAX);
      }
    };

    this.controlWs.onerror = () => {
      connectionStatus.set('error');
    };
  }

  private handleJsonMessage(msg: Record<string, unknown>): void {
    const type = msg.type as string;
    switch (type) {
      case 'panel_list':
        if (isValidLayoutData(msg.layout)) {
          this.restoreLayoutFromServer(msg.layout);
        }
        break;
      case 'panel_created':
        this.handlePanelCreated(msg.panel_id as number);
        break;
      case 'panel_closed':
        this.handlePanelClosed(msg.panel_id as number);
        break;
      case 'panel_title':
        this.updatePanelTitle(msg.panel_id as number, msg.title as string);
        break;
      case 'auth_state':
        authState.set({
          role: msg.role as number,
          authRequired: msg.authRequired as boolean,
          hasPassword: msg.hasPassword as boolean,
          passkeyCount: msg.passkeyCount as number,
        });
        break;
    }
  }

  private handleBinaryMessage(data: ArrayBuffer): void {
    if (data.byteLength < 1) return;
    const view = new DataView(data);
    const bytes = new Uint8Array(data);
    const msgType = view.getUint8(0);

    // Panel-specific messages: cache if panel not registered yet
    if (data.byteLength >= 5 && (
      msgType === SERVER_MSG.PANEL_TITLE ||
      msgType === SERVER_MSG.PANEL_PWD ||
      msgType === SERVER_MSG.PANEL_BELL ||
      msgType === SERVER_MSG.CURSOR_STATE ||
      msgType === SERVER_MSG.INSPECTOR_STATE
    )) {
      const panelId = view.getUint32(1, true);
      if (!this.panelsByServerId.has(panelId)) {
        let pending = this.controlPendingByPanel.get(panelId);
        if (!pending) {
          pending = [];
          this.controlPendingByPanel.set(panelId, pending);
        }
        pending.push(data);
        return;
      }
    }

    try {
      switch (msgType) {
        case SERVER_MSG.PANEL_LIST: {
          const count = view.getUint8(1);
          const panelList: Array<{ panel_id: number; title: string }> = [];
          let offset = 2;
          for (let i = 0; i < count; i++) {
            const panelId = view.getUint32(offset, true);
            offset += 4;
            const titleLen = view.getUint8(offset);
            offset += 1;
            const title = sharedTextDecoder.decode(bytes.slice(offset, offset + titleLen));
            offset += titleLen;
            panelList.push({ panel_id: panelId, title });
          }
          const layoutLen = view.getUint16(offset, true);
          offset += 2;
          const layoutJson = sharedTextDecoder.decode(bytes.slice(offset, offset + layoutLen));
          let layout = null;
          try { layout = JSON.parse(layoutJson); } catch { /* ignore */ }
          this.handlePanelList(panelList, layout);
          break;
        }
        case SERVER_MSG.PANEL_CREATED:
          this.handlePanelCreated(view.getUint32(1, true));
          break;
        case SERVER_MSG.PANEL_CLOSED:
          this.handlePanelClosed(view.getUint32(1, true));
          break;
        case SERVER_MSG.PANEL_TITLE: {
          const panelId = view.getUint32(1, true);
          const titleLen = view.getUint8(5);
          const title = sharedTextDecoder.decode(bytes.slice(6, 6 + titleLen));
          this.updatePanelTitle(panelId, title);
          break;
        }
        case SERVER_MSG.PANEL_PWD: {
          const panelId = view.getUint32(1, true);
          const pwdLen = view.getUint16(5, true);
          const pwd = sharedTextDecoder.decode(bytes.slice(7, 7 + pwdLen));
          this.updatePanelPwd(panelId, pwd);
          break;
        }
        case SERVER_MSG.PANEL_BELL:
          this.handleBell(view.getUint32(1, true));
          break;
        case SERVER_MSG.LAYOUT_UPDATE: {
          const layoutLen = view.getUint16(1, true);
          const layoutJson = sharedTextDecoder.decode(bytes.slice(3, 3 + layoutLen));
          try {
            const layout = JSON.parse(layoutJson);
            this.handleLayoutUpdate(layout);
          } catch { /* ignore */ }
          break;
        }
        case SERVER_MSG.CLIPBOARD: {
          const dataLen = view.getUint32(1, true);
          const text = sharedTextDecoder.decode(bytes.slice(5, 5 + dataLen));
          navigator.clipboard.writeText(text).catch(console.error);
          break;
        }
        case SERVER_MSG.AUTH_STATE: {
          const role = view.getUint8(1);
          authState.set({
            role,
            authRequired: view.getUint8(2) === 1,
            hasPassword: view.getUint8(3) === 1,
            passkeyCount: view.getUint8(4),
            githubConfigured: data.byteLength > 5 ? view.getUint8(5) === 1 : false,
            googleConfigured: data.byteLength > 6 ? view.getUint8(6) === 1 : false,
          });
          // Update UI isAdmin flag
          const isAdmin = role === Role.ADMIN;
          ui.update(s => ({ ...s, isAdmin }));
          // Auto-switch mode based on role
          // Admins and editors use main mode (can create/interact with panels)
          // Only read-only viewers use viewer mode
          if (role === Role.VIEWER) {
            this.enterViewerMode();
          } else {
            this.enterMainMode();
          }
          break;
        }
        case SERVER_MSG.JWT_RENEWAL: {
          // [0x0D][jwt_len:u16_le][jwt...]
          if (data.byteLength > 3) {
            const jwtLen = view.getUint16(1, true);
            if (jwtLen > 0 && data.byteLength >= 3 + jwtLen) {
              const jwt = new TextDecoder().decode(bytes.slice(3, 3 + jwtLen));
              // Update URL without reload so future requests/reconnects use the new JWT
              const url = new URL(window.location.href);
              url.searchParams.set('token', jwt);
              window.history.replaceState({}, '', url.toString());
            }
          }
          break;
        }
        case SERVER_MSG.OVERVIEW_STATE:
          ui.update(s => ({ ...s, overviewOpen: view.getUint8(1) === 1 }));
          break;
        case SERVER_MSG.QUICK_TERMINAL_STATE:
          ui.update(s => ({ ...s, quickTerminalOpen: view.getUint8(1) === 1 }));
          break;
        case SERVER_MSG.MAIN_CLIENT_STATE: {
          if (data.byteLength < 6) break;
          const isMain = view.getUint8(1) === 1;
          const clientId = view.getUint32(2, true);
          ui.update(s => ({ ...s, isMainClient: isMain, clientId }));
          // Switch viewer/main mode based on role
          // Editors stay in main mode; only viewers are read-only
          const currentAuth = get(authState);
          if (currentAuth.role === Role.VIEWER) {
            this.enterViewerMode();
          } else {
            this.enterMainMode();
          }
          break;
        }
        case SERVER_MSG.PANEL_ASSIGNMENT: {
          // [0x11][panel_id:u32][session_id_len:u8][session_id:...]
          if (data.byteLength < 6) break;
          const panelId = view.getUint32(1, true);
          const sidLen = view.getUint8(5);
          const sessionId = sidLen > 0
            ? sharedTextDecoder.decode(bytes.slice(6, 6 + sidLen))
            : '';
          ui.update(s => {
            const assignments = new Map(s.panelAssignments);
            if (sessionId) {
              assignments.set(panelId, sessionId);
            } else {
              assignments.delete(panelId);
            }
            return { ...s, panelAssignments: assignments };
          });
          // Wire/unwire coworker input based on assignment
          this.updateCoworkerInput(panelId, sessionId);
          break;
        }
        case SERVER_MSG.SESSION_IDENTITY: {
          // [0x13][session_id_len:u8][session_id:...]
          if (data.byteLength < 2) break;
          const sidLen = view.getUint8(1);
          const mySessionId = sidLen > 0
            ? sharedTextDecoder.decode(bytes.slice(2, 2 + sidLen))
            : null;
          ui.update(s => ({ ...s, sessionId: mySessionId }));
          // Re-evaluate coworker input for all assigned panels
          if (mySessionId) {
            const currentAssignments = get(ui).panelAssignments;
            for (const [pid, sid] of currentAssignments) {
              this.updateCoworkerInput(pid, sid);
            }
          }
          break;
        }
        case SERVER_MSG.CLIENT_LIST: {
          // [0x12][count:u8][{client_id:u32, role:u8, session_id_len:u8, session_id:...}*]
          if (data.byteLength < 2) break;
          const count = view.getUint8(1);
          const clients: Array<{clientId: number; role: number; sessionId: string}> = [];
          let offset = 2;
          for (let i = 0; i < count; i++) {
            if (offset + 6 > data.byteLength) break;
            const cid = view.getUint32(offset, true); offset += 4;
            const role = view.getUint8(offset); offset += 1;
            const sidLen = view.getUint8(offset); offset += 1;
            const sid = sidLen > 0
              ? sharedTextDecoder.decode(bytes.slice(offset, offset + sidLen))
              : '';
            offset += sidLen;
            clients.push({ clientId: cid, role, sessionId: sid });
          }
          ui.update(s => ({ ...s, connectedClients: clients }));
          break;
        }

        case SERVER_MSG.SESSION_LIST: {
          // [0x0B][count:u16][{id_len:u16, id, name_len:u16, name, token_hex:64, role:u8}*]
          if (data.byteLength < 3) break;
          const count = view.getUint16(1, true);
          const parsed: Array<{id: string; name: string; createdAt: number; token: string; role: number}> = [];
          let offset = 3;
          for (let i = 0; i < count; i++) {
            if (offset + 2 > data.byteLength) break;
            const idLen = view.getUint16(offset, true); offset += 2;
            if (offset + idLen > data.byteLength) break;
            const id = sharedTextDecoder.decode(bytes.slice(offset, offset + idLen)); offset += idLen;
            if (offset + 2 > data.byteLength) break;
            const nameLen = view.getUint16(offset, true); offset += 2;
            if (offset + nameLen > data.byteLength) break;
            const name = sharedTextDecoder.decode(bytes.slice(offset, offset + nameLen)); offset += nameLen;
            if (offset + 65 > data.byteLength) break; // 64 hex + 1 role
            const token = sharedTextDecoder.decode(bytes.slice(offset, offset + 64)); offset += 64;
            const role = bytes[offset]; offset += 1;
            parsed.push({ id, name, createdAt: 0, token, role });
          }
          sessions.set(parsed);
          break;
        }
        case SERVER_MSG.SHARE_LINKS: {
          // [0x0C][count:u16][{token:44, type:u8, use_count:u32, valid:u8}*]
          // Currently just log — full share link UI can be added later
          break;
        }
        case SERVER_MSG.SURFACE_DIMS: {
          // [0x15][panel_id:u32][width:u16][height:u16] = 9 bytes
          if (data.byteLength < 9) break;
          this.surfaceDims.set(view.getUint32(1, true), {
            w: view.getUint16(5, true),
            h: view.getUint16(7, true),
          });
          break;
        }
        case SERVER_MSG.CURSOR_STATE: {
          // [0x14][panel_id:u32][x:u16][y:u16][w:u16][h:u16][style:u8][visible:u8][r:u8][g:u8][b:u8] = 18 bytes
          if (data.byteLength < 18) break;
          const panelId = view.getUint32(1, true);
          const x = view.getUint16(5, true);
          const y = view.getUint16(7, true);
          const w = view.getUint16(9, true);
          const h = view.getUint16(11, true);
          const style = view.getUint8(13);   // 0=bar, 1=block, 2=underline, 3=block_hollow
          const visible = view.getUint8(14) === 1;
          const colorR = view.getUint8(15);
          const colorG = view.getUint8(16);
          const colorB = view.getUint8(17);
          // Use cached surface dims from SURFACE_DIMS message
          const dims = this.surfaceDims.get(panelId);
          const totalW = dims?.w ?? 0;
          const totalH = dims?.h ?? 0;
          const panel = this.panelsByServerId.get(panelId);
          if (panel) {
            panel.updateCursorState(x, y, w, h, style, visible, totalW, totalH, colorR, colorG, colorB);
          }
          break;
        }
        case SERVER_MSG.INSPECTOR_STATE: {
          // [type:u8][panel_id:u32][cols:u16][rows:u16][sw:u16][sh:u16][cw:u8][ch:u8] = 15 bytes
          if (data.byteLength < 15) break;
          const panelId = view.getUint32(1, true);
          const state = {
            cols: view.getUint16(5, true),
            rows: view.getUint16(7, true),
            width_px: view.getUint16(9, true),
            height_px: view.getUint16(11, true),
            cell_width: view.getUint8(13),
            cell_height: view.getUint8(14),
          };
          const panel = this.panelsByServerId.get(panelId);
          if (panel) panel.handleInspectorState(state);
          break;
        }
        case SERVER_MSG.CONFIG_UPDATED: {
          if (data.byteLength > 1) {
            try {
              const jsonBytes = new Uint8Array(data, 1);
              const updatedConfig: AppConfig = JSON.parse(sharedTextDecoder.decode(jsonBytes));
              this.applyConfig(updatedConfig);
            } catch (err) {
              console.error('Failed to parse CONFIG_UPDATED payload:', err);
            }
          }
          break;
        }
        case SERVER_MSG.INSPECTOR_OPEN_STATE: {
          // [type:u8][open:u8] = 2 bytes
          if (data.byteLength < 2) break;
          const isOpen = view.getUint8(1) === 1;
          ui.update(s => ({ ...s, inspectorOpen: isOpen }));
          if (isOpen) {
            for (const panel of this.panelInstances.values()) {
              panel.toggleInspector(true);
            }
          }
          break;
        }
        case SERVER_MSG.CONFIG_CONTENT: {
          // [type:u8][path_len:u16_le][path...][content_len:u32_le][content...]
          if (data.byteLength < 7) break;
          const pathLen = view.getUint16(1, true);
          if (data.byteLength < 3 + pathLen + 4) break;
          const configPath = sharedTextDecoder.decode(bytes.slice(3, 3 + pathLen));
          const contentLen = view.getUint32(3 + pathLen, true);
          const contentStart = 7 + pathLen;
          if (data.byteLength < contentStart + contentLen) break;
          const configContent = sharedTextDecoder.decode(bytes.slice(contentStart, contentStart + contentLen));
          this.onConfigContent?.(configPath, configContent);
          break;
        }
        case SERVER_MSG.SCREEN_DUMP: {
          // [type:u8][filename_len:u8][filename...][content_len:u32_le][content...]
          if (data.byteLength < 6) break;
          const filenameLen = view.getUint8(1);
          if (data.byteLength < 2 + filenameLen + 4) break;
          const filename = sharedTextDecoder.decode(bytes.slice(2, 2 + filenameLen));
          const contentLen = view.getUint32(2 + filenameLen, true);
          const contentStart = 6 + filenameLen;
          if (data.byteLength < contentStart + contentLen) break;
          const content = bytes.slice(contentStart, contentStart + contentLen);
          // Trigger browser download
          const blob = new Blob([content], { type: 'text/plain' });
          const url = URL.createObjectURL(blob);
          const a = document.createElement('a');
          a.href = url;
          a.download = filename || 'screen.txt';
          document.body.appendChild(a);
          a.click();
          document.body.removeChild(a);
          URL.revokeObjectURL(url);
          break;
        }
        case SERVER_MSG.OAUTH_CONFIG: {
          // [0x1A][github:u8][google:u8][default_role:u8]
          if (data.byteLength >= 4) {
            authState.update(s => ({
              ...s,
              githubConfigured: view.getUint8(1) === 1,
              googleConfigured: view.getUint8(2) === 1,
            }));
          }
          break;
        }
        default:
          break;
      }
    } catch (err) {
      console.error('Failed to parse binary message:', err);
    }
  }

  private updatePanelPwd(serverId: number, pwd: string): void {
    const panel = this.panelsByServerId.get(serverId);
    if (panel) {
      panel.setPwd(pwd);
      panels.updatePanel(panel.id, { pwd });
    }
  }

  private handleBell(serverId: number): void {
    const panel = this.panelsByServerId.get(serverId);
    if (panel) {
      const existingTimeout = this.bellTimeouts.get(serverId);
      if (existingTimeout) clearTimeout(existingTimeout);
      panel.element.classList.add('bell');
      const timeoutId = setTimeout(() => {
        this.bellTimeouts.delete(serverId);
        if (this.panelInstances.has(panel.id)) {
          panel.element.classList.remove('bell');
        }
      }, TIMING.BELL_FLASH_DURATION);
      this.bellTimeouts.set(serverId, timeoutId);
    }
  }

  private handleLayoutUpdate(layout: LayoutData): void {
    // Build a set of server tab IDs for later cleanup
    const serverTabIds = new Set(layout.tabs.map(t => String(t.id)));

    // Handle new tabs incrementally — create only what's missing
    for (const tabLayout of layout.tabs) {
      const serverTabId = String(tabLayout.id);
      if (!this.tabInstances.has(serverTabId)) {
        // Before creating a duplicate, check if an existing client tab already
        // has the same panel(s) — this happens when the client creates a tab
        // locally (with a client-generated ID) before the server assigns its own ID.
        const serverPanelIds = new Set<number>();
        this.collectLayoutPanelIds(tabLayout.root, serverPanelIds);

        let remapped = false;
        for (const [clientTabId, clientTab] of this.tabInstances) {
          if (serverTabIds.has(clientTabId)) continue; // Already matched to a server tab
          const clientPanels = clientTab.root.getAllPanels();
          const overlap = clientPanels.some(p => p.serverId !== null && serverPanelIds.has(p.serverId));
          if (overlap) {
            // Remap: update the client tab ID to match the server's
            console.log(`[MUX] Remapping client tab ${clientTabId} → server tab ${serverTabId}`);
            this.tabInstances.delete(clientTabId);
            clientTab.id = serverTabId;
            clientTab.element.dataset.tabId = serverTabId;
            this.tabInstances.set(serverTabId, clientTab);
            tabs.remove(clientTabId);
            tabs.add({ id: serverTabId, title: clientTab.title, panelIds: clientPanels.map(p => p.id) });
            // Fix tab history references
            this.tabHistory = this.tabHistory.map(id => id === clientTabId ? serverTabId : id);
            // Fix active tab store if it pointed to the old ID
            if (get(activeTabIdStore) === clientTabId) {
              activeTabIdStore.set(serverTabId);
            }
            this.nextTabId = Math.max(this.nextTabId, tabLayout.id + 1);
            remapped = true;
            break;
          }
        }

        if (!remapped) {
          console.log(`[MUX] Layout has new tab ${tabLayout.id} — creating`);
          this.restoreTab(tabLayout);
        }
      }
    }

    // Remove client tabs that no longer exist in the server layout
    for (const clientTabId of Array.from(this.tabInstances.keys())) {
      if (!serverTabIds.has(clientTabId)) {
        // Check if this tab has any panels — if it has unmatched panels, it might
        // be a local-only tab that hasn't been assigned a server ID yet
        const clientTab = this.tabInstances.get(clientTabId);
        if (clientTab) {
          const clientPanels = clientTab.root.getAllPanels();
          const hasUnassignedPanel = clientPanels.some(p => p.serverId === null);
          if (!hasUnassignedPanel) {
            // All panels have server IDs but tab isn't in server layout — stale, remove it
            console.log(`[MUX] Removing stale client tab ${clientTabId} (not in server layout)`);
            this.closeTab(clientTabId);
          }
        }
      }
    }

    // Reconcile existing tabs: direction, ratio, and new splits (leaf→split conversion)
    for (const tabLayout of layout.tabs) {
      const tabId = String(tabLayout.id);
      const tab = this.tabInstances.get(tabId);
      if (tab) {
        const fixes = this.reconcileTree(tab.root, tabLayout.root, tab.element);
        if (fixes > 0) {
          console.log(`[MUX] Reconciled ${fixes} mismatches from server layout`);
          // Update tab's panel list after structural changes
          const allPanels = tab.root.getAllPanels();
          tabs.updateTab(tabId, { panelIds: allPanels.map(p => p.id) });
        }
      }
    }
  }

  private collectLayoutPanelIds(node: LayoutNode, ids: Set<number>): void {
    if (node.type === 'leaf' && node.panelId !== undefined) {
      ids.add(node.panelId);
    } else if (node.type === 'split') {
      if (node.first) this.collectLayoutPanelIds(node.first, ids);
      if (node.second) this.collectLayoutPanelIds(node.second, ids);
    }
  }

  /**
   * Walk client and server trees in parallel, fixing structural mismatches.
   * Handles direction/ratio fixes AND leaf→split conversions (for server-initiated splits).
   * Returns the number of fixes applied.
   */
  private reconcileTree(container: SplitContainer, node: LayoutNode, tabElement: HTMLElement): number {
    let fixes = 0;

    if (node.type === 'leaf') {
      // Server says leaf — nothing structural to change
      return fixes;
    }

    if (node.type !== 'split' || !node.first || !node.second) return fixes;

    if (container.direction !== null && container.first && container.second) {
      // Both are splits — check direction
      const expectedDirection: 'horizontal' | 'vertical' = node.direction === 'horizontal' ? 'horizontal' : 'vertical';
      if (container.direction !== expectedDirection) {
        console.log(`[MUX] Direction mismatch: client=${container.direction}, server=${expectedDirection}`);
        container.direction = expectedDirection;
        container.element.className = `split-container ${expectedDirection}`;
        fixes++;
      }
      // Fix ratio
      if (node.ratio !== undefined && Math.abs(container.ratio - node.ratio) > 0.001) {
        container.ratio = node.ratio;
        container.applyRatio();
        fixes++;
      }
      // Recurse into children
      fixes += this.reconcileTree(container.first, node.first, tabElement);
      fixes += this.reconcileTree(container.second, node.second, tabElement);
    } else if (container.panel) {
      // Client has leaf, server has split — convert leaf to split incrementally.
      // This happens when the server (e.g. tmux API) splits an existing panel.
      const existingServerId = container.panel.serverId;

      // Figure out which side of the server split contains the existing panel
      const firstIds = new Set<number>();
      this.collectLayoutPanelIds(node.first, firstIds);
      const secondIds = new Set<number>();
      this.collectLayoutPanelIds(node.second, secondIds);

      const existingInFirst = existingServerId !== null && firstIds.has(existingServerId);
      const existingInSecond = existingServerId !== null && secondIds.has(existingServerId);

      if (!existingInFirst && !existingInSecond) {
        // Existing panel not found in server layout — fall back to full rebuild
        console.warn(`[MUX] Panel ${existingServerId} not found in server split — full rebuild`);
        return fixes;
      }

      const isHorizontal = node.direction === 'horizontal';
      // SplitContainer.split() directions: 'right'|'down'|'left'|'up'
      // If existing is first child → new panel goes right/down
      // If existing is second child → new panel goes left/up
      const splitCmd: 'right' | 'down' | 'left' | 'up' = existingInFirst
        ? (isHorizontal ? 'right' : 'down')
        : (isHorizontal ? 'left' : 'up');

      // Get the first leaf ID from the "other" side to create as the new panel
      const otherNode = existingInFirst ? node.second : node.first;
      const newPanelServerId = this.getFirstLeafId(otherNode);

      if (newPanelServerId === null) {
        console.warn('[MUX] No leaf found in other side of server split');
        return fixes;
      }

      console.log(`[MUX] Converting leaf (panel ${existingServerId}) to split: creating panel ${newPanelServerId}, direction=${splitCmd}`);
      const newPanel = this.createPanel(tabElement, newPanelServerId);
      container.split(splitCmd, newPanel);
      // Flush pending messages AFTER the split so the panel element has its
      // correct post-split dimensions. Don't send resize here — the Panel.svelte
      // ResizeObserver will fire on the next animation frame with accurate
      // dimensions from each client's own viewport.
      this.flushPendingMessages(newPanelServerId, newPanel);

      // Apply ratio from server
      if (node.ratio !== undefined) {
        container.ratio = node.ratio;
        container.applyRatio();
      }
      fixes++;

      // Recurse into both children for further structural changes
      if (container.first && container.second) {
        const [firstNode, secondNode] = existingInFirst
          ? [node.first, node.second]
          : [node.second, node.first];
        fixes += this.reconcileTree(container.first, firstNode, tabElement);
        fixes += this.reconcileTree(container.second, secondNode, tabElement);
      }
    }
    return fixes;
  }

  /** Get the first leaf panel ID from a layout subtree. */
  private getFirstLeafId(node: LayoutNode): number | null {
    if (node.type === 'leaf' && node.panelId !== undefined) return node.panelId;
    if (node.type === 'split') {
      if (node.first) {
        const id = this.getFirstLeafId(node.first);
        if (id !== null) return id;
      }
      if (node.second) {
        const id = this.getFirstLeafId(node.second);
        if (id !== null) return id;
      }
    }
    return null;
  }

  /**
   * Flush buffered control messages and H264 frames for a newly registered panel.
   * Does NOT send a resize — the Panel.svelte ResizeObserver handles that after
   * the DOM has reflowed, giving each client accurate viewport-based dimensions.
   */
  private flushPendingMessages(serverId: number, panel: PanelInstance): void {
    const pendingCtrl = this.controlPendingByPanel.get(serverId);
    if (pendingCtrl) {
      this.controlPendingByPanel.delete(serverId);
      for (const msg of pendingCtrl) {
        this.handleBinaryMessage(msg);
      }
    }
    const pendingFrames = this.h264PendingFrames.get(serverId);
    if (pendingFrames) {
      this.h264PendingFrames.delete(serverId);
      for (const frame of pendingFrames) {
        panel.decodePreviewFrame(frame);
      }
    }
  }

  private handlePanelList(panelList: Array<{ panel_id: number; title: string }>, layout: unknown): void {
    if (isValidLayoutData(layout) && layout.tabs.length > 0) {
      this.restoreLayoutFromServer(layout);
    } else if (panelList.length > 0) {
      this.reconnectPanelsAsSplits(panelList);
    }
    // Apply panel titles from the panel list (layout JSON doesn't include titles)
    for (const { panel_id, title } of panelList) {
      if (title) {
        this.updatePanelTitle(panel_id, title);
      }
    }
    // Mark that we've received the initial layout from server
    initialLayoutLoaded.set(true);
    if (this.initialPanelListResolve) {
      this.initialPanelListResolve();
      this.initialPanelListResolve = null;
    }
  }

  private reconnectPanelsAsSplits(panelList: Array<{ panel_id: number; title: string }>): void {
    if (panelList.length === 0) return;
    const tabId = this.createTab(panelList[0].panel_id, panelList[0].title);
    const tab = this.tabInstances.get(tabId);
    if (!tab) return;
    for (let i = 1; i < panelList.length; i++) {
      const panel = this.createPanel(tab.element, panelList[i].panel_id);
      tab.root.split('right', panel);
    }
  }

  private handlePanelCreated(panelId: number): void {
    for (const panel of this.panelInstances.values()) {
      if (panel.serverId === null) {
        panel.serverId = panelId;
        this.panelsByServerId.set(panelId, panel);
        // Flush any control messages that arrived before the panel was registered
        const pendingCtrl = this.controlPendingByPanel.get(panelId);
        if (pendingCtrl) {
          this.controlPendingByPanel.delete(panelId);
          for (const msg of pendingCtrl) {
            this.handleBinaryMessage(msg);
          }
        }
        // Flush any H264 frames that arrived before the panel was registered
        const pendingFrames = this.h264PendingFrames.get(panelId);
        if (pendingFrames) {
          this.h264PendingFrames.delete(panelId);
          for (const frame of pendingFrames) {
            panel.decodePreviewFrame(frame);
          }
        }
        // Send resize now that the server has assigned an ID.
        // Any resize sent before this point used serverId=0 and was dropped.
        const rect = panel.element.getBoundingClientRect();
        const w = Math.floor(rect.width);
        const h = Math.floor(rect.height);
        if (w > 0 && h > 0) {
          const scale = window.devicePixelRatio || 1;
          this.sendResizePanelWithScale(panelId, w, h, scale);
        }
        // Now that we have a real serverId, re-activate this panel if it's the
        // current active one. This sends FOCUS_PANEL to the server (skipped
        // earlier because serverId was null) and ensures the tab is properly shown.
        if (this.currentActivePanel?.id === panel.id) {
          this.setActivePanel(panel);
        }
        break;
      }
    }
  }

  private handlePanelClosed(serverId: number): void {
    this.surfaceDims.delete(serverId);
    this.h264PendingFrames.delete(serverId);
    this.controlPendingByPanel.delete(serverId);
    const panel = this.panelsByServerId.get(serverId);
    if (panel) {
      this.removePanel(panel.id);
    }
  }

  private updatePanelTitle(serverId: number, title: string): void {
    const panel = this.panelsByServerId.get(serverId);
    if (panel) {
      panels.updatePanel(panel.id, { title });
      const tabId = this.findTabIdForPanel(panel);
      if (tabId) {
        tabs.updateTab(tabId, { title });
        // Update browser title when the active tab's title changes
        if (tabId === get(activeTabIdStore)) {
          document.title = title || '👻';
        }
      }
    }
  }

  private findTabIdForPanel(panel: PanelLike): string | null {
    for (const [tabId, tab] of this.tabInstances) {
      const allPanels = tab.root.getAllPanels();
      if (allPanels.some(p => p.id === panel.id)) {
        return tabId;
      }
    }
    return null;
  }

  createTab(serverId?: number, title?: string): string {
    if (!this.panelsEl) {
      console.error('Cannot create tab: panelsEl not initialized');
      return '';
    }
    const tabId = String(this.nextTabId++);
    const tabContent = document.createElement('div');
    tabContent.className = 'tab-content';
    tabContent.dataset.tabId = tabId;
    this.panelsEl.appendChild(tabContent);

    const root = new SplitContainer(null);
    root.element.className = 'split-pane';
    root.element.style.flex = '1';
    tabContent.appendChild(root.element);

    const panel = this.createPanel(root.element, serverId ?? null);
    root.panel = panel;

    const tabInfo: InternalTabInfo = {
      id: tabId,
      title: title || UI.DEFAULT_TAB_TITLE,
      root,
      element: tabContent,
    };
    this.tabInstances.set(tabId, tabInfo);
    tabs.add(createTabInfo(tabId));
    tabs.updateTab(tabId, { title: title || UI.DEFAULT_TAB_TITLE, panelIds: [panel.id] });
    this.selectTab(tabId);
    return tabId;
  }

  selectTab(tabId: string): void {
    const tab = this.tabInstances.get(tabId);
    if (!tab) return;

    // Always update DOM state: remove 'active' from all tabs, add to this one
    for (const t of this.tabInstances.values()) {
      t.element.classList.remove('active');
    }
    tab.element.classList.add('active');
    activeTabIdStore.set(tabId);
    this.tabHistory = this.tabHistory.filter(id => id !== tabId);
    this.tabHistory.push(tabId);

    const allPanels = tab.root.getAllPanels();
    if (allPanels.length > 0) {
      this.setActivePanel(allPanels[0] as PanelInstance);
    }
  }

  closeTab(tabId: string): void {
    const tab = this.tabInstances.get(tabId);
    if (!tab) return;
    const allPanels = tab.root.getAllPanels();
    for (const panel of allPanels) {
      // Send close message to server (optimistic update - frontend updates immediately)
      if (panel.serverId !== null) {
        this.sendClosePanel(panel.serverId);

        this.panelsByServerId.delete(panel.serverId);
      }
      this.panelInstances.delete(panel.id);
      panels.remove(panel.id);
      // Note: Don't call panel.destroy() here - SplitContainer.destroy() will do it
    }
    tab.root.destroy();
    tab.element.remove();
    this.tabInstances.delete(tabId);
    tabs.remove(tabId);
    this.tabHistory = this.tabHistory.filter(id => id !== tabId);
    if (this.tabHistory.length > 0) {
      this.selectTab(this.tabHistory[this.tabHistory.length - 1]);
    } else if (this.tabInstances.size > 0) {
      const firstTabId = this.tabInstances.keys().next().value;
      if (firstTabId) this.selectTab(firstTabId);
    } else {
      activeTabIdStore.set(null);
      activePanelId.set(null);
      this.currentActivePanel = null;
      document.title = '👻';
    }
  }

  private createPanel(
    container: HTMLElement,
    serverId: number | null,
    isQuickTerminal = false,
    splitInfo?: { parentPanelId: number; direction: 'right' | 'down' | 'left' | 'up' }
  ): PanelInstance {
    const panelId = generateId();

    // Create wrapper element
    const wrapperEl = document.createElement('div');
    wrapperEl.className = 'panel';
    container.appendChild(wrapperEl);

    // Mount Svelte component
    const component = mount(PanelComponent, {
      target: wrapperEl,
      props: {
        id: panelId,
        serverId,
        isQuickTerminal,
        splitInfo,
        onStatusChange: (status: PanelStatus) => panels.updatePanel(panelId, { status }),
        onTitleChange: (title: string) => {
          panels.updatePanel(panelId, { title });
          const tabId = this.findTabIdForPanelId(panelId);
          if (tabId) tabs.updateTab(tabId, { title });
        },
        onPwdChange: (pwd: string) => panels.updatePanel(panelId, { pwd }),
        onServerIdAssigned: (newServerId: number) => {
          panel.serverId = newServerId;
          this.panelsByServerId.set(newServerId, panel);
        },
        onActivate: () => this.setActivePanel(panel),
        onFileDrop: (files: File[], dirHandle?: FileSystemDirectoryHandle) => this.handleFileDrop(panel, files, dirHandle),
        onTextPaste: (text: string) => {
          this.sendClipboard(text);
          this.sendViewAction('paste_from_clipboard');
        },
      },
    });

    // Get component exports
    const comp = component as unknown as {
      connect: () => void;
      focus: () => void;
      toggleInspector: (visible?: boolean) => void;
      isInspectorOpen: () => boolean;
      hide: () => void;
      show: () => void;
      sendKeyInput: (e: KeyboardEvent, action: number) => void;
      sendTextInput: (text: string) => void;
      setControlWsSend: (fn: ((msg: ArrayBuffer | ArrayBufferView) => void) | null, immediateFn?: ((msg: ArrayBuffer | ArrayBufferView) => void) | null) => void;
      decodePreviewFrame: (frameData: Uint8Array) => void;
      handleInspectorState: (state: unknown) => void;
      getStatus: () => PanelStatus;
      getPwd: () => string;
      setPwd: (pwd: string) => void;
      getCanvas: () => HTMLCanvasElement | undefined;
      getSnapshotCanvas: () => HTMLCanvasElement | undefined;
      updateCursorState: (x: number, y: number, w: number, h: number, style: number, visible: boolean, totalW: number, totalH: number) => void;
    };

    const panel: PanelInstance = {
      id: panelId,
      serverId,
      element: wrapperEl,
      get canvas() { return comp.getCanvas(); },
      component,
      connect: () => comp.connect(),
      focus: () => comp.focus(),
      destroy: () => {
        unmount(component);
        wrapperEl.remove();
      },
      toggleInspector: (v) => comp.toggleInspector(v),
      isInspectorOpen: () => comp.isInspectorOpen(),
      hide: () => comp.hide(),
      show: () => comp.show(),
      sendKeyInput: (e, a) => comp.sendKeyInput(e, a),
      sendTextInput: (t) => comp.sendTextInput(t),
      setControlWsSend: (fn, immFn) => comp.setControlWsSend(fn, immFn),
      decodePreviewFrame: (f) => comp.decodePreviewFrame(f),
      handleInspectorState: (s) => comp.handleInspectorState(s),
      getStatus: () => comp.getStatus(),
      getPwd: () => comp.getPwd(),
      setPwd: (p) => comp.setPwd(p),
      getSnapshotCanvas: () => comp.getSnapshotCanvas(),
      updateCursorState: (x, y, w, h, s, v, tw, th) => comp.updateCursorState(x, y, w, h, s, v, tw, th),
    };

    this.panelInstances.set(panelId, panel);
    if (serverId !== null) {
      this.panelsByServerId.set(serverId, panel);
    }
    panels.add(createPanelInfo(panelId, serverId, isQuickTerminal));

    // Wire panel to send via PANEL_MSG envelope on control WS
    // Batched path (rAF) for bulk messages, immediate path for key/click input
    panel.setControlWsSend(
      (msg) => {
        const sid = panel.serverId ?? 0;
        this.sendPanelMsg(sid, msg);
      },
      (msg) => {
        const sid = panel.serverId ?? 0;
        this.sendPanelMsgImmediate(sid, msg);
      },
    );

    // Viewers only receive frames (via H264 WS demux) — no create/split/input
    if (!this.isViewer) {
      panel.connect();
    }
    return panel;
  }

  private findTabIdForPanelId(panelId: string): string | null {
    const panel = this.panelInstances.get(panelId);
    return panel ? this.findTabIdForPanel(panel) : null;
  }

  private setActivePanel(panel: PanelInstance | null): void {
    for (const p of this.panelInstances.values()) {
      p.element.classList.remove('focused');
    }
    if (panel) {
      panel.element.classList.add('focused');
      activePanelId.set(panel.id);
      this.currentActivePanel = panel;
      panel.focus();

      // Always sync tab DOM state from the panel's tab
      const tabId = this.findTabIdForPanel(panel);
      if (tabId) {
        for (const t of this.tabInstances.values()) {
          t.element.classList.remove('active');
        }
        const tab = this.tabInstances.get(tabId);
        if (tab) tab.element.classList.add('active');
        if (tabId !== get(activeTabIdStore)) {
          activeTabIdStore.set(tabId);
          this.tabHistory = this.tabHistory.filter(id => id !== tabId);
          this.tabHistory.push(tabId);
        }
        // Update browser title
        const tabInfo = tabs.get(tabId);
        document.title = tabInfo?.title || '👻';
      }

      // Notify server so it persists the active panel/tab
      if (panel.serverId !== null) {
        this.sendControlMessage(BinaryCtrlMsg.FOCUS_PANEL, MuxClient.u32Bytes(panel.serverId));
      }
    } else {
      activePanelId.set(null);
      this.currentActivePanel = null;
    }
  }

  closePanel(panelId: string): void {
    // Guard against double-fire (e.g. Svelte event delegation dispatching twice)
    if (this.closeInProgress) return;
    this.closeInProgress = true;
    setTimeout(() => { this.closeInProgress = false; }, 0);

    const panel = this.panelInstances.get(panelId);
    if (!panel) return;
    if (panel.serverId !== null) {
      const bellTimeout = this.bellTimeouts.get(panel.serverId);
      if (bellTimeout) {
        clearTimeout(bellTimeout);
        this.bellTimeouts.delete(panel.serverId);
      }
    }
    // Handle quick terminal specially - just hide it, don't close
    if (this.quickTerminalPanel === panel) {
      this.hideQuickTerminal();
      return;
    }
    if (this.previousActivePanel === panel) {
      this.previousActivePanel = null;
    }
    const tabId = this.findTabIdForPanel(panel);
    if (!tabId) return;
    const tab = this.tabInstances.get(tabId);
    if (!tab) return;
    const allPanels = tab.root.getAllPanels();
    if (allPanels.length === 1) {
      this.closeTab(tabId);
    } else {
      // Find the adjacent sibling BEFORE removing, so it becomes the new active panel
      const adjacentPanel = tab.root.findAdjacentPanel(panel) as PanelInstance | null;

      // Send close message to server (optimistic update - frontend updates immediately)
      if (panel.serverId !== null) {
        this.sendClosePanel(panel.serverId);
        this.panelsByServerId.delete(panel.serverId);
      }
      tab.root.removePanel(panel);
      this.panelInstances.delete(panelId);
      panels.remove(panelId);
      panel.destroy();

      // Activate the sibling panel (falls back to first remaining if sibling not found)
      const remainingPanels = tab.root.getAllPanels();
      const nextActive = (adjacentPanel && this.panelInstances.has(adjacentPanel.id)
        ? adjacentPanel
        : remainingPanels[0] as PanelInstance | undefined) ?? null;
      if (nextActive) {
        this.setActivePanel(nextActive);
        const panelInfo = panels.get(nextActive.id);
        if (panelInfo?.title) {
          tabs.updateTab(tabId, { title: panelInfo.title });
          document.title = panelInfo.title;
        }
      }
    }
  }

  private removePanel(panelId: string): void {
    this.closePanel(panelId);
  }


  splitPanel(panel: PanelInstance, direction: 'right' | 'down' | 'left' | 'up'): void {
    const tabId = this.findTabIdForPanel(panel);
    if (!tabId) return;
    const tab = this.tabInstances.get(tabId);
    if (!tab) return;
    const container = tab.root.findContainer(panel);
    if (!container) return;
    // Pass splitInfo so the server knows to add the new panel to the existing tab's split tree
    const splitInfo = panel.serverId !== null ? { parentPanelId: panel.serverId, direction } : undefined;
    const newPanel = this.createPanel(tab.element, null, false, splitInfo);
    container.split(direction, newPanel);
    this.setActivePanel(newPanel);
    const allPanels = tab.root.getAllPanels();
    tabs.updateTab(tabId, { panelIds: allPanels.map(p => p.id) });
  }

  selectAdjacentSplit(direction: 1 | -1): void {
    const activeTabId = get(activeTabIdStore);
    if (!activeTabId || !this.currentActivePanel) return;
    const tab = this.tabInstances.get(activeTabId);
    if (!tab) return;
    const allPanels = tab.root.getAllPanels() as PanelInstance[];
    if (allPanels.length < 2) return;
    const currentIndex = allPanels.findIndex(p => p.id === this.currentActivePanel?.id);
    if (currentIndex === -1) return;
    const nextIndex = (currentIndex + direction + allPanels.length) % allPanels.length;
    this.setActivePanel(allPanels[nextIndex]);
  }

  zoomSplit(): void {
    const activeTabId = get(activeTabIdStore);
    if (!activeTabId || !this.currentActivePanel) return;
    const tab = this.tabInstances.get(activeTabId);
    if (!tab) return;

    const container = tab.root.element;
    const isZoomed = container.classList.toggle('zoomed');

    if (isZoomed) {
      // Store which panel is zoomed
      container.dataset.zoomedPanel = this.currentActivePanel.id;

      // Hide all split-panes and dividers
      container.querySelectorAll('.split-pane').forEach((pane: Element) => {
        (pane as HTMLElement).dataset.zoomStyle = (pane as HTMLElement).style.cssText;
        (pane as HTMLElement).style.display = 'none';
      });
      container.querySelectorAll('.split-divider').forEach((d: Element) => {
        (d as HTMLElement).style.display = 'none';
      });

      // Show the active panel's container chain and make it fill
      const activeEl = this.currentActivePanel.element;
      let el: HTMLElement | null = activeEl.closest('.split-pane');
      while (el && container.contains(el)) {
        el.style.display = 'flex';
        el.style.flex = '1';
        el.style.width = '100%';
        el.style.height = '100%';
        el = el.parentElement?.closest('.split-pane') || null;
      }
    } else {
      // Restore all split-panes
      container.querySelectorAll('.split-pane').forEach((pane: Element) => {
        (pane as HTMLElement).style.cssText = (pane as HTMLElement).dataset.zoomStyle || '';
        delete (pane as HTMLElement).dataset.zoomStyle;
      });
      // Show dividers
      container.querySelectorAll('.split-divider').forEach((d: Element) => {
        (d as HTMLElement).style.display = '';
      });
      delete container.dataset.zoomedPanel;
    }

    // Trigger resize after layout updates
    requestAnimationFrame(() => {
      const allPanels = tab.root.getAllPanels();
      for (const panel of allPanels) {
        const el = panel.element;
        el.style.visibility = 'hidden';
        el.offsetHeight; // Force reflow
        el.style.visibility = '';
      }
    });
  }

  equalizeSplits(): void {
    const activeTabId = get(activeTabIdStore);
    if (!activeTabId) return;
    const tab = this.tabInstances.get(activeTabId);
    if (!tab) return;
    tab.root.equalize();
  }

  selectSplitInDirection(direction: 'up' | 'down' | 'left' | 'right'): void {
    const activeTabId = get(activeTabIdStore);
    if (!activeTabId || !this.currentActivePanel) return;
    const tab = this.tabInstances.get(activeTabId);
    if (!tab) return;
    const target = tab.root.selectSplitInDirection(direction, this.currentActivePanel.id);
    if (target) {
      const panel = this.panelInstances.get(target.id);
      if (panel) this.setActivePanel(panel);
    }
  }

  resizeSplit(direction: 'up' | 'down' | 'left' | 'right'): void {
    if (!this.currentActivePanel) return;
    const activeTabId = get(activeTabIdStore);
    if (!activeTabId) return;
    const tab = this.tabInstances.get(activeTabId);
    if (!tab) return;
    const container = tab.root.findContainer(this.currentActivePanel as PanelLike);
    if (container) {
      container.resizeSplit(direction, 50);
    }
  }

  private restoreLayoutFromServer(layout: LayoutData): void {
    console.log('[MUX] restoreLayoutFromServer: rebuilding from server layout');
    for (const tabId of Array.from(this.tabInstances.keys())) {
      this.closeTab(tabId);
    }
    for (const tabLayout of layout.tabs) {
      this.restoreTab(tabLayout);
    }
    // Active panel is per-session (client-side) — default to first panel in first tab
    if (this.tabInstances.size > 0) {
      const firstTab = this.tabInstances.values().next().value;
      if (firstTab) {
        const panels = firstTab.root.getAllPanels();
        if (panels.length > 0) this.setActivePanel(panels[0] as PanelInstance);
      }
    }
  }

  private restoreTab(tabLayout: LayoutTab): void {
    if (!this.panelsEl) return;
    const tabId = String(tabLayout.id);
    this.nextTabId = Math.max(this.nextTabId, tabLayout.id + 1);

    const tabContent = document.createElement('div');
    tabContent.className = 'tab-content';
    tabContent.dataset.tabId = tabId;
    this.panelsEl.appendChild(tabContent);

    const root = new SplitContainer(null);
    root.element.className = 'split-pane';
    root.element.style.flex = '1';
    tabContent.appendChild(root.element);

    this.buildSplitTree(tabLayout.root, root, tabContent);

    const tabInfo: InternalTabInfo = {
      id: tabId,
      title: UI.DEFAULT_TAB_TITLE,
      root,
      element: tabContent,
    };
    this.tabInstances.set(tabId, tabInfo);
    const allPanels = root.getAllPanels();
    tabs.add(createTabInfo(tabId));
    tabs.updateTab(tabId, { panelIds: allPanels.map(p => p.id) });
  }

  /**
   * Recursively build the split tree from layout data.
   * Directly constructs the tree structure instead of using split() method.
   */
  private buildSplitTree(node: LayoutNode, container: SplitContainer, tabElement: HTMLElement): void {
    if (node.type === 'leaf' && node.panelId !== undefined) {
      // Leaf node - create a panel
      const panel = this.createPanel(container.element, node.panelId);
      container.panel = panel;
    } else if (node.type === 'split' && node.first && node.second) {
      // Split node - directly construct the tree structure
      const direction = node.direction === 'horizontal' ? 'horizontal' : 'vertical';

      // Create child containers
      const firstContainer = new SplitContainer(container);
      firstContainer.element.className = 'split-pane';
      firstContainer.element.style.flex = '1';

      const secondContainer = new SplitContainer(container);
      secondContainer.element.className = 'split-pane';
      secondContainer.element.style.flex = '1';

      // Set up the split structure
      container.panel = null;
      (container as unknown as { direction: string }).direction = direction;
      (container as unknown as { first: SplitContainer }).first = firstContainer;
      (container as unknown as { second: SplitContainer }).second = secondContainer;
      (container as unknown as { ratio: number }).ratio = node.ratio ?? 0.5;

      // Rebuild DOM for the container
      this.rebuildContainerDOM(container);

      // Recursively build children
      this.buildSplitTree(node.first, firstContainer, tabElement);
      this.buildSplitTree(node.second, secondContainer, tabElement);
    }
  }

  /**
   * Rebuild the DOM for a split container (similar to SplitContainer.rebuildDOM)
   */
  private rebuildContainerDOM(container: SplitContainer): void {
    const parent = container.element.parentElement;
    const oldElement = container.element;
    const direction = (container as unknown as { direction: string }).direction;
    const first = (container as unknown as { first: SplitContainer }).first;
    const second = (container as unknown as { second: SplitContainer }).second;
    const ratio = (container as unknown as { ratio: number }).ratio;

    // Create new container element
    const newElement = document.createElement('div');
    newElement.className = `split-container ${direction}`;
    if (oldElement.style.flex) {
      newElement.style.flex = oldElement.style.flex;
    }

    // Add children and divider
    newElement.appendChild(first.element);

    const divider = document.createElement('div');
    divider.className = 'split-divider';
    (container as unknown as { divider: HTMLElement }).divider = divider;
    newElement.appendChild(divider);

    newElement.appendChild(second.element);

    // Replace in DOM
    if (parent) {
      parent.replaceChild(newElement, oldElement);
    }
    (container as unknown as { element: HTMLElement }).element = newElement;

    // Apply ratio
    const firstPercent = (ratio * 100).toFixed(2);
    const secondPercent = ((1 - ratio) * 100).toFixed(2);
    first.element.style.flex = `0 0 calc(${firstPercent}% - 2px)`;
    second.element.style.flex = `0 0 calc(${secondPercent}% - 2px)`;

    // Set up divider drag (call the container's method)
    if (typeof (container as unknown as { setupDividerDrag: () => void }).setupDividerDrag === 'function') {
      (container as unknown as { setupDividerDrag: () => void }).setupDividerDrag();
    }
  }

  private enterMainMode(): void {
    if (!this.isViewer) return;
    this.isViewer = false;
    console.log('Entering main mode');
    // Resume all panels (they receive frames via shared H264 WS)
    for (const panel of this.panelInstances.values()) {
      panel.show();
    }
  }

  private enterViewerMode(): void {
    if (this.isViewer) return;
    this.isViewer = true;
    console.log('Entering viewer mode');
    // Pause all panels — viewers receive frames but don't send input
    for (const panel of this.panelInstances.values()) {
      panel.hide();
    }
  }

  private h264OverrideHandler: ((panelId: number, data: Uint8Array) => void) | null = null;

  /** Connect the shared H264 WebSocket for receiving video frames */
  private connectH264(): void {
    if (this.destroyed) return;
    if (this.h264Ws && this.h264Ws.readyState !== WebSocket.CLOSED) return;
    const url = getWsUrl(WS_PATHS.H264);
    this.h264Ws = new WebSocket(url);
    this.h264Ws.binaryType = 'arraybuffer';
    this.h264Ws.onmessage = (e: MessageEvent) => {
      if (e.data instanceof ArrayBuffer && e.data.byteLength > 4) {
        const view = new DataView(e.data);
        const panelId = view.getUint32(0, true);
        const frameData = new Uint8Array(e.data, 4);
        // Route to override handler (overview) if set
        if (this.h264OverrideHandler) {
          this.h264OverrideHandler(panelId, frameData);
        }
        // Route to panel by server ID, cache if not ready yet
        const panel = this.panelsByServerId.get(panelId);
        if (panel) {
          panel.decodePreviewFrame(frameData);
        } else {
          let pending = this.h264PendingFrames.get(panelId);
          if (!pending) {
            pending = [];
            this.h264PendingFrames.set(panelId, pending);
          }
          pending.push(frameData);
        }
      }
    };
    this.h264Ws.onclose = () => {
      this.h264Ws = null;
      if (!this.destroyed) {
        setTimeout(() => this.connectH264(), TIMING.WS_RECONNECT_DELAY);
      }
    };
  }

  /** Set an override handler for H264 frames (used by overview) */
  setH264OverrideHandler(handler: ((panelId: number, data: Uint8Array) => void) | null): void {
    this.h264OverrideHandler = handler;
  }

  isViewerMode(): boolean {
    return this.isViewer;
  }

  sendControlMessage(type: number, data: Uint8Array): void {
    const message = new Uint8Array(1 + data.length);
    message[0] = type;
    message.set(data, 1);
    this.sendControlBinary(message);
  }

  /** Send binary data via the control WS bus */
  sendControlDirect(data: Uint8Array): void {
    this.sendControlBinary(data);
  }

  /** Build a [type:u8][serverId:u32][payload...] envelope from an input message */
  private static buildEnvelope(type: number, serverId: number, msg: ArrayBuffer | ArrayBufferView): Uint8Array {
    const inputBytes = msg instanceof ArrayBuffer
      ? new Uint8Array(msg)
      : new Uint8Array(msg.buffer, msg.byteOffset, msg.byteLength);
    const envelope = new Uint8Array(1 + 4 + inputBytes.length);
    envelope[0] = type;
    new DataView(envelope.buffer).setUint32(1, serverId, true);
    envelope.set(inputBytes, 5);
    return envelope;
  }

  /** Wrap a panel message in PANEL_MSG envelope and send via control WS */
  private sendPanelMsg(serverId: number, msg: ArrayBuffer | ArrayBufferView): void {
    this.sendControlBinary(MuxClient.buildEnvelope(BinaryCtrlMsg.PANEL_MSG, serverId, msg));
  }

  /** Wrap a panel message in PANEL_MSG envelope and send immediately (no rAF). */
  private sendPanelMsgImmediate(serverId: number, msg: ArrayBuffer | ArrayBufferView): void {
    this.sendControlImmediate(MuxClient.buildEnvelope(BinaryCtrlMsg.PANEL_MSG, serverId, msg));
  }

  private sendClosePanel(serverId: number): void {
    this.sendControlMessage(BinaryCtrlMsg.CLOSE_PANEL, MuxClient.u32Bytes(serverId));
  }

  sendClipboard(text: string): void {
    const panel = this.currentActivePanel;
    if (!panel || panel.serverId === null) return;
    const textBytes = sharedTextEncoder.encode(text);
    const data = new Uint8Array(4 + 4 + textBytes.length);
    const view = new DataView(data.buffer);
    view.setUint32(0, panel.serverId, true);
    view.setUint32(4, textBytes.length, true);
    data.set(textBytes, 8);
    this.sendControlMessage(BinaryCtrlMsg.SET_CLIPBOARD, data);
  }

  sendViewAction(action: string): void {
    const panel = this.currentActivePanel;
    if (!panel || panel.serverId === null) return;
    const actionBytes = sharedTextEncoder.encode(action);
    const data = new Uint8Array(4 + 1 + actionBytes.length);
    const view = new DataView(data.buffer);
    view.setUint32(0, panel.serverId, true);
    data[4] = actionBytes.length;
    data.set(actionBytes, 5);
    this.sendControlMessage(BinaryCtrlMsg.VIEW_ACTION, data);
  }

  saveConfig(content: string): void {
    const contentBytes = sharedTextEncoder.encode(content);
    const data = new Uint8Array(4 + contentBytes.length);
    const view = new DataView(data.buffer);
    view.setUint32(0, contentBytes.length, true);
    data.set(contentBytes, 4);
    this.sendControlMessage(BinaryCtrlMsg.SAVE_CONFIG, data);
  }

  // --- Multiplayer: Pane Assignment ---

  /** Admin assigns a panel to a session */
  assignPanel(serverId: number, sessionId: string): void {
    const sidBytes = sharedTextEncoder.encode(sessionId);
    const data = new Uint8Array(4 + 1 + sidBytes.length);
    const view = new DataView(data.buffer);
    view.setUint32(0, serverId, true);
    data[4] = sidBytes.length;
    data.set(sidBytes, 5);
    this.sendControlMessage(BinaryCtrlMsg.ASSIGN_PANEL, data);
  }

  /** Admin unassigns a panel */
  unassignPanel(serverId: number): void {
    this.sendControlMessage(BinaryCtrlMsg.UNASSIGN_PANEL, MuxClient.u32Bytes(serverId));
  }

  /** Request session list from server (admin only) */
  requestSessionList(): void {
    this.sendControlMessage(BinaryCtrlMsg.GET_SESSION_LIST, new Uint8Array(0));
  }

  /** Create a new session (admin only) */
  createSession(id: string, name: string, role: number = 1): void {
    const idBytes = sharedTextEncoder.encode(id);
    const nameBytes = sharedTextEncoder.encode(name);
    const data = new Uint8Array(2 + 2 + 1 + idBytes.length + nameBytes.length);
    const view = new DataView(data.buffer);
    view.setUint16(0, idBytes.length, true);
    view.setUint16(2, nameBytes.length, true);
    data[4] = role;
    data.set(idBytes, 5);
    data.set(nameBytes, 5 + idBytes.length);
    this.sendControlMessage(BinaryCtrlMsg.CREATE_SESSION, data);
  }

  /** Delete a session (admin only) */
  deleteSession(id: string): void {
    const idBytes = sharedTextEncoder.encode(id);
    const data = new Uint8Array(2 + idBytes.length);
    const view = new DataView(data.buffer);
    view.setUint16(0, idBytes.length, true);
    data.set(idBytes, 2);
    this.sendControlMessage(BinaryCtrlMsg.DELETE_SESSION, data);
  }

  /** Regenerate a session's permanent token (admin only) */
  regenerateToken(sessionId: string): void {
    const idBytes = sharedTextEncoder.encode(sessionId);
    const data = new Uint8Array(2 + idBytes.length);
    const view = new DataView(data.buffer);
    view.setUint16(0, idBytes.length, true);
    data.set(idBytes, 2);
    this.sendControlMessage(BinaryCtrlMsg.REGEN_TOKEN, data);
  }

  /** Request OAuth config from server (admin only) */
  requestOAuthConfig(): void {
    this.sendControlMessage(BinaryCtrlMsg.GET_OAUTH_CONFIG, new Uint8Array(0));
  }

  /** Set OAuth provider config (admin only) */
  setOAuthConfig(provider: string, clientId: string, clientSecret: string): void {
    const provBytes = sharedTextEncoder.encode(provider);
    const idBytes = sharedTextEncoder.encode(clientId);
    const secretBytes = sharedTextEncoder.encode(clientSecret);
    const data = new Uint8Array(1 + provBytes.length + 2 + idBytes.length + 2 + secretBytes.length);
    const view = new DataView(data.buffer);
    let off = 0;
    data[off] = provBytes.length; off += 1;
    data.set(provBytes, off); off += provBytes.length;
    view.setUint16(off, idBytes.length, true); off += 2;
    data.set(idBytes, off); off += idBytes.length;
    view.setUint16(off, secretBytes.length, true); off += 2;
    data.set(secretBytes, off);
    this.sendControlMessage(BinaryCtrlMsg.SET_OAUTH_CONFIG, data);
  }

  /** Remove OAuth provider config (admin only) */
  removeOAuthConfig(provider: string): void {
    const provBytes = sharedTextEncoder.encode(provider);
    const data = new Uint8Array(1 + provBytes.length);
    data[0] = provBytes.length;
    data.set(provBytes, 1);
    this.sendControlMessage(BinaryCtrlMsg.REMOVE_OAUTH_CONFIG, data);
  }

  /** Send input to assigned panel via control WS (coworker mode) */
  private sendPanelInputViaControl(serverId: number, inputMsg: ArrayBuffer | ArrayBufferView): void {
    this.sendControlBinary(MuxClient.buildEnvelope(BinaryCtrlMsg.PANEL_INPUT, serverId, inputMsg));
  }

  /** Send input immediately to assigned panel via control WS (coworker mode) */
  private sendPanelInputViaControlImmediate(serverId: number, inputMsg: ArrayBuffer | ArrayBufferView): void {
    this.sendControlImmediate(MuxClient.buildEnvelope(BinaryCtrlMsg.PANEL_INPUT, serverId, inputMsg));
  }

  /** Wire up coworker input for a panel */
  private setupCoworkerInput(panel: PanelInstance, serverId: number): void {
    panel.setControlWsSend(
      (msg) => this.sendPanelInputViaControl(serverId, msg),
      (msg) => this.sendPanelInputViaControlImmediate(serverId, msg),
    );
  }

  /** Remove coworker input from a panel */
  private clearCoworkerInput(panel: PanelInstance): void {
    panel.setControlWsSend(null, null);
  }

  /** Called when PANEL_ASSIGNMENT is received — wire/unwire coworker input */
  private updateCoworkerInput(panelId: number, sessionId: string): void {
    const panel = this.panelsByServerId.get(panelId);
    if (!panel) return;

    const currentAuth = get(authState);
    // Admin uses PANEL_MSG envelope — coworker overrides don't apply
    if (currentAuth.role === Role.ADMIN) return;

    const uiState = get(ui);
    if (sessionId && sessionId === uiState.sessionId && currentAuth.role === Role.EDITOR) {
      this.setupCoworkerInput(panel, panelId);
    } else {
      this.clearCoworkerInput(panel);
    }
  }

  getActivePanel(): PanelInstance | null {
    return this.currentActivePanel;
  }

  /** Get all panel server IDs in the active tab */
  getActiveTabPanelServerIds(): number[] {
    const activeId = get(activeTabIdStore);
    if (!activeId) return [];
    const tab = this.tabInstances.get(activeId);
    if (!tab) return [];
    return tab.root.getAllPanels()
      .map(p => (p as PanelInstance).serverId)
      .filter((id): id is number => id != null);
  }

  getTabElements(): Map<string, HTMLElement> {
    const result = new Map<string, HTMLElement>();
    for (const [tabId, tabInfo] of this.tabInstances) {
      result.set(tabId, tabInfo.element);
    }
    return result;
  }

  getTabSnapshots(): Map<string, string> {
    const result = new Map<string, string>();
    const activeId = get(activeTabIdStore);

    // Temporarily show hidden tabs so getBoundingClientRect returns valid positions
    const hiddenTabs: InternalTabInfo[] = [];
    for (const [tabId, tab] of this.tabInstances) {
      if (tabId !== activeId) {
        tab.element.style.visibility = 'hidden';
        tab.element.style.display = 'flex';
        hiddenTabs.push(tab);
      }
    }

    // Force layout reflow so positions are computed
    if (hiddenTabs.length > 0) {
      document.body.offsetHeight;
    }

    for (const [tabId, tab] of this.tabInstances) {
      const tabRect = tab.element.getBoundingClientRect();
      if (tabRect.width === 0 || tabRect.height === 0) continue;

      const allPanels = tab.root.getAllPanels() as PanelInstance[];
      const composite = document.createElement('canvas');
      composite.width = Math.round(tabRect.width);
      composite.height = Math.round(tabRect.height);
      const ctx = composite.getContext('2d');
      if (!ctx) continue;

      ctx.fillStyle = '#000';
      ctx.fillRect(0, 0, composite.width, composite.height);

      for (const panel of allPanels) {
        // Use snapshot canvas (persists content across hide/show, works with WebGPU)
        const src = panel.getSnapshotCanvas();
        if (!src || src.width === 0 || src.height === 0) continue;
        // Use main canvas element for layout position
        const mainCanvas = panel.canvas;
        if (!mainCanvas) continue;
        const panelRect = mainCanvas.getBoundingClientRect();
        const x = panelRect.left - tabRect.left;
        const y = panelRect.top - tabRect.top;
        try {
          ctx.drawImage(src, x, y, panelRect.width, panelRect.height);
        } catch {
          // Ignore draw errors
        }
      }

      try {
        result.set(tabId, composite.toDataURL('image/png'));
      } catch {
        // Ignore toDataURL errors
      }
    }

    // Restore hidden tabs
    for (const tab of hiddenTabs) {
      tab.element.style.display = '';
      tab.element.style.visibility = '';
    }

    return result;
  }

  getTabPanelServerIds(): Map<string, number[]> {
    const result = new Map<string, number[]>();
    for (const [tabId, tab] of this.tabInstances) {
      const allPanels = tab.root.getAllPanels() as PanelInstance[];
      const serverIds: number[] = [];
      for (const panel of allPanels) {
        if (panel.serverId != null) {
          serverIds.push(panel.serverId);
        }
      }
      result.set(tabId, serverIds);
    }
    return result;
  }

  getPanelsEl(): HTMLElement | null {
    return this.panelsEl;
  }

  pauseAllPanels(): void {
    for (const panel of this.panelInstances.values()) {
      panel.hide();
    }
  }

  resumeAllPanels(): void {
    for (const panel of this.panelInstances.values()) {
      panel.show();
    }
  }

  setOverviewOpen(open: boolean): void {
    const data = new Uint8Array([open ? 1 : 0]);
    this.sendControlMessage(BinaryCtrlMsg.SET_OVERVIEW, data);
  }

  toggleQuickTerminal(container: HTMLElement): void {
    ui.update(s => {
      if (s.quickTerminalOpen) {
        if (this.previousActivePanel && this.panelInstances.has(this.previousActivePanel.id)) {
          this.setActivePanel(this.previousActivePanel);
        } else {
          const firstPanel = this.panelInstances.values().next().value;
          if (firstPanel && firstPanel !== this.quickTerminalPanel) {
            this.setActivePanel(firstPanel);
          }
        }
        this.previousActivePanel = null;
        return { ...s, quickTerminalOpen: false };
      } else {
        this.previousActivePanel = this.currentActivePanel;
        if (!this.quickTerminalPanel) {
          this.quickTerminalPanel = this.createPanel(container, null, true);
        }
        this.setActivePanel(this.quickTerminalPanel);
        return { ...s, quickTerminalOpen: true, quickTerminalPanelId: this.quickTerminalPanel.id };
      }
    });
  }

  getQuickTerminalPanel(): PanelInstance | null {
    return this.quickTerminalPanel;
  }

  hideQuickTerminal(): void {
    if (!this.quickTerminalPanel) return;
    // Just hide the quick terminal UI, keep the panel running on server
    if (this.previousActivePanel && this.panelInstances.has(this.previousActivePanel.id)) {
      this.setActivePanel(this.previousActivePanel);
    } else {
      const firstPanel = this.panelInstances.values().next().value;
      if (firstPanel && firstPanel !== this.quickTerminalPanel) {
        this.setActivePanel(firstPanel);
      }
    }
    this.previousActivePanel = null;
    // Update UI state to hide quick terminal
    ui.update(s => ({ ...s, quickTerminalOpen: false }));
  }

  toggleInspector(): void {
    if (this.currentActivePanel) {
      this.currentActivePanel.toggleInspector();
      const isOpen = this.currentActivePanel.isInspectorOpen();
      const data = new Uint8Array([isOpen ? 1 : 0]);
      this.sendControlMessage(BinaryCtrlMsg.SET_INSPECTOR, data);
    }
  }

  showUploadDialog(): void {
    this.onUploadRequest?.();
  }

  showDownloadDialog(): void {
    this.onDownloadRequest?.();
  }

  handleFileDrop(panel: PanelInstance, files: File[], dirHandle?: FileSystemDirectoryHandle): void {
    if (files.length === 0 && !dirHandle) return;
    this.onFileDropRequest?.(panel, files, dirHandle);
  }

  /** Get the pwd of the active panel (for dialog default paths). */
  getActivePanelPwd(): string {
    const panel = this.currentActivePanel;
    const panelInfo = panel ? panels.get(panel.id) : undefined;
    return panelInfo?.pwd || panel?.getPwd() || '~';
  }

  async showStorageDialog(): Promise<void> {
    let usage: { totalBytes: number; fileCount: number };
    try {
      usage = await this.fileTransfer.getCacheUsage();
    } catch {
      usage = { totalBytes: 0, fileCount: 0 };
    }

    const formatBytes = (bytes: number): string => {
      if (bytes === 0) return '0 B';
      const units = ['B', 'KB', 'MB', 'GB'];
      const i = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1);
      const val = bytes / Math.pow(1024, i);
      return `${val.toFixed(i === 0 ? 0 : 1)} ${units[i]}`;
    };

    if (usage.fileCount === 0) {
      window.alert('File cache is empty.');
      return;
    }

    const confirmed = window.confirm(
      `File cache: ${formatBytes(usage.totalBytes)} (${usage.fileCount} files)\n\n` +
      'Clear all cached files?\n' +
      'This will remove locally cached copies used for delta sync.\n' +
      'Next sync will re-download full files.',
    );

    if (confirmed) {
      try {
        await this.fileTransfer.clearCache();
        console.log('File cache cleared');
      } catch (err) {
        console.error('Failed to clear cache:', err);
      }
    }
  }

}

let muxClient: MuxClient | null = null;

export function getMuxClient(): MuxClient {
  if (!muxClient) {
    muxClient = new MuxClient();
  }
  return muxClient;
}

export async function initMuxClient(panelsEl: HTMLElement): Promise<MuxClient> {
  const client = getMuxClient();
  await client.init(panelsEl);
  return client;
}
