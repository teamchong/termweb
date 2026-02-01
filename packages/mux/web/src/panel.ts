/**
 * Panel - Terminal panel with H.264 video via WebCodecs
 * Lower latency than jMuxer/MSE by decoding directly to canvas
 */

import { ClientMsg, BinaryCtrlMsg } from './protocol';

export interface PanelCallbacks {
  onResize?: (panelId: number, width: number, height: number) => void;
  onViewAction?: (action: string, data?: unknown) => void;
}

export class Panel {
  readonly id: string;
  serverId: number | null;
  container: HTMLElement;
  readonly canvas: HTMLCanvasElement;
  readonly element: HTMLElement;
  pwd: string = '';

  private ws: WebSocket | null = null;
  private callbacks: PanelCallbacks;
  private destroyed = false;
  private paused = false;

  // WebCodecs decoder
  private decoder: VideoDecoder | null = null;
  private decoderConfigured = false;
  private gotFirstKeyframe = false; // Must receive keyframe before decoding
  private frameCount = 0;
  private ctx: CanvasRenderingContext2D | null = null;

  private lastReportedWidth = 0;
  private lastReportedHeight = 0;
  private resizeTimeout: ReturnType<typeof setTimeout> | null = null;
  resizeObserver: ResizeObserver | null = null;

  // Adaptive bitrate - buffer monitoring
  private lastBufferReport = 0;
  private frameTimestamps: number[] = [];
  private pendingDecode = 0; // Frames waiting to be decoded

  // Debug stats overlay (enable with #debug=1 or ?debug=1 in URL)
  private static debugEnabled = window.location.hash.includes('debug') ||
    window.location.search.includes('debug');
  private statsOverlay: HTMLElement | null = null;
  private renderedFrames = 0;
  private lastStatsUpdate = 0;
  private displayedFps = 0;
  private decodeLatencies: number[] = [];
  private lastDecodeStart = 0;

  // Inspector state
  private inspectorVisible = false;
  private inspectorHeight = 200;
  private inspectorActiveTab = 'screen';
  private inspectorState: Record<string, number> | null = null;
  private inspectorEl: HTMLElement | null = null;

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

    // Create panel element with canvas
    this.element = document.createElement('div');
    this.element.className = 'panel';
    this.element.innerHTML = `
      <div class="panel-content">
        <canvas class="panel-canvas"></canvas>
      </div>
    `;
    container.appendChild(this.element);

    this.canvas = this.element.querySelector('.panel-canvas') as HTMLCanvasElement;
    this.ctx = this.canvas.getContext('2d');

    this.createInspectorElement();
    this.setupEventHandlers();
    this.setupResizeObserver();
    this.initDecoder();
    this.setupStatsOverlay();
    this.showLoading();
  }

  private createInspectorElement(): void {
    this.inspectorEl = document.createElement('div');
    this.inspectorEl.className = 'panel-inspector';
    this.inspectorEl.innerHTML = `
      <div class="inspector-resize"></div>
      <div class="inspector-content">
        <div class="inspector-left">
          <div class="inspector-left-header">
            <div class="inspector-dock-wrapper">
              <span class="inspector-dock-icon"></span>
              <div class="inspector-dock-menu">
                <div class="inspector-dock-menu-item" data-action="hide-header">Hide Tab Bar</div>
              </div>
            </div>
            <div class="inspector-tabs">
              <button class="inspector-tab active" data-tab="screen">Screen</button>
            </div>
          </div>
          <div class="inspector-collapsed-toggle" data-panel="left"></div>
          <div class="inspector-main"></div>
        </div>
        <div class="inspector-right">
          <div class="inspector-right-header">
            <div class="inspector-dock-wrapper">
              <span class="inspector-dock-icon"></span>
              <div class="inspector-dock-menu">
                <div class="inspector-dock-menu-item" data-action="hide-header">Hide Tab Bar</div>
              </div>
            </div>
            <span class="inspector-right-title">Surface Info</span>
          </div>
          <div class="inspector-collapsed-toggle" data-panel="right"></div>
          <div class="inspector-sidebar"></div>
        </div>
      </div>
    `;
    this.element.appendChild(this.inspectorEl);
    this.setupInspectorHandlers();
  }

  private setupInspectorHandlers(): void {
    if (!this.inspectorEl) return;

    // Tab switching
    const tabs = this.inspectorEl.querySelectorAll('.inspector-tab');
    tabs.forEach(tab => {
      tab.addEventListener('click', () => {
        tabs.forEach(t => t.classList.remove('active'));
        tab.classList.add('active');
        this.inspectorActiveTab = (tab as HTMLElement).dataset.tab || 'screen';
        this.renderInspectorView();
      });
    });

    // Resize handle
    const handle = this.inspectorEl.querySelector('.inspector-resize');
    let startY: number, startHeight: number;
    const onMouseMove = (e: MouseEvent) => {
      const delta = startY - e.clientY;
      const newHeight = Math.min(Math.max(startHeight + delta, 100), this.element.clientHeight * 0.6);
      this.inspectorHeight = newHeight;
      if (this.inspectorEl) {
        this.inspectorEl.style.height = newHeight + 'px';
      }
    };
    const onMouseUp = () => {
      document.removeEventListener('mousemove', onMouseMove);
      document.removeEventListener('mouseup', onMouseUp);
      this.triggerResize();
    };
    handle?.addEventListener('mousedown', (e) => {
      startY = (e as MouseEvent).clientY;
      startHeight = this.inspectorHeight;
      document.addEventListener('mousemove', onMouseMove);
      document.addEventListener('mouseup', onMouseUp);
    });

    // Dock icon dropdown
    const dockIcons = this.inspectorEl.querySelectorAll('.inspector-dock-icon');
    dockIcons.forEach(icon => {
      icon.addEventListener('click', (e) => {
        e.stopPropagation();
        const menu = icon.parentElement?.querySelector('.inspector-dock-menu');
        // Close other menus
        this.inspectorEl?.querySelectorAll('.inspector-dock-menu.visible').forEach(m => {
          if (m !== menu) m.classList.remove('visible');
        });
        menu?.classList.toggle('visible');
      });
    });

    // Hide menu when clicking elsewhere
    document.addEventListener('click', () => {
      this.inspectorEl?.querySelectorAll('.inspector-dock-menu.visible').forEach(m => {
        m.classList.remove('visible');
      });
    });

    // Menu item click - hide header
    const menuItems = this.inspectorEl.querySelectorAll('.inspector-dock-menu-item');
    menuItems.forEach(item => {
      item.addEventListener('click', (e) => {
        e.stopPropagation();
        const panel = (item as HTMLElement).closest('.inspector-left, .inspector-right');
        if (panel && (item as HTMLElement).dataset.action === 'hide-header') {
          panel.classList.add('header-hidden');
        }
        (item as HTMLElement).closest('.inspector-dock-menu')?.classList.remove('visible');
      });
    });

    // Collapsed toggle - show header again
    const toggles = this.inspectorEl.querySelectorAll('.inspector-collapsed-toggle');
    toggles.forEach(toggle => {
      toggle.addEventListener('click', () => {
        const panel = toggle.closest('.inspector-left, .inspector-right');
        panel?.classList.remove('header-hidden');
      });
    });
  }

  private triggerResize(): void {
    requestAnimationFrame(() => {
      const rect = this.canvas.getBoundingClientRect();
      const width = Math.floor(rect.width);
      const height = Math.floor(rect.height);
      if (width > 0 && height > 0 && this.serverId !== null && this.callbacks.onResize) {
        this.lastReportedWidth = width;
        this.lastReportedHeight = height;
        this.callbacks.onResize(this.serverId, width, height);
      }
    });
  }

  private showLoading(): void {
    if (!this.ctx) return;
    const rect = this.container.getBoundingClientRect();
    this.canvas.width = rect.width * (window.devicePixelRatio || 1);
    this.canvas.height = rect.height * (window.devicePixelRatio || 1);

    // Dark background with loading text
    this.ctx.fillStyle = '#1a1a1a';
    this.ctx.fillRect(0, 0, this.canvas.width, this.canvas.height);
    this.ctx.fillStyle = '#666';
    this.ctx.font = `${14 * (window.devicePixelRatio || 1)}px system-ui`;
    this.ctx.textAlign = 'center';
    this.ctx.fillText('Connecting...', this.canvas.width / 2, this.canvas.height / 2);
  }

  private initDecoder(): void {
    this.decoder = new VideoDecoder({
      output: (frame) => this.onFrame(frame),
      error: (e) => console.error('Decoder error:', e),
    });
  }

  private setupStatsOverlay(): void {
    if (!Panel.debugEnabled) return;
    console.log('Debug stats overlay enabled');

    this.statsOverlay = document.createElement('div');
    this.statsOverlay.className = 'panel-stats-overlay';
    this.statsOverlay.style.cssText = `
      position: absolute;
      top: 8px;
      right: 8px;
      background: rgba(0, 0, 0, 0.8);
      color: #0f0;
      font-family: monospace;
      font-size: 11px;
      padding: 6px 10px;
      border-radius: 4px;
      z-index: 1000;
      pointer-events: none;
      line-height: 1.4;
    `;
    this.element.appendChild(this.statsOverlay);
  }

  private updateStatsOverlay(): void {
    if (!this.statsOverlay) return;

    const now = performance.now();

    // Update displayed FPS every 500ms
    if (now - this.lastStatsUpdate > 500) {
      this.displayedFps = this.renderedFrames * 2; // 2x because 500ms interval
      this.renderedFrames = 0;
      this.lastStatsUpdate = now;
    }

    // Calculate average decode latency
    const avgLatency = this.decodeLatencies.length > 0
      ? (this.decodeLatencies.reduce((a, b) => a + b, 0) / this.decodeLatencies.length).toFixed(1)
      : '0.0';

    // Keep only recent latencies
    if (this.decodeLatencies.length > 30) {
      this.decodeLatencies.shift();
    }

    // Calculate received FPS
    const oneSecondAgo = now - 1000;
    const receivedFps = this.frameTimestamps.filter(t => t > oneSecondAgo).length;

    // Buffer health
    const health = Math.max(0, 100 - this.pendingDecode * 20);

    this.statsOverlay.innerHTML = `
      FPS: <span style="color: ${this.displayedFps >= 25 ? '#0f0' : this.displayedFps >= 15 ? '#ff0' : '#f00'}">${this.displayedFps}</span> render / ${receivedFps} recv<br>
      Queue: <span style="color: ${this.pendingDecode <= 1 ? '#0f0' : this.pendingDecode <= 3 ? '#ff0' : '#f00'}">${this.pendingDecode}</span> frames<br>
      Decode: ${avgLatency}ms<br>
      Health: <span style="color: ${health >= 80 ? '#0f0' : health >= 40 ? '#ff0' : '#f00'}">${health}%</span>
    `;
  }

  private onFrame(frame: VideoFrame): void {
    this.pendingDecode--;

    // Track decode latency
    if (this.lastDecodeStart > 0) {
      this.decodeLatencies.push(performance.now() - this.lastDecodeStart);
    }

    if (this.destroyed || !this.ctx) {
      frame.close();
      return;
    }

    // Resize canvas to match frame if needed
    if (this.canvas.width !== frame.displayWidth || this.canvas.height !== frame.displayHeight) {
      this.canvas.width = frame.displayWidth;
      this.canvas.height = frame.displayHeight;
    }

    // Draw frame to canvas
    this.ctx.drawImage(frame, 0, 0);
    frame.close();

    // Update stats
    this.renderedFrames++;
    this.updateStatsOverlay();
  }

  private setupEventHandlers(): void {
    // Mouse events on canvas
    this.canvas.addEventListener('mousedown', (e) => this.handleMouseDown(e));
    this.canvas.addEventListener('mouseup', (e) => this.handleMouseUp(e));
    this.canvas.addEventListener('mousemove', (e) => this.handleMouseMove(e));
    this.canvas.addEventListener('wheel', (e) => this.handleWheel(e), { passive: false });
    this.canvas.addEventListener('contextmenu', (e) => e.preventDefault());

    // Focus handling
    this.canvas.tabIndex = 1;

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

  connect(host: string, port: number): void {
    if (this.ws) {
      this.ws.close();
    }

    const wsUrl = `ws://${host}:${port}`;
    this.ws = new WebSocket(wsUrl);
    this.ws.binaryType = 'arraybuffer';

    this.ws.onopen = () => {
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

  // Parse NAL units from Annex B format (00 00 00 01 start codes)
  private parseNalUnits(data: Uint8Array): Uint8Array[] {
    const units: Uint8Array[] = [];
    let start = 0;

    for (let i = 0; i < data.length - 3; i++) {
      // Look for start code 00 00 00 01
      if (data[i] === 0 && data[i + 1] === 0 && data[i + 2] === 0 && data[i + 3] === 1) {
        if (i > start) {
          units.push(data.slice(start, i));
        }
        start = i + 4; // Skip start code
        i += 3;
      }
    }

    // Last NAL unit
    if (start < data.length) {
      units.push(data.slice(start));
    }

    return units;
  }

  // Extract codec string from SPS NAL unit
  private getCodecFromSps(sps: Uint8Array): string {
    // SPS structure: [NAL header][profile_idc][constraint_flags][level_idc]...
    // Format: avc1.PPCCLL (PP=profile, CC=constraints, LL=level)
    if (sps.length < 4) return 'avc1.42E01F'; // Default baseline 3.1

    const profile = sps[1];     // Skip NAL header byte
    const constraints = sps[2];
    const level = sps[3];

    return `avc1.${profile.toString(16).padStart(2, '0')}${constraints.toString(16).padStart(2, '0')}${level.toString(16).padStart(2, '0')}`;
  }

  private handleFrame(data: ArrayBuffer): void {
    if (this.destroyed || !this.decoder) return;

    this.frameTimestamps.push(performance.now());
    const nalData = new Uint8Array(data);
    const nalUnits = this.parseNalUnits(nalData);

    let isKeyframe = false;
    let sps: Uint8Array | null = null;
    let pps: Uint8Array | null = null;

    // Check NAL unit types
    for (const nal of nalUnits) {
      if (nal.length === 0) continue;
      const nalType = nal[0] & 0x1f;

      if (nalType === 7) { // SPS
        sps = nal;
      } else if (nalType === 8) { // PPS
        pps = nal;
      } else if (nalType === 5) { // IDR (keyframe)
        isKeyframe = true;
      }
    }

    // Configure decoder on first SPS
    if (sps && !this.decoderConfigured) {
      const codec = this.getCodecFromSps(sps);

      try {
        this.decoder.configure({
          codec: codec,
          optimizeForLatency: true,
        });
        this.decoderConfigured = true;
        console.log('Decoder configured:', codec);
      } catch (e) {
        console.error('Failed to configure decoder:', e);
        return;
      }
    }

    // Must have decoder configured
    if (!this.decoderConfigured) {
      return;
    }

    // Must receive keyframe first after configure
    if (!this.gotFirstKeyframe) {
      if (!isKeyframe) {
        return; // Skip until we get a keyframe
      }
      this.gotFirstKeyframe = true;
      console.log('Got first keyframe, starting decode');
    }

    this.decodeFrame(nalData, isKeyframe);
    this.checkBufferHealth();
  }

  private decodeFrame(data: Uint8Array, isKeyframe: boolean): void {
    if (!this.decoder || this.decoder.state !== 'configured') return;

    const timestamp = this.frameCount * (1000000 / 30); // microseconds at 30fps
    this.frameCount++;
    this.pendingDecode++;
    this.lastDecodeStart = performance.now();

    try {
      const chunk = new EncodedVideoChunk({
        type: isKeyframe ? 'key' : 'delta',
        timestamp: timestamp,
        data: data,
      });
      this.decoder.decode(chunk);
    } catch (e) {
      console.error('Decode error:', e);
      this.pendingDecode--;
    }
  }

  private checkBufferHealth(): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;

    const now = performance.now();

    // Calculate received FPS
    const oneSecondAgo = now - 1000;
    this.frameTimestamps = this.frameTimestamps.filter(t => t > oneSecondAgo);
    const receivedFps = this.frameTimestamps.length;

    // Buffer health based on pending decode queue
    // 0 pending = healthy (100), many pending = unhealthy (0)
    const health = Math.max(0, 100 - this.pendingDecode * 20);

    // Report every second
    if (now - this.lastBufferReport > 1000) {
      this.sendBufferStats(health, receivedFps);
      this.lastBufferReport = now;
    }
  }

  private sendBufferStats(health: number, fps: number): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;

    const buf = new ArrayBuffer(5);
    const view = new DataView(buf);
    view.setUint8(0, ClientMsg.BUFFER_STATS);
    view.setUint8(1, Math.round(health));
    view.setUint8(2, Math.round(fps));
    view.setUint16(3, this.pendingDecode * 33, true); // Approx ms of buffer
    this.ws.send(buf);
  }

  // Input handling
  sendKeyInput(e: KeyboardEvent, action: number): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;

    const encoder = new TextEncoder();
    const codeBytes = encoder.encode(e.code);
    const text = (e.key.length === 1) ? e.key : '';
    const textBytes = encoder.encode(text);

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

    // Use CSS pixels (points), not device pixels - Ghostty expects point coordinates
    const rect = this.canvas.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;

    const buf = new ArrayBuffer(18);
    const view = new DataView(buf);
    view.setUint8(0, ClientMsg.MOUSE_MOVE);
    view.setFloat64(1, x, true);
    view.setFloat64(9, y, true);
    view.setUint8(17, this.getModifiers(e));
    this.ws.send(buf);
  }

  private sendMouseButton(e: MouseEvent, pressed: boolean): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;

    const rect = this.canvas.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;

    const buf = new ArrayBuffer(20);
    const view = new DataView(buf);
    view.setUint8(0, ClientMsg.MOUSE_INPUT);
    view.setFloat64(1, x, true);
    view.setFloat64(9, y, true);
    view.setUint8(17, e.button);
    view.setUint8(18, pressed ? 1 : 0);
    view.setUint8(19, this.getModifiers(e));
    this.ws.send(buf);
  }

  private handleWheel(e: WheelEvent): void {
    e.preventDefault();
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;

    const rect = this.canvas.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;

    let dx = e.deltaX;
    let dy = e.deltaY;
    if (e.deltaMode === 1) {
      dx *= 20;
      dy *= 20;
    } else if (e.deltaMode === 2) {
      dx *= this.canvas.clientWidth;
      dy *= this.canvas.clientHeight;
    }

    const buf = new ArrayBuffer(34);
    const view = new DataView(buf);
    view.setUint8(0, ClientMsg.MOUSE_SCROLL);
    view.setFloat64(1, x, true);
    view.setFloat64(9, y, true);
    view.setFloat64(17, dx, true);
    view.setFloat64(25, dy, true);
    view.setUint8(33, this.getModifiers(e));
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
    const newVisible = visible ?? !this.inspectorVisible;
    if (newVisible) {
      this.showInspector();
    } else {
      this.hideInspector();
    }
  }

  private showInspector(): void {
    this.inspectorVisible = true;
    if (this.inspectorEl) {
      this.inspectorEl.classList.add('visible');
      this.inspectorEl.style.height = this.inspectorHeight + 'px';
    }
    // Subscribe to inspector updates
    this.callbacks.onViewAction?.('inspector_subscribe', { panelId: this.serverId });
    this.triggerResize();
  }

  private hideInspector(): void {
    this.inspectorVisible = false;
    if (this.inspectorEl) {
      this.inspectorEl.classList.remove('visible');
    }
    // Unsubscribe from inspector updates
    this.callbacks.onViewAction?.('inspector_unsubscribe', { panelId: this.serverId });
    this.triggerResize();
  }

  hide(): void {
    if (this.paused) return;
    this.paused = true;

    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      const buf = new ArrayBuffer(1);
      new DataView(buf).setUint8(0, ClientMsg.PAUSE_STREAM);
      this.ws.send(buf);
    }
  }

  show(): void {
    if (!this.paused) return;
    this.paused = false;

    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      const buf = new ArrayBuffer(1);
      new DataView(buf).setUint8(0, ClientMsg.RESUME_STREAM);
      this.ws.send(buf);
    }
  }

  handleInspectorState(state: unknown): void {
    if (state && typeof state === 'object') {
      this.inspectorState = state as Record<string, number>;
      this.renderInspectorSidebar();
      this.renderInspectorView();
    }
  }

  private renderInspectorSidebar(): void {
    const sidebarEl = this.inspectorEl?.querySelector('.inspector-sidebar') as HTMLElement;
    if (!sidebarEl || !this.inspectorState) return;

    const s = this.inspectorState;

    if (!sidebarEl.dataset.initialized) {
      sidebarEl.dataset.initialized = 'true';
      sidebarEl.innerHTML = `
        <div class="inspector-simple-section">
          <span class="inspector-simple-title">Dimensions</span>
          <hr>
        </div>
        <div class="inspector-row"><span class="inspector-label">Screen Size</span><span class="inspector-value" data-field="screen-size"></span></div>
        <div class="inspector-row"><span class="inspector-label">Grid Size</span><span class="inspector-value" data-field="grid-size"></span></div>
        <div class="inspector-row"><span class="inspector-label">Cell Size</span><span class="inspector-value" data-field="cell-size"></span></div>
      `;
    }

    const f = (field: string) => sidebarEl.querySelector(`[data-field="${field}"]`);
    const screenSize = f('screen-size');
    const gridSize = f('grid-size');
    const cellSize = f('cell-size');
    if (screenSize) screenSize.textContent = `${s.width_px ?? 0}px × ${s.height_px ?? 0}px`;
    if (gridSize) gridSize.textContent = `${s.cols ?? 0}c × ${s.rows ?? 0}r`;
    if (cellSize) cellSize.textContent = `${s.cell_width ?? 0}px × ${s.cell_height ?? 0}px`;
  }

  private renderInspectorView(): void {
    const mainEl = this.inspectorEl?.querySelector('.inspector-main');
    if (!mainEl) return;

    const s = this.inspectorState || {};

    mainEl.innerHTML = `
      <div class="inspector-simple-section">
        <span class="inspector-simple-title">Terminal Size</span>
        <hr>
      </div>
      <div class="inspector-row"><span class="inspector-label">Grid</span><span class="inspector-value">${s.cols ?? 0} columns × ${s.rows ?? 0} rows</span></div>
      <div class="inspector-row"><span class="inspector-label">Screen</span><span class="inspector-value">${s.width_px ?? 0} × ${s.height_px ?? 0} px</span></div>
      <div class="inspector-row"><span class="inspector-label">Cell</span><span class="inspector-value">${s.cell_width ?? 0} × ${s.cell_height ?? 0} px</span></div>
    `;
  }

  sendTextInput(text: string): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;

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

    if (this.decoder) {
      this.decoder.close();
      this.decoder = null;
    }

    if (this.statsOverlay) {
      this.statsOverlay.remove();
      this.statsOverlay = null;
    }

    if (this.element.parentElement) {
      this.element.parentElement.removeChild(this.element);
    }
  }
}
