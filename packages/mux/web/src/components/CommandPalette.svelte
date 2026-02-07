<script lang="ts">
  import { getCommands, type Command } from '../dialogs';
  import { tabs, activePanelId } from '../stores/index';

  interface Props {
    open?: boolean;
    onClose?: () => void;
    onExecute?: (action: string) => void;
  }

  let { open = false, onClose, onExecute }: Props = $props();


  // State
  let filter = $state('');
  let selectedIndex = $state(0);
  let inputEl: HTMLInputElement | undefined = $state();
  let listEl: HTMLElement | undefined = $state();

  // Get context for disabled state
  let hasTabs = $derived($tabs.size > 0);
  let hasActivePanel = $derived($activePanelId !== null);

  // Commands
  const allCommands = getCommands();

  // Filtered commands
  let filteredCommands = $derived.by(() => {
    const filterLower = filter.toLowerCase();
    return allCommands.filter(cmd =>
      cmd.title.toLowerCase().includes(filterLower) ||
      cmd.description.toLowerCase().includes(filterLower)
    );
  });

  // Check if command is disabled
  function isDisabled(cmd: Command): boolean {
    if (cmd.requiresPanel && !hasActivePanel) return true;
    if (cmd.requiresTab && !hasTabs) return true;
    return false;
  }

  // Execute selected command
  function executeCommand(index: number): void {
    const cmd = filteredCommands[index];
    if (cmd && !isDisabled(cmd)) {
      onExecute?.(cmd.action);
      handleClose();
    }
  }

  // Handle keyboard navigation
  function handleKeydown(e: KeyboardEvent): void {
    // Stop propagation to prevent App.svelte shortcuts from firing
    e.stopPropagation();

    switch (e.key) {
      case 'ArrowDown':
        e.preventDefault();
        selectNext(1);
        break;
      case 'ArrowUp':
        e.preventDefault();
        selectNext(-1);
        break;
      case 'Enter':
        e.preventDefault();
        executeCommand(selectedIndex);
        break;
      case 'Escape':
        e.preventDefault();
        handleClose();
        break;
    }
  }

  // Select next enabled command
  function selectNext(direction: 1 | -1): void {
    const len = filteredCommands.length;
    if (len === 0) return;

    let index = selectedIndex;
    for (let i = 0; i < len; i++) {
      index = (index + direction + len) % len;
      if (!isDisabled(filteredCommands[index])) {
        selectedIndex = index;
        scrollToSelected();
        return;
      }
    }
  }

  // Scroll selected item into view
  function scrollToSelected(): void {
    if (listEl) {
      const el = listEl.querySelector('.command-item.selected');
      el?.scrollIntoView({ block: 'nearest' });
    }
  }

  // Handle close
  function handleClose(): void {
    filter = '';
    selectedIndex = 0;
    onClose?.();
  }

  // Handle overlay click
  function handleOverlayClick(e: MouseEvent): void {
    if (e.target === e.currentTarget) {
      handleClose();
    }
  }

  // Focus input when opened
  $effect(() => {
    if (open && inputEl) {
      inputEl.focus();
    }
  });

  // Reset selection when filtered commands change
  $effect(() => {
    const commands = filteredCommands;
    selectedIndex = 0;
    // Find first enabled command
    for (let i = 0; i < commands.length; i++) {
      if (!isDisabled(commands[i])) {
        selectedIndex = i;
        break;
      }
    }
  });
</script>

{#if open}
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div class="command-palette-overlay" onclick={handleOverlayClick} onkeydown={handleKeydown}>
    <div class="command-palette">
      <input
        bind:this={inputEl}
        bind:value={filter}
        type="text"
        class="command-input"
        placeholder="Type a command..."
      />
      <div class="command-list" bind:this={listEl}>
        {#each filteredCommands as cmd, i (cmd.action)}
          <button
            type="button"
            class="command-item"
            class:selected={i === selectedIndex}
            class:disabled={isDisabled(cmd)}
            onclick={() => executeCommand(i)}
          >
            <div class="command-title">{cmd.title}</div>
            <div class="command-desc">{cmd.description}</div>
            {#if cmd.shortcut}
              <div class="command-shortcut">{cmd.shortcut}</div>
            {/if}
          </button>
        {/each}
        {#if filteredCommands.length === 0}
          <div class="command-empty">No commands found</div>
        {/if}
      </div>
    </div>
  </div>
{/if}

<style>
  .command-palette-overlay {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.5);
    display: flex;
    align-items: flex-start;
    justify-content: center;
    padding-top: 15vh;
    z-index: 1000;
  }

  .command-palette {
    background: var(--toolbar-bg);
    border: 1px solid rgba(128, 128, 128, 0.3);
    border-radius: 8px;
    width: 500px;
    max-width: 90vw;
    max-height: 60vh;
    display: flex;
    flex-direction: column;
    box-shadow: 0 8px 32px rgba(0, 0, 0, 0.4);
  }

  .command-input {
    padding: 12px 16px;
    border: none;
    border-bottom: 1px solid rgba(128, 128, 128, 0.2);
    background: transparent;
    color: var(--text);
    font-size: 14px;
    outline: none;
  }

  .command-input::placeholder {
    color: var(--text-dim);
  }

  .command-list {
    overflow-y: auto;
    max-height: calc(60vh - 50px);
  }

  .command-item {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    gap: 2px;
    padding: 10px 16px;
    cursor: pointer;
    border: none;
    background: transparent;
    color: var(--text);
    width: 100%;
    text-align: left;
    position: relative;
  }

  .command-item:hover:not(.disabled) {
    background: var(--tab-hover);
  }

  .command-item.selected:not(.disabled) {
    background: var(--tab-active);
  }

  .command-item.disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }

  .command-title {
    font-size: 13px;
    font-weight: 500;
  }

  .command-desc {
    font-size: 11px;
    color: var(--text-dim);
  }

  .command-shortcut {
    position: absolute;
    right: 16px;
    top: 50%;
    transform: translateY(-50%);
    font-size: 11px;
    color: var(--text-dim);
    background: rgba(128, 128, 128, 0.2);
    padding: 2px 6px;
    border-radius: 3px;
    font-family: Inter, "Source Code Pro", Roboto, Verdana, system-ui, sans-serif;
  }


  .command-empty {
    padding: 20px 16px;
    text-align: center;
    color: var(--text-dim);
    font-size: 13px;
  }
</style>
