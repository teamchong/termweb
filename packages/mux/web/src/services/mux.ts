/**
 * Mux Client Service
 * Centralized WebSocket and state management using Svelte stores
 */
import { writable, get } from 'svelte/store';
import { mount, unmount } from 'svelte';
import { tabs, activeTabId as activeTabIdStore, panels, activePanelId, ui, createPanelInfo, createTabInfo } from '../stores/index';
import PanelComponent from '../components/Panel.svelte';
import { SplitContainer, type PanelLike } from '../split-container';
import { FileTransferHandler } from '../file-transfer';
import type { AppConfig, LayoutData, LayoutNode, LayoutTab } from '../types';
import type { PanelStatus } from '../stores/types';
import { applyColors, generateId, getWsUrl, sharedTextEncoder, sharedTextDecoder } from '../utils';
import { TIMING, WS_PATHS, CONFIG_ENDPOINT, SERVER_MSG, UI } from '../constants';
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
  setControlWsSend: (fn: ((msg: ArrayBuffer | ArrayBufferView) => void) | null) => void;
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
}>({
  role: 0,
  authRequired: false,
  hasPassword: false,
  passkeyCount: 0,
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

  constructor() {
    this.fileTransfer = new FileTransferHandler();
    this.fileTransfer.onTransferComplete = (transferId, totalBytes) => {
      console.log(`Transfer ${transferId} completed: ${totalBytes} bytes`);
    };
    this.fileTransfer.onTransferError = (transferId, error) => {
      console.error(`Transfer ${transferId} failed: ${error}`);
    };
    this.fileTransfer.onDryRunReport = (transferId, report) => {
      console.log(`Transfer ${transferId} dry run: ${report.newCount} new, ${report.updateCount} update, ${report.deleteCount} delete`);
    };
  }

  private static checkWebCodecsSupport(): boolean {
    return typeof VideoDecoder !== 'undefined' && typeof VideoDecoder.isConfigSupported === 'function';
  }

  private isControlWsOpen(): boolean {
    return this.controlWs !== null && this.controlWs.readyState === WebSocket.OPEN;
  }

  // --- Outgoing message batching (60fps bus) ---
  private controlOutQueue: Uint8Array[] = [];
  private controlFlushScheduled = false;

  /** Queue binary data for the next batch flush (once per rAF) */
  private sendControlBinary(data: Uint8Array): void {
    if (!this.isControlWsOpen()) return;
    this.controlOutQueue.push(data);
    if (!this.controlFlushScheduled) {
      this.controlFlushScheduled = true;
      requestAnimationFrame(() => this.flushControlBatch());
    }
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

  /** Compress and send a single zstd-framed message on the control WS */
  private sendRawCompressed(data: Uint8Array): void {
    try {
      const compressed = compressZstd(data);
      if (compressed.length + 1 < data.length + 1) {
        const frame = new Uint8Array(1 + compressed.length);
        frame[0] = 0x01;
        frame.set(compressed, 1);
        this.controlWs!.send(frame);
        return;
      }
    } catch { /* compression didn't shrink — send with uncompressed flag */ }
    const frame = new Uint8Array(1 + data.length);
    frame[0] = 0x00;
    frame.set(data, 1);
    this.controlWs!.send(frame);
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

    const config = await this.fetchConfig();
    if (config.colors) {
      applyColors(config.colors);
    }

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

  private async fetchConfig(): Promise<AppConfig> {
    try {
      const response = await fetch(CONFIG_ENDPOINT);
      if (!response.ok) return {};
      return await response.json();
    } catch {
      return {};
    }
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
      // Wire file transfer to send via control WS (bypasses batch queue for large payloads)
      this.fileTransfer.setSend((data) => this.sendControlDirect(data));
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
          });
          // Update UI isAdmin flag
          const isAdmin = role === Role.ADMIN;
          ui.update(s => ({ ...s, isAdmin }));
          // Auto-switch mode based on role
          if (isAdmin) {
            this.enterMainMode();
          } else if (role === Role.EDITOR || role === Role.VIEWER) {
            this.enterViewerMode();
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
          const currentAuth = get(authState);
          if (currentAuth.role === Role.ADMIN) {
            this.enterMainMode();
          } else if (currentAuth.role === Role.EDITOR || currentAuth.role === Role.VIEWER) {
            this.enterViewerMode();
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
          // [0x14][panel_id:u32][x:u16][y:u16][w:u16][h:u16][style:u8][visible:u8] = 15 bytes
          if (data.byteLength < 15) break;
          const panelId = view.getUint32(1, true);
          const x = view.getUint16(5, true);
          const y = view.getUint16(7, true);
          const w = view.getUint16(9, true);
          const h = view.getUint16(11, true);
          const style = view.getUint8(13);   // 0=bar, 1=block, 2=underline, 3=block_hollow
          const visible = view.getUint8(14) === 1;
          // Use cached surface dims from SURFACE_DIMS message
          const dims = this.surfaceDims.get(panelId);
          const totalW = dims?.w ?? 0;
          const totalH = dims?.h ?? 0;
          const panel = this.panelsByServerId.get(panelId);
          if (panel) {
            panel.updateCursorState(x, y, w, h, style, visible, totalW, totalH);
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
        default:
          // Route file transfer responses (0x30-0x36) to FileTransferHandler
          if (msgType >= 0x30 && msgType <= 0x36) {
            this.fileTransfer.handleServerMessage(data);
          }
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
    // Reconcile client tree with server's authoritative layout
    for (const tabLayout of layout.tabs) {
      const tabId = String(tabLayout.id);
      const tab = this.tabInstances.get(tabId);
      if (tab) {
        const mismatches = this.reconcileTree(tab.root, tabLayout.root);
        if (mismatches > 0) {
          console.log(`[MUX] Reconciled ${mismatches} direction/ratio mismatches from server layout`);
        }
      }
    }
  }

  /**
   * Walk client and server trees in parallel, fixing direction/ratio mismatches.
   * Returns the number of fixes applied.
   */
  private reconcileTree(container: SplitContainer, node: LayoutNode): number {
    let fixes = 0;

    if (node.type === 'split' && container.direction !== null && node.first && node.second) {
      // Both are splits - check direction
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
      if (container.first) fixes += this.reconcileTree(container.first, node.first);
      if (container.second) fixes += this.reconcileTree(container.second, node.second);
    }
    return fixes;
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
      setControlWsSend: (fn: ((msg: ArrayBuffer | ArrayBufferView) => void) | null) => void;
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
      setControlWsSend: (fn) => comp.setControlWsSend(fn),
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
    panel.setControlWsSend((msg) => {
      const sid = panel.serverId ?? 0;
      this.sendPanelMsg(sid, msg);
    });

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

      // Derive active tab from the panel's tab
      const tabId = this.findTabIdForPanel(panel);
      if (tabId && tabId !== get(activeTabIdStore)) {
        for (const t of this.tabInstances.values()) {
          t.element.classList.remove('active');
        }
        const tab = this.tabInstances.get(tabId);
        if (tab) tab.element.classList.add('active');
        activeTabIdStore.set(tabId);
        this.tabHistory = this.tabHistory.filter(id => id !== tabId);
        this.tabHistory.push(tabId);
        // Update browser title to match the new active tab
        const tabInfo = tabs.get(tabId);
        document.title = tabInfo?.title || '👻';
      }

      // Notify server so it persists the active panel/tab
      if (panel.serverId !== null) {
        const data = new Uint8Array(4);
        new DataView(data.buffer).setUint32(0, panel.serverId, true);
        this.sendControlMessage(BinaryCtrlMsg.FOCUS_PANEL, data);
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
    // Restore active panel (active tab is derived from it)
    const activePanel = layout.activePanelId !== undefined
      ? this.panelsByServerId.get(layout.activePanelId) as PanelInstance | undefined
      : undefined;
    if (activePanel) {
      this.setActivePanel(activePanel);
    } else if (this.tabInstances.size > 0) {
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

  /** Wrap a panel message in PANEL_MSG envelope and send via control WS */
  private sendPanelMsg(serverId: number, msg: ArrayBuffer | ArrayBufferView): void {
    const inputBytes = msg instanceof ArrayBuffer
      ? new Uint8Array(msg)
      : new Uint8Array(msg.buffer, msg.byteOffset, msg.byteLength);
    const envelope = new Uint8Array(1 + 4 + inputBytes.length);
    envelope[0] = BinaryCtrlMsg.PANEL_MSG;
    new DataView(envelope.buffer).setUint32(1, serverId, true);
    envelope.set(inputBytes, 5);
    this.sendControlBinary(envelope);
  }

  private sendClosePanel(serverId: number): void {
    const data = new Uint8Array(4);
    const view = new DataView(data.buffer);
    view.setUint32(0, serverId, true);
    this.sendControlMessage(BinaryCtrlMsg.CLOSE_PANEL, data);
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
    const data = new Uint8Array(4);
    const view = new DataView(data.buffer);
    view.setUint32(0, serverId, true);
    this.sendControlMessage(BinaryCtrlMsg.UNASSIGN_PANEL, data);
  }

  /** Send input to assigned panel via control WS (coworker mode) */
  private sendPanelInputViaControl(serverId: number, inputMsg: ArrayBuffer | ArrayBufferView): void {
    const inputBytes = inputMsg instanceof ArrayBuffer
      ? new Uint8Array(inputMsg)
      : new Uint8Array(inputMsg.buffer, inputMsg.byteOffset, inputMsg.byteLength);
    const msg = new Uint8Array(1 + 4 + inputBytes.length);
    msg[0] = BinaryCtrlMsg.PANEL_INPUT;
    const view = new DataView(msg.buffer);
    view.setUint32(1, serverId, true);
    msg.set(inputBytes, 5);
    this.sendControlBinary(msg);
  }

  /** Wire up coworker input for a panel */
  private setupCoworkerInput(panel: PanelInstance, serverId: number): void {
    panel.setControlWsSend((msg) => {
      this.sendPanelInputViaControl(serverId, msg);
    });
  }

  /** Remove coworker input from a panel */
  private clearCoworkerInput(panel: PanelInstance): void {
    panel.setControlWsSend(null);
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

  async showUploadDialog(): Promise<void> {
    if (!('showDirectoryPicker' in window)) return;
    try {
      const dirHandle = await window.showDirectoryPicker({ mode: 'read' });
      const panel = this.currentActivePanel;
      const panelInfo = panel ? panels.get(panel.id) : undefined;
      const defaultPath = panelInfo?.pwd || '~';
      const serverPath = window.prompt('Upload to server path:', defaultPath);
      if (!serverPath) return;
      await this.fileTransfer.startFolderUpload(dirHandle, serverPath);
    } catch (err: unknown) {
      if (err instanceof Error && err.name !== 'AbortError') {
        console.error('Upload failed:', err);
      }
    }
  }

  async showDownloadDialog(): Promise<void> {
    const panel = this.currentActivePanel;
    const panelInfo = panel ? panels.get(panel.id) : undefined;
    const defaultPath = panelInfo?.pwd || '~';
    const serverPath = window.prompt('Download from server path:', defaultPath);
    if (!serverPath) return;
    try {
      await this.fileTransfer.startFolderDownload(serverPath);
    } catch (err: unknown) {
      console.error('Download failed:', err);
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
