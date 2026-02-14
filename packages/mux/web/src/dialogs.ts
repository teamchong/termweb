// Dialog components - command palette, upload/download, access control

import { formatBytes } from './utils';
import type { KeyBinding } from './types';

import { TIMING } from './constants';

export interface Command {
  title: string;
  action: string;
  description: string;
  shortcut?: string;
  requiresPanel?: boolean;  // Disabled when no active panel
  requiresTab?: boolean;    // Disabled when no tabs
}

// Cached sorted commands (computed once at module load)
const cachedCommands: Command[] = [
  // Screen/Selection Download (require active panel)
  { title: 'Save Screen to File', action: '_save_screen', description: 'Download terminal screen content', shortcut: '⇧⌘J', requiresPanel: true },
  { title: 'Save Selection to File', action: '_save_selection', description: 'Download selected text', requiresPanel: true },
  { title: 'Copy Terminal Title to Clipboard', action: 'copy_title_to_clipboard', description: 'Copy terminal title to clipboard', requiresPanel: true },

  // Text Operations (require active panel)
  { title: 'Copy to Clipboard', action: 'copy_to_clipboard', description: 'Copy selected text', requiresPanel: true },
  { title: 'Copy URL to Clipboard', action: 'copy_url_to_clipboard', description: 'Copy URL under cursor to clipboard', requiresPanel: true },
  { title: 'Paste from Clipboard', action: 'paste_from_clipboard', description: 'Paste contents of clipboard', requiresPanel: true },
  { title: 'Paste from Selection', action: 'paste_from_selection', description: 'Paste from selection clipboard', requiresPanel: true },
  { title: 'Select All', action: 'select_all', description: 'Select all text', shortcut: '⌘A', requiresPanel: true },
  { title: 'Show On-Screen Keyboard', action: 'show_on_screen_keyboard', description: 'Show on-screen keyboard', requiresPanel: true },

  // Font Control (require active panel)
  { title: 'Increase Font Size', action: 'increase_font_size:1', description: 'Make text larger', shortcut: '⌘=', requiresPanel: true },
  { title: 'Decrease Font Size', action: 'decrease_font_size:1', description: 'Make text smaller', shortcut: '⌘-', requiresPanel: true },
  { title: 'Reset Font Size', action: 'reset_font_size', description: 'Reset to default size', shortcut: '⌘0', requiresPanel: true },

  // Screen Operations (require active panel)
  { title: 'Clear Screen', action: 'clear_screen', description: 'Clear screen and scrollback', requiresPanel: true },
  { title: 'Scroll to Top', action: 'scroll_to_top', description: 'Scroll to top of buffer', shortcut: '⇧⌘↑', requiresPanel: true },
  { title: 'Scroll to Bottom', action: 'scroll_to_bottom', description: 'Scroll to bottom of buffer', shortcut: '⇧⌘↓', requiresPanel: true },
  { title: 'Scroll to Selection', action: 'scroll_to_selection', description: 'Scroll to selected text', requiresPanel: true },
  { title: 'Scroll Page Up', action: 'scroll_page_up', description: 'Scroll up one page', shortcut: '⌘↑', requiresPanel: true },
  { title: 'Scroll Page Down', action: 'scroll_page_down', description: 'Scroll down one page', shortcut: '⌘↓', requiresPanel: true },

  // Tab Management
  { title: 'Move Tab Left', action: 'move_tab:-1', description: 'Move current tab left', requiresTab: true },
  { title: 'Move Tab Right', action: 'move_tab:1', description: 'Move current tab right', requiresTab: true },
  { title: 'New Tab', action: '_new_tab', description: 'Open a new tab', shortcut: '⌘/' },
  { title: 'Close', action: '_close', description: 'Close current panel or tab', shortcut: '⌘.', requiresTab: true },
  { title: 'Close Tab', action: '_close_tab', description: 'Close current tab', shortcut: '⌥⌘.', requiresTab: true },
  { title: 'Close Other Tabs', action: '_close_other_tabs', description: 'Close all other tabs', requiresTab: true },
  { title: 'Close Window', action: '_close_window', description: 'Close all tabs', shortcut: '⌘⇧.', requiresTab: true },
  { title: 'Show All Tabs', action: '_show_all_tabs', description: 'Show tab overview', shortcut: '⌘⇧A', requiresTab: true },

  // Split Management (require active panel)
  { title: 'Split Right', action: '_split_right', description: 'Split pane to the right', shortcut: '⌘D', requiresPanel: true },
  { title: 'Split Down', action: '_split_down', description: 'Split pane downward', shortcut: '⌘⇧D', requiresPanel: true },
  { title: 'Split Left', action: '_split_left', description: 'Split pane to the left', requiresPanel: true },
  { title: 'Split Up', action: '_split_up', description: 'Split pane upward', requiresPanel: true },

  // Navigation (require active panel) — uses client-side handlers (_select_split_*, _zoom_split, _equalize_splits)
  { title: 'Focus Split: Left', action: '_select_split_left', description: 'Focus left split', shortcut: '⌥⌘←', requiresPanel: true },
  { title: 'Focus Split: Right', action: '_select_split_right', description: 'Focus right split', shortcut: '⌥⌘→', requiresPanel: true },
  { title: 'Focus Split: Up', action: '_select_split_up', description: 'Focus split above', shortcut: '⌥⌘↑', requiresPanel: true },
  { title: 'Focus Split: Down', action: '_select_split_down', description: 'Focus split below', shortcut: '⌥⌘↓', requiresPanel: true },
  { title: 'Focus Split: Previous', action: '_previous_split', description: 'Focus previous split', requiresPanel: true },
  { title: 'Focus Split: Next', action: '_next_split', description: 'Focus next split', requiresPanel: true },
  { title: 'Toggle Split Zoom', action: '_zoom_split', description: 'Toggle zoom on current split', shortcut: '⇧⌘↩', requiresPanel: true },
  { title: 'Equalize Splits', action: '_equalize_splits', description: 'Make all splits equal size', requiresPanel: true },

  // Terminal Control (require active panel)
  { title: 'Reset Terminal', action: 'reset', description: 'Reset terminal state', requiresPanel: true },
  { title: 'Toggle Fullscreen', action: 'toggle_fullscreen', description: 'Toggle fullscreen mode', shortcut: '⌃⌘F' },
  { title: 'Toggle Secure Input', action: 'toggle_secure_input', description: 'Toggle secure input mode' },
  { title: 'Toggle Read-Only Mode', action: 'toggle_readonly', description: 'Toggle read-only mode', requiresPanel: true },

  // Config
  { title: 'Open Config', action: 'open_config', description: 'Open config file in editor', shortcut: '⌘,' },
  { title: 'Reload Config', action: 'reload_config', description: 'Reload configuration', shortcut: '⇧⌘,' },
  { title: 'Toggle Inspector', action: '_toggle_inspector', description: 'Toggle terminal inspector', shortcut: '⌥⌘I', requiresPanel: true },
  { title: 'Quick Terminal', action: '_quick_terminal', description: 'Toggle quick terminal', shortcut: '⌥⌘`' },

  // Title (require tab)
  { title: 'Change Title...', action: '_change_title', description: 'Change the terminal title', requiresTab: true },

  // Fun (require active panel)
  { title: 'Ghostty', action: 'text:👻', description: 'Add a little ghost to your terminal', requiresPanel: true },
].sort((a, b) => a.title.localeCompare(b.title));

const keyDisplayMap: Record<string, string> = {
  'enter': '↵', 'arrowup': '↑', 'arrowdown': '↓',
  'arrowleft': '←', 'arrowright': '→', 'backslash': '\\',
  'backquote': '`', ' ': '␣', 'escape': 'Esc', 'tab': '⇥',
  'delete': '⌫', 'backspace': '⌫',
};

/** Format a keybinding as a human-readable shortcut string (e.g. "⌘⇧K") */
export function formatShortcut(binding: KeyBinding): string {
  let result = '';
  if (binding.mods.includes('ctrl')) result += '⌃';
  if (binding.mods.includes('alt')) result += '⌥';
  if (binding.mods.includes('shift')) result += '⇧';
  if (binding.mods.includes('super')) result += '⌘';
  result += keyDisplayMap[binding.key] || binding.key.toUpperCase();
  return result;
}

/**
 * Get the list of available commands, optionally with dynamic shortcuts from server.
 */
export function getCommands(bindings?: Record<string, KeyBinding>): Command[] {
  if (!bindings || Object.keys(bindings).length === 0) return cachedCommands;
  return cachedCommands.map(cmd => {
    const binding = bindings[cmd.action];
    if (binding) {
      return { ...cmd, shortcut: formatShortcut(binding) };
    }
    return cmd;
  });
}

export class CommandPalette {
  private overlay: HTMLElement | null = null;
  private input: HTMLInputElement | null = null;
  private list: HTMLElement | null = null;
  private commands: Command[] = [];
  private filteredCommands: Command[] = [];
  private selectedIndex = 0;
  private onExecute?: (action: string) => void;
  private hasTabs = false;
  private hasActivePanel = false;
  private commandItems: NodeListOf<Element> | null = null;

  constructor(onExecute: (action: string) => void) {
    this.onExecute = onExecute;
    this.commands = getCommands();
  }

  show(hasTabs = false, hasActivePanel = false): void {
    this.hasTabs = hasTabs;
    this.hasActivePanel = hasActivePanel;

    this.overlay = document.getElementById('command-palette');
    if (!this.overlay) return;

    this.input = document.getElementById('command-palette-input') as HTMLInputElement;
    this.list = document.getElementById('command-palette-list');

    if (this.input) {
      this.input.value = '';
      this.input.oninput = () => this.renderList(this.input!.value);
      this.input.onkeydown = (e) => this.handleKeydown(e);
    }

    this.selectedIndex = 0;
    this.renderList('');
    // Select first enabled item
    this.selectNextEnabled(0);
    this.overlay.classList.add('visible');
    this.input?.focus();

    this.overlay.onclick = (e) => {
      if (e.target === this.overlay) this.hide();
    };
  }

  hide(): void {
    this.overlay?.classList.remove('visible');
  }

  private isCommandDisabled(cmd: Command): boolean {
    if (cmd.requiresPanel && !this.hasActivePanel) return true;
    if (cmd.requiresTab && !this.hasTabs) return true;
    return false;
  }

  private selectNextEnabled(startIndex: number, direction: 1 | -1 = 1): void {
    const len = this.filteredCommands.length;
    if (len === 0) return;

    let index = startIndex;
    for (let i = 0; i < len; i++) {
      if (!this.isCommandDisabled(this.filteredCommands[index])) {
        this.selectedIndex = index;
        this.updateSelection();
        return;
      }
      index = (index + direction + len) % len;
    }
    // All disabled, just select the start
    this.selectedIndex = startIndex;
  }

  private renderList(filter: string): void {
    if (!this.list) return;

    const filterLower = filter.toLowerCase();
    this.filteredCommands = this.commands.filter(cmd =>
      cmd.title.toLowerCase().includes(filterLower) ||
      cmd.description.toLowerCase().includes(filterLower)
    );

    this.selectedIndex = Math.min(this.selectedIndex, Math.max(0, this.filteredCommands.length - 1));

    this.list.innerHTML = this.filteredCommands.map((cmd, i) => {
      const disabled = this.isCommandDisabled(cmd);
      return `
      <div class="command-item ${i === this.selectedIndex ? 'selected' : ''} ${disabled ? 'disabled' : ''}" data-index="${i}">
        <div class="command-title">${cmd.title}</div>
        <div class="command-desc">${cmd.description}</div>
        ${cmd.shortcut ? `<div class="command-shortcut">${cmd.shortcut}</div>` : ''}
      </div>
    `;
    }).join('');

    // Cache querySelectorAll result for use in updateSelection()
    // Note: innerHTML replaces elements, so old handlers are automatically cleaned up
    this.commandItems = this.list.querySelectorAll('.command-item');
    this.commandItems.forEach((el, i) => {
      const htmlEl = el as HTMLElement;
      if (!this.isCommandDisabled(this.filteredCommands[i])) {
        htmlEl.onclick = () => this.executeIndex(i);
      }
      htmlEl.onmouseenter = () => {
        if (!this.isCommandDisabled(this.filteredCommands[i])) {
          this.selectedIndex = i;
          this.updateSelection();
        }
      };
    });
  }

  private updateSelection(): void {
    if (!this.commandItems) return;
    this.commandItems.forEach((el, i) => {
      el.classList.toggle('selected', i === this.selectedIndex);
    });
  }

  private handleKeydown(e: KeyboardEvent): void {
    switch (e.key) {
      case 'ArrowDown':
        e.preventDefault();
        if (this.selectedIndex < this.filteredCommands.length - 1) {
          this.selectNextEnabled(this.selectedIndex + 1, 1);
        }
        break;
      case 'ArrowUp':
        e.preventDefault();
        if (this.selectedIndex > 0) {
          this.selectNextEnabled(this.selectedIndex - 1, -1);
        }
        break;
      case 'Enter':
        e.preventDefault();
        if (this.selectedIndex < this.filteredCommands.length &&
            !this.isCommandDisabled(this.filteredCommands[this.selectedIndex])) {
          this.executeIndex(this.selectedIndex);
        }
        break;
      case 'Escape':
        e.preventDefault();
        this.hide();
        break;
    }
  }

  private executeIndex(index: number): void {
    const cmd = this.filteredCommands[index];
    if (cmd) {
      this.hide();
      this.onExecute?.(cmd.action);
    }
  }
}

export class UploadDialog {
  private overlay: HTMLElement | null = null;
  private onUpload?: (file: File) => void;
  private handlersSetup = false;

  constructor(onUpload: (file: File) => void) {
    this.onUpload = onUpload;
  }

  show(): void {
    this.overlay = document.getElementById('upload-dialog');
    if (!this.overlay) return;

    // Setup handlers only once
    if (!this.handlersSetup) {
      const dropzone = this.overlay.querySelector('.upload-dropzone') as HTMLElement | null;
      const input = this.overlay.querySelector('input[type="file"]') as HTMLInputElement;
      const closeBtn = this.overlay.querySelector('.dialog-btn.cancel') as HTMLElement | null;

      if (dropzone) {
        dropzone.ondragover = (e: DragEvent) => {
          e.preventDefault();
          dropzone.classList.add('dragover');
        };

        dropzone.ondragleave = () => {
          dropzone.classList.remove('dragover');
        };

        dropzone.ondrop = (e: DragEvent) => {
          e.preventDefault();
          dropzone.classList.remove('dragover');
          const files = e.dataTransfer?.files;
          if (files && files.length > 0) {
            this.uploadFile(files[0]);
          }
        };

        dropzone.onclick = () => input?.click();
      }

      if (input) {
        input.onchange = () => {
          if (input.files && input.files.length > 0) {
            this.uploadFile(input.files[0]);
          }
        };
      }

      if (closeBtn) {
        closeBtn.onclick = () => this.hide();
      }

      this.overlay.onclick = (e) => {
        if (e.target === this.overlay) this.hide();
      };

      this.handlersSetup = true;
    }

    this.overlay.classList.add('visible');
  }

  hide(): void {
    this.overlay?.classList.remove('visible');
  }

  private uploadFile(file: File): void {
    this.hide();
    this.onUpload?.(file);
  }
}

export interface DownloadOptions {
  path: string;
  excludes: string[];
  preview: boolean;
}

export class DownloadDialog {
  private overlay: HTMLElement | null = null;
  private onDownload?: (options: DownloadOptions) => void;
  // Cached element references
  private inputEl: HTMLInputElement | null = null;
  private excludeEl: HTMLInputElement | null = null;
  private previewEl: HTMLInputElement | null = null;
  private downloadBtn: Element | null = null;
  private closeBtn: Element | null = null;
  private handlersSetup = false;

  constructor(onDownload: (options: DownloadOptions) => void) {
    this.onDownload = onDownload;
  }

  show(): void {
    this.overlay = document.getElementById('download-dialog');
    if (!this.overlay) return;

    // Cache element references (only once)
    if (!this.handlersSetup) {
      this.inputEl = this.overlay.querySelector('.download-input') as HTMLInputElement;
      this.excludeEl = this.overlay.querySelector('.download-exclude') as HTMLInputElement;
      this.previewEl = this.overlay.querySelector('.download-preview') as HTMLInputElement;
      this.downloadBtn = this.overlay.querySelector('.dialog-btn.primary');
      this.closeBtn = this.overlay.querySelector('.dialog-btn.cancel');

      if (this.inputEl) {
        this.inputEl.onkeydown = (e) => {
          if (e.key === 'Enter') {
            e.preventDefault();
            this.download();
          } else if (e.key === 'Escape') {
            e.preventDefault();
            this.hide();
          }
        };
      }

      if (this.downloadBtn) (this.downloadBtn as HTMLElement).onclick = () => this.download();
      if (this.closeBtn) (this.closeBtn as HTMLElement).onclick = () => this.hide();

      this.overlay.onclick = (e) => {
        if (e.target === this.overlay) this.hide();
      };

      this.handlersSetup = true;
    }

    // Reset input value each time dialog is shown
    if (this.inputEl) {
      this.inputEl.value = '';
    }

    this.overlay.classList.add('visible');

    // Focus after visible (needs slight delay for CSS transition)
    if (this.inputEl) {
      requestAnimationFrame(() => this.inputEl?.focus());
    }
  }

  hide(): void {
    this.overlay?.classList.remove('visible');
  }

  private download(): void {
    if (!this.overlay) return;

    const path = this.inputEl?.value.trim();
    if (!path) return;

    const excludes = this.excludeEl?.value
      .split(',')
      .map(s => s.trim())
      .filter(s => s.length > 0) || [];

    const options: DownloadOptions = {
      path,
      excludes,
      preview: this.previewEl?.checked || false,
    };

    this.hide();
    this.onDownload?.(options);
  }
}


export function showDryRunPreview(
  report: { newCount: number; updateCount: number; deleteCount: number; entries: Array<{ action: string; path: string; size: number }> },
  onConfirm: () => void
): void {
  const overlay = document.getElementById('preview-dialog');
  if (!overlay) return;

  // Update summary counts
  const newEl = document.getElementById('preview-new');
  const updateEl = document.getElementById('preview-update');
  const deleteEl = document.getElementById('preview-delete');
  if (newEl) newEl.textContent = String(report.newCount);
  if (updateEl) updateEl.textContent = String(report.updateCount);
  if (deleteEl) deleteEl.textContent = String(report.deleteCount);

  // Build entries list
  const entriesEl = document.getElementById('preview-entries');
  if (entriesEl) {
    const entriesHtml = report.entries.map(e => {
      const icon = e.action === 'create' ? '+' : e.action === 'update' ? '~' : '-';
      return `<div class="preview-entry ${e.action}">${icon} ${e.path} (${formatBytes(e.size)})</div>`;
    }).join('');
    entriesEl.innerHTML = entriesHtml || '<div style="color: var(--text-dim);">No changes</div>';
  }

  // Show dialog
  overlay.classList.add('visible');

  // Handle buttons - use onclick assignment to replace previous handlers
  const cancelBtn = overlay.querySelector('.dialog-btn.cancel') as HTMLElement | null;
  const proceedBtn = overlay.querySelector('.dialog-btn.primary') as HTMLElement | null;

  const hide = () => {
    overlay.classList.remove('visible');
    if (cancelBtn) cancelBtn.onclick = null;
    if (proceedBtn) proceedBtn.onclick = null;
  };

  if (cancelBtn) {
    cancelBtn.onclick = hide;
  }

  if (proceedBtn) {
    proceedBtn.onclick = () => {
      hide();
      onConfirm();
    };
  }
}
