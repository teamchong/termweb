/**
 * Main entry point for termweb-mux client
 * Initializes Svelte UI with MuxClient service
 */
import App from './App.svelte';
import { mount } from 'svelte';

// Export stores and services for external use
export {
  panels, activePanelId, activePanel,
  tabs, activeTabId, activeTab,
  ui, toggleQuickTerminal, toggleOverview, toggleInspector, toggleCommandPalette,
  createPanelInfo, createTabInfo,
} from './stores/index';
export type { PanelInfo, PanelStatus, UIState } from './stores/types';
export type { TabInfo as StoreTabInfo } from './stores/types';
export * from './services/mux';
export { SplitContainer, type PanelLike } from './split-container';
export { FileTransferHandler } from './file-transfer';
export * from './protocol';
export * from './types';
export * from './utils';

// Mount Svelte app when DOM is ready
function init(): void {
  const target = document.getElementById('app') || document.body;
  mount(App, { target });
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', init);
} else {
  init();
}
