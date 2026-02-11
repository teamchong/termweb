<script lang="ts">
  import { formatBytes } from '../utils';
  import type { DryRunReport } from '../file-transfer';

  export interface TransferConfig {
    serverPath: string;
    excludes: string[];
    useGitignore: boolean;
    dirHandle?: FileSystemDirectoryHandle;
    files?: File[];
  }

  interface Props {
    open?: boolean;
    mode?: 'upload' | 'download';
    defaultPath?: string;
    initialDirHandle?: FileSystemDirectoryHandle;
    initialFiles?: File[];
    onTransfer?: (config: TransferConfig) => void;
    onPreview?: (config: TransferConfig) => Promise<DryRunReport | null>;
    onClose?: () => void;
  }

  let {
    open = false,
    mode = 'download',
    defaultPath = '',
    initialDirHandle,
    initialFiles,
    onTransfer,
    onPreview,
    onClose,
  }: Props = $props();

  let stage: 'config' | 'preview' = $state('config');
  let serverPath = $state('');
  let excludesText = $state('');
  let useGitignore = $state(true);
  let previewReport: DryRunReport | null = $state(null);
  let isLoading = $state(false);
  let errorMsg = $state('');

  // Upload source state
  let dirHandle: FileSystemDirectoryHandle | undefined = $state();
  let uploadFiles: File[] | undefined = $state();
  let sourceName = $state('');

  let pathInputEl: HTMLInputElement | undefined = $state();

  // Reset state when dialog opens
  $effect(() => {
    if (open) {
      stage = 'config';
      serverPath = defaultPath || '';
      excludesText = '';
      useGitignore = true;
      previewReport = null;
      isLoading = false;
      errorMsg = '';
      isSubmitting = false; // Reset submit guard
      // Initialize upload source from props
      dirHandle = initialDirHandle;
      uploadFiles = initialFiles;
      if (initialDirHandle) {
        sourceName = initialDirHandle.name + '/';
      } else if (initialFiles && initialFiles.length > 0) {
        sourceName = initialFiles.length === 1
          ? initialFiles[0].name
          : `${initialFiles.length} files`;
      } else {
        sourceName = '';
      }
      // Focus path input after DOM update
      requestAnimationFrame(() => pathInputEl?.focus());
    }
  });

  function getConfig(): TransferConfig {
    let path = serverPath.trim();
    // Resolve relative paths against panel pwd (defaultPath) on the client side,
    // since the server only knows initial_cwd, not the panel's current directory
    if (path && !path.startsWith('/') && !path.startsWith('~') && defaultPath && defaultPath.startsWith('/')) {
      path = defaultPath.endsWith('/') ? defaultPath + path : defaultPath + '/' + path;
    }
    const excludes = excludesText
      .split(',')
      .map(s => s.trim())
      .filter(s => s.length > 0);
    return { serverPath: path, excludes, useGitignore, dirHandle, files: uploadFiles };
  }

  let canSubmit = $derived(
    mode === 'download'
      ? !!serverPath.trim()
      : !!serverPath.trim() && !!(dirHandle || uploadFiles)
  );

  let isSubmitting = $state(false);

  function handleTransfer() {
    if (isSubmitting) return; // Prevent double-submission
    const config = getConfig();
    if (!config.serverPath) return;
    if (mode === 'upload' && !config.dirHandle && !config.files) return;
    isSubmitting = true;
    onTransfer?.(config);
    onClose?.();
  }

  async function handlePreview() {
    const config = getConfig();
    if (!config.serverPath) return;
    isLoading = true;
    errorMsg = '';
    try {
      const report = await onPreview?.(config);
      if (report) {
        previewReport = report;
        stage = 'preview';
      } else {
        errorMsg = 'Preview failed — check the path is valid.';
      }
    } catch {
      errorMsg = 'Preview request failed.';
    } finally {
      isLoading = false;
    }
  }

  function handleProceed() {
    const config = getConfig();
    if (!config.serverPath) return;
    onTransfer?.(config);
    onClose?.();
  }

  function handleBack() {
    stage = 'config';
    previewReport = null;
  }

  function handleOverlayClick(e: MouseEvent) {
    if (e.target === e.currentTarget) {
      if (stage === 'preview') {
        handleBack();
      } else {
        onClose?.();
      }
    }
  }

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Escape') {
      e.preventDefault();
      e.stopPropagation();
      if (stage === 'preview') {
        handleBack();
      } else {
        onClose?.();
      }
    }
  }

  function handlePathKeydown(e: KeyboardEvent) {
    if (e.key === 'Enter') {
      e.preventDefault();
      handleTransfer();
    }
  }

  async function selectFolder() {
    if (!('showDirectoryPicker' in window)) return;
    try {
      const handle = await (window as any).showDirectoryPicker({ mode: 'read' });
      dirHandle = handle;
      uploadFiles = undefined;
      sourceName = handle.name + '/';
    } catch (err: unknown) {
      if (err instanceof Error && err.name !== 'AbortError') {
        console.error('Directory picker failed:', err);
      }
    }
  }

  async function selectFiles() {
    if (!('showOpenFilePicker' in window)) return;
    try {
      const handles: FileSystemFileHandle[] = await (window as any).showOpenFilePicker({ multiple: true });
      const files = await Promise.all(handles.map((h: FileSystemFileHandle) => h.getFile()));
      dirHandle = undefined;
      uploadFiles = files;
      sourceName = files.length === 1 ? files[0].name : `${files.length} files`;
    } catch (err: unknown) {
      if (err instanceof Error && err.name !== 'AbortError') {
        console.error('File picker failed:', err);
      }
    }
  }

  function actionIcon(action: string): string {
    switch (action) {
      case 'new': return '+';
      case 'update': return '~';
      case 'delete': return '-';
      default: return '?';
    }
  }

  function actionClass(action: string): string {
    switch (action) {
      case 'new': return 'action-new';
      case 'update': return 'action-update';
      case 'delete': return 'action-delete';
      default: return '';
    }
  }

  let modeLabel = $derived(mode === 'upload' ? 'Upload' : 'Download');
</script>

{#if open}
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div class="transfer-overlay" onclick={handleOverlayClick} onkeydown={handleKeydown}>
    <div class="transfer-dialog">
      <div class="transfer-header">{modeLabel} Files</div>

      {#if stage === 'config'}
        {#if mode === 'upload'}
          <div class="form-group">
            <span class="form-label">Source:</span>
            <div class="source-row">
              <button type="button" class="btn btn-secondary btn-sm" onclick={selectFolder}>Folder</button>
              <button type="button" class="btn btn-secondary btn-sm" onclick={selectFiles}>Files</button>
              {#if sourceName}
                <span class="source-name">{sourceName}</span>
              {:else}
                <span class="source-hint">Select files or a folder to upload</span>
              {/if}
            </div>
          </div>
        {/if}

        <div class="form-group">
          <label class="form-label" for="server-path">Server Path:</label>
          <input
            bind:this={pathInputEl}
            id="server-path"
            type="text"
            class="form-input mono"
            bind:value={serverPath}
            placeholder="/home/user/project"
            onkeydown={handlePathKeydown}
          />
        </div>

        <div class="form-group">
          <label class="form-label" for="excludes">Exclude patterns:</label>
          <input
            id="excludes"
            type="text"
            class="form-input"
            bind:value={excludesText}
            placeholder="*.log, node_modules, .git"
          />
        </div>

        <label class="checkbox-label">
          <input type="checkbox" bind:checked={useGitignore} />
          Use .gitignore
        </label>

        {#if errorMsg}
          <div class="error-msg">{errorMsg}</div>
        {/if}

        <div class="button-row">
          <button type="button" class="btn btn-secondary" onclick={() => onClose?.()}>Cancel</button>
          <div class="button-spacer"></div>
          <button
            type="button"
            class="btn btn-secondary"
            onclick={handlePreview}
            disabled={!canSubmit || isLoading || isSubmitting}
          >
            {isLoading ? 'Loading...' : 'Preview'}
          </button>
          <button
            type="button"
            class="btn btn-primary"
            onclick={handleTransfer}
            disabled={!canSubmit || isLoading || isSubmitting}
          >
            {modeLabel}
          </button>
        </div>

      {:else if stage === 'preview' && previewReport}
        {@const totalSize = previewReport.entries.reduce((sum, e) => sum + (e.action !== 'delete' ? e.size : 0), 0)}
        <div class="preview-summary">
          {#if previewReport.newCount > 0}
            <span class="badge badge-new">+{previewReport.newCount} new</span>
          {/if}
          {#if previewReport.updateCount > 0}
            <span class="badge badge-update">~{previewReport.updateCount} modified</span>
          {/if}
          {#if previewReport.deleteCount > 0}
            <span class="badge badge-delete">-{previewReport.deleteCount} deleted</span>
          {/if}
          {#if previewReport.newCount === 0 && previewReport.updateCount === 0 && previewReport.deleteCount === 0}
            <span class="badge badge-none">No changes</span>
          {/if}
          {#if totalSize > 0}
            <span class="badge badge-size">{formatBytes(totalSize)}</span>
          {/if}
        </div>

        <div class="file-list">
          {#each previewReport.entries as entry}
            <div class="file-entry">
              <span class="file-action {actionClass(entry.action)}">{actionIcon(entry.action)}</span>
              <span class="file-path">{entry.path}</span>
              {#if entry.size > 0}
                <span class="file-size">{formatBytes(entry.size)}</span>
              {/if}
            </div>
          {/each}
          {#if previewReport.entries.length === 0}
            <div class="file-entry-empty">No files to transfer.</div>
          {/if}
        </div>

        <div class="button-row">
          <button type="button" class="btn btn-secondary" onclick={handleBack}>Back</button>
          <div class="button-spacer"></div>
          <button type="button" class="btn btn-primary" onclick={handleProceed}>
            Proceed
          </button>
        </div>
      {/if}
    </div>
  </div>
{/if}

<style>
  .transfer-overlay {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.5);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 1000;
  }

  .transfer-dialog {
    background: var(--toolbar-bg);
    border: 1px solid rgba(128, 128, 128, 0.3);
    border-radius: 8px;
    width: 480px;
    max-width: 90vw;
    padding: 20px;
    display: flex;
    flex-direction: column;
    gap: 12px;
    box-shadow: 0 8px 32px rgba(0, 0, 0, 0.4);
  }

  .transfer-header {
    font-size: 16px;
    font-weight: 600;
    color: var(--text);
  }

  .form-group {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .form-label {
    font-size: 12px;
    color: var(--text-dim);
  }

  .form-input {
    padding: 8px 10px;
    border: 1px solid rgba(128, 128, 128, 0.3);
    border-radius: 4px;
    background: rgba(0, 0, 0, 0.2);
    color: var(--text);
    font-size: 13px;
    outline: none;
  }

  .form-input.mono {
    font-family: ui-monospace, monospace;
  }

  .form-input:focus {
    border-color: rgba(128, 128, 128, 0.5);
  }

  .form-input::placeholder {
    color: rgba(128, 128, 128, 0.5);
  }

  .source-row {
    display: flex;
    align-items: center;
    gap: 6px;
  }

  .source-name {
    font-size: 12px;
    color: var(--text);
    font-family: ui-monospace, monospace;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    min-width: 0;
  }

  .source-hint {
    font-size: 12px;
    color: var(--text-dim);
  }

  .checkbox-label {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 13px;
    color: var(--text);
    cursor: pointer;
  }

  .checkbox-label input[type="checkbox"] {
    accent-color: var(--accent);
  }

  .button-row {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-top: 4px;
  }

  .button-spacer {
    flex: 1;
  }

  .btn {
    padding: 7px 16px;
    border: 1px solid rgba(128, 128, 128, 0.3);
    border-radius: 4px;
    font-size: 12px;
    cursor: pointer;
    white-space: nowrap;
    transition: background 0.15s;
  }

  .btn:disabled {
    opacity: 0.5;
    cursor: default;
  }

  .btn-sm {
    padding: 4px 10px;
    font-size: 11px;
  }

  .btn-secondary {
    background: rgba(128, 128, 128, 0.15);
    color: var(--text);
  }

  .btn-secondary:hover:not(:disabled) {
    background: rgba(128, 128, 128, 0.25);
  }

  .btn-primary {
    background: rgba(80, 160, 255, 0.25);
    color: var(--text);
    border-color: rgba(80, 160, 255, 0.4);
  }

  .btn-primary:hover:not(:disabled) {
    background: rgba(80, 160, 255, 0.35);
  }

  /* Preview stage */
  .preview-summary {
    display: flex;
    gap: 8px;
    flex-wrap: wrap;
  }

  .badge {
    padding: 3px 10px;
    border-radius: 12px;
    font-size: 12px;
    font-weight: 500;
  }

  .badge-new {
    background: rgba(80, 200, 120, 0.2);
    color: rgb(80, 200, 120);
  }

  .badge-update {
    background: rgba(240, 180, 60, 0.2);
    color: rgb(240, 180, 60);
  }

  .badge-delete {
    background: rgba(240, 80, 80, 0.2);
    color: rgb(240, 80, 80);
  }

  .badge-none {
    background: rgba(128, 128, 128, 0.2);
    color: var(--text-dim);
  }

  .badge-size {
    background: rgba(128, 160, 255, 0.15);
    color: rgba(128, 160, 255, 0.9);
  }

  .file-list {
    max-height: 300px;
    overflow-y: auto;
    border: 1px solid rgba(128, 128, 128, 0.2);
    border-radius: 4px;
    background: rgba(0, 0, 0, 0.15);
  }

  .file-entry {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 4px 8px;
    font-size: 12px;
    border-bottom: 1px solid rgba(128, 128, 128, 0.1);
  }

  .file-entry:last-child {
    border-bottom: none;
  }

  .file-action {
    width: 16px;
    text-align: center;
    font-weight: 700;
    font-family: ui-monospace, monospace;
  }

  .action-new {
    color: rgb(80, 200, 120);
  }

  .action-update {
    color: rgb(240, 180, 60);
  }

  .action-delete {
    color: rgb(240, 80, 80);
  }

  .file-path {
    flex: 1;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    color: var(--text);
    font-family: ui-monospace, monospace;
  }

  .file-size {
    color: var(--text-dim);
    font-size: 11px;
    white-space: nowrap;
  }

  .file-entry-empty {
    padding: 12px;
    text-align: center;
    color: var(--text-dim);
    font-size: 12px;
  }

  .error-msg {
    font-size: 12px;
    color: rgb(240, 80, 80);
    padding: 6px 10px;
    background: rgba(240, 80, 80, 0.1);
    border-radius: 4px;
  }
</style>
