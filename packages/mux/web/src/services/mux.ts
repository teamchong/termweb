/**
 * Mux Client Service
 * Centralized WebSocket and state management using Svelte stores
 */
import { writable } from 'svelte/store';
import { tabs, activeTabId, panels, activePanelId, ui, createPanelInfo, createTabInfo } from '../stores/index';
import { Panel, type PanelCallbacks } from '../panel';
import { SplitContainer } from '../split-container';
import { FileTransferHandler } from '../file-transfer';
import type { AppConfig, LayoutData, LayoutNode, LayoutTab } from '../types';
import { applyColors, generateId, getWsUrl, sharedTextEncoder, sharedTextDecoder } from '../utils';
import { TIMING, WS_PATHS, CONFIG_ENDPOINT, SERVER_MSG } from '../constants';
import { BinaryCtrlMsg } from '../protocol';

// Type guard for validating LayoutData structure from server
function isValidLayoutData(data: unknown): data is LayoutData {
  if (!data || typeof data !== 'object') return false;
  const layout = data as Record<string, unknown>;
  if (!Array.isArray(layout.tabs)) return false;
  // Validate each tab has required fields
  for (const tab of layout.tabs) {
    if (!tab || typeof tab !== 'object') return false;
    const t = tab as Record<string, unknown>;
    if (typeof t.id !== 'number' || !t.root) return false;
  }
  return true;
}

// Connection status store
export const connectionStatus = writable<'connected' | 'disconnected' | 'error'>('disconnected');

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
  private panelInstances = new Map<string, Panel>();
  private panelsByServerId = new Map<number, Panel>(); // O(1) lookup by serverId
  private tabInstances = new Map<string, InternalTabInfo>();
  private tabHistory: string[] = [];
  private nextTabId = 1;
  private destroyed = false;
  private reconnectTimeoutId: ReturnType<typeof setTimeout> | null = null;
  private reconnectDelay: number = TIMING.WS_RECONNECT_INITIAL;
  private currentActivePanel: Panel | null = null;
  private quickTerminalPanel: Panel | null = null;
  private previousActivePanel: Panel | null = null;
  private bellTimeouts = new Map<number, ReturnType<typeof setTimeout>>();

  // DOM element references
  private panelsEl: HTMLElement | null = null;

  // Initial panel list promise for blocking init until first response
  private initialPanelListResolve: (() => void) | null = null;

  constructor() {
    this.fileTransfer = new FileTransferHandler();

    // Wire up file transfer callbacks
    this.fileTransfer.onTransferComplete = (transferId, totalBytes) => {
      console.log(`Transfer ${transferId} completed: ${totalBytes} bytes`);
    };

    this.fileTransfer.onTransferError = (transferId, error) => {
      console.error(`Transfer ${transferId} failed: ${error}`);
      // TODO: Show error in UI toast/notification when available
    };

    this.fileTransfer.onDryRunReport = (transferId, report) => {
      console.log(`Transfer ${transferId} dry run: ${report.newCount} new, ${report.updateCount} update, ${report.deleteCount} delete`);
    };
  }

  /**
   * Check if WebCodecs API is available
   */
  private static checkWebCodecsSupport(): boolean {
    return typeof VideoDecoder !== 'undefined' && typeof VideoDecoder.isConfigSupported === 'function';
  }

  /** Check if control WebSocket is connected and ready */
  private isControlWsOpen(): boolean {
    return this.controlWs !== null && this.controlWs.readyState === WebSocket.OPEN;
  }

  /**
   * Initialize the client - connect WebSockets and setup UI
   */
  async init(panelsEl: HTMLElement): Promise<void> {
    // Check WebCodecs support before initializing
    if (!MuxClient.checkWebCodecsSupport()) {
      const error = 'WebCodecs API not supported. Please use a modern browser (Chrome 94+, Edge 94+, or Safari 16.4+).';
      console.error(error);
      connectionStatus.set('error');
      throw new Error(error);
    }

    this.panelsEl = panelsEl;

    // Fetch config and apply colors
    const config = await this.fetchConfig();
    if (config.colors) {
      applyColors(config.colors);
    }

    // Create promise that resolves when initial panel list is received
    const initialPanelListPromise = new Promise<void>((resolve) => {
      this.initialPanelListResolve = resolve;
    });

    // Connect WebSockets
    this.connectControl();
    // File transfer connection is non-critical - log errors but don't block init
    this.fileTransfer.connect().catch(err => {
      console.warn('File transfer connection failed:', err);
    });

    // Wait for initial panel list (with timeout to prevent hanging)
    await Promise.race([
      initialPanelListPromise,
      new Promise<void>(resolve => setTimeout(resolve, 3000)), // 3s timeout
    ]);
  }

  /**
   * Cleanup resources
   */
  destroy(): void {
    this.destroyed = true;

    // Resolve any pending init promise
    if (this.initialPanelListResolve) {
      this.initialPanelListResolve();
      this.initialPanelListResolve = null;
    }

    if (this.reconnectTimeoutId) {
      clearTimeout(this.reconnectTimeoutId);
      this.reconnectTimeoutId = null;
    }

    // Clear all bell timeouts
    for (const timeoutId of this.bellTimeouts.values()) {
      clearTimeout(timeoutId);
    }
    this.bellTimeouts.clear();

    if (this.controlWs) {
      this.controlWs.close();
      this.controlWs = null;
    }

    this.fileTransfer.disconnect();

    for (const panel of this.panelInstances.values()) {
      panel.destroy();
    }
    this.panelInstances.clear();
    this.panelsByServerId.clear();
    panels.clear();

    for (const tab of this.tabInstances.values()) {
      tab.root.destroy();
    }
    this.tabInstances.clear();
    tabs.clear();

    // Clear panel references
    this.currentActivePanel = null;
    this.quickTerminalPanel = null;
    this.previousActivePanel = null;
  }

  // ===========================================================================
  // WebSocket Management
  // ===========================================================================

  private async fetchConfig(): Promise<AppConfig> {
    try {
      const response = await fetch(CONFIG_ENDPOINT);
      if (!response.ok) {
        console.warn('Failed to fetch config:', response.status);
        return {};
      }
      return await response.json();
    } catch (err) {
      console.warn('Failed to fetch config:', err);
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
      // Reset reconnect delay on successful connection
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
        this.handleBinaryMessage(event.data);
      }
    };

    this.controlWs.onclose = () => {
      console.log('Control channel disconnected');
      connectionStatus.set('disconnected');
      if (!this.destroyed) {
        // Exponential backoff with jitter
        const jitter = Math.random() * 0.3 * this.reconnectDelay;
        const delay = Math.min(this.reconnectDelay + jitter, TIMING.WS_RECONNECT_MAX);
        console.log(`Reconnecting in ${Math.round(delay)}ms...`);
        // Clear any existing reconnect timeout to prevent multiple concurrent reconnects
        if (this.reconnectTimeoutId) {
          clearTimeout(this.reconnectTimeoutId);
        }
        this.reconnectTimeoutId = setTimeout(() => this.connectControl(), delay);
        // Increase delay for next attempt (exponential backoff)
        this.reconnectDelay = Math.min(this.reconnectDelay * 2, TIMING.WS_RECONNECT_MAX);
      }
    };

    this.controlWs.onerror = () => {
      connectionStatus.set('error');
    };
  }

  // ===========================================================================
  // Message Handlers
  // ===========================================================================

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
        try { layout = JSON.parse(layoutJson); } catch (err) { console.warn('Failed to parse layout JSON:', err); }
        this.handlePanelList(panelList, layout);
        break;
      }
      case SERVER_MSG.PANEL_CREATED: {
        const panelId = view.getUint32(1, true);
        this.handlePanelCreated(panelId);
        break;
      }
      case SERVER_MSG.PANEL_CLOSED: {
        const panelId = view.getUint32(1, true);
        this.handlePanelClosed(panelId);
        break;
      }
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
      case SERVER_MSG.PANEL_BELL: {
        const panelId = view.getUint32(1, true);
        this.handleBell(panelId);
        break;
      }
      case SERVER_MSG.LAYOUT_UPDATE: {
        const layoutLen = view.getUint16(1, true);
        const layoutJson = sharedTextDecoder.decode(bytes.slice(3, 3 + layoutLen));
        try {
          const layout = JSON.parse(layoutJson);
          this.handleLayoutUpdate(layout);
        } catch (err) { console.warn('Failed to parse layout update:', err); }
        break;
      }
      case SERVER_MSG.CLIPBOARD: {
        const dataLen = view.getUint32(1, true);
        const text = sharedTextDecoder.decode(bytes.slice(5, 5 + dataLen));
        navigator.clipboard.writeText(text).catch(console.error);
        break;
      }
      case SERVER_MSG.AUTH_STATE: {
        authState.set({
          role: view.getUint8(1),
          authRequired: view.getUint8(2) === 1,
          hasPassword: view.getUint8(3) === 1,
          passkeyCount: view.getUint8(4),
        });
        break;
      }
      }
    } catch (err) {
      console.error('Failed to parse binary message:', err);
    }
  }

  private updatePanelPwd(serverId: number, pwd: string): void {
    const panel = this.panelsByServerId.get(serverId);
    if (panel) {
      panels.updatePanel(panel.id, { pwd });
    }
  }

  private handleBell(serverId: number): void {
    const panel = this.panelsByServerId.get(serverId);
    if (panel) {
      // Clear any existing bell timeout for this panel
      const existingTimeout = this.bellTimeouts.get(serverId);
      if (existingTimeout) {
        clearTimeout(existingTimeout);
      }

      // Flash the panel briefly
      panel.element.classList.add('bell');
      const timeoutId = setTimeout(() => {
        this.bellTimeouts.delete(serverId);
        // Check panel still exists before removing class
        if (this.panelInstances.has(panel.id)) {
          panel.element.classList.remove('bell');
        }
      }, TIMING.BELL_FLASH_DURATION);

      this.bellTimeouts.set(serverId, timeoutId);
    }
  }

  private handleLayoutUpdate(layout: LayoutData): void {
    // Server sent updated layout - sync with local state
    // For now, just log it - full implementation would reconcile state
    console.log('Layout update from server:', layout);
  }

  // ===========================================================================
  // Panel/Tab Management
  // ===========================================================================

  private handlePanelList(panelList: Array<{ panel_id: number; title: string }>, layout: unknown): void {
    if (isValidLayoutData(layout) && layout.tabs.length > 0) {
      this.restoreLayoutFromServer(layout);
    } else if (panelList.length > 0) {
      this.reconnectPanelsAsSplits(panelList);
    }

    // Resolve initial panel list promise to unblock init()
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
    // Find a panel without a serverId and assign it
    for (const panel of this.panelInstances.values()) {
      if (panel.serverId === null) {
        panel.serverId = panelId;
        // Add to serverId lookup map
        this.panelsByServerId.set(panelId, panel);
        break;
      }
    }
  }

  private handlePanelClosed(serverId: number): void {
    const panel = this.panelsByServerId.get(serverId);
    if (panel) {
      this.removePanel(panel.id);
    }
  }

  private updatePanelTitle(serverId: number, title: string): void {
    const panel = this.panelsByServerId.get(serverId);
    if (panel) {
      panels.updatePanel(panel.id, { title });
      // Update tab title if this is the active panel
      const tabId = this.findTabIdForPanel(panel);
      if (tabId) {
        tabs.updateTab(tabId, { title });
      }
    }
  }

  private findTabIdForPanel(panel: Panel): string | null {
    for (const [tabId, tab] of this.tabInstances) {
      const allPanels = tab.root.getAllPanels();
      if (allPanels.some(p => p.id === panel.id)) {
        return tabId;
      }
    }
    return null;
  }

  // ===========================================================================
  // Public API
  // ===========================================================================

  /**
   * Create a new tab
   */
  createTab(serverId?: number, title?: string): string {
    if (!this.panelsEl) {
      console.error('Cannot create tab: panelsEl not initialized');
      return '';
    }

    const tabId = String(this.nextTabId++);

    // Create tab element
    const tabContent = document.createElement('div');
    tabContent.className = 'tab-content';
    tabContent.dataset.tabId = tabId;
    this.panelsEl.appendChild(tabContent);

    // Create split container as root (will become a leaf)
    const root = new SplitContainer(null);
    root.element.className = 'split-pane';
    root.element.style.flex = '1';
    tabContent.appendChild(root.element);

    // Create panel
    const panel = this.createPanel(root.element, serverId ?? null);
    root.panel = panel;

    // Create tab info
    const tabInfo: InternalTabInfo = {
      id: tabId,
      title: title || 'Terminal',
      root,
      element: tabContent,
    };
    this.tabInstances.set(tabId, tabInfo);

    // Update stores
    tabs.add(createTabInfo(tabId));
    tabs.updateTab(tabId, { title: title || 'Terminal', panelIds: [panel.id] });

    // Select the new tab
    this.selectTab(tabId);

    return tabId;
  }

  /**
   * Select a tab
   */
  selectTab(tabId: string): void {
    const tab = this.tabInstances.get(tabId);
    if (!tab) return;

    // Deactivate all tabs
    for (const t of this.tabInstances.values()) {
      t.element.classList.remove('active');
    }

    // Activate selected tab
    tab.element.classList.add('active');
    activeTabId.set(tabId);

    // Update tab history
    this.tabHistory = this.tabHistory.filter(id => id !== tabId);
    this.tabHistory.push(tabId);

    // Focus the first panel in this tab
    const allPanels = tab.root.getAllPanels();
    if (allPanels.length > 0) {
      this.setActivePanel(allPanels[0]);
    }
  }

  /**
   * Close a tab
   */
  closeTab(tabId: string): void {
    const tab = this.tabInstances.get(tabId);
    if (!tab) return;

    // Destroy all panels in the tab
    const allPanels = tab.root.getAllPanels();
    for (const panel of allPanels) {
      this.panelInstances.delete(panel.id);
      // Remove from serverId lookup map
      if (panel.serverId !== null) {
        this.panelsByServerId.delete(panel.serverId);
      }
      panels.remove(panel.id);
      panel.destroy();
    }

    // Destroy split container
    tab.root.destroy();
    tab.element.remove();

    // Remove from stores
    this.tabInstances.delete(tabId);
    tabs.remove(tabId);

    // Update tab history
    this.tabHistory = this.tabHistory.filter(id => id !== tabId);

    // Select previous tab if available
    if (this.tabHistory.length > 0) {
      this.selectTab(this.tabHistory[this.tabHistory.length - 1]);
    } else if (this.tabInstances.size > 0) {
      const firstTabId = this.tabInstances.keys().next().value;
      if (firstTabId) this.selectTab(firstTabId);
    } else {
      activeTabId.set(null);
      activePanelId.set(null);
      this.currentActivePanel = null;
    }
  }

  /**
   * Create a panel
   */
  private createPanel(container: HTMLElement, serverId: number | null): Panel {
    const panelId = generateId();

    const callbacks: PanelCallbacks = {
      onViewAction: (action: string, data?: unknown) => this.handleViewAction(panelId, action, data),
      onStatusChange: (status) => panels.updatePanel(panelId, { status }),
      onTitleChange: (title) => {
        panels.updatePanel(panelId, { title });
        const tabId = this.findTabIdForPanelId(panelId);
        if (tabId) tabs.updateTab(tabId, { title });
      },
      onPwdChange: (pwd) => panels.updatePanel(panelId, { pwd }),
      onServerIdAssigned: (newServerId: number) => {
        // When server assigns an ID, add to lookup map
        this.panelsByServerId.set(newServerId, panel);
      },
    };

    const panel = new Panel(
      panelId,
      container,
      serverId,
      callbacks
    );

    this.panelInstances.set(panelId, panel);
    // Add to serverId lookup map if serverId is known
    if (serverId !== null) {
      this.panelsByServerId.set(serverId, panel);
    }
    panels.add(createPanelInfo(panelId, serverId));

    // Connect the panel
    panel.connect();

    return panel;
  }

  private findTabIdForPanelId(panelId: string): string | null {
    const panel = this.panelInstances.get(panelId);
    return panel ? this.findTabIdForPanel(panel) : null;
  }

  /**
   * Set the active panel
   */
  private setActivePanel(panel: Panel | null): void {
    // Update focus states
    for (const p of this.panelInstances.values()) {
      p.element.classList.remove('focused');
    }

    if (panel) {
      panel.element.classList.add('focused');
      activePanelId.set(panel.id);
      this.currentActivePanel = panel;
      panel.focus();
    } else {
      activePanelId.set(null);
      this.currentActivePanel = null;
    }
  }

  /**
   * Close a panel
   */
  closePanel(panelId: string): void {
    const panel = this.panelInstances.get(panelId);
    if (!panel) return;

    // Clear any pending bell timeout for this panel
    if (panel.serverId !== null) {
      const bellTimeout = this.bellTimeouts.get(panel.serverId);
      if (bellTimeout) {
        clearTimeout(bellTimeout);
        this.bellTimeouts.delete(panel.serverId);
      }
    }

    // Clear quick terminal references if this panel is being closed
    if (this.quickTerminalPanel === panel) {
      this.quickTerminalPanel = null;
    }
    if (this.previousActivePanel === panel) {
      this.previousActivePanel = null;
    }

    // Find the tab containing this panel
    const tabId = this.findTabIdForPanel(panel);
    if (!tabId) return;

    const tab = this.tabInstances.get(tabId);
    if (!tab) return;

    // Remove panel from split container
    const allPanels = tab.root.getAllPanels();
    if (allPanels.length === 1) {
      // Last panel - close the tab
      this.closeTab(tabId);
    } else {
      // Remove just this panel
      tab.root.removePanel(panel);
      this.panelInstances.delete(panelId);
      // Remove from serverId lookup map
      if (panel.serverId !== null) {
        this.panelsByServerId.delete(panel.serverId);
      }
      panels.remove(panelId);
      panel.destroy();

      // Update active panel
      const remainingPanels = tab.root.getAllPanels();
      if (remainingPanels.length > 0) {
        this.setActivePanel(remainingPanels[0]);
      }
    }
  }

  /**
   * Remove a panel (called when server closes it)
   */
  private removePanel(panelId: string): void {
    this.closePanel(panelId);
  }

  /**
   * Handle panel view actions
   */
  private handleViewAction(panelId: string, action: string, _data?: unknown): void {
    const panel = this.panelInstances.get(panelId);
    if (!panel) return;

    switch (action) {
      case 'split-right':
        this.splitPanel(panel, 'right');
        break;
      case 'split-down':
        this.splitPanel(panel, 'down');
        break;
      case 'close':
        this.closePanel(panel.id);
        break;
    }
  }

  /**
   * Split a panel
   */
  splitPanel(panel: Panel, direction: 'right' | 'down' | 'left' | 'up'): void {
    const tabId = this.findTabIdForPanel(panel);
    if (!tabId) return;

    const tab = this.tabInstances.get(tabId);
    if (!tab) return;

    // Find the container holding this panel
    const container = tab.root.findContainer(panel);
    if (!container) return;

    const newPanel = this.createPanel(tab.element, null);
    container.split(direction, newPanel);
    this.setActivePanel(newPanel);

    // Update tab's panel list
    const allPanels = tab.root.getAllPanels();
    tabs.updateTab(tabId, { panelIds: allPanels.map(p => p.id) });
  }

  /**
   * Restore layout from server
   */
  private restoreLayoutFromServer(layout: LayoutData): void {
    // Clear existing tabs
    for (const tabId of Array.from(this.tabInstances.keys())) {
      this.closeTab(tabId);
    }

    // Restore tabs from layout
    for (const tabLayout of layout.tabs) {
      this.restoreTab(tabLayout);
    }

    // Select active tab
    if (layout.activeTabId !== undefined) {
      const tabId = String(layout.activeTabId);
      if (this.tabInstances.has(tabId)) {
        this.selectTab(tabId);
      }
    }
  }

  private restoreTab(tabLayout: LayoutTab): void {
    if (!this.panelsEl) {
      console.error('Cannot restore tab: panelsEl not initialized');
      return;
    }

    const tabId = String(tabLayout.id);
    this.nextTabId = Math.max(this.nextTabId, tabLayout.id + 1);

    // Create tab element
    const tabContent = document.createElement('div');
    tabContent.className = 'tab-content';
    tabContent.dataset.tabId = tabId;
    this.panelsEl.appendChild(tabContent);

    // Create root split container
    const root = new SplitContainer(null);
    root.element.className = 'split-pane';
    root.element.style.flex = '1';
    tabContent.appendChild(root.element);

    // Build split tree from layout
    this.buildSplitTree(tabLayout.root, root);

    // Create tab info
    const tabInfo: InternalTabInfo = {
      id: tabId,
      title: 'Terminal',
      root,
      element: tabContent,
    };
    this.tabInstances.set(tabId, tabInfo);

    // Update stores
    const allPanels = root.getAllPanels();
    tabs.add(createTabInfo(tabId));
    tabs.updateTab(tabId, { panelIds: allPanels.map(p => p.id) });
  }

  private buildSplitTree(node: LayoutNode, container: SplitContainer): void {
    if (node.type === 'leaf' && node.panelId !== undefined) {
      // Create panel in this container
      const panel = this.createPanel(container.element, node.panelId);
      container.panel = panel;
    } else if (node.type === 'split' && node.first && node.second) {
      // For a split node, we need to:
      // 1. Build the first child (creates panels in container)
      // 2. Find a leaf to split
      // 3. Split and build the second child

      // First, get a placeholder panel for the first child
      const firstPanel = this.getFirstLeafPanel(node.first);
      if (firstPanel !== undefined) {
        const panel = this.createPanel(container.element, firstPanel);
        container.panel = panel;
      }

      // Now split the container for the second child
      const secondPanel = this.getFirstLeafPanel(node.second);
      if (secondPanel !== undefined) {
        const panel = this.createPanel(container.element, secondPanel);
        const dir = node.direction === 'horizontal' ? 'right' : 'down';
        container.split(dir, panel);

        // If children are splits themselves, we need to continue building
        // But SplitContainer.split() creates leaf containers, so we need to
        // split those further if needed
        if (node.first.type === 'split' && container.first) {
          this.buildNestedSplit(node.first, container.first);
        }
        if (node.second.type === 'split' && container.second) {
          this.buildNestedSplit(node.second, container.second);
        }
      }
    }
  }

  // Get the first leaf panel ID from a node (for placeholder)
  private getFirstLeafPanel(node: LayoutNode): number | undefined {
    if (node.type === 'leaf') {
      return node.panelId;
    } else if (node.type === 'split' && node.first) {
      return this.getFirstLeafPanel(node.first);
    }
    return undefined;
  }

  // Build nested splits after the initial split
  private buildNestedSplit(node: LayoutNode, container: SplitContainer): void {
    if (node.type !== 'split' || !node.first || !node.second) return;

    // The container currently has a panel from getFirstLeafPanel
    // We need to split it to add the remaining panels

    // Get all leaf panels except the first one
    const remainingPanels = this.collectLeafPanels(node.second);

    for (const panelId of remainingPanels) {
      // Find the rightmost/bottommost leaf to split
      const leaf = this.findLeafContainer(container);
      if (leaf && leaf.panel) {
        const panel = this.createPanel(container.element, panelId);
        const dir = node.direction === 'horizontal' ? 'right' : 'down';
        leaf.split(dir, panel);
      }
    }
  }

  // Collect all leaf panel IDs from a node
  private collectLeafPanels(node: LayoutNode): number[] {
    const panelIds: number[] = [];
    if (node.type === 'leaf' && node.panelId !== undefined) {
      panelIds.push(node.panelId);
    } else if (node.type === 'split') {
      if (node.first) panelIds.push(...this.collectLeafPanels(node.first));
      if (node.second) panelIds.push(...this.collectLeafPanels(node.second));
    }
    return panelIds;
  }

  // Find a leaf container (one with a panel, not a split)
  private findLeafContainer(container: SplitContainer): SplitContainer | null {
    if (container.panel) return container;
    if (container.second) {
      const found = this.findLeafContainer(container.second);
      if (found) return found;
    }
    if (container.first) {
      return this.findLeafContainer(container.first);
    }
    return null;
  }

  // ===========================================================================
  // Send Messages
  // ===========================================================================

  /**
   * Send a control message to the server
   */
  sendControlMessage(type: number, data: Uint8Array): void {
    if (this.isControlWsOpen()) {
      const message = new Uint8Array(1 + data.length);
      message[0] = type;
      message.set(data, 1);
      this.controlWs!.send(message);
    }
  }

  /**
   * Send a view action to the active panel
   */
  sendViewAction(action: string): void {
    const panel = this.currentActivePanel;
    if (!panel || panel.serverId === null) return;

    // Format: [type:u8][panel_id:u32][action_len:u16][action...]
    const actionBytes = sharedTextEncoder.encode(action);
    const data = new Uint8Array(4 + 2 + actionBytes.length);
    const view = new DataView(data.buffer);
    view.setUint32(0, panel.serverId, true);
    view.setUint16(4, actionBytes.length, true);
    data.set(actionBytes, 6);

    this.sendControlMessage(BinaryCtrlMsg.VIEW_ACTION, data);
  }

  /**
   * Get the active panel
   */
  getActivePanel(): Panel | null {
    return this.currentActivePanel;
  }

  /**
   * Toggle quick terminal
   */
  toggleQuickTerminal(container: HTMLElement): void {
    ui.update(s => {
      if (s.quickTerminalOpen) {
        // Closing - restore previous active panel if it still exists
        if (this.previousActivePanel && this.panelInstances.has(this.previousActivePanel.id)) {
          this.setActivePanel(this.previousActivePanel);
        } else {
          // Previous panel was closed, find another one to focus
          const firstPanel = this.panelInstances.values().next().value;
          if (firstPanel && firstPanel !== this.quickTerminalPanel) {
            this.setActivePanel(firstPanel);
          }
        }
        this.previousActivePanel = null;
        return { ...s, quickTerminalOpen: false };
      } else {
        // Opening - save current active panel
        this.previousActivePanel = this.currentActivePanel;

        // Create quick terminal panel if needed
        if (!this.quickTerminalPanel) {
          this.quickTerminalPanel = this.createQuickTerminalPanel(container);
        }

        // Focus the quick terminal
        this.setActivePanel(this.quickTerminalPanel);

        return { ...s, quickTerminalOpen: true, quickTerminalPanelId: this.quickTerminalPanel.id };
      }
    });
  }

  /**
   * Create quick terminal panel (doesn't get added to server layout)
   */
  private createQuickTerminalPanel(container: HTMLElement): Panel {
    const panelId = generateId();

    const callbacks: PanelCallbacks = {
      onViewAction: (_action: string, _data?: unknown) => {
        // Quick terminal doesn't support view actions
      },
      onStatusChange: (status) => panels.updatePanel(panelId, { status }),
      onTitleChange: (title) => panels.updatePanel(panelId, { title }),
      onPwdChange: (pwd) => panels.updatePanel(panelId, { pwd }),
    };

    const panel = new Panel(
      panelId,
      container,
      null,
      callbacks,
      null,
      undefined,
      undefined,
      true // isQuickTerminal - tells server not to add to layout
    );

    this.panelInstances.set(panelId, panel);
    panels.add(createPanelInfo(panelId, null, true));
    panel.connect();

    return panel;
  }

  /**
   * Get quick terminal panel
   */
  getQuickTerminalPanel(): Panel | null {
    return this.quickTerminalPanel;
  }

  /**
   * Toggle inspector on active panel
   */
  toggleInspector(): void {
    const panel = this.currentActivePanel;
    if (panel) {
      panel.toggleInspector();
    }
  }

  /**
   * Show upload dialog - select a local folder to upload to the server
   */
  async showUploadDialog(): Promise<void> {
    if (!('showDirectoryPicker' in window)) {
      console.error('File System Access API not supported');
      return;
    }

    try {
      const dirHandle = await window.showDirectoryPicker({
        mode: 'read',
      });

      // Prompt for server path (use panel's current working directory if available)
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

  /**
   * Show download dialog - specify a server path to download
   */
  async showDownloadDialog(): Promise<void> {
    // Prompt for server path (use panel's current working directory if available)
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

// Singleton instance
let muxClient: MuxClient | null = null;

/**
 * Get or create the MuxClient instance
 */
export function getMuxClient(): MuxClient {
  if (!muxClient) {
    muxClient = new MuxClient();
  }
  return muxClient;
}

/**
 * Initialize the MuxClient
 */
export async function initMuxClient(panelsEl: HTMLElement): Promise<MuxClient> {
  const client = getMuxClient();
  await client.init(panelsEl);
  return client;
}
