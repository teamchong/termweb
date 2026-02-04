/**
 * Panel - Terminal panel with H.264 video via WebCodecs
 * Lower latency than jMuxer/MSE by decoding directly to canvas
 */

import { ClientMsg, BinaryCtrlMsg } from './protocol';
import type { PanelStatus } from './stores/types';
import { getWsUrl, sharedTextEncoder, CircularBuffer, throttle } from './utils';
import { PANEL, TIMING, WS_PATHS, UI, NAL, MODIFIER, WHEEL_MODE, STATS_THRESHOLD } from './constants';

export interface PanelCallbacks {
  onViewAction?: (action: string, data?: unknown) => void;
  onStatusChange?: (status: PanelStatus) => void;
  onTitleChange?: (title: string) => void;
  onPwdChange?: (pwd: string) => void;
  onServerIdAssigned?: (serverId: number) => void;
}

export class Panel {
  readonly id: string;
  serverId: number | null;
  container: HTMLElement;
  readonly canvas: HTMLCanvasElement;
  readonly element: HTMLElement;
  pwd: string = '';
  private inheritCwdFrom: number | null = null;

  private ws: WebSocket | null = null;
  private callbacks: PanelCallbacks;
  private _status: PanelStatus = 'disconnected';
  private destroyed = false;
  private paused = false;

  get status(): PanelStatus {
    return this._status;
  }

  private setStatus(status: PanelStatus): void {
    if (this._status === status) return;
    this._status = status;
    this.callbacks.onStatusChange?.(status);
  }

  /** Check if WebSocket is connected and ready */
  private isWsOpen(): boolean {
    return this.ws !== null && this.ws.readyState === WebSocket.OPEN;
  }

  // WebCodecs decoder
  private decoder: VideoDecoder | null = null;
  private decoderConfigured = false;
  private lastCodec: string | null = null; // Track codec to detect resolution changes
  private gotFirstKeyframe = false; // Must receive keyframe before decoding
  private frameCount = 0;
  private ctx: CanvasRenderingContext2D | null = null;

  private lastReportedWidth = 0;
  private lastReportedHeight = 0;
  resizeObserver: ResizeObserver | null = null;

  // Adaptive bitrate - buffer monitoring
  private lastBufferReport = 0;
  private frameTimestamps: CircularBuffer<number> = new CircularBuffer(60); // ~2s at 30fps
  private pendingDecode = 0; // Frames waiting to be decoded

  // Debug stats overlay (enable with #debug=1 or ?debug=1 in URL)
  private static debugEnabled = window.location.hash.includes('debug') ||
    window.location.search.includes('debug');
  private static statsOverlay: HTMLElement | null = null; // Singleton overlay
  private static statsElements: {
    fpsValue: HTMLSpanElement;
    recvFps: HTMLSpanElement;
    queueValue: HTMLSpanElement;
    decodeValue: HTMLSpanElement;
    healthValue: HTMLSpanElement;
  } | null = null;
  private renderedFrames = 0;
  private lastStatsUpdate = 0;
  private displayedFps = 0;
  private decodeLatencies: CircularBuffer<number> = new CircularBuffer(PANEL.MAX_LATENCY_SAMPLES);
  private lastDecodeStart = 0;

  // Pre-allocated buffers for hot paths (avoid allocation on every mouse move)
  private mouseMoveBuffer = new ArrayBuffer(18);
  private mouseMoveView = new DataView(this.mouseMoveBuffer);
  private mouseButtonBuffer = new ArrayBuffer(20);
  private mouseButtonView = new DataView(this.mouseButtonBuffer);
  private wheelBuffer = new ArrayBuffer(34);
  private wheelView = new DataView(this.wheelBuffer);
  private resizeBuffer = new ArrayBuffer(5);
  private resizeView = new DataView(this.resizeBuffer);

  // Throttled mouse move handler
  private throttledSendMouseMove: ((x: number, y: number, mods: number) => void) | null = null;

  // Event handler references for cleanup
  private handleMouseDownBound: ((e: MouseEvent) => void) | null = null;
  private handleMouseUpBound: ((e: MouseEvent) => void) | null = null;
  private handleMouseMoveBound: ((e: MouseEvent) => void) | null = null;
  private handleWheelBound: ((e: WheelEvent) => void) | null = null;
  private handleContextMenuBound: ((e: Event) => void) | null = null;

  // Inspector state
  private inspectorVisible = false;
  private inspectorHeight: number = PANEL.DEFAULT_INSPECTOR_HEIGHT;
  private inspectorActiveTab: string = UI.DEFAULT_INSPECTOR_TAB;
  private inspectorState: Record<string, number> | null = null;
  private inspectorEl: HTMLElement | null = null;
  private inspectorSidebarEl: HTMLElement | null = null;
  private inspectorMainEl: HTMLElement | null = null;
  private inspectorFieldEls: {
    screenSize: Element | null;
    gridSize: Element | null;
    cellSize: Element | null;
  } | null = null;
  private documentClickHandler: (() => void) | null = null;

  // Inspector event handler references for cleanup
  private inspectorHandlers: Array<{ element: Element; type: string; handler: EventListener }> = [];
  private inspectorResizeHandler: ((e: Event) => void) | null = null;
  // Document-level resize handlers (added during drag, need cleanup on destroy)
  private inspectorResizeMoveHandler: ((e: MouseEvent) => void) | null = null;
  private inspectorResizeUpHandler: (() => void) | null = null;
  private connectTimeoutId: ReturnType<typeof setTimeout> | null = null;

  private initialSize: { width: number; height: number } | null = null;
  private splitInfo: { parentPanelId: number; direction: 'right' | 'down' | 'left' | 'up' } | null = null;
  private isQuickTerminal = false;

  constructor(
    id: string,
    container: HTMLElement,
    serverId: number | null,
    callbacks: PanelCallbacks = {},
    inheritCwdFrom: number | null = null,
    initialSize?: { width: number; height: number },
    splitInfo?: { parentPanelId: number; direction: 'right' | 'down' | 'left' | 'up' },
    isQuickTerminal = false
  ) {
    this.id = id;
    this.serverId = serverId;
    this.container = container;
    this.callbacks = callbacks;
    this.inheritCwdFrom = inheritCwdFrom;
    this.initialSize = initialSize ?? null;
    this.splitInfo = splitInfo ?? null;
    this.isQuickTerminal = isQuickTerminal;

    // Create panel element with canvas
    this.element = document.createElement('div');
    this.element.className = 'panel';
    this.element.innerHTML = `
      <div class="panel-content">
        <canvas class="panel-canvas"></canvas>
        <div class="panel-loading">${UI.LOADING_TEXT}</div>
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

    // Helper to track handlers for cleanup
    const addHandler = (element: Element, type: string, handler: EventListener) => {
      element.addEventListener(type, handler);
      this.inspectorHandlers.push({ element, type, handler });
    };

    // Tab switching
    const tabs = this.inspectorEl.querySelectorAll('.inspector-tab');
    tabs.forEach(tab => {
      const handler = () => {
        tabs.forEach(t => t.classList.remove('active'));
        tab.classList.add('active');
        this.inspectorActiveTab = (tab as HTMLElement).dataset.tab || 'screen';
        this.renderInspectorView();
      };
      addHandler(tab, 'click', handler);
    });

    // Resize handle
    const handle = this.inspectorEl.querySelector('.inspector-resize');
    if (handle) {
      let startY: number, startHeight: number;
      this.inspectorResizeMoveHandler = (e: MouseEvent) => {
        const delta = startY - e.clientY;
        const newHeight = Math.min(Math.max(startHeight + delta, PANEL.MIN_INSPECTOR_HEIGHT), this.element.clientHeight * PANEL.MAX_INSPECTOR_HEIGHT_RATIO);
        this.inspectorHeight = newHeight;
        if (this.inspectorEl) {
          this.inspectorEl.style.height = newHeight + 'px';
        }
      };
      this.inspectorResizeUpHandler = () => {
        if (this.inspectorResizeMoveHandler) {
          document.removeEventListener('mousemove', this.inspectorResizeMoveHandler);
        }
        if (this.inspectorResizeUpHandler) {
          document.removeEventListener('mouseup', this.inspectorResizeUpHandler);
        }
        this.inspectorResizeMoveHandler = null;
        this.inspectorResizeUpHandler = null;
        this.triggerResize();
      };
      this.inspectorResizeHandler = (e: Event) => {
        startY = (e as MouseEvent).clientY;
        startHeight = this.inspectorHeight;
        if (this.inspectorResizeMoveHandler) {
          document.addEventListener('mousemove', this.inspectorResizeMoveHandler);
        }
        if (this.inspectorResizeUpHandler) {
          document.addEventListener('mouseup', this.inspectorResizeUpHandler);
        }
      };
      addHandler(handle, 'mousedown', this.inspectorResizeHandler);
    }

    // Dock icon dropdown
    const dockIcons = this.inspectorEl.querySelectorAll('.inspector-dock-icon');
    dockIcons.forEach(icon => {
      const handler = (e: Event) => {
        e.stopPropagation();
        const menu = icon.parentElement?.querySelector('.inspector-dock-menu');
        // Close other menus
        this.inspectorEl?.querySelectorAll('.inspector-dock-menu.visible').forEach(m => {
          if (m !== menu) m.classList.remove('visible');
        });
        menu?.classList.toggle('visible');
      };
      addHandler(icon, 'click', handler);
    });

    // Hide menu when clicking elsewhere
    this.documentClickHandler = () => {
      this.inspectorEl?.querySelectorAll('.inspector-dock-menu.visible').forEach(m => {
        m.classList.remove('visible');
      });
    };
    document.addEventListener('click', this.documentClickHandler);

    // Menu item click - hide header
    const menuItems = this.inspectorEl.querySelectorAll('.inspector-dock-menu-item');
    menuItems.forEach(item => {
      const handler = (e: Event) => {
        e.stopPropagation();
        const panel = (item as HTMLElement).closest('.inspector-left, .inspector-right');
        if (panel && (item as HTMLElement).dataset.action === 'hide-header') {
          panel.classList.add('header-hidden');
        }
        (item as HTMLElement).closest('.inspector-dock-menu')?.classList.remove('visible');
      };
      addHandler(item, 'click', handler);
    });

    // Collapsed toggle - show header again
    const toggles = this.inspectorEl.querySelectorAll('.inspector-collapsed-toggle');
    toggles.forEach(toggle => {
      const handler = () => {
        const panel = toggle.closest('.inspector-left, .inspector-right');
        panel?.classList.remove('header-hidden');
      };
      addHandler(toggle, 'click', handler);
    });
  }

  private triggerResize(): void {
    requestAnimationFrame(() => {
      const rect = this.canvas.getBoundingClientRect();
      const width = Math.floor(rect.width);
      const height = Math.floor(rect.height);
      if (width > 0 && height > 0) {
        this.lastReportedWidth = width;
        this.lastReportedHeight = height;
        this.sendResizeBinary(width, height);
      }
    });
  }

  private hideLoading(): void {
    const loading = this.element.querySelector('.panel-loading');
    if (loading) loading.remove();
  }

  private initDecoder(): void {
    this.decoder = new VideoDecoder({
      output: (frame) => this.onFrame(frame),
      error: (e) => {
        console.error('Decoder error:', e);
        this.setStatus('error');
      },
    });
  }

  private setupStatsOverlay(): void {
    if (!Panel.debugEnabled || Panel.statsOverlay) return; // Only create once
    console.log('Debug stats overlay enabled');

    Panel.statsOverlay = document.createElement('div');
    Panel.statsOverlay.className = 'panel-stats-overlay';
    Panel.statsOverlay.style.cssText = `
      position: fixed;
      bottom: 8px;
      right: 8px;
      background: rgba(0, 0, 0, 0.5);
      color: #0f0;
      font-family: monospace;
      font-size: 11px;
      padding: 6px 10px;
      border-radius: 4px;
      z-index: 10000;
      pointer-events: none;
      line-height: 1.4;
    `;
    Panel.statsOverlay.innerHTML = `
      FPS: <span id="stats-fps">0</span> render / <span id="stats-recv">0</span> recv<br>
      Queue: <span id="stats-queue">0</span> frames<br>
      Decode: <span id="stats-decode">0.0</span>ms<br>
      Health: <span id="stats-health">100</span>%
    `;
    document.body.appendChild(Panel.statsOverlay);

    // Cache span element references for efficient updates
    Panel.statsElements = {
      fpsValue: Panel.statsOverlay.querySelector('#stats-fps') as HTMLSpanElement,
      recvFps: Panel.statsOverlay.querySelector('#stats-recv') as HTMLSpanElement,
      queueValue: Panel.statsOverlay.querySelector('#stats-queue') as HTMLSpanElement,
      decodeValue: Panel.statsOverlay.querySelector('#stats-decode') as HTMLSpanElement,
      healthValue: Panel.statsOverlay.querySelector('#stats-health') as HTMLSpanElement,
    };
  }

  private updateStatsOverlay(): void {
    if (!Panel.statsOverlay || !Panel.statsElements) return;

    const now = performance.now();

    // Update displayed FPS every 500ms
    if (now - this.lastStatsUpdate > TIMING.STATS_UPDATE_INTERVAL) {
      this.displayedFps = this.renderedFrames * 2; // 2x because 500ms interval
      this.renderedFrames = 0;
      this.lastStatsUpdate = now;
    }

    // Calculate average decode latency from circular buffer
    const avgLatency = this.decodeLatencies.average().toFixed(1);

    // Calculate received FPS from circular buffer
    const oneSecondAgo = now - TIMING.FPS_CALCULATION_WINDOW;
    const receivedFps = this.frameTimestamps.filterRecent(oneSecondAgo, (a, b) => a - b).length;

    // Buffer health
    const health = Math.max(0, PANEL.MAX_BUFFER_HEALTH - this.pendingDecode * PANEL.HEALTH_PENALTY_PER_PENDING);

    // Update cached span elements (avoids innerHTML reflow)
    const els = Panel.statsElements;
    els.fpsValue.textContent = String(this.displayedFps);
    els.fpsValue.style.color = this.displayedFps >= STATS_THRESHOLD.FPS_GOOD ? '#0f0' : this.displayedFps >= STATS_THRESHOLD.FPS_WARN ? '#ff0' : '#f00';
    els.recvFps.textContent = String(receivedFps);
    els.queueValue.textContent = String(this.pendingDecode);
    els.queueValue.style.color = this.pendingDecode <= STATS_THRESHOLD.QUEUE_GOOD ? '#0f0' : this.pendingDecode <= STATS_THRESHOLD.QUEUE_WARN ? '#ff0' : '#f00';
    els.decodeValue.textContent = avgLatency;
    els.healthValue.textContent = String(health);
    els.healthValue.style.color = health >= STATS_THRESHOLD.HEALTH_GOOD ? '#0f0' : health >= STATS_THRESHOLD.HEALTH_WARN ? '#ff0' : '#f00';
  }

  private onFrame(frame: VideoFrame): void {
    this.pendingDecode--;

    // Check destroyed early to avoid side effects on destroyed panel
    if (this.destroyed || !this.ctx) {
      console.warn(`Panel ${this.id}: onFrame skipped - destroyed=${this.destroyed}, ctx=${!!this.ctx}`);
      frame.close();
      return;
    }

    // Track decode latency using circular buffer
    if (this.lastDecodeStart > 0) {
      this.decodeLatencies.push(performance.now() - this.lastDecodeStart);
    }

    // Log first frame
    if (this.renderedFrames === 0) {
      console.log(`Panel ${this.id}: First frame rendered, size=${frame.displayWidth}x${frame.displayHeight}`);
    }

    // Resize canvas to match frame if needed
    if (this.canvas.width !== frame.displayWidth || this.canvas.height !== frame.displayHeight) {
      this.canvas.width = frame.displayWidth;
      this.canvas.height = frame.displayHeight;
    }

    // Draw frame to canvas
    this.ctx.drawImage(frame, 0, 0);
    frame.close();

    // Hide loading overlay on first frame
    this.hideLoading();

    // Update stats
    this.renderedFrames++;
    this.updateStatsOverlay();
  }

  private setupEventHandlers(): void {
    // Initialize throttled mouse move (30fps = ~33ms between sends)
    this.throttledSendMouseMove = throttle((x: number, y: number, mods: number) => {
      this.sendMouseMoveInternal(x, y, mods);
    }, PANEL.APPROX_FRAME_DURATION_MS);

    // Store bound references for cleanup
    this.handleMouseDownBound = (e: MouseEvent) => this.handleMouseDown(e);
    this.handleMouseUpBound = (e: MouseEvent) => this.handleMouseUp(e);
    this.handleMouseMoveBound = (e: MouseEvent) => this.handleMouseMove(e);
    this.handleWheelBound = (e: WheelEvent) => this.handleWheel(e);
    this.handleContextMenuBound = (e: Event) => e.preventDefault();

    // Mouse events on canvas
    this.canvas.addEventListener('mousedown', this.handleMouseDownBound);
    this.canvas.addEventListener('mouseup', this.handleMouseUpBound);
    this.canvas.addEventListener('mousemove', this.handleMouseMoveBound);
    this.canvas.addEventListener('wheel', this.handleWheelBound, { passive: false });
    this.canvas.addEventListener('contextmenu', this.handleContextMenuBound);

    // Focus handling
    this.canvas.tabIndex = PANEL.CANVAS_TAB_INDEX;
  }

  private setupResizeObserver(): void {
    this.resizeObserver = new ResizeObserver(() => {
      // Use rAF to ensure layout is complete, no debounce needed
      // Dimension check below prevents duplicate calls
      requestAnimationFrame(() => {
        const rect = this.element.getBoundingClientRect();
        const width = Math.floor(rect.width);
        const height = Math.floor(rect.height);

        if (width === 0 || height === 0) return;
        if (width === this.lastReportedWidth && height === this.lastReportedHeight) return;

        this.lastReportedWidth = width;
        this.lastReportedHeight = height;

        // Send resize directly as binary on panel WebSocket (faster than JSON on control WS)
        this.sendResizeBinary(width, height);
      });
    });
    this.resizeObserver.observe(this.element);
  }

  private sendResizeBinary(width: number, height: number): void {
    if (!this.isWsOpen()) return;

    // Use pre-allocated buffer to avoid GC
    this.resizeView.setUint8(0, ClientMsg.RESIZE);
    this.resizeView.setUint16(1, width, true);
    this.resizeView.setUint16(3, height, true);
    this.ws!.send(this.resizeBuffer);
  }

  connect(): void {
    if (this.ws) {
      this.ws.close();
    }

    this.setStatus('connecting');

    const wsUrl = getWsUrl(WS_PATHS.PANEL);
    this.ws = new WebSocket(wsUrl);
    this.ws.binaryType = 'arraybuffer';

    this.ws.onopen = () => {
      this.setStatus('connected');
      // Delay slightly to ensure DOM layout is complete before measuring
      requestAnimationFrame(() => requestAnimationFrame(() => {
        if (this.serverId !== null) {
          this.sendConnectPanel(this.serverId);
        } else if (this.splitInfo) {
          this.sendSplitPanel();
        } else {
          this.sendCreatePanel();
        }
      }));
    };

    this.ws.onmessage = (event) => {
      if (event.data instanceof ArrayBuffer) {
        this.handleFrame(event.data);
      }
    };

    this.ws.onclose = () => {
      this.ws = null;
      if (!this.destroyed) {
        this.setStatus('disconnected');
      }
    };

    this.ws.onerror = (e) => {
      console.error('WebSocket error:', e);
      this.setStatus('error');
    };
  }

  private sendConnectPanel(panelId: number): void {
    if (!this.isWsOpen()) return;

    const buf = new ArrayBuffer(5);
    const view = new DataView(buf);
    view.setUint8(0, ClientMsg.CONNECT_PANEL);
    view.setUint32(1, panelId, true);
    this.ws!.send(buf);

    // Send resize after a short delay to ensure correct dimensions after layout
    this.connectTimeoutId = setTimeout(() => {
      this.connectTimeoutId = null;
      if (this.destroyed) return;
      requestAnimationFrame(() => {
        // Re-check destroyed after rAF delay
        if (this.destroyed) return;
        const rect = this.element.getBoundingClientRect();
        const width = Math.floor(rect.width);
        const height = Math.floor(rect.height);
        if (width > 0 && height > 0) {
          this.lastReportedWidth = width;
          this.lastReportedHeight = height;
          this.sendResizeBinary(width, height);
        }
      });
    }, TIMING.RESIZE_DELAY_AFTER_CONNECT);
  }

  private sendCreatePanel(): void {
    if (!this.isWsOpen()) return;

    // Use pre-calculated size if provided, otherwise measure element
    let width: number, height: number;
    if (this.initialSize) {
      width = this.initialSize.width;
      height = this.initialSize.height;
      this.initialSize = null; // Clear after use
    } else {
      const rect = this.element.getBoundingClientRect();
      width = Math.floor(rect.width) || PANEL.DEFAULT_WIDTH;
      height = Math.floor(rect.height) || PANEL.DEFAULT_HEIGHT;
    }
    const scale = window.devicePixelRatio || 1;

    this.lastReportedWidth = width;
    this.lastReportedHeight = height;

    // [msg_type:u8][width:u16][height:u16][scale:f32][inherit_cwd_from:u32][flags:u8]
    // flags: bit 0 = isQuickTerminal (don't add to layout)
    const buf = new ArrayBuffer(14);
    const view = new DataView(buf);
    view.setUint8(0, ClientMsg.CREATE_PANEL);
    view.setUint16(1, width, true);
    view.setUint16(3, height, true);
    view.setFloat32(5, scale, true);
    view.setUint32(9, this.inheritCwdFrom ?? 0, true);
    view.setUint8(13, this.isQuickTerminal ? 1 : 0);
    this.ws!.send(buf);
  }

  private sendSplitPanel(): void {
    if (!this.isWsOpen() || !this.splitInfo) return;

    // Use pre-calculated size if provided, otherwise measure element
    let width: number, height: number;
    if (this.initialSize) {
      width = this.initialSize.width;
      height = this.initialSize.height;
      this.initialSize = null;
    } else {
      const rect = this.element.getBoundingClientRect();
      width = Math.floor(rect.width) || PANEL.DEFAULT_WIDTH;
      height = Math.floor(rect.height) || PANEL.DEFAULT_HEIGHT;
    }
    const scale = window.devicePixelRatio || 1;

    this.lastReportedWidth = width;
    this.lastReportedHeight = height;

    // Map direction to horizontal/vertical: right/left = horizontal, down/up = vertical
    const isVertical = this.splitInfo.direction === 'down' || this.splitInfo.direction === 'up';
    const dirByte = isVertical ? 1 : 0;

    // Binary: [msg_type:u8][parent_id:u32][dir_byte:u8][width:u16][height:u16][scale_x100:u16]
    const buf = new ArrayBuffer(12);
    const view = new DataView(buf);
    view.setUint8(0, ClientMsg.SPLIT_PANEL);
    view.setUint32(1, this.splitInfo.parentPanelId, true);
    view.setUint8(5, dirByte);
    view.setUint16(6, width, true);
    view.setUint16(8, height, true);
    view.setUint16(10, Math.round(scale * 100), true);
    this.ws!.send(buf);
    this.splitInfo = null; // Clear after use
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
    if (sps.length < 4) return PANEL.DEFAULT_H264_CODEC; // Default baseline 3.1

    const profile = sps[1];     // Skip NAL header byte
    const constraints = sps[2];
    const level = sps[3];

    return `avc1.${profile.toString(16).padStart(2, '0')}${constraints.toString(16).padStart(2, '0')}${level.toString(16).padStart(2, '0')}`;
  }

  private handleFrame(data: ArrayBuffer): void {
    if (this.destroyed) return;

    this.frameTimestamps.push(performance.now()); // CircularBuffer handles size limit
    const frameData = new Uint8Array(data);

    // Handle H.264 frame
    if (!this.decoder) return;

    const nalUnits = this.parseNalUnits(frameData);

    let isKeyframe = false;
    let sps: Uint8Array | null = null;
    let pps: Uint8Array | null = null;

    // Check NAL unit types
    for (const nal of nalUnits) {
      if (nal.length === 0) continue;
      const nalType = nal[0] & NAL.TYPE_MASK;

      if (nalType === NAL.TYPE_SPS) {
        sps = nal;
      } else if (nalType === NAL.TYPE_PPS) {
        pps = nal;
      } else if (nalType === NAL.TYPE_IDR) {
        isKeyframe = true;
      }
    }

    // Configure or reconfigure decoder when SPS is received
    // SPS contains resolution info - must reconfigure when it changes (e.g., after resize)
    if (sps) {
      const codec = this.getCodecFromSps(sps);

      // Check if we need to reconfigure (first time or codec changed)
      if (!this.decoderConfigured || codec !== this.lastCodec) {
        try {
          // Reset decoder if reconfiguring
          if (this.decoderConfigured) {
            console.log('Reconfiguring decoder:', this.lastCodec, '->', codec);
            this.decoder.reset();
            this.gotFirstKeyframe = false;
          }

          this.decoder.configure({
            codec: codec,
            optimizeForLatency: true,
          });
          this.decoderConfigured = true;
          this.lastCodec = codec;
          console.log('Decoder configured:', codec);
        } catch (e) {
          console.error('Failed to configure decoder:', e);
          this.setStatus('error');
          return;
        }
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

    this.decodeFrame(frameData, isKeyframe);
    this.checkBufferHealth();
  }

  private decodeFrame(data: Uint8Array, isKeyframe: boolean): void {
    if (!this.decoder || this.decoder.state !== 'configured') return;

    const timestamp = this.frameCount * (1000000 / PANEL.ASSUMED_FPS); // microseconds
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
      this.setStatus('error');
    }
  }

  private checkBufferHealth(): void {
    if (!this.isWsOpen()) return;

    const now = performance.now();

    // Calculate received FPS using CircularBuffer filterRecent
    const oneSecondAgo = now - TIMING.FPS_CALCULATION_WINDOW;
    const receivedFps = this.frameTimestamps.filterRecent(oneSecondAgo, (a, b) => a - b).length;

    // Buffer health based on pending decode queue
    // 0 pending = healthy (100), many pending = unhealthy (0)
    const health = Math.max(0, PANEL.MAX_BUFFER_HEALTH - this.pendingDecode * PANEL.HEALTH_PENALTY_PER_PENDING);

    // Report every second
    if (now - this.lastBufferReport > TIMING.BUFFER_STATS_INTERVAL) {
      this.sendBufferStats(health, receivedFps);
      this.lastBufferReport = now;
    }
  }

  private sendBufferStats(health: number, fps: number): void {
    if (!this.isWsOpen()) return;

    const buf = new ArrayBuffer(5);
    const view = new DataView(buf);
    view.setUint8(0, ClientMsg.BUFFER_STATS);
    view.setUint8(1, Math.round(health));
    view.setUint8(2, Math.round(fps));
    view.setUint16(3, this.pendingDecode * PANEL.APPROX_FRAME_DURATION_MS, true);
    this.ws!.send(buf);
  }

  // Input handling
  sendKeyInput(e: KeyboardEvent, action: number): void {
    if (!this.isWsOpen()) return;

    const codeBytes = sharedTextEncoder.encode(e.code);
    const text = (e.key.length === 1) ? e.key : '';
    const textBytes = sharedTextEncoder.encode(text);

    const buf = new ArrayBuffer(5 + codeBytes.length + textBytes.length);
    const view = new Uint8Array(buf);
    view[0] = ClientMsg.KEY_INPUT;
    view[1] = action;
    view[2] = this.getModifiers(e);
    view[3] = codeBytes.length;
    view.set(codeBytes, 4);
    view[4 + codeBytes.length] = textBytes.length;
    view.set(textBytes, 5 + codeBytes.length);
    this.ws!.send(buf);
  }

  private handleMouseDown(e: MouseEvent): void {
    this.element.focus();
    this.sendMouseButton(e, true);
  }

  private handleMouseUp(e: MouseEvent): void {
    this.sendMouseButton(e, false);
  }

  private handleMouseMove(e: MouseEvent): void {
    if (!this.isWsOpen()) return;

    // Use CSS pixels (points), not device pixels - Ghostty expects point coordinates
    const rect = this.canvas.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;
    const mods = this.getModifiers(e);

    // Use throttled handler to reduce event frequency
    this.throttledSendMouseMove?.(x, y, mods);
  }

  private sendMouseMoveInternal(x: number, y: number, mods: number): void {
    if (!this.isWsOpen()) return;

    // Use pre-allocated buffer to avoid GC in hot path
    this.mouseMoveView.setUint8(0, ClientMsg.MOUSE_MOVE);
    this.mouseMoveView.setFloat64(1, x, true);
    this.mouseMoveView.setFloat64(9, y, true);
    this.mouseMoveView.setUint8(17, mods);
    this.ws!.send(this.mouseMoveBuffer);
  }

  private sendMouseButton(e: MouseEvent, pressed: boolean): void {
    if (!this.isWsOpen()) return;

    const rect = this.canvas.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;

    // Use pre-allocated buffer to avoid GC in hot path
    this.mouseButtonView.setUint8(0, ClientMsg.MOUSE_INPUT);
    this.mouseButtonView.setFloat64(1, x, true);
    this.mouseButtonView.setFloat64(9, y, true);
    this.mouseButtonView.setUint8(17, e.button);
    this.mouseButtonView.setUint8(18, pressed ? 1 : 0);
    this.mouseButtonView.setUint8(19, this.getModifiers(e));
    this.ws!.send(this.mouseButtonBuffer);
  }

  private handleWheel(e: WheelEvent): void {
    e.preventDefault();
    if (!this.isWsOpen()) return;

    const rect = this.canvas.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;

    let dx = e.deltaX;
    let dy = e.deltaY;
    if (e.deltaMode === WHEEL_MODE.LINE) {
      dx *= PANEL.LINE_SCROLL_MULTIPLIER;
      dy *= PANEL.LINE_SCROLL_MULTIPLIER;
    } else if (e.deltaMode === WHEEL_MODE.PAGE) {
      dx *= this.canvas.clientWidth;
      dy *= this.canvas.clientHeight;
    }

    // Use pre-allocated buffer to avoid GC in hot path
    this.wheelView.setUint8(0, ClientMsg.MOUSE_SCROLL);
    this.wheelView.setFloat64(1, x, true);
    this.wheelView.setFloat64(9, y, true);
    this.wheelView.setFloat64(17, dx, true);
    this.wheelView.setFloat64(25, dy, true);
    this.wheelView.setUint8(33, this.getModifiers(e));
    this.ws!.send(this.wheelBuffer);
  }

  private getModifiers(e: KeyboardEvent | MouseEvent): number {
    let mods = 0;
    if (e.shiftKey) mods |= MODIFIER.SHIFT;
    if (e.ctrlKey) mods |= MODIFIER.CTRL;
    if (e.altKey) mods |= MODIFIER.ALT;
    if (e.metaKey) mods |= MODIFIER.META;
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

  isInspectorOpen(): boolean {
    return this.inspectorVisible;
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

    if (this.isWsOpen()) {
      const buf = new ArrayBuffer(1);
      new DataView(buf).setUint8(0, ClientMsg.PAUSE_STREAM);
      this.ws!.send(buf);
    }
  }

  show(): void {
    if (!this.paused) return;
    this.paused = false;

    if (this.isWsOpen()) {
      const buf = new ArrayBuffer(1);
      new DataView(buf).setUint8(0, ClientMsg.RESUME_STREAM);
      this.ws!.send(buf);
    }
  }

  // Decode a preview frame received via preview WebSocket
  decodePreviewFrame(frameData: Uint8Array): void {
    console.log(`Panel ${this.serverId}: decodePreviewFrame, decoder configured=${this.decoderConfigured}, gotFirstKeyframe=${this.gotFirstKeyframe}`);
    this.handleFrame(frameData.buffer.slice(frameData.byteOffset, frameData.byteOffset + frameData.byteLength) as ArrayBuffer);
  }

  handleInspectorState(state: unknown): void {
    if (state && typeof state === 'object') {
      this.inspectorState = state as Record<string, number>;
      this.renderInspectorSidebar();
      this.renderInspectorView();
    }
  }

  private renderInspectorSidebar(): void {
    // Cache sidebar element reference
    if (!this.inspectorSidebarEl) {
      this.inspectorSidebarEl = this.inspectorEl?.querySelector('.inspector-sidebar') as HTMLElement;
    }
    if (!this.inspectorSidebarEl || !this.inspectorState) return;

    const s = this.inspectorState;

    // Initialize HTML once and cache field element references
    if (!this.inspectorFieldEls) {
      this.inspectorSidebarEl.innerHTML = `
        <div class="inspector-simple-section">
          <span class="inspector-simple-title">Dimensions</span>
          <hr>
        </div>
        <div class="inspector-row"><span class="inspector-label">Screen Size</span><span class="inspector-value" data-field="screen-size"></span></div>
        <div class="inspector-row"><span class="inspector-label">Grid Size</span><span class="inspector-value" data-field="grid-size"></span></div>
        <div class="inspector-row"><span class="inspector-label">Cell Size</span><span class="inspector-value" data-field="cell-size"></span></div>
      `;
      this.inspectorFieldEls = {
        screenSize: this.inspectorSidebarEl.querySelector('[data-field="screen-size"]'),
        gridSize: this.inspectorSidebarEl.querySelector('[data-field="grid-size"]'),
        cellSize: this.inspectorSidebarEl.querySelector('[data-field="cell-size"]'),
      };
    }

    // Update cached elements directly
    if (this.inspectorFieldEls.screenSize) {
      this.inspectorFieldEls.screenSize.textContent = `${s.width_px ?? 0}px × ${s.height_px ?? 0}px`;
    }
    if (this.inspectorFieldEls.gridSize) {
      this.inspectorFieldEls.gridSize.textContent = `${s.cols ?? 0}c × ${s.rows ?? 0}r`;
    }
    if (this.inspectorFieldEls.cellSize) {
      this.inspectorFieldEls.cellSize.textContent = `${s.cell_width ?? 0}px × ${s.cell_height ?? 0}px`;
    }
  }

  private renderInspectorView(): void {
    // Cache main element reference
    if (!this.inspectorMainEl) {
      this.inspectorMainEl = this.inspectorEl?.querySelector('.inspector-main') as HTMLElement;
    }
    if (!this.inspectorMainEl) return;

    const s = this.inspectorState || {};

    this.inspectorMainEl.innerHTML = `
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
    if (!this.isWsOpen()) return;

    const textBytes = sharedTextEncoder.encode(text);
    const buf = new ArrayBuffer(1 + textBytes.length);
    const view = new Uint8Array(buf);
    view[0] = ClientMsg.TEXT_INPUT;
    view.set(textBytes, 1);
    this.ws!.send(buf);
  }

  destroy(): void {
    this.destroyed = true;

    // Clear pending timeouts
    if (this.connectTimeoutId) {
      clearTimeout(this.connectTimeoutId);
      this.connectTimeoutId = null;
    }

    if (this.resizeObserver) {
      this.resizeObserver.disconnect();
      this.resizeObserver = null;
    }

    // Remove canvas event listeners
    if (this.handleMouseDownBound) {
      this.canvas.removeEventListener('mousedown', this.handleMouseDownBound);
      this.handleMouseDownBound = null;
    }
    if (this.handleMouseUpBound) {
      this.canvas.removeEventListener('mouseup', this.handleMouseUpBound);
      this.handleMouseUpBound = null;
    }
    if (this.handleMouseMoveBound) {
      this.canvas.removeEventListener('mousemove', this.handleMouseMoveBound);
      this.handleMouseMoveBound = null;
    }
    if (this.handleWheelBound) {
      this.canvas.removeEventListener('wheel', this.handleWheelBound);
      this.handleWheelBound = null;
    }
    if (this.handleContextMenuBound) {
      this.canvas.removeEventListener('contextmenu', this.handleContextMenuBound);
      this.handleContextMenuBound = null;
    }

    if (this.documentClickHandler) {
      document.removeEventListener('click', this.documentClickHandler);
      this.documentClickHandler = null;
    }

    // Remove all inspector event listeners
    for (const { element, type, handler } of this.inspectorHandlers) {
      element.removeEventListener(type, handler);
    }
    this.inspectorHandlers = [];
    this.inspectorResizeHandler = null;

    // Remove document-level resize handlers if drag was in progress
    if (this.inspectorResizeMoveHandler) {
      document.removeEventListener('mousemove', this.inspectorResizeMoveHandler);
      this.inspectorResizeMoveHandler = null;
    }
    if (this.inspectorResizeUpHandler) {
      document.removeEventListener('mouseup', this.inspectorResizeUpHandler);
      this.inspectorResizeUpHandler = null;
    }

    // Clear cached inspector elements
    this.inspectorSidebarEl = null;
    this.inspectorMainEl = null;
    this.inspectorFieldEls = null;

    // Clear throttled handler
    this.throttledSendMouseMove = null;

    if (this.ws) {
      this.ws.close();
      this.ws = null;
    }

    if (this.decoder) {
      this.decoder.close();
      this.decoder = null;
    }

    // Clear circular buffers
    this.frameTimestamps.clear();
    this.decodeLatencies.clear();

    // Note: statsOverlay is shared/static, don't remove it

    if (this.element.parentElement) {
      this.element.parentElement.removeChild(this.element);
    }
  }
}
