<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import TabBar from './components/TabBar.svelte';
  import StatusDot from './components/StatusDot.svelte';
  import CommandPalette from './components/CommandPalette.svelte';
  import Menu, { type MenuItem } from './components/Menu.svelte';
  import QuickTerminal from './components/QuickTerminal.svelte';
  import TabOverview from './components/TabOverview.svelte';
  import ShareDialog from './components/ShareDialog.svelte';
  import TransferDialog, { type TransferConfig } from './components/TransferDialog.svelte';
  import DownloadProgressDialog from './components/DownloadProgressDialog.svelte';
  import { tabs, activeTabId, activeTab, ui } from './stores/index';
  import { connectionStatus, initialLayoutLoaded, initMuxClient, type MuxClient } from './services/mux';

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

  // Share dialog state
  let shareDialogOpen = $state(false);

  // Transfer dialog state
  let transferDialogOpen = $state(false);
  let transferDialogMode: 'upload' | 'download' = $state('download');
  let transferDialogDefaultPath = $state('');
  let transferDialogInitialDirHandle: FileSystemDirectoryHandle | undefined = $state();
  let transferDialogInitialFiles: File[] | undefined = $state();

  // Download progress dialog state
  let downloadProgressOpen = $state(false);

  // Quick terminal ref
  let quickTerminalRef: QuickTerminal | undefined = $state();

  // Tab overview state (synced with server via ui store)
  let tabOverviewOpen = $derived($ui.overviewOpen);

  // Download progress state (supports multiple concurrent downloads)
  let activeDownloads = $state(new Map<number, {
    files: number;
    total: number;
    bytes: number;
    totalBytes: number;
    path?: string;
    status: 'active' | 'complete' | 'error';
    startTime: number;
    endTime?: number;
  }>());
  let pendingTransferPath = $state<string | null>(null);
  let opfsUsageBytes = $state(0);
  let opfsFileCount = $state(0);

  // Subscribe to connection status
  let status = $derived($connectionStatus);

  // Subscribe to initial layout loaded state
  let layoutLoaded = $derived($initialLayoutLoaded);

  // Check if there are tabs
  let hasTabs = $derived($tabs.size > 0);

  // Check if there are multiple tabs (for prev/next tab)
  let hasMultipleTabs = $derived($tabs.size > 1);

  // Show loading while waiting for initial layout from server
  let isLoading = $derived(showLoading || !layoutLoaded);

  // Menu definitions - disabled state based on hasTabs
  // File menu: New Tab, Upload/Download, Split operations, Close Tab/All
  let fileMenuItems = $derived<MenuItem[]>([
    { label: 'New Tab', action: '_new_tab', shortcut: '⌘/', icon: '⊞' },
    { separator: true },
    { label: 'Upload...', action: '_upload', shortcut: '⌘U', icon: '⬆', disabled: !hasTabs },
    { label: 'Download...', action: '_download', shortcut: '⌘⇧S', icon: '⬇', disabled: !hasTabs },
    { label: 'Transfer Monitor', action: '_transfer_monitor', icon: '⚡' },
    { separator: true },
    { label: 'Split Right', action: '_split_right', shortcut: '⌘D', icon: '⬚▐', disabled: !hasTabs },
    { label: 'Split Down', action: '_split_down', shortcut: '⌘⇧D', icon: '⬚▄', disabled: !hasTabs },
    { label: 'Split Left', action: '_split_left', icon: '▌⬚', disabled: !hasTabs },
    { label: 'Split Up', action: '_split_up', icon: '▀⬚', disabled: !hasTabs },
    { separator: true },
    { label: 'Close', action: '_close', shortcut: '⌘.', icon: '✕', disabled: !hasTabs },
    { label: 'Close Tab', action: '_close_tab', shortcut: '⌥⌘.', icon: '⊠', disabled: !hasTabs },
    { label: 'Close Other Tabs', action: '_close_other_tabs', icon: '⊟', disabled: !hasTabs },
    { label: 'Close Window', action: '_close_window', shortcut: '⌘⇧.', icon: '⊠', disabled: !hasTabs },
  ]);

  // Edit menu: Copy, Paste, Select All
  let editMenuItems = $derived<MenuItem[]>([
    { label: 'Copy', action: 'copy_to_clipboard', shortcut: '⌘C', icon: '⧉', disabled: !hasTabs },
    { label: 'Paste', action: 'paste_from_clipboard', shortcut: '⌘V', icon: '📋', disabled: !hasTabs },
    { label: 'Paste Selection', action: 'paste_from_selection', shortcut: '⌘⇧V', icon: '📄', disabled: !hasTabs },
    { label: 'Select All', action: 'select_all', shortcut: '⌘A', icon: '▣', disabled: !hasTabs },
  ]);

  // View menu: Show All Tabs, Font, Command Palette, Change Title, Quick Terminal, Inspector
  let viewMenuItems = $derived<MenuItem[]>([
    { label: 'Show All Tabs', action: '_show_all_tabs', shortcut: '⌘⇧A', icon: '⊞', disabled: !hasTabs },
    { separator: true },
    { label: 'Increase Font', action: 'increase_font_size:1', shortcut: '⌘=', icon: 'A+', disabled: !hasTabs },
    { label: 'Decrease Font', action: 'decrease_font_size:1', shortcut: '⌘-', icon: 'A−', disabled: !hasTabs },
    { label: 'Reset Font', action: 'reset_font_size', shortcut: '⌘0', icon: 'A', disabled: !hasTabs },
    { separator: true },
    { label: 'Command Palette', action: '_command_palette', shortcut: '⌘⇧P', icon: '⌘' },
    { label: 'Change Title...', action: '_change_title', icon: '✎', disabled: !hasTabs },
    { separator: true },
    { label: 'Quick Terminal', action: '_quick_terminal', shortcut: '⌥⌘\\', icon: '▼' },
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
    { label: 'Show Previous Tab', action: '_previous_tab', icon: '◀', disabled: !hasMultipleTabs },
    { label: 'Show Next Tab', action: '_next_tab', icon: '▶', disabled: !hasMultipleTabs },
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

  // Share menu
  let shareMenuItems = $derived<MenuItem[]>([
    { label: 'Share URL', action: '_share_url', icon: '🔗' },
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
    ui.update(s => ({ ...s, overviewOpen: true }));
    muxClient?.setOverviewOpen(true);
  }

  function toggleQuickTerminal() {
    const container = quickTerminalRef?.getContainer();
    if (container) {
      muxClient?.toggleQuickTerminal(container);
    }
  }

  // UI fullscreen mode - hides titlebar and toolbar
  let isFullscreen = $state(false);

  function toggleFullscreen() {
    isFullscreen = !isFullscreen;
    // Trigger resize after DOM updates so panels reclaim space
    requestAnimationFrame(() => {
      window.dispatchEvent(new Event('resize'));
    });
  }

  // Transfer dialog helpers
  function openUploadDialog() {
    transferDialogMode = 'upload';
    transferDialogDefaultPath = muxClient?.getActivePanelPwd() || '';
    transferDialogInitialDirHandle = undefined;
    transferDialogInitialFiles = undefined;
    downloadProgressOpen = false; // Close transfer monitor when opening upload dialog
    transferDialogOpen = true;
  }

  function openDownloadDialog() {
    transferDialogMode = 'download';
    transferDialogDefaultPath = muxClient?.getActivePanelPwd() || '';
    transferDialogInitialDirHandle = undefined;
    transferDialogInitialFiles = undefined;
    downloadProgressOpen = false; // Close transfer monitor when opening download dialog
    transferDialogOpen = true;
  }

  function openFileDropDialog(files: File[]) {
    transferDialogMode = 'upload';
    transferDialogDefaultPath = muxClient?.getActivePanelPwd() || '';
    transferDialogInitialDirHandle = undefined;
    transferDialogInitialFiles = files;
    downloadProgressOpen = false; // Close transfer monitor when opening file drop dialog
    transferDialogOpen = true;
  }

  async function handleTransferExecute(config: TransferConfig) {
    if (!muxClient) return;
    const ft = muxClient.getFileTransfer();
    const options = { excludes: config.excludes, deleteExtra: config.deleteExtra, useGitignore: config.useGitignore };

    console.log('[App] handleTransferExecute START:', {
      mode: transferDialogMode,
      path: config.serverPath,
      hasPendingTransfer: !!ft['pendingTransfer'],
      activeTransfersCount: ft['activeTransfers'].size,
    });

    try {
      await muxClient.ensureFileWs();

      // Close config dialog and open progress dialog immediately
      transferDialogOpen = false;
      downloadProgressOpen = true;

      // Store pending path to display while waiting for first progress callback
      pendingTransferPath = config.serverPath;
      console.log('[App] Set pendingTransferPath:', pendingTransferPath);

      if (transferDialogMode === 'upload') {
        if (config.dirHandle) {
          await ft.startFolderUpload(config.dirHandle, config.serverPath, options);
        } else if (config.files) {
          await ft.startFilesUpload(config.files, config.serverPath, options);
        }
      } else {
        console.log('[App] Calling startFolderDownload...');
        await ft.startFolderDownload(config.serverPath, options);
        console.log('[App] startFolderDownload returned, hasPendingTransfer:', !!ft['pendingTransfer']);
      }
    } catch (err) {
      console.error('[App] Transfer failed:', err);
      pendingTransferPath = null;
    }
  }

  async function handleTransferPreview(config: TransferConfig) {
    if (!muxClient) return null;
    const options = { excludes: config.excludes, deleteExtra: config.deleteExtra, useGitignore: config.useGitignore };
    return muxClient.requestDryRun(
      transferDialogMode,
      config.serverPath,
      options,
      config.dirHandle,
      config.files,
    );
  }

  // Handle command execution from command palette
  function handleCommand(action: string) {
    switch (action) {
      case '_new_tab':
        handleNewTab();
        break;
      case '_close': {
        // Smart close: close panel if multiple, close tab if single
        const activePanel = muxClient?.getActivePanel();
        if (activePanel) {
          muxClient?.closePanel(activePanel.id);
        }
        break;
      }
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
        openUploadDialog();
        break;
      case '_download':
        openDownloadDialog();
        break;
      case '_transfer_monitor':
        downloadProgressOpen = true;
        break;
      case '_close_window':
        // Close all tabs (close window)
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
        toggleFullscreen();
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
      case '_previous_tab': {
        const tabArray = Array.from($tabs.values());
        if (tabArray.length < 2 || !$activeTabId) break;
        const currentIndex = tabArray.findIndex(t => t.id === $activeTabId);
        const prevIndex = (currentIndex - 1 + tabArray.length) % tabArray.length;
        muxClient?.selectTab(tabArray[prevIndex].id);
        break;
      }
      case '_next_tab': {
        const tabArray = Array.from($tabs.values());
        if (tabArray.length < 2 || !$activeTabId) break;
        const currentIndex = tabArray.findIndex(t => t.id === $activeTabId);
        const nextIndex = (currentIndex + 1) % tabArray.length;
        muxClient?.selectTab(tabArray[nextIndex].id);
        break;
      }
      case '_previous_split':
        muxClient?.selectAdjacentSplit(-1);
        break;
      case '_next_split':
        muxClient?.selectAdjacentSplit(1);
        break;
      case '_zoom_split':
        muxClient?.zoomSplit();
        break;
      case '_equalize_splits':
        muxClient?.equalizeSplits();
        break;
      case '_select_split_up':
        muxClient?.selectSplitInDirection('up');
        break;
      case '_select_split_down':
        muxClient?.selectSplitInDirection('down');
        break;
      case '_select_split_left':
        muxClient?.selectSplitInDirection('left');
        break;
      case '_select_split_right':
        muxClient?.selectSplitInDirection('right');
        break;
      case '_resize_split_up':
        muxClient?.resizeSplit('up');
        break;
      case '_resize_split_down':
        muxClient?.resizeSplit('down');
        break;
      case '_resize_split_left':
        muxClient?.resizeSplit('left');
        break;
      case '_resize_split_right':
        muxClient?.resizeSplit('right');
        break;
      case 'paste_from_clipboard':
        navigator.clipboard.readText().then(text => {
          if (text && muxClient) {
            muxClient.sendClipboard(text);
            muxClient.sendViewAction('paste_from_clipboard');
          }
        }).catch(() => {});
        break;
      case '_share_url':
        shareDialogOpen = true;
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
        // Wire transfer dialog callbacks
        muxClient.onUploadRequest = () => openUploadDialog();
        muxClient.onDownloadRequest = () => openDownloadDialog();
        muxClient.onFileDropRequest = (_panel, files) => openFileDropDialog(files);

        // Initialize download entry when transfer starts (creates single entry with correct totals)
        muxClient.getFileTransfer().onTransferStart = (transferId, path, direction, totalFiles, totalBytes) => {
          console.log(`[App] onTransferStart: id=${transferId}, direction=${direction}, files=${totalFiles}, bytes=${totalBytes}, path=${path}`);
          if (direction === 'download') {
            // Open the progress dialog automatically
            downloadProgressOpen = true;

            // Create the download entry - create new Map to trigger Svelte 5 reactivity
            activeDownloads.set(transferId, {
              files: 0,
              total: totalFiles,
              bytes: 0,
              totalBytes: totalBytes,
              path: path,
              status: 'active',
              startTime: Date.now(),
            });
            activeDownloads = new Map(activeDownloads); // Create new Map instance for reactivity
            console.log(`[App] Created download entry for transfer ${transferId}, map size: ${activeDownloads.size}`);

            // Clear pending path since we now have the actual transfer
            if (pendingTransferPath) {
              console.log('[App] Clearing pendingTransferPath');
              pendingTransferPath = null;
            }
          }
        };

        console.log('[App] Setting muxClient.onDownloadProgress callback');
        muxClient.onDownloadProgress = (transferId, filesCompleted, totalFiles, bytesTransferred, totalBytes) => {
          console.log(`[App] onDownloadProgress called: transferId=${transferId}, filesCompleted=${filesCompleted}, map size=${activeDownloads.size}`);
          // Update existing download entry (created by onTransferStart)
          const existing = activeDownloads.get(transferId);
          if (existing) {
            existing.files = filesCompleted;
            existing.total = totalFiles;
            existing.bytes = bytesTransferred;
            existing.totalBytes = totalBytes;
            existing.status = 'active';
            activeDownloads.set(transferId, existing);
            activeDownloads = new Map(activeDownloads); // Create new Map instance for reactivity

            // Update window title with overall progress (only for active transfers)
            const activeCount = Array.from(activeDownloads.values()).filter(d => d.status === 'active').length;
            const pct = totalBytes > 0 ? Math.round((bytesTransferred / totalBytes) * 100) : 0;
            if (activeCount === 1) {
              document.title = `⬇ ${filesCompleted}/${totalFiles} (${pct}%) — termweb`;
            } else if (activeCount > 1) {
              document.title = `⬇ ${activeCount} downloads — termweb`;
            } else {
              document.title = 'termweb';
            }
          } else {
            console.warn(`[App] onDownloadProgress for unknown transfer ${transferId}, map size: ${activeDownloads.size}`);
          }
        };

        // Mark completed downloads (don't delete - keep for history)
        const originalOnTransferComplete = muxClient.getFileTransfer().onTransferComplete;
        muxClient.getFileTransfer().onTransferComplete = (transferId, totalBytes) => {
          console.log(`[App] onTransferComplete: transferId=${transferId}, totalBytes=${totalBytes}`);
          originalOnTransferComplete?.(transferId, totalBytes);
          const existing = activeDownloads.get(transferId);
          if (existing) {
            console.log(`[App] Setting transfer ${transferId} status to 'complete'`);
            existing.status = 'complete';
            existing.endTime = Date.now();
            activeDownloads.set(transferId, existing);
            activeDownloads = new Map(activeDownloads); // Create new Map instance for reactivity
          } else {
            console.warn(`[App] onTransferComplete: transfer ${transferId} not found in activeDownloads`);
          }

          // Update title based on remaining active transfers
          const activeCount = Array.from(activeDownloads.values()).filter(d => d.status === 'active').length;
          if (activeCount === 0) {
            setTimeout(() => { document.title = 'termweb'; }, 2000);
          }
        };

        // Handle cancelled transfers
        muxClient.getFileTransfer().onTransferCancelled = (transferId) => {
          activeDownloads.delete(transferId);
          activeDownloads = new Map(activeDownloads); // Create new Map instance for reactivity

          // Update title based on remaining active transfers
          const activeCount = Array.from(activeDownloads.values()).filter(d => d.status === 'active').length;
          if (activeCount === 0) {
            document.title = 'termweb';
          }
        };

        // Handle transfer errors
        const originalOnTransferError = muxClient.getFileTransfer().onTransferError;
        muxClient.getFileTransfer().onTransferError = (transferId, error) => {
          console.error(`[App] Transfer error: transferId=${transferId}, error=${error}`);
          originalOnTransferError?.(transferId, error);

          // Clear pending path on error
          if (pendingTransferPath) {
            console.log('[App] Error handler clearing pendingTransferPath');
            pendingTransferPath = null;
          }

          // Mark transfer as error or remove it
          const existing = activeDownloads.get(transferId);
          if (existing) {
            existing.status = 'error';
            activeDownloads.set(transferId, existing);
            activeDownloads = new Map(activeDownloads);
          }

          // Update title
          const activeCount = Array.from(activeDownloads.values()).filter(d => d.status === 'active').length;
          if (activeCount === 0) {
            document.title = 'termweb';
          }
        };
      } catch (err) {
        console.error('Failed to initialize MuxClient:', err);
      } finally {
        showLoading = false;
      }
    }

    // Poll OPFS usage every 5 seconds when dialog is open
    const usageInterval = setInterval(async () => {
      if (downloadProgressOpen && muxClient) {
        const usage = await muxClient.getFileTransfer().getCacheUsage();
        opfsUsageBytes = usage.totalBytes;
        opfsFileCount = usage.fileCount;
      }
    }, 5000);

    return () => clearInterval(usageInterval);
  });

  onDestroy(() => {
    muxClient?.destroy();
  });

  // Setup keyboard shortcuts and input forwarding
  function handleKeydown(e: KeyboardEvent) {
    // Skip if dialog is open - let them handle their own keyboard events
    if (commandPaletteOpen || tabOverviewOpen || transferDialogOpen) {
      return;
    }

    const key = e.key.toLowerCase();

    // Application shortcuts (Cmd+key combinations)
    if (e.metaKey && e.shiftKey && key === 'p') {
      e.preventDefault();
      commandPaletteOpen = true;
      return;
    } else if (e.metaKey && key === '/') {
      e.preventDefault();
      handleNewTab();
      return;
    } else if (e.metaKey && e.shiftKey && key === '.') {
      e.preventDefault();
      if (!e.repeat) handleCommand('_close_window');
      return;
    } else if (e.metaKey && e.altKey && key === '.') {
      e.preventDefault();
      if (!e.repeat) handleCommand('_close_tab');
      return;
    } else if (e.metaKey && key === '.') {
      e.preventDefault();
      if (!e.repeat) handleCommand('_close');
      return;
    } else if (e.metaKey && key === 'd') {
      e.preventDefault();
      if (e.shiftKey) {
        handleCommand('_split_down');
      } else {
        handleCommand('_split_right');
      }
      return;
    } else if (e.metaKey && e.shiftKey && (key === 'a' || key === '\\')) {
      e.preventDefault();
      handleShowAllTabs();
      return;
    } else if (e.metaKey && key === 'u') {
      e.preventDefault();
      handleCommand('_upload');
      return;
    } else if (e.metaKey && e.shiftKey && key === 's') {
      e.preventDefault();
      handleCommand('_download');
      return;
    } else if (e.metaKey && e.shiftKey && key === 'f') {
      e.preventDefault();
      handleCommand('_toggle_fullscreen');
      return;
    } else if (e.metaKey && e.altKey && e.code === 'Backslash') {
      e.preventDefault();
      handleCommand('_quick_terminal');
      return;
    } else if (e.metaKey && e.shiftKey && key === '[') {
      e.preventDefault();
      handleCommand('_previous_tab');
      return;
    } else if (e.metaKey && e.shiftKey && key === ']') {
      e.preventDefault();
      handleCommand('_next_tab');
      return;
    } else if (e.metaKey && key === '[') {
      e.preventDefault();
      handleCommand('_previous_split');
      return;
    } else if (e.metaKey && key === ']') {
      e.preventDefault();
      handleCommand('_next_split');
      return;
    } else if (e.metaKey && e.shiftKey && key === 'enter') {
      e.preventDefault();
      handleCommand('_zoom_split');
      return;
    } else if (e.metaKey && e.shiftKey) {
      if (key === 'v') {
        e.preventDefault();
        handleCommand('paste_from_selection');
        return;
      } else if (key === 'arrowup') {
        e.preventDefault();
        handleCommand('_select_split_up');
        return;
      } else if (key === 'arrowdown') {
        e.preventDefault();
        handleCommand('_select_split_down');
        return;
      } else if (key === 'arrowleft') {
        e.preventDefault();
        handleCommand('_select_split_left');
        return;
      } else if (key === 'arrowright') {
        e.preventDefault();
        handleCommand('_select_split_right');
        return;
      }
    } else if (e.metaKey && e.altKey && e.code === 'KeyI') {
      e.preventDefault();
      handleCommand('_toggle_inspector');
      return;
    } else if (e.metaKey && key === '=') {
      e.preventDefault();
      handleCommand('increase_font_size:1');
      return;
    } else if (e.metaKey && key === '-') {
      e.preventDefault();
      handleCommand('decrease_font_size:1');
      return;
    } else if (e.metaKey && key === '0') {
      e.preventDefault();
      handleCommand('reset_font_size');
      return;
    } else if (e.metaKey && key >= '1' && key <= '9') {
      // Tab switching with Cmd+1-9
      e.preventDefault();
      const tabIndex = parseInt(key) - 1;
      const tabArray = Array.from($tabs.values());
      if (tabIndex < tabArray.length) {
        muxClient?.selectTab(tabArray[tabIndex].id);
      }
      return;
    } else if (e.metaKey && key === 'c' && !e.shiftKey && !e.altKey) {
      e.preventDefault();
      handleCommand('copy_to_clipboard');
      return;
    } else if (e.metaKey && key === 'v' && !e.shiftKey && !e.altKey) {
      // Don't preventDefault — let the browser fire native paste event on the focused panel.
      // Panel.svelte's handlePaste detects files (→ upload) vs text (→ terminal paste).
      return;
    } else if (e.metaKey && key === 'a' && !e.shiftKey && !e.altKey) {
      e.preventDefault();
      handleCommand('select_all');
      return;
    }

    // Forward all other keys to active panel
    // Skip if a mobile-input textarea has focus (it handles its own input)
    if ((e.target as HTMLElement)?.classList?.contains('mobile-input')) return;

    const activePanel = muxClient?.getActivePanel();
    if (activePanel) {
      e.preventDefault();
      activePanel.sendKeyInput(e, 1); // 1 = press
    }
  }

  function handleKeyup(e: KeyboardEvent) {
    // Skip if dialog is open
    if (commandPaletteOpen || tabOverviewOpen || transferDialogOpen) {
      return;
    }

    // Don't forward Cmd key releases (they're handled by shortcuts)
    if (e.metaKey) return;

    // Skip if a mobile-input textarea has focus
    if ((e.target as HTMLElement)?.classList?.contains('mobile-input')) return;

    // Forward keyup to active panel
    const activePanel = muxClient?.getActivePanel();
    if (activePanel) {
      e.preventDefault();
      activePanel.sendKeyInput(e, 0); // 0 = release
    }
  }
</script>

<svelte:window onkeydown={handleKeydown} onkeyup={handleKeyup} />

<div class="app-container">
  <!-- Titlebar -->
  <div id="titlebar" class:hidden={isFullscreen}>
    <div id="title-left">
      <span id="app-title">{$activeTab?.title || '👻'}</span>
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
        <Menu label="Share" items={shareMenuItems} onAction={handleCommand} />
      </div>
      <StatusDot {status} />
    </div>
  </div>

  <!-- Toolbar with tabs -->
  <div id="toolbar" class:hidden={isFullscreen}>
    <TabBar
      onNewTab={handleNewTab}
      onSelectTab={handleSelectTab}
      onCloseTab={handleCloseTab}
      onShowAllTabs={handleShowAllTabs}
    />
  </div>

  <!-- Panels area -->
  <div id="panels" bind:this={panelsEl}>
    {#if isLoading}
      <div id="panels-loading">
        <div class="spinner"></div>
        <span>Loading...</span>
      </div>
    {/if}

    {#if !isLoading && !hasTabs}
      <div id="panels-empty" class="visible">
        <h2>Welcome to Termweb</h2>
        <div class="shortcuts">
          <button type="button" class="shortcut" onclick={handleNewTab}>
            <span>New Tab</span><kbd>⌘/</kbd>
          </button>
          <button type="button" class="shortcut" onclick={() => commandPaletteOpen = true}>
            <span>Command Palette</span><kbd>⌘⇧P</kbd>
          </button>
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
    onClose={() => { ui.update(s => ({ ...s, overviewOpen: false })); muxClient?.setOverviewOpen(false); }}
    onSelectTab={handleSelectTab}
    onCloseTab={handleCloseTab}
    onNewTab={handleNewTab}
  />

  <!-- Share Dialog -->
  <ShareDialog
    open={shareDialogOpen}
    onClose={() => shareDialogOpen = false}
  />

  <!-- Transfer Dialog -->
  <TransferDialog
    open={transferDialogOpen}
    mode={transferDialogMode}
    defaultPath={transferDialogDefaultPath}
    initialDirHandle={transferDialogInitialDirHandle}
    initialFiles={transferDialogInitialFiles}
    onTransfer={handleTransferExecute}
    onPreview={handleTransferPreview}
    onClose={() => transferDialogOpen = false}
  />

  <!-- Download/Upload Progress Dialog -->
  <DownloadProgressDialog
    downloads={activeDownloads}
    pendingPath={pendingTransferPath}
    opfsUsageBytes={opfsUsageBytes}
    opfsFileCount={opfsFileCount}
    open={downloadProgressOpen}
    onClose={() => {
      downloadProgressOpen = false;
      // Reset title when dialog is closed
      const activeCount = Array.from(activeDownloads.values()).filter(d => d.status === 'active').length;
      if (activeCount === 0) {
        document.title = 'termweb';
      }
    }}
    onCancel={async (id) => {
      const transfer = activeDownloads.get(id);
      // Only cancel if transfer is still active
      if (transfer?.status === 'active') {
        muxClient?.getFileTransfer().cancelTransfer(id);
        // Clear cache when canceling to remove temp files
        await muxClient?.getFileTransfer().clearCache();
        // Refresh usage display
        const usage = await muxClient?.getFileTransfer().getCacheUsage();
        if (usage) {
          opfsUsageBytes = usage.totalBytes;
          opfsFileCount = usage.fileCount;
        }
      }
      // Remove from activeDownloads regardless
      activeDownloads.delete(id);
      activeDownloads = new Map(activeDownloads);
    }}
    onClearStorage={async () => {
      // Cancel all active transfers first
      muxClient?.getFileTransfer().cancelAllTransfers();
      // Then clear the cache
      await muxClient?.getFileTransfer().clearCache();
      // Refresh usage display
      const usage = await muxClient?.getFileTransfer().getCacheUsage();
      if (usage) {
        opfsUsageBytes = usage.totalBytes;
        opfsFileCount = usage.fileCount;
      }
    }}
    onClearCompleted={() => {
      // Filter out completed transfers
      const filtered = new Map();
      for (const [id, transfer] of activeDownloads) {
        if (transfer.status !== 'complete') {
          filtered.set(id, transfer);
        }
      }
      activeDownloads = filtered;
      console.log('[App] Cleared completed transfers, remaining:', activeDownloads.size);
    }}
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
    height: 28px;
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
    line-height: 18px;
    overflow: hidden;
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
    height: 40px;
  }

  #titlebar.hidden,
  #toolbar.hidden {
    display: none;
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
    font-family: Inter, "Source Code Pro", Roboto, Verdana, system-ui, sans-serif;
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
