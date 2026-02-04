<script lang="ts">
  import { tabs, activeTabId } from '../stores/index';

  interface Props {
    open?: boolean;
    onClose?: () => void;
    onSelectTab?: (id: string) => void;
    onCloseTab?: (id: string) => void;
    onNewTab?: () => void;
  }

  let { open = false, onClose, onSelectTab, onCloseTab, onNewTab }: Props = $props();

  // Convert tabs to array
  let tabList = $derived(Array.from($tabs.values()));

  function handleSelectTab(id: string) {
    onSelectTab?.(id);
    onClose?.();
  }

  function handleCloseTab(e: MouseEvent, id: string) {
    e.stopPropagation();
    onCloseTab?.(id);
  }

  function handleNewTab() {
    onNewTab?.();
    onClose?.();
  }

  function handleOverlayClick(e: MouseEvent) {
    if (e.target === e.currentTarget) {
      onClose?.();
    }
  }

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Escape') {
      e.stopPropagation();
      onClose?.();
    }
  }

  // Only attach window listener when open
  $effect(() => {
    if (open) {
      window.addEventListener('keydown', handleKeydown);
      return () => {
        window.removeEventListener('keydown', handleKeydown);
      };
    }
  });
</script>

{#if open}
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <!-- svelte-ignore a11y_click_events_have_key_events -->
  <div class="tab-overview-overlay" onclick={handleOverlayClick}>
    <div class="tab-overview">
      <div class="tab-overview-header">
        <h2>All Tabs</h2>
        <button type="button" class="tab-overview-close" onclick={() => onClose?.()}>×</button>
      </div>
      <div class="tab-overview-grid">
        {#each tabList as tab, i (tab.id)}
          <!-- svelte-ignore a11y_no_static_element_interactions -->
          <!-- svelte-ignore a11y_click_events_have_key_events -->
          <div
            class="tab-overview-item"
            class:active={$activeTabId === tab.id}
            onclick={() => handleSelectTab(tab.id)}
          >
            <div class="tab-overview-preview">
              <span class="tab-number">{i + 1}</span>
            </div>
            <div class="tab-overview-info">
              <span class="tab-title">{tab.title || 'Terminal'}</span>
              <button
                type="button"
                class="tab-close-btn"
                onclick={(e) => handleCloseTab(e, tab.id)}
                aria-label="Close tab"
              >×</button>
            </div>
          </div>
        {/each}
        <button type="button" class="tab-overview-item new-tab" onclick={handleNewTab}>
          <div class="tab-overview-preview">
            <span class="new-tab-icon">+</span>
          </div>
          <div class="tab-overview-info">
            <span class="tab-title">New Tab</span>
          </div>
        </button>
      </div>
    </div>
  </div>
{/if}

<style>
  .tab-overview-overlay {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.7);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 950;
  }

  .tab-overview {
    background: var(--toolbar-bg);
    border-radius: 12px;
    padding: 16px;
    width: 80vw;
    max-width: 800px;
    max-height: 80vh;
    display: flex;
    flex-direction: column;
    box-shadow: 0 8px 32px rgba(0, 0, 0, 0.5);
  }

  .tab-overview-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 16px;
  }

  .tab-overview-header h2 {
    margin: 0;
    font-size: 16px;
    font-weight: 500;
    color: var(--text);
  }

  .tab-overview-close {
    width: 28px;
    height: 28px;
    display: flex;
    align-items: center;
    justify-content: center;
    border: none;
    background: transparent;
    color: var(--text-dim);
    cursor: pointer;
    border-radius: 6px;
    font-size: 18px;
  }

  .tab-overview-close:hover {
    background: var(--tab-hover);
    color: var(--text);
  }

  .tab-overview-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(180px, 1fr));
    gap: 12px;
    overflow-y: auto;
  }

  .tab-overview-item {
    background: var(--bg);
    border: 2px solid transparent;
    border-radius: 8px;
    padding: 0;
    cursor: pointer;
    overflow: hidden;
    text-align: left;
    transition: border-color 0.15s, transform 0.15s;
  }

  .tab-overview-item:hover {
    border-color: rgba(128, 128, 128, 0.3);
    transform: scale(1.02);
  }

  .tab-overview-item.active {
    border-color: var(--accent);
  }

  .tab-overview-preview {
    height: 100px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: var(--bg);
    color: var(--text-dim);
    font-size: 32px;
    font-weight: 100;
    font-family: ui-monospace, monospace;
  }

  .tab-overview-item.new-tab .tab-overview-preview {
    background: rgba(128, 128, 128, 0.1);
  }

  .new-tab-icon {
    font-size: 48px;
    color: var(--accent);
  }

  .tab-overview-info {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 8px 12px;
    background: var(--toolbar-bg);
    border-top: 1px solid rgba(128, 128, 128, 0.2);
  }

  .tab-title {
    font-size: 12px;
    color: var(--text);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .tab-close-btn {
    width: 20px;
    height: 20px;
    display: flex;
    align-items: center;
    justify-content: center;
    border: none;
    background: transparent;
    color: var(--text-dim);
    cursor: pointer;
    border-radius: 4px;
    font-size: 14px;
    opacity: 0;
    transition: opacity 0.15s;
  }

  .tab-overview-item:hover .tab-close-btn {
    opacity: 1;
  }

  .tab-close-btn:hover {
    background: var(--close-hover);
    color: var(--text);
  }
</style>
