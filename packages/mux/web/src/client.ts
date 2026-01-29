/**
 * termweb-mux browser client
 * Connects to mux server, handles VT sequences with OPFS persistence
 */

interface MuxMessage {
  type: string;
  sessionId?: number;
  data?: string;
  compressed?: boolean;
  error?: string;
  clientId?: string;
  sessions?: Array<{ id: number; cols: number; rows: number }>;
  code?: number;
}

interface SessionCallbacks {
  onData?: (data: string) => void;
  onExit?: (code: number) => void;
}

export class MuxClient {
  private ws: WebSocket | null = null;
  private url: string;
  private clientId: string | null = null;
  private sessions: Map<number, SessionCallbacks> = new Map();
  private reconnectAttempts = 0;
  private maxReconnectAttempts = 5;
  private opfsRoot: FileSystemDirectoryHandle | null = null;

  onConnect?: () => void;
  onDisconnect?: () => void;
  onError?: (error: string) => void;

  constructor(url: string = 'ws://localhost:7682') {
    this.url = url;
  }

  async connect(): Promise<void> {
    return new Promise((resolve, reject) => {
      try {
        this.ws = new WebSocket(this.url);

        this.ws.onopen = () => {
          this.reconnectAttempts = 0;
          this.initOPFS();
        };

        this.ws.onmessage = (event) => {
          this.handleMessage(JSON.parse(event.data), resolve);
        };

        this.ws.onclose = () => {
          this.onDisconnect?.();
          this.tryReconnect();
        };

        this.ws.onerror = () => {
          reject(new Error('WebSocket connection failed'));
        };
      } catch (e) {
        reject(e);
      }
    });
  }

  private async initOPFS(): Promise<void> {
    try {
      if ('storage' in navigator && 'getDirectory' in navigator.storage) {
        this.opfsRoot = await navigator.storage.getDirectory();
      }
    } catch {
      // OPFS not available
    }
  }

  private handleMessage(msg: MuxMessage, onConnected?: (value: void) => void): void {
    switch (msg.type) {
      case 'connected':
        this.clientId = msg.clientId ?? null;
        this.onConnect?.();
        onConnected?.();
        break;

      case 'data':
        if (msg.sessionId !== undefined) {
          const data = msg.compressed ? this.decompress(msg.data!) : msg.data!;
          const session = this.sessions.get(msg.sessionId);
          session?.onData?.(data);
          this.saveToOPFS(msg.sessionId, data);
        }
        break;

      case 'exit':
        if (msg.sessionId !== undefined) {
          const session = this.sessions.get(msg.sessionId);
          session?.onExit?.(msg.code ?? 0);
          this.sessions.delete(msg.sessionId);
        }
        break;

      case 'error':
        this.onError?.(msg.error ?? 'Unknown error');
        break;

      case 'created':
      case 'attached':
      case 'killed':
      case 'sessions':
      case 'scrollback':
        // Handled by promise resolvers
        break;
    }
  }

  private decompress(base64Data: string): string {
    // Use pako for zlib decompression in browser
    const binary = atob(base64Data);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }

    // @ts-ignore - pako loaded externally
    if (typeof pako !== 'undefined') {
      // @ts-ignore
      return pako.inflate(bytes, { to: 'string' });
    }

    // Fallback: return as-is if pako not available
    return new TextDecoder().decode(bytes);
  }

  private async saveToOPFS(sessionId: number, data: string): Promise<void> {
    if (!this.opfsRoot) return;

    try {
      const filename = `session_${sessionId}_scrollback.txt`;
      const fileHandle = await this.opfsRoot.getFileHandle(filename, { create: true });
      const writable = await fileHandle.createWritable({ keepExistingData: true });
      const file = await fileHandle.getFile();
      await writable.seek(file.size);
      await writable.write(data);
      await writable.close();
    } catch {
      // Ignore OPFS errors
    }
  }

  async loadFromOPFS(sessionId: number): Promise<string | null> {
    if (!this.opfsRoot) return null;

    try {
      const filename = `session_${sessionId}_scrollback.txt`;
      const fileHandle = await this.opfsRoot.getFileHandle(filename);
      const file = await fileHandle.getFile();
      return await file.text();
    } catch {
      return null;
    }
  }

  async clearOPFS(sessionId: number): Promise<void> {
    if (!this.opfsRoot) return;

    try {
      const filename = `session_${sessionId}_scrollback.txt`;
      await this.opfsRoot.removeEntry(filename);
    } catch {
      // Ignore
    }
  }

  private tryReconnect(): void {
    if (this.reconnectAttempts < this.maxReconnectAttempts) {
      this.reconnectAttempts++;
      setTimeout(() => this.connect(), 1000 * this.reconnectAttempts);
    }
  }

  private send(msg: object): void {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(msg));
    }
  }

  createSession(
    callbacks: SessionCallbacks,
    options: { cols?: number; rows?: number; shell?: string } = {}
  ): Promise<number> {
    return new Promise((resolve) => {
      const handler = (event: MessageEvent) => {
        const msg = JSON.parse(event.data);
        if (msg.type === 'created') {
          this.sessions.set(msg.sessionId, callbacks);
          this.ws?.removeEventListener('message', handler);
          resolve(msg.sessionId);
        }
      };
      this.ws?.addEventListener('message', handler);

      this.send({
        type: 'create',
        cols: options.cols ?? 80,
        rows: options.rows ?? 24,
        shell: options.shell,
      });
    });
  }

  attachSession(sessionId: number, callbacks: SessionCallbacks): Promise<void> {
    return new Promise((resolve) => {
      const handler = (event: MessageEvent) => {
        const msg = JSON.parse(event.data);
        if (msg.type === 'attached' && msg.sessionId === sessionId) {
          this.sessions.set(sessionId, callbacks);
          this.ws?.removeEventListener('message', handler);
          resolve();
        }
      };
      this.ws?.addEventListener('message', handler);

      this.send({ type: 'attach', sessionId });
    });
  }

  write(sessionId: number, data: string): void {
    this.send({ type: 'input', sessionId, data });
  }

  resize(sessionId: number, cols: number, rows: number): void {
    this.send({ type: 'resize', sessionId, cols, rows });
  }

  kill(sessionId: number): void {
    this.send({ type: 'kill', sessionId });
    this.sessions.delete(sessionId);
  }

  listSessions(): Promise<Array<{ id: number; cols: number; rows: number }>> {
    return new Promise((resolve) => {
      const handler = (event: MessageEvent) => {
        const msg = JSON.parse(event.data);
        if (msg.type === 'sessions') {
          this.ws?.removeEventListener('message', handler);
          resolve(msg.sessions);
        }
      };
      this.ws?.addEventListener('message', handler);

      this.send({ type: 'list' });
    });
  }

  disconnect(): void {
    this.ws?.close();
    this.ws = null;
    this.sessions.clear();
  }
}

// Export for UMD/browser global
if (typeof window !== 'undefined') {
  (window as any).MuxClient = MuxClient;
}
