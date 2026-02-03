// Dialog components - command palette, upload/download, access control

import { formatBytes } from './utils';

export interface Command {
  title: string;
  action: string;
  description: string;
  shortcut?: string;
  requiresPanel?: boolean;  // Disabled when no active panel
  requiresTab?: boolean;    // Disabled when no tabs
}

export function getCommands(): Command[] {
  const commands: Command[] = [
    // Text Operations (require active panel)
    { title: 'Copy to Clipboard', action: 'copy_to_clipboard', description: 'Copy selected text', requiresPanel: true },
    { title: 'Paste from Clipboard', action: 'paste_from_clipboard', description: 'Paste contents of clipboard', requiresPanel: true },
    { title: 'Paste from Selection', action: 'paste_from_selection', description: 'Paste from selection clipboard', requiresPanel: true },
    { title: 'Select All', action: 'select_all', description: 'Select all text', requiresPanel: true },

    // Font Control (require active panel)
    { title: 'Increase Font Size', action: 'increase_font_size:1', description: 'Make text larger', shortcut: '⌘=', requiresPanel: true },
    { title: 'Decrease Font Size', action: 'decrease_font_size:1', description: 'Make text smaller', shortcut: '⌘-', requiresPanel: true },
    { title: 'Reset Font Size', action: 'reset_font_size', description: 'Reset to default size', shortcut: '⌘0', requiresPanel: true },

    // Screen Operations (require active panel)
    { title: 'Clear Screen', action: 'clear_screen', description: 'Clear screen and scrollback', requiresPanel: true },
    { title: 'Scroll to Top', action: 'scroll_to_top', description: 'Scroll to top of buffer', requiresPanel: true },
    { title: 'Scroll to Bottom', action: 'scroll_to_bottom', description: 'Scroll to bottom of buffer', requiresPanel: true },
    { title: 'Scroll Page Up', action: 'scroll_page_up', description: 'Scroll up one page', requiresPanel: true },
    { title: 'Scroll Page Down', action: 'scroll_page_down', description: 'Scroll down one page', requiresPanel: true },

    // Tab Management
    { title: 'New Tab', action: '_new_tab', description: 'Open a new tab', shortcut: '⌘/' },
    { title: 'Close Tab', action: '_close_tab', description: 'Close current tab', shortcut: '⌘.', requiresTab: true },
    { title: 'Show All Tabs', action: '_show_all_tabs', description: 'Show tab overview', shortcut: '⌘⇧A', requiresTab: true },

    // Split Management (require active panel)
    { title: 'Split Right', action: '_split_right', description: 'Split pane to the right', shortcut: '⌘D', requiresPanel: true },
    { title: 'Split Down', action: '_split_down', description: 'Split pane downward', shortcut: '⌘⇧D', requiresPanel: true },
    { title: 'Split Left', action: '_split_left', description: 'Split pane to the left', requiresPanel: true },
    { title: 'Split Up', action: '_split_up', description: 'Split pane upward', requiresPanel: true },

    // Navigation (require active panel)
    { title: 'Focus Split: Left', action: 'goto_split:left', description: 'Focus left split', requiresPanel: true },
    { title: 'Focus Split: Right', action: 'goto_split:right', description: 'Focus right split', requiresPanel: true },
    { title: 'Focus Split: Up', action: 'goto_split:up', description: 'Focus split above', requiresPanel: true },
    { title: 'Focus Split: Down', action: 'goto_split:down', description: 'Focus split below', requiresPanel: true },
    { title: 'Focus Split: Previous', action: 'goto_split:previous', description: 'Focus previous split', requiresPanel: true },
    { title: 'Focus Split: Next', action: 'goto_split:next', description: 'Focus next split', requiresPanel: true },
    { title: 'Toggle Split Zoom', action: 'toggle_split_zoom', description: 'Toggle zoom on current split', requiresPanel: true },
    { title: 'Equalize Splits', action: 'equalize_splits', description: 'Make all splits equal size', requiresPanel: true },

    // Terminal Control (require active panel)
    { title: 'Reset Terminal', action: 'reset', description: 'Reset terminal state', requiresPanel: true },
    { title: 'Toggle Read-Only Mode', action: 'toggle_readonly', description: 'Toggle read-only mode', requiresPanel: true },

    // Config
    { title: 'Reload Config', action: 'reload_config', description: 'Reload configuration' },
    { title: 'Toggle Inspector', action: '_toggle_inspector', description: 'Toggle terminal inspector', shortcut: '⌥⌘I', requiresPanel: true },

    // Title (require tab)
    { title: 'Change Title...', action: '_change_title', description: 'Change the terminal title', requiresTab: true },

    // Fun (require active panel)
    { title: 'Ghostty', action: 'text:👻', description: 'Add a little ghost to your terminal', requiresPanel: true },
  ];

  return commands.sort((a, b) => a.title.localeCompare(b.title));
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

    this.list.querySelectorAll('.command-item').forEach((el, i) => {
      if (!this.isCommandDisabled(this.filteredCommands[i])) {
        el.addEventListener('click', () => this.executeIndex(i));
      }
      el.addEventListener('mouseenter', () => {
        if (!this.isCommandDisabled(this.filteredCommands[i])) {
          this.selectedIndex = i;
          this.updateSelection();
        }
      });
    });
  }

  private updateSelection(): void {
    if (!this.list) return;
    this.list.querySelectorAll('.command-item').forEach((el, i) => {
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
        if (!this.isCommandDisabled(this.filteredCommands[this.selectedIndex])) {
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

  constructor(onUpload: (file: File) => void) {
    this.onUpload = onUpload;
  }

  show(): void {
    this.overlay = document.getElementById('upload-dialog');
    if (!this.overlay) return;

    const dropzone = this.overlay.querySelector('.upload-dropzone') as HTMLElement | null;
    const input = this.overlay.querySelector('input[type="file"]') as HTMLInputElement;

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

    this.overlay.classList.add('visible');

    const closeBtn = this.overlay.querySelector('.dialog-btn.cancel');
    closeBtn?.addEventListener('click', () => this.hide());

    this.overlay.onclick = (e) => {
      if (e.target === this.overlay) this.hide();
    };
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
  deleteExtra: boolean;
  preview: boolean;
}

export class DownloadDialog {
  private overlay: HTMLElement | null = null;
  private onDownload?: (options: DownloadOptions) => void;

  constructor(onDownload: (options: DownloadOptions) => void) {
    this.onDownload = onDownload;
  }

  show(): void {
    this.overlay = document.getElementById('download-dialog');
    if (!this.overlay) return;

    const input = this.overlay.querySelector('.download-input') as HTMLInputElement;
    const excludeInput = this.overlay.querySelector('.download-exclude') as HTMLInputElement;
    const deleteCheckbox = this.overlay.querySelector('.download-delete') as HTMLInputElement;
    const previewCheckbox = this.overlay.querySelector('.download-preview') as HTMLInputElement;
    const downloadBtn = this.overlay.querySelector('.dialog-btn.primary');

    if (input) {
      input.value = '';

      input.onkeydown = (e) => {
        if (e.key === 'Enter') {
          e.preventDefault();
          this.download();
        } else if (e.key === 'Escape') {
          e.preventDefault();
          this.hide();
        }
      };
    }

    downloadBtn?.addEventListener('click', () => this.download());

    this.overlay.classList.add('visible');

    // Focus after visible (needs slight delay for CSS transition)
    if (input) {
      requestAnimationFrame(() => input.focus());
    }

    const closeBtn = this.overlay.querySelector('.dialog-btn.cancel');
    closeBtn?.addEventListener('click', () => this.hide());

    this.overlay.onclick = (e) => {
      if (e.target === this.overlay) this.hide();
    };
  }

  hide(): void {
    this.overlay?.classList.remove('visible');
  }

  private download(): void {
    if (!this.overlay) return;

    const input = this.overlay.querySelector('.download-input') as HTMLInputElement;
    const excludeInput = this.overlay.querySelector('.download-exclude') as HTMLInputElement;
    const deleteCheckbox = this.overlay.querySelector('.download-delete') as HTMLInputElement;
    const previewCheckbox = this.overlay.querySelector('.download-preview') as HTMLInputElement;

    const path = input?.value.trim();
    if (!path) return;

    const excludes = excludeInput?.value
      .split(',')
      .map(s => s.trim())
      .filter(s => s.length > 0) || [];

    const options: DownloadOptions = {
      path,
      excludes,
      deleteExtra: deleteCheckbox?.checked || false,
      preview: previewCheckbox?.checked || false,
    };

    this.hide();
    this.onDownload?.(options);
  }
}

export interface AuthSession {
  id: string;
  name: string;
  editorToken: string;
  viewerToken: string;
}

export interface ShareLink {
  token: string;
  type: number;
  useCount: number;
}

export class AccessControlDialog {
  private overlay: HTMLElement | null = null;
  private sessions: AuthSession[] = [];
  private shareLinks: ShareLink[] = [];

  onSetPassword?: (password: string) => void;
  onCreateSession?: (id: string, name: string) => void;
  onRegenerateToken?: (sessionId: string, tokenType: number) => void;
  onCreateShareLink?: (tokenType: number) => void;
  onRevokeShareLink?: (token: string) => void;
  onRevokeAllShares?: () => void;

  show(): void {
    this.overlay = document.getElementById('access-control-dialog');
    if (!this.overlay) return;

    this.setupHandlers();
    this.overlay.classList.add('visible');
  }

  hide(): void {
    this.overlay?.classList.remove('visible');
  }

  updateSessions(sessions: AuthSession[]): void {
    this.sessions = sessions;
    this.renderSessions();
  }

  updateShareLinks(links: ShareLink[]): void {
    this.shareLinks = links;
    this.renderShareLinks();
  }

  private setupHandlers(): void {
    if (!this.overlay) return;

    const passwordInput = this.overlay.querySelector('#admin-password-input') as HTMLInputElement;
    const setPasswordBtn = this.overlay.querySelector('#set-password-btn');
    setPasswordBtn?.addEventListener('click', () => {
      if (passwordInput?.value) {
        this.onSetPassword?.(passwordInput.value);
        passwordInput.value = '';
      }
    });

    const newSessionInput = this.overlay.querySelector('#new-session-name') as HTMLInputElement;
    const createSessionBtn = this.overlay.querySelector('#create-session-btn');
    createSessionBtn?.addEventListener('click', () => {
      const name = newSessionInput?.value.trim();
      if (name) {
        const id = name.toLowerCase().replace(/[^a-z0-9]/g, '-');
        this.onCreateSession?.(id, name);
        newSessionInput.value = '';
      }
    });

    this.overlay.querySelector('#generate-editor-link')?.addEventListener('click', () => {
      this.onCreateShareLink?.(1);
    });

    this.overlay.querySelector('#generate-viewer-link')?.addEventListener('click', () => {
      this.onCreateShareLink?.(2);
    });

    this.overlay.querySelector('#revoke-all-btn')?.addEventListener('click', () => {
      this.onRevokeAllShares?.();
    });

    const closeBtn = this.overlay.querySelector('.dialog-btn.cancel');
    closeBtn?.addEventListener('click', () => this.hide());

    this.overlay.onclick = (e) => {
      if (e.target === this.overlay) this.hide();
    };
  }

  private renderSessions(): void {
    const listEl = document.getElementById('sessions-list');
    if (!listEl) return;

    listEl.innerHTML = '';
    for (const session of this.sessions) {
      const itemEl = document.createElement('div');
      itemEl.className = 'session-item';
      itemEl.innerHTML = `
        <span class="session-name">${session.name}</span>
        <div class="token-group">
          <span class="token editor" title="Click to copy editor link" data-token="${session.editorToken}">Editor</span>
          <span class="token viewer" title="Click to copy viewer link" data-token="${session.viewerToken}">Viewer</span>
          <button class="regen-btn" data-session="${session.id}" data-type="editor" title="Regenerate editor token">🔄</button>
        </div>
      `;

      itemEl.querySelectorAll('.token').forEach(el => {
        (el as HTMLElement).onclick = () => {
          const url = `${location.origin}?token=${(el as HTMLElement).dataset.token}`;
          navigator.clipboard.writeText(url).then(() => {
            (el as HTMLElement).style.background = 'rgba(100,200,100,0.3)';
            setTimeout(() => (el as HTMLElement).style.background = '', 500);
          });
        };
      });

      const regenBtn = itemEl.querySelector('.regen-btn') as HTMLElement;
      regenBtn.onclick = () => {
        this.onRegenerateToken?.(regenBtn.dataset.session!, 1);
      };

      listEl.appendChild(itemEl);
    }
  }

  private renderShareLinks(): void {
    const listEl = document.getElementById('share-links-list');
    if (!listEl) return;

    listEl.innerHTML = '';
    for (const link of this.shareLinks) {
      const typeLabel = link.type === 1 ? 'Editor' : 'Viewer';
      const typeClass = link.type === 1 ? 'editor' : 'viewer';

      const itemEl = document.createElement('div');
      itemEl.className = 'share-link-item';
      itemEl.innerHTML = `
        <div style="display: flex; align-items: center; gap: 8px;">
          <span class="link-type ${typeClass}">${typeLabel}</span>
          <span class="link-token" title="Click to copy" style="font-family: monospace; font-size: 11px; cursor: pointer;">${link.token.slice(0, 12)}...</span>
        </div>
        <div style="display: flex; align-items: center; gap: 8px;">
          <span class="link-uses">${link.useCount} uses</span>
          <button class="revoke-btn" data-token="${link.token}" style="padding: 2px 6px; font-size: 11px;">Revoke</button>
        </div>
      `;

      const tokenEl = itemEl.querySelector('.link-token') as HTMLElement;
      tokenEl.onclick = () => {
        navigator.clipboard.writeText(`${location.origin}?token=${link.token}`);
      };

      const revokeBtn = itemEl.querySelector('.revoke-btn') as HTMLElement;
      revokeBtn.onclick = () => {
        this.onRevokeShareLink?.(revokeBtn.dataset.token!);
      };

      listEl.appendChild(itemEl);
    }

    if (this.shareLinks.length === 0) {
      listEl.innerHTML = '<div style="color: var(--text-dim); font-size: 12px; padding: 8px;">No active share links</div>';
    }
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

  // Handle buttons
  const cancelBtn = overlay.querySelector('.dialog-btn.cancel');
  const proceedBtn = overlay.querySelector('.dialog-btn.primary');

  const hide = () => {
    overlay.classList.remove('visible');
    cancelBtn?.removeEventListener('click', hide);
    proceedBtn?.removeEventListener('click', handleProceed);
  };

  const handleProceed = () => {
    hide();
    onConfirm();
  };

  cancelBtn?.addEventListener('click', hide);
  proceedBtn?.addEventListener('click', handleProceed);
}
