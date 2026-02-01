/**
 * Panel - Terminal panel with WebGPU rendering
 */

import { ClientMsg, FrameType } from './protocol';

// WebGPU Shaders
const XOR_SHADER = `
  @group(0) @binding(0) var<storage, read> diff: array<u32>;
  @group(0) @binding(1) var<storage, read_write> prev: array<u32>;

  @compute @workgroup_size(256)
  fn main(@builtin(global_invocation_id) id: vec3<u32>) {
    let idx = id.x;
    if (idx < arrayLength(&prev)) {
      prev[idx] = prev[idx] ^ diff[idx];
    }
  }
`;

const RGB_TO_RGBA_SHADER = `
  @group(0) @binding(0) var<storage, read> rgb: array<u32>;
  @group(0) @binding(1) var outTex: texture_storage_2d<rgba8unorm, write>;

  @compute @workgroup_size(16, 16)
  fn main(@builtin(global_invocation_id) id: vec3<u32>) {
    let dims = textureDimensions(outTex);
    if (id.x >= dims.x || id.y >= dims.y) { return; }

    let pixelIdx = id.y * dims.x + id.x;
    let byteIdx = pixelIdx * 3u;
    let wordIdx = byteIdx / 4u;
    let byteOff = byteIdx % 4u;

    let w0 = rgb[wordIdx];
    let w1 = rgb[wordIdx + 1u];

    var r: u32; var g: u32; var b: u32;
    if (byteOff == 0u) {
      r = (w0 >> 0u) & 0xFFu;
      g = (w0 >> 8u) & 0xFFu;
      b = (w0 >> 16u) & 0xFFu;
    } else if (byteOff == 1u) {
      r = (w0 >> 8u) & 0xFFu;
      g = (w0 >> 16u) & 0xFFu;
      b = (w0 >> 24u) & 0xFFu;
    } else if (byteOff == 2u) {
      r = (w0 >> 16u) & 0xFFu;
      g = (w0 >> 24u) & 0xFFu;
      b = (w1 >> 0u) & 0xFFu;
    } else {
      r = (w0 >> 24u) & 0xFFu;
      g = (w1 >> 0u) & 0xFFu;
      b = (w1 >> 8u) & 0xFFu;
    }

    let color = vec4<f32>(f32(r) / 255.0, f32(g) / 255.0, f32(b) / 255.0, 1.0);
    textureStore(outTex, vec2<i32>(i32(id.x), i32(id.y)), color);
  }
`;

const QUAD_SHADER = `
  @group(0) @binding(0) var tex: texture_2d<f32>;
  @group(0) @binding(1) var samp: sampler;

  struct VSOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) uv: vec2<f32>,
  };

  @vertex
  fn vs(@builtin(vertex_index) idx: u32) -> VSOut {
    var pos = array<vec2<f32>, 4>(
      vec2(-1.0, 1.0), vec2(1.0, 1.0), vec2(-1.0, -1.0), vec2(1.0, -1.0)
    );
    var uv = array<vec2<f32>, 4>(
      vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(0.0, 1.0), vec2(1.0, 1.0)
    );
    var out: VSOut;
    out.pos = vec4(pos[idx], 0.0, 1.0);
    out.uv = uv[idx];
    return out;
  }

  @fragment
  fn fs(in: VSOut) -> @location(0) vec4<f32> {
    return textureSample(tex, samp, in.uv);
  }
`;

export interface PanelCallbacks {
  onResize?: (panelId: number, width: number, height: number) => void;
  onViewAction?: (action: string, data?: unknown) => void;
}

export class Panel {
  readonly id: string;
  serverId: number | null;
  container: HTMLElement;
  readonly canvas: HTMLCanvasElement;
  readonly element: HTMLDivElement;
  ws: WebSocket | null = null;
  width = 0;
  height = 0;
  pwd: string | null = null;

  private sequence = 0;
  private lastReportedWidth = 0;
  private lastReportedHeight = 0;
  private resizeTimeout: ReturnType<typeof setTimeout> | null = null;
  resizeObserver: ResizeObserver | null = null;
  private callbacks: PanelCallbacks;

  // WebGPU state
  private device: GPUDevice | null = null;
  private context: GPUCanvasContext | null = null;
  private pipeline: GPURenderPipeline | null = null;
  private xorPipeline: GPUComputePipeline | null = null;
  private rgbToRgbaPipeline: GPUComputePipeline | null = null;
  private prevBuffer: GPUBuffer | null = null;
  private diffBuffer: GPUBuffer | null = null;
  private texture: GPUTexture | null = null;
  private sampler: GPUSampler | null = null;
  private xorBindGroup: GPUBindGroup | null = null;
  private convertBindGroup: GPUBindGroup | null = null;
  private renderBindGroup: GPUBindGroup | null = null;

  // Inspector state
  private inspectorEl: HTMLDivElement;
  private inspectorVisible = false;
  private inspectorHeight = 200;
  private inspectorActiveTab = 'screen';
  private inspectorState: unknown = null;
  private inspectorClickHandler: (() => void) | null = null;
  private destroyed = false;

  constructor(
    id: string,
    container: HTMLElement,
    serverId: number | null = null,
    callbacks: PanelCallbacks = {}
  ) {
    this.id = id;
    this.serverId = serverId;
    this.container = container;
    this.callbacks = callbacks;

    // Create DOM elements
    this.canvas = document.createElement('canvas');
    this.canvas.className = 'panel-canvas';
    this.canvas.tabIndex = 1;

    this.element = document.createElement('div');
    this.element.className = 'panel';
    this.element.appendChild(this.canvas);

    this.inspectorEl = this.createInspectorElement();
    this.element.appendChild(this.inspectorEl);

    container.appendChild(this.element);

    // Initialize
    this.setupInputHandlers();
    this.initGPU();
    this.setupResizeObserver();
  }

  private createInspectorElement(): HTMLDivElement {
    const el = document.createElement('div');
    el.className = 'panel-inspector';
    el.innerHTML = `
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
    this.setupInspectorHandlers(el);
    return el;
  }

  private setupInspectorHandlers(el: HTMLDivElement): void {
    // Tab switching
    const tabs = el.querySelectorAll<HTMLButtonElement>('.inspector-tab');
    tabs.forEach(tab => {
      tab.addEventListener('click', () => {
        tabs.forEach(t => t.classList.remove('active'));
        tab.classList.add('active');
        this.inspectorActiveTab = tab.dataset.tab || 'screen';
        this.sendInspectorTab(this.inspectorActiveTab);
        this.renderInspectorView();
      });
    });

    // Dock icon dropdown
    const dockIcons = el.querySelectorAll('.inspector-dock-icon');
    dockIcons.forEach(icon => {
      icon.addEventListener('click', (e) => {
        e.stopPropagation();
        const menu = icon.parentElement?.querySelector('.inspector-dock-menu');
        // Close other menus
        el.querySelectorAll('.inspector-dock-menu.visible').forEach(m => {
          if (m !== menu) m.classList.remove('visible');
        });
        menu?.classList.toggle('visible');
      });
    });

    // Hide menu when clicking elsewhere
    this.inspectorClickHandler = () => {
      el.querySelectorAll('.inspector-dock-menu.visible').forEach(m => {
        m.classList.remove('visible');
      });
    };
    document.addEventListener('click', this.inspectorClickHandler);

    // Menu item click - hide header
    const menuItems = el.querySelectorAll('.inspector-dock-menu-item');
    menuItems.forEach(item => {
      item.addEventListener('click', (e) => {
        e.stopPropagation();
        const panel = item.closest('.inspector-left, .inspector-right');
        if (panel && (item as HTMLElement).dataset.action === 'hide-header') {
          panel.classList.add('header-hidden');
        }
        item.closest('.inspector-dock-menu')?.classList.remove('visible');
      });
    });

    // Collapsed toggle - show header again
    const toggles = el.querySelectorAll('.inspector-collapsed-toggle');
    toggles.forEach(toggle => {
      toggle.addEventListener('click', () => {
        const panel = toggle.closest('.inspector-left, .inspector-right');
        panel?.classList.remove('header-hidden');
      });
    });

    // Resize handle
    const handle = el.querySelector('.inspector-resize');
    if (handle) {
      let startY = 0;
      let startHeight = 0;

      const onMouseMove = (e: MouseEvent) => {
        const delta = startY - e.clientY;
        const newHeight = Math.min(
          Math.max(startHeight + delta, 100),
          this.element.clientHeight * 0.6
        );
        this.inspectorHeight = newHeight;
        this.inspectorEl.style.height = `${newHeight}px`;
      };

      const onMouseUp = () => {
        document.removeEventListener('mousemove', onMouseMove);
        document.removeEventListener('mouseup', onMouseUp);
        this.triggerResize();
      };

      handle.addEventListener('mousedown', (e: Event) => {
        const me = e as MouseEvent;
        startY = me.clientY;
        startHeight = this.inspectorHeight;
        document.addEventListener('mousemove', onMouseMove);
        document.addEventListener('mouseup', onMouseUp);
      });
    }
  }

  // Inspector methods
  toggleInspector(): void {
    this.inspectorVisible ? this.hideInspector() : this.showInspector();
  }

  showInspector(): void {
    this.inspectorVisible = true;
    this.inspectorEl.classList.add('visible');
    this.inspectorEl.style.height = `${this.inspectorHeight}px`;
    this.sendInspectorSubscribe();
    this.triggerResize();
  }

  hideInspector(): void {
    this.inspectorVisible = false;
    this.inspectorEl.classList.remove('visible');
    this.sendInspectorUnsubscribe();
    this.triggerResize();
  }

  private sendInspectorSubscribe(): void {
    this.ws?.send(JSON.stringify({ type: 'inspector_subscribe', tab: this.inspectorActiveTab }));
  }

  private sendInspectorUnsubscribe(): void {
    this.ws?.send(JSON.stringify({ type: 'inspector_unsubscribe' }));
  }

  private sendInspectorTab(tab: string): void {
    this.ws?.send(JSON.stringify({ type: 'inspector_tab', tab }));
  }

  handleInspectorState(state: unknown): void {
    this.inspectorState = state;
    this.renderInspectorSidebar();
    this.renderInspectorView();
  }

  private renderInspectorSidebar(): void {
    const sidebarEl = this.inspectorEl.querySelector<HTMLDivElement>('.inspector-sidebar');
    if (!sidebarEl || !this.inspectorState) return;

    const state = this.inspectorState as { size?: Record<string, number> };
    const size = state.size || {};

    // Initialize once with data-field pattern for efficient updates
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
    if (screenSize) screenSize.textContent = `${size.screen_width ?? 0}px x ${size.screen_height ?? 0}px`;
    if (gridSize) gridSize.textContent = `${size.cols ?? 0}c x ${size.rows ?? 0}r`;
    if (cellSize) cellSize.textContent = `${size.cell_width ?? 0}px x ${size.cell_height ?? 0}px`;
  }

  private renderInspectorView(): void {
    const mainEl = this.inspectorEl.querySelector<HTMLDivElement>('.inspector-main');
    if (!mainEl) return;

    const state = this.inspectorState as { size?: Record<string, number> } | null;
    const size = state?.size || {};

    mainEl.innerHTML = `
      <div class="inspector-simple-section">
        <span class="inspector-simple-title">Terminal Size</span>
        <hr>
      </div>
      <div class="inspector-row">
        <span class="inspector-label">Grid</span>
        <span class="inspector-value">${size.cols ?? 0} columns × ${size.rows ?? 0} rows</span>
      </div>
      <div class="inspector-row">
        <span class="inspector-label">Screen</span>
        <span class="inspector-value">${size.screen_width ?? 0} × ${size.screen_height ?? 0} px</span>
      </div>
      <div class="inspector-row">
        <span class="inspector-label">Cell</span>
        <span class="inspector-value">${size.cell_width ?? 0} × ${size.cell_height ?? 0} px</span>
      </div>
    `;
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

  // WebGPU initialization
  private async initGPU(): Promise<void> {
    if (!navigator.gpu) {
      console.error('WebGPU not supported');
      return;
    }

    const adapter = await navigator.gpu.requestAdapter();
    if (!adapter) {
      console.error('No WebGPU adapter');
      return;
    }

    this.device = await adapter.requestDevice();
    this.device.lost.then((info) => {
      if (this.destroyed) return;
      console.error('WebGPU device lost:', info.message, info.reason);
    });
    this.device.onuncapturederror = (e) => {
      if (this.destroyed) return;
      console.error('WebGPU error:', e.error);
    };

    this.context = this.canvas.getContext('webgpu');
    if (!this.context) {
      console.error('Could not get WebGPU context');
      return;
    }

    const format = navigator.gpu.getPreferredCanvasFormat();
    this.context.configure({
      device: this.device,
      format,
      alphaMode: 'opaque',
    });

    // Create compute pipelines
    const xorShader = this.device.createShaderModule({ code: XOR_SHADER });
    this.xorPipeline = this.device.createComputePipeline({
      layout: 'auto',
      compute: { module: xorShader, entryPoint: 'main' },
    });

    const convertShader = this.device.createShaderModule({ code: RGB_TO_RGBA_SHADER });
    this.rgbToRgbaPipeline = this.device.createComputePipeline({
      layout: 'auto',
      compute: { module: convertShader, entryPoint: 'main' },
    });

    // Create render pipeline
    const quadShader = this.device.createShaderModule({ code: QUAD_SHADER });
    this.pipeline = this.device.createRenderPipeline({
      layout: 'auto',
      vertex: { module: quadShader, entryPoint: 'vs' },
      fragment: {
        module: quadShader,
        entryPoint: 'fs',
        targets: [{ format }],
      },
      primitive: { topology: 'triangle-strip' },
    });

    this.sampler = this.device.createSampler({
      magFilter: 'nearest',
      minFilter: 'nearest',
    });

    console.log('WebGPU initialized');
  }

  private createGPUBuffers(width: number, height: number): void {
    if (!this.device) return;

    // Cleanup old resources
    this.prevBuffer?.destroy();
    this.diffBuffer?.destroy();
    this.texture?.destroy();

    const rgbSize = width * height * 3;
    const alignedSize = Math.ceil(rgbSize / 4) * 4;

    this.prevBuffer = this.device.createBuffer({
      size: alignedSize,
      usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
    });

    this.diffBuffer = this.device.createBuffer({
      size: alignedSize,
      usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
    });

    this.texture = this.device.createTexture({
      size: [width, height],
      format: 'rgba8unorm',
      usage: GPUTextureUsage.STORAGE_BINDING | GPUTextureUsage.TEXTURE_BINDING,
    });

    // Create bind groups
    this.xorBindGroup = this.device.createBindGroup({
      layout: this.xorPipeline!.getBindGroupLayout(0),
      entries: [
        { binding: 0, resource: { buffer: this.diffBuffer } },
        { binding: 1, resource: { buffer: this.prevBuffer } },
      ],
    });

    this.convertBindGroup = this.device.createBindGroup({
      layout: this.rgbToRgbaPipeline!.getBindGroupLayout(0),
      entries: [
        { binding: 0, resource: { buffer: this.prevBuffer } },
        { binding: 1, resource: this.texture.createView() },
      ],
    });

    this.renderBindGroup = this.device.createBindGroup({
      layout: this.pipeline!.getBindGroupLayout(0),
      entries: [
        { binding: 0, resource: this.texture.createView() },
        { binding: 1, resource: this.sampler! },
      ],
    });
  }

  // WebSocket connection
  connect(host: string, port: number): void {
    // Close any existing connection before reconnecting
    if (this.ws) {
      this.disconnect();
    }
    this.ws = new WebSocket(`ws://${host}:${port}`);
    this.ws.binaryType = 'arraybuffer';

    this.ws.onopen = () => {
      console.log(`Panel ${this.id}: Connected`);
      if (this.serverId !== null) {
        this.sendConnectPanel(this.serverId);
      } else {
        this.sendCreatePanel();
      }
    };

    this.ws.onmessage = (event) => {
      if (typeof event.data === 'string') {
        try {
          const msg = JSON.parse(event.data);
          if (msg.type === 'inspector_state') {
            this.handleInspectorState(msg);
          }
        } catch (e) {
          console.error('Failed to parse JSON:', e);
        }
      } else {
        this.handleFrame(event.data);
      }
    };

    this.ws.onclose = () => {
      console.log(`Panel ${this.id}: Disconnected`);
    };

    this.ws.onerror = () => {
      if (this.ws?.readyState === WebSocket.CLOSING || this.ws?.readyState === WebSocket.CLOSED) {
        return;
      }
      console.error(`Panel ${this.id}: WebSocket error`);
    };
  }

  disconnect(): void {
    this.ws?.close();
    this.ws = null;
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

  // Frame handling
  private async handleFrame(data: ArrayBuffer): Promise<void> {
    if (!this.device || this.destroyed) return;

    const view = new DataView(data);
    const frameType = view.getUint8(0);

    // Handle partial_delta (uncompressed, different header)
    if (frameType === FrameType.PARTIAL_DELTA) {
      // Header: type(1) + seq(4) + width(2) + height(2) + offset(4) + length(4) = 17
      const sequence = view.getUint32(1, true);
      const width = view.getUint16(5, true);
      const height = view.getUint16(7, true);
      const offset = view.getUint32(9, true);
      const length = view.getUint32(13, true);

      // Resize if needed
      if (width !== this.width || height !== this.height) {
        this.width = width;
        this.height = height;
        this.canvas.width = width;
        this.canvas.height = height;
        const format = navigator.gpu.getPreferredCanvasFormat();
        this.context!.configure({ device: this.device, format, alphaMode: 'opaque' });
        this.createGPUBuffers(width, height);
      }

      // Create full diff buffer with zeros, place partial data at offset
      const expectedSize = width * height * 3;
      const alignedSize = Math.ceil(expectedSize / 4) * 4;
      const fullDiff = new Uint8Array(alignedSize);
      const partialData = new Uint8Array(data, 17, length);
      fullDiff.set(partialData, offset);

      // XOR with prevBuffer
      this.device.queue.writeBuffer(this.diffBuffer!, 0, fullDiff as Uint8Array<ArrayBuffer>);
      const commandEncoder = this.device.createCommandEncoder();
      const pass = commandEncoder.beginComputePass();
      pass.setPipeline(this.xorPipeline!);
      pass.setBindGroup(0, this.xorBindGroup!);
      pass.dispatchWorkgroups(Math.ceil(expectedSize / 4 / 256));
      pass.end();
      this.device.queue.submit([commandEncoder.finish()]);

      this.renderFrame();
      this.sequence = sequence;
      return;
    }

    // Standard header (13 bytes) for keyframe/delta
    const sequence = view.getUint32(1, true);
    const width = view.getUint16(5, true);
    const height = view.getUint16(7, true);
    const compressedSize = view.getUint32(9, true);

    // Resize if needed
    if (width !== this.width || height !== this.height) {
      this.width = width;
      this.height = height;
      this.canvas.width = width;
      this.canvas.height = height;

      const format = navigator.gpu.getPreferredCanvasFormat();
      this.context!.configure({
        device: this.device,
        format,
        alphaMode: 'opaque',
      });
      this.createGPUBuffers(width, height);
    }

    // Decompress
    const compressed = new Uint8Array(data, 13, compressedSize);
    let rgb: Uint8Array;
    try {
      rgb = await this.decompress(compressed);
    } catch (e) {
      console.error('Decompress failed:', e);
      return;
    }

    // Verify size
    const expectedSize = width * height * 3;
    if (rgb.length !== expectedSize) {
      console.error(`Size mismatch: got ${rgb.length}, expected ${expectedSize}`);
      return;
    }

    // Align to 4 bytes
    const alignedSize = Math.ceil(rgb.length / 4) * 4;
    let rgbAligned = rgb;
    if (rgb.length !== alignedSize) {
      rgbAligned = new Uint8Array(alignedSize);
      rgbAligned.set(rgb);
    }

    // Process frame
    if (frameType === FrameType.KEYFRAME) {
      this.device.queue.writeBuffer(this.prevBuffer!, 0, rgbAligned as Uint8Array<ArrayBuffer>);
    } else {
      this.device.queue.writeBuffer(this.diffBuffer!, 0, rgbAligned as Uint8Array<ArrayBuffer>);

      const commandEncoder = this.device.createCommandEncoder();
      const pass = commandEncoder.beginComputePass();
      pass.setPipeline(this.xorPipeline!);
      pass.setBindGroup(0, this.xorBindGroup!);
      pass.dispatchWorkgroups(Math.ceil(rgb.length / 4 / 256));
      pass.end();
      this.device.queue.submit([commandEncoder.finish()]);
    }

    this.renderFrame();
    this.sequence = sequence;
  }

  private async decompress(data: Uint8Array): Promise<Uint8Array> {
    const ds = new DecompressionStream('deflate-raw');
    const writer = ds.writable.getWriter();
    writer.write(data as Uint8Array<ArrayBuffer>);
    writer.close();

    const reader = ds.readable.getReader();
    const chunks: Uint8Array[] = [];
    let totalLength = 0;

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      chunks.push(value);
      totalLength += value.length;
    }

    const result = new Uint8Array(totalLength);
    let offset = 0;
    for (const chunk of chunks) {
      result.set(chunk, offset);
      offset += chunk.length;
    }
    return result;
  }

  private renderFrame(): void {
    if (!this.device || !this.context || !this.pipeline) return;
    if (!this.convertBindGroup || !this.renderBindGroup) return;

    const commandEncoder = this.device.createCommandEncoder();

    // RGB to RGBA conversion
    const convertPass = commandEncoder.beginComputePass();
    convertPass.setPipeline(this.rgbToRgbaPipeline!);
    convertPass.setBindGroup(0, this.convertBindGroup!);
    convertPass.dispatchWorkgroups(
      Math.ceil(this.width / 16),
      Math.ceil(this.height / 16)
    );
    convertPass.end();

    // Render to canvas
    const renderPass = commandEncoder.beginRenderPass({
      colorAttachments: [{
        view: this.context.getCurrentTexture().createView(),
        loadOp: 'clear',
        storeOp: 'store',
        clearValue: { r: 0, g: 0, b: 0, a: 1 },
      }],
    });
    renderPass.setPipeline(this.pipeline);
    renderPass.setBindGroup(0, this.renderBindGroup!);
    renderPass.draw(4);
    renderPass.end();

    this.device.queue.submit([commandEncoder.finish()]);
  }

  // Input handling
  private setupInputHandlers(): void {
    // Keyboard and paste are handled at document level in App class

    this.canvas.addEventListener('mousedown', (e) => {
      this.canvas.focus();
      this.sendMouseButton(e, 1);
    });

    this.canvas.addEventListener('mouseup', (e) => {
      this.sendMouseButton(e, 0);
    });

    this.canvas.addEventListener('mousemove', (e) => {
      this.sendMouseMove(e);
    });

    this.canvas.addEventListener('wheel', (e) => {
      e.preventDefault();
      this.sendMouseScroll(e);
    });

    this.canvas.addEventListener('contextmenu', (e) => e.preventDefault());

    // Drag & drop file upload
    this.canvas.addEventListener('dragover', (e) => {
      e.preventDefault();
      e.stopPropagation();
      if (e.dataTransfer) e.dataTransfer.dropEffect = 'copy';
      this.canvas.style.opacity = '0.7';
    });

    this.canvas.addEventListener('dragleave', (e) => {
      e.preventDefault();
      e.stopPropagation();
      this.canvas.style.opacity = '1';
    });

    this.canvas.addEventListener('drop', (e) => {
      e.preventDefault();
      e.stopPropagation();
      this.canvas.style.opacity = '1';
      if (e.dataTransfer?.files) {
        for (const file of e.dataTransfer.files) {
          (window as unknown as { app?: { uploadFile(f: File): void } }).app?.uploadFile(file);
        }
      }
    });
  }

  private getModifiers(e: KeyboardEvent | MouseEvent | WheelEvent): number {
    let mods = 0;
    if (e.shiftKey) mods |= 0x01;
    if (e.ctrlKey) mods |= 0x02;
    if (e.altKey) mods |= 0x04;
    if (e.metaKey) mods |= 0x08;
    return mods;
  }

  private getCanvasCoords(e: MouseEvent | WheelEvent): { x: number; y: number } {
    const rect = this.canvas.getBoundingClientRect();
    return {
      x: e.clientX - rect.left,
      y: e.clientY - rect.top
    };
  }

  // Public input methods - match original protocol exactly
  sendKeyInput(e: KeyboardEvent, action: number): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;

    // Format: [msg_type:u8][action:u8][mods:u8][code_len:u8][code:...][text_len:u8][text:...]
    const codeBytes = new TextEncoder().encode(e.code);
    const text = (e.key.length === 1) ? e.key : '';
    const textBytes = new TextEncoder().encode(text);

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

  sendMouseButton(e: MouseEvent, state: number): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;

    const coords = this.getCanvasCoords(e);
    const buf = new ArrayBuffer(20);
    const view = new DataView(buf);
    view.setUint8(0, ClientMsg.MOUSE_INPUT);
    view.setFloat64(1, coords.x, true);
    view.setFloat64(9, coords.y, true);
    view.setUint8(17, e.button);
    view.setUint8(18, state);
    view.setUint8(19, this.getModifiers(e));
    this.ws.send(buf);
  }

  sendMouseMove(e: MouseEvent): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;

    const coords = this.getCanvasCoords(e);
    const buf = new ArrayBuffer(18);
    const view = new DataView(buf);
    view.setUint8(0, ClientMsg.MOUSE_MOVE);
    view.setFloat64(1, coords.x, true);
    view.setFloat64(9, coords.y, true);
    view.setUint8(17, this.getModifiers(e));
    this.ws.send(buf);
  }

  sendMouseScroll(e: WheelEvent): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;

    const coords = this.getCanvasCoords(e);
    const buf = new ArrayBuffer(34);
    const view = new DataView(buf);
    view.setUint8(0, ClientMsg.MOUSE_SCROLL);
    view.setFloat64(1, coords.x, true);
    view.setFloat64(9, coords.y, true);
    view.setFloat64(17, e.deltaX, true);
    view.setFloat64(25, e.deltaY, true);
    view.setUint8(33, this.getModifiers(e));
    this.ws.send(buf);
  }

  sendTextInput(text: string): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;

    const textBytes = new TextEncoder().encode(text);
    const buf = new ArrayBuffer(1 + textBytes.length);
    const view = new Uint8Array(buf);
    view[0] = ClientMsg.TEXT_INPUT;
    view.set(textBytes, 1);
    this.ws.send(buf);
  }

  requestKeyframe(): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;
    this.ws.send(new Uint8Array([ClientMsg.REQUEST_KEYFRAME]));
  }

  pause(): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;
    this.ws.send(new Uint8Array([ClientMsg.PAUSE_STREAM]));
  }

  resume(): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;
    this.ws.send(new Uint8Array([ClientMsg.RESUME_STREAM]));
    this.requestKeyframe();
  }

  show(): void {
    this.element.classList.add('active');
    this.canvas.focus();
    this.resume();
  }

  hide(): void {
    this.element.classList.remove('active');
    this.pause();
  }

  focus(): void {
    this.canvas.focus();
  }

  reparent(newContainer: HTMLElement): void {
    this.container = newContainer;
    newContainer.appendChild(this.element);

    // Force resize check after reparenting since container changed
    // Use 50ms delay to wait for layout to settle
    setTimeout(() => {
      const rect = this.container.getBoundingClientRect();
      const width = Math.floor(rect.width);
      const height = Math.floor(rect.height);
      if (width > 0 && height > 0 &&
          (width !== this.lastReportedWidth || height !== this.lastReportedHeight)) {
        this.lastReportedWidth = width;
        this.lastReportedHeight = height;
        if (this.serverId !== null && this.callbacks.onResize) {
          this.callbacks.onResize(this.serverId, width, height);
        }
      }
    }, 50);
  }

  destroy(): void {
    // Mark as destroyed to prevent callbacks on stale panel
    this.destroyed = true;

    // Clear resize timeout
    if (this.resizeTimeout) {
      clearTimeout(this.resizeTimeout);
      this.resizeTimeout = null;
    }

    // Disconnect WebSocket
    this.disconnect();

    // Disconnect resize observer
    if (this.resizeObserver) {
      this.resizeObserver.disconnect();
      this.resizeObserver = null;
    }

    // Remove inspector click handler
    if (this.inspectorClickHandler) {
      document.removeEventListener('click', this.inspectorClickHandler);
      this.inspectorClickHandler = null;
    }

    // Clean up WebGPU resources
    if (this.prevBuffer) {
      this.prevBuffer.destroy();
      this.prevBuffer = null;
    }
    if (this.diffBuffer) {
      this.diffBuffer.destroy();
      this.diffBuffer = null;
    }
    if (this.texture) {
      this.texture.destroy();
      this.texture = null;
    }

    // Clear references for GC
    this.xorBindGroup = null;
    this.convertBindGroup = null;
    this.renderBindGroup = null;
    this.pipeline = null;
    this.xorPipeline = null;
    this.rgbToRgbaPipeline = null;
    this.sampler = null;
    this.context = null;
    this.device = null;

    // Remove element from DOM
    this.element.remove();
  }
}
