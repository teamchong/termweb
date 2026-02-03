/**
 * termweb-mux browser client
 * Connects to server, receives frames, renders to canvas, sends input
 */

import { Panel } from './panel';
import { SplitContainer } from './split-container';
import { FileTransferHandler } from './file-transfer';
import { CommandPalette, UploadDialog, DownloadDialog, AccessControlDialog, type DownloadOptions } from './dialogs';
import type { AppConfig, TabInfo, LayoutData, LayoutNode } from './types';
import { generateId, applyColors, formatBytes, isLightColor, shadowColor } from './utils';
import { BinaryCtrlMsg } from './protocol';

// Re-export for external use
export * from './protocol';
export * from './types';
export * from './utils';
export { Panel } from './panel';
export { SplitContainer } from './split-container';
export { FileTransferHandler } from './file-transfer';

// WebSocket URL builder - auto-detects ws/wss based on page protocol
function getWsUrl(path: string): string {
  const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
  const host = window.location.host; // includes port if non-standard
  return `${protocol}//${host}${path}`;
}

// ============================================================================
// App - main application controller
// ============================================================================

class App {
  private controlWs: WebSocket | null = null;
  private fileTransfer: FileTransferHandler;
  private panels = new Map<string, Panel>();
  private tabs = new Map<string, TabInfo>();
  private tabHistory: string[] = [];
  private activePanel: Panel | null = null;
  private activeTab: string | null = null;
  private host: string;
  private nextTabId = 1;
  private pendingDownload: DownloadOptions | null = null;
  private quickTerminalPanel: Panel | null = null;
  private previousActivePanel: Panel | null = null;

  // UI elements
  private tabsEl: HTMLElement | null = null;
  private panelsEl: HTMLElement | null = null;
  private statusDot: HTMLElement | null = null;

  // Dialogs
  private commandPalette: CommandPalette;
  private uploadDialog: UploadDialog;
  private downloadDialog: DownloadDialog;
  private accessControlDialog: AccessControlDialog;

  // Auth state
  private role = 0;
  private authRequired = false;
  private sessions: Array<{ id: string; name: string; editorToken: string; viewerToken: string }> = [];
  private shareLinks: Array<{ token: string; type: number; useCount: number }> = [];

  // Tab overview state
  private tabOverviewTabs: Array<{ tabId: string; tab: TabInfo; element: HTMLElement }> | null = null;
  private tabOverviewCloseHandler: ((e: KeyboardEvent | MouseEvent) => void) | null = null;

  // Cleanup state
  private destroyed = false;
  private reconnectTimeoutId: ReturnType<typeof setTimeout> | null = null;

  constructor() {
    this.host = window.location.hostname || 'localhost';
    this.fileTransfer = new FileTransferHandler();

    this.commandPalette = new CommandPalette((action) => this.executeCommand(action));
    this.uploadDialog = new UploadDialog((file) => this.uploadFile(file));
    this.downloadDialog = new DownloadDialog((options) => this.requestDownload(options));
    this.accessControlDialog = new AccessControlDialog();

    this.setupAccessControlCallbacks();
  }

  async init(): Promise<void> {
    // Get UI elements
    this.tabsEl = document.getElementById('tabs');
    this.panelsEl = document.getElementById('panels');
    this.statusDot = document.getElementById('status-dot');

    // Setup UI event listeners
    document.getElementById('new-tab')?.addEventListener('click', () => this.createTab());
    document.getElementById('show-all-tabs')?.addEventListener('click', () => this.showTabOverview());

    // Fetch config
    const config = await this.fetchConfig();

    if (config.colors) {
      applyColors(config.colors);
    }

    // Connect WebSockets (path-based on same port)
    this.connectControl();
    this.fileTransfer.connect();

    // Wait for panel_list from server to decide whether to create or connect
    // createTab() will be called in handleJsonMessage if no panels exist

    // Setup keyboard shortcuts
    this.setupShortcuts();

    // Setup menus
    this.setupMenus();

    // Update menu state (disable items that require tabs on initial load)
    this.updateMenuState();

    // Setup iOS accessory bar
    this.setupAccessoryBar();

    // Setup unload handler for cleanup
    window.addEventListener('beforeunload', () => this.destroy());
  }

  destroy(): void {
    this.destroyed = true;

    // Cancel pending reconnection
    if (this.reconnectTimeoutId) {
      clearTimeout(this.reconnectTimeoutId);
      this.reconnectTimeoutId = null;
    }

    // Close control WebSocket
    if (this.controlWs) {
      this.controlWs.close();
      this.controlWs = null;
    }

    // Disconnect file transfer handler
    this.fileTransfer.disconnect();

    // Destroy all panels
    for (const [, panel] of this.panels) {
      panel.destroy();
    }
    this.panels.clear();

    // Clean up tabs
    for (const [, tab] of this.tabs) {
      tab.root.destroy();
    }
    this.tabs.clear();

    // Clean up quick terminal if exists
    if (this.quickTerminalPanel) {
      this.quickTerminalPanel.destroy();
      this.quickTerminalPanel = null;
    }
  }

  private async fetchConfig(): Promise<AppConfig> {
    const response = await fetch('/config');
    return response.json();
  }

  private setStatus(state: 'connected' | 'disconnected' | 'error', _message?: string): void {
    if (this.statusDot) {
      this.statusDot.className = `status-dot ${state}`;
    }
  }

  private connectControl(): void {
    if (this.destroyed) return;

    const wsUrl = getWsUrl('/ws/control');
    this.controlWs = new WebSocket(wsUrl);
    this.controlWs.binaryType = 'arraybuffer';

    this.controlWs.onopen = () => {
      console.log('Control channel connected');
      this.setStatus('connected');
    };

    this.controlWs.onmessage = (event) => {
      if (this.destroyed) return;
      if (typeof event.data === 'string') {
        this.handleJsonMessage(JSON.parse(event.data));
      } else if (event.data instanceof ArrayBuffer) {
        this.handleBinaryMessage(event.data);
      }
    };

    this.controlWs.onclose = () => {
      console.log('Control channel disconnected');
      this.setStatus('disconnected');
      if (!this.destroyed) {
        this.reconnectTimeoutId = setTimeout(() => this.connectControl(), 1000);
      }
    };

    this.controlWs.onerror = () => {
      this.setStatus('error');
    };
  }

  private handleJsonMessage(msg: Record<string, unknown>): void {
    const type = msg.type as string;

    switch (type) {
      case 'panel_list':
        // Server is authoritative - restore whatever state it sends
        // If empty, frontend stays empty (user can create tab with hotkey)
        if (msg.layout && typeof msg.layout === 'object') {
          this.restoreLayoutFromServer(msg.layout as LayoutData);
        } else if (Array.isArray(msg.panels) && msg.panels.length > 0) {
          this.reconnectPanelsAsSplits(msg.panels as Array<{ panel_id: number; title: string }>);
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
      case 'panel_pwd':
        this.updatePanelPwd(msg.panel_id as number, msg.pwd as string);
        break;
      case 'panel_bell':
        this.handleBell(msg.panel_id as number);
        break;
      case 'clipboard':
        try {
          const text = atob(msg.data as string);
          navigator.clipboard.writeText(text).catch(err => {
            console.error('Failed to write clipboard:', err);
          });
        } catch { /* ignore */ }
        break;
      case 'auth_state':
        this.handleAuthState(msg as { role: number; authRequired: boolean; hasPassword: boolean; passkeyCount: number });
        break;
      case 'sessions':
        this.handleSessionList(msg.sessions as typeof this.sessions);
        break;
      case 'share_links':
        this.handleShareLinks(msg.links as typeof this.shareLinks);
        break;
      case 'auth_error':
        console.error('Auth error:', msg.message);
        break;
    }
  }

  private handleBinaryMessage(data: ArrayBuffer): void {
    const view = new DataView(data);
    const bytes = new Uint8Array(data);
    const msgType = view.getUint8(0);
    const decoder = new TextDecoder();

    switch (msgType) {
      case 0x01: { // panel_list
        // Format: [type:u8][count:u8][panel_id:u32, title_len:u8, title...]*[layout_len:u16][layout_json]
        const count = view.getUint8(1);
        const panels: Array<{ panel_id: number; title: string }> = [];
        let offset = 2;
        for (let i = 0; i < count; i++) {
          const panelId = view.getUint32(offset, true);
          offset += 4;
          const titleLen = view.getUint8(offset);
          offset += 1;
          const title = decoder.decode(bytes.slice(offset, offset + titleLen));
          offset += titleLen;
          panels.push({ panel_id: panelId, title });
        }
        const layoutLen = view.getUint16(offset, true);
        offset += 2;
        const layoutJson = decoder.decode(bytes.slice(offset, offset + layoutLen));
        let layout = null;
        try { layout = JSON.parse(layoutJson); } catch { /* ignore */ }
        this.handlePanelList(panels, layout);
        break;
      }
      case 0x02: { // panel_created
        const panelId = view.getUint32(1, true);
        this.handlePanelCreated(panelId);
        break;
      }
      case 0x03: { // panel_closed
        const panelId = view.getUint32(1, true);
        this.handlePanelClosed(panelId);
        break;
      }
      case 0x04: { // panel_title
        // Format: [type:u8][panel_id:u32][title_len:u8][title...]
        const panelId = view.getUint32(1, true);
        const titleLen = view.getUint8(5);
        const title = decoder.decode(bytes.slice(6, 6 + titleLen));
        this.updatePanelTitle(panelId, title);
        break;
      }
      case 0x05: { // panel_pwd
        // Format: [type:u8][panel_id:u32][pwd_len:u16][pwd...]
        const panelId = view.getUint32(1, true);
        const pwdLen = view.getUint16(5, true);
        const pwd = decoder.decode(bytes.slice(7, 7 + pwdLen));
        this.updatePanelPwd(panelId, pwd);
        break;
      }
      case 0x06: { // panel_bell
        const panelId = view.getUint32(1, true);
        this.handleBell(panelId);
        break;
      }
      case 0x07: { // layout_update
        const layoutLen = view.getUint16(1, true);
        const layoutJson = decoder.decode(bytes.slice(3, 3 + layoutLen));
        let layout = null;
        try { layout = JSON.parse(layoutJson); } catch { /* ignore */ }
        this.handleLayoutUpdate(layout);
        break;
      }
      case 0x08: { // clipboard
        const dataLen = view.getUint32(1, true);
        const text = decoder.decode(bytes.slice(5, 5 + dataLen));
        navigator.clipboard.writeText(text).catch(err => {
          console.error('Failed to write clipboard:', err);
        });
        break;
      }
      case 0x09: { // inspector_state (binary format)
        // Format: [type:u8][panel_id:u32][cols:u16][rows:u16][width:u16][height:u16][cell_w:u8][cell_h:u8]
        const panelId = view.getUint32(1, true);
        const state = {
          cols: view.getUint16(5, true),
          rows: view.getUint16(7, true),
          width_px: view.getUint16(9, true),
          height_px: view.getUint16(11, true),
          cell_width: view.getUint8(13),
          cell_height: view.getUint8(14),
        };
        this.updateInspectorState(panelId, state);
        break;
      }
      case 0x0A: { // auth_state
        const role = view.getUint8(1);
        const authRequired = view.getUint8(2) === 1;
        const hasPassword = view.getUint8(3) === 1;
        const passkeyCount = view.getUint8(4);
        this.handleAuthState({ role, authRequired, hasPassword, passkeyCount });
        break;
      }
      case 0x0B: { // session_list
        const count = view.getUint16(1, true);
        const sessions: typeof this.sessions = [];
        let offset = 3;
        for (let i = 0; i < count; i++) {
          const idLen = view.getUint16(offset, true); offset += 2;
          const id = decoder.decode(bytes.slice(offset, offset + idLen)); offset += idLen;
          const nameLen = view.getUint16(offset, true); offset += 2;
          const name = decoder.decode(bytes.slice(offset, offset + nameLen)); offset += nameLen;
          const editorToken = decoder.decode(bytes.slice(offset, offset + 44)); offset += 44;
          const viewerToken = decoder.decode(bytes.slice(offset, offset + 44)); offset += 44;
          sessions.push({ id, name, editorToken, viewerToken });
        }
        this.handleSessionList(sessions);
        break;
      }
      case 0x0C: { // share_links
        const count = view.getUint16(1, true);
        const links: typeof this.shareLinks = [];
        let offset = 3;
        for (let i = 0; i < count; i++) {
          const token = decoder.decode(bytes.slice(offset, offset + 44)); offset += 44;
          const type = view.getUint8(offset); offset += 1;
          const useCount = view.getUint32(offset, true); offset += 4;
          offset += 1; // valid byte (unused)
          links.push({ token, type, useCount });
        }
        this.handleShareLinks(links);
        break;
      }
      case 0x0D: { // panel_notification
        // Format: [type:u8][panel_id:u32][title_len:u8][title...][body_len:u16][body...]
        const panelId = view.getUint32(1, true);
        const titleLen = view.getUint8(5);
        const title = decoder.decode(bytes.slice(6, 6 + titleLen));
        const bodyLen = view.getUint16(6 + titleLen, true);
        const body = decoder.decode(bytes.slice(8 + titleLen, 8 + titleLen + bodyLen));
        this.handleNotification(panelId, title, body);
        break;
      }
      case 0x12: // FILE_DATA (single file download response)
        this.handleFileData(data);
        break;
      case 0x13: // FILE_ERROR
        this.handleFileError(data);
        break;
      case 0x15: // FOLDER_DATA (zip download response)
        this.handleFolderData(data);
        break;
      case 0x19: // FILE_PREVIEW response
        this.handleFilePreview(data);
        break;
      case 0x1A: // FOLDER_PREVIEW response
        this.handleFolderPreview(data);
        break;
    }
  }

  private handlePanelList(panels: Array<{ panel_id: number; title: string }>, layout: unknown): void {
    // Server is authoritative - restore whatever state it sends
    // If empty, frontend stays empty (user can create tab with hotkey)
    if (layout && typeof layout === 'object' && (layout as LayoutData).tabs?.length > 0) {
      this.restoreLayoutFromServer(layout as LayoutData);
    } else if (panels.length > 0) {
      this.reconnectPanelsAsSplits(panels);
    }
    // No else - empty state is valid, user creates tab manually
  }

  private reconnectPanelsAsSplits(panels: Array<{ panel_id: number; title: string }>): void {
    // Put all panels in one tab with horizontal splits
    if (panels.length === 0) {
      return; // Empty state - user creates tab manually
    }

    // Create first panel as tab
    const tabId = this.createTab(panels[0].panel_id, panels[0].title);
    const tab = this.tabs.get(tabId);
    if (!tab) return;

    // Add remaining panels as splits
    for (let i = 1; i < panels.length; i++) {
      const panel = this.createPanel(tab.element, panels[i].panel_id);
      tab.root.split('right', panel);
    }
  }

  private handlePanelCreated(panelId: number): void {
    // New panel created on server - update local panel's serverId
    for (const [, panel] of this.panels) {
      if (panel.serverId === null) {
        panel.serverId = panelId;
        break;
      }
    }
  }

  private handlePanelClosed(serverId: number): void {
    let targetPanel: Panel | null = null;
    let targetPanelId: string | null = null;

    for (const [id, panel] of this.panels) {
      if (panel.serverId === serverId) {
        targetPanel = panel;
        targetPanelId = id;
        break;
      }
    }

    if (!targetPanel || !targetPanelId) return;

    // Check if this is the quick terminal panel
    if (targetPanel === this.quickTerminalPanel) {
      this.quickTerminalPanel = null;
      const container = document.getElementById('quick-terminal');
      if (container?.classList.contains('visible')) {
        container.classList.remove('visible');
        if (this.previousActivePanel) {
          this.setActivePanel(this.previousActivePanel);
          this.previousActivePanel = null;
        } else if (this.activeTab) {
          // Update title for current active tab
          const tab = this.tabs.get(this.activeTab);
          if (tab) {
            const tabPanels = tab.root.getAllPanels();
            if (tabPanels.length > 0) {
              this.setActivePanel(tabPanels[0]);
            }
          }
        }
      }
      this.panels.delete(targetPanelId);
      targetPanel.destroy();
      return;
    }

    // Clear previousActivePanel if it's the panel being closed
    if (this.previousActivePanel === targetPanel) {
      this.previousActivePanel = null;
    }

    // Find which tab contains this panel
    let containingTabId: string | null = null;
    for (const [tabId, tab] of this.tabs) {
      if (tab.root.findContainer(targetPanel)) {
        containingTabId = tabId;
        break;
      }
    }

    // Remove from panels map
    this.panels.delete(targetPanelId);

    if (!containingTabId) {
      // Panel not in any tab - just destroy it
      targetPanel.destroy();
      return;
    }

    const tab = this.tabs.get(containingTabId);
    if (!tab) {
      targetPanel.destroy();
      return;
    }

    const allPanels = tab.root.getAllPanels();

    if (allPanels.length <= 1) {
      // Last panel in tab - close the whole tab
      tab.root.destroy();
      tab.element.remove();
      this.tabs.delete(containingTabId);
      this.removeTabUI(containingTabId);

      // Remove from tab history
      const histIndex = this.tabHistory.indexOf(containingTabId);
      if (histIndex !== -1) {
        this.tabHistory.splice(histIndex, 1);
      }

      if (this.activeTab === containingTabId) {
        this.activeTab = null;
        this.activePanel = null;
        // Find most recently used tab that still exists
        for (let i = this.tabHistory.length - 1; i >= 0; i--) {
          if (this.tabs.has(this.tabHistory[i])) {
            this.switchToTab(this.tabHistory[i]);
            return;
          }
        }
        // Fallback: switch to any remaining tab
        const remaining = this.tabs.keys().next();
        if (!remaining.done) {
          this.switchToTab(remaining.value);
        }
      }
    } else {
      // Multiple panels - just close this one
      const wasActive = targetPanel === this.activePanel;
      const otherPanel = allPanels.find(p => p !== targetPanel);

      // Remove from split container
      tab.root.removePanel(targetPanel);

      // Destroy panel
      targetPanel.destroy();

      // Focus other panel if needed
      if (wasActive && otherPanel) {
        this.setActivePanel(otherPanel);
      }
    }
  }

  private handleLayoutUpdate(layout: unknown): void {
    // Check if server has no tabs (scale to zero) - clear client UI
    const layoutData = layout as LayoutData | null;
    if (!layoutData || !layoutData.tabs || layoutData.tabs.length === 0) {
      // Server has no panels - clear all tabs
      for (const [tabId, tab] of this.tabs) {
        tab.root.destroy();
        tab.element.remove();
        this.removeTabUI(tabId);
      }
      this.tabs.clear();
      this.panels.clear();
      this.activeTab = null;
      this.activePanel = null;

      // Reset title to ghost emoji (empty state)
      const appTitle = document.getElementById('app-title');
      if (appTitle) appTitle.textContent = '👻';

      this.updateMenuState();
    }
    // Non-empty layouts are ignored - client manages its own state
  }

  private restoreLayoutFromServer(layout: LayoutData): void {
    // Clear existing panels/tabs
    for (const [tabId, tab] of this.tabs) {
      tab.root.destroy();
      tab.element.remove();
      this.removeTabUI(tabId);
    }
    this.tabs.clear();
    this.panels.clear();
    this.activeTab = null;
    this.activePanel = null;

    const serverToClientTabId = new Map<number, string>();
    const tabActivePanels = new Map<string, number>(); // clientTabId -> activePanelId

    // Restore each tab
    for (const serverTab of layout.tabs || []) {
      const tabId = String(this.nextTabId++);
      serverToClientTabId.set(serverTab.id, tabId);
      if (serverTab.activePanelId !== undefined) {
        tabActivePanels.set(tabId, serverTab.activePanelId);
      }

      const tabContent = document.createElement('div');
      tabContent.className = 'tab-content';
      tabContent.id = `tab-${tabId}`;
      this.panelsEl?.appendChild(tabContent);

      const root = this.buildSplitTreeFromNode(serverTab.root, tabContent);
      if (!root) {
        tabContent.remove();
        continue;
      }

      tabContent.appendChild(root.element);

      this.tabs.set(tabId, {
        id: tabId,
        title: '',
        root,
        element: tabContent,
      });

      this.addTabUI(tabId, '');
    }

    // Switch to active tab
    let targetTabId: string | null = null;
    if (layout.activeTabId !== undefined && serverToClientTabId.has(layout.activeTabId)) {
      targetTabId = serverToClientTabId.get(layout.activeTabId) || null;
    } else if (this.tabs.size > 0) {
      targetTabId = this.tabs.keys().next().value || null;
    }

    if (targetTabId) {
      this.switchToTab(targetTabId);
      // Restore active panel within tab
      const activePanelId = tabActivePanels.get(targetTabId);
      if (activePanelId !== undefined) {
        for (const [, panel] of this.panels) {
          if (panel.serverId === activePanelId) {
            this.setActivePanel(panel);
            break;
          }
        }
      }
    } else {
      this.createTab();
    }
  }

  private buildSplitTreeFromNode(node: LayoutNode | null, parentContainer: HTMLElement): SplitContainer | null {
    if (!node) return null;

    if (node.type === 'leaf' && node.panelId !== undefined) {
      const panel = this.createPanel(parentContainer, node.panelId);
      return SplitContainer.createLeaf(panel);
    }

    if (node.type === 'split' && node.first && node.second) {
      const container = new SplitContainer(null);
      container.direction = node.direction || 'horizontal';
      container.ratio = node.ratio || 0.5;

      const first = this.buildSplitTreeFromNode(node.first, parentContainer);
      if (!first) return null;
      first.parent = container;

      const second = this.buildSplitTreeFromNode(node.second, parentContainer);
      if (!second) return null;
      second.parent = container;

      container.first = first;
      container.second = second;

      container.element = document.createElement('div');
      container.element.className = `split-container ${container.direction}`;

      container.element.appendChild(first.element);

      container.divider = document.createElement('div');
      container.divider.className = 'split-divider';
      container.setupDividerDrag();
      container.element.appendChild(container.divider);

      container.element.appendChild(second.element);

      container.applyRatio();

      return container;
    }

    return null;
  }

  private updateInspectorState(panelId: number, state: unknown): void {
    for (const [, panel] of this.panels) {
      if (panel.serverId === panelId) {
        panel.handleInspectorState(state);
        break;
      }
    }
  }

  private handleAuthState(state: { role: number; authRequired: boolean; hasPassword: boolean; passkeyCount: number }): void {
    this.role = state.role;
    this.authRequired = state.authRequired;
    console.log('Auth state:', state);
  }

  private handleBell(serverId: number): void {
    this.handlePanelBell(serverId);
  }

  private handleFileData(data: ArrayBuffer): void {
    const view = new DataView(data);
    const bytes = new Uint8Array(data);

    let offset = 1;
    const filenameLen = view.getUint16(offset, true); offset += 2;
    const filename = new TextDecoder().decode(bytes.slice(offset, offset + filenameLen)); offset += filenameLen;
    const fileData = bytes.slice(offset);

    this.triggerDownload(filename, fileData);
  }

  private handleFolderData(data: ArrayBuffer): void {
    const view = new DataView(data);
    const bytes = new Uint8Array(data);

    let offset = 1;
    const filenameLen = view.getUint16(offset, true); offset += 2;
    const filename = new TextDecoder().decode(bytes.slice(offset, offset + filenameLen)); offset += filenameLen;
    const fileData = bytes.slice(offset);

    this.triggerDownload(filename, fileData);
  }

  private triggerDownload(filename: string, data: Uint8Array): void {
    const blob = new Blob([data as Uint8Array<ArrayBuffer>]);
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
    console.log(`Downloaded ${filename}: ${formatBytes(data.length)}`);
  }

  private handleFileError(data: ArrayBuffer): void {
    const view = new DataView(data);
    const bytes = new Uint8Array(data);
    const errorLen = view.getUint16(1, true);
    const error = new TextDecoder().decode(bytes.slice(3, 3 + errorLen));
    console.error('File transfer error:', error);
    alert(`Download error: ${error}`);
  }

  private handleFilePreview(data: ArrayBuffer): void {
    // Format: [0x19][name_len:u16][name][size:u64]
    const view = new DataView(data);
    const bytes = new Uint8Array(data);
    const nameLen = view.getUint16(1, true);
    const name = new TextDecoder().decode(bytes.slice(3, 3 + nameLen));
    const size = Number(view.getBigUint64(3 + nameLen, true));

    this.showDownloadPreview(name, size, false, 1);
  }

  private handleFolderPreview(data: ArrayBuffer): void {
    // Format: [0x1A][name_len:u16][name.zip][size:u64][file_count:u32]
    const view = new DataView(data);
    const bytes = new Uint8Array(data);
    const nameLen = view.getUint16(1, true);
    const name = new TextDecoder().decode(bytes.slice(3, 3 + nameLen));
    const size = Number(view.getBigUint64(3 + nameLen, true));
    const fileCount = view.getUint32(3 + nameLen + 8, true);

    this.showDownloadPreview(name, size, true, fileCount);
  }

  private showDownloadPreview(name: string, size: number, isFolder: boolean, fileCount: number): void {
    const overlay = document.getElementById('preview-dialog');
    if (!overlay) return;

    // Update summary - repurpose the counts for file info
    const newEl = document.getElementById('preview-new');
    const updateEl = document.getElementById('preview-update');
    const deleteEl = document.getElementById('preview-delete');

    // Update dialog title
    const titleEl = overlay.querySelector('.dialog-title');
    if (titleEl) titleEl.textContent = isFolder ? 'Download Folder' : 'Download File';

    // Update summary labels
    const summaryEl = overlay.querySelector('.preview-summary');
    if (summaryEl) {
      summaryEl.innerHTML = isFolder
        ? `<div class="preview-stat">Folder: <span class="preview-count">${name}</span></div>
           <div class="preview-stat">Files: <span class="preview-count">${fileCount}</span></div>
           <div class="preview-stat">Size: <span class="preview-count">${formatBytes(size)}</span></div>`
        : `<div class="preview-stat">File: <span class="preview-count">${name}</span></div>
           <div class="preview-stat">Size: <span class="preview-count">${formatBytes(size)}</span></div>`;
    }

    // Hide entries list for simple preview
    const entriesEl = document.getElementById('preview-entries');
    if (entriesEl) entriesEl.style.display = 'none';

    // Show dialog
    overlay.classList.add('visible');

    // Handle buttons
    const cancelBtn = overlay.querySelector('.dialog-btn.cancel');
    const proceedBtn = overlay.querySelector('.dialog-btn.primary');

    const hide = () => {
      overlay.classList.remove('visible');
      if (entriesEl) entriesEl.style.display = '';
      cancelBtn?.removeEventListener('click', handleCancel);
      proceedBtn?.removeEventListener('click', handleProceed);
    };

    const handleCancel = () => {
      hide();
      this.pendingDownload = null;
    };

    const handleProceed = () => {
      hide();
      if (this.pendingDownload) {
        const opts = { ...this.pendingDownload, preview: false };
        this.pendingDownload = null;
        this.requestDownload(opts);
      }
    };

    cancelBtn?.addEventListener('click', handleCancel);
    proceedBtn?.addEventListener('click', handleProceed);
  }

  // ============================================================================
  // Tab Management
  // ============================================================================

  createTab(serverIdOrTitle?: number | string, title?: string): string {
    // Handle overloaded signatures:
    // createTab() - new panel with empty title (shows 👻)
    // createTab("Title") - new panel with custom title
    // createTab(serverId, "Title") - connect to existing server panel
    let serverId: number | null = null;
    let tabTitle = '';

    if (typeof serverIdOrTitle === 'number') {
      serverId = serverIdOrTitle;
      tabTitle = title || '';
    } else if (typeof serverIdOrTitle === 'string') {
      tabTitle = serverIdOrTitle;
    }

    const tabId = String(this.nextTabId++);
    const container = document.createElement('div');
    container.className = 'tab-content';
    container.id = `tab-${tabId}`;

    this.panelsEl?.appendChild(container);

    // When creating a new panel (serverId is null), inherit CWD from active panel
    const inheritCwdFrom = serverId === null ? this.activePanel?.serverId ?? null : null;
    const panel = this.createPanel(container, serverId, inheritCwdFrom);
    const root = SplitContainer.createLeaf(panel);
    container.appendChild(root.element);

    this.tabs.set(tabId, {
      id: tabId,
      title: tabTitle,
      root,
      element: container,
    });

    this.addTabUI(tabId, tabTitle);
    this.switchToTab(tabId);
    this.updateMenuState();
    return tabId;
  }

  private createPanel(container: HTMLElement, serverId: number | null = null, inheritCwdFrom: number | null = null): Panel {
    const id = generateId();
    const panel = new Panel(id, container, serverId, {
      onViewAction: (action, data) => this.handleViewAction(panel, action, data),
    }, inheritCwdFrom);

    this.panels.set(id, panel);
    panel.connect();

    // Add click handler to focus this panel
    panel.element.addEventListener('mousedown', () => {
      this.setActivePanel(panel);
    });

    if (!this.activePanel) {
      this.setActivePanel(panel);
    }

    return panel;
  }

  private setActivePanel(panel: Panel | null): void {
    if (this.activePanel === panel) return;

    // Remove active/focused class from previous panel
    if (this.activePanel) {
      this.activePanel.element.classList.remove('active', 'focused');
    }

    this.activePanel = panel;

    if (panel) {
      // Add active/focused class to new panel
      panel.element.classList.add('active', 'focused');
      panel.focus();

      if (panel.serverId !== null) {
        this.sendFocusPanel(panel.serverId);
      }

      this.updateTitleForPanel(panel);
    }

    this.updateMenuState();
  }

  switchToTab(tabId: string): void {
    console.log(`switchToTab: switching to tab ${tabId}, total tabs: ${this.tabs.size}`);

    // Update tab history (LRU: move to end)
    const histIndex = this.tabHistory.indexOf(tabId);
    if (histIndex !== -1) {
      this.tabHistory.splice(histIndex, 1);
    }
    this.tabHistory.push(tabId);

    // Hide ALL tabs first (ensures clean state)
    for (const [tid, t] of this.tabs) {
      t.element.classList.remove('active');
      if (tid !== tabId) {
        // Pause panels in non-active tabs
        for (const panel of t.root.getAllPanels()) {
          panel.hide();
        }
      }
    }

    // Show the target tab
    const tab = this.tabs.get(tabId);
    if (tab) {
      tab.element.classList.add('active');
      this.activeTab = tabId;
      this.updateTabUIActive(tabId);

      // Resume all panels in new tab
      const tabPanels = tab.root.getAllPanels();
      for (const panel of tabPanels) {
        panel.show();
      }

      // Set active panel to first panel if none set (use setActivePanel to notify server)
      if (!this.activePanel || !tabPanels.includes(this.activePanel)) {
        this.setActivePanel(tabPanels[0] || null);
      } else {
        // Still notify server of the focus change even if panel didn't change
        if (this.activePanel && this.activePanel.serverId !== null) {
          this.sendFocusPanel(this.activePanel.serverId);
        }
        this.updateTitleForPanel(this.activePanel);
      }
    }
  }

  closeTab(tabId: string): void {
    const tab = this.tabs.get(tabId);
    if (!tab) return;

    // Get all panels in tab
    const tabPanels = tab.root.getAllPanels();

    // Close all panels on server and remove from map
    for (const panel of tabPanels) {
      if (panel.serverId !== null) {
        this.sendClosePanel(panel.serverId);
      }
      // Find and delete from panels map
      for (const [id, p] of this.panels) {
        if (p === panel) {
          this.panels.delete(id);
          break;
        }
      }
    }

    // Destroy the split container (will destroy panels)
    tab.root.destroy();
    tab.element.remove();
    this.tabs.delete(tabId);
    this.removeTabUI(tabId);

    // Remove from tab history
    const histIndex = this.tabHistory.indexOf(tabId);
    if (histIndex !== -1) {
      this.tabHistory.splice(histIndex, 1);
    }

    // Switch to last recently used tab if this was active
    if (this.activeTab === tabId) {
      this.activeTab = null;
      this.activePanel = null;
      // Find most recently used tab that still exists
      for (let i = this.tabHistory.length - 1; i >= 0; i--) {
        if (this.tabs.has(this.tabHistory[i])) {
          this.switchToTab(this.tabHistory[i]);
          return;
        }
      }
      // Fallback: switch to any remaining tab
      const remaining = this.tabs.keys().next();
      if (!remaining.done) {
        this.switchToTab(remaining.value);
        return;
      }
    }

    // No tabs left - reset to empty state
    if (this.tabs.size === 0) {
      const appTitle = document.getElementById('app-title');
      if (appTitle) appTitle.textContent = '👻';
    }

    this.updateMenuState();
  }

  closeActivePanel(): void {
    // If quick terminal is visible, close it first
    const quickTerminal = document.getElementById('quick-terminal');
    if (quickTerminal?.classList.contains('visible')) {
      this.toggleQuickTerminal();
      return;
    }

    if (!this.activePanel || !this.activeTab) return;

    const tab = this.tabs.get(this.activeTab);
    if (!tab) return;

    const panels = tab.root.getAllPanels();
    if (panels.length <= 1) {
      // Only one panel - close the whole tab
      this.closeTab(this.activeTab);
      return;
    }

    // Remove panel from split container
    const panelToClose = this.activePanel;
    tab.root.removePanel(panelToClose);

    // Close on server
    if (panelToClose.serverId !== null) {
      this.sendClosePanel(panelToClose.serverId);
    }

    // Remove from panels map
    for (const [id, panel] of this.panels) {
      if (panel === panelToClose) {
        this.panels.delete(id);
        break;
      }
    }

    panelToClose.destroy();

    // Focus remaining panel
    const remainingPanels = tab.root.getAllPanels();
    if (remainingPanels.length > 0) {
      this.setActivePanel(remainingPanels[0]);
    }
  }

  closeAllTabs(): void {
    const tabIds = Array.from(this.tabs.keys());
    if (tabIds.length === 0) return;

    // Close all tabs - frontend will be empty (scale to zero)
    for (const tabId of tabIds) {
      this.closeTab(tabId);
    }
  }

  // ============================================================================
  // Split Management
  // ============================================================================

  splitActivePanel(direction: 'right' | 'down' | 'left' | 'up'): void {
    if (!this.activePanel || !this.activeTab) return;

    const tab = this.tabs.get(this.activeTab);
    if (!tab) return;

    const container = tab.root.findContainer(this.activePanel);
    if (!container) return;

    // Get parent panel's serverId for CWD inheritance
    const inheritCwdFrom = this.activePanel.serverId;

    // INSTANT: Do DOM split immediately
    // New panel created with serverId=null, will get ID when server responds
    const newPanel = this.createPanel(tab.element, null, inheritCwdFrom);
    container.split(direction, newPanel);

    // Focus new panel immediately
    this.setActivePanel(newPanel);

    // ResizeObserver will measure correct size after layout
    // Panel.connect() sends CREATE_PANEL with measured dimensions
  }

  // ============================================================================
  // Tab UI
  // ============================================================================

  private addTabUI(tabId: string, title: string): void {
    if (!this.tabsEl) return;

    const tab = document.createElement('div');
    tab.className = 'tab';
    tab.dataset.id = tabId;

    const tabIndex = this.tabsEl.children.length + 1;
    const hotkeyHint = tabIndex <= 9 ? `⌘${tabIndex}` : '';
    const displayTitle = title || '👻';

    tab.innerHTML = `<span class="close">×</span><span class="title-wrapper"><span class="indicator">•</span><span class="title">${displayTitle}</span></span><span class="hotkey">${hotkeyHint}</span>`;

    tab.addEventListener('click', (e) => {
      if (!(e.target as HTMLElement).classList.contains('close')) {
        this.switchToTab(tabId);
      }
    });

    tab.querySelector('.close')?.addEventListener('click', (e) => {
      e.stopPropagation();
      this.closeTab(tabId);
    });

    this.tabsEl.appendChild(tab);
  }

  private removeTabUI(tabId: string): void {
    const tab = this.tabsEl?.querySelector(`[data-id="${tabId}"]`);
    tab?.remove();
    this.updateHotkeyHints();
  }

  private updateHotkeyHints(): void {
    const tabs = this.tabsEl?.querySelectorAll('.tab');
    tabs?.forEach((tab, index) => {
      const hotkey = tab.querySelector('.hotkey');
      if (hotkey) {
        hotkey.textContent = index < 9 ? `⌘${index + 1}` : '';
      }
    });
  }

  private updateTabUIActive(tabId: string): void {
    if (!this.tabsEl) return;
    for (const tab of Array.from(this.tabsEl.children)) {
      tab.classList.toggle('active', (tab as HTMLElement).dataset.id === tabId);
    }
  }

  private updateTitleForPanel(panel: Panel): void {
    for (const [tabId, tab] of this.tabs) {
      if (tab.root.findContainer(panel)) {
        const tabEl = this.tabsEl?.querySelector(`[data-id="${tabId}"] .title`);
        let title = tabEl?.textContent || '';
        // Ghost emoji means no title set yet
        if (title === '👻') title = '';

        const appTitle = document.getElementById('app-title');
        if (title) {
          document.title = title;
          if (appTitle) appTitle.textContent = title;
        } else {
          document.title = '👻';
          if (appTitle) appTitle.textContent = '👻';
        }
        this.updateIndicatorForPanel(panel, title);
        break;
      }
    }
  }

  private updatePanelTitle(serverId: number, title: string): void {
    let targetPanel: Panel | null = null;
    for (const [, panel] of this.panels) {
      if (panel.serverId === serverId) {
        targetPanel = panel;
        break;
      }
    }
    if (!targetPanel) return;

    const tabId = this.findTabIdForPanel(targetPanel);
    if (tabId !== null) {
      const tabEl = this.tabsEl?.querySelector(`[data-id="${tabId}"] .title`);
      if (tabEl) tabEl.textContent = title;

      const indicatorEl = this.tabsEl?.querySelector(`[data-id="${tabId}"] .indicator`);
      if (indicatorEl) {
        const isAtPrompt = this.isAtPrompt(targetPanel, title);
        indicatorEl.textContent = isAtPrompt ? '•' : '✱';
      }

      const tab = this.tabs.get(tabId);
      if (tab) tab.title = title;
    }

    if (targetPanel === this.activePanel) {
      document.title = title;
      const appTitle = document.getElementById('app-title');
      if (appTitle) appTitle.textContent = title;
      this.updateIndicatorForPanel(targetPanel, title);
    }
  }

  private updatePanelPwd(serverId: number, pwd: string): void {
    let targetPanel: Panel | null = null;
    for (const [, panel] of this.panels) {
      if (panel.serverId === serverId) {
        targetPanel = panel;
        panel.pwd = pwd;
        break;
      }
    }
    if (!targetPanel) return;

    // Update tab indicator to match (both tab and title should show same state)
    const tabId = this.findTabIdForPanel(targetPanel);
    if (tabId !== null) {
      const tab = this.tabs.get(tabId);
      const currentTitle = tab?.title || '';
      const indicatorEl = this.tabsEl?.querySelector(`[data-id="${tabId}"] .indicator`);
      if (indicatorEl) {
        const isAtPrompt = this.isAtPrompt(targetPanel, currentTitle);
        indicatorEl.textContent = isAtPrompt ? '•' : '✱';
      }
    }

    // If this is the active panel, update the title indicator
    if (targetPanel === this.activePanel) {
      const appTitle = document.getElementById('app-title');
      const currentTitle = appTitle ? appTitle.textContent || '' : '';
      this.updateIndicatorForPanel(targetPanel, currentTitle);
    }
  }

  private isAtPrompt(panel: Panel, title: string): boolean {
    if (!panel.pwd || !title) return true;
    const dirName = panel.pwd.split('/').pop() || panel.pwd;
    return title.includes(dirName) || title.includes('/') || title === panel.pwd;
  }

  private findTabIdForPanel(panel: Panel): string | null {
    for (const [tabId, tab] of this.tabs) {
      if (tab.root.findContainer(panel)) return tabId;
    }
    return null;
  }

  private handlePanelBell(serverId: number): void {
    let targetPanel: Panel | null = null;
    for (const [, panel] of this.panels) {
      if (panel.serverId === serverId) {
        targetPanel = panel;
        break;
      }
    }
    if (!targetPanel) return;

    const tabId = this.findTabIdForPanel(targetPanel);
    if (tabId !== null) {
      const tabEl = this.tabsEl?.querySelector(`[data-id="${tabId}"]`);
      if (tabEl && !tabEl.classList.contains('active')) {
        tabEl.classList.add('bell');
        setTimeout(() => tabEl.classList.remove('bell'), 500);
      }
    }

    // Show bell indicator in title bar if this is the active panel
    if (targetPanel === this.activePanel) {
      this.updateTitleIndicator('🔔', '');
      setTimeout(() => {
        if (targetPanel) {
          const appTitle = document.getElementById('app-title');
          this.updateIndicatorForPanel(targetPanel, appTitle?.textContent || '');
        }
      }, 2000);
    }
  }

  private handleNotification(serverId: number, title: string, body: string): void {
    // Find which panel this notification is from
    let targetPanel: Panel | null = null;
    for (const [, panel] of this.panels) {
      if (panel.serverId === serverId) {
        targetPanel = panel;
        break;
      }
    }

    // Check if we have notification permission
    if (Notification.permission === 'granted') {
      this.showBrowserNotification(title, body, targetPanel);
    } else if (Notification.permission !== 'denied') {
      Notification.requestPermission().then(permission => {
        if (permission === 'granted') {
          this.showBrowserNotification(title, body, targetPanel);
        }
      });
    }

    // Also show visual indicator in tab if panel is in a non-active tab
    if (targetPanel) {
      const tabId = this.findTabIdForPanel(targetPanel);
      if (tabId !== null && tabId !== this.activeTab) {
        const tabEl = this.tabsEl?.querySelector(`[data-id="${tabId}"]`);
        if (tabEl) {
          tabEl.classList.add('notification');
          setTimeout(() => tabEl.classList.remove('notification'), 3000);
        }
      }
    }
  }

  private showBrowserNotification(title: string, body: string, panel: Panel | null): void {
    const notificationTitle = title || 'Terminal Notification';
    const notification = new Notification(notificationTitle, {
      body: body,
      tag: `termweb-${panel?.serverId || 'unknown'}`,
    });

    notification.onclick = () => {
      window.focus();
      if (panel) {
        // Find and switch to the tab containing this panel
        const tabId = this.findTabIdForPanel(panel);
        if (tabId) {
          this.switchToTab(tabId);
          this.setActivePanel(panel);
        }
      }
      notification.close();
    };

    // Auto-close after 5 seconds
    setTimeout(() => notification.close(), 5000);
  }

  private updateTitleIndicator(indicator: string, stateIndicator?: string): void {
    const el = document.getElementById('title-indicator');
    if (el) el.innerHTML = indicator;
    const elState = document.getElementById('title-state-indicator');
    if (elState && stateIndicator !== undefined) elState.innerHTML = stateIndicator;
  }

  private updateIndicatorForPanel(panel: Panel, title: string): void {
    // Format: folder + indicator (• at prompt, ✱ running)
    const isAtPrompt = this.isAtPrompt(panel, title);
    const stateIndicator = isAtPrompt ? '•' : '✱';
    const indicator = panel.pwd ? '📁' : '';
    this.updateTitleIndicator(indicator, stateIndicator);
  }

  // ============================================================================
  // Tab Overview
  // ============================================================================

  showTabOverview(): void {
    const overlay = document.getElementById('tab-overview');
    const grid = document.getElementById('tab-overview-grid');
    if (!overlay || !grid || !this.panelsEl) return;

    grid.innerHTML = '';
    this.tabOverviewTabs = [];

    // Disable resize observers
    for (const [, panel] of this.panels) {
      panel.resizeObserver?.disconnect();
    }

    const panelsRect = this.panelsEl.getBoundingClientRect();
    const aspectRatio = panelsRect.width / panelsRect.height;
    const previewHeight = 200;
    const previewWidth = Math.round(previewHeight * aspectRatio);
    const scale = Math.min(previewWidth / panelsRect.width, previewHeight / panelsRect.height);
    const scaledWidth = panelsRect.width * scale;
    const scaledHeight = panelsRect.height * scale;

    for (const [tabId, tab] of this.tabs) {
      const preview = document.createElement('div');
      preview.className = 'tab-preview';
      preview.style.cssText = `width: ${scaledWidth}px; height: ${scaledHeight + 44}px;`;
      if (tabId === this.activeTab) {
        preview.classList.add('active');
      }

      const content = document.createElement('div');
      content.className = 'tab-preview-content';
      content.style.cssText = `overflow: hidden; position: relative; width: ${scaledWidth}px; height: ${scaledHeight}px;`;

      const scaleWrapper = document.createElement('div');
      scaleWrapper.style.cssText = `
        width: ${panelsRect.width}px;
        height: ${panelsRect.height}px;
        transform: scale(${scale});
        transform-origin: top left;
        pointer-events: none;
        position: absolute;
        top: 0;
        left: 0;
      `;

      tab.element.style.display = 'flex';
      tab.element.style.position = 'relative';
      tab.element.style.width = '100%';
      tab.element.style.height = '100%';
      scaleWrapper.appendChild(tab.element);
      content.appendChild(scaleWrapper);

      this.tabOverviewTabs.push({ tabId, tab, element: tab.element });

      const titleBar = document.createElement('div');
      titleBar.className = 'tab-preview-title';

      // Calculate indicator based on whether command is running
      const panels = tab.root.getAllPanels();
      const firstPanel = panels[0];
      const isAtPrompt = firstPanel ? this.isAtPrompt(firstPanel, tab.title) : true;
      const indicator = isAtPrompt ? '•' : '✱';

      titleBar.innerHTML = `
        <span class="tab-preview-close">✕</span>
        <span class="tab-preview-title-text">
          <span class="tab-preview-indicator">${indicator}</span>
          <span class="tab-preview-title-label">${tab.title || '👻'}</span>
        </span>
        <span class="tab-preview-spacer"></span>
      `;

      titleBar.querySelector('.tab-preview-close')?.addEventListener('click', (e) => {
        e.stopPropagation();
        this.restoreTabsFromOverview();
        this.closeTab(tabId);
        if (this.tabs.size > 0) {
          this.showTabOverview();
        } else {
          this.hideTabOverview();
        }
      });

      preview.appendChild(titleBar);
      preview.appendChild(content);

      preview.addEventListener('click', () => {
        this.hideTabOverview();
        this.switchToTab(tabId);
      });

      grid.appendChild(preview);
    }

    // Add new tab button
    const newTabCard = document.createElement('div');
    newTabCard.className = 'tab-preview-new';
    newTabCard.style.cssText = `width: ${scaledWidth}px; height: ${scaledHeight + 44}px;`;
    newTabCard.innerHTML = '<span class="tab-preview-new-icon">+</span>';
    newTabCard.addEventListener('click', () => {
      this.hideTabOverview();
      this.createTab();
    });
    grid.appendChild(newTabCard);

    overlay.classList.add('visible');

    // Clean up any existing handlers before adding new ones
    if (this.tabOverviewCloseHandler) {
      document.removeEventListener('keydown', this.tabOverviewCloseHandler);
      overlay.removeEventListener('click', this.tabOverviewCloseHandler);
    }

    this.tabOverviewCloseHandler = (e: KeyboardEvent | MouseEvent) => {
      if ((e as KeyboardEvent).key === 'Escape' || e.target === overlay) {
        this.hideTabOverview();
      }
    };
    document.addEventListener('keydown', this.tabOverviewCloseHandler);
    overlay.addEventListener('click', this.tabOverviewCloseHandler);
  }

  private restoreTabsFromOverview(): void {
    if (!this.tabOverviewTabs || !this.panelsEl) return;

    for (const { element } of this.tabOverviewTabs) {
      element.style.display = '';
      element.style.position = '';
      element.style.width = '';
      element.style.height = '';
      this.panelsEl.appendChild(element);
    }
    this.tabOverviewTabs = null;

    // Re-enable resize observers
    for (const [, panel] of this.panels) {
      if (panel.resizeObserver && panel.element) {
        panel.resizeObserver.observe(panel.element);
      }
    }
  }

  hideTabOverview(): void {
    this.restoreTabsFromOverview();

    const overlay = document.getElementById('tab-overview');
    if (overlay) {
      overlay.classList.remove('visible');
      const grid = document.getElementById('tab-overview-grid');
      if (grid) grid.innerHTML = '';

      if (this.tabOverviewCloseHandler) {
        document.removeEventListener('keydown', this.tabOverviewCloseHandler);
        overlay.removeEventListener('click', this.tabOverviewCloseHandler);
        this.tabOverviewCloseHandler = null;
      }
    }

    if (this.activeTab !== null) {
      const tab = this.tabs.get(this.activeTab);
      if (tab) {
        for (const [, t] of this.tabs) {
          t.element.classList.remove('active');
        }
        tab.element.classList.add('active');
      }
    }

    this.activePanel?.focus();
  }

  // ============================================================================
  // Command Execution
  // ============================================================================

  private executeCommand(action: string): void {
    // Handle local commands (starting with _)
    if (action.startsWith('_')) {
      switch (action) {
        case '_new_tab':
          this.createTab();
          break;
        case '_close_tab':
          this.closeActivePanel();
          break;
        case '_show_all_tabs':
          this.showTabOverview();
          break;
        case '_split_right':
          this.splitActivePanel('right');
          break;
        case '_split_down':
          this.splitActivePanel('down');
          break;
        case '_split_left':
          this.splitActivePanel('left');
          break;
        case '_split_up':
          this.splitActivePanel('up');
          break;
        case '_toggle_inspector':
          this.activePanel?.toggleInspector?.();
          break;
        case '_change_title':
          this.promptChangeTitle();
          break;
      }
      return;
    }

    // Send view action to server
    if (this.activePanel && this.activePanel.serverId !== null) {
      this.sendViewAction(this.activePanel.serverId, action);
    }
  }

  private handleViewAction(panel: Panel, action: string, data?: unknown): void {
    const panelId = (data as { panelId?: number })?.panelId ?? panel.serverId;
    if (panelId === null || panelId === undefined) return;

    if (action === 'inspector_subscribe' || action === 'inspector_unsubscribe') {
      this.sendInspectorSubscribe(panelId, action === 'inspector_subscribe');
    }
  }

  private sendInspectorSubscribe(panelId: number, subscribe: boolean): void {
    if (!this.controlWs || this.controlWs.readyState !== WebSocket.OPEN) return;

    // Format: [type:u8][panel_id:u32][tab_len:u8][tab...]
    // For subscribe: include empty tab (tab_len=0)
    // For unsubscribe: just [type:u8][panel_id:u32]
    const buf = new ArrayBuffer(subscribe ? 6 : 5);
    const view = new DataView(buf);
    view.setUint8(0, subscribe ? BinaryCtrlMsg.INSPECTOR_SUBSCRIBE : BinaryCtrlMsg.INSPECTOR_UNSUBSCRIBE);
    view.setUint32(1, panelId, true);
    if (subscribe) {
      view.setUint8(5, 0); // Empty tab name (use default)
    }
    this.controlWs.send(buf);
  }

  // ============================================================================
  // Server Communication
  // ============================================================================

  private sendFocusPanel(serverId: number): void {
    if (this.controlWs?.readyState === WebSocket.OPEN) {
      this.controlWs.send(JSON.stringify({
        type: 'focus_panel',
        panel_id: serverId
      }));
    }
  }

  private sendClosePanel(serverId: number): void {
    if (this.controlWs?.readyState === WebSocket.OPEN) {
      this.controlWs.send(JSON.stringify({
        type: 'close_panel',
        panel_id: serverId
      }));
    }
  }

  private sendViewAction(serverId: number, action: string): void {
    if (this.controlWs?.readyState === WebSocket.OPEN) {
      this.controlWs.send(JSON.stringify({
        type: 'view_action',
        panel_id: serverId,
        action
      }));
    }
  }

  // ============================================================================
  // File Transfer
  // ============================================================================

  requestDownload(options: DownloadOptions): void {
    if (!this.activePanel?.serverId) {
      console.error('No active panel for download');
      return;
    }

    let { path, preview } = options;
    let isFolder = false;

    if (path.endsWith('/')) {
      isFolder = true;
      path = path.slice(0, -1);
    }

    const panelId = this.activePanel.serverId;
    const pathBytes = new TextEncoder().encode(path);

    // Message format: type(1) + panelId(4) + pathLen(2) + path
    const msgLen = 1 + 4 + 2 + pathBytes.length;
    const msg = new ArrayBuffer(msgLen);
    const view = new DataView(msg);
    const bytes = new Uint8Array(msg);

    let offset = 0;

    if (preview) {
      // Send preview request (0x17 for file, 0x18 for folder)
      this.pendingDownload = { ...options, path }; // Store for later use
      view.setUint8(offset, isFolder ? 0x18 : 0x17); offset += 1;
    } else {
      // Send actual download request (0x11 for file, 0x14 for folder)
      view.setUint8(offset, isFolder ? 0x14 : 0x11); offset += 1;
    }

    view.setUint32(offset, panelId, true); offset += 4;
    view.setUint16(offset, pathBytes.length, true); offset += 2;
    bytes.set(pathBytes, offset);

    this.controlWs?.send(msg);
    console.log(`Requesting ${preview ? 'preview' : 'download'} for ${isFolder ? 'folder' : 'file'}: ${path}`);
  }

  private uploadFile(file: File): void {
    if (!this.activePanel?.serverId) {
      console.error('No active panel for upload');
      return;
    }

    const reader = new FileReader();
    reader.onload = () => {
      const data = new Uint8Array(reader.result as ArrayBuffer);
      const pathBytes = new TextEncoder().encode(file.name);

      const msgLen = 1 + 4 + 2 + pathBytes.length + 4 + data.length;
      const msg = new ArrayBuffer(msgLen);
      const view = new DataView(msg);
      const bytes = new Uint8Array(msg);

      let offset = 0;
      view.setUint8(offset, 0x10); offset += 1; // UPLOAD_FILE
      view.setUint32(offset, this.activePanel!.serverId!, true); offset += 4;
      view.setUint16(offset, pathBytes.length, true); offset += 2;
      bytes.set(pathBytes, offset); offset += pathBytes.length;
      view.setUint32(offset, data.length, true); offset += 4;
      bytes.set(data, offset);

      this.controlWs?.send(msg);
      console.log(`Uploading ${file.name}: ${formatBytes(file.size)}`);
    };
    reader.readAsArrayBuffer(file);
  }

  // ============================================================================
  // Auth
  // ============================================================================

  private setupAccessControlCallbacks(): void {
    this.accessControlDialog.onSetPassword = (password) => this.sendSetPassword(password);
    this.accessControlDialog.onCreateSession = (id, name) => this.sendCreateSession(id, name);
    this.accessControlDialog.onRegenerateToken = (sessionId, tokenType) => this.sendRegenerateToken(sessionId, tokenType);
    this.accessControlDialog.onCreateShareLink = (tokenType) => this.sendCreateShareLink(tokenType);
    this.accessControlDialog.onRevokeShareLink = (token) => this.sendRevokeShareLink(token);
    this.accessControlDialog.onRevokeAllShares = () => this.sendRevokeAllShares();
  }

  private handleSessionList(sessions: typeof this.sessions): void {
    this.sessions = sessions;
    this.accessControlDialog.updateSessions(sessions);
  }

  private handleShareLinks(links: typeof this.shareLinks): void {
    this.shareLinks = links;
    this.accessControlDialog.updateShareLinks(links);
  }

  private sendGetAuthState(): void {
    if (this.controlWs?.readyState === WebSocket.OPEN) {
      this.controlWs.send(new Uint8Array([0x90]));
    }
  }

  private sendSetPassword(password: string): void {
    if (this.controlWs?.readyState === WebSocket.OPEN) {
      const pwdBytes = new TextEncoder().encode(password);
      const msg = new Uint8Array(3 + pwdBytes.length);
      msg[0] = 0x91;
      new DataView(msg.buffer).setUint16(1, pwdBytes.length, true);
      msg.set(pwdBytes, 3);
      this.controlWs.send(msg);
    }
  }

  private sendCreateSession(id: string, name: string): void {
    if (this.controlWs?.readyState === WebSocket.OPEN) {
      const idBytes = new TextEncoder().encode(id);
      const nameBytes = new TextEncoder().encode(name);
      const msg = new Uint8Array(5 + idBytes.length + nameBytes.length);
      msg[0] = 0x93;
      const view = new DataView(msg.buffer);
      view.setUint16(1, idBytes.length, true);
      view.setUint16(3, nameBytes.length, true);
      msg.set(idBytes, 5);
      msg.set(nameBytes, 5 + idBytes.length);
      this.controlWs.send(msg);
    }
  }

  private sendRegenerateToken(sessionId: string, tokenType: number): void {
    if (this.controlWs?.readyState === WebSocket.OPEN) {
      const idBytes = new TextEncoder().encode(sessionId);
      const msg = new Uint8Array(4 + idBytes.length);
      msg[0] = 0x95;
      new DataView(msg.buffer).setUint16(1, idBytes.length, true);
      msg[3] = tokenType;
      msg.set(idBytes, 4);
      this.controlWs.send(msg);
    }
  }

  private sendCreateShareLink(tokenType: number): void {
    if (this.controlWs?.readyState === WebSocket.OPEN) {
      this.controlWs.send(new Uint8Array([0x96, tokenType]));
    }
  }

  private sendRevokeShareLink(token: string): void {
    if (this.controlWs?.readyState === WebSocket.OPEN) {
      const tokenBytes = new TextEncoder().encode(token);
      const msg = new Uint8Array(1 + tokenBytes.length);
      msg[0] = 0x97;
      msg.set(tokenBytes, 1);
      this.controlWs.send(msg);
    }
  }

  private sendRevokeAllShares(): void {
    if (this.controlWs?.readyState === WebSocket.OPEN) {
      this.controlWs.send(new Uint8Array([0x98]));
    }
  }

  // ============================================================================
  // UI Helpers
  // ============================================================================

  private promptChangeTitle(): void {
    const tab = this.tabs.get(this.activeTab!);
    const currentTitle = tab?.title || '';

    const newTitle = prompt('Enter new title:', currentTitle);
    if (newTitle !== null && this.activePanel && this.activePanel.serverId !== null) {
      this.sendViewAction(this.activePanel.serverId, `set_title:${newTitle}`);
      if (tab) {
        tab.title = newTitle;
        const tabEl = this.tabsEl?.querySelector(`[data-id="${this.activeTab}"] .title`);
        if (tabEl) tabEl.textContent = newTitle || '👻';
        document.title = newTitle || '👻';
        const appTitle = document.getElementById('app-title');
        if (appTitle) appTitle.textContent = newTitle || '👻';
      }
    }
  }

  showCommandPalette(): void {
    this.commandPalette.show(this.tabs.size > 0, this.activePanel !== null);
  }

  showUploadDialog(): void {
    this.uploadDialog.show();
  }

  showDownloadDialog(): void {
    this.downloadDialog.show();
  }

  showAccessControlDialog(): void {
    this.sendGetAuthState();
    this.accessControlDialog.show();
  }


  // ============================================================================
  // Keyboard Shortcuts
  // ============================================================================

  private setupShortcuts(): void {
    document.addEventListener('keydown', (e) => {
      // Skip if dialog is open
      const commandPalette = document.getElementById('command-palette');
      const downloadDialog = document.getElementById('download-dialog');
      if ((commandPalette?.classList.contains('visible')) ||
          (downloadDialog?.classList.contains('visible'))) {
        return;
      }

      // ⌘1-9 to switch tabs
      if (e.metaKey && e.key >= '1' && e.key <= '9') {
        e.preventDefault();
        e.stopPropagation();
        const index = parseInt(e.key) - 1;
        const tabIds = Array.from(this.tabs.keys());
        if (index < tabIds.length) {
          this.switchToTab(tabIds[index]);
        }
        return;
      }

      // ⌘/ for new tab
      if (e.metaKey && e.key === '/') {
        e.preventDefault();
        e.stopPropagation();
        this.createTab();
        return;
      }

      // ⌘. to close tab/split
      if (e.metaKey && !e.shiftKey && e.key === '.') {
        e.preventDefault();
        e.stopPropagation();
        this.closeActivePanel();
        return;
      }

      // ⌘⇧. to close all tabs
      if (e.metaKey && e.shiftKey && (e.key === '>' || e.key === '.')) {
        e.preventDefault();
        e.stopPropagation();
        this.closeAllTabs();
        return;
      }

      // ⌘⇧A to show all tabs
      if (e.metaKey && e.shiftKey && (e.key === 'a' || e.key === 'A')) {
        e.preventDefault();
        e.stopPropagation();
        this.showTabOverview();
        return;
      }

      // ⌘⇧P to show command palette
      if (e.metaKey && e.shiftKey && (e.key === 'p' || e.key === 'P')) {
        e.preventDefault();
        e.stopPropagation();
        this.showCommandPalette();
        return;
      }

      // ⌘U for upload
      if (e.metaKey && !e.shiftKey && (e.key === 'u' || e.key === 'U')) {
        e.preventDefault();
        e.stopPropagation();
        this.showUploadDialog();
        return;
      }

      // ⌘⇧S for download
      if (e.metaKey && e.shiftKey && (e.key === 's' || e.key === 'S')) {
        e.preventDefault();
        e.stopPropagation();
        this.showDownloadDialog();
        return;
      }

      // ⌘D for split right
      if (e.metaKey && !e.shiftKey && (e.key === 'd' || e.key === 'D')) {
        e.preventDefault();
        e.stopPropagation();
        this.splitActivePanel('right');
        return;
      }

      // ⌘⇧D for split down
      if (e.metaKey && e.shiftKey && (e.key === 'd' || e.key === 'D')) {
        e.preventDefault();
        e.stopPropagation();
        this.splitActivePanel('down');
        return;
      }

      // ⌘⇧F for toggle fullscreen (hide title/tabbar)
      if (e.metaKey && e.shiftKey && (e.key === 'f' || e.key === 'F')) {
        e.preventDefault();
        e.stopPropagation();
        this.toggleFullscreen();
        return;
      }

      // ⌘⇧Enter for zoom split
      if (e.metaKey && e.shiftKey && e.key === 'Enter') {
        e.preventDefault();
        e.stopPropagation();
        this.zoomSplit();
        return;
      }

      // ⌘A for select all
      if (e.metaKey && !e.shiftKey && e.key === 'a') {
        e.preventDefault();
        e.stopPropagation();
        if (this.activePanel?.serverId !== null) {
          this.sendViewAction(this.activePanel!.serverId!, 'select_all');
        }
        return;
      }

      // ⌘C for copy
      if (e.metaKey && !e.shiftKey && (e.key === 'c' || e.key === 'C')) {
        e.preventDefault();
        e.stopPropagation();
        if (this.activePanel?.serverId !== null) {
          this.sendViewAction(this.activePanel!.serverId!, 'copy_to_clipboard');
        }
        return;
      }

      // ⌘V for paste from system clipboard
      if (e.metaKey && !e.shiftKey && e.key === 'v') {
        e.preventDefault();
        e.stopPropagation();
        navigator.clipboard.readText().then(text => {
          if (this.activePanel) {
            this.activePanel.sendTextInput(text);
          }
        });
        return;
      }

      // ⌘⇧V for paste selection
      if (e.metaKey && e.shiftKey && e.key === 'v') {
        e.preventDefault();
        e.stopPropagation();
        if (this.activePanel?.serverId !== null) {
          this.sendViewAction(this.activePanel!.serverId!, 'paste_from_selection');
        }
        return;
      }

      // Font size shortcuts ⌘-/+/0
      if (e.metaKey && (e.key === '-' || e.key === '=' || e.key === '0')) {
        e.preventDefault();
        e.stopPropagation();
        if (this.activePanel?.serverId !== null) {
          if (e.key === '=') this.sendViewAction(this.activePanel!.serverId!, 'increase_font_size:1');
          else if (e.key === '-') this.sendViewAction(this.activePanel!.serverId!, 'decrease_font_size:1');
          else if (e.key === '0') this.sendViewAction(this.activePanel!.serverId!, 'reset_font_size');
        }
        return;
      }

      // ⌘⌥I to toggle inspector
      if (e.metaKey && e.altKey && e.code === 'KeyI') {
        e.preventDefault();
        e.stopPropagation();
        this.toggleInspector();
        return;
      }

      // ⌘` for quick terminal
      if (e.metaKey && e.key === '`') {
        e.preventDefault();
        e.stopPropagation();
        this.toggleQuickTerminal();
        return;
      }

      // ⌘⇧Arrow to select split in direction
      if (e.metaKey && e.shiftKey && ['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown'].includes(e.key)) {
        e.preventDefault();
        e.stopPropagation();
        const dir = e.key.replace('Arrow', '').toLowerCase() as 'up' | 'down' | 'left' | 'right';
        this.selectSplitDirection(dir);
        return;
      }

      // ⌘] and ⌘[ to cycle through splits
      if (e.metaKey && (e.key === ']' || e.key === '[')) {
        e.preventDefault();
        e.stopPropagation();
        if (e.key === ']') this.selectNextSplit();
        else this.selectPreviousSplit();
        return;
      }

      // Forward all other keys to active panel
      if (this.activePanel) {
        e.preventDefault();
        // Apply sticky modifiers from accessory bar
        const modEvent = this.applyingStickyModifiers(e);
        this.activePanel.sendKeyInput(modEvent, 1); // press
      }
    }, true); // capture phase

    // Also capture keyup at document level
    document.addEventListener('keyup', (e) => {
      if (e.metaKey) return;
      if (this.activePanel) {
        e.preventDefault();
        const modEvent = this.applyingStickyModifiers(e);
        this.activePanel.sendKeyInput(modEvent, 0); // release
        // Clear sticky modifiers after key release
        this.clearStickyModifiers();
      }
    }, true);

    // Handle paste at document level
    document.addEventListener('paste', (e) => {
      // Skip if dialog is open
      const commandPalette = document.getElementById('command-palette');
      const downloadDialog = document.getElementById('download-dialog');
      if ((commandPalette?.classList.contains('visible')) ||
          (downloadDialog?.classList.contains('visible'))) {
        return;
      }

      e.preventDefault();
      const text = e.clipboardData?.getData('text');
      if (text && this.activePanel) {
        this.activePanel.sendTextInput(text);
      }
    });
  }

  private toggleInspector(): void {
    this.activePanel?.toggleInspector();
  }

  toggleQuickTerminal(): void {
    const container = document.getElementById('quick-terminal');
    if (!container) return;

    if (container.classList.contains('visible')) {
      container.classList.remove('visible');
      if (this.previousActivePanel) {
        this.setActivePanel(this.previousActivePanel);
        this.previousActivePanel = null;
      }
    } else {
      container.classList.add('visible');
      this.previousActivePanel = this.activePanel;
      if (!this.quickTerminalPanel) {
        const content = container.querySelector('.quick-terminal-content');
        if (content) {
          content.innerHTML = '';
          // Inherit CWD from the previously active panel
          const inheritCwdFrom = this.previousActivePanel?.serverId ?? null;
          this.quickTerminalPanel = this.createPanel(content as HTMLElement, null, inheritCwdFrom);
        }
      }
      if (this.quickTerminalPanel) {
        this.setActivePanel(this.quickTerminalPanel);
      }
    }
  }

  // ============================================================================
  // Menus
  // ============================================================================

  private setupMenus(): void {
    const isTouchDevice = () => !window.matchMedia('(hover: hover)').matches;

    // Touch devices: click to toggle menu dropdown
    document.querySelectorAll('.menu-label').forEach(label => {
      label.addEventListener('click', (e) => {
        if (!isTouchDevice()) return;
        e.stopPropagation();
        const menu = label.parentElement;
        const wasOpen = menu?.classList.contains('open');
        // Close all menus
        document.querySelectorAll('.menu').forEach(m => m.classList.remove('open'));
        // Toggle this one
        if (!wasOpen) menu?.classList.add('open');
      });
    });

    // Touch devices: tap to toggle submenu
    document.querySelectorAll('.menu-submenu').forEach(submenu => {
      submenu.addEventListener('click', (e) => {
        if (!isTouchDevice()) return;
        e.stopPropagation();
        const wasOpen = submenu.classList.contains('open');
        // Close all submenus
        document.querySelectorAll('.menu-submenu').forEach(s => s.classList.remove('open'));
        // Toggle this one
        if (!wasOpen) submenu.classList.add('open');
      });
    });

    // Adjust submenu position to stay on screen (only when visible)
    const adjustSubmenuPosition = (submenu: Element) => {
      const dropdown = submenu.querySelector('.menu-dropdown') as HTMLElement;
      if (!dropdown) return;
      // Only adjust if dropdown is visible
      const style = window.getComputedStyle(dropdown);
      if (style.display === 'none') return;
      // Reset position
      dropdown.style.left = '';
      dropdown.style.right = '100%';
      dropdown.style.top = '-4px';
      dropdown.style.bottom = '';
      // Check bounds after a frame
      requestAnimationFrame(() => {
        const rect = dropdown.getBoundingClientRect();
        // If goes off left edge, show on right side
        if (rect.left < 0) {
          dropdown.style.right = '';
          dropdown.style.left = '100%';
        }
        // If goes off bottom edge, align to bottom
        if (rect.bottom > window.innerHeight) {
          dropdown.style.top = '';
          dropdown.style.bottom = '0';
        }
      });
    };

    // Use mouseover (bubbles) to catch when dropdown becomes visible
    document.querySelectorAll('.menu-submenu').forEach(submenu => {
      submenu.addEventListener('mouseover', () => adjustSubmenuPosition(submenu));
    });

    // Close menus when clicking outside
    document.addEventListener('click', () => {
      document.querySelectorAll('.menu').forEach(m => m.classList.remove('open'));
      document.querySelectorAll('.menu-submenu').forEach(s => s.classList.remove('open'));
      document.getElementById('menubar')?.classList.remove('open');
    });

    // Hamburger menu toggle
    const hamburger = document.getElementById('hamburger');
    if (hamburger) {
      hamburger.addEventListener('click', (e) => {
        e.stopPropagation();
        document.getElementById('menubar')?.classList.toggle('open');
      });
    }

    // Menu item actions
    document.querySelectorAll('.menu-item').forEach(item => {
      item.addEventListener('click', () => {
        const action = (item as HTMLElement).dataset.action;
        if (!action) return;

        // Close menu after action
        document.querySelectorAll('.menu').forEach(m => m.classList.remove('open'));
        document.getElementById('menubar')?.classList.remove('open');

        switch (action) {
          case 'new-tab':
            this.createTab();
            break;
          case 'close-tab':
            this.closeActivePanel();
            break;
          case 'close-all-tabs':
            this.closeAllTabs();
            break;
          case 'upload':
            this.showUploadDialog();
            break;
          case 'download':
            this.showDownloadDialog();
            break;
          case 'sessions':
          case 'access-control':
            this.showAccessControlDialog();
            break;
          case 'split-right':
            this.splitActivePanel('right');
            break;
          case 'split-down':
            this.splitActivePanel('down');
            break;
          case 'split-left':
            this.splitActivePanel('left');
            break;
          case 'split-up':
            this.splitActivePanel('up');
            break;
          case 'quick-terminal':
            this.toggleQuickTerminal();
            break;
          case 'show-all-tabs':
            this.showTabOverview();
            break;
          case 'toggle-inspector':
            this.toggleInspector();
            break;
          case 'copy':
            if (this.activePanel?.serverId !== null) {
              this.sendViewAction(this.activePanel!.serverId!, 'copy_to_clipboard');
            }
            break;
          case 'paste':
            navigator.clipboard.readText().then(text => {
              if (this.activePanel) {
                this.activePanel.sendTextInput(text);
              }
            });
            break;
          case 'paste-selection':
            if (this.activePanel?.serverId !== null) {
              this.sendViewAction(this.activePanel!.serverId!, 'paste_from_selection');
            }
            break;
          case 'select-all':
            if (this.activePanel?.serverId !== null) {
              this.sendViewAction(this.activePanel!.serverId!, 'select_all');
            }
            break;
          case 'zoom-in':
            if (this.activePanel?.serverId !== null) {
              this.sendViewAction(this.activePanel!.serverId!, 'increase_font_size:1');
            }
            break;
          case 'zoom-out':
            if (this.activePanel?.serverId !== null) {
              this.sendViewAction(this.activePanel!.serverId!, 'decrease_font_size:1');
            }
            break;
          case 'zoom-reset':
            if (this.activePanel?.serverId !== null) {
              this.sendViewAction(this.activePanel!.serverId!, 'reset_font_size');
            }
            break;
          case 'command-palette':
            this.showCommandPalette();
            break;
          case 'change-title':
            this.promptChangeTitle();
            break;
          // Window menu actions
          case 'toggle-fullscreen':
            this.toggleFullscreen();
            break;
          case 'previous-tab':
            this.switchToPreviousTab();
            break;
          case 'next-tab':
            this.switchToNextTab();
            break;
          case 'zoom-split':
            this.zoomSplit();
            break;
          case 'previous-split':
            this.selectPreviousSplit();
            break;
          case 'next-split':
            this.selectNextSplit();
            break;
          case 'select-split-above':
            this.selectSplitDirection('up');
            break;
          case 'select-split-below':
            this.selectSplitDirection('down');
            break;
          case 'select-split-left':
            this.selectSplitDirection('left');
            break;
          case 'select-split-right':
            this.selectSplitDirection('right');
            break;
          case 'equalize-splits':
            this.equalizeSplits();
            break;
          case 'resize-split-up':
            this.resizeSplit('up');
            break;
          case 'resize-split-down':
            this.resizeSplit('down');
            break;
          case 'resize-split-left':
            this.resizeSplit('left');
            break;
          case 'resize-split-right':
            this.resizeSplit('right');
            break;
        }
        // Handle dynamic tab selection (tab-id-xxx)
        if (action.startsWith('select-tab-')) {
          const tabId = action.replace('select-tab-', '');
          this.switchToTab(tabId);
        }
      });
    });

    // Populate window tab list and update split menu visibility on menu hover
    const windowMenu = document.querySelector('.menu-label + .menu-dropdown #window-tab-list')?.closest('.menu');
    windowMenu?.addEventListener('mouseenter', () => {
      this.populateWindowTabList();
      this.updateSplitMenuVisibility();
    });
  }

  private updateSplitMenuVisibility(): void {
    const tab = this.activeTab ? this.tabs.get(this.activeTab) : null;
    const panelCount = tab?.root?.getAllPanels().length ?? 0;
    const hasSplits = panelCount > 1;
    document.querySelectorAll('.split-menu-item').forEach(item => {
      item.classList.toggle('visible', hasSplits);
    });
  }

  // Update menu item enabled/disabled state based on current tabs
  private updateMenuState(): void {
    const hasTabs = this.tabs.size > 0;
    const hasActivePanel = this.activePanel !== null;

    // Actions that require at least one tab
    const requiresTab = [
      'close-tab', 'close-all-tabs', 'show-all-tabs',
      'previous-tab', 'next-tab', 'change-title'
    ];

    // Actions that require an active panel
    const requiresPanel = [
      'upload', 'download',
      'split-right', 'split-down', 'split-left', 'split-up',
      'copy', 'paste', 'paste-selection', 'select-all',
      'zoom-in', 'zoom-out', 'zoom-reset',
      'toggle-inspector',
      'zoom-split', 'previous-split', 'next-split',
      'select-split-above', 'select-split-below', 'select-split-left', 'select-split-right',
      'equalize-splits', 'resize-split-up', 'resize-split-down', 'resize-split-left', 'resize-split-right'
    ];

    document.querySelectorAll('.menu-item[data-action]').forEach(item => {
      const action = (item as HTMLElement).dataset.action;
      if (!action) return;

      let disabled = false;
      if (requiresTab.includes(action)) {
        disabled = !hasTabs;
      } else if (requiresPanel.includes(action)) {
        disabled = !hasActivePanel;
      }

      item.classList.toggle('disabled', disabled);
    });
  }

  private populateWindowTabList(): void {
    const tabListEl = document.getElementById('window-tab-list');
    if (!tabListEl) return;

    tabListEl.innerHTML = '';
    let index = 1;
    for (const [tabId, tab] of this.tabs) {
      const item = document.createElement('div');
      item.className = 'menu-item';
      item.dataset.action = `select-tab-${tabId}`;
      const shortcut = index <= 9 ? `<span class="shortcut">⌘${index}</span>` : '';
      const activeMarker = tabId === this.activeTab ? '• ' : '';
      item.innerHTML = `<span class="menu-icon">${activeMarker}</span><span class="menu-text">${tab.title || 'Terminal'}</span>${shortcut}`;
      item.addEventListener('click', () => {
        this.switchToTab(tabId);
        document.querySelectorAll('.menu').forEach(m => m.classList.remove('open'));
      });
      tabListEl.appendChild(item);
      index++;
    }
  }

  private toggleFullscreen(): void {
    const titlebar = document.getElementById('titlebar');
    const toolbar = document.getElementById('toolbar');
    const isFullscreen = document.body.classList.toggle('fullscreen');
    if (titlebar) titlebar.style.display = isFullscreen ? 'none' : '';
    if (toolbar) toolbar.style.display = isFullscreen ? 'none' : '';
    // Trigger resize for panels to reclaim space
    window.dispatchEvent(new Event('resize'));
  }

  private switchToPreviousTab(): void {
    const tabIds = Array.from(this.tabs.keys());
    if (tabIds.length < 2 || !this.activeTab) return;
    const currentIndex = tabIds.indexOf(this.activeTab);
    const prevIndex = (currentIndex - 1 + tabIds.length) % tabIds.length;
    this.switchToTab(tabIds[prevIndex]);
  }

  private switchToNextTab(): void {
    const tabIds = Array.from(this.tabs.keys());
    if (tabIds.length < 2 || !this.activeTab) return;
    const currentIndex = tabIds.indexOf(this.activeTab);
    const nextIndex = (currentIndex + 1) % tabIds.length;
    this.switchToTab(tabIds[nextIndex]);
  }

  private zoomSplit(): void {
    // Toggle zoom - make active panel fill the entire tab (hide other splits)
    if (!this.activeTab || !this.activePanel) return;
    const tab = this.tabs.get(this.activeTab);
    if (!tab) return;

    const container = tab.root.element;
    const isZoomed = container.classList.toggle('zoomed');

    if (isZoomed) {
      // Store which panel is zoomed
      container.dataset.zoomedPanel = this.activePanel.id;

      // Hide all split-panes and dividers
      container.querySelectorAll('.split-pane').forEach((pane: Element) => {
        (pane as HTMLElement).dataset.zoomStyle = (pane as HTMLElement).style.cssText;
        (pane as HTMLElement).style.display = 'none';
      });
      container.querySelectorAll('.split-divider').forEach((d: Element) => {
        (d as HTMLElement).style.display = 'none';
      });

      // Show the active panel's container chain and make it fill
      const activeEl = this.activePanel.element;
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
      // Force ResizeObserver to fire by toggling a style
      const allPanels = tab.root.getAllPanels();
      for (const panel of allPanels) {
        const el = panel.element;
        el.style.visibility = 'hidden';
        el.offsetHeight; // Force reflow
        el.style.visibility = '';
      }
    });
  }

  private selectPreviousSplit(): void {
    if (this.activeTab) {
      const tab = this.tabs.get(this.activeTab);
      const panels = tab?.root?.getAllPanels?.() || [];
      if (panels.length < 2 || !this.activePanel) return;
      const currentIndex = panels.findIndex(p => p.id === this.activePanel?.id);
      const prevIndex = (currentIndex - 1 + panels.length) % panels.length;
      this.setActivePanel(panels[prevIndex]);
    }
  }

  private selectNextSplit(): void {
    if (this.activeTab) {
      const tab = this.tabs.get(this.activeTab);
      const panels = tab?.root?.getAllPanels?.() || [];
      if (panels.length < 2 || !this.activePanel) return;
      const currentIndex = panels.findIndex(p => p.id === this.activePanel?.id);
      const nextIndex = (currentIndex + 1) % panels.length;
      this.setActivePanel(panels[nextIndex]);
    }
  }

  private selectSplitDirection(direction: 'up' | 'down' | 'left' | 'right'): void {
    if (!this.activeTab) return;
    const tab = this.tabs.get(this.activeTab);
    if (!tab?.root) return;
    const panel = tab.root.selectSplitInDirection(direction, this.activePanel?.id);
    if (panel) {
      this.setActivePanel(panel);
    }
  }

  private equalizeSplits(): void {
    if (!this.activeTab) return;
    const tab = this.tabs.get(this.activeTab);
    tab?.root?.equalize();
  }

  private resizeSplit(direction: 'up' | 'down' | 'left' | 'right'): void {
    if (!this.activeTab || !this.activePanel) return;
    const tab = this.tabs.get(this.activeTab);
    if (!tab?.root) return;
    // Find the container for the active panel and resize from there
    const container = tab.root.findContainer(this.activePanel);
    container?.resizeSplit(direction, 50);
  }
  // ============================================================================
  // iOS Accessory Bar
  // ============================================================================

  // Sticky modifiers from accessory bar (shared with keyboard handler)
  private stickyModifiers = { ctrl: false, alt: false, meta: false };

  private applyingStickyModifiers(e: KeyboardEvent): KeyboardEvent {
    if (!this.stickyModifiers.ctrl && !this.stickyModifiers.alt && !this.stickyModifiers.meta) {
      return e; // No sticky modifiers active
    }
    // Create new event with sticky modifiers applied
    return new KeyboardEvent(e.type, {
      key: e.key,
      code: e.code,
      ctrlKey: e.ctrlKey || this.stickyModifiers.ctrl,
      altKey: e.altKey || this.stickyModifiers.alt,
      metaKey: e.metaKey || this.stickyModifiers.meta,
      shiftKey: e.shiftKey,
      bubbles: e.bubbles,
    });
  }

  private clearStickyModifiers(): void {
    this.stickyModifiers.ctrl = false;
    this.stickyModifiers.alt = false;
    this.stickyModifiers.meta = false;
    document.querySelectorAll('#accessory-bar .modifier').forEach(m => m.classList.remove('active'));
  }

  private setupAccessoryBar(): void {
    const accessoryBar = document.getElementById('accessory-bar');
    if (!accessoryBar) return;

    const modifiers = this.stickyModifiers;

    // Handle drawer toggle
    const handle = accessoryBar.querySelector('.accessory-handle');
    handle?.addEventListener('click', () => {
      accessoryBar.classList.toggle('collapsed');
    });

    // Handle modifier toggles
    const toggleModifier = (btn: Element) => {
      const mod = (btn as HTMLElement).dataset.modifier as keyof typeof modifiers;
      modifiers[mod] = !modifiers[mod];
      btn.classList.toggle('active', modifiers[mod]);
      console.log('Modifier toggled:', mod, modifiers[mod]);
    };

    let lastTouchTime = 0;
    accessoryBar.querySelectorAll('.modifier').forEach(btn => {
      btn.addEventListener('touchend', (e) => {
        e.preventDefault();
        lastTouchTime = Date.now();
        toggleModifier(btn);
      });
      btn.addEventListener('click', (e) => {
        e.preventDefault();
        // Ignore click if touch just happened (prevents double toggle)
        if (Date.now() - lastTouchTime < 300) return;
        toggleModifier(btn);
      });
    });

    // Handle key buttons
    const sendKey = (btn: Element) => {
      const key = (btn as HTMLElement).dataset.key;
      if (!key) return;

      if (!this.activePanel) {
        console.log('No active panel');
        return;
      }

      console.log('Sending key:', key, 'modifiers:', modifiers);

      // Create synthetic keyboard event
      const event = new KeyboardEvent('keydown', {
        key: key,
        code: key,
        ctrlKey: modifiers.ctrl,
        altKey: modifiers.alt,
        metaKey: modifiers.meta,
        bubbles: true,
      });

      // Send to active panel
      this.activePanel.sendKeyInput(event, 1); // press

      // Also send release
      setTimeout(() => {
        const releaseEvent = new KeyboardEvent('keyup', {
          key: key,
          code: key,
          ctrlKey: modifiers.ctrl,
          altKey: modifiers.alt,
          metaKey: modifiers.meta,
          bubbles: true,
        });
        this.activePanel?.sendKeyInput(releaseEvent, 0);

        this.clearStickyModifiers();
      }, 50);
    };

    accessoryBar.querySelectorAll('.accessory-key:not(.modifier)').forEach(btn => {
      btn.addEventListener('touchend', (e) => {
        e.preventDefault();
        lastTouchTime = Date.now();
        sendKey(btn);
      });
      btn.addEventListener('click', (e) => {
        e.preventDefault();
        if (Date.now() - lastTouchTime < 300) return;
        sendKey(btn);
      });
    });
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
