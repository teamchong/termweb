/**
 * termweb-mux browser client
 * Connects to server, receives frames, renders to canvas, sends input
 */

import { Panel } from './panel';
import type { AppConfig, TabInfo } from './types';
import { generateId, applyColors } from './utils';

// Re-export for external use
export * from './protocol';
export * from './types';
export * from './utils';
export { Panel } from './panel';
export { SplitContainer } from './split-container';

// WebSocket ports (fetched from /config endpoint)
let PANEL_PORT = 0;
let CONTROL_PORT = 0;
let FILE_PORT = 0;

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
      const msg = JSON.parse(event.data);
      this.handleJsonMessage(msg);
    } else if (event.data instanceof ArrayBuffer) {
      this.handleBinaryMessage(event.data);
    }
  }

  private handleJsonMessage(_msg: Record<string, unknown>): void {
    // Handle JSON control messages
  }

  private handleBinaryMessage(_data: ArrayBuffer): void {
    // Handle binary control messages
  }

  createTab(title = 'Terminal'): string {
    const tabId = generateId();
    const container = document.createElement('div');
    container.className = 'tab-content';
    container.id = `tab-${tabId}`;

    document.querySelector('.tabs-container')?.appendChild(container);

    const panel = this.createPanel(container);

    this.tabs.set(tabId, {
      id: tabId,
      title,
      root: null as unknown as TabInfo['root'],
      element: container,
    });

    this.switchTab(tabId);
    return tabId;
  }

  createPanel(container: HTMLElement): Panel {
    const id = generateId();
    const panel = new Panel(id, container, null, {
      onResize: (panelId, width, height) => this.handlePanelResize(panelId, width, height),
      onViewAction: (action, data) => this.handleViewAction(panel, action, data),
    });

    this.panels.set(id, panel);
    panel.connect(this.host, PANEL_PORT);

    if (!this.activePanel) {
      this.activePanel = panel;
    }

    return panel;
  }

  private handlePanelResize(panelId: number, width: number, height: number): void {
    if (this.controlWs?.readyState === WebSocket.OPEN) {
      const msg = new ArrayBuffer(13);
      const view = new DataView(msg);
      view.setUint8(0, 0x82); // RESIZE_PANEL
      view.setUint32(1, panelId, true);
      view.setUint32(5, width, true);
      view.setUint32(9, height, true);
      this.controlWs.send(msg);
    }
  }

  private handleViewAction(_panel: Panel, action: string, data?: unknown): void {
    console.log('View action:', action, data);
  }

  switchTab(tabId: string): void {
    if (this.activeTab) {
      const currentTab = this.tabs.get(this.activeTab);
      currentTab?.element.classList.remove('active');
    }

    const tab = this.tabs.get(tabId);
    if (tab) {
      tab.element.classList.add('active');
      this.activeTab = tabId;
    }
  }

  private setupShortcuts(): void {
    document.addEventListener('keydown', (e) => {
      if (e.metaKey && e.key === 't') {
        e.preventDefault();
        this.createTab();
      }

      if (e.metaKey && e.key === 'w') {
        e.preventDefault();
        if (this.activeTab) {
          this.closeTab(this.activeTab);
        }
      }

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
    if (!tab || this.tabs.size <= 1) return;

    tab.element.remove();
    this.tabs.delete(tabId);

    if (this.activeTab === tabId) {
      const remaining = Array.from(this.tabs.keys());
      if (remaining.length > 0) {
        this.switchTab(remaining[0]);
      }
    }
  }

  requestDownload(path: string, isFolder = false): void {
    if (!this.activePanel?.serverId) {
      console.error('No active panel for download');
      return;
    }

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
  (window as any).termwebApp = app;
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', init);
} else {
  init();
}
