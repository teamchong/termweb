<script lang="ts">
  let {
    downloads,
    pendingPath = null,
    opfsUsageBytes = 0,
    opfsFileCount = 0,
    open = $bindable(false),
    onClose = () => {},
    onCancel = () => {},
    onClearStorage = () => {},
    onClearCompleted = () => {}
  }: {
    downloads: Map<number, {
      files: number;
      total: number;
      bytes: number;
      totalBytes: number;
      path?: string;
      status: 'active' | 'complete' | 'error';
      startTime: number;
      endTime?: number;
    }>;
    pendingPath?: string | null;
    opfsUsageBytes?: number;
    opfsFileCount?: number;
    open?: boolean;
    onClose?: () => void;
    onCancel?: (transferId: number) => void;
    onClearStorage?: () => void;
    onClearCompleted?: () => void;
  } = $props();

  function formatBytes(bytes: number): string {
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
    return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
  }

  function getProgress(d: { files: number; total: number; bytes: number; totalBytes: number }): number {
    return d.totalBytes > 0 ? Math.round((d.bytes / d.totalBytes) * 100) : 0;
  }

  function formatDuration(ms: number): string {
    const seconds = Math.floor(ms / 1000);
    if (seconds < 60) return `${seconds}s`;
    const minutes = Math.floor(seconds / 60);
    const secs = seconds % 60;
    return `${minutes}m ${secs}s`;
  }

  function formatTime(timestamp: number): string {
    return new Date(timestamp).toLocaleTimeString();
  }

  function hasActiveTransfers(): boolean {
    return Array.from(downloads.values()).some(d => d.status === 'active');
  }

  function handleCancel(transferId: number, event: Event) {
    event.stopPropagation();
    onCancel(transferId);
  }

  function handleClearStorage(event: Event) {
    event.stopPropagation();
    if (confirm('Are you sure you want to clear all cached files and completed transfers? This will free up disk space but the next download will take longer.')) {
      onClearStorage();
      onClearCompleted();
    }
  }
</script>

{#if open}
  <div class="dialog-backdrop" onclick={onClose} role="presentation">
    <!-- svelte-ignore a11y_click_events_have_key_events -->
    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <div class="dialog" onclick={(e) => e.stopPropagation()}>
      <div class="dialog-header">
        <h2>Transfer Monitor</h2>
        <button type="button" class="close-btn" onclick={onClose}>✕</button>
      </div>

      <div class="dialog-body">
        {#if downloads.size === 0 && !pendingPath}
          <div class="empty-state">
            <p>No transfers</p>
          </div>
        {:else}
          {#if pendingPath && downloads.size === 0}
            <div class="download-item">
              <div class="download-header">
                <span class="download-icon">⬇</span>
                <span class="download-path">{pendingPath}</span>
              </div>
              <div class="download-stats">
                <span>Starting...</span>
              </div>
              <div class="progress-bar">
                <div class="progress-fill" style="width: 0%"></div>
              </div>
            </div>
          {/if}
          {#each Array.from(downloads.entries()) as [transferId, download]}
            {@const pct = getProgress(download)}
            {@const duration = download.endTime ? download.endTime - download.startTime : Date.now() - download.startTime}
            <div class="download-item" class:completed={download.status === 'complete'}>
              <div class="download-header">
                {#if download.status === 'complete'}
                  <span class="download-icon">✅</span>
                {:else}
                  <span class="download-icon">⬇</span>
                {/if}
                <span class="download-path">{download.path || `Transfer ${transferId}`}</span>
                {#if download.status === 'active'}
                  <button
                    type="button"
                    class="cancel-btn"
                    onclick={(e) => handleCancel(transferId, e)}
                    title="Cancel transfer"
                  >
                    ✕
                  </button>
                {:else if download.status === 'complete'}
                  <button
                    type="button"
                    class="clear-item-btn"
                    onclick={(e) => handleCancel(transferId, e)}
                    title="Clear from list"
                  >
                    ✕
                  </button>
                {/if}
              </div>
              <div class="download-stats">
                {#if download.status === 'complete'}
                  <span>✓ Complete</span>
                  <span>·</span>
                  <span>{download.files} files</span>
                  <span>·</span>
                  <span>{formatBytes(download.totalBytes)}</span>
                  <span>·</span>
                  <span>{formatDuration(duration)}</span>
                  <span>·</span>
                  <span class="timestamp">{formatTime(download.endTime!)}</span>
                {:else}
                  <span>{download.files}/{download.total} files</span>
                  <span>·</span>
                  <span>{formatBytes(download.bytes)} / {formatBytes(download.totalBytes)}</span>
                  <span>·</span>
                  <span>{pct}%</span>
                {/if}
              </div>
              <div class="progress-bar">
                <div class="progress-fill" class:complete={download.status === 'complete'} style="width: {download.status === 'complete' ? 100 : pct}%"></div>
              </div>
            </div>
          {/each}
        {/if}
      </div>

      <div class="dialog-footer">
        <div class="footer-left">
          <button type="button" class="hide-btn" onclick={onClose}>
            Hide
          </button>
        </div>
        <div class="footer-right">
          <button type="button" class="clear-storage-btn" onclick={handleClearStorage} title="Clear completed transfers and cached files">
            Clear {#if opfsUsageBytes > 0}({formatBytes(opfsUsageBytes)}){/if}
          </button>
        </div>
      </div>
    </div>
  </div>
{/if}

<style>
  .dialog-backdrop {
    position: fixed;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    background: rgba(0, 0, 0, 0.5);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 10000;
  }

  .dialog {
    background: var(--bg);
    border-radius: 8px;
    box-shadow: 0 8px 32px rgba(0, 0, 0, 0.4);
    width: 90%;
    max-width: 500px;
    max-height: 80vh;
    display: flex;
    flex-direction: column;
  }

  .dialog-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 16px 20px;
    border-bottom: 1px solid rgba(128, 128, 128, 0.2);
  }

  .dialog-header h2 {
    margin: 0;
    font-size: 16px;
    font-weight: 600;
    color: var(--text);
  }

  .close-btn {
    background: none;
    border: none;
    color: var(--text);
    font-size: 20px;
    cursor: pointer;
    padding: 4px 8px;
    line-height: 1;
    opacity: 0.7;
    transition: opacity 0.2s;
  }

  .close-btn:hover {
    opacity: 1;
  }

  .dialog-body {
    padding: 20px;
    overflow-y: auto;
    display: flex;
    flex-direction: column;
    gap: 16px;
  }

  .download-item {
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  .download-item.completed {
    opacity: 0.7;
  }

  .download-header {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .download-icon {
    font-size: 18px;
  }

  .download-path {
    font-weight: 500;
    color: var(--text);
    flex: 1;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .download-stats {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: 13px;
    color: rgba(255, 255, 255, 0.6);
  }

  .progress-bar {
    width: 100%;
    height: 6px;
    background: rgba(128, 128, 128, 0.2);
    border-radius: 3px;
    overflow: hidden;
  }

  .progress-fill {
    height: 100%;
    background: linear-gradient(90deg, #4a9eff 0%, #68b5ff 100%);
    transition: width 0.3s ease;
    border-radius: 3px;
  }

  .progress-fill.complete {
    background: linear-gradient(90deg, #4caf50 0%, #66bb6a 100%);
  }

  .timestamp {
    font-size: 11px;
    opacity: 0.8;
  }

  .cancel-btn {
    background: none;
    border: none;
    color: rgba(255, 255, 255, 0.5);
    font-size: 16px;
    cursor: pointer;
    padding: 4px 8px;
    line-height: 1;
    transition: color 0.2s;
    margin-left: auto;
  }

  .cancel-btn:hover {
    color: #ff6b6b;
  }

  .clear-item-btn {
    background: none;
    border: none;
    color: rgba(255, 255, 255, 0.4);
    font-size: 16px;
    cursor: pointer;
    padding: 4px 8px;
    line-height: 1;
    transition: color 0.2s;
    margin-left: auto;
  }

  .clear-item-btn:hover {
    color: rgba(255, 255, 255, 0.8);
  }

  .dialog-footer {
    padding: 16px 20px;
    border-top: 1px solid rgba(128, 128, 128, 0.2);
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 12px;
  }

  .footer-left, .footer-right {
    display: flex;
    gap: 12px;
  }

  .hide-btn {
    padding: 8px 16px;
    background: rgba(128, 128, 128, 0.2);
    border: none;
    border-radius: 4px;
    color: var(--text);
    font-size: 13px;
    cursor: pointer;
    transition: background 0.2s;
  }

  .hide-btn:hover {
    background: rgba(128, 128, 128, 0.3);
  }

  .clear-storage-btn {
    padding: 8px 16px;
    background: rgba(128, 128, 128, 0.2);
    border: none;
    border-radius: 4px;
    color: var(--text);
    font-size: 13px;
    cursor: pointer;
    transition: background 0.2s;
  }

  .clear-storage-btn:hover {
    background: rgba(128, 128, 128, 0.3);
  }

  .empty-state {
    text-align: center;
    padding: 40px 20px;
    color: rgba(255, 255, 255, 0.5);
  }

  .empty-state p {
    margin: 0;
    font-size: 14px;
  }
</style>
