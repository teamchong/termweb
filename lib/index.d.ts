/**
 * Termweb SDK TypeScript Definitions
 */

export interface OpenOptions {
  /** Show navigation toolbar (default: true) */
  toolbar?: boolean;
  /** Enable keyboard shortcuts (default: true) */
  hotkeys?: boolean;
  /** Enable Ctrl+H hint mode (default: true) */
  hints?: boolean;
  /** Use mobile viewport (default: false) */
  mobile?: boolean;
  /** Page zoom scale (default: 1.0) */
  scale?: number;
  /** Start with fresh profile (default: false) */
  noProfile?: boolean;
}

export interface Channel {
  /** Channel ID to pass to invoke calls */
  id: number;
  /** Register callback for data chunks */
  onData(callback: (data: any) => void): this;
  /** Register callback for stream completion */
  onDone(callback: () => void): this;
  /** Close the channel */
  close(): void;
}

export interface FileInfo {
  /** Base64 encoded content */
  content: string;
  /** File size in bytes */
  size: number;
  /** MIME type */
  type: string;
  /** Last modified timestamp */
  lastModified?: number;
}

export interface DirEntry {
  /** Entry name */
  name: string;
  /** Whether entry is a directory */
  isDirectory: boolean;
}

export interface FileStat {
  /** Whether path is a directory */
  isDirectory: boolean;
  /** File size (if file) */
  size?: number;
}

// ============================================================================
// Core API
// ============================================================================

/**
 * Open a URL in termweb (blocking)
 */
export function open(url: string, options?: OpenOptions): Promise<void>;

/**
 * Open a URL in termweb (non-blocking)
 */
export function openAsync(url: string, options?: OpenOptions): void;

/**
 * Evaluate JavaScript in the active viewer
 */
export function evalJS(script: string): boolean;

/**
 * Close the active viewer
 */
export function close(): boolean;

/**
 * Check if a viewer is currently open
 */
export function isOpen(): boolean;

/**
 * Register callback for when viewer closes
 */
export function onClose(callback: () => void): void;

/**
 * Send a message to the page
 */
export function sendToPage(message: any): boolean;

// ============================================================================
// Tauri-style Invoke API
// ============================================================================

/**
 * Invoke a command in the page and get a return value
 *
 * @example
 * const result = await termweb.invoke('getData', { id: 123 });
 */
export function invoke<T = any>(command: string, args?: Record<string, any>, timeout?: number): Promise<T>;

/**
 * Register a command handler that can be called from the page
 *
 * @example
 * termweb.command('readConfig', async (args) => {
 *   return { theme: 'dark' };
 * });
 */
export function command<T = any, R = any>(name: string, handler: (args: T) => R | Promise<R>): void;

// ============================================================================
// Event System
// ============================================================================

/**
 * Emit an event to the page
 *
 * @example
 * termweb.emit('user-updated', { name: 'John' });
 */
export function emit(event: string, payload?: any): boolean;

/**
 * Listen for events from the page
 *
 * @returns Unsubscribe function
 * @example
 * const unsubscribe = termweb.listen('button-clicked', (payload) => {
 *   console.log(payload);
 * });
 */
export function listen(event: string, callback: (payload: any) => void): () => void;

/**
 * Listen for an event once
 */
export function once(event: string, callback: (payload: any) => void): () => void;

// ============================================================================
// Streaming Channels
// ============================================================================

/**
 * Create a channel for streaming data from the page
 *
 * @example
 * const ch = termweb.channel();
 * ch.onData((chunk) => console.log(chunk));
 * ch.onDone(() => console.log('done'));
 * await termweb.invoke('streamFile', { channelId: ch.id });
 */
export function channel(): Channel;

// ============================================================================
// Window API
// ============================================================================

export const window: {
  /** Set window/viewport size */
  setSize(width: number, height: number): boolean;
  /** Set page title */
  setTitle(title: string): boolean;
  /** Navigate to URL */
  navigate(url: string): boolean;
  /** Go back in history */
  back(): boolean;
  /** Go forward in history */
  forward(): boolean;
  /** Reload page */
  reload(): boolean;
  /** Scroll to position */
  scrollTo(x: number, y: number): boolean;
  /** Get current URL */
  getUrl(): Promise<string>;
  /** Get page title */
  getTitle(): Promise<string>;
};

// ============================================================================
// Filesystem API
// ============================================================================

export const fs: {
  /** Read a file (returns base64 content) */
  readFile(path: string): Promise<FileInfo>;
  /** Write a file (content should be base64 encoded) */
  writeFile(path: string, content: string): Promise<boolean>;
  /** Read directory contents */
  readDir(path: string): Promise<DirEntry[]>;
  /** Get file/directory stats */
  stat(path: string): Promise<FileStat>;
  /** Create a directory */
  mkdir(path: string): Promise<boolean>;
  /** Remove a file or directory */
  remove(path: string, recursive?: boolean): Promise<boolean>;
  /** Check if path exists */
  exists(path: string): Promise<boolean>;
};

// ============================================================================
// Key Bindings
// ============================================================================

/**
 * Register callback for key binding events
 */
export function onKeyBinding(callback: (key: string, action: string) => void): void;

/**
 * Add a key binding dynamically
 */
export function addKeyBinding(key: string, action: string): boolean;

/**
 * Remove a key binding
 */
export function removeKeyBinding(key: string): boolean;

// ============================================================================
// Utility
// ============================================================================

/**
 * Get termweb version
 */
export function version(): string;

/**
 * Check if terminal supports Kitty graphics
 */
export function isSupported(): boolean;

/**
 * Check if native module is available
 */
export function isAvailable(): boolean;

// ============================================================================
// Legacy (deprecated)
// ============================================================================

/**
 * @deprecated Use listen('message', callback) instead
 */
export function onMessage(callback: (message: string) => void): void;
