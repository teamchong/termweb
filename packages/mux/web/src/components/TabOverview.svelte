<script lang="ts">
  import { tabs, activeTabId } from '../stores/index';
  import type { MuxClient } from '../services/mux';

  interface Props {
    open?: boolean;
    panelsEl?: HTMLElement;
    muxClient?: MuxClient | null;
    onClose?: () => void;
    onSelectTab?: (id: string) => void;
    onCloseTab?: (id: string) => void;
    onNewTab?: () => void;
  }

  let { open = false, panelsEl, muxClient, onClose, onSelectTab, onCloseTab, onNewTab }: Props = $props();

  // Convert tabs to array
  let tabList = $derived(Array.from($tabs.values()));

  // Preview dimensions
  let previewWidth = $state(0);
  let previewHeight = $state(0);
  let scale = $state(0);

  // Keyboard navigation - selected index (-1 = new tab button)
  let selectedIndex = $state(0);

  // Track moved tab elements for restoration
  let movedTabs: Array<{ tabId: string; element: HTMLElement; wrapper: HTMLElement }> = [];

  function handleSelectTab(id: string) {
    restoreTabElements();
    onSelectTab?.(id);
    onClose?.();
  }

  function handleCloseTab(e: MouseEvent, id: string) {
    e.stopPropagation();
    // Remove from movedTabs before closing
    const idx = movedTabs.findIndex(t => t.tabId === id);
    if (idx !== -1) {
      movedTabs.splice(idx, 1);
    }
    onCloseTab?.(id);
    // Close overview if no tabs remain
    if ($tabs.size <= 1) {
      restoreTabElements();
      onClose?.();
    }
  }

  function handleNewTab() {
    restoreTabElements();
    onNewTab?.();
    onClose?.();
  }

  function handleOverlayClick(e: MouseEvent) {
    if (e.target === e.currentTarget) {
      restoreTabElements();
      onClose?.();
    }
  }

  function handleKeydown(e: KeyboardEvent) {
    const totalItems = tabList.length + 1; // tabs + new tab button

    switch (e.key) {
      case 'Escape':
        e.preventDefault();
        e.stopPropagation();
        restoreTabElements();
        onClose?.();
        break;
      case 'ArrowRight':
      case 'ArrowDown':
        e.preventDefault();
        selectedIndex = (selectedIndex + 1) % totalItems;
        break;
      case 'ArrowLeft':
      case 'ArrowUp':
        e.preventDefault();
        selectedIndex = (selectedIndex - 1 + totalItems) % totalItems;
        break;
      case 'Enter':
        e.preventDefault();
        if (selectedIndex < tabList.length) {
          handleSelectTab(tabList[selectedIndex].id);
        } else {
          handleNewTab();
        }
        break;
    }
  }

  function restoreTabElements(): void {
    if (!panelsEl) return;
    for (const { element, wrapper } of movedTabs) {
      // Restore original styles
      element.style.display = '';
      element.style.position = '';
      element.style.width = '';
      element.style.height = '';
      // Move back to panels container
      panelsEl.appendChild(element);
      // Remove the scale wrapper
      wrapper.remove();
    }
    movedTabs = [];
    // Resume panel rendering
    muxClient?.resumeAllPanels();
  }

  function moveTabElementsToOverview(): void {
    if (!muxClient || !panelsEl) return;

    // Pause panel rendering to save server resources
    muxClient.pauseAllPanels();

    const tabElements = muxClient.getTabElements();
    const rect = panelsEl.getBoundingClientRect();

    // Calculate dimensions
    const aspectRatio = rect.width / rect.height;
    const targetHeight = 200;
    const targetWidth = Math.round(targetHeight * aspectRatio);
    scale = Math.min(targetWidth / rect.width, targetHeight / rect.height);
    previewWidth = rect.width * scale;
    previewHeight = rect.height * scale;

    movedTabs = [];

    for (const [tabId, element] of tabElements) {
      const contentEl = document.querySelector(`[data-tab-id="${tabId}"] .tab-preview-content`) as HTMLElement;
      if (!contentEl) continue;

      // Create scale wrapper
      const scaleWrapper = document.createElement('div');
      scaleWrapper.style.cssText = `
        width: ${rect.width}px;
        height: ${rect.height}px;
        transform: scale(${scale});
        transform-origin: top left;
        pointer-events: none;
        position: absolute;
        top: 0;
        left: 0;
      `;

      // Style the tab element for preview
      element.style.display = 'flex';
      element.style.position = 'relative';
      element.style.width = '100%';
      element.style.height = '100%';

      scaleWrapper.appendChild(element);
      contentEl.appendChild(scaleWrapper);

      movedTabs.push({ tabId, element, wrapper: scaleWrapper });
    }
  }

  // Calculate preview dimensions and move elements when open
  $effect(() => {
    if (open && panelsEl && muxClient) {
      // Reset selection to active tab
      const activeIndex = tabList.findIndex(t => t.id === $activeTabId);
      selectedIndex = activeIndex >= 0 ? activeIndex : 0;
      // Use requestAnimationFrame to ensure DOM is ready
      requestAnimationFrame(() => {
        moveTabElementsToOverview();
      });
    }
  });

  // Keyboard listener
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
  <div class="tab-overview" onclick={handleOverlayClick}>
    <div class="tab-overview-grid">
      {#each tabList as tab, i (tab.id)}
        <!-- svelte-ignore a11y_no_static_element_interactions -->
        <!-- svelte-ignore a11y_click_events_have_key_events -->
        <div
          class="tab-preview"
          class:active={$activeTabId === tab.id}
          class:selected={selectedIndex === i}
          data-tab-id={tab.id}
          style="width: {previewWidth}px;"
          onclick={() => handleSelectTab(tab.id)}
        >
          <div class="tab-preview-title">
            <span
              class="tab-preview-close"
              role="button"
              tabindex="0"
              onclick={(e) => handleCloseTab(e, tab.id)}
              onkeydown={(e) => e.key === 'Enter' && handleCloseTab(e as unknown as MouseEvent, tab.id)}
            >✕</span>
            <span class="tab-preview-title-text">
              <span class="tab-preview-indicator">•</span>
              <span class="tab-preview-title-label">{tab.title || '👻'}</span>
            </span>
            <span class="tab-preview-spacer"></span>
          </div>
          <div
            class="tab-preview-content"
            style="width: {previewWidth}px; height: {previewHeight}px;"
          >
            <!-- Tab element will be moved here -->
          </div>
        </div>
      {/each}
      <!-- svelte-ignore a11y_no_static_element_interactions -->
      <!-- svelte-ignore a11y_click_events_have_key_events -->
      <div
        class="tab-preview-new"
        class:selected={selectedIndex === tabList.length}
        style="width: {previewWidth}px; height: {previewHeight + 18}px;"
        onclick={handleNewTab}
      >
        <span class="tab-preview-new-icon">+</span>
      </div>
    </div>
  </div>
{/if}

<style>
  .tab-overview {
    position: fixed;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    background: color-mix(in srgb, var(--bg) 90%, black);
    z-index: 1000;
    overflow: auto;
    padding: 32px;
  }

  .tab-overview-grid {
    display: flex;
    flex-wrap: wrap;
    gap: 20px;
    align-items: flex-start;
    justify-content: flex-start;
  }

  .tab-preview {
    background: var(--bg);
    border-radius: 12px;
    overflow: hidden;
    cursor: pointer;
    transition: transform 0.15s, box-shadow 0.15s, border-color 0.15s;
    position: relative;
    border: 3px solid transparent;
  }

  .tab-preview:hover {
    transform: scale(1.02);
    box-shadow: 0 8px 32px rgba(0, 0, 0, 0.4);
    border-color: rgba(255, 255, 255, 0.3);
  }

  .tab-preview.active {
    border-color: #007AFF;
    box-shadow: 0 0 0 1px #007AFF, 0 4px 20px rgba(0, 122, 255, 0.3);
  }

  .tab-preview.selected {
    outline: 2px solid rgba(255, 255, 255, 0.6);
    outline-offset: 2px;
  }

  .tab-preview-new.selected {
    outline: 2px solid rgba(255, 255, 255, 0.6);
    outline-offset: 2px;
  }

  .tab-preview-title {
    padding: 0 6px;
    font-size: 11px;
    color: var(--text);
    background: var(--toolbar-bg);
    display: flex;
    align-items: center;
    justify-content: space-between;
    border-radius: 12px 12px 0 0;
  }

  .tab-preview-spacer {
    width: 16px;
    flex-shrink: 0;
  }

  .tab-preview-title-text {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
    min-width: 0;
    flex: 1;
  }

  .tab-preview-indicator {
    color: var(--text-dim);
    flex-shrink: 0;
  }

  .tab-preview-title-label {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .tab-preview-close {
    width: 16px;
    height: 16px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: 50%;
    font-size: 10px;
    color: var(--text-dim);
    cursor: pointer;
    transition: opacity 0.15s, background 0.1s;
    opacity: 0;
  }

  .tab-preview:hover .tab-preview-close {
    opacity: 1;
  }

  .tab-preview-close:hover {
    background: var(--close-hover);
    color: var(--text);
  }

  .tab-preview-content {
    overflow: hidden;
    position: relative;
    background: var(--bg);
    border-radius: 0 0 12px 12px;
  }

  .tab-preview-new {
    background: rgba(255, 255, 255, 0.05);
    border: 3px dashed rgba(255, 255, 255, 0.2);
    border-radius: 12px;
    cursor: pointer;
    transition: all 0.15s;
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .tab-preview-new:hover {
    background: rgba(255, 255, 255, 0.1);
    border-color: rgba(255, 255, 255, 0.4);
    transform: scale(1.02);
  }

  .tab-preview-new-icon {
    font-size: 48px;
    color: rgba(255, 255, 255, 0.4);
  }

  .tab-preview-new:hover .tab-preview-new-icon {
    color: rgba(255, 255, 255, 0.7);
  }

  @media (hover: none) {
    .tab-preview-close {
      opacity: 1;
    }
  }
</style>
