/**
 * termweb-mux browser client
 * Connects to server, receives frames, renders to canvas, sends input
 */

import { ClientMsg, FrameType, KEY_MAP, TransferMsgType } from './protocol';
import type { AppConfig, PanelInstance, TabInfo, TransferState, AuthState } from './types';
import { formatBytes, generateId, applyColors, parseQueryParams } from './utils';

// Re-export for external use
export * from './protocol';
export * from './types';
export * from './utils';

// WebSocket ports (fetched from /config endpoint)
let PANEL_PORT = 0;
let CONTROL_PORT = 0;
let FILE_PORT = 0;

// ============================================================================
// Panel - one terminal panel with its own WebSocket
// ============================================================================

class Panel implements PanelInstance {
  id: string;
  serverId: number | null;
  container: HTMLElement;
  canvas: HTMLCanvasElement;
  ws: WebSocket | null = null;
  width = 0;
  height = 0;
  pwd: string | null = null;

  private element: HTMLDivElement;
  private sequence = 0;
  private lastReportedWidth = 0;
  private lastReportedHeight = 0;
  private resizeTimeout: ReturnType<typeof setTimeout> | null = null;
  private onResize?: (width: number, height: number) => void;
  private onViewAction?: (action: string, data?: unknown) => void;

  // WebGPU state
  private device: GPUDevice | null = null;
  private context: GPUCanvasContext | null = null;
  private pipeline: GPURenderPipeline | null = null;
  private xorPipeline: GPUComputePipeline | null = null;
  private rgbToRgbaPipeline: GPUComputePipeline | null = null;
  private prevBuffer: GPUBuffer | null = null;
  private diffBuffer: GPUBuffer | null = null;
  private texture: GPUTexture | null = null;
  private sampler: GPUSampler | null = null;

  // Inspector state
  private inspectorVisible = false;
  private inspectorHeight = 200;
  private inspectorActiveTab = 'screen';
  private inspectorState: unknown = null;
  private inspectorEl!: HTMLDivElement;

  constructor(
    id: string,
    container: HTMLElement,
    serverId: number | null = null,
    onResize?: (width: number, height: number) => void,
    onViewAction?: (action: string, data?: unknown) => void
  ) {
    this.id = id;
    this.serverId = serverId;
    this.container = container;
    this.onResize = onResize;
    this.onViewAction = onViewAction;

    this.canvas = document.createElement('canvas');
    this.element = document.createElement('div');
    this.element.className = 'panel';
    this.element.appendChild(this.canvas);
    this.createInspectorElement();
    container.appendChild(this.element);

    this.setupInputHandlers();
    this.initGPU();
    this.setupResizeObserver();
  }

  private createInspectorElement(): void {
    this.inspectorEl = document.createElement('div');
    this.inspectorEl.className = 'panel-inspector';
    this.inspectorEl.innerHTML = `
      <div class="inspector-resize"></div>
      <div class="inspector-content">
        <div class="inspector-left">
          <div class="inspector-left-header">
            <div class="inspector-tabs">
              <button class="inspector-tab active" data-tab="screen">Screen</button>
            </div>
          </div>
          <div class="inspector-main"></div>
        </div>
        <div class="inspector-right">
          <div class="inspector-right-header">
            <span class="inspector-right-title">Surface Info</span>
          </div>
          <div class="inspector-sidebar"></div>
        </div>
      </div>
    `;
    this.element.appendChild(this.inspectorEl);
  }

  connect(host: string, port: number): void {
    if (this.ws) {
      this.ws.close();
    }

    const wsUrl = `ws://${host}:${port}`;
    this.ws = new WebSocket(wsUrl);
    this.ws.binaryType = 'arraybuffer';

    this.ws.onopen = () => {
      console.log(`Panel ${this.id} connected`);
      if (this.serverId !== null) {
        this.sendConnectPanel(this.serverId);
      } else {
        this.sendCreatePanel();
      }
    };

    this.ws.onmessage = (event) => {
      if (event.data instanceof ArrayBuffer) {
        this.handleFrame(event.data);
      }
    };

    this.ws.onclose = () => {
      console.log(`Panel ${this.id} disconnected`);
    };

    this.ws.onerror = (error) => {
      console.error(`Panel ${this.id} error:`, error);
    };
  }

  disconnect(): void {
    if (this.ws) {
      this.ws.close();
      this.ws = null;
    }
  }

  private sendConnectPanel(panelId: number): void {
    const msg = new ArrayBuffer(5);
    const view = new DataView(msg);
    view.setUint8(0, ClientMsg.CONNECT_PANEL);
    view.setUint32(1, panelId, true);
    this.ws?.send(msg);
  }

  private sendCreatePanel(): void {
    const msg = new ArrayBuffer(1);
    const view = new DataView(msg);
    view.setUint8(0, ClientMsg.CREATE_PANEL);
    this.ws?.send(msg);
  }

  private handleFrame(data: ArrayBuffer): void {
    const view = new DataView(data);
    const frameType = view.getUint8(0);

    if (frameType === 0xFF) {
      // Panel ID assignment
      this.serverId = view.getUint32(1, true);
      console.log(`Panel ${this.id} assigned server ID: ${this.serverId}`);
      this.resize();
      return;
    }

    // Handle keyframe/delta frames
    if (frameType === FrameType.KEYFRAME || frameType === FrameType.DELTA) {
      this.renderFrame(data);
    }
  }

  private async renderFrame(data: ArrayBuffer): Promise<void> {
    // WebGPU rendering - simplified for now
    // Full implementation would handle decompression and GPU upload
  }

  resize(): void {
    const rect = this.canvas.getBoundingClientRect();
    const width = Math.floor(rect.width);
    const height = Math.floor(rect.height);

    if (width > 0 && height > 0 && (width !== this.width || height !== this.height)) {
      this.width = width;
      this.height = height;
      this.canvas.width = width;
      this.canvas.height = height;

      if (this.serverId !== null && this.onResize) {
        this.onResize(width, height);
      }
    }
  }

  focus(): void {
    this.canvas.focus();
  }

  sendKeyInput(keyCode: number, action: number, mods: number, text?: string): void {
    const textBytes = text ? new TextEncoder().encode(text) : new Uint8Array(0);
    const msg = new ArrayBuffer(8 + textBytes.length);
    const view = new DataView(msg);

    view.setUint8(0, ClientMsg.KEY_INPUT);
    view.setUint32(1, keyCode, true);
    view.setUint8(5, action);
    view.setUint8(6, mods);
    view.setUint8(7, textBytes.length);
    new Uint8Array(msg).set(textBytes, 8);

    this.ws?.send(msg);
  }

  sendMouseInput(x: number, y: number, button: number, action: number, mods: number): void {
    const msg = new ArrayBuffer(12);
    const view = new DataView(msg);

    view.setUint8(0, ClientMsg.MOUSE_INPUT);
    view.setUint16(1, x, true);
    view.setUint16(3, y, true);
    view.setUint8(5, button);
    view.setUint8(6, action);
    view.setUint8(7, mods);

    this.ws?.send(msg);
  }

  sendTextInput(text: string): void {
    const textBytes = new TextEncoder().encode(text);
    const msg = new ArrayBuffer(3 + textBytes.length);
    const view = new DataView(msg);

    view.setUint8(0, ClientMsg.TEXT_INPUT);
    view.setUint16(1, textBytes.length, true);
    new Uint8Array(msg).set(textBytes, 3);

    this.ws?.send(msg);
  }

  requestKeyframe(): void {
    const msg = new ArrayBuffer(1);
    const view = new DataView(msg);
    view.setUint8(0, ClientMsg.REQUEST_KEYFRAME);
    this.ws?.send(msg);
  }

  private setupInputHandlers(): void {
    this.canvas.tabIndex = 0;

    this.canvas.addEventListener('keydown', (e) => {
      e.preventDefault();
      const keyCode = KEY_MAP[e.code] ?? 0;
      const mods = this.getModifiers(e);
      this.sendKeyInput(keyCode, 1, mods, e.key.length === 1 ? e.key : undefined);
    });

    this.canvas.addEventListener('keyup', (e) => {
      e.preventDefault();
      const keyCode = KEY_MAP[e.code] ?? 0;
      const mods = this.getModifiers(e);
      this.sendKeyInput(keyCode, 0, mods);
    });

    this.canvas.addEventListener('mousedown', (e) => {
      const rect = this.canvas.getBoundingClientRect();
      const x = e.clientX - rect.left;
      const y = e.clientY - rect.top;
      this.sendMouseInput(x, y, e.button, 1, this.getModifiers(e));
    });

    this.canvas.addEventListener('mouseup', (e) => {
      const rect = this.canvas.getBoundingClientRect();
      const x = e.clientX - rect.left;
      const y = e.clientY - rect.top;
      this.sendMouseInput(x, y, e.button, 0, this.getModifiers(e));
    });

    this.canvas.addEventListener('wheel', (e) => {
      e.preventDefault();
      const msg = new ArrayBuffer(6);
      const view = new DataView(msg);
      view.setUint8(0, ClientMsg.MOUSE_SCROLL);
      view.setInt16(1, Math.round(e.deltaX), true);
      view.setInt16(3, Math.round(e.deltaY), true);
      view.setUint8(5, this.getModifiers(e));
      this.ws?.send(msg);
    });
  }

  private getModifiers(e: KeyboardEvent | MouseEvent | WheelEvent): number {
    let mods = 0;
    if (e.shiftKey) mods |= 0x01;
    if (e.ctrlKey) mods |= 0x02;
    if (e.altKey) mods |= 0x04;
    if (e.metaKey) mods |= 0x08;
    return mods;
  }

  private async initGPU(): Promise<void> {
    if (!navigator.gpu) {
      console.warn('WebGPU not supported');
      return;
    }

    const adapter = await navigator.gpu.requestAdapter();
    if (!adapter) {
      console.warn('No GPU adapter found');
      return;
    }

    this.device = await adapter.requestDevice();
    this.context = this.canvas.getContext('webgpu');

    if (!this.context) {
      console.warn('Could not get WebGPU context');
      return;
    }

    const format = navigator.gpu.getPreferredCanvasFormat();
    this.context.configure({
      device: this.device,
      format,
      alphaMode: 'premultiplied',
    });

    // Initialize pipelines, buffers, etc.
    this.initPipelines();
  }

  private initPipelines(): void {
    // WebGPU pipeline initialization
    // Full implementation in client.js
  }

  private setupResizeObserver(): void {
    const observer = new ResizeObserver(() => {
      if (this.resizeTimeout) clearTimeout(this.resizeTimeout);
      this.resizeTimeout = setTimeout(() => this.resize(), 100);
    });
    observer.observe(this.canvas);
  }
}

// ============================================================================
// App - main application controller
// ============================================================================

class App {
  private controlWs: WebSocket | null = null;
  private fileWs: WebSocket | null = null;
  private panels = new Map<string, Panel>();
  private tabs = new Map<string, TabInfo>();
  private activePanel: Panel | null = null;
  private activeTab: string | null = null;
  private host: string;

  constructor() {
    this.host = window.location.hostname || 'localhost';
  }

  async init(): Promise<void> {
    // Fetch config
    const config = await this.fetchConfig();
    PANEL_PORT = config.panelWsPort;
    CONTROL_PORT = config.controlWsPort;
    FILE_PORT = config.fileWsPort;

    if (config.colors) {
      applyColors(config.colors);
    }

    // Connect control WebSocket
    this.connectControl();
    this.connectFileTransfer();

    // Create initial tab and panel
    this.createTab();

    // Setup keyboard shortcuts
    this.setupShortcuts();
  }

  private async fetchConfig(): Promise<AppConfig> {
    const response = await fetch('/config');
    return response.json();
  }

  private connectControl(): void {
    const wsUrl = `ws://${this.host}:${CONTROL_PORT}`;
    this.controlWs = new WebSocket(wsUrl);
    this.controlWs.binaryType = 'arraybuffer';

    this.controlWs.onopen = () => {
      console.log('Control channel connected');
    };

    this.controlWs.onmessage = (event) => {
      this.handleControlMessage(event);
    };

    this.controlWs.onclose = () => {
      console.log('Control channel disconnected');
      // Reconnect after delay
      setTimeout(() => this.connectControl(), 1000);
    };
  }

  private connectFileTransfer(): void {
    const wsUrl = `ws://${this.host}:${FILE_PORT}`;
    this.fileWs = new WebSocket(wsUrl);
    this.fileWs.binaryType = 'arraybuffer';

    this.fileWs.onopen = () => {
      console.log('File transfer channel connected');
    };
  }

  private handleControlMessage(event: MessageEvent): void {
    if (typeof event.data === 'string') {
      // JSON message
      const msg = JSON.parse(event.data);
      this.handleJsonMessage(msg);
    } else if (event.data instanceof ArrayBuffer) {
      // Binary message
      this.handleBinaryMessage(event.data);
    }
  }

  private handleJsonMessage(msg: Record<string, unknown>): void {
    // Handle JSON control messages
  }

  private handleBinaryMessage(data: ArrayBuffer): void {
    // Handle binary control messages
  }

  createTab(title = 'Terminal'): string {
    const tabId = generateId();
    const container = document.createElement('div');
    container.className = 'tab-content';
    container.id = `tab-${tabId}`;

    document.querySelector('.tabs-container')?.appendChild(container);

    // Create panel in the tab
    const panel = this.createPanel(container);

    this.tabs.set(tabId, {
      id: tabId,
      title,
      root: null as any, // SplitContainer would go here
      element: container,
    });

    this.switchTab(tabId);
    return tabId;
  }

  createPanel(container: HTMLElement): Panel {
    const id = generateId();
    const panel = new Panel(
      id,
      container,
      null,
      (width, height) => this.handlePanelResize(panel, width, height),
      (action, data) => this.handleViewAction(panel, action, data)
    );

    this.panels.set(id, panel);
    panel.connect(this.host, PANEL_PORT);

    if (!this.activePanel) {
      this.activePanel = panel;
    }

    return panel;
  }

  private handlePanelResize(panel: Panel, width: number, height: number): void {
    // Send resize to server via control channel
    if (panel.serverId !== null && this.controlWs?.readyState === WebSocket.OPEN) {
      const msg = new ArrayBuffer(13);
      const view = new DataView(msg);
      view.setUint8(0, 0x82); // RESIZE_PANEL
      view.setUint32(1, panel.serverId, true);
      view.setUint32(5, width, true);
      view.setUint32(9, height, true);
      this.controlWs.send(msg);
    }
  }

  private handleViewAction(panel: Panel, action: string, data?: unknown): void {
    console.log(`View action from panel ${panel.id}:`, action, data);
  }

  switchTab(tabId: string): void {
    // Hide current tab
    if (this.activeTab) {
      const currentTab = this.tabs.get(this.activeTab);
      if (currentTab) {
        currentTab.element.classList.remove('active');
      }
    }

    // Show new tab
    const tab = this.tabs.get(tabId);
    if (tab) {
      tab.element.classList.add('active');
      this.activeTab = tabId;
    }
  }

  private setupShortcuts(): void {
    document.addEventListener('keydown', (e) => {
      // Cmd+T: New tab
      if (e.metaKey && e.key === 't') {
        e.preventDefault();
        this.createTab();
      }

      // Cmd+W: Close tab
      if (e.metaKey && e.key === 'w') {
        e.preventDefault();
        if (this.activeTab) {
          this.closeTab(this.activeTab);
        }
      }

      // Cmd+1-9: Switch tabs
      if (e.metaKey && e.key >= '1' && e.key <= '9') {
        e.preventDefault();
        const index = parseInt(e.key) - 1;
        const tabIds = Array.from(this.tabs.keys());
        if (index < tabIds.length) {
          this.switchTab(tabIds[index]);
        }
      }
    });
  }

  closeTab(tabId: string): void {
    const tab = this.tabs.get(tabId);
    if (!tab) return;

    // Don't close last tab
    if (this.tabs.size <= 1) return;

    // Remove panels in this tab
    // ...

    tab.element.remove();
    this.tabs.delete(tabId);

    // Switch to another tab
    if (this.activeTab === tabId) {
      const remaining = Array.from(this.tabs.keys());
      if (remaining.length > 0) {
        this.switchTab(remaining[0]);
      }
    }
  }

  // File transfer methods
  requestDownload(path: string, isFolder = false): void {
    if (!this.activePanel?.serverId) {
      console.error('No active panel for download');
      return;
    }

    // Auto-detect folder if path ends with /
    if (path.endsWith('/')) {
      isFolder = true;
      path = path.slice(0, -1);
    }

    const panelId = this.activePanel.serverId;
    const pathBytes = new TextEncoder().encode(path);

    const msgLen = 1 + 4 + 2 + pathBytes.length;
    const msg = new ArrayBuffer(msgLen);
    const view = new DataView(msg);
    const bytes = new Uint8Array(msg);

    let offset = 0;
    view.setUint8(offset, isFolder ? 0x14 : 0x11); offset += 1;
    view.setUint32(offset, panelId, true); offset += 4;
    view.setUint16(offset, pathBytes.length, true); offset += 2;
    bytes.set(pathBytes, offset);

    this.controlWs?.send(msg);
    console.log(`Requesting ${isFolder ? 'folder' : 'file'} download: ${path}`);
  }
}

// ============================================================================
// Initialize on DOM ready
// ============================================================================

let app: App | undefined;

function init(): void {
  app = new App();
  app.init().catch(console.error);
  // Export for external access
  (window as any).termwebApp = app;
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', init);
} else {
  init();
}
