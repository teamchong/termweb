<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import { ClientMsg } from '../protocol';
  import type { PanelStatus } from '../stores/types';
  import { sharedTextEncoder, CircularBuffer, throttle } from '../utils';
  import { PANEL, TIMING, UI, NAL, MODIFIER, WHEEL_MODE, STATS_THRESHOLD } from '../constants';
  import { initWebGPURenderer, type WebGPUFrameRenderer } from '../webgpu-renderer';

  // ============================================================================
  // Props
  // ============================================================================

  interface Props {
    id: string;
    serverId?: number | null;
    inheritCwdFrom?: number | null;
    initialSize?: { width: number; height: number } | null;
    splitInfo?: { parentPanelId: number; direction: 'right' | 'down' | 'left' | 'up' } | null;
    isQuickTerminal?: boolean;
    onStatusChange?: (status: PanelStatus) => void;
    onTitleChange?: (title: string) => void;
    onPwdChange?: (pwd: string) => void;
    onServerIdAssigned?: (serverId: number) => void;
    onActivate?: () => void;
  }

  let {
    id,
    serverId = null,
    inheritCwdFrom = null,
    initialSize = null,
    splitInfo = null,
    isQuickTerminal = false,
    onStatusChange,
    onTitleChange,
    onPwdChange,
    onServerIdAssigned,
    onActivate,
  }: Props = $props();

  // ============================================================================
  // Reactive State
  // ============================================================================

  let status = $state<PanelStatus>('disconnected');
  let pwd = $state('');
  let destroyed = $state(false);
  let paused = $state(false);

  // Inspector state
  let inspectorVisible = $state(false);
  let inspectorHeight = $state(PANEL.DEFAULT_INSPECTOR_HEIGHT);
  let inspectorActiveTab = $state(UI.DEFAULT_INSPECTOR_TAB);
  let inspectorState = $state<Record<string, number> | null>(null);
  let inspectorLeftHeaderHidden = $state(false);
  let inspectorRightHeaderHidden = $state(false);
  let dockMenuVisible = $state<'left' | 'right' | null>(null);

  // Stats
  let pendingDecode = $state(0);
  let displayedFps = $state(0);
  let displayedLatency = $state(0);
  let displayedHealth = $state(100);
  let displayedReceivedFps = $state(0);
  let renderedFrames = $state(0);
  let lastStatsUpdate = $state(0);


  // ============================================================================
  // DOM References
  // ============================================================================

  let panelEl: HTMLElement | undefined = $state();
  let canvasEl: HTMLCanvasElement | undefined = $state();
  let loadingEl: HTMLElement | undefined = $state();
  let inspectorEl: HTMLElement | undefined = $state();

  // ============================================================================
  // Internal State (non-reactive for performance)
  // ============================================================================

  let controlWsSend: ((msg: ArrayBuffer | ArrayBufferView) => void) | null = null;
  let decoder: VideoDecoder | null = null;
  let snapshotCanvas: HTMLCanvasElement | undefined;
  let snapshotCtx: CanvasRenderingContext2D | null = null;
  let lastSnapshotTime = 0;
  const SNAPSHOT_INTERVAL = 500;
  let decoderConfigured = false;
  let lastCodec: string | null = null;
  let gotFirstKeyframe = false;
  let frameCount = 0;
  let gpuRenderer: WebGPUFrameRenderer | null = null;
  let cachedFrame: VideoFrame | null = null;
  // Buffer raw H264 frame data until gpuRenderer is ready — prevents hardware
  // decoder surface exhaustion by not submitting frames for decode before we
  // can consume VideoFrame output. Keeps latest keyframe + subsequent deltas.
  let rawFrameBuffer: ArrayBuffer[] = [];
  let lastReportedWidth = 0;
  let lastReportedHeight = 0;
  let resizeObserver: ResizeObserver | null = null;
  let lastBufferReport = 0;
  let frameTimestamps = new CircularBuffer<number>(60);
  let decodeLatencies = new CircularBuffer<number>(PANEL.MAX_LATENCY_SAMPLES);
  let lastDecodeStart = 0;
  let lastRenderedTime = 0;
  let connectTimeoutId: ReturnType<typeof setTimeout> | null = null;
  // These are intentionally copied from props - we want mutable local copies
  let _initialSize: { width: number; height: number } | null = null;
  let _splitInfo: { parentPanelId: number; direction: 'right' | 'down' | 'left' | 'up' } | null = null;
  let _serverId: number | null = null;
  // Copy initial values immediately (before any effects run)
  $effect.pre(() => {
    if (_initialSize === null && initialSize !== null) _initialSize = initialSize;
    if (_splitInfo === null && splitInfo !== null) _splitInfo = splitInfo;
    if (_serverId === null && serverId !== null) _serverId = serverId;
  });

  // Pre-allocated buffers for hot paths
  const mouseMoveBuffer = new ArrayBuffer(18);
  const mouseMoveView = new DataView(mouseMoveBuffer);
  const mouseButtonBuffer = new ArrayBuffer(20);
  const mouseButtonView = new DataView(mouseButtonBuffer);
  const wheelBuffer = new ArrayBuffer(34);
  const wheelView = new DataView(wheelBuffer);
  const resizeBuffer = new ArrayBuffer(5);
  const resizeView = new DataView(resizeBuffer);

  // Throttled mouse move
  let throttledSendMouseMove: ((x: number, y: number, mods: number) => void) | null = null;

  // Inspector resize drag state
  let resizeDragStartY = 0;
  let resizeDragStartHeight = 0;

  // Debug mode
  const debugEnabled = typeof window !== 'undefined' && (
    window.location.hash.includes('debug') || window.location.search.includes('debug')
  );

  // ============================================================================
  // Computed
  // ============================================================================

  // Computed inspector dimensions for sidebar
  let screenSizeText = $derived(
    inspectorState ? `${inspectorState.width_px ?? 0}px × ${inspectorState.height_px ?? 0}px` : ''
  );
  let gridSizeText = $derived(
    inspectorState ? `${inspectorState.cols ?? 0}c × ${inspectorState.rows ?? 0}r` : ''
  );
  let cellSizeText = $derived(
    inspectorState ? `${inspectorState.cell_width ?? 0}px × ${inspectorState.cell_height ?? 0}px` : ''
  );

  // Cursor state from server (surface-space pixel coordinates)
  let cursorX = $state(0);
  let cursorY = $state(0);
  let cursorW = $state(0);
  let cursorH = $state(0);
  let cursorStyle = $state(1); // 0=bar, 1=block, 2=underline, 3=block_hollow
  let cursorVisible = $state(true);
  // Server surface dimensions — the coordinate space cursor values live in
  let cursorSurfW = $state(0);
  let cursorSurfH = $state(0);

  // Reactive canvas buffer dimensions (encoder-aligned) — updated from video frames.
  let frameWidth = $state(0);
  let frameHeight = $state(0);

  // Cursor overlay position: percentage-based within a CSS viewport div that
  // replicates the canvas's object-fit:contain area using container queries.
  // No JS objFitScale math — CSS handles the contain-fit sizing identically.
  let cursorPct = $derived.by(() => {
    if (!cursorVisible || cursorW === 0 || paused) return null;
    if (frameWidth === 0 || frameHeight === 0) return null;

    return {
      left: (cursorX / frameWidth) * 100,
      top: (cursorY / frameHeight) * 100,
      width: (cursorW / frameWidth) * 100,
      height: (cursorH / frameHeight) * 100,
    };
  });

  // ============================================================================
  // WebSocket Helpers
  // ============================================================================

  /** Check if send path is available (control WS via PANEL_MSG envelope) */
  function canSendInput(): boolean {
    return controlWsSend !== null;
  }

  /** Send input via control WS (PANEL_MSG envelope) */
  function sendInput(buf: ArrayBuffer | ArrayBufferView): void {
    controlWsSend?.(buf);
  }

  export function setControlWsSend(fn: ((msg: ArrayBuffer | ArrayBufferView) => void) | null): void {
    controlWsSend = fn;
  }

  function setStatus(newStatus: PanelStatus): void {
    if (status === newStatus) return;
    status = newStatus;
    onStatusChange?.(newStatus);
  }

  // ============================================================================
  // Decoder
  // ============================================================================

  function initDecoder(): void {
    decoder = new VideoDecoder({
      output: (frame) => onFrame(frame),
      error: (e) => {
        console.error('[Panel] decoder error callback:', e, 'message:', e.message, 'state:', decoder?.state);
        pendingDecode = 0;
        if (decoder && decoder.state !== 'closed') {
          decoder.reset();
          decoderConfigured = false;
          gotFirstKeyframe = false;
        }
        requestKeyframe('decoder_error');
      },
    });

  }

  function renderFrame(frame: VideoFrame): void {
    if (canvasEl && (canvasEl.width !== frame.displayWidth || canvasEl.height !== frame.displayHeight)) {
      canvasEl.width = frame.displayWidth;
      canvasEl.height = frame.displayHeight;
    }
    // Update reactive frame dimensions so cursorPct recomputes
    if (frameWidth !== frame.displayWidth || frameHeight !== frame.displayHeight) {
      frameWidth = frame.displayWidth;
      frameHeight = frame.displayHeight;
    }

    gpuRenderer!.renderFrame(frame);

    // Update snapshot for tab overview (throttled, before frame.close())
    const now = performance.now();
    if (now - lastSnapshotTime > SNAPSHOT_INTERVAL) {
      lastSnapshotTime = now;
      if (!snapshotCanvas) {
        snapshotCanvas = document.createElement('canvas');
      }
      if (snapshotCanvas.width !== frame.displayWidth || snapshotCanvas.height !== frame.displayHeight) {
        snapshotCanvas.width = frame.displayWidth;
        snapshotCanvas.height = frame.displayHeight;
        snapshotCtx = snapshotCanvas.getContext('2d');
      }
      snapshotCtx?.drawImage(frame, 0, 0);
    }

    frame.close();

    // Hide loading
    if (loadingEl) {
      loadingEl.remove();
      loadingEl = undefined;
    }

    lastRenderedTime = performance.now();
    renderedFrames++;
    updateStatsOverlay();
  }

  function onFrame(frame: VideoFrame): void {
    pendingDecode--;

    if (destroyed) {
      frame.close();
      return;
    }

    // Renderer not ready yet — cache latest frame so it renders instantly
    // when WebGPU init completes (avoids missing the only keyframe)
    if (!gpuRenderer) {
      if (cachedFrame) cachedFrame.close();
      cachedFrame = frame;
      return;
    }

    // Measure actual decode queue latency using frame timestamp roundtrip
    // (timestamp was set to performance.now()*1000 at submit time)
    const submitTimeUs = frame.timestamp;
    const nowUs = performance.now() * 1000;
    const decodeMs = (nowUs - submitTimeUs) / 1000;
    if (decodeMs > 0 && decodeMs < 10000) {
      decodeLatencies.push(decodeMs);
    }

    renderFrame(frame);
  }

  function parseNalUnits(data: Uint8Array): Uint8Array[] {
    const units: Uint8Array[] = [];
    let start = 0;

    for (let i = 0; i < data.length - 3; i++) {
      if (data[i] === 0 && data[i + 1] === 0 && data[i + 2] === 0 && data[i + 3] === 1) {
        if (i > start) {
          units.push(data.slice(start, i));
        }
        start = i + 4;
        i += 3;
      }
    }

    if (start < data.length) {
      units.push(data.slice(start));
    }

    return units;
  }

  function getCodecFromSps(sps: Uint8Array): string {
    if (sps.length < 4) return PANEL.DEFAULT_H264_CODEC;
    const profile = sps[1];
    const constraints = sps[2];
    const level = sps[3];
    return `avc3.${profile.toString(16).padStart(2, '0')}${constraints.toString(16).padStart(2, '0')}${level.toString(16).padStart(2, '0')}`;
  }

  function handleFrame(data: ArrayBuffer): void {
    if (destroyed) return;

    // Buffer raw frames until renderer is ready — prevents hardware decoder
    // surface exhaustion by not submitting frames before we can consume output.
    if (!gpuRenderer) {
      const peek = new Uint8Array(data);
      let isKey = false;
      for (let i = 0; i < peek.length - 4; i++) {
        if (peek[i] === 0 && peek[i + 1] === 0 && peek[i + 2] === 0 && peek[i + 3] === 1) {
          if (((peek[i + 4] ?? 0) & NAL.TYPE_MASK) === NAL.TYPE_IDR) { isKey = true; break; }
        }
      }
      if (isKey) {
        rawFrameBuffer = [data]; // new keyframe — discard everything before
      } else if (rawFrameBuffer.length > 0) {
        rawFrameBuffer.push(data); // delta after keyframe — keep
      }
      // deltas before any keyframe are discarded
      return;
    }

    frameTimestamps.push(performance.now());
    const frameData = new Uint8Array(data);

    if (!decoder) { console.debug('[Panel] handleFrame: no decoder'); return; }

    // Parse NAL units to detect SPS/PPS/IDR
    const nalUnits = parseNalUnits(frameData);
    let isKeyframe = false;
    let sps: Uint8Array | null = null;

    for (const nal of nalUnits) {
      if (nal.length === 0) continue;
      const nalType = nal[0] & NAL.TYPE_MASK;
      if (nalType === NAL.TYPE_SPS) sps = nal;
      else if (nalType === NAL.TYPE_IDR) isKeyframe = true;
    }

    // Configure decoder with avc3 codec (SPS/PPS in-band via Annex B, no description needed).
    if (sps) {
      const codec = getCodecFromSps(sps);
      const needReconfigure = !decoderConfigured || codec !== lastCodec;
      if (needReconfigure) {
        try {
          if (decoderConfigured) {
            decoder.reset();
            gotFirstKeyframe = false;
          }
          decoder.configure({
            codec,
            optimizeForLatency: true,
            hardwareAcceleration: 'prefer-hardware',
            avc: { format: 'annexb' },
          } as VideoDecoderConfig);
          decoderConfigured = true;
          lastCodec = codec;
          console.log(`[Panel] decoder configured: ${codec}`);
        } catch (e) {
          console.error('Failed to configure decoder:', e);
          setStatus('error');
          return;
        }
      }
    }

    if (!decoderConfigured) { console.debug('[Panel] handleFrame: decoder not configured'); return; }

    if (!gotFirstKeyframe) {
      if (!isKeyframe) { console.debug('[Panel] handleFrame: waiting for first keyframe'); return; }
      gotFirstKeyframe = true;
    }

    // Drop P-frames when decode queue is too deep (reduces pipeline latency).
    if (!isKeyframe && decoder && decoder.decodeQueueSize > 2) {
      requestKeyframe(`queue_overflow_queueSize=${decoder.decodeQueueSize}`);
      return;
    }

    if (isKeyframe) {
      keyframeRequested = false;
    }

    decodeFrame(frameData, isKeyframe);
    checkBufferHealth();
  }

  function decodeFrame(data: Uint8Array, isKeyframe: boolean): void {
    if (!decoder || decoder.state !== 'configured') {
      console.warn(`[Panel] decodeFrame skipped: decoder=${decoder ? decoder.state : 'null'}`);
      return;
    }

    // Use real time as timestamp so we can measure decode latency in onFrame()
    const timestamp = performance.now() * 1000; // microseconds
    frameCount++;
    pendingDecode++;

    try {
      const chunk = new EncodedVideoChunk({
        type: isKeyframe ? 'key' : 'delta',
        timestamp,
        data,
      });
      decoder.decode(chunk);
    } catch (e) {
      console.error('[Panel] decoder.decode() threw:', e);
      pendingDecode--;
      setStatus('error');
    }
  }

  function checkBufferHealth(): void {
    if (!canSendInput()) return;

    const now = performance.now();
    const oneSecondAgo = now - TIMING.FPS_CALCULATION_WINDOW;
    const receivedFps = frameTimestamps.filterRecent(oneSecondAgo, (a, b) => a - b).length;
    const health = Math.max(0, PANEL.MAX_BUFFER_HEALTH - pendingDecode * PANEL.HEALTH_PENALTY_PER_PENDING);

    if (now - lastBufferReport > TIMING.BUFFER_STATS_INTERVAL) {
      sendBufferStats(health, receivedFps);
      lastBufferReport = now;
    }
  }

  let keyframeRequested = false;

  function requestKeyframe(reason: string): void {
    if (keyframeRequested || !canSendInput()) return;
    keyframeRequested = true;
    const buf = new Uint8Array([ClientMsg.REQUEST_KEYFRAME]);
    sendInput(buf);
  }

  function sendBufferStats(health: number, fps: number): void {
    if (!canSendInput()) return;

    const buf = new ArrayBuffer(5);
    const view = new DataView(buf);
    view.setUint8(0, ClientMsg.BUFFER_STATS);
    view.setUint8(1, Math.round(health));
    view.setUint8(2, Math.round(fps));
    view.setUint16(3, pendingDecode * PANEL.APPROX_FRAME_DURATION_MS, true);
    sendInput(buf);
  }

  // ============================================================================
  // Stats Overlay (debug mode)
  // ============================================================================

  function updateStatsOverlay(): void {
    if (!debugEnabled) return;

    const now = performance.now();

    if (now - lastStatsUpdate > TIMING.STATS_UPDATE_INTERVAL) {
      displayedFps = renderedFrames * 2;
      renderedFrames = 0;
      lastStatsUpdate = now;

      // Calculate average decode latency
      const latencies = decodeLatencies.getAll();
      if (latencies.length > 0) {
        const sum = latencies.reduce((a, b) => a + b, 0);
        displayedLatency = Math.round(sum / latencies.length);
      }

      // Calculate received FPS
      const oneSecondAgo = now - TIMING.FPS_CALCULATION_WINDOW;
      displayedReceivedFps = frameTimestamps.filterRecent(oneSecondAgo, (a, b) => a - b).length;

      // Calculate health
      displayedHealth = Math.max(0, PANEL.MAX_BUFFER_HEALTH - pendingDecode * PANEL.HEALTH_PENALTY_PER_PENDING);
    }
  }

  // ============================================================================
  // WebSocket Connection
  // ============================================================================

  export function connect(): void {
    if (!canSendInput()) return;
    setStatus('connected');

    if (_serverId !== null) {
      // Reconnecting to existing panel — send resize after DOM settles
      connectTimeoutId = setTimeout(() => {
        connectTimeoutId = null;
        if (destroyed || !panelEl) return;
        const rect = panelEl.getBoundingClientRect();
        const width = Math.floor(rect.width);
        const height = Math.floor(rect.height);
        if (width > 0 && height > 0) {
          lastReportedWidth = width;
          lastReportedHeight = height;
          sendResizeBinary(width, height);
        }
      }, 0);
    } else if (_splitInfo) {
      sendSplitPanel();
    } else {
      sendCreatePanel();
    }
  }

  function sendCreatePanel(): void {
    if (!canSendInput()) return;

    let width: number, height: number;
    if (_initialSize) {
      width = _initialSize.width;
      height = _initialSize.height;
      _initialSize = null;
    } else if (panelEl) {
      const rect = panelEl.getBoundingClientRect();
      width = Math.floor(rect.width) || PANEL.DEFAULT_WIDTH;
      height = Math.floor(rect.height) || PANEL.DEFAULT_HEIGHT;
    } else {
      width = PANEL.DEFAULT_WIDTH;
      height = PANEL.DEFAULT_HEIGHT;
    }
    const scale = window.devicePixelRatio || 1;

    lastReportedWidth = width;
    lastReportedHeight = height;

    const buf = new ArrayBuffer(14);
    const view = new DataView(buf);
    view.setUint8(0, ClientMsg.CREATE_PANEL);
    view.setUint16(1, width, true);
    view.setUint16(3, height, true);
    view.setFloat32(5, scale, true);
    view.setUint32(9, inheritCwdFrom ?? 0, true);
    view.setUint8(13, isQuickTerminal ? 1 : 0);
    sendInput(buf);
  }

  function sendSplitPanel(): void {
    if (!canSendInput() || !_splitInfo) return;

    let width: number, height: number;
    if (_initialSize) {
      width = _initialSize.width;
      height = _initialSize.height;
      _initialSize = null;
    } else if (panelEl) {
      const rect = panelEl.getBoundingClientRect();
      width = Math.floor(rect.width) || PANEL.DEFAULT_WIDTH;
      height = Math.floor(rect.height) || PANEL.DEFAULT_HEIGHT;
    } else {
      width = PANEL.DEFAULT_WIDTH;
      height = PANEL.DEFAULT_HEIGHT;
    }
    const scale = window.devicePixelRatio || 1;

    lastReportedWidth = width;
    lastReportedHeight = height;

    const isVertical = _splitInfo.direction === 'down' || _splitInfo.direction === 'up';
    const dirByte = isVertical ? 1 : 0;

    const buf = new ArrayBuffer(12);
    const view = new DataView(buf);
    view.setUint8(0, ClientMsg.SPLIT_PANEL);
    view.setUint32(1, _splitInfo.parentPanelId, true);
    view.setUint8(5, dirByte);
    view.setUint16(6, width, true);
    view.setUint16(8, height, true);
    view.setUint16(10, Math.round(scale * 100), true);
    sendInput(buf);
    _splitInfo = null;
  }

  function sendResizeBinary(width: number, height: number): void {
    if (!canSendInput()) return;

    resizeView.setUint8(0, ClientMsg.RESIZE);
    resizeView.setUint16(1, width, true);
    resizeView.setUint16(3, height, true);
    sendInput(resizeBuffer);
  }

  // ============================================================================
  // Input Handling
  // ============================================================================

  function getModifiers(e: KeyboardEvent | MouseEvent): number {
    let mods = 0;
    if (e.shiftKey) mods |= MODIFIER.SHIFT;
    if (e.ctrlKey) mods |= MODIFIER.CTRL;
    if (e.altKey) mods |= MODIFIER.ALT;
    if (e.metaKey) mods |= MODIFIER.META;
    return mods;
  }

  export function sendKeyInput(e: KeyboardEvent, action: number): void {
    if (!canSendInput()) return;

    const codeBytes = sharedTextEncoder.encode(e.code);
    const text = (e.key.length === 1) ? e.key : '';
    const textBytes = sharedTextEncoder.encode(text);

    const buf = new ArrayBuffer(5 + codeBytes.length + textBytes.length);
    const view = new Uint8Array(buf);
    view[0] = ClientMsg.KEY_INPUT;
    view[1] = action;
    view[2] = getModifiers(e);
    view[3] = codeBytes.length;
    view.set(codeBytes, 4);
    view[4 + codeBytes.length] = textBytes.length;
    view.set(textBytes, 5 + codeBytes.length);
    sendInput(buf);
  }

  function handleMouseDown(e: MouseEvent): void {
    panelEl?.focus();
    onActivate?.();
    sendMouseButton(e, true);
  }

  function handleMouseUp(e: MouseEvent): void {
    sendMouseButton(e, false);
  }

  function handleMouseMove(e: MouseEvent): void {
    if (!canSendInput() || !canvasEl) return;

    const rect = canvasEl.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;
    const mods = getModifiers(e);

    throttledSendMouseMove?.(x, y, mods);
  }

  function sendMouseMoveInternal(x: number, y: number, mods: number): void {
    if (!canSendInput()) return;

    mouseMoveView.setUint8(0, ClientMsg.MOUSE_MOVE);
    mouseMoveView.setFloat64(1, x, true);
    mouseMoveView.setFloat64(9, y, true);
    mouseMoveView.setUint8(17, mods);
    sendInput(mouseMoveBuffer);
  }

  function sendMouseButton(e: MouseEvent, pressed: boolean): void {
    if (!canSendInput() || !canvasEl) return;

    const rect = canvasEl.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;

    mouseButtonView.setUint8(0, ClientMsg.MOUSE_INPUT);
    mouseButtonView.setFloat64(1, x, true);
    mouseButtonView.setFloat64(9, y, true);
    mouseButtonView.setUint8(17, e.button);
    mouseButtonView.setUint8(18, pressed ? 1 : 0);
    mouseButtonView.setUint8(19, getModifiers(e));
    sendInput(mouseButtonBuffer);
  }

  function handleWheel(e: WheelEvent): void {
    e.preventDefault();
    if (!canSendInput() || !canvasEl) return;

    const rect = canvasEl.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;

    let dx = e.deltaX;
    let dy = e.deltaY;
    if (e.deltaMode === WHEEL_MODE.LINE) {
      dx *= PANEL.LINE_SCROLL_MULTIPLIER;
      dy *= PANEL.LINE_SCROLL_MULTIPLIER;
    } else if (e.deltaMode === WHEEL_MODE.PAGE) {
      dx *= canvasEl.clientWidth;
      dy *= canvasEl.clientHeight;
    }

    wheelView.setUint8(0, ClientMsg.MOUSE_SCROLL);
    wheelView.setFloat64(1, x, true);
    wheelView.setFloat64(9, y, true);
    wheelView.setFloat64(17, dx, true);
    wheelView.setFloat64(25, dy, true);
    wheelView.setUint8(33, getModifiers(e));
    sendInput(wheelBuffer);
  }

  function handleContextMenu(e: Event): void {
    e.preventDefault();
  }

  // ============================================================================
  // Inspector
  // ============================================================================

  function triggerResize(): void {
    requestAnimationFrame(() => {
      if (!canvasEl) return;
      const rect = canvasEl.getBoundingClientRect();
      const width = Math.floor(rect.width);
      const height = Math.floor(rect.height);
      if (width > 0 && height > 0) {
        lastReportedWidth = width;
        lastReportedHeight = height;
        sendResizeBinary(width, height);
      }
    });
  }

  function handleInspectorResizeStart(e: MouseEvent): void {
    resizeDragStartY = e.clientY;
    resizeDragStartHeight = inspectorHeight;
    document.addEventListener('mousemove', handleInspectorResizeMove);
    document.addEventListener('mouseup', handleInspectorResizeEnd);
  }

  function handleInspectorResizeMove(e: MouseEvent): void {
    if (!panelEl) return;
    const delta = resizeDragStartY - e.clientY;
    const maxHeight = panelEl.clientHeight * PANEL.MAX_INSPECTOR_HEIGHT_RATIO;
    inspectorHeight = Math.min(Math.max(resizeDragStartHeight + delta, PANEL.MIN_INSPECTOR_HEIGHT), maxHeight);
  }

  function handleInspectorResizeEnd(): void {
    document.removeEventListener('mousemove', handleInspectorResizeMove);
    document.removeEventListener('mouseup', handleInspectorResizeEnd);
    triggerResize();
  }

  function handleDockIconClick(panel: 'left' | 'right', e: MouseEvent): void {
    e.stopPropagation();
    dockMenuVisible = dockMenuVisible === panel ? null : panel;
  }

  function handleHideHeader(panel: 'left' | 'right'): void {
    if (panel === 'left') {
      inspectorLeftHeaderHidden = true;
    } else {
      inspectorRightHeaderHidden = true;
    }
    dockMenuVisible = null;
  }

  function handleShowHeader(panel: 'left' | 'right'): void {
    if (panel === 'left') {
      inspectorLeftHeaderHidden = false;
    } else {
      inspectorRightHeaderHidden = false;
    }
  }

  function handleDocumentClick(): void {
    dockMenuVisible = null;
  }

  // ============================================================================
  // Public API
  // ============================================================================

  export function setServerId(newId: number): void {
    _serverId = newId;
  }

  export function getServerId(): number | null {
    return _serverId;
  }

  export function focus(): void {
    panelEl?.focus();
  }

  export function getElement(): HTMLElement | undefined {
    return panelEl;
  }

  export function getCanvas(): HTMLCanvasElement | undefined {
    return canvasEl;
  }

  export function getSnapshotCanvas(): HTMLCanvasElement | undefined {
    return snapshotCanvas;
  }

  export function toggleInspector(visible?: boolean): void {
    const newVisible = visible ?? !inspectorVisible;
    if (newVisible) {
      showInspector();
    } else {
      hideInspector();
    }
  }

  export function isInspectorOpen(): boolean {
    return inspectorVisible;
  }

  function showInspector(): void {
    inspectorVisible = true;
    if (canSendInput()) {
      const tab = sharedTextEncoder.encode(inspectorActiveTab);
      const buf = new ArrayBuffer(2 + tab.length);
      const view = new DataView(buf);
      view.setUint8(0, ClientMsg.INSPECTOR_SUBSCRIBE);
      view.setUint8(1, tab.length);
      new Uint8Array(buf).set(tab, 2);
      sendInput(buf);
    }
    triggerResize();
  }

  function hideInspector(): void {
    inspectorVisible = false;
    if (canSendInput()) {
      const buf = new ArrayBuffer(1);
      new DataView(buf).setUint8(0, ClientMsg.INSPECTOR_UNSUBSCRIBE);
      sendInput(buf);
    }
    triggerResize();
  }

  export function hide(): void {
    if (paused) return;
    paused = true;

    if (canSendInput()) {
      const buf = new ArrayBuffer(1);
      new DataView(buf).setUint8(0, ClientMsg.PAUSE_STREAM);
      sendInput(buf);
    }
  }

  export function show(): void {
    if (!paused) return;
    paused = false;

    if (canSendInput()) {
      const buf = new ArrayBuffer(1);
      new DataView(buf).setUint8(0, ClientMsg.RESUME_STREAM);
      sendInput(buf);
    }
  }

  export function decodePreviewFrame(frameData: Uint8Array): void {
    handleFrame(frameData.buffer.slice(frameData.byteOffset, frameData.byteOffset + frameData.byteLength) as ArrayBuffer);
  }

  export function handleInspectorState(state: unknown): void {
    if (state && typeof state === 'object') {
      inspectorState = state as Record<string, number>;
    }
  }

  export function sendTextInput(text: string): void {
    if (!canSendInput()) return;

    const textBytes = sharedTextEncoder.encode(text);
    const buf = new ArrayBuffer(1 + textBytes.length);
    const view = new Uint8Array(buf);
    view[0] = ClientMsg.TEXT_INPUT;
    view.set(textBytes, 1);
    sendInput(buf);
  }

  export function getStatus(): PanelStatus {
    return status;
  }

  export function getPwd(): string {
    return pwd;
  }

  export function setPwd(newPwd: string): void {
    pwd = newPwd;
    onPwdChange?.(newPwd);
  }

  export function updateCursorState(x: number, y: number, w: number, h: number, style: number, visible: boolean, totalW: number, totalH: number): void {
    cursorX = x;
    cursorY = y;
    cursorW = w;
    cursorH = h;
    cursorStyle = style;
    cursorVisible = visible;
    cursorSurfW = totalW;
    cursorSurfH = totalH;
  }

  // ============================================================================
  // Lifecycle
  // ============================================================================

  onMount(() => {
    if (!canvasEl || !navigator.gpu) {
      setStatus('error');
      console.error('WebGPU is required but not available in this browser.');
      return;
    }

    // Decoder starts immediately so early frames are cached (not dropped).
    // WebGPU init is async — cached frames render once the renderer is ready.
    initDecoder();

    initWebGPURenderer(canvasEl).then((renderer) => {
      if (destroyed) return;
      if (!renderer) {
        setStatus('error');
        console.error('WebGPU renderer initialization failed.');
        return;
      }
      gpuRenderer = renderer;

      // Renderer is ready — remove Loading overlay immediately.
      // A blank canvas is acceptable; an indefinite spinner is not.
      if (loadingEl) {
        loadingEl.remove();
        loadingEl = undefined;
      }

      // Flush raw H264 frames buffered while renderer was initializing.
      // These are decoded now so the hardware decoder output surfaces are
      // consumed immediately by the ready renderer.
      if (rawFrameBuffer.length > 0) {
        const frames = rawFrameBuffer;
        rawFrameBuffer = [];
        for (const frameData of frames) {
          handleFrame(frameData);
        }
      }

      // Flush any cached decoded frame (safety net, should not happen with buffering)
      if (cachedFrame) {
        renderFrame(cachedFrame);
        cachedFrame = null;
      }
    });

    // Initialize throttled mouse move
    throttledSendMouseMove = throttle((x: number, y: number, mods: number) => {
      sendMouseMoveInternal(x, y, mods);
    }, PANEL.APPROX_FRAME_DURATION_MS);

    // Setup resize observer
    if (panelEl) {
      resizeObserver = new ResizeObserver(() => {
        requestAnimationFrame(() => {
          if (!panelEl || paused) return;
          const rect = panelEl.getBoundingClientRect();
          const width = Math.floor(rect.width);
          const height = Math.floor(rect.height);

          if (width === 0 || height === 0) return;
          if (width === lastReportedWidth && height === lastReportedHeight) return;

          lastReportedWidth = width;
          lastReportedHeight = height;
          sendResizeBinary(width, height);
        });
      });
      resizeObserver.observe(panelEl);
    }

    // Document click handler for dock menu
    document.addEventListener('click', handleDocumentClick);
  });

  onDestroy(() => {
    destroyed = true;

    // Clear pending timeouts
    if (connectTimeoutId) {
      clearTimeout(connectTimeoutId);
      connectTimeoutId = null;
    }
    // Cleanup resize observer
    if (resizeObserver) {
      resizeObserver.disconnect();
      resizeObserver = null;
    }

    // Cleanup cached frame
    if (cachedFrame) {
      cachedFrame.close();
      cachedFrame = null;
    }
    rawFrameBuffer = [];

    // Cleanup decoder
    if (decoder) {
      decoder.close();
      decoder = null;
    }

    // Cleanup WebGPU renderer
    if (gpuRenderer) {
      gpuRenderer.dispose();
      gpuRenderer = null;
    }

    // Clear circular buffers
    frameTimestamps.clear();
    decodeLatencies.clear();

    // Cleanup document listeners
    document.removeEventListener('click', handleDocumentClick);
    document.removeEventListener('mousemove', handleInspectorResizeMove);
    document.removeEventListener('mouseup', handleInspectorResizeEnd);

    // Clear throttled handler
    throttledSendMouseMove = null;
  });
</script>

<!-- svelte-ignore a11y_no_noninteractive_tabindex -->
<div class="panel-root" bind:this={panelEl} tabindex={PANEL.CANVAS_TAB_INDEX}>
  <div class="panel-content">
    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <canvas
      class="panel-canvas"
      bind:this={canvasEl}
      onmousedown={handleMouseDown}
      onmouseup={handleMouseUp}
      onmousemove={handleMouseMove}
      onwheel={handleWheel}
      oncontextmenu={handleContextMenu}
    ></canvas>
    {#if frameWidth > 0 && frameHeight > 0}
      <div class="cursor-container" style="--fw:{frameWidth};--fh:{frameHeight}">
        <div class="cursor-viewport">
          {#if cursorPct}
            <div
              class="cursor-overlay"
              class:cursor-bar={cursorStyle === 0}
              class:cursor-block={cursorStyle === 1}
              class:cursor-underline={cursorStyle === 2}
              class:cursor-hollow={cursorStyle === 3}
              style="left:{cursorPct.left}%;top:{cursorPct.top}%;width:{cursorPct.width}%;height:{cursorPct.height}%"
            ></div>
          {/if}
        </div>
      </div>
    {/if}
    <div class="panel-loading" bind:this={loadingEl}>
      <div class="spinner"></div>
      <span>Loading...</span>
    </div>
    {#if debugEnabled}
      <div class="panel-stats">
        <span class="stat" class:good={displayedFps >= STATS_THRESHOLD.FPS_GOOD} class:warn={displayedFps < STATS_THRESHOLD.FPS_GOOD && displayedFps >= STATS_THRESHOLD.FPS_WARN} class:bad={displayedFps < STATS_THRESHOLD.FPS_WARN}>FPS: {displayedFps}</span>
        <span class="stat">Queue: {pendingDecode}</span>
        <span class="stat" class:good={displayedLatency <= STATS_THRESHOLD.LATENCY_GOOD} class:warn={displayedLatency > STATS_THRESHOLD.LATENCY_GOOD && displayedLatency <= STATS_THRESHOLD.LATENCY_WARN} class:bad={displayedLatency > STATS_THRESHOLD.LATENCY_WARN}>Decode: {displayedLatency}ms</span>
        <span class="stat" class:good={displayedHealth >= STATS_THRESHOLD.HEALTH_GOOD} class:warn={displayedHealth < STATS_THRESHOLD.HEALTH_GOOD && displayedHealth >= STATS_THRESHOLD.HEALTH_WARN} class:bad={displayedHealth < STATS_THRESHOLD.HEALTH_WARN}>Health: {displayedHealth}%</span>
      </div>
    {/if}
  </div>

  <div
    class="panel-inspector"
    class:visible={inspectorVisible}
    style="height: {inspectorHeight}px"
    bind:this={inspectorEl}
  >
    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <div class="inspector-resize" onmousedown={handleInspectorResizeStart}></div>
    <div class="inspector-content">
      <div class="inspector-left" class:header-hidden={inspectorLeftHeaderHidden}>
        <div class="inspector-left-header">
          <!-- svelte-ignore a11y_no_static_element_interactions -->
          <!-- svelte-ignore a11y_click_events_have_key_events -->
          <div class="inspector-dock-wrapper">
            <span class="inspector-dock-icon" onclick={(e) => handleDockIconClick('left', e)}></span>
            <div class="inspector-dock-menu" class:visible={dockMenuVisible === 'left'}>
              <!-- svelte-ignore a11y_no_static_element_interactions -->
              <!-- svelte-ignore a11y_click_events_have_key_events -->
              <div class="inspector-dock-menu-item" onclick={() => handleHideHeader('left')}>Hide Tab Bar</div>
            </div>
          </div>
          <div class="inspector-tabs">
            <button class="inspector-tab active" data-tab="screen">Screen</button>
          </div>
        </div>
        <!-- svelte-ignore a11y_no_static_element_interactions -->
        <!-- svelte-ignore a11y_click_events_have_key_events -->
        <div class="inspector-collapsed-toggle" onclick={() => handleShowHeader('left')}></div>
        <div class="inspector-main">
          <div class="inspector-simple-section">
            <span class="inspector-simple-title">Terminal Size</span>
            <hr>
          </div>
          <div class="inspector-row">
            <span class="inspector-label">Grid</span>
            <span class="inspector-value">{inspectorState?.cols ?? 0} columns × {inspectorState?.rows ?? 0} rows</span>
          </div>
          <div class="inspector-row">
            <span class="inspector-label">Screen</span>
            <span class="inspector-value">{inspectorState?.width_px ?? 0} × {inspectorState?.height_px ?? 0} px</span>
          </div>
          <div class="inspector-row">
            <span class="inspector-label">Cell</span>
            <span class="inspector-value">{inspectorState?.cell_width ?? 0} × {inspectorState?.cell_height ?? 0} px</span>
          </div>
        </div>
      </div>
      <div class="inspector-right" class:header-hidden={inspectorRightHeaderHidden}>
        <div class="inspector-right-header">
          <!-- svelte-ignore a11y_no_static_element_interactions -->
          <!-- svelte-ignore a11y_click_events_have_key_events -->
          <div class="inspector-dock-wrapper">
            <span class="inspector-dock-icon" onclick={(e) => handleDockIconClick('right', e)}></span>
            <div class="inspector-dock-menu" class:visible={dockMenuVisible === 'right'}>
              <!-- svelte-ignore a11y_no_static_element_interactions -->
              <!-- svelte-ignore a11y_click_events_have_key_events -->
              <div class="inspector-dock-menu-item" onclick={() => handleHideHeader('right')}>Hide Tab Bar</div>
            </div>
          </div>
          <span class="inspector-right-title">Surface Info</span>
        </div>
        <!-- svelte-ignore a11y_no_static_element_interactions -->
        <!-- svelte-ignore a11y_click_events_have_key_events -->
        <div class="inspector-collapsed-toggle" onclick={() => handleShowHeader('right')}></div>
        <div class="inspector-sidebar">
          <div class="inspector-simple-section">
            <span class="inspector-simple-title">Dimensions</span>
            <hr>
          </div>
          <div class="inspector-row">
            <span class="inspector-label">Screen Size</span>
            <span class="inspector-value">{screenSizeText}</span>
          </div>
          <div class="inspector-row">
            <span class="inspector-label">Grid Size</span>
            <span class="inspector-value">{gridSizeText}</span>
          </div>
          <div class="inspector-row">
            <span class="inspector-label">Cell Size</span>
            <span class="inspector-value">{cellSizeText}</span>
          </div>
        </div>
      </div>
    </div>
  </div>
</div>

<style>
  .panel-root {
    position: absolute;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    display: flex;
    flex-direction: column;
    background: var(--bg);
    outline: none;
  }

  .panel-content {
    flex: 1;
    min-height: 0;
    position: relative;
    display: flex;
    flex-direction: column;
  }

  .panel-canvas {
    flex: 1;
    min-height: 0;
    width: 100%;
    height: 100%;
    object-fit: contain;
    object-position: top left;
    background: var(--bg);
    outline: none;
  }

  .cursor-container {
    position: absolute;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    pointer-events: none;
    z-index: 5;
    container-type: size;
    overflow: hidden;
  }

  /* Replicates object-fit:contain + object-position:top left using container queries.
     min(full-inline, block-scaled-by-aspect) picks the constraining dimension,
     exactly matching what object-fit:contain computes for the canvas content. */
  .cursor-viewport {
    position: relative;
    width: min(100cqi, calc(100cqb * var(--fw) / var(--fh)));
    height: min(100cqb, calc(100cqi * var(--fh) / var(--fw)));
  }

  .cursor-overlay {
    position: absolute;
    pointer-events: none;
    box-sizing: border-box;
    animation: cursor-blink 1.2s step-end infinite;
  }
  .cursor-bar {
    background: var(--text, #c8c8c8);
    max-width: 2px;
  }
  .cursor-block { background: var(--text, #c8c8c8); opacity: 0.7; }
  .cursor-underline {
    background: transparent;
    border-bottom: 2px solid var(--text, #c8c8c8);
  }
  .cursor-hollow {
    background: transparent;
    border: 1px solid var(--text, #c8c8c8);
  }

  /* Inactive panel: show hollow cursor without blink */
  :global(.panel:not(.focused)) .cursor-overlay {
    background: transparent;
    border: 1px solid var(--text, #c8c8c8);
    max-width: none;
    opacity: 1;
    animation: none;
  }

  @keyframes cursor-blink {
    0%, 49% { visibility: visible; }
    50%, 100% { visibility: hidden; }
  }

  .panel-loading {
    position: absolute;
    inset: 0;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 12px;
    color: var(--text-dim);
    font: 14px system-ui, sans-serif;
    background: var(--bg);
  }

  .panel-loading .spinner {
    width: 24px;
    height: 24px;
    border: 2px solid #333;
    border-top-color: var(--accent);
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
  }

  @keyframes spin {
    to { transform: rotate(360deg); }
  }

  .panel-stats {
    position: absolute;
    top: 8px;
    left: 8px;
    display: flex;
    gap: 12px;
    padding: 6px 10px;
    background: rgba(0, 0, 0, 0.7);
    border-radius: 4px;
    font: 11px ui-monospace, monospace;
    color: #fff;
    z-index: 10;
  }

  .panel-stats .stat {
    white-space: nowrap;
  }

  .panel-stats .stat.good {
    color: #4caf50;
  }

  .panel-stats .stat.warn {
    color: #ff9800;
  }

  .panel-stats .stat.bad {
    color: #f44336;
  }

  /* Inspector styles */
  .panel-inspector {
    display: none;
    flex-direction: column;
    background: var(--toolbar-bg);
    border-top: 1px solid rgba(128, 128, 128, 0.3);
    min-height: 100px;
    max-height: 60%;
    overflow: hidden;
  }

  .panel-inspector.visible {
    display: flex;
  }

  .inspector-resize {
    height: 4px;
    cursor: ns-resize;
    background: transparent;
    flex-shrink: 0;
  }

  .inspector-resize:hover {
    background: var(--accent);
  }

  .inspector-content {
    flex: 1;
    display: flex;
    overflow: hidden;
  }

  .inspector-left,
  .inspector-right {
    flex: 1;
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }

  .inspector-left {
    border-right: 1px solid rgba(128, 128, 128, 0.2);
  }

  .inspector-left-header,
  .inspector-right-header {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 4px 8px;
    background: rgba(0, 0, 0, 0.2);
    border-bottom: 1px solid rgba(128, 128, 128, 0.2);
    flex-shrink: 0;
  }

  .inspector-left.header-hidden .inspector-left-header,
  .inspector-right.header-hidden .inspector-right-header {
    display: none;
  }

  .inspector-collapsed-toggle {
    display: none;
    height: 20px;
    background: rgba(0, 0, 0, 0.2);
    cursor: pointer;
    flex-shrink: 0;
  }

  .inspector-collapsed-toggle:hover {
    background: rgba(255, 255, 255, 0.1);
  }

  .inspector-left.header-hidden .inspector-collapsed-toggle,
  .inspector-right.header-hidden .inspector-collapsed-toggle {
    display: block;
  }

  .inspector-dock-wrapper {
    position: relative;
  }

  .inspector-dock-icon {
    width: 16px;
    height: 16px;
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    opacity: 0.5;
    border-radius: 3px;
  }

  .inspector-dock-icon:hover {
    opacity: 1;
    background: rgba(255, 255, 255, 0.1);
  }

  .inspector-dock-icon::before {
    content: '⋮';
    font-size: 12px;
    color: var(--text);
  }

  .inspector-dock-menu {
    display: none;
    position: absolute;
    top: 100%;
    left: 0;
    background: var(--toolbar-bg);
    border: 1px solid rgba(128, 128, 128, 0.3);
    border-radius: 4px;
    box-shadow: 0 2px 8px rgba(0, 0, 0, 0.3);
    z-index: 100;
    min-width: 120px;
  }

  .inspector-dock-menu.visible {
    display: block;
  }

  .inspector-dock-menu-item {
    padding: 6px 12px;
    cursor: pointer;
    font-size: 12px;
    color: var(--text);
    white-space: nowrap;
  }

  .inspector-dock-menu-item:hover {
    background: rgba(255, 255, 255, 0.1);
  }

  .inspector-tabs {
    display: flex;
    gap: 2px;
  }

  .inspector-tab {
    padding: 4px 8px;
    background: transparent;
    border: none;
    color: var(--text-dim);
    font-size: 11px;
    cursor: pointer;
    border-radius: 3px;
  }

  .inspector-tab:hover {
    background: rgba(255, 255, 255, 0.1);
    color: var(--text);
  }

  .inspector-tab.active {
    background: rgba(255, 255, 255, 0.15);
    color: var(--text);
  }

  .inspector-right-title {
    font-size: 11px;
    font-weight: 500;
    color: var(--text);
  }

  .inspector-main,
  .inspector-sidebar {
    flex: 1;
    overflow-y: auto;
    padding: 8px;
  }

  .inspector-simple-section {
    margin-bottom: 8px;
  }

  .inspector-simple-title {
    font-size: 10px;
    font-weight: 600;
    color: var(--text-dim);
    text-transform: uppercase;
    letter-spacing: 0.5px;
  }

  .inspector-simple-section hr {
    border: none;
    border-top: 1px solid rgba(128, 128, 128, 0.2);
    margin: 4px 0 8px;
  }

  .inspector-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 4px 0;
    font-size: 11px;
  }

  .inspector-label {
    color: var(--text-dim);
  }

  .inspector-value {
    color: var(--text);
    font-family: ui-monospace, monospace;
  }
</style>
