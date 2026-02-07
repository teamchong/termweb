/**
 * Svelte stores for mux client state management
 */
import { writable, derived, get } from 'svelte/store';
import type { PanelInfo, TabInfo, UIState, PanelStatus } from './types';

// Re-export types
export * from './types';

// ============================================================================
// Panel Store
// ============================================================================

function createPanelStore() {
  const { subscribe, set, update } = writable<Map<string, PanelInfo>>(new Map());

  return {
    subscribe,
    add: (panel: PanelInfo) => update(panels => {
      panels.set(panel.id, panel);
      return new Map(panels);
    }),
    remove: (id: string) => update(panels => {
      panels.delete(id);
      return new Map(panels);
    }),
    updatePanel: (id: string, updates: Partial<PanelInfo>) => update(panels => {
      const panel = panels.get(id);
      if (panel) {
        panels.set(id, { ...panel, ...updates });
      }
      return new Map(panels);
    }),
    setStatus: (id: string, status: PanelStatus) => update(panels => {
      const panel = panels.get(id);
      if (panel) {
        panels.set(id, { ...panel, status });
      }
      return new Map(panels);
    }),
    get: (id: string) => get({ subscribe }).get(id),
    getByServerId: (serverId: number) => {
      for (const panel of get({ subscribe }).values()) {
        if (panel.serverId === serverId) return panel;
      }
      return undefined;
    },
    clear: () => set(new Map()),
  };
}

export const panels = createPanelStore();
export const activePanelId = writable<string | null>(null);
export const activePanel = derived(
  [panels, activePanelId],
  ([$panels, $id]) => $id ? $panels.get($id) : undefined
);

// ============================================================================
// Tab Store
// ============================================================================

function createTabStore() {
  const { subscribe, set, update } = writable<Map<string, TabInfo>>(new Map());
  let nextId = 1;

  return {
    subscribe,
    add: (tab: TabInfo) => update(tabs => {
      tabs.set(tab.id, tab);
      return new Map(tabs);
    }),
    remove: (id: string) => update(tabs => {
      tabs.delete(id);
      return new Map(tabs);
    }),
    updateTab: (id: string, updates: Partial<TabInfo>) => update(tabs => {
      const tab = tabs.get(id);
      if (tab) {
        tabs.set(id, { ...tab, ...updates });
      }
      return new Map(tabs);
    }),
    get: (id: string) => get({ subscribe }).get(id),
    createId: () => String(nextId++),
    clear: () => { set(new Map()); nextId = 1; },
  };
}

export const tabs = createTabStore();
export const activeTabId = writable<string | null>(null);
export const activeTab = derived(
  [tabs, activeTabId],
  ([$tabs, $id]) => $id ? $tabs.get($id) : undefined
);

// ============================================================================
// UI Store
// ============================================================================

export const ui = writable<UIState>({
  quickTerminalOpen: false,
  quickTerminalPanelId: null,
  overviewOpen: false,
  inspectorOpen: false,
  commandPaletteOpen: false,
  isMainClient: false,
  clientId: 0,
});

// Convenience functions for UI state
export function toggleQuickTerminal() {
  ui.update(s => ({ ...s, quickTerminalOpen: !s.quickTerminalOpen }));
}

export function toggleOverview() {
  ui.update(s => ({ ...s, overviewOpen: !s.overviewOpen }));
}

export function toggleInspector() {
  ui.update(s => ({ ...s, inspectorOpen: !s.inspectorOpen }));
}

export function toggleCommandPalette() {
  ui.update(s => ({ ...s, commandPaletteOpen: !s.commandPaletteOpen }));
}

// ============================================================================
// Helpers
// ============================================================================

export function createPanelInfo(
  id: string,
  serverId: number | null = null,
  isQuickTerminal = false
): PanelInfo {
  return {
    id,
    serverId,
    status: 'disconnected',
    title: '',
    pwd: '',
    isQuickTerminal,
  };
}

export function createTabInfo(id: string): TabInfo {
  return {
    id,
    title: '',
    panelIds: [],
  };
}
