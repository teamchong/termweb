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
import { TIMING, WS_PATHS, CONFIG_ENDPOINT, SERVER_MSG } from '../constants';
import { BinaryCtrlMsg } from '../protocol';

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
  decodePreviewFrame: (frameData: Uint8Array) => void;
  handleInspectorState: (state: unknown) => void;
  getStatus: () => PanelStatus;
  getPwd: () => string;
  setPwd: (pwd: string) => void;
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
  private panelsEl: HTMLElement | null = null;
  private initialPanelListResolve: (() => void) | null = null;

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

  async init(panelsEl: HTMLElement): Promise<void> {
    if (!MuxClient.checkWebCodecsSupport()) {
      const error = 'WebCodecs API not supported. Please use a modern browser (Chrome 94+, Edge 94+, or Safari 16.4+).';
      console.error(error);
      connectionStatus.set('error');
      throw new Error(error);
    }

    this.panelsEl = panelsEl;
    const config = await this.fetchConfig();
    if (config.colors) {
      applyColors(config.colors);
    }

    const initialPanelListPromise = new Promise<void>((resolve) => {
      this.initialPanelListResolve = resolve;
    });

    this.connectControl();
    this.fileTransfer.connect().catch(err => {
      console.warn('File transfer connection failed:', err);
    });

    await Promise.race([
      initialPanelListPromise,
      new Promise<void>(resolve => setTimeout(resolve, 3000)),
    ]);
  }

  destroy(): void {
    this.destroyed = true;
    initialLayoutLoaded.set(false);
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
        case SERVER_MSG.AUTH_STATE:
          authState.set({
            role: view.getUint8(1),
            authRequired: view.getUint8(2) === 1,
            hasPassword: view.getUint8(3) === 1,
            passkeyCount: view.getUint8(4),
          });
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
    console.log('Layout update from server:', layout);
  }

  private handlePanelList(panelList: Array<{ panel_id: number; title: string }>, layout: unknown): void {
    if (isValidLayoutData(layout) && layout.tabs.length > 0) {
      this.restoreLayoutFromServer(layout);
    } else if (panelList.length > 0) {
      this.reconnectPanelsAsSplits(panelList);
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
      const tabId = this.findTabIdForPanel(panel);
      if (tabId) {
        tabs.updateTab(tabId, { title });
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
      title: title || 'Terminal',
      root,
      element: tabContent,
    };
    this.tabInstances.set(tabId, tabInfo);
    tabs.add(createTabInfo(tabId));
    tabs.updateTab(tabId, { title: title || 'Terminal', panelIds: [panel.id] });
    this.selectTab(tabId);
    return tabId;
  }

  selectTab(tabId: string): void {
    const tab = this.tabInstances.get(tabId);
    if (!tab) return;
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
        onViewAction: (action: string, data?: unknown) => this.handleViewAction(panelId, action, data),
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
      decodePreviewFrame: (frameData: Uint8Array) => void;
      handleInspectorState: (state: unknown) => void;
      getStatus: () => PanelStatus;
      getPwd: () => string;
      setPwd: (pwd: string) => void;
      getCanvas: () => HTMLCanvasElement | undefined;
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
      decodePreviewFrame: (f) => comp.decodePreviewFrame(f),
      handleInspectorState: (s) => comp.handleInspectorState(s),
      getStatus: () => comp.getStatus(),
      getPwd: () => comp.getPwd(),
      setPwd: (p) => comp.setPwd(p),
    };

    this.panelInstances.set(panelId, panel);
    if (serverId !== null) {
      this.panelsByServerId.set(serverId, panel);
    }
    panels.add(createPanelInfo(panelId, serverId, isQuickTerminal));
    panel.connect();
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
    } else {
      activePanelId.set(null);
      this.currentActivePanel = null;
    }
  }

  closePanel(panelId: string): void {
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
      // Send close message to server (optimistic update - frontend updates immediately)
      if (panel.serverId !== null) {
        this.sendClosePanel(panel.serverId);
        this.panelsByServerId.delete(panel.serverId);
      }
      tab.root.removePanel(panel);
      this.panelInstances.delete(panelId);
      panels.remove(panelId);
      panel.destroy();
      const remainingPanels = tab.root.getAllPanels();
      if (remainingPanels.length > 0) {
        this.setActivePanel(remainingPanels[0] as PanelInstance);
      }
    }
  }

  private removePanel(panelId: string): void {
    this.closePanel(panelId);
  }

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

  private restoreLayoutFromServer(layout: LayoutData): void {
    for (const tabId of Array.from(this.tabInstances.keys())) {
      this.closeTab(tabId);
    }
    for (const tabLayout of layout.tabs) {
      this.restoreTab(tabLayout);
    }
    if (layout.activeTabId !== undefined) {
      const tabId = String(layout.activeTabId);
      if (this.tabInstances.has(tabId)) {
        this.selectTab(tabId);
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
      title: 'Terminal',
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

  sendControlMessage(type: number, data: Uint8Array): void {
    if (this.isControlWsOpen()) {
      const message = new Uint8Array(1 + data.length);
      message[0] = type;
      message.set(data, 1);
      this.controlWs!.send(message);
    }
  }

  private sendClosePanel(serverId: number): void {
    const data = new Uint8Array(4);
    const view = new DataView(data.buffer);
    view.setUint32(0, serverId, true);
    this.sendControlMessage(BinaryCtrlMsg.CLOSE_PANEL, data);
  }

  sendViewAction(action: string): void {
    const panel = this.currentActivePanel;
    if (!panel || panel.serverId === null) return;
    const actionBytes = sharedTextEncoder.encode(action);
    const data = new Uint8Array(4 + 2 + actionBytes.length);
    const view = new DataView(data.buffer);
    view.setUint32(0, panel.serverId, true);
    view.setUint16(4, actionBytes.length, true);
    data.set(actionBytes, 6);
    this.sendControlMessage(BinaryCtrlMsg.VIEW_ACTION, data);
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
