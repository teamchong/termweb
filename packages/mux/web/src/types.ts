// Type definitions for the termweb-mux client

// File System Access API type declarations
export interface FileSystemDirectoryHandleIterator {
  entries(): AsyncIterableIterator<[string, FileSystemFileHandle | FileSystemDirectoryHandle]>;
}

declare global {
  interface Window {
    showDirectoryPicker(options?: { mode?: 'read' | 'readwrite' }): Promise<FileSystemDirectoryHandle>;
  }
}

export interface PanelOptions {
  id: string;
  container: HTMLElement;
  serverId?: number | null;
  onResize?: (width: number, height: number) => void;
}

export interface SplitContainerOptions {
  direction: 'horizontal' | 'vertical';
  element: HTMLElement;
  onPanelFocus?: (panel: PanelInstance) => void;
  onPanelClose?: (panel: PanelInstance) => void;
}

export interface PanelInstance {
  id: string;
  serverId: number | null;
  container: HTMLElement;
  video: HTMLVideoElement;
  canvas: HTMLVideoElement; // Alias for backwards compatibility
  ws: WebSocket | null;
  width: number;
  height: number;
  pwd: string;

  connect(host: string, port: number): void;
  destroy(): void;
  focus(): void;
  show(): void;
  hide(): void;
  sendKeyInput(e: KeyboardEvent, action: number): void;
  sendTextInput(text: string): void;
  toggleInspector(visible?: boolean): void;
  handleInspectorState(state: unknown): void;
}

export interface SplitContainerInstance {
  direction: 'horizontal' | 'vertical';
  element: HTMLElement;
  children: (PanelInstance | SplitContainerInstance)[];

  split(direction: 'horizontal' | 'vertical', panel: PanelInstance): PanelInstance;
  removePanel(panel: PanelInstance): void;
  getActivePanel(): PanelInstance | null;
  getAllPanels(): PanelInstance[];
}

// Re-export transfer types from file-transfer for backwards compatibility
export type { TransferFile, TransferOptions, TransferState } from './file-transfer';

export interface AuthState {
  authRequired: boolean;
  hasPassword: boolean;
  passkeyCount: number;
  role: number;
}

export interface Session {
  id: string;
  name: string;
  createdAt: number;
  token: string;  // Hex-encoded 256-bit permanent token
  role: number;   // Server-side role (0=admin, 1=editor, 2=viewer)
}

export interface ShareLink {
  token: string;  // Hex-encoded 256-bit token
  role: number;   // 0=admin, 1=editor, 2=viewer
  createdAt: number;
  expiresAt: number | null;
  useCount: number;
  maxUses: number | null;
  label: string | null;
}

// Command palette action
export interface CommandAction {
  id: string;
  label: string;
  shortcut?: string;
  action: () => void;
  category?: string;
}

// App configuration from server
export interface AppConfig {
  wsPath?: boolean; // True if using path-based WebSocket on same port
  colors?: Record<string, string>;
}

// Layout data for restoration
export interface LayoutNode {
  type: 'leaf' | 'split';
  panelId?: number;
  direction?: 'horizontal' | 'vertical';
  ratio?: number;
  first?: LayoutNode;
  second?: LayoutNode;
}

export interface LayoutTab {
  id: number;
  root: LayoutNode;
}

export interface LayoutData {
  tabs: LayoutTab[];
  // activePanelId removed — active panel is per-session, managed client-side
}
