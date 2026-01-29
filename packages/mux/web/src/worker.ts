/**
 * Shared Worker for libghostty-vt WASM with sync OPFS access
 *
 * Handles:
 * - Terminal emulation via libghostty-vt WASM
 * - Sync OPFS for scrollback/session storage
 * - Multiple tab connections
 */

declare const self: SharedWorkerGlobalScope;

interface WasmExports {
  memory: WebAssembly.Memory;
  ghostty_wasm_alloc_u8_array: (len: number) => number;
  ghostty_wasm_free_u8_array: (ptr: number, len: number) => void;
  ghostty_key_encoder_new: () => number;
  ghostty_key_encoder_free: (encoder: number) => void;
  ghostty_key_encoder_encode: (encoder: number, event: number, buf: number, len: number) => number;
  ghostty_osc_new: () => number;
  ghostty_osc_free: (parser: number) => void;
  ghostty_osc_next: (parser: number, byte: number) => number;
  ghostty_sgr_new: () => number;
  ghostty_sgr_free: (parser: number) => void;
  ghostty_sgr_next: (parser: number) => number;
}

let wasmInstance: WebAssembly.Instance | null = null;
let wasmExports: WasmExports | null = null;
let opfsRoot: FileSystemDirectoryHandle | null = null;
let connections: Map<number, MessagePort> = new Map();
let connectionId = 0;

// Terminal state per session
interface TerminalSession {
  id: number;
  scrollback: string;
  scrollbackFile: FileSystemSyncAccessHandle | null;
}

const sessions: Map<number, TerminalSession> = new Map();

async function initWasm() {
  try {
    const response = await fetch('./ghostty-vt.wasm');
    const wasmBytes = await response.arrayBuffer();

    const result = await WebAssembly.instantiate(wasmBytes, {
      env: {
        // WASM imports for memory management
      },
    });

    wasmInstance = result.instance;
    wasmExports = wasmInstance.exports as unknown as WasmExports;
    console.log('[Worker] WASM loaded');
  } catch (err) {
    console.error('[Worker] WASM load failed:', err);
  }
}

async function initOPFS() {
  try {
    opfsRoot = await navigator.storage.getDirectory();
    console.log('[Worker] OPFS initialized');
  } catch (err) {
    console.error('[Worker] OPFS init failed:', err);
  }
}

async function getSessionFile(sessionId: number): Promise<FileSystemSyncAccessHandle | null> {
  if (!opfsRoot) return null;

  try {
    const filename = `session_${sessionId}.scrollback`;
    const fileHandle = await opfsRoot.getFileHandle(filename, { create: true });
    // @ts-ignore - createSyncAccessHandle is available in worker context
    return await fileHandle.createSyncAccessHandle();
  } catch (err) {
    console.error('[Worker] Failed to get session file:', err);
    return null;
  }
}

function createSession(sessionId: number): TerminalSession {
  const session: TerminalSession = {
    id: sessionId,
    scrollback: '',
    scrollbackFile: null,
  };

  // Initialize sync file access
  getSessionFile(sessionId).then(handle => {
    session.scrollbackFile = handle;
  });

  sessions.set(sessionId, session);
  return session;
}

function appendScrollback(sessionId: number, data: string) {
  const session = sessions.get(sessionId);
  if (!session) return;

  session.scrollback += data;

  // Write to OPFS synchronously if handle available
  if (session.scrollbackFile) {
    const encoder = new TextEncoder();
    const bytes = encoder.encode(data);
    const currentSize = session.scrollbackFile.getSize();
    session.scrollbackFile.write(bytes, { at: currentSize });
    session.scrollbackFile.flush();
  }
}

function getScrollback(sessionId: number): string {
  const session = sessions.get(sessionId);
  if (!session) return '';

  // Try to read from OPFS if scrollback is empty
  if (!session.scrollback && session.scrollbackFile) {
    const size = session.scrollbackFile.getSize();
    if (size > 0) {
      const buffer = new Uint8Array(size);
      session.scrollbackFile.read(buffer, { at: 0 });
      session.scrollback = new TextDecoder().decode(buffer);
    }
  }

  return session.scrollback;
}

function closeSession(sessionId: number) {
  const session = sessions.get(sessionId);
  if (session?.scrollbackFile) {
    session.scrollbackFile.close();
  }
  sessions.delete(sessionId);
}

// Handle messages from main thread
function handleMessage(port: MessagePort, msg: any) {
  switch (msg.type) {
    case 'init':
      // Initialize session
      createSession(msg.sessionId);
      port.postMessage({ type: 'ready', sessionId: msg.sessionId });
      break;

    case 'data':
      // VT data from server - store and forward to main thread for rendering
      appendScrollback(msg.sessionId, msg.data);
      port.postMessage({ type: 'render', sessionId: msg.sessionId, data: msg.data });
      break;

    case 'getScrollback':
      const scrollback = getScrollback(msg.sessionId);
      port.postMessage({ type: 'scrollback', sessionId: msg.sessionId, data: scrollback });
      break;

    case 'close':
      closeSession(msg.sessionId);
      break;

    case 'clearScrollback':
      const session = sessions.get(msg.sessionId);
      if (session) {
        session.scrollback = '';
        if (session.scrollbackFile) {
          session.scrollbackFile.truncate(0);
        }
      }
      break;
  }
}

// Shared Worker connection handler
self.onconnect = (event: MessageEvent) => {
  const port = event.ports[0];
  const connId = ++connectionId;
  connections.set(connId, port);

  port.onmessage = (e: MessageEvent) => {
    handleMessage(port, e.data);
  };

  port.postMessage({ type: 'connected', connectionId: connId });
  port.start();
};

// Initialize on load
initWasm();
initOPFS();
