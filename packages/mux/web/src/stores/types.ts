/**
 * State types for Svelte stores
 */

// Panel lifecycle states
export type PanelStatus =
  | 'disconnected'
  | 'connecting'
  | 'connected'
  | 'streaming'
  | 'paused'
  | 'destroyed'
  | 'error';

export interface PanelInfo {
  id: string;
  serverId: number | null;
  status: PanelStatus;
  title: string;
  pwd: string;
  isQuickTerminal: boolean;
}

export interface TabInfo {
  id: string;
  title: string;
  panelIds: string[];
}

export interface ConnectedClient {
  clientId: number;
  role: number;
  sessionId: string;
}

export interface UIState {
  quickTerminalOpen: boolean;
  quickTerminalPanelId: string | null;
  overviewOpen: boolean;
  inspectorOpen: boolean;
  commandPaletteOpen: boolean;
  isMainClient: boolean;
  clientId: number;
  isAdmin: boolean;
  sessionId: string | null;
  panelAssignments: Map<number, string>;
  connectedClients: ConnectedClient[];
}
