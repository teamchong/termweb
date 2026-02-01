/**
 * Panel - Terminal panel with H.264 video via MSE + jMuxer
 */

import JMuxer from 'jmuxer';
import { ClientMsg } from './protocol';

export interface PanelCallbacks {
  onResize?: (panelId: number, width: number, height: number) => void;
  onViewAction?: (action: string, data?: unknown) => void;
}

export class Panel {
  readonly id: string;
  serverId: number | null;
  container: HTMLElement;
  readonly video: HTMLVideoElement;
  readonly element: HTMLElement;
  pwd: string = ''; // Current working directory

  private ws: WebSocket | null = null;
  private callbacks: PanelCallbacks;
  private destroyed = false;
  private paused = false;

  // jMuxer for H.264 → fMP4 → MSE
  private jmuxer: JMuxer | null = null;

  private lastReportedWidth = 0;
  private lastReportedHeight = 0;
  private resizeTimeout: ReturnType<typeof setTimeout> | null = null;
  resizeObserver: ResizeObserver | null = null;

  // Adaptive bitrate - buffer monitoring
  private bufferMonitorInterval: ReturnType<typeof setInterval> | null = null;
  private lastBufferReport = 0;
  private frameTimestamps: number[] = []; // For FPS calculation

  // Inspector elements
  private inspectorVisible = false;

  // Alias for backwards compatibility - returns video element for getBoundingClientRect
  get canvas(): HTMLVideoElement {
    return this.video;
  }

  constructor(
    id: string,
    container: HTMLElement,
    serverId: number | null,
    callbacks: PanelCallbacks = {}
  ) {
    this.id = id;
    this.serverId = serverId;
    this.container = container;
    this.callbacks = callbacks;

    // Create panel element
    this.element = document.createElement('div');
    this.element.className = 'panel';
    this.element.innerHTML = `
      <div class="panel-content">
        <video class="panel-video" autoplay muted playsinline></video>
      </div>
      <div class="panel-inspector" style="display: none;">
        <div class="inspector-header">
          <span class="inspector-title">Inspector</span>
          <button class="inspector-close">&times;</button>
        </div>
        <div class="inspector-tabs"></div>
        <div class="inspector-content"></div>
        <div class="inspector-resize"></div>
      </div>
    `;
    container.appendChild(this.element);

    this.video = this.element.querySelector('.panel-video') as HTMLVideoElement;

    // Setup event handlers
    this.setupEventHandlers();
    this.setupResizeObserver();
    this.initJMuxer();
  }

  private initJMuxer(): void {
    this.jmuxer = new JMuxer({
      node: this.video,
      mode: 'video',
      flushingTime: 0, // Immediate flush for low latency
      fps: 30,
      debug: false,
      onReady: () => {
        console.log('jMuxer ready');
        this.startBufferMonitor();
      },
      onError: (e: Error) => {
        console.error('jMuxer error:', e);
      },
    });
  }

  private startBufferMonitor(): void {
    // Monitor buffer health every 500ms
    this.bufferMonitorInterval = setInterval(() => {
      this.checkBufferHealth();
    }, 500);
  }

  private checkBufferHealth(): void {
    if (!this.video || !this.ws || this.ws.readyState !== WebSocket.OPEN) return;

    const now = performance.now();

    // Calculate buffer length (how much video is buffered ahead)
    let bufferLength = 0;
    if (this.video.buffered.length > 0) {
      const currentTime = this.video.currentTime;
      for (let i = 0; i < this.video.buffered.length; i++) {
        if (this.video.buffered.start(i) <= currentTime && this.video.buffered.end(i) > currentTime) {
          bufferLength = this.video.buffered.end(i) - currentTime;
          break;
        }
      }
    }

    // Calculate received FPS from frame timestamps
    const oneSecondAgo = now - 1000;
    this.frameTimestamps = this.frameTimestamps.filter(t => t > oneSecondAgo);
    const receivedFps = this.frameTimestamps.length;

    // Buffer health: 0-100 (0 = starving, 100 = too much buffered)
    // Target: ~100ms buffer (3 frames at 30fps)
    // < 50ms = starving (need lower bitrate/fps)
    // > 300ms = too much buffer (can increase quality)
    const targetBuffer = 0.1; // 100ms
    const bufferHealth = Math.min(100, Math.max(0, (bufferLength / targetBuffer) * 50));

    // Only report if enough time has passed or significant change
    if (now - this.lastBufferReport > 1000) {
      this.sendBufferStats(bufferHealth, receivedFps, bufferLength);
      this.lastBufferReport = now;
    }
  }

  private sendBufferStats(health: number, fps: number, bufferMs: number): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;

    // Format: [msg_type:u8][health:u8][fps:u8][buffer_ms:u16]
    const buf = new ArrayBuffer(5);
    const view = new DataView(buf);
    view.setUint8(0, ClientMsg.BUFFER_STATS);
    view.setUint8(1, Math.round(health));
    view.setUint8(2, Math.round(fps));
    view.setUint16(3, Math.round(bufferMs * 1000), true); // Convert to ms
    this.ws.send(buf);
  }

  private setupEventHandlers(): void {
    // Keyboard is handled at document level in App class, not here
    // This avoids double input issues

    // Mouse events
    this.video.addEventListener('mousedown', (e) => this.handleMouseDown(e));
    this.video.addEventListener('mouseup', (e) => this.handleMouseUp(e));
    this.video.addEventListener('mousemove', (e) => this.handleMouseMove(e));
    this.video.addEventListener('wheel', (e) => this.handleWheel(e), { passive: false });
    this.video.addEventListener('contextmenu', (e) => e.preventDefault());

    // Focus handling - video needs tabIndex for focus
    this.video.tabIndex = 1;

    // Inspector close button
    const closeBtn = this.element.querySelector('.inspector-close');
    if (closeBtn) {
      closeBtn.addEventListener('click', () => this.toggleInspector(false));
    }
  }

  private setupResizeObserver(): void {
    this.resizeObserver = new ResizeObserver(() => {
      if (this.resizeTimeout) clearTimeout(this.resizeTimeout);
      this.resizeTimeout = setTimeout(() => {
        const rect = this.container.getBoundingClientRect();
        const width = Math.floor(rect.width);
        const height = Math.floor(rect.height);

        if (width === 0 || height === 0) return;
        if (width === this.lastReportedWidth && height === this.lastReportedHeight) return;

        this.lastReportedWidth = width;
        this.lastReportedHeight = height;

        if (this.serverId !== null && this.callbacks.onResize) {
          this.callbacks.onResize(this.serverId, width, height);
        }
      }, 16);
    });
    this.resizeObserver.observe(this.element);
  }

  // WebSocket connection
  connect(host: string, port: number): void {
    if (this.ws) {
      this.ws.close();
    }

    const wsUrl = `ws://${host}:${port}`;
    this.ws = new WebSocket(wsUrl);
    this.ws.binaryType = 'arraybuffer';

    this.ws.onopen = () => {
      // If we have a serverId, reconnect to existing panel; otherwise create new
      if (this.serverId !== null) {
        this.sendConnectPanel(this.serverId);
      } else {
        this.sendCreatePanel();
      }
    };

    this.ws.onmessage = (event) => {
      if (event.data instanceof ArrayBuffer) {
        this.handleFrame(event.data);
      }
    };

    this.ws.onclose = () => {
      this.ws = null;
    };

    this.ws.onerror = (e) => {
      console.error('WebSocket error:', e);
    };
  }

  private sendConnectPanel(panelId: number): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;

    const buf = new ArrayBuffer(5);
    const view = new DataView(buf);
    view.setUint8(0, ClientMsg.CONNECT_PANEL);
    view.setUint32(1, panelId, true);
    this.ws.send(buf);
  }

  private sendCreatePanel(): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;

    const rect = this.container.getBoundingClientRect();
    const width = Math.floor(rect.width) || 800;
    const height = Math.floor(rect.height) || 600;
    const scale = window.devicePixelRatio || 1;

    this.lastReportedWidth = width;
    this.lastReportedHeight = height;

    const buf = new ArrayBuffer(9);
    const view = new DataView(buf);
    view.setUint8(0, ClientMsg.CREATE_PANEL);
    view.setUint16(1, width, true);
    view.setUint16(3, height, true);
    view.setFloat32(5, scale, true);
    this.ws.send(buf);
  }

  // Frame handling - receives raw H.264 NAL units with Annex B start codes
  private handleFrame(data: ArrayBuffer): void {
    if (this.destroyed || !this.jmuxer) return;

    // Track frame timestamp for FPS calculation
    this.frameTimestamps.push(performance.now());

    const nalData = new Uint8Array(data);

    // Feed H.264 NAL units to jMuxer
    // jMuxer handles Annex B format (00 00 00 01 start codes)
    this.jmuxer.feed({
      video: nalData,
    });
  }

  // Input handling - called from App class at document level
  sendKeyInput(e: KeyboardEvent, action: number): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;

    // Send raw key code and key text to server
    // Format: [msg_type:u8][action:u8][mods:u8][code_len:u8][code:...][text_len:u8][text:...]
    const encoder = new TextEncoder();
    const codeBytes = encoder.encode(e.code);
    const text = (e.key.length === 1) ? e.key : '';
    const textBytes = encoder.encode(text);

    // 5 bytes header: msg_type + action + mods + code_len + text_len
    const buf = new ArrayBuffer(5 + codeBytes.length + textBytes.length);
    const view = new Uint8Array(buf);
    view[0] = ClientMsg.KEY_INPUT;
    view[1] = action;
    view[2] = this.getModifiers(e);
    view[3] = codeBytes.length;
    view.set(codeBytes, 4);
    view[4 + codeBytes.length] = textBytes.length;
    view.set(textBytes, 5 + codeBytes.length);
    this.ws.send(buf);
  }

  private handleMouseDown(e: MouseEvent): void {
    this.element.focus();
    this.sendMouseButton(e, true);
  }

  private handleMouseUp(e: MouseEvent): void {
    this.sendMouseButton(e, false);
  }

  private handleMouseMove(e: MouseEvent): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;

    const rect = this.video.getBoundingClientRect();
    const x = (e.clientX - rect.left) * (window.devicePixelRatio || 1);
    const y = (e.clientY - rect.top) * (window.devicePixelRatio || 1);
    const mods = this.getModifiers(e);

    const buf = new ArrayBuffer(10);
    const view = new DataView(buf);
    view.setUint8(0, ClientMsg.MOUSE_MOVE);
    view.setFloat32(1, x, true);
    view.setFloat32(5, y, true);
    view.setUint8(9, mods);
    this.ws.send(buf);
  }

  private sendMouseButton(e: MouseEvent, pressed: boolean): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;

    const rect = this.video.getBoundingClientRect();
    const x = (e.clientX - rect.left) * (window.devicePixelRatio || 1);
    const y = (e.clientY - rect.top) * (window.devicePixelRatio || 1);
    const mods = this.getModifiers(e);

    const buf = new ArrayBuffer(12);
    const view = new DataView(buf);
    view.setUint8(0, ClientMsg.MOUSE_INPUT);
    view.setFloat32(1, x, true);
    view.setFloat32(5, y, true);
    view.setUint8(9, e.button);
    view.setUint8(10, pressed ? 1 : 0);
    view.setUint8(11, mods);
    this.ws.send(buf);
  }

  private handleWheel(e: WheelEvent): void {
    e.preventDefault();
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;

    const rect = this.video.getBoundingClientRect();
    const x = (e.clientX - rect.left) * (window.devicePixelRatio || 1);
    const y = (e.clientY - rect.top) * (window.devicePixelRatio || 1);

    // Normalize scroll delta
    let dx = e.deltaX;
    let dy = e.deltaY;
    if (e.deltaMode === 1) {
      dx *= 20;
      dy *= 20;
    } else if (e.deltaMode === 2) {
      dx *= this.video.clientWidth;
      dy *= this.video.clientHeight;
    }

    const buf = new ArrayBuffer(18);
    const view = new DataView(buf);
    view.setUint8(0, ClientMsg.MOUSE_SCROLL);
    view.setFloat32(1, x, true);
    view.setFloat32(5, y, true);
    view.setFloat32(9, dx, true);
    view.setFloat32(13, dy, true);
    view.setUint8(17, this.getModifiers(e));
    this.ws.send(buf);
  }

  private getModifiers(e: KeyboardEvent | MouseEvent): number {
    let mods = 0;
    if (e.shiftKey) mods |= 1;
    if (e.ctrlKey) mods |= 2;
    if (e.altKey) mods |= 4;
    if (e.metaKey) mods |= 8;
    return mods;
  }

  // Public API
  setServerId(id: number): void {
    this.serverId = id;
  }

  focus(): void {
    this.element.focus();
  }

  reparent(newContainer: HTMLElement): void {
    if (this.element.parentElement) {
      this.element.parentElement.removeChild(this.element);
    }
    newContainer.appendChild(this.element);
    this.container = newContainer;
  }

  toggleInspector(visible?: boolean): void {
    this.inspectorVisible = visible ?? !this.inspectorVisible;
    const inspector = this.element.querySelector('.panel-inspector') as HTMLElement;
    if (inspector) {
      inspector.style.display = this.inspectorVisible ? 'flex' : 'none';
    }
  }

  // Pause streaming (when tab is not visible)
  hide(): void {
    if (this.paused) return;
    this.paused = true;

    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      const buf = new ArrayBuffer(1);
      new DataView(buf).setUint8(0, ClientMsg.PAUSE_STREAM);
      this.ws.send(buf);
    }
  }

  // Resume streaming (when tab becomes visible)
  show(): void {
    if (!this.paused) return;
    this.paused = false;

    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      const buf = new ArrayBuffer(1);
      new DataView(buf).setUint8(0, ClientMsg.RESUME_STREAM);
      this.ws.send(buf);
    }
  }

  // Handle inspector state from server
  handleInspectorState(state: unknown): void {
    // Update inspector content if visible
    if (!this.inspectorVisible) return;

    const content = this.element.querySelector('.inspector-content');
    if (content && state) {
      content.textContent = JSON.stringify(state, null, 2);
    }
  }

  // Send text input (for paste operations)
  sendTextInput(text: string): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;

    // Format: [msg_type:u8][text:...]
    const encoder = new TextEncoder();
    const textBytes = encoder.encode(text);
    const buf = new ArrayBuffer(1 + textBytes.length);
    const view = new Uint8Array(buf);
    view[0] = ClientMsg.TEXT_INPUT;
    view.set(textBytes, 1);
    this.ws.send(buf);
  }

  destroy(): void {
    this.destroyed = true;

    if (this.bufferMonitorInterval) {
      clearInterval(this.bufferMonitorInterval);
      this.bufferMonitorInterval = null;
    }

    if (this.resizeTimeout) {
      clearTimeout(this.resizeTimeout);
      this.resizeTimeout = null;
    }

    if (this.resizeObserver) {
      this.resizeObserver.disconnect();
      this.resizeObserver = null;
    }

    if (this.ws) {
      this.ws.close();
      this.ws = null;
    }

    if (this.jmuxer) {
      this.jmuxer.destroy();
      this.jmuxer = null;
    }

    if (this.element.parentElement) {
      this.element.parentElement.removeChild(this.element);
    }
  }
}
