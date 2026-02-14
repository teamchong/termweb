<script lang="ts">
  interface Props {
    open?: boolean;
    onClose?: () => void;
    onSave?: (content: string) => void;
    configPath?: string;
    configContent?: string;
    loading?: boolean;
  }

  let { open = false, onClose, onSave, configPath = '', configContent = '', loading = false }: Props = $props();

  let content = $state('');
  let isDirty = $state(false);
  let saved = $state(false);
  let textareaEl: HTMLTextAreaElement | undefined = $state();

  $effect(() => {
    if (open) {
      content = configContent;
      isDirty = false;
      saved = false;
    }
  });

  $effect(() => {
    if (open && !loading && textareaEl) {
      textareaEl.focus();
    }
  });

  function handleInput() {
    isDirty = content !== configContent;
    saved = false;
  }

  function handleSave() {
    onSave?.(content);
    isDirty = false;
    saved = true;
    setTimeout(() => { saved = false; }, 1500);
  }

  function handleOverlayClick(e: MouseEvent) {
    if (e.target === e.currentTarget) onClose?.();
  }

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Escape') {
      e.preventDefault();
      e.stopPropagation();
      onClose?.();
    } else if (e.key === 's' && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      e.stopPropagation();
      if (isDirty) handleSave();
    }
  }
</script>

{#if open}
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div class="config-overlay" onclick={handleOverlayClick} onkeydown={handleKeydown}>
    <div class="config-dialog">
      <div class="config-header">
        <span class="config-title">Ghostty Config</span>
        <span class="config-path">{configPath}</span>
      </div>

      {#if loading}
        <div class="spinner-container">
          <div class="spinner"></div>
          <div class="spinner-text">Loading config...</div>
        </div>
      {:else}
        <textarea
          bind:this={textareaEl}
          bind:value={content}
          oninput={handleInput}
          class="config-textarea"
          spellcheck="false"
          autocomplete="off"
          autocorrect="off"
          autocapitalize="off"
        ></textarea>
      {/if}

      <div class="config-footer">
        <div class="config-hint">
          {#if saved}
            <span class="saved-indicator">Saved & reloaded</span>
          {:else if isDirty}
            <span class="unsaved-indicator">Unsaved changes</span>
          {:else}
            <span class="hint-text">Cmd+S to save</span>
          {/if}
        </div>
        <div class="config-actions">
          <button type="button" class="btn btn-secondary" onclick={() => onClose?.()}>Close</button>
          <button type="button" class="btn btn-primary" class:saved disabled={!isDirty && !saved} onclick={handleSave}>
            {saved ? 'Saved' : 'Save & Reload'}
          </button>
        </div>
      </div>
    </div>
  </div>
{/if}

<style>
  .config-overlay {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.5);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 1000;
  }

  .config-dialog {
    background: var(--toolbar-bg);
    border: 1px solid rgba(128, 128, 128, 0.3);
    border-radius: 8px;
    width: 640px;
    max-width: 90vw;
    max-height: 80vh;
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 12px;
    box-shadow: 0 8px 32px rgba(0, 0, 0, 0.4);
  }

  .config-header {
    display: flex;
    align-items: baseline;
    gap: 10px;
  }

  .config-title {
    font-size: 15px;
    font-weight: 600;
    color: var(--text);
  }

  .config-path {
    font-size: 11px;
    color: var(--text-dim);
    font-family: monospace;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .config-textarea {
    flex: 1;
    min-height: 400px;
    max-height: 60vh;
    padding: 12px;
    border: 1px solid rgba(128, 128, 128, 0.3);
    border-radius: 4px;
    background: rgba(0, 0, 0, 0.3);
    color: var(--text);
    font-size: 13px;
    font-family: monospace;
    line-height: 1.5;
    resize: vertical;
    outline: none;
    tab-size: 4;
    white-space: pre;
    overflow-wrap: normal;
    overflow-x: auto;
  }

  .config-textarea:focus {
    border-color: rgba(128, 128, 128, 0.5);
  }

  .config-footer {
    display: flex;
    align-items: center;
    justify-content: space-between;
  }

  .config-hint {
    font-size: 11px;
  }

  .hint-text {
    color: var(--text-dim);
  }

  .saved-indicator {
    color: rgba(100, 200, 100, 0.9);
  }

  .unsaved-indicator {
    color: rgba(255, 200, 100, 0.9);
  }

  .config-actions {
    display: flex;
    gap: 8px;
  }

  .btn {
    padding: 6px 16px;
    border: 1px solid rgba(128, 128, 128, 0.3);
    border-radius: 4px;
    font-size: 12px;
    cursor: pointer;
    transition: background 0.15s;
  }

  .btn-secondary {
    background: transparent;
    color: var(--text);
  }

  .btn-secondary:hover {
    background: rgba(128, 128, 128, 0.15);
  }

  .btn-primary {
    background: rgba(128, 128, 128, 0.2);
    color: var(--text);
  }

  .btn-primary:hover:not(:disabled) {
    background: rgba(128, 128, 128, 0.3);
  }

  .btn-primary:disabled {
    opacity: 0.4;
    cursor: default;
  }

  .btn-primary.saved {
    background: rgba(100, 200, 100, 0.3);
    border-color: rgba(100, 200, 100, 0.5);
  }

  .spinner-container {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 12px;
    padding: 48px 0;
  }

  .spinner {
    width: 32px;
    height: 32px;
    border: 3px solid rgba(128, 128, 128, 0.2);
    border-top-color: var(--text);
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
  }

  @keyframes spin {
    to { transform: rotate(360deg); }
  }

  .spinner-text {
    font-size: 12px;
    color: var(--text-dim);
  }
</style>
