<script lang="ts">
  import { sessions } from '../stores/index';
  import type { MuxClient } from '../services/mux';
  import type { Session } from '../types';

  interface Props {
    open?: boolean;
    onClose?: () => void;
    muxClient: MuxClient | null;
    onShareSession?: (session: Session) => void;
  }

  let { open = false, onClose, muxClient, onShareSession }: Props = $props();

  let confirmDeleteId = $state<string | null>(null);

  $effect(() => {
    if (open && muxClient) {
      muxClient.requestSessionList();
      confirmDeleteId = null;
    }
  });

  function handleDelete(session: Session) {
    if (confirmDeleteId === session.id) {
      muxClient?.deleteSession(session.id);
      confirmDeleteId = null;
    } else {
      confirmDeleteId = session.id;
    }
  }

  function handleRegenToken(session: Session) {
    muxClient?.regenerateToken(session.id);
  }

  function handleCopyUrl(session: Session) {
    const url = `${window.location.origin}?token=${session.token}`;
    navigator.clipboard.writeText(url).catch(() => {});
  }

  function handleShare(session: Session) {
    onShareSession?.(session);
  }

  function handleOverlayClick(e: MouseEvent) {
    if (e.target === e.currentTarget) onClose?.();
  }

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Escape') {
      e.preventDefault();
      e.stopPropagation();
      onClose?.();
    }
  }
</script>

{#if open}
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div class="overlay" onclick={handleOverlayClick} onkeydown={handleKeydown}>
    <div class="dialog">
      <div class="header">
        <span class="title">Manage Shares</span>
        <button type="button" class="close-x" onclick={() => onClose?.()}>x</button>
      </div>

      {#if $sessions.length === 0}
        <div class="empty">No shared sessions yet. Use Share menu to share a panel or tab.</div>
      {:else}
        <div class="session-list">
          {#each $sessions as session (session.id)}
            <div class="session-row">
              <div class="session-info">
                <div class="session-name">{session.name || session.id}</div>
                <div class="session-id">{session.id}</div>
              </div>
              <div class="session-actions">
                <button type="button" class="action-btn" onclick={() => handleShare(session)} title="Show QR & URL">QR</button>
                <button type="button" class="action-btn" onclick={() => handleCopyUrl(session)} title="Copy share URL">Copy</button>
                <button type="button" class="action-btn" onclick={() => handleRegenToken(session)} title="Regenerate token">Regen</button>
                <button
                  type="button"
                  class="action-btn delete"
                  class:confirming={confirmDeleteId === session.id}
                  onclick={() => handleDelete(session)}
                  title={confirmDeleteId === session.id ? 'Click again to confirm' : 'Delete session'}
                >{confirmDeleteId === session.id ? 'Confirm?' : 'Delete'}</button>
              </div>
            </div>
          {/each}
        </div>
      {/if}

      <button type="button" class="close-btn" onclick={() => onClose?.()}>Close</button>
    </div>
  </div>
{/if}

<style>
  .overlay {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.5);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 1000;
  }

  .dialog {
    background: var(--toolbar-bg);
    border: 1px solid rgba(128, 128, 128, 0.3);
    border-radius: 8px;
    width: 520px;
    max-width: 90vw;
    max-height: 80vh;
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 12px;
    box-shadow: 0 8px 32px rgba(0, 0, 0, 0.4);
  }

  .header {
    display: flex;
    justify-content: space-between;
    align-items: center;
  }

  .title {
    font-size: 16px;
    font-weight: 600;
    color: var(--text);
  }

  .close-x {
    background: none;
    border: none;
    color: var(--text-dim);
    font-size: 18px;
    cursor: pointer;
    padding: 2px 6px;
    line-height: 1;
  }

  .close-x:hover {
    color: var(--text);
  }

  .empty {
    font-size: 13px;
    color: var(--text-dim);
    text-align: center;
    padding: 24px 0;
  }

  .session-list {
    display: flex;
    flex-direction: column;
    gap: 6px;
    overflow-y: auto;
    max-height: 50vh;
  }

  .session-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 8px 10px;
    border: 1px solid rgba(128, 128, 128, 0.2);
    border-radius: 4px;
    background: rgba(0, 0, 0, 0.1);
  }

  .session-info {
    min-width: 0;
    flex: 1;
  }

  .session-name {
    font-size: 13px;
    color: var(--text);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .session-id {
    font-size: 11px;
    color: var(--text-dim);
    font-family: monospace;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .session-actions {
    display: flex;
    gap: 4px;
    flex-shrink: 0;
    margin-left: 8px;
  }

  .action-btn {
    padding: 3px 8px;
    border: 1px solid rgba(128, 128, 128, 0.3);
    border-radius: 3px;
    background: rgba(128, 128, 128, 0.1);
    color: var(--text);
    font-size: 11px;
    cursor: pointer;
    white-space: nowrap;
  }

  .action-btn:hover {
    background: rgba(128, 128, 128, 0.2);
  }

  .action-btn.delete {
    color: #e06c6c;
    border-color: rgba(224, 108, 108, 0.3);
  }

  .action-btn.delete:hover {
    background: rgba(224, 108, 108, 0.15);
  }

  .action-btn.confirming {
    background: rgba(224, 108, 108, 0.25);
    border-color: rgba(224, 108, 108, 0.5);
  }

  .close-btn {
    align-self: center;
    padding: 6px 20px;
    border: 1px solid rgba(128, 128, 128, 0.3);
    border-radius: 4px;
    background: transparent;
    color: var(--text);
    font-size: 12px;
    cursor: pointer;
  }

  .close-btn:hover {
    background: rgba(128, 128, 128, 0.15);
  }
</style>
