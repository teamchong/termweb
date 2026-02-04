<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import TabBar from './components/TabBar.svelte';
  import StatusDot from './components/StatusDot.svelte';
  import CommandPalette from './components/CommandPalette.svelte';
  import Menu, { type MenuItem } from './components/Menu.svelte';
  import QuickTerminal from './components/QuickTerminal.svelte';
  import TabOverview from './components/TabOverview.svelte';
  import { tabs, activeTabId } from './stores/index';
  import { connectionStatus, initMuxClient, type MuxClient } from './services/mux';

  // MuxClient instance
  let muxClient: MuxClient | null = $state(null);

  // DOM refs
  let panelsEl: HTMLElement | undefined = $state();

  // Loading state
  let showLoading = $state(true);

  // Mobile menu state
  let mobileMenuOpen = $state(false);

  // Command palette state
  let commandPaletteOpen = $state(false);

  // Quick terminal ref
  let quickTerminalRef: QuickTerminal | undefined = $state();

  // Tab overview state
  let tabOverviewOpen = $state(false);

  // Subscribe to connection status
  let status = $derived($connectionStatus);

  // Check if there are tabs
  let hasTabs = $derived($tabs.size > 0);

  // Menu definitions - disabled state based on hasTabs
  // File menu: New Tab, Upload/Download, Split operations, Close Tab/All
  let fileMenuItems = $derived<MenuItem[]>([
    { label: 'New Tab', action: '_new_tab', shortcut: '⌘/', icon: '⊞' },
    { separator: true },
    { label: 'Upload...', action: '_upload', shortcut: '⌘U', icon: '⬆', disabled: !hasTabs },
    { label: 'Download...', action: '_download', shortcut: '⌘⇧S', icon: '⬇', disabled: !hasTabs },
    { separator: true },
    { label: 'Split Right', action: '_split_right', shortcut: '⌘D', icon: '⬚▐', disabled: !hasTabs },
    { label: 'Split Down', action: '_split_down', shortcut: '⌘⇧D', icon: '⬚▄', disabled: !hasTabs },
    { label: 'Split Left', action: '_split_left', icon: '▌⬚', disabled: !hasTabs },
    { label: 'Split Up', action: '_split_up', icon: '▀⬚', disabled: !hasTabs },
    { separator: true },
    { label: 'Close Tab', action: '_close_tab', shortcut: '⌘.', icon: '✕', disabled: !hasTabs },
    { label: 'Close Other Tabs', action: '_close_other_tabs', icon: '⊟', disabled: !hasTabs },
    { label: 'Close All Tabs', action: '_close_all_tabs', shortcut: '⌘⇧.', icon: '⊠', disabled: !hasTabs },
  ]);

  // Edit menu: Undo/Redo, Copy, Paste, Select All
  let editMenuItems = $derived<MenuItem[]>([
    { label: 'Undo', action: 'undo', icon: '↩', disabled: !hasTabs },
    { label: 'Redo', action: 'redo', icon: '↪', disabled: !hasTabs },
    { separator: true },
    { label: 'Copy', action: 'copy', shortcut: '⌘C', icon: '⧉', disabled: !hasTabs },
    { label: 'Paste', action: 'paste', shortcut: '⌘V', icon: '📋', disabled: !hasTabs },
    { label: 'Paste Selection', action: 'paste-selection', shortcut: '⌘⇧V', icon: '📄', disabled: !hasTabs },
    { label: 'Select All', action: 'select-all', shortcut: '⌘A', icon: '▣', disabled: !hasTabs },
  ]);

  // View menu: Show All Tabs, Font, Command Palette, Change Title, Quick Terminal, Inspector
  let viewMenuItems = $derived<MenuItem[]>([
    { label: 'Show All Tabs', action: '_show_all_tabs', shortcut: '⌘⇧A', icon: '⊞', disabled: !hasTabs },
    { separator: true },
    { label: 'Increase Font', action: 'zoom-in', shortcut: '⌘=', icon: 'A+', disabled: !hasTabs },
    { label: 'Decrease Font', action: 'zoom-out', shortcut: '⌘-', icon: 'A−', disabled: !hasTabs },
    { label: 'Reset Font', action: 'zoom-reset', shortcut: '⌘0', icon: 'A', disabled: !hasTabs },
    { separator: true },
    { label: 'Command Palette', action: '_command_palette', shortcut: '⌘⇧P', icon: '⌘' },
    { label: 'Change Title...', action: '_change_title', icon: '✎', disabled: !hasTabs },
    { separator: true },
    { label: 'Quick Terminal', action: '_quick_terminal', icon: '▼' },
    { separator: true },
    { label: 'Toggle Inspector', action: '_toggle_inspector', shortcut: '⌥⌘I', icon: '🔍', disabled: !hasTabs },
  ]);

  // Window menu: Fullscreen, Tab navigation, Split navigation/resize
  // Build dynamic tab list items with active marker and shortcuts
  let windowTabListItems = $derived<MenuItem[]>(
    Array.from($tabs.values()).map((tab, index) => ({
      label: tab.title || '👻',
      action: `_select_tab:${tab.id}`,
      icon: tab.id === $activeTabId ? '•' : '',
      shortcut: index < 9 ? `⌘${index + 1}` : undefined,
    }))
  );

  let windowMenuItems = $derived<MenuItem[]>([
    { label: 'Toggle Full Screen', action: '_toggle_fullscreen', shortcut: '⌘⇧F', icon: '⛶' },
    { label: 'Show Previous Tab', action: '_previous_tab', icon: '◀', disabled: !hasTabs },
    { label: 'Show Next Tab', action: '_next_tab', icon: '▶', disabled: !hasTabs },
    { separator: true },
    // Split menu items (split-menu-item class in original - visible only when splits exist)
    { label: 'Zoom Split', action: '_zoom_split', shortcut: '⌘⇧↵', icon: '⤢', disabled: !hasTabs },
    { label: 'Select Previous Split', action: '_previous_split', shortcut: '⌘[', icon: '⇤', disabled: !hasTabs },
    { label: 'Select Next Split', action: '_next_split', shortcut: '⌘]', icon: '⇥', disabled: !hasTabs },
    // Select Split submenu
    {
      label: 'Select Split',
      icon: '◫',
      disabled: !hasTabs,
      submenu: [
        { label: 'Select Split Above', action: '_select_split_up', shortcut: '⌘⇧↑', icon: '↑', disabled: !hasTabs },
        { label: 'Select Split Below', action: '_select_split_down', shortcut: '⌘⇧↓', icon: '↓', disabled: !hasTabs },
        { label: 'Select Split Left', action: '_select_split_left', shortcut: '⌘⇧←', icon: '←', disabled: !hasTabs },
        { label: 'Select Split Right', action: '_select_split_right', shortcut: '⌘⇧→', icon: '→', disabled: !hasTabs },
      ],
    },
    // Resize Split submenu
    {
      label: 'Resize Split',
      icon: '⇔',
      disabled: !hasTabs,
      submenu: [
        { label: 'Equalize Splits', action: '_equalize_splits', icon: '=', disabled: !hasTabs },
        { label: 'Move Divider Up', action: '_resize_split_up', icon: '↑', disabled: !hasTabs },
        { label: 'Move Divider Down', action: '_resize_split_down', icon: '↓', disabled: !hasTabs },
        { label: 'Move Divider Left', action: '_resize_split_left', icon: '←', disabled: !hasTabs },
        { label: 'Move Divider Right', action: '_resize_split_right', icon: '→', disabled: !hasTabs },
      ],
    },
    // Separator before Window Tab List
    ...(windowTabListItems.length > 0 ? [{ separator: true } as MenuItem] : []),
    // Window Tab List (dynamically populated)
    ...windowTabListItems,
  ]);

  // Admin menu (shown only for admin users)
  let adminMenuItems = $derived<MenuItem[]>([
    { label: 'Sessions', action: '_sessions', icon: '📂' },
    { label: 'Access Control', action: '_access_control', icon: '🔐' },
  ]);

  // Tab event handlers
  function handleNewTab() {
    muxClient?.createTab();
  }

  function handleSelectTab(id: string) {
    muxClient?.selectTab(id);
  }

  function handleCloseTab(id: string) {
    muxClient?.closeTab(id);
  }

  function handleShowAllTabs() {
    tabOverviewOpen = true;
  }

  function toggleQuickTerminal() {
    const container = quickTerminalRef?.getContainer();
    if (container) {
      muxClient?.toggleQuickTerminal(container);
    }
  }

  // Handle command execution from command palette
  function handleCommand(action: string) {
    switch (action) {
      case '_new_tab':
        handleNewTab();
        break;
      case '_close_tab': {
        const tabId = $activeTabId;
        if (tabId) handleCloseTab(tabId);
        break;
      }
      case '_show_all_tabs':
        handleShowAllTabs();
        break;
      case '_split_right': {
        const panel = muxClient?.getActivePanel();
        if (panel) muxClient?.splitPanel(panel, 'right');
        break;
      }
      case '_split_down': {
        const panel = muxClient?.getActivePanel();
        if (panel) muxClient?.splitPanel(panel, 'down');
        break;
      }
      case '_split_left': {
        const panel = muxClient?.getActivePanel();
        if (panel) muxClient?.splitPanel(panel, 'left');
        break;
      }
      case '_split_up': {
        const panel = muxClient?.getActivePanel();
        if (panel) muxClient?.splitPanel(panel, 'up');
        break;
      }
      case '_command_palette':
        commandPaletteOpen = true;
        break;
      case '_toggle_inspector':
        muxClient?.toggleInspector();
        break;
      case '_upload':
        muxClient?.showUploadDialog();
        break;
      case '_download':
        muxClient?.showDownloadDialog();
        break;
      case '_close_all_tabs':
        // Close all tabs
        for (const tab of $tabs.values()) {
          muxClient?.closeTab(tab.id);
        }
        break;
      case '_close_other_tabs': {
        // Close all tabs except the active one
        const currentTabId = $activeTabId;
        for (const tab of $tabs.values()) {
          if (tab.id !== currentTabId) {
            muxClient?.closeTab(tab.id);
          }
        }
        break;
      }
      case '_toggle_fullscreen':
        if (document.fullscreenElement) {
          document.exitFullscreen();
        } else {
          document.documentElement.requestFullscreen();
        }
        break;
      case '_quick_terminal':
        toggleQuickTerminal();
        break;
      case '_change_title': {
        const newTitle = prompt('Enter new title:');
        if (newTitle && $activeTabId) {
          tabs.updateTab($activeTabId, { title: newTitle });
        }
        break;
      }
      case '_previous_tab':
      case '_next_tab':
      case '_previous_split':
      case '_next_split':
      case '_zoom_split':
      case '_equalize_splits':
      case '_select_split_up':
      case '_select_split_down':
      case '_select_split_left':
      case '_select_split_right':
      case '_resize_split_up':
      case '_resize_split_down':
      case '_resize_split_left':
      case '_resize_split_right':
        // TODO: implement tab/split navigation in muxClient
        break;
      case '_sessions':
        muxClient?.showSessionsDialog();
        break;
      case '_access_control':
        muxClient?.showAccessControlDialog();
        break;
      default:
        // Handle dynamic tab selection from Window Tab List
        if (action.startsWith('_select_tab:')) {
          const tabId = action.slice('_select_tab:'.length);
          muxClient?.selectTab(tabId);
        } else {
          // Send other commands to server via control WebSocket
          muxClient?.sendViewAction(action);
        }
        break;
    }
  }

  onMount(async () => {
    if (panelsEl) {
      try {
        muxClient = await initMuxClient(panelsEl);
      } catch (err) {
        console.error('Failed to initialize MuxClient:', err);
      } finally {
        showLoading = false;
      }
    }
  });

  onDestroy(() => {
    muxClient?.destroy();
  });

  // Setup keyboard shortcuts
  function handleKeydown(e: KeyboardEvent) {
    // Skip if dialog is open
    if (commandPaletteOpen || tabOverviewOpen) {
      return;
    }
    const downloadDialog = document.getElementById('download-dialog');
    const uploadDialog = document.getElementById('upload-dialog');
    if (downloadDialog?.classList.contains('visible') ||
        uploadDialog?.classList.contains('visible')) {
      return;
    }

    const key = e.key.toLowerCase();

    if (e.metaKey && e.shiftKey && key === 'p') {
      e.preventDefault();
      commandPaletteOpen = true;
    } else if (e.metaKey && key === '/') {
      e.preventDefault();
      handleNewTab();
    } else if (e.metaKey && e.shiftKey && key === '.') {
      e.preventDefault();
      handleCommand('_close_all_tabs');
    } else if (e.metaKey && key === '.') {
      e.preventDefault();
      const tabId = $activeTabId;
      if (tabId) handleCloseTab(tabId);
    } else if (e.metaKey && key === 'd') {
      e.preventDefault();
      if (e.shiftKey) {
        handleCommand('_split_down');
      } else {
        handleCommand('_split_right');
      }
    } else if (e.metaKey && e.shiftKey && (key === 'a' || key === '\\')) {
      e.preventDefault();
      handleShowAllTabs();
    } else if (e.metaKey && key === 'u') {
      e.preventDefault();
      handleCommand('_upload');
    } else if (e.metaKey && e.shiftKey && key === 's') {
      e.preventDefault();
      handleCommand('_download');
    } else if (e.metaKey && e.shiftKey && key === 'f') {
      e.preventDefault();
      handleCommand('_toggle_fullscreen');
    } else if (e.metaKey && e.shiftKey && key === '[') {
      e.preventDefault();
      handleCommand('_previous_tab');
    } else if (e.metaKey && e.shiftKey && key === ']') {
      e.preventDefault();
      handleCommand('_next_tab');
    } else if (e.metaKey && key === '[') {
      e.preventDefault();
      handleCommand('_previous_split');
    } else if (e.metaKey && key === ']') {
      e.preventDefault();
      handleCommand('_next_split');
    } else if (e.metaKey && e.shiftKey && key === 'enter') {
      e.preventDefault();
      handleCommand('_zoom_split');
    } else if (e.metaKey && e.shiftKey) {
      // Cmd+Shift+arrow keys for split selection
      if (key === 'arrowup') {
        e.preventDefault();
        handleCommand('_select_split_up');
      } else if (key === 'arrowdown') {
        e.preventDefault();
        handleCommand('_select_split_down');
      } else if (key === 'arrowleft') {
        e.preventDefault();
        handleCommand('_select_split_left');
      } else if (key === 'arrowright') {
        e.preventDefault();
        handleCommand('_select_split_right');
      }
    } else if (e.metaKey && e.altKey && key === 'i') {
      e.preventDefault();
      handleCommand('_toggle_inspector');
    } else if (e.metaKey && key === '=') {
      e.preventDefault();
      handleCommand('zoom-in');
    } else if (e.metaKey && key === '-') {
      e.preventDefault();
      handleCommand('zoom-out');
    } else if (e.metaKey && key === '0') {
      e.preventDefault();
      handleCommand('zoom-reset');
    } else if (e.metaKey && key >= '1' && key <= '9') {
      // Tab switching with Cmd+1-9
      e.preventDefault();
      const tabIndex = parseInt(key) - 1;
      const tabArray = Array.from($tabs.values());
      if (tabIndex < tabArray.length) {
        muxClient?.selectTab(tabArray[tabIndex].id);
      }
    }
  }
</script>

<svelte:window onkeydown={handleKeydown} />

<div class="app-container">
  <!-- Titlebar -->
  <div id="titlebar">
    <div id="title-left">
      <span id="app-title">👻</span>
    </div>
    <div id="title-right">
      <!-- svelte-ignore a11y_click_events_have_key_events -->
      <!-- svelte-ignore a11y_no_static_element_interactions -->
      <span id="hamburger" onclick={() => mobileMenuOpen = !mobileMenuOpen}>☰</span>
      <div id="menubar" class:open={mobileMenuOpen}>
        <Menu label="File" items={fileMenuItems} onAction={handleCommand} />
        <Menu label="Edit" items={editMenuItems} onAction={handleCommand} />
        <Menu label="View" items={viewMenuItems} onAction={handleCommand} />
        <Menu label="Window" items={windowMenuItems} onAction={handleCommand} />
        <Menu label="Admin" items={adminMenuItems} onAction={handleCommand} />
      </div>
      <StatusDot {status} />
    </div>
  </div>

  <!-- Toolbar with tabs -->
  <div id="toolbar">
    <TabBar
      onNewTab={handleNewTab}
      onSelectTab={handleSelectTab}
      onCloseTab={handleCloseTab}
      onShowAllTabs={handleShowAllTabs}
    />
  </div>

  <!-- Panels area -->
  <div id="panels" bind:this={panelsEl}>
    {#if showLoading}
      <div id="panels-loading">
        <div class="spinner"></div>
        <span>Loading...</span>
      </div>
    {/if}

    {#if !showLoading && !hasTabs}
      <div id="panels-empty" class="visible">
        <h2>No Open Tabs</h2>
        <div class="shortcuts">
          <button type="button" class="shortcut" onclick={handleNewTab}>
            <span>New Tab</span><kbd>⌘/</kbd>
          </button>
          <div class="shortcut"><span>Split Right</span><kbd>⌘D</kbd></div>
          <div class="shortcut"><span>Split Down</span><kbd>⌘⇧D</kbd></div>
          <div class="shortcut"><span>Command Palette</span><kbd>⌘⇧P</kbd></div>
        </div>
      </div>
    {/if}

    <!-- Tab content panels are dynamically created by MuxClient -->
  </div>

  <!-- Command Palette -->
  <CommandPalette
    open={commandPaletteOpen}
    onClose={() => commandPaletteOpen = false}
    onExecute={handleCommand}
  />

  <!-- Quick Terminal -->
  <QuickTerminal
    bind:this={quickTerminalRef}
    onClose={toggleQuickTerminal}
  />

  <!-- Tab Overview -->
  <TabOverview
    open={tabOverviewOpen}
    panelsEl={panelsEl}
    {muxClient}
    onClose={() => tabOverviewOpen = false}
    onSelectTab={handleSelectTab}
    onCloseTab={handleCloseTab}
    onNewTab={handleNewTab}
  />
</div>

<style>
  .app-container {
    display: flex;
    flex-direction: column;
    height: 100vh;
    background: var(--bg);
    color: var(--text);
  }

  #titlebar {
    background: var(--toolbar-bg);
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 4px 10px;
    border-bottom: 1px solid rgba(128,128,128,0.2);
    position: relative;
  }

  #title-left {
    display: flex;
    align-items: center;
    gap: 2px;
  }

  #title-right {
    display: flex;
    align-items: center;
    gap: 4px;
  }

  #app-title {
    font-size: 13px;
    font-weight: 500;
    color: var(--text);
  }

  #hamburger {
    display: none;
    padding: 4px 8px;
    font-size: 18px;
    cursor: pointer;
    color: var(--text);
  }

  #menubar {
    display: flex;
    gap: 2px;
  }

  /* Mobile menu */
  @media (hover: none) {
    #hamburger {
      display: block;
      font-size: 22px;
      padding: 6px 10px;
    }

    #title-right {
      position: relative;
    }

    #menubar {
      display: none;
      position: absolute;
      top: 100%;
      right: 0;
      background: var(--toolbar-bg);
      border: 1px solid rgba(128,128,128,0.3);
      border-radius: 10px;
      padding: 12px;
      flex-direction: column;
      z-index: 100;
      box-shadow: 0 4px 12px rgba(0,0,0,0.3);
      min-width: 280px;
      gap: 4px;
      max-height: calc(100vh - 80px);
      overflow-y: auto;
    }

    #menubar.open {
      display: flex;
    }
  }

  #toolbar {
    background: var(--toolbar-bg);
    display: flex;
    align-items: center;
    padding: 5px;
  }

  #panels {
    flex: 1;
    position: relative;
    background: var(--bg);
  }

  #panels-loading {
    position: absolute;
    inset: 0;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 12px;
    color: #666;
    font: 14px system-ui, sans-serif;
  }

  #panels-loading .spinner {
    width: 24px;
    height: 24px;
    border: 2px solid #333;
    border-top-color: var(--accent);
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
  }

  @keyframes spin {
    to { transform: rotate(360deg); }
  }

  #panels-empty {
    position: absolute;
    inset: 0;
    display: none;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 24px;
    color: #888;
    font: 14px system-ui, sans-serif;
  }

  #panels-empty.visible {
    display: flex;
  }

  #panels-empty h2 {
    margin: 0;
    font-size: 20px;
    font-weight: 500;
    color: #aaa;
  }

  .shortcuts {
    display: flex;
    flex-direction: column;
    gap: 6px;
    min-width: 200px;
  }

  .shortcut {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 6px 12px;
    border-radius: 4px;
    background: transparent;
    border: none;
    color: inherit;
    font: inherit;
    cursor: pointer;
    text-align: left;
    width: 100%;
  }

  .shortcut:hover {
    background: rgba(255,255,255,0.05);
  }

  .shortcut span {
    color: #aaa;
  }

  .shortcut kbd {
    background: #333;
    padding: 3px 6px;
    border-radius: 3px;
    font-family: ui-monospace, monospace;
    font-size: 11px;
    color: #888;
    margin-left: 24px;
  }

  /* Panel and split container styles */
  :global(.tab-content) {
    position: absolute;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    display: none;
  }

  :global(.tab-content.active) {
    display: flex;
  }

  :global(.panel) {
    position: absolute;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    display: flex;
    flex-direction: column;
    background: var(--bg);
  }

  :global(.panel video),
  :global(.panel canvas) {
    flex: 1;
    min-height: 0;
    width: 100%;
    height: 100%;
    object-fit: contain;
    object-position: top left;
    background: var(--bg);
    outline: none;
  }

  :global(.split-container) {
    display: flex;
    width: 100%;
    height: 100%;
  }

  :global(.split-container.horizontal) {
    flex-direction: row;
  }

  :global(.split-container.vertical) {
    flex-direction: column;
  }

  :global(.split-container > .split-pane) {
    overflow: hidden;
    position: relative;
  }

  :global(.split-container > .split-pane > .panel) {
    position: absolute;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    display: flex;
  }

  :global(.split-container > .split-pane > .panel:not(.focused)) {
    opacity: 0.6;
  }

  :global(.split-container > .split-pane > .panel.focused) {
    opacity: 1;
  }

  :global(.split-divider) {
    background: rgba(128,128,128,0.3);
    flex-shrink: 0;
    z-index: 10;
  }

  :global(.split-divider:hover) {
    background: var(--accent);
  }

  :global(.split-container.horizontal > .split-divider) {
    width: 4px;
    cursor: col-resize;
  }

  :global(.split-container.vertical > .split-divider) {
    height: 4px;
    cursor: row-resize;
  }

  /* Panel content and loading */
  :global(.panel-content) {
    flex: 1;
    min-height: 0;
    position: relative;
    display: flex;
    flex-direction: column;
  }

  :global(.panel-canvas) {
    flex: 1;
    min-height: 0;
  }

  :global(.panel-loading) {
    position: absolute;
    inset: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--text-dim);
    font: 14px system-ui, sans-serif;
    background: var(--bg);
  }

  /* Inspector styles */
  :global(.panel-inspector) {
    display: none;
    flex-direction: column;
    background: var(--toolbar-bg);
    border-top: 1px solid rgba(128, 128, 128, 0.3);
    min-height: 100px;
    max-height: 60%;
    overflow: hidden;
  }

  :global(.panel-inspector.visible) {
    display: flex;
  }

  :global(.inspector-resize) {
    height: 4px;
    cursor: ns-resize;
    background: transparent;
    flex-shrink: 0;
  }

  :global(.inspector-resize:hover) {
    background: var(--accent);
  }

  :global(.inspector-content) {
    flex: 1;
    display: flex;
    overflow: hidden;
  }

  :global(.inspector-left),
  :global(.inspector-right) {
    flex: 1;
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }

  :global(.inspector-left) {
    border-right: 1px solid rgba(128, 128, 128, 0.2);
  }

  :global(.inspector-left-header),
  :global(.inspector-right-header) {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 4px 8px;
    background: rgba(0, 0, 0, 0.2);
    border-bottom: 1px solid rgba(128, 128, 128, 0.2);
    flex-shrink: 0;
  }

  :global(.inspector-left.header-hidden .inspector-left-header),
  :global(.inspector-right.header-hidden .inspector-right-header) {
    display: none;
  }

  :global(.inspector-collapsed-toggle) {
    display: none;
    height: 20px;
    background: rgba(0, 0, 0, 0.2);
    cursor: pointer;
    flex-shrink: 0;
  }

  :global(.inspector-collapsed-toggle:hover) {
    background: rgba(255, 255, 255, 0.1);
  }

  :global(.inspector-left.header-hidden .inspector-collapsed-toggle),
  :global(.inspector-right.header-hidden .inspector-collapsed-toggle) {
    display: block;
  }

  :global(.inspector-dock-wrapper) {
    position: relative;
  }

  :global(.inspector-dock-icon) {
    width: 16px;
    height: 16px;
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    opacity: 0.5;
    border-radius: 3px;
  }

  :global(.inspector-dock-icon:hover) {
    opacity: 1;
    background: rgba(255, 255, 255, 0.1);
  }

  :global(.inspector-dock-icon::before) {
    content: '⋮';
    font-size: 12px;
    color: var(--text);
  }

  :global(.inspector-dock-menu) {
    display: none;
    position: absolute;
    top: 100%;
    left: 0;
    background: var(--toolbar-bg);
    border: 1px solid rgba(128, 128, 128, 0.3);
    border-radius: 4px;
    box-shadow: 0 2px 8px rgba(0, 0, 0, 0.3);
    z-index: 100;
    min-width: 120px;
  }

  :global(.inspector-dock-menu.visible) {
    display: block;
  }

  :global(.inspector-dock-menu-item) {
    padding: 6px 12px;
    cursor: pointer;
    font-size: 12px;
    color: var(--text);
    white-space: nowrap;
  }

  :global(.inspector-dock-menu-item:hover) {
    background: rgba(255, 255, 255, 0.1);
  }

  :global(.inspector-tabs) {
    display: flex;
    gap: 2px;
  }

  :global(.inspector-tab) {
    padding: 4px 8px;
    background: transparent;
    border: none;
    color: var(--text-dim);
    font-size: 11px;
    cursor: pointer;
    border-radius: 3px;
  }

  :global(.inspector-tab:hover) {
    background: rgba(255, 255, 255, 0.1);
    color: var(--text);
  }

  :global(.inspector-tab.active) {
    background: rgba(255, 255, 255, 0.15);
    color: var(--text);
  }

  :global(.inspector-right-title) {
    font-size: 11px;
    font-weight: 500;
    color: var(--text);
  }

  :global(.inspector-main),
  :global(.inspector-sidebar) {
    flex: 1;
    overflow-y: auto;
    padding: 8px;
  }

  :global(.inspector-simple-section) {
    margin-bottom: 8px;
  }

  :global(.inspector-simple-title) {
    font-size: 10px;
    font-weight: 600;
    color: var(--text-dim);
    text-transform: uppercase;
    letter-spacing: 0.5px;
  }

  :global(.inspector-simple-section hr) {
    border: none;
    border-top: 1px solid rgba(128, 128, 128, 0.2);
    margin: 4px 0 8px;
  }

  :global(.inspector-row) {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 4px 0;
    font-size: 11px;
  }

  :global(.inspector-label) {
    color: var(--text-dim);
  }

  :global(.inspector-value) {
    color: var(--text);
    font-family: ui-monospace, monospace;
  }

  /* Bell animation */
  :global(.panel.bell) {
    animation: bell-flash 0.15s ease-out;
  }

  @keyframes bell-flash {
    0% { filter: brightness(1); }
    50% { filter: brightness(1.5); }
    100% { filter: brightness(1); }
  }
</style>
