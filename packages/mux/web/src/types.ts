// Type definitions for the termweb-mux client

export interface PanelOptions {
  id: string;
  container: HTMLElement;
  serverId?: number | null;
  onResize?: (width: number, height: number) => void;
  onViewAction?: (action: string, data?: unknown) => void;
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
  canvas: HTMLCanvasElement;
  ws: WebSocket | null;
  width: number;
  height: number;
  pwd: string | null;

  connect(host: string, port: number): void;
  disconnect(): void;
  resize(): void;
  focus(): void;
  sendKeyInput(keyCode: number, action: number, mods: number, text?: string): void;
  sendMouseInput(x: number, y: number, button: number, action: number, mods: number): void;
  sendTextInput(text: string): void;
  requestKeyframe(): void;
}

export interface TabInfo {
  id: string;
  title: string;
  root: SplitContainerInstance;
  element: HTMLElement;
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

export interface TransferState {
  id: number;
  direction: 'upload' | 'download';
  serverPath: string;
  files: TransferFile[];
  currentFileIndex: number;
  currentChunkOffset: number;
  state: 'pending' | 'active' | 'paused' | 'complete' | 'error';
  options: TransferOptions;
}

export interface TransferFile {
  path: string;
  size: number;
  mtime: number;
  hash: bigint;
}

export interface TransferOptions {
  deleteExtra?: boolean;
  dryRun?: boolean;
  excludes?: string[];
}

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
  editorToken: string;
  viewerToken: string;
}

export interface ShareLink {
  token: string;
  type: number;
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
  panelWsPort: number;
  controlWsPort: number;
  fileWsPort: number;
  colors?: Record<string, string>;
}
