<script lang="ts">
  import { ui } from '../stores/index';

  interface Props {
    onClose?: () => void;
  }

  let { onClose }: Props = $props();

  // Container ref for the panel
  let containerEl: HTMLElement | undefined = $state();

  // Subscribe to UI state
  let isOpen = $derived($ui.quickTerminalOpen);

  function handleOverlayClick(e: MouseEvent) {
    if (e.target === e.currentTarget) {
      onClose?.();
    }
  }


  // Export container for parent to use
  export function getContainer(): HTMLElement | undefined {
    return containerEl;
  }
</script>

<div class="quick-terminal" class:open={isOpen}>
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <!-- svelte-ignore a11y_click_events_have_key_events -->
  <div class="quick-terminal-overlay" onclick={handleOverlayClick}></div>
  <div class="quick-terminal-panel">
    <div class="quick-terminal-header">
      <span class="quick-terminal-title">Quick Terminal</span>
      <button type="button" class="quick-terminal-close" onclick={() => onClose?.()}>×</button>
    </div>
    <div class="quick-terminal-content" bind:this={containerEl}>
      <!-- Panel will be mounted here by MuxClient -->
    </div>
  </div>
</div>

<style>
  .quick-terminal {
    position: fixed;
    top: 0;
    left: 0;
    right: 0;
    z-index: 900;
    transform: translateY(-100%);
    transition: transform 0.2s ease-out;
    pointer-events: none;
  }

  .quick-terminal.open {
    transform: translateY(0);
    pointer-events: auto;
  }

  .quick-terminal-overlay {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.3);
    opacity: 0;
    transition: opacity 0.2s;
  }

  .quick-terminal.open .quick-terminal-overlay {
    opacity: 1;
  }

  .quick-terminal-panel {
    position: relative;
    background: var(--bg);
    border-bottom: 2px solid var(--accent);
    height: 40vh;
    display: flex;
    flex-direction: column;
    box-shadow: 0 4px 24px rgba(0, 0, 0, 0.5);
  }

  .quick-terminal-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 4px 8px;
    background: var(--toolbar-bg);
    border-bottom: 1px solid rgba(128, 128, 128, 0.2);
  }

  .quick-terminal-title {
    font-size: 11px;
    color: var(--text-dim);
    font-weight: 500;
  }

  .quick-terminal-close {
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
  }

  .quick-terminal-close:hover {
    background: var(--tab-hover);
    color: var(--text);
  }

  .quick-terminal-content {
    flex: 1;
    position: relative;
    overflow: hidden;
  }
</style>
