<script lang="ts">
  export type MenuItem = {
    separator: true;
  } | {
    separator?: false;
    label: string;
    action?: string;
    shortcut?: string;
    disabled?: boolean;
    icon?: string;
    submenu?: MenuItem[];
  };

  interface Props {
    label: string;
    items: MenuItem[];
    onAction?: (action: string) => void;
  }

  let { label, items, onAction }: Props = $props();


  let open = $state(false);
  let openSubmenu = $state<string | null>(null);

  function handleItemClick(e: MouseEvent, item: MenuItem) {
    e.stopPropagation();
    if ('submenu' in item && item.submenu) {
      // Toggle submenu on touch devices
      if (!window.matchMedia('(hover: hover)').matches) {
        openSubmenu = openSubmenu === item.label ? null : item.label;
      }
      return;
    }
    if ('action' in item && item.action && !item.disabled) {
      onAction?.(item.action);
    }
    // Always close menu after clicking an item
    open = false;
    openSubmenu = null;
  }

  function handleTouchClick(e: MouseEvent) {
    e.stopPropagation();
    // Touch devices use click to toggle
    if (!window.matchMedia('(hover: hover)').matches) {
      open = !open;
      openSubmenu = null;
    }
  }

  function handleClickOutside(e: MouseEvent) {
    const target = e.target as HTMLElement;
    if (!target.closest('.menu')) {
      open = false;
      openSubmenu = null;
    }
  }

  $effect(() => {
    if (open) {
      document.addEventListener('click', handleClickOutside);
      return () => document.removeEventListener('click', handleClickOutside);
    }
  });
</script>

<div class="menu" class:open>
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <!-- svelte-ignore a11y_click_events_have_key_events -->
  <span class="menu-label" onclick={(e) => handleTouchClick(e)}>{label}</span>
  <div class="menu-dropdown">
    {#each items as item}
      {#if item.separator}
        <div class="menu-separator"></div>
      {:else if 'submenu' in item && item.submenu}
        <!-- svelte-ignore a11y_click_events_have_key_events -->
        <!-- svelte-ignore a11y_no_static_element_interactions -->
        <div
          class="menu-item menu-submenu"
          class:disabled={item.disabled}
          class:open={openSubmenu === item.label}
          onclick={(e) => handleItemClick(e, item)}
        >
          {#if item.icon}
            <span class="menu-icon">{item.icon}</span>
          {/if}
          <span class="menu-text">{item.label}</span>
          <div class="submenu-dropdown">
            {#each item.submenu as subitem}
              {#if subitem.separator}
                <div class="menu-separator"></div>
              {:else}
                <!-- svelte-ignore a11y_click_events_have_key_events -->
                <!-- svelte-ignore a11y_no_static_element_interactions -->
                <div
                  class="menu-item"
                  class:disabled={subitem.disabled}
                  onclick={(e) => handleItemClick(e, subitem)}
                >
                  {#if subitem.icon}
                    <span class="menu-icon">{subitem.icon}</span>
                  {/if}
                  <span class="menu-text">{subitem.label}</span>
                  {#if subitem.shortcut}
                    <span class="shortcut">{subitem.shortcut}</span>
                  {/if}
                </div>
              {/if}
            {/each}
          </div>
        </div>
      {:else}
        <!-- svelte-ignore a11y_click_events_have_key_events -->
        <!-- svelte-ignore a11y_no_static_element_interactions -->
        <div
          class="menu-item"
          class:disabled={item.disabled}
          onclick={(e) => handleItemClick(e, item)}
        >
          {#if item.icon}
            <span class="menu-icon">{item.icon}</span>
          {/if}
          <span class="menu-text">{item.label}</span>
          {#if item.shortcut}
            <span class="shortcut">{item.shortcut}</span>
          {/if}
        </div>
      {/if}
    {/each}
  </div>
</div>

<style>
  .menu {
    position: relative;
  }

  .menu-label {
    padding: 4px 10px;
    font-size: 12px;
    color: var(--text);
    cursor: pointer;
    border-radius: 4px;
    transition: background 0.1s;
  }

  .menu-label:hover {
    background: var(--tab-hover);
  }

  .menu-dropdown {
    display: none;
    position: absolute;
    top: 100%;
    right: 0;
    background: var(--toolbar-bg);
    border: 1px solid rgba(128, 128, 128, 0.3);
    border-radius: 6px;
    padding: 4px 0;
    min-width: 160px;
    box-shadow: 0 4px 12px rgba(0, 0, 0, 0.3);
    z-index: 100;
  }

  /* Desktop: hover to show */
  @media (hover: hover) {
    .menu:hover > .menu-dropdown {
      display: block;
    }
  }

  /* Touch: click to show */
  @media (hover: none) {
    .menu:hover > .menu-dropdown {
      display: none;
    }
  }

  .menu.open > .menu-dropdown {
    display: block;
  }

  .menu-item {
    display: flex;
    align-items: center;
    padding: 6px 12px;
    font-size: 12px;
    color: var(--text);
    cursor: pointer;
    transition: background 0.1s;
    gap: 8px;
    white-space: nowrap;
    position: relative;
  }

  .menu-icon {
    width: 18px;
    text-align: center;
    flex-shrink: 0;
    font-size: 11px;
  }

  .menu-text {
    flex: 1;
  }

  .menu-item:hover:not(.disabled) {
    background: var(--tab-hover);
  }

  .menu-item.disabled {
    opacity: 0.4;
    cursor: default;
    pointer-events: none;
  }

  .shortcut {
    color: var(--text-dim);
    font-size: 11px;
    margin-left: 16px;
    font-family: Inter, "Source Code Pro", Roboto, Verdana, system-ui, sans-serif;
  }

  .menu-separator {
    height: 1px;
    background: rgba(128, 128, 128, 0.3);
    margin: 4px 0;
  }

  /* Submenu styles */
  .menu-submenu {
    position: relative;
  }

  .menu-submenu > .menu-text::after {
    content: '◀';
    position: absolute;
    left: 8px;
    font-size: 10px;
    opacity: 0.6;
  }

  .submenu-dropdown {
    display: none;
    position: absolute;
    right: calc(100% - 8px);
    left: auto;
    top: -4px;
    background: var(--toolbar-bg);
    border: 1px solid rgba(128, 128, 128, 0.3);
    border-radius: 6px;
    padding: 4px 0;
    min-width: 160px;
    box-shadow: 0 4px 12px rgba(0, 0, 0, 0.3);
    z-index: 101;
    padding-right: 8px;
  }

  /* Desktop: hover to show submenu */
  @media (hover: hover) {
    .menu-submenu:hover > .submenu-dropdown {
      display: block;
    }
  }

  /* Touch: tap to show submenu */
  .menu-submenu.open > .submenu-dropdown {
    display: block;
  }

  /* Mobile styles */
  @media (hover: none) {
    .menu-label {
      display: block;
      width: 100%;
      font-size: 18px;
      font-weight: 600;
      padding: 16px 20px;
      border-radius: 8px;
    }

    .menu-dropdown {
      position: static;
      box-shadow: none;
      border: none;
      padding: 4px 0 8px 0;
      width: 100%;
    }

    .menu-item {
      font-size: 18px;
      padding: 20px 28px;
      width: 100%;
      border-radius: 8px;
      min-height: 56px;
      align-items: center;
    }

    .shortcut {
      font-size: 14px;
      padding-left: 12px;
      letter-spacing: 1px;
      font-family: Inter, "Source Code Pro", Roboto, Verdana, system-ui, sans-serif;
    }

    .menu-icon {
      width: 24px;
      font-size: 16px;
    }

    .menu-submenu > .menu-text::after {
      content: '▼';
      position: static;
      margin-left: 8px;
    }

    .submenu-dropdown {
      position: static;
      right: auto;
      top: auto;
      box-shadow: none;
      border: none;
      padding: 4px 0 8px 16px;
      width: 100%;
    }
  }
</style>
