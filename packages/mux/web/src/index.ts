/**
 * termweb-mux browser client
 * Connects to server, receives frames, renders to canvas, sends input
 */

import { Panel } from './panel';
import { SplitContainer } from './split-container';
import { FileTransferHandler } from './file-transfer';
import { CommandPalette, UploadDialog, DownloadDialog, AccessControlDialog } from './dialogs';
import type { AppConfig, TabInfo } from './types';
import { generateId, applyColors, formatBytes, isLightColor, shadowColor } from './utils';

// Re-export for external use
export * from './protocol';
export * from './types';
export * from './utils';
export { Panel } from './panel';
export { SplitContainer } from './split-container';
export { FileTransferHandler } from './file-transfer';

// WebSocket ports (fetched from /config endpoint)
let PANEL_PORT = 0;
let CONTROL_PORT = 0;
let FILE_PORT = 0;

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
  private pendingSplit: { parentPanelId: number; direction: string; container: SplitContainer } | null = null;

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
  private sessions: Array<{ id: string; name: string; editorToken: string; viewerToken: string }> = [];
  private shareLinks: Array<{ token: string; type: number; useCount: number }> = [];

  // Tab overview state
  private tabOverviewTabs: Array<{ tabId: string; tab: TabInfo; element: HTMLElement }> | null = null;
  private tabOverviewCloseHandler: ((e: KeyboardEvent | MouseEvent) => void) | null = null;

  constructor() {
    this.host = window.location.hostname || 'localhost';
    this.fileTransfer = new FileTransferHandler();

    this.commandPalette = new CommandPalette((action) => this.executeCommand(action));
    this.uploadDialog = new UploadDialog((file) => this.uploadFile(file));
    this.downloadDialog = new DownloadDialog((path) => this.requestDownload(path));
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
    PANEL_PORT = config.panelWsPort;
    CONTROL_PORT = config.controlWsPort;
    FILE_PORT = config.fileWsPort;

    if (config.colors) {
      applyColors(config.colors);
    }

    // Connect WebSockets
    this.connectControl();
    if (FILE_PORT) {
      this.fileTransfer.connect(this.host, FILE_PORT);
    }

    // Create initial tab and panel
    this.createTab();

    // Setup keyboard shortcuts
    this.setupShortcuts();

    // Setup menus
    this.setupMenus();
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
    const wsUrl = `ws://${this.host}:${CONTROL_PORT}`;
    this.controlWs = new WebSocket(wsUrl);
    this.controlWs.binaryType = 'arraybuffer';

    this.controlWs.onopen = () => {
      console.log('Control channel connected');
      this.setStatus('connected');
    };

    this.controlWs.onmessage = (event) => {
      if (typeof event.data === 'string') {
        this.handleJsonMessage(JSON.parse(event.data));
      } else if (event.data instanceof ArrayBuffer) {
        this.handleBinaryMessage(event.data);
      }
    };

    this.controlWs.onclose = () => {
      console.log('Control channel disconnected');
      this.setStatus('disconnected');
      setTimeout(() => this.connectControl(), 1000);
    };

    this.controlWs.onerror = () => {
      this.setStatus('error');
    };
  }

  private handleJsonMessage(msg: Record<string, unknown>): void {
    const type = msg.type as string;

    switch (type) {
      case 'auth_state':
        this.handleAuthState(msg);
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
    const msgType = view.getUint8(0);

    switch (msgType) {
      case 0x01: // PANEL_CREATED
        this.handlePanelCreated(data);
        break;
      case 0x02: // PANEL_CLOSED
        this.handlePanelClosed(data);
        break;
      case 0x03: // TITLE_CHANGED
        this.handleTitleChanged(data);
        break;
      case 0x04: // PWD_CHANGED
        this.handlePwdChanged(data);
        break;
      case 0x05: // BELL
        this.handleBell(data);
        break;
      case 0x12: // FILE_DATA (single file download response)
        this.handleFileData(data);
        break;
      case 0x15: // FOLDER_DATA (zip download response)
        this.handleFolderData(data);
        break;
    }
  }

  private handlePanelCreated(data: ArrayBuffer): void {
    const view = new DataView(data);
    const panelId = view.getUint32(1, true);

    if (this.pendingSplit) {
      this.completePendingSplit(panelId);
    }
  }

  private handlePanelClosed(data: ArrayBuffer): void {
    const view = new DataView(data);
    const serverId = view.getUint32(1, true);

    for (const [id, panel] of this.panels) {
      if (panel.serverId === serverId) {
        this.panels.delete(id);
        panel.destroy();
        break;
      }
    }
  }

  private handleTitleChanged(data: ArrayBuffer): void {
    const view = new DataView(data);
    const bytes = new Uint8Array(data);

    const serverId = view.getUint32(1, true);
    const titleLen = view.getUint16(5, true);
    const title = new TextDecoder().decode(bytes.slice(7, 7 + titleLen));

    this.updatePanelTitle(serverId, title);
  }

  private handlePwdChanged(data: ArrayBuffer): void {
    const view = new DataView(data);
    const bytes = new Uint8Array(data);

    const serverId = view.getUint32(1, true);
    const pwdLen = view.getUint16(5, true);
    const pwd = new TextDecoder().decode(bytes.slice(7, 7 + pwdLen));

    this.updatePanelPwd(serverId, pwd);
  }

  private handleBell(data: ArrayBuffer): void {
    const view = new DataView(data);
    const serverId = view.getUint32(1, true);
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

  // ============================================================================
  // Tab Management
  // ============================================================================

  createTab(title = 'Terminal'): string {
    const tabId = String(this.nextTabId++);
    const container = document.createElement('div');
    container.className = 'tab-content';
    container.id = `tab-${tabId}`;

    this.panelsEl?.appendChild(container);

    const panel = this.createPanel(container);
    const root = SplitContainer.createLeaf(panel);
    container.appendChild(root.element);

    this.tabs.set(tabId, {
      id: tabId,
      title,
      root,
      element: container,
    });

    this.addTabUI(tabId, title);
    this.switchToTab(tabId);
    return tabId;
  }

  private createPanel(container: HTMLElement, serverId: number | null = null): Panel {
    const id = generateId();
    const panel = new Panel(id, container, serverId, {
      onResize: (panelId, width, height) => this.sendResizePanel(panelId, width, height),
      onViewAction: (action, data) => this.handleViewAction(panel, action, data),
    });

    this.panels.set(id, panel);
    panel.connect(this.host, PANEL_PORT);

    if (!this.activePanel) {
      this.setActivePanel(panel);
    }

    return panel;
  }

  private setActivePanel(panel: Panel): void {
    this.activePanel = panel;
    panel.focus();

    if (panel.serverId !== null) {
      this.sendFocusPanel(panel.serverId);
    }

    this.updateTitleForPanel(panel);
  }

  switchToTab(tabId: string): void {
    if (this.activeTab) {
      const currentTab = this.tabs.get(this.activeTab);
      currentTab?.element.classList.remove('active');
    }

    const tab = this.tabs.get(tabId);
    if (tab) {
      tab.element.classList.add('active');
      this.activeTab = tabId;
      this.updateTabUIActive(tabId);

      // Update tab history
      const histIndex = this.tabHistory.indexOf(tabId);
      if (histIndex !== -1) {
        this.tabHistory.splice(histIndex, 1);
      }
      this.tabHistory.push(tabId);

      // Focus the first panel in this tab
      const panels = tab.root.getAllPanels();
      if (panels.length > 0) {
        this.setActivePanel(panels[0]);
      }
    }
  }

  closeTab(tabId: string): void {
    const tab = this.tabs.get(tabId);
    if (!tab || this.tabs.size <= 1) return;

    // Destroy all panels in this tab
    tab.root.destroy();

    tab.element.remove();
    this.removeTabUI(tabId);
    this.tabs.delete(tabId);

    // Remove from history
    const histIndex = this.tabHistory.indexOf(tabId);
    if (histIndex !== -1) {
      this.tabHistory.splice(histIndex, 1);
    }

    // Switch to most recent tab
    if (this.activeTab === tabId) {
      const nextTab = this.tabHistory[this.tabHistory.length - 1] || Array.from(this.tabs.keys())[0];
      if (nextTab) {
        this.switchToTab(nextTab);
      }
    }
  }

  closeActivePanel(): void {
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
    // Keep at least one tab
    for (let i = 0; i < tabIds.length - 1; i++) {
      this.closeTab(tabIds[i]);
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

    // Request new panel from server
    const rect = this.activePanel.canvas.getBoundingClientRect();
    const width = Math.floor(rect.width / 2);
    const height = Math.floor(rect.height / 2);

    this.pendingSplit = {
      parentPanelId: this.activePanel.serverId!,
      direction,
      container,
    };

    this.sendSplitPanel(this.activePanel.serverId!, direction, width, height);
  }

  private completePendingSplit(newPanelId: number): void {
    if (!this.pendingSplit || !this.activeTab) return;

    const { direction, container } = this.pendingSplit;
    const tab = this.tabs.get(this.activeTab);
    if (!tab) return;

    const newPanel = this.createPanel(tab.element, newPanelId);
    container.split(direction as 'right' | 'down' | 'left' | 'up', newPanel);

    this.setActivePanel(newPanel);
    this.pendingSplit = null;
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

    tab.innerHTML = `
      <span class="close">×</span>
      <span class="title-wrapper">
        <span class="indicator">•</span>
        <span class="title">${displayTitle}</span>
      </span>
      <span class="hotkey">${hotkeyHint}</span>
    `;

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
        const title = tabEl?.textContent || '';

        document.title = title || '👻';
        const appTitle = document.getElementById('app-title');
        if (appTitle) appTitle.textContent = title || '👻';
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
    }
  }

  private updatePanelPwd(serverId: number, pwd: string): void {
    for (const [, panel] of this.panels) {
      if (panel.serverId === serverId) {
        panel.pwd = pwd;
        break;
      }
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
      titleBar.innerHTML = `
        <span class="tab-preview-close">✕</span>
        <span class="tab-preview-title-text">
          <span class="tab-preview-indicator">•</span>
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
    console.log(`View action from panel ${panel.id}:`, action, data);
  }

  // ============================================================================
  // Server Communication
  // ============================================================================

  private sendFocusPanel(serverId: number): void {
    if (this.controlWs?.readyState === WebSocket.OPEN) {
      const msg = new ArrayBuffer(5);
      const view = new DataView(msg);
      view.setUint8(0, 0x81); // FOCUS_PANEL
      view.setUint32(1, serverId, true);
      this.controlWs.send(msg);
    }
  }

  private sendResizePanel(serverId: number, width: number, height: number): void {
    if (this.controlWs?.readyState === WebSocket.OPEN) {
      const msg = new ArrayBuffer(13);
      const view = new DataView(msg);
      view.setUint8(0, 0x82); // RESIZE_PANEL
      view.setUint32(1, serverId, true);
      view.setUint32(5, width, true);
      view.setUint32(9, height, true);
      this.controlWs.send(msg);
    }
  }

  private sendClosePanel(serverId: number): void {
    if (this.controlWs?.readyState === WebSocket.OPEN) {
      const msg = new ArrayBuffer(5);
      const view = new DataView(msg);
      view.setUint8(0, 0x83); // CLOSE_PANEL
      view.setUint32(1, serverId, true);
      this.controlWs.send(msg);
    }
  }

  private sendSplitPanel(parentPanelId: number, direction: string, width: number, height: number): void {
    if (this.controlWs?.readyState === WebSocket.OPEN) {
      const dirCode = { right: 0, down: 1, left: 2, up: 3 }[direction] ?? 0;
      const msg = new ArrayBuffer(14);
      const view = new DataView(msg);
      view.setUint8(0, 0x84); // SPLIT_PANEL
      view.setUint32(1, parentPanelId, true);
      view.setUint8(5, dirCode);
      view.setUint32(6, width, true);
      view.setUint32(10, height, true);
      this.controlWs.send(msg);
    }
  }

  private sendViewAction(serverId: number, action: string): void {
    if (this.controlWs?.readyState === WebSocket.OPEN) {
      const actionBytes = new TextEncoder().encode(action);
      const msg = new ArrayBuffer(7 + actionBytes.length);
      const view = new DataView(msg);
      view.setUint8(0, 0x85); // VIEW_ACTION
      view.setUint32(1, serverId, true);
      view.setUint16(5, actionBytes.length, true);
      new Uint8Array(msg).set(actionBytes, 7);
      this.controlWs.send(msg);
    }
  }

  // ============================================================================
  // File Transfer
  // ============================================================================

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

  private handleAuthState(msg: Record<string, unknown>): void {
    console.log('Auth state:', msg);
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
    this.commandPalette.show();
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
    });
  }

  // ============================================================================
  // Menus
  // ============================================================================

  private setupMenus(): void {
    document.querySelectorAll('.menu-item').forEach(item => {
      item.addEventListener('click', () => {
        const action = (item as HTMLElement).dataset.action;
        if (!action) return;

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
        }
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
