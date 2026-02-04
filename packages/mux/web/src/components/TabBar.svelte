<script lang="ts">
  import { tabs, activeTabId } from '../stores/index';

  interface Props {
    onNewTab?: () => void;
    onSelectTab?: (id: string) => void;
    onCloseTab?: (id: string) => void;
    onShowAllTabs?: () => void;
  }

  let { onNewTab, onSelectTab, onCloseTab, onShowAllTabs }: Props = $props();

  // Convert Map to array for iteration
  let tabList = $derived(Array.from($tabs.values()));
</script>

<div id="tabbar">
  <div id="tabs" role="tablist">
    {#each tabList as tab, i (tab.id)}
      <div
        class="tab"
        class:active={$activeTabId === tab.id}
        onclick={() => onSelectTab?.(tab.id)}
        onkeydown={(e) => e.key === 'Enter' && onSelectTab?.(tab.id)}
        role="tab"
        tabindex="0"
        aria-selected={$activeTabId === tab.id}
      >
        <button
          type="button"
          class="close"
          onclick={(e) => { e.stopPropagation(); onCloseTab?.(tab.id); }}
          aria-label="Close tab"
        >×</button>
        <div class="title-wrapper">
          <span class="indicator">{i + 1}</span>
          <span class="title">{tab.title || 'Terminal'}</span>
        </div>
      </div>
    {/each}
  </div>
  <button id="show-all-tabs" title="Show All Tabs (⌘⇧\)" onclick={() => onShowAllTabs?.()}>⊞</button>
  <button id="new-tab" title="New Tab (⌘/)" onclick={() => onNewTab?.()}>+</button>
</div>

<style>
  #tabbar {
    flex: 1;
    display: flex;
    align-items: center;
    background: var(--tabbar-bg);
    border-radius: 14px;
    padding: 2px;
    gap: 2px;
    min-width: 0;
    overflow: hidden;
  }

  #tabs {
    display: flex;
    flex: 1;
    gap: 2px;
    min-width: 0;
  }

  .tab {
    flex: 1;
    display: flex;
    align-items: center;
    height: 26px;
    padding: 0 10px 0 4px;
    cursor: pointer;
    background: transparent;
    border-radius: 12px;
    min-width: 0;
    transition: background 0.1s;
  }

  .tab:hover {
    background: var(--tab-hover);
  }

  .tab.active {
    background: var(--tab-active);
    box-shadow: 0 4px 24px rgba(0,0,0,0.4), 0 2px 8px rgba(0,0,0,0.3);
  }

  .tab .close {
    width: 20px;
    height: 20px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: 50%;
    border: none;
    font-size: 12px;
    flex-shrink: 0;
    color: var(--text-dim);
    background: transparent;
    opacity: 0;
    transition: opacity 0.15s, background 0.15s;
    cursor: pointer;
    padding: 0;
  }

  .tab:hover .close {
    opacity: 1;
  }

  .tab .close:hover {
    background: var(--close-hover);
    color: var(--text);
  }

  .tab .title-wrapper {
    flex: 1;
    display: flex;
    align-items: center;
    justify-content: center;
    min-width: 0;
    gap: 4px;
  }

  .tab .indicator {
    font-size: 14px;
    font-weight: 100;
    color: var(--text-dim);
    font-family: ui-monospace, "SF Mono", Menlo, Monaco, "Cascadia Mono", monospace;
    flex-shrink: 0;
    line-height: 1;
  }

  .tab .title {
    font-size: 12px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    color: var(--text);
    min-width: 0;
  }

  #show-all-tabs, #new-tab {
    width: 26px;
    height: 26px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: transparent;
    border: none;
    border-radius: 12px;
    color: var(--accent);
    cursor: pointer;
    font-size: 14px;
    transition: all 0.1s;
    flex-shrink: 0;
    margin-left: 2px;
  }

  #show-all-tabs:hover, #new-tab:hover {
    background: var(--tab-hover);
  }

  @media (hover: none) {
    .tab .close {
      opacity: 1;
    }
  }
</style>
