// termweb-mux browser client
// Connects to server, receives frames, renders to canvas, sends input

// WebSocket ports are fetched from /config endpoint
let PANEL_PORT = 0;
let CONTROL_PORT = 0;

// Message types (must match server)
const ClientMsg = {
  KEY_INPUT: 0x01,
  MOUSE_INPUT: 0x02,
  MOUSE_MOVE: 0x03,
  MOUSE_SCROLL: 0x04,
  TEXT_INPUT: 0x05,
  RESIZE: 0x10,
  REQUEST_KEYFRAME: 0x11,
  PAUSE_STREAM: 0x12,
  RESUME_STREAM: 0x13,
  CONNECT_PANEL: 0x20,
  CREATE_PANEL: 0x21,
};

const FrameType = {
  KEYFRAME: 0x01,
  DELTA: 0x02,
};

// ============================================================================
// Panel - one terminal panel with its own WebSocket
// ============================================================================

class Panel {
  constructor(id, container, serverId = null, onResize = null, onViewAction = null) {
    this.id = id;                    // Local client ID
    this.serverId = serverId;        // Server panel ID (null = create new)
    this.container = container;
    this.onResize = onResize;        // Callback for resize events
    this.onViewAction = onViewAction; // Callback for ghostty view actions
    this.ws = null;
    this.canvas = document.createElement('canvas');
    this.width = 0;
    this.height = 0;
    this.sequence = 0;
    this.lastReportedWidth = 0;
    this.lastReportedHeight = 0;
    this.resizeTimeout = null;
    this.pwd = null;                 // Current working directory

    // WebGPU state
    this.device = null;
    this.context = null;
    this.pipeline = null;
    this.xorPipeline = null;
    this.rgbToRgbaPipeline = null;
    this.prevBuffer = null;
    this.diffBuffer = null;
    this.texture = null;
    this.sampler = null;

    // Inspector state (per-panel)
    this.inspectorVisible = false;
    this.inspectorHeight = 200;
    this.inspectorActiveTab = 'screen';
    this.inspectorState = null;

    this.element = document.createElement('div');
    this.element.className = 'panel';
    this.element.appendChild(this.canvas);
    this.createInspectorElement();
    container.appendChild(this.element);

    this.setupInputHandlers();
    this.initGPU();
    this.setupResizeObserver();
  }

  createInspectorElement() {
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

  setupInspectorHandlers() {
    // Tab switching
    const tabs = this.inspectorEl.querySelectorAll('.inspector-tab');
    tabs.forEach(tab => {
      tab.addEventListener('click', () => {
        tabs.forEach(t => t.classList.remove('active'));
        tab.classList.add('active');
        this.inspectorActiveTab = tab.dataset.tab;
        this.sendInspectorTab(tab.dataset.tab);
        this.renderInspectorView();
      });
    });

    // Resize handle
    const handle = this.inspectorEl.querySelector('.inspector-resize');
    let startY, startHeight;
    const onMouseMove = (e) => {
      const delta = startY - e.clientY;
      const newHeight = Math.min(Math.max(startHeight + delta, 100), this.element.clientHeight * 0.6);
      this.inspectorHeight = newHeight;
      this.inspectorEl.style.height = newHeight + 'px';
    };
    const onMouseUp = () => {
      document.removeEventListener('mousemove', onMouseMove);
      document.removeEventListener('mouseup', onMouseUp);
      // Trigger resize after drag ends
      this.triggerResize();
    };
    handle.addEventListener('mousedown', (e) => {
      startY = e.clientY;
      startHeight = this.inspectorHeight;
      document.addEventListener('mousemove', onMouseMove);
      document.addEventListener('mouseup', onMouseUp);
    });

    // Dock icon dropdown
    const dockIcons = this.inspectorEl.querySelectorAll('.inspector-dock-icon');
    dockIcons.forEach(icon => {
      icon.addEventListener('click', (e) => {
        e.stopPropagation();
        const menu = icon.parentElement.querySelector('.inspector-dock-menu');
        // Close other menus
        this.inspectorEl.querySelectorAll('.inspector-dock-menu.visible').forEach(m => {
          if (m !== menu) m.classList.remove('visible');
        });
        menu.classList.toggle('visible');
      });
    });

    // Hide menu when clicking elsewhere
    document.addEventListener('click', () => {
      this.inspectorEl.querySelectorAll('.inspector-dock-menu.visible').forEach(m => {
        m.classList.remove('visible');
      });
    });

    // Menu item click - hide header
    const menuItems = this.inspectorEl.querySelectorAll('.inspector-dock-menu-item');
    menuItems.forEach(item => {
      item.addEventListener('click', (e) => {
        e.stopPropagation();
        const panel = item.closest('.inspector-left, .inspector-right');
        if (panel && item.dataset.action === 'hide-header') {
          panel.classList.add('header-hidden');
        }
        // Close menu
        item.closest('.inspector-dock-menu').classList.remove('visible');
      });
    });

    // Collapsed toggle - show header again
    const toggles = this.inspectorEl.querySelectorAll('.inspector-collapsed-toggle');
    toggles.forEach(toggle => {
      toggle.addEventListener('click', () => {
        const panel = toggle.closest('.inspector-left, .inspector-right');
        if (panel) {
          panel.classList.remove('header-hidden');
        }
      });
    });
  }

  toggleInspector() {
    this.inspectorVisible ? this.hideInspector() : this.showInspector();
  }

  showInspector() {
    this.inspectorVisible = true;
    this.inspectorEl.classList.add('visible');
    this.inspectorEl.style.height = this.inspectorHeight + 'px';
    this.sendInspectorSubscribe();
    // Trigger resize so terminal reflows
    this.triggerResize();
  }

  hideInspector() {
    this.inspectorVisible = false;
    this.inspectorEl.classList.remove('visible');
    this.sendInspectorUnsubscribe();
    // Trigger resize so terminal reclaims space
    this.triggerResize();
  }

  triggerResize() {
    // Force recalculate size after layout change
    requestAnimationFrame(() => {
      const rect = this.canvas.getBoundingClientRect();
      const width = Math.floor(rect.width);
      const height = Math.floor(rect.height);
      if (width > 0 && height > 0 && this.serverId !== null && this.onResize) {
        this.lastReportedWidth = width;
        this.lastReportedHeight = height;
        this.onResize(this.serverId, width, height);
      }
    });
  }

  sendInspectorSubscribe() {
    if (!this.ws) return;
    this.ws.send(JSON.stringify({ type: 'inspector_subscribe', tab: this.inspectorActiveTab }));
  }

  sendInspectorUnsubscribe() {
    if (!this.ws) return;
    this.ws.send(JSON.stringify({ type: 'inspector_unsubscribe' }));
  }

  sendInspectorTab(tab) {
    if (!this.ws) return;
    this.ws.send(JSON.stringify({ type: 'inspector_tab', tab: tab }));
  }

  handleInspectorState(state) {
    this.inspectorState = state;
    this.renderInspectorSidebar();
    this.renderInspectorView();
  }

  renderInspectorSidebar() {
    const sidebarEl = this.inspectorEl.querySelector('.inspector-sidebar');
    if (!sidebarEl || !this.inspectorState) return;

    const size = this.inspectorState.size || {};

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

    const f = (field) => sidebarEl.querySelector(`[data-field="${field}"]`);
    f('screen-size').textContent = `${size.screen_width ?? 0}px x ${size.screen_height ?? 0}px`;
    f('grid-size').textContent = `${size.cols ?? 0}c x ${size.rows ?? 0}r`;
    f('cell-size').textContent = `${size.cell_width ?? 0}px x ${size.cell_height ?? 0}px`;
  }

  renderInspectorView() {
    const mainEl = this.inspectorEl.querySelector('.inspector-main');
    if (!mainEl) return;

    const size = this.inspectorState?.size || {};

    mainEl.innerHTML = `
      <div class="inspector-simple-section">
        <span class="inspector-simple-title">Terminal Size</span>
        <hr>
      </div>
      <div class="inspector-row"><span class="inspector-label">Grid</span><span class="inspector-value">${size.cols ?? 0} columns × ${size.rows ?? 0} rows</span></div>
      <div class="inspector-row"><span class="inspector-label">Screen</span><span class="inspector-value">${size.screen_width ?? 0} × ${size.screen_height ?? 0} px</span></div>
      <div class="inspector-row"><span class="inspector-label">Cell</span><span class="inspector-value">${size.cell_width ?? 0} × ${size.cell_height ?? 0} px</span></div>
    `;
  }

  setupResizeObserver() {
    this.resizeObserver = new ResizeObserver(() => {
      // Debounce resize to avoid flooding server during drag
      if (this.resizeTimeout) {
        clearTimeout(this.resizeTimeout);
      }
      this.resizeTimeout = setTimeout(() => {
        // Use container size for consistency with sendCreatePanel
        const rect = this.container.getBoundingClientRect();
        const width = Math.floor(rect.width);
        const height = Math.floor(rect.height);

        // Skip if panel is hidden (0x0) or size unchanged
        if (width === 0 || height === 0) return;
        if (width === this.lastReportedWidth && height === this.lastReportedHeight) return;

        this.lastReportedWidth = width;
        this.lastReportedHeight = height;

        if (this.serverId !== null && this.onResize) {
          this.onResize(this.serverId, width, height);
        }
      }, 16);  // ~60fps for responsive resize
    });
    this.resizeObserver.observe(this.element);
  }

  async initGPU() {
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
    this.context = this.canvas.getContext('webgpu');

    const format = navigator.gpu.getPreferredCanvasFormat();
    this.context.configure({
      device: this.device,
      format: format,
      alphaMode: 'opaque',
    });

    // XOR compute shader
    const xorShader = this.device.createShaderModule({
      code: `
        @group(0) @binding(0) var<storage, read> diff: array<u32>;
        @group(0) @binding(1) var<storage, read_write> prev: array<u32>;

        @compute @workgroup_size(256)
        fn main(@builtin(global_invocation_id) id: vec3<u32>) {
          let idx = id.x;
          if (idx < arrayLength(&prev)) {
            prev[idx] = prev[idx] ^ diff[idx];
          }
        }
      `
    });

    this.xorPipeline = this.device.createComputePipeline({
      layout: 'auto',
      compute: { module: xorShader, entryPoint: 'main' }
    });

    // RGB to RGBA compute shader
    const convertShader = this.device.createShaderModule({
      code: `
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
      `
    });

    this.rgbToRgbaPipeline = this.device.createComputePipeline({
      layout: 'auto',
      compute: { module: convertShader, entryPoint: 'main' }
    });

    // Fullscreen quad render
    const quadShader = this.device.createShaderModule({
      code: `
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
      `
    });

    this.pipeline = this.device.createRenderPipeline({
      layout: 'auto',
      vertex: { module: quadShader, entryPoint: 'vs' },
      fragment: {
        module: quadShader,
        entryPoint: 'fs',
        targets: [{ format: format }]
      },
      primitive: { topology: 'triangle-strip' }
    });

    this.sampler = this.device.createSampler({ magFilter: 'nearest', minFilter: 'nearest' });
    console.log('WebGPU initialized');
  }
  
  connect(host = 'localhost') {
    this.ws = new WebSocket(`ws://${host}:${PANEL_PORT}`);
    this.ws.binaryType = 'arraybuffer';

    this.ws.onopen = () => {
      console.log(`Panel ${this.id}: Connected`);
      if (this.serverId !== null) {
        // Connect to existing server panel
        this.sendConnectPanel(this.serverId);
      } else {
        // Request new panel creation
        this.sendCreatePanel();
      }
    };

    this.ws.onmessage = (event) => {
      // Check if it's a text message (JSON for inspector) or binary (frame data)
      if (typeof event.data === 'string') {
        try {
          const msg = JSON.parse(event.data);
          if (msg.type === 'inspector_state') {
            this.handleInspectorState(msg);
          }
        } catch (e) {
          console.error('Failed to parse JSON message:', e);
        }
      } else {
        this.handleFrame(event.data);
      }
    };

    this.ws.onclose = () => {
      console.log(`Panel ${this.id}: Disconnected`);
    };

    this.ws.onerror = () => {
      // Ignore errors during close (race between client/server closing)
      if (this.ws?.readyState === WebSocket.CLOSING || this.ws?.readyState === WebSocket.CLOSED) {
        return;
      }
      console.error(`Panel ${this.id}: WebSocket error`);
    };
  }

  sendConnectPanel(panelId) {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;
    const buf = new ArrayBuffer(5);
    const view = new DataView(buf);
    view.setUint8(0, ClientMsg.CONNECT_PANEL);
    view.setUint32(1, panelId, true);
    this.ws.send(buf);
    console.log(`Panel ${this.id}: Connecting to server panel ${panelId}`);
    // ResizeObserver will send resize via control WS
  }

  sendCreatePanel() {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;
    // Use container size since panel might be hidden (display: none)
    const rect = this.container.getBoundingClientRect();
    const width = Math.floor(rect.width) || 800;
    const height = Math.floor(rect.height) || 600;
    const scale = window.devicePixelRatio || 1;

    // Track what size we're creating with to avoid duplicate resize
    this.lastReportedWidth = width;
    this.lastReportedHeight = height;

    const buf = new ArrayBuffer(9);
    const view = new DataView(buf);
    view.setUint8(0, ClientMsg.CREATE_PANEL);
    view.setUint16(1, width, true);
    view.setUint16(3, height, true);
    view.setFloat32(5, scale, true);
    this.ws.send(buf);
    console.log(`Panel ${this.id}: Requesting new panel (${width}x${height} @${scale}x)`);
  }
  
  disconnect() {
    if (this.ws) {
      this.ws.close();
      this.ws = null;
    }
  }
  
  async handleFrame(data) {
    if (!this.device) {
      console.log('handleFrame: device not ready');
      return;
    }

    const view = new DataView(data);

    // Parse header (13 bytes)
    const frameType = view.getUint8(0);
    const sequence = view.getUint32(1, true);
    const width = view.getUint16(5, true);
    const height = view.getUint16(7, true);
    const compressedSize = view.getUint32(9, true);

    if (sequence % 100 === 0) {
      console.log(`Frame ${sequence}: ${width}x${height}, type=${frameType}, compressed=${compressedSize}`);
    }

    // Resize GPU resources if needed
    if (width !== this.width || height !== this.height) {
      console.log(`Resizing to ${width}x${height}`);
      this.width = width;
      this.height = height;
      this.canvas.width = width;
      this.canvas.height = height;
      this.createGPUBuffers(width, height);
    }

    // Decompress RGB data
    const compressed = new Uint8Array(data, 13, compressedSize);
    let rgb;
    try {
      rgb = await this.decompress(compressed);
      if (sequence % 100 === 0) {
        console.log(`Decompressed: ${rgb.length} bytes`);
      }
    } catch (e) {
      console.error('Decompress failed:', e);
      return;
    }

    // Verify size matches
    const expectedSize = width * height * 3;
    if (rgb.length !== expectedSize) {
      console.error(`Size mismatch: got ${rgb.length}, expected ${expectedSize}`);
      return;
    }

    // Pad RGB data to multiple of 4 bytes for WebGPU
    const alignedSize = Math.ceil(rgb.length / 4) * 4;
    let rgbAligned = rgb;
    if (rgb.length !== alignedSize) {
      rgbAligned = new Uint8Array(alignedSize);
      rgbAligned.set(rgb);
    }

    // Upload to GPU and process
    if (frameType === FrameType.KEYFRAME) {
      this.device.queue.writeBuffer(this.prevBuffer, 0, rgbAligned);
    } else {
      this.device.queue.writeBuffer(this.diffBuffer, 0, rgbAligned);

      const commandEncoder = this.device.createCommandEncoder();
      const pass = commandEncoder.beginComputePass();
      pass.setPipeline(this.xorPipeline);
      pass.setBindGroup(0, this.xorBindGroup);
      pass.dispatchWorkgroups(Math.ceil(rgb.length / 4 / 256));
      pass.end();
      this.device.queue.submit([commandEncoder.finish()]);
    }

    // Convert RGB→RGBA and render
    this.renderFrame();
    this.sequence = sequence;
  }

  createGPUBuffers(width, height) {
    const rgbSize = width * height * 3;
    const rgbAligned = Math.ceil(rgbSize / 4) * 4; // Align to 4 bytes

    this.prevBuffer = this.device.createBuffer({
      size: rgbAligned,
      usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
    });

    this.diffBuffer = this.device.createBuffer({
      size: rgbAligned,
      usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
    });

    this.texture = this.device.createTexture({
      size: [width, height],
      format: 'rgba8unorm',
      usage: GPUTextureUsage.STORAGE_BINDING | GPUTextureUsage.TEXTURE_BINDING,
    });

    // XOR bind group
    this.xorBindGroup = this.device.createBindGroup({
      layout: this.xorPipeline.getBindGroupLayout(0),
      entries: [
        { binding: 0, resource: { buffer: this.diffBuffer } },
        { binding: 1, resource: { buffer: this.prevBuffer } },
      ],
    });

    // RGB→RGBA bind group
    this.convertBindGroup = this.device.createBindGroup({
      layout: this.rgbToRgbaPipeline.getBindGroupLayout(0),
      entries: [
        { binding: 0, resource: { buffer: this.prevBuffer } },
        { binding: 1, resource: this.texture.createView() },
      ],
    });

    // Render bind group
    this.renderBindGroup = this.device.createBindGroup({
      layout: this.pipeline.getBindGroupLayout(0),
      entries: [
        { binding: 0, resource: this.texture.createView() },
        { binding: 1, resource: this.sampler },
      ],
    });
  }

  renderFrame() {
    const commandEncoder = this.device.createCommandEncoder();

    // RGB→RGBA compute pass
    const computePass = commandEncoder.beginComputePass();
    computePass.setPipeline(this.rgbToRgbaPipeline);
    computePass.setBindGroup(0, this.convertBindGroup);
    computePass.dispatchWorkgroups(
      Math.ceil(this.width / 16),
      Math.ceil(this.height / 16)
    );
    computePass.end();

    // Render pass
    const renderPass = commandEncoder.beginRenderPass({
      colorAttachments: [{
        view: this.context.getCurrentTexture().createView(),
        loadOp: 'clear',
        storeOp: 'store',
      }],
    });
    renderPass.setPipeline(this.pipeline);
    renderPass.setBindGroup(0, this.renderBindGroup);
    renderPass.draw(4);
    renderPass.end();

    this.device.queue.submit([commandEncoder.finish()]);
  }

  async decompress(compressed) {
    const ds = new DecompressionStream('deflate-raw');
    const writer = ds.writable.getWriter();
    writer.write(compressed);
    writer.close();
    const chunks = [];
    const reader = ds.readable.getReader();
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      chunks.push(value);
    }
    const totalLen = chunks.reduce((a, c) => a + c.length, 0);
    const result = new Uint8Array(totalLen);
    let offset = 0;
    for (const chunk of chunks) {
      result.set(chunk, offset);
      offset += chunk.length;
    }
    return result;
  }
  
  setupInputHandlers() {
    // Focus handling (kept for mouse events)
    this.canvas.tabIndex = 1;

    // Keyboard and paste are now handled at document level in App class

    // Mouse
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
    
    // Prevent context menu
    this.canvas.addEventListener('contextmenu', (e) => e.preventDefault());

    // Drag & drop file upload
    this.canvas.addEventListener('dragover', (e) => {
      e.preventDefault();
      e.dataTransfer.dropEffect = 'copy';
      this.canvas.style.opacity = '0.7';
    });

    this.canvas.addEventListener('dragleave', (e) => {
      e.preventDefault();
      this.canvas.style.opacity = '1';
    });

    this.canvas.addEventListener('drop', (e) => {
      e.preventDefault();
      this.canvas.style.opacity = '1';
      if (e.dataTransfer.files.length > 0) {
        for (const file of e.dataTransfer.files) {
          window.app?.uploadFile(file);
        }
      }
    });
  }

  getModifiers(e) {
    let mods = 0;
    if (e.shiftKey) mods |= 0x01;
    if (e.ctrlKey) mods |= 0x02;
    if (e.altKey) mods |= 0x04;
    if (e.metaKey) mods |= 0x08;
    return mods;
  }
  
  getCanvasCoords(e) {
    // Return coordinates in points (CSS pixels), not device pixels
    // Ghostty expects point coordinates matching the surface size
    const rect = this.canvas.getBoundingClientRect();
    return {
      x: e.clientX - rect.left,
      y: e.clientY - rect.top
    };
  }
  
  sendKeyInput(e, action) {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;

    // Send raw key code and key text to server
    // Format: [msg_type:u8][action:u8][mods:u8][code_len:u8][code:...][text_len:u8][text:...]
    const codeBytes = new TextEncoder().encode(e.code);
    const text = (e.key.length === 1) ? e.key : '';
    const textBytes = new TextEncoder().encode(text);

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

  sendTextInput(text) {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;

    const encoder = new TextEncoder();
    const textBytes = encoder.encode(text);
    const buf = new ArrayBuffer(1 + textBytes.length);
    const view = new Uint8Array(buf);
    view[0] = ClientMsg.TEXT_INPUT;
    view.set(textBytes, 1);
    this.ws.send(buf);
  }
  
  sendMouseButton(e, state) {
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
  
  sendMouseMove(e) {
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
  
  sendMouseScroll(e) {
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
  
  requestKeyframe() {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;
    this.ws.send(new Uint8Array([ClientMsg.REQUEST_KEYFRAME]));
  }
  
  pause() {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;
    this.ws.send(new Uint8Array([ClientMsg.PAUSE_STREAM]));
  }
  
  resume() {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;
    this.ws.send(new Uint8Array([ClientMsg.RESUME_STREAM]));
    this.requestKeyframe();
  }
  
  show() {
    this.element.classList.add('active');
    this.canvas.focus();
    this.resume();
  }
  
  hide() {
    this.element.classList.remove('active');
    this.pause();
  }
  
  destroy() {
    if (this.resizeObserver) {
      this.resizeObserver.disconnect();
      this.resizeObserver = null;
    }
    if (this.resizeTimeout) {
      clearTimeout(this.resizeTimeout);
      this.resizeTimeout = null;
    }
    this.disconnect();

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
    // Bind groups, pipelines, sampler are automatically garbage collected
    // but clear references to help GC
    this.xorBindGroup = null;
    this.convertBindGroup = null;
    this.renderBindGroup = null;
    this.pipeline = null;
    this.xorPipeline = null;
    this.rgbToRgbaPipeline = null;
    this.sampler = null;
    this.context = null;
    this.device = null;

    this.element.remove();
  }

  // Reparent panel to a new container
  reparent(newContainer) {
    this.container = newContainer;
    newContainer.appendChild(this.element);

    // Force resize check after reparenting since container changed
    setTimeout(() => {
      const rect = this.container.getBoundingClientRect();
      const width = Math.floor(rect.width);
      const height = Math.floor(rect.height);
      if (width > 0 && height > 0 &&
          (width !== this.lastReportedWidth || height !== this.lastReportedHeight)) {
        this.lastReportedWidth = width;
        this.lastReportedHeight = height;
        if (this.serverId !== null && this.onResize) {
          this.onResize(this.serverId, width, height);
        }
      }
    }, 50);  // Wait for layout to settle
  }
}

// ============================================================================
// SplitContainer - manages split panes within a tab
// ============================================================================

class SplitContainer {
  constructor(parent = null) {
    this.parent = parent;           // Parent SplitContainer (null for root)
    this.direction = null;          // 'horizontal' | 'vertical' | null (leaf)
    this.first = null;              // First child SplitContainer
    this.second = null;             // Second child SplitContainer
    this.panel = null;              // Panel (only for leaf nodes)
    this.ratio = 0.5;               // Split ratio (0.0 - 1.0)
    this.element = null;            // DOM element
    this.paneElement = null;        // Pane wrapper element (for leaves)
    this.divider = null;            // Divider element (for splits)
    this.isDragging = false;
  }

  // Create a leaf node with a panel
  static createLeaf(panel, parent = null) {
    const container = new SplitContainer(parent);
    container.panel = panel;
    container.element = document.createElement('div');
    container.element.className = 'split-pane';
    container.element.style.flex = '1';
    panel.reparent(container.element);
    return container;
  }

  // Split this container in a direction
  // splitDirection: 'right', 'down', 'left', 'up'
  split(splitDirection, newPanel) {
    if (this.direction !== null) {
      // Already split - delegate to the focused child
      console.error('Cannot split a non-leaf container directly');
      return null;
    }

    // Determine layout direction and order
    const isHorizontal = splitDirection === 'left' || splitDirection === 'right';
    const newPanelFirst = splitDirection === 'left' || splitDirection === 'up';

    // Convert leaf to split node
    const oldPanel = this.panel;
    this.panel = null;
    this.direction = isHorizontal ? 'horizontal' : 'vertical';

    if (newPanelFirst) {
      // New panel goes first (left/up)
      this.first = SplitContainer.createLeaf(newPanel, this);
      this.second = SplitContainer.createLeaf(oldPanel, this);
    } else {
      // Old panel stays first (right/down)
      this.first = SplitContainer.createLeaf(oldPanel, this);
      this.second = SplitContainer.createLeaf(newPanel, this);
    }

    // Rebuild DOM
    this.rebuildDOM();

    return newPanelFirst ? this.first : this.second;
  }

  rebuildDOM() {
    // Clear element
    const parent = this.element.parentElement;
    const oldElement = this.element;

    // Create new container element
    this.element = document.createElement('div');
    this.element.className = `split-container ${this.direction}`;

    // Build first pane
    this.element.appendChild(this.first.element);

    // Create divider
    this.divider = document.createElement('div');
    this.divider.className = 'split-divider';
    this.setupDividerDrag();
    this.element.appendChild(this.divider);

    // Build second pane
    this.element.appendChild(this.second.element);

    // Apply ratio
    this.applyRatio();

    // Replace old element
    if (parent) {
      parent.replaceChild(this.element, oldElement);
    }
  }

  setupDividerDrag() {
    let startPos = 0;
    let startRatio = 0;
    let containerSize = 0;

    const onMouseDown = (e) => {
      e.preventDefault();
      this.isDragging = true;
      this.divider.classList.add('dragging');

      const rect = this.element.getBoundingClientRect();
      if (this.direction === 'horizontal') {
        startPos = e.clientX;
        containerSize = rect.width;
      } else {
        startPos = e.clientY;
        containerSize = rect.height;
      }
      startRatio = this.ratio;

      document.addEventListener('mousemove', onMouseMove);
      document.addEventListener('mouseup', onMouseUp);
    };

    const onMouseMove = (e) => {
      if (!this.isDragging) return;

      let delta;
      if (this.direction === 'horizontal') {
        delta = e.clientX - startPos;
      } else {
        delta = e.clientY - startPos;
      }

      // Calculate new ratio (account for divider size)
      const dividerSize = this.direction === 'horizontal' ? 4 : 4;
      const availableSize = containerSize - dividerSize;
      const deltaRatio = delta / availableSize;

      this.ratio = Math.max(0.1, Math.min(0.9, startRatio + deltaRatio));
      this.applyRatio();
    };

    const onMouseUp = () => {
      this.isDragging = false;
      this.divider.classList.remove('dragging');
      document.removeEventListener('mousemove', onMouseMove);
      document.removeEventListener('mouseup', onMouseUp);
    };

    this.divider.addEventListener('mousedown', onMouseDown);
  }

  applyRatio() {
    if (!this.first || !this.second) return;

    const firstPercent = (this.ratio * 100).toFixed(2);
    const secondPercent = ((1 - this.ratio) * 100).toFixed(2);

    this.first.element.style.flex = `0 0 calc(${firstPercent}% - 2px)`;
    this.second.element.style.flex = `0 0 calc(${secondPercent}% - 2px)`;
  }

  // Find the container holding a specific panel
  findContainer(panel) {
    if (this.panel === panel) return this;
    if (this.first) {
      const found = this.first.findContainer(panel);
      if (found) return found;
    }
    if (this.second) {
      const found = this.second.findContainer(panel);
      if (found) return found;
    }
    return null;
  }

  // Get all panels in this container tree
  getAllPanels() {
    const panels = [];
    if (this.panel) {
      panels.push(this.panel);
    }
    if (this.first) {
      panels.push(...this.first.getAllPanels());
    }
    if (this.second) {
      panels.push(...this.second.getAllPanels());
    }
    return panels;
  }

  // Remove a panel and collapse the split
  removePanel(panel) {
    if (this.panel === panel) {
      // This is a leaf - parent needs to handle removal
      return true;
    }

    if (this.first && this.first.panel === panel) {
      // First child is the panel to remove - promote second
      const toRemove = this.first;
      this.promoteChild(this.second);
      // Clean up the removed container's element
      if (toRemove.element) toRemove.element.remove();
      return true;
    }

    if (this.second && this.second.panel === panel) {
      // Second child is the panel to remove - promote first
      const toRemove = this.second;
      this.promoteChild(this.first);
      // Clean up the removed container's element
      if (toRemove.element) toRemove.element.remove();
      return true;
    }

    // Recurse into children
    if (this.first && this.first.removePanel(panel)) return true;
    if (this.second && this.second.removePanel(panel)) return true;

    return false;
  }

  promoteChild(child) {
    // Clean up old divider
    if (this.divider) {
      this.divider.remove();
      this.divider = null;
    }

    // Replace this split with the remaining child
    if (child.direction !== null) {
      // Child is also a split - adopt its structure
      this.direction = child.direction;
      this.first = child.first;
      this.second = child.second;
      this.ratio = child.ratio;
      this.divider = child.divider;
      this.panel = null;
      if (this.first) this.first.parent = this;
      if (this.second) this.second.parent = this;
      this.rebuildDOM();
    } else {
      // Child is a leaf - become a leaf
      this.direction = null;
      this.first = null;
      this.second = null;
      this.panel = child.panel;

      // Rebuild as leaf
      const parent = this.element.parentElement;
      const oldElement = this.element;

      this.element = document.createElement('div');
      this.element.className = 'split-pane';
      this.element.style.flex = '1';
      this.panel.reparent(this.element);

      if (parent) {
        parent.replaceChild(this.element, oldElement);
      }
    }
  }

  // Destroy all panels in this container
  destroy() {
    if (this.panel) {
      this.panel.destroy();
    }
    if (this.first) {
      this.first.destroy();
    }
    if (this.second) {
      this.second.destroy();
    }
    if (this.element && this.element.parentElement) {
      this.element.remove();
    }
  }
}

// ============================================================================
// Key code mapping (JavaScript code -> ghostty key code)
// ============================================================================


// ============================================================================
// App - manages control connection and panels
// ============================================================================

class App {
  constructor() {
    this.controlWs = null;
    this.panels = new Map();        // panelId -> Panel
    this.tabs = new Map();          // tabId -> { root: SplitContainer, element: DOM, title: string }
    this.tabHistory = [];           // Tab activation history (most recent at end) for LRU switching
    this.activePanel = null;
    this.activeTab = null;          // Current tab ID
    this.nextLocalId = 1;
    this.nextTabId = 1;
    this.pendingSplit = null;       // Pending split operation waiting for panel_created

    this.tabsEl = document.getElementById('tabs');
    this.panelsEl = document.getElementById('panels');
    this.statusDot = document.getElementById('status-dot');

    document.getElementById('new-tab').addEventListener('click', () => {
      this.createTab();
    });

    document.getElementById('show-all-tabs').addEventListener('click', () => {
      this.showTabOverview();
    });

    // Global keyboard shortcuts (use capture phase to run before canvas handler)
    document.addEventListener('keydown', (e) => {
      // Skip if dialog is open (let user type)
      const commandPalette = document.getElementById('command-palette');
      const downloadDialog = document.getElementById('download-dialog');
      if ((commandPalette && commandPalette.classList.contains('visible')) ||
          (downloadDialog && downloadDialog.classList.contains('visible'))) {
        return;
      }

      // ⌘1-9 to switch tabs
      if (e.metaKey && e.key >= '1' && e.key <= '9') {
        e.preventDefault();
        e.stopPropagation();
        const index = parseInt(e.key) - 1;
        const tabs = Array.from(this.tabsEl.children);
        if (index < tabs.length) {
          const tabId = parseInt(tabs[index].dataset.id);
          this.switchToTab(tabId);
        }
        return;
      }
      // ⌘/ for new tab
      if (e.metaKey && e.key === '/') {
        e.preventDefault();
        e.stopPropagation();
        this.createTab();
        return;
      }
      // ⌘. to close tab/split
      if (e.metaKey && !e.shiftKey && e.key === '.') {
        e.preventDefault();
        e.stopPropagation();
        this.closeActivePanel();
        return;
      }
      // ⌘⇧. to close all tabs
      if (e.metaKey && e.shiftKey && (e.key === '>' || e.key === '.')) {
        e.preventDefault();
        e.stopPropagation();
        this.closeAllTabs();
        return;
      }
      // ⌘⇧A to show all tabs
      if (e.metaKey && e.shiftKey && (e.key === 'a' || e.key === 'A')) {
        e.preventDefault();
        e.stopPropagation();
        this.showTabOverview();
        return;
      }
      // ⌘⇧P to show command palette
      if (e.metaKey && e.shiftKey && (e.key === 'p' || e.key === 'P')) {
        e.preventDefault();
        e.stopPropagation();
        this.showCommandPalette();
        return;
      }
      // ⌘U for upload
      if (e.metaKey && !e.shiftKey && (e.key === 'u' || e.key === 'U')) {
        e.preventDefault();
        e.stopPropagation();
        this.showUploadDialog();
        return;
      }
      // ⌘⇧S for download
      if (e.metaKey && e.shiftKey && (e.key === 's' || e.key === 'S')) {
        e.preventDefault();
        e.stopPropagation();
        this.showDownloadDialog();
        return;
      }
      // ⌘A for select all
      if (e.metaKey && !e.shiftKey && e.key === 'a') {
        e.preventDefault();
        e.stopPropagation();
        if (this.activePanel?.serverId !== null) {
          this.sendViewAction(this.activePanel.serverId, 'select_all');
        }
        return;
      }
      // ⌘⇧V for paste selection - use ghostty's selection clipboard
      if (e.metaKey && e.shiftKey && e.key === 'v') {
        e.preventDefault();
        e.stopPropagation();
        if (this.activePanel?.serverId !== null) {
          this.sendViewAction(this.activePanel.serverId, 'paste_from_selection');
        }
        return;
      }
      // ⌘V for paste from system clipboard
      if (e.metaKey && !e.shiftKey && e.key === 'v') {
        e.preventDefault();
        e.stopPropagation();
        navigator.clipboard.readText().then(text => {
          if (this.activePanel && this.activePanel.ws) {
            const encoder = new TextEncoder();
            const textBytes = encoder.encode(text);
            const buf = new ArrayBuffer(1 + textBytes.length);
            const view = new Uint8Array(buf);
            view[0] = 0x05; // TEXT_INPUT
            view.set(textBytes, 1);
            this.activePanel.ws.send(buf);
          }
        });
        return;
      }
      // ⌘C for copy - send to ghostty
      if (e.metaKey && !e.shiftKey && (e.key === 'c' || e.key === 'C')) {
        e.preventDefault();
        e.stopPropagation();
        if (this.activePanel?.serverId !== null) {
          this.sendViewAction(this.activePanel.serverId, 'copy_to_clipboard');
        }
        return;
      }
      // Font size shortcuts
      if (e.metaKey && (e.key === '-' || e.key === '=' || e.key === '0')) {
        e.preventDefault();
        e.stopPropagation();
        if (this.activePanel?.serverId !== null) {
          if (e.key === '=') this.sendViewAction(this.activePanel.serverId, 'increase_font_size:1');
          else if (e.key === '-') this.sendViewAction(this.activePanel.serverId, 'decrease_font_size:1');
          else if (e.key === '0') this.sendViewAction(this.activePanel.serverId, 'reset_font_size');
        }
        return;
      }
      // ⌘D for split right, ⌘⇧D for split down
      if (e.metaKey && (e.key === 'd' || e.key === 'D')) {
        e.preventDefault();
        e.stopPropagation();
        if (this.activePanel) {
          if (e.shiftKey) {
            this.splitActivePanel('down');
          } else {
            this.splitActivePanel('right');
          }
        }
        return;
      }
      // ⌘⌥I to toggle inspector
      if (e.metaKey && e.altKey && e.code === 'KeyI') {
        e.preventDefault();
        e.stopPropagation();
        this.toggleInspector();
        return;
      }
      // ⌘⌥Arrow to navigate between splits
      if (e.metaKey && e.altKey && ['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown'].includes(e.key)) {
        e.preventDefault();
        e.stopPropagation();
        this.navigateSplit(e.key.replace('Arrow', '').toLowerCase());
        return;
      }
      // ⌘] and ⌘[ to cycle through splits
      if (e.metaKey && (e.key === ']' || e.key === '[')) {
        e.preventDefault();
        e.stopPropagation();
        this.cycleSplit(e.key === ']' ? 1 : -1);
        return;
      }
      // Forward all other keys to active panel
      if (this.activePanel) {
        e.preventDefault();
        this.activePanel.sendKeyInput(e, 1); // press
      }
    }, true);  // true = capture phase

    // Also capture keyup at document level
    document.addEventListener('keyup', (e) => {
      if (e.metaKey) return;
      if (this.activePanel) {
        e.preventDefault();
        this.activePanel.sendKeyInput(e, 0); // release
      }
    }, true);

    // Handle paste at document level
    document.addEventListener('paste', (e) => {
      e.preventDefault();
      const text = e.clipboardData.getData('text');
      if (text && this.activePanel) {
        this.activePanel.sendTextInput(text);
      }
    });
  }

  setStatus(state, message) {
    if (!this.statusDot) return;
    this.statusDot.className = '';
    if (state === 'connected') {
      this.statusDot.classList.add('connected');
    } else if (state === 'error') {
      this.statusDot.classList.add('error');
    }
    this.statusDot.title = message;
  }

  connect(host = 'localhost') {
    this.controlWs = new WebSocket(`ws://${host}:${CONTROL_PORT}`);
    
    this.controlWs.onopen = () => {
      this.setStatus('connected', 'Connected');
      console.log('Control channel connected');
      // Wait for panel_list to decide whether to create or connect
    };
    
    this.controlWs.onmessage = (event) => {
      if (event.data instanceof ArrayBuffer) {
        // Binary message (file transfer)
        this.handleBinaryFileData(event.data);
      } else if (event.data instanceof Blob) {
        // Blob - convert to ArrayBuffer
        event.data.arrayBuffer().then(buf => this.handleBinaryFileData(buf));
      } else {
        // Text message (JSON)
        this.handleControlMessage(JSON.parse(event.data));
      }
    };
    
    this.controlWs.onclose = () => {
      this.setStatus('disconnected', 'Disconnected');
      console.log('Control channel disconnected');
    };
    
    this.controlWs.onerror = (err) => {
      this.setStatus('error', 'Connection error');
      console.error('Control error:', err);
    };
  }
  
  handleControlMessage(msg) {
    console.log('Control message:', msg);

    switch (msg.type) {
      case 'panel_list':
        // Initial panel list from server with layout
        console.log('Panel list received:', msg.panels, 'layout:', msg.layout);
        if (msg.layout && msg.layout.tabs && msg.layout.tabs.length > 0) {
          // Restore layout from server
          console.log('Restoring layout from server');
          this.restoreLayoutFromServer(msg.layout);
        } else if (msg.panels && msg.panels.length > 0) {
          // Fallback: put all panels in one tab with splits
          console.log('Connecting to', msg.panels.length, 'existing panels (no layout)');
          this.reconnectPanelsAsSplits(msg.panels);
        } else {
          // No panels on server - create one
          console.log('No panels on server, creating new one');
          this.createTab();
        }
        // Server will send panel_title/panel_pwd messages after this
        break;

      case 'layout_update':
        // Layout changed on server
        console.log('Layout update received:', msg.layout);
        // TODO: Update local layout to match server (for multi-client sync)
        break;

      case 'panel_created':
        // Check if this is from a pending split
        if (this.pendingSplit) {
          console.log(`Completing pending split with new panel ${msg.panel_id}`);
          this.completePendingSplit(msg.panel_id);
        } else {
          // New panel created on server - update local panel's serverId
          for (const [, panel] of this.panels) {
            if (panel.serverId === null) {
              panel.serverId = msg.panel_id;
              console.log(`Local panel ${panel.id} assigned server ID ${msg.panel_id}`);
              break;
            }
          }
        }
        break;
        
      case 'panel_closed':
        // Server closed a panel - find and remove it
        this.handleServerPanelClosed(msg.panel_id);
        break;
        
      case 'panel_title':
        this.updatePanelTitle(msg.panel_id, msg.title);
        break;

      case 'panel_pwd':
        this.updatePanelPwd(msg.panel_id, msg.pwd);
        break;

      case 'panel_bell':
        this.handlePanelBell(msg.panel_id);
        break;

      case 'clipboard':
        // Clipboard data from server (base64 encoded)
        try {
          const text = atob(msg.data);
          navigator.clipboard.writeText(text).then(() => {
            console.log('Clipboard updated from terminal');
          }).catch(err => {
            console.error('Failed to write clipboard:', err);
          });
        } catch (e) {
          console.error('Failed to decode clipboard data:', e);
        }
        break;

      // File transfer uses binary messages now (0x10, 0x11, 0x12, 0x13)
    }
  }
  
  // Create a new panel (used internally)
  createPanel(container, serverId = null) {
    const localId = this.nextLocalId++;
    const onResize = (sid, w, h) => this.sendResizePanel(sid, w, h);
    const onViewAction = (sid, action) => this.sendViewAction(sid, action);
    const panel = new Panel(localId, container, serverId, onResize, onViewAction);
    panel.connect();
    this.panels.set(localId, panel);

    // Add click handler to focus this panel
    panel.element.addEventListener('mousedown', () => {
      this.setActivePanel(panel);
    });

    return panel;
  }

  // Create a new tab with a single panel
  createTab() {
    const tabId = this.nextTabId++;
    console.log(`createTab: creating tab ${tabId}, total tabs before: ${this.tabs.size}`);

    // Create tab content container
    const tabContent = document.createElement('div');
    tabContent.className = 'tab-content';
    tabContent.dataset.tabId = tabId;
    // Ensure we're appending to the correct element
    const panelsEl = document.getElementById('panels');
    panelsEl.appendChild(tabContent);
    console.log(`createTab: appended tabContent to #panels, children count: ${panelsEl.children.length}`);

    // Create panel in the tab content
    const panel = this.createPanel(tabContent, null);

    // Create root split container with the panel
    const root = SplitContainer.createLeaf(panel, null);
    tabContent.appendChild(root.element);

    // Store tab info
    this.tabs.set(tabId, { root, element: tabContent, title: '' });

    // Add tab to tab bar
    this.addTabUI(tabId, '');

    // Switch to new tab
    this.switchToTab(tabId);

    return tabId;
  }

  // Create a tab connected to an existing server panel
  createTabWithServerId(serverId) {
    // Check if already connected
    for (const [, panel] of this.panels) {
      if (panel.serverId === serverId) return;
    }

    const tabId = this.nextTabId++;

    // Create tab content container
    const tabContent = document.createElement('div');
    tabContent.className = 'tab-content';
    tabContent.dataset.tabId = tabId;
    this.panelsEl.appendChild(tabContent);

    // Create panel connected to server
    const panel = this.createPanel(tabContent, serverId);

    // Create root split container
    const root = SplitContainer.createLeaf(panel, null);
    tabContent.appendChild(root.element);

    // Store tab info
    this.tabs.set(tabId, { root, element: tabContent, title: '' });

    // Add tab to tab bar
    this.addTabUI(tabId, '');

    // Switch to tab if no active tab
    if (!this.activeTab) {
      this.switchToTab(tabId);
    }

    return tabId;
  }

  // Reconnect to multiple server panels as splits in a single tab
  reconnectPanelsAsSplits(serverPanels) {
    if (serverPanels.length === 0) return;

    // Check if already connected to any of these panels
    for (const p of serverPanels) {
      for (const [, panel] of this.panels) {
        if (panel.serverId === p.id) return; // Already connected
      }
    }

    const tabId = this.nextTabId++;

    // Create tab content container
    const tabContent = document.createElement('div');
    tabContent.className = 'tab-content';
    tabContent.dataset.tabId = tabId;
    this.panelsEl.appendChild(tabContent);

    // Create first panel
    const firstPanel = this.createPanel(tabContent, serverPanels[0].id);
    const root = SplitContainer.createLeaf(firstPanel, null);
    tabContent.appendChild(root.element);

    // Store tab info
    this.tabs.set(tabId, { root, element: tabContent, title: '' });

    // Add tab to tab bar
    this.addTabUI(tabId, '');

    // Switch to new tab
    this.switchToTab(tabId);

    // Add remaining panels as splits
    for (let i = 1; i < serverPanels.length; i++) {
      const serverId = serverPanels[i].id;
      const tab = this.tabs.get(tabId);
      if (!tab) break;

      // Find the current active panel's container
      const container = tab.root.findContainer(this.activePanel);
      if (!container) break;

      // Create new panel connected to server
      const newPanel = this.createPanel(document.createElement('div'), serverId);

      // Alternate between right and down splits for a grid-like layout
      const direction = (i % 2 === 1) ? 'right' : 'down';
      container.split(direction, newPanel);

      // Focus the new panel
      this.setActivePanel(newPanel);
    }
  }

  // Restore layout from server (tabs and splits)
  restoreLayoutFromServer(layout) {
    console.log('restoreLayoutFromServer:', layout);

    // Clear any existing panels/tabs
    for (const [tabId, tab] of this.tabs) {
      tab.root.destroy();
      tab.element.remove();
      this.removeTabUI(tabId);
    }
    this.tabs.clear();
    this.panels.clear();
    this.activeTab = null;
    this.activePanel = null;

    // Map server tab ID to client tab ID
    const serverToClientTabId = new Map();

    // Restore each tab from server layout
    for (const serverTab of layout.tabs) {
      const tabId = this.nextTabId++;
      serverToClientTabId.set(serverTab.id, tabId);

      // Create tab content container
      const tabContent = document.createElement('div');
      tabContent.className = 'tab-content';
      tabContent.dataset.tabId = tabId;
      this.panelsEl.appendChild(tabContent);

      // Build split tree from server node
      const root = this.buildSplitTreeFromNode(serverTab.root, tabContent);
      if (!root) {
        tabContent.remove();
        continue;
      }

      tabContent.appendChild(root.element);

      // Store tab info (include server tab ID for mapping)
      this.tabs.set(tabId, { root, element: tabContent, title: '', serverTabId: serverTab.id });

      // Add tab to tab bar (empty title shows ghost emoji)
      this.addTabUI(tabId, '');
    }

    // Switch to active tab using server's activeTabId
    let targetTabId = null;
    if (layout.activeTabId && serverToClientTabId.has(layout.activeTabId)) {
      targetTabId = serverToClientTabId.get(layout.activeTabId);
    } else if (this.tabs.size > 0) {
      // Fallback to first tab
      targetTabId = this.tabs.keys().next().value;
    }

    if (targetTabId !== null) {
      this.switchToTab(targetTabId);
    } else {
      // No tabs restored - create a new one
      this.createTab();
    }
  }

  // Build a SplitContainer tree from a server node
  buildSplitTreeFromNode(node, parentContainer) {
    if (!node) return null;

    if (node.type === 'leaf' && node.panelId !== undefined) {
      // Leaf node - create panel
      const panel = this.createPanel(parentContainer, node.panelId);
      return SplitContainer.createLeaf(panel, null);
    }

    if (node.type === 'split' && node.first && node.second) {
      // Split node - create container with children
      const container = new SplitContainer(null);
      container.direction = node.direction || 'horizontal';
      container.ratio = node.ratio || 0.5;

      // Create first child
      const first = this.buildSplitTreeFromNode(node.first, parentContainer);
      if (!first) return null;
      first.parent = container;

      // Create second child
      const second = this.buildSplitTreeFromNode(node.second, parentContainer);
      if (!second) return null;
      second.parent = container;

      container.first = first;
      container.second = second;

      // Build DOM for split container
      container.element = document.createElement('div');
      container.element.className = `split-container ${container.direction}`;

      container.element.appendChild(first.element);

      container.divider = document.createElement('div');
      container.divider.className = 'split-divider';
      container.setupDividerDrag();
      container.element.appendChild(container.divider);

      container.element.appendChild(second.element);

      container.applyRatio();

      return container;
    }

    return null;
  }

  // Split the active panel
  splitActivePanel(direction) {
    if (!this.activePanel || this.activeTab === null) return;
    if (this.activePanel.serverId === null) return; // Can't split if not connected

    const tab = this.tabs.get(this.activeTab);
    if (!tab) return;

    // Find the container holding the active panel
    const container = tab.root.findContainer(this.activePanel);
    if (!container) return;

    // Get container dimensions for the new panel
    const rect = container.element.getBoundingClientRect();
    const width = Math.floor(rect.width / 2) || 400;
    const height = Math.floor(rect.height / 2) || 300;
    const scale = window.devicePixelRatio || 1;

    // Map client direction to server direction
    const serverDirection = (direction === 'left' || direction === 'right') ? 'horizontal' : 'vertical';

    // Store pending split info - will complete when panel_created arrives
    this.pendingSplit = {
      parentPanelId: this.activePanel.serverId,
      direction: direction,
      container: container,
      tabId: this.activeTab
    };

    // Send split request to server
    this.sendSplitPanel(this.activePanel.serverId, serverDirection, width, height, scale);
  }

  // Send split_panel request to server
  sendSplitPanel(parentPanelId, direction, width, height, scale) {
    if (!this.controlWs || this.controlWs.readyState !== WebSocket.OPEN) return;
    const msg = JSON.stringify({
      type: 'split_panel',
      panel_id: parentPanelId,
      direction: direction,
      width: width,
      height: height,
      scale: scale
    });
    this.controlWs.send(msg);
    console.log(`Sent split_panel: parent=${parentPanelId}, direction=${direction}`);
  }

  // Complete a pending split when panel_created arrives
  completePendingSplit(newPanelId) {
    const split = this.pendingSplit;
    this.pendingSplit = null;

    if (!split) return;

    const tab = this.tabs.get(split.tabId);
    if (!tab) return;

    // Create new panel connected to the server panel
    const newPanel = this.createPanel(document.createElement('div'), newPanelId);

    // Perform the local split
    const newContainer = split.container.split(split.direction, newPanel);
    if (newContainer) {
      // Focus the new panel
      this.setActivePanel(newPanel);
    }
  }

  // Close the active panel (or tab if last panel in tab)
  closeActivePanel() {
    // If quick terminal is visible, close it first
    const quickTerminal = document.getElementById('quick-terminal');
    if (quickTerminal?.classList.contains('visible')) {
      this.toggleQuickTerminal();
      return;
    }

    if (!this.activePanel || this.activeTab === null) return;

    const tab = this.tabs.get(this.activeTab);
    if (!tab) return;

    // Get all panels in the tab
    const tabPanels = tab.root.getAllPanels();

    if (tabPanels.length === 1) {
      // Last panel in tab - close the whole tab
      this.closeTab(this.activeTab);
    } else {
      // Multiple panels - just close this one
      const panelToClose = this.activePanel;
      const panelId = panelToClose.id;

      // Find another panel to focus
      const otherPanel = tabPanels.find(p => p !== panelToClose);

      // Remove from split container
      tab.root.removePanel(panelToClose);

      // Tell server to close
      if (panelToClose.serverId !== null) {
        this.sendClosePanel(panelToClose.serverId);
      }

      // Destroy panel
      panelToClose.destroy();
      this.panels.delete(panelId);

      // Focus other panel
      if (otherPanel) {
        this.setActivePanel(otherPanel);
      }
    }
  }

  // Close a tab
  closeTab(tabId) {
    const tab = this.tabs.get(tabId);
    if (!tab) return;

    // If last tab, create new one first
    if (this.tabs.size === 1) {
      this.createTab();
    }

    // Get all panels in tab
    const tabPanels = tab.root.getAllPanels();

    // Close all panels
    for (const panel of tabPanels) {
      if (panel.serverId !== null) {
        this.sendClosePanel(panel.serverId);
      }
      this.panels.delete(panel.id);
    }

    // Destroy the split container (will destroy panels)
    tab.root.destroy();
    tab.element.remove();
    this.tabs.delete(tabId);
    this.removeTabUI(tabId);

    // Remove from tab history
    const historyIdx = this.tabHistory.indexOf(tabId);
    if (historyIdx !== -1) {
      this.tabHistory.splice(historyIdx, 1);
    }

    // Switch to last recently used tab if this was active
    if (this.activeTab === tabId) {
      this.activeTab = null;
      this.activePanel = null;
      // Find most recently used tab that still exists
      for (let i = this.tabHistory.length - 1; i >= 0; i--) {
        if (this.tabs.has(this.tabHistory[i])) {
          this.switchToTab(this.tabHistory[i]);
          return;
        }
      }
      // Fallback: switch to any remaining tab
      const remaining = this.tabs.keys().next();
      if (!remaining.done) {
        this.switchToTab(remaining.value);
      }
    }
  }

  // Close all tabs
  closeAllTabs() {
    const tabIds = Array.from(this.tabs.keys());
    if (tabIds.length === 0) return;

    // Create new tab first
    this.createTab();

    // Close old tabs
    for (const tabId of tabIds) {
      this.closeTab(tabId);
    }
  }

  // Set active panel (for focus tracking)
  setActivePanel(panel) {
    if (this.activePanel === panel) return;

    // Update active panel
    this.activePanel = panel;

    // Focus the panel's canvas
    if (panel && panel.canvas) {
      panel.canvas.focus();
    }

    // Notify server of focus change (for remembering active tab)
    if (panel && panel.serverId !== null) {
      this.sendFocusPanel(panel.serverId);
    }

    // Update title
    this.updateTitleForPanel(panel);
  }

  // Send focus_panel to server to track active tab
  sendFocusPanel(serverId) {
    if (!this.controlWs || this.controlWs.readyState !== WebSocket.OPEN) return;
    const msg = JSON.stringify({ type: 'focus_panel', panel_id: serverId });
    this.controlWs.send(msg);
  }

  // Navigate to an adjacent split pane
  navigateSplit(direction) {
    if (!this.activePanel || this.activeTab === null) return;

    const tab = this.tabs.get(this.activeTab);
    if (!tab) return;

    const panels = tab.root.getAllPanels();
    if (panels.length <= 1) return;

    // Get bounding rects for all panels
    const activeRect = this.activePanel.element.getBoundingClientRect();
    const activeCenterX = activeRect.left + activeRect.width / 2;
    const activeCenterY = activeRect.top + activeRect.height / 2;

    let bestPanel = null;
    let bestDistance = Infinity;

    for (const panel of panels) {
      if (panel === this.activePanel) continue;

      const rect = panel.element.getBoundingClientRect();
      const centerX = rect.left + rect.width / 2;
      const centerY = rect.top + rect.height / 2;

      // Check if panel is in the right direction
      let isInDirection = false;
      let distance = 0;

      switch (direction) {
        case 'left':
          isInDirection = centerX < activeCenterX;
          distance = activeCenterX - centerX + Math.abs(centerY - activeCenterY) * 0.1;
          break;
        case 'right':
          isInDirection = centerX > activeCenterX;
          distance = centerX - activeCenterX + Math.abs(centerY - activeCenterY) * 0.1;
          break;
        case 'up':
          isInDirection = centerY < activeCenterY;
          distance = activeCenterY - centerY + Math.abs(centerX - activeCenterX) * 0.1;
          break;
        case 'down':
          isInDirection = centerY > activeCenterY;
          distance = centerY - activeCenterY + Math.abs(centerX - activeCenterX) * 0.1;
          break;
      }

      if (isInDirection && distance < bestDistance) {
        bestDistance = distance;
        bestPanel = panel;
      }
    }

    if (bestPanel) {
      this.setActivePanel(bestPanel);
    }
  }

  // Cycle through split panes
  cycleSplit(delta) {
    if (!this.activePanel || this.activeTab === null) return;

    const tab = this.tabs.get(this.activeTab);
    if (!tab) return;

    const panels = tab.root.getAllPanels();
    if (panels.length <= 1) return;

    const currentIndex = panels.indexOf(this.activePanel);
    if (currentIndex === -1) return;

    let newIndex = currentIndex + delta;
    if (newIndex < 0) newIndex = panels.length - 1;
    if (newIndex >= panels.length) newIndex = 0;

    this.setActivePanel(panels[newIndex]);
  }

  // Handle server notifying us that a panel was closed
  handleServerPanelClosed(serverId) {
    // Find the panel with this server ID
    let targetPanel = null;
    for (const [, panel] of this.panels) {
      if (panel.serverId === serverId) {
        targetPanel = panel;
        break;
      }
    }
    if (!targetPanel) return;

    // Check if this is the quick terminal panel
    if (targetPanel === this.quickTerminalPanel) {
      const container = document.getElementById('quick-terminal');
      if (container) container.classList.remove('visible');
      targetPanel.destroy();
      this.panels.delete(targetPanel.id);
      this.quickTerminalPanel = null;
      // Restore previous active panel or current active tab's panel
      if (this.previousActivePanel) {
        this.setActivePanel(this.previousActivePanel);
        this.previousActivePanel = null;
      } else if (this.activeTab !== null) {
        // Update title for current active tab
        const tab = this.tabs.get(this.activeTab);
        if (tab) {
          const tabPanels = tab.root.getAllPanels();
          if (tabPanels.length > 0) {
            this.setActivePanel(tabPanels[0]);
          }
        }
      }
      return;
    }

    // Clear previousActivePanel if it's the panel being closed
    if (this.previousActivePanel === targetPanel) {
      this.previousActivePanel = null;
    }

    // Find which tab this panel belongs to
    const tabId = this.findTabForPanel(targetPanel);
    if (tabId === null) return;

    const tab = this.tabs.get(tabId);
    if (!tab) return;

    // Get all panels in the tab
    const tabPanels = tab.root.getAllPanels();

    if (tabPanels.length === 1) {
      // Last panel in tab - close the whole tab
      // But first create a new tab if this is the last tab
      if (this.tabs.size === 1) {
        this.createTab();
      }

      tab.root.destroy();
      tab.element.remove();
      this.tabs.delete(tabId);
      this.removeTabUI(tabId);
      this.panels.delete(targetPanel.id);

      // Remove from tab history
      const historyIdx = this.tabHistory.indexOf(tabId);
      if (historyIdx !== -1) {
        this.tabHistory.splice(historyIdx, 1);
      }

      if (this.activeTab === tabId) {
        this.activeTab = null;
        this.activePanel = null;
        // Find most recently used tab that still exists
        for (let i = this.tabHistory.length - 1; i >= 0; i--) {
          if (this.tabs.has(this.tabHistory[i])) {
            this.switchToTab(this.tabHistory[i]);
            return;
          }
        }
        // Fallback: switch to any remaining tab
        const remaining = this.tabs.keys().next();
        if (!remaining.done) {
          this.switchToTab(remaining.value);
        }
      }
    } else {
      // Multiple panels - just close this one
      const panelId = targetPanel.id;

      // Find another panel to focus if this was active
      const wasActive = targetPanel === this.activePanel;
      const otherPanel = tabPanels.find(p => p !== targetPanel);

      // Remove from split container
      tab.root.removePanel(targetPanel);

      // Destroy panel
      targetPanel.destroy();
      this.panels.delete(panelId);

      // Focus other panel if needed
      if (wasActive && otherPanel) {
        this.setActivePanel(otherPanel);
      }
    }
  }

  sendClosePanel(serverId) {
    if (!this.controlWs || this.controlWs.readyState !== WebSocket.OPEN) return;
    const msg = JSON.stringify({ type: 'close_panel', panel_id: serverId });
    this.controlWs.send(msg);
    console.log('Sent close_panel for server panel', serverId);
  }

  sendResizePanel(serverId, width, height) {
    if (!this.controlWs || this.controlWs.readyState !== WebSocket.OPEN) return;
    const msg = JSON.stringify({ type: 'resize_panel', panel_id: serverId, width, height });
    this.controlWs.send(msg);
    console.log(`Sent resize_panel for server panel ${serverId}: ${width}x${height}`);
  }

  sendViewAction(serverId, action) {
    if (!this.controlWs || this.controlWs.readyState !== WebSocket.OPEN) return;
    const msg = JSON.stringify({ type: 'view_action', panel_id: serverId, action });
    this.controlWs.send(msg);
    console.log(`Sent view_action for server panel ${serverId}: ${action}`);
  }

  // Switch to a tab
  switchToTab(tabId) {
    console.log(`switchToTab: switching to tab ${tabId}, total tabs: ${this.tabs.size}`);

    // Update tab history (LRU: move to end)
    const historyIdx = this.tabHistory.indexOf(tabId);
    if (historyIdx !== -1) {
      this.tabHistory.splice(historyIdx, 1);
    }
    this.tabHistory.push(tabId);

    // Hide ALL tabs first (ensures clean state)
    for (const [tid, t] of this.tabs) {
      t.element.classList.remove('active');
      console.log(`switchToTab: removed active from tab ${tid}`);
      if (tid !== tabId) {
        // Pause panels in non-active tabs
        for (const panel of t.root.getAllPanels()) {
          panel.hide();
        }
      }
    }

    // Show the target tab
    const tab = this.tabs.get(tabId);
    if (tab) {
      tab.element.classList.add('active');
      console.log(`switchToTab: added active to tab ${tabId}`);
      this.activeTab = tabId;
      this.updateTabUIActive(tabId);

      // Resume all panels in new tab
      const tabPanels = tab.root.getAllPanels();
      for (const panel of tabPanels) {
        panel.show();
      }

      // Set active panel to first panel if none set (use setActivePanel to notify server)
      if (!this.activePanel || !tabPanels.includes(this.activePanel)) {
        this.setActivePanel(tabPanels[0] || null);
      } else {
        // Still notify server of the focus change even if panel didn't change
        if (this.activePanel && this.activePanel.serverId !== null) {
          this.sendFocusPanel(this.activePanel.serverId);
        }
        this.updateTitleForPanel(this.activePanel);
      }
    }
  }

  // Update title bar for a panel
  updateTitleForPanel(panel) {
    // Find which tab this panel belongs to
    for (const [tabId, tab] of this.tabs) {
      if (tab.root.findContainer(panel)) {
        const tabEl = this.tabsEl.querySelector(`[data-id="${tabId}"] .title`);
        let title = tabEl ? tabEl.textContent : '';
        // Ghost emoji means no title set yet
        if (title === '👻') title = '';

        const appTitle = document.getElementById('app-title');
        if (title) {
          document.title = title;
          if (appTitle) appTitle.textContent = title;
        } else {
          document.title = '👻';
          if (appTitle) appTitle.textContent = '👻';
        }
        this.updateIndicatorForPanel(panel, title);
        break;
      }
    }
  }

  // Add tab UI element
  addTabUI(tabId, title) {
    const tab = document.createElement('div');
    tab.className = 'tab';
    tab.dataset.id = tabId;

    // Get tab index for hotkey (1-9)
    const tabIndex = this.tabsEl.children.length + 1;
    const hotkeyHint = tabIndex <= 9 ? `⌘${tabIndex}` : '';

    const displayTitle = title || '👻';
    tab.innerHTML = `<span class="close">×</span><span class="title-wrapper"><span class="indicator">•</span><span class="title">${displayTitle}</span></span><span class="hotkey">${hotkeyHint}</span>`;

    tab.addEventListener('click', (e) => {
      if (!e.target.classList.contains('close')) {
        this.switchToTab(tabId);
      }
    });

    tab.querySelector('.close').addEventListener('click', (e) => {
      e.stopPropagation();
      this.closeTab(tabId);
    });

    this.tabsEl.appendChild(tab);
  }

  // Remove tab UI element
  removeTabUI(tabId) {
    const tab = this.tabsEl.querySelector(`[data-id="${tabId}"]`);
    if (tab) tab.remove();
    this.updateHotkeyHints();
  }

  updateHotkeyHints() {
    const tabs = this.tabsEl.querySelectorAll('.tab');
    tabs.forEach((tab, index) => {
      const hotkey = tab.querySelector('.hotkey');
      if (hotkey) {
        hotkey.textContent = index < 9 ? `⌘${index + 1}` : '';
      }
    });
  }

  updateTabUIActive(tabId) {
    for (const tab of this.tabsEl.children) {
      tab.classList.toggle('active', tab.dataset.id == tabId);
    }
  }

  // Find which tab a panel belongs to
  findTabForPanel(panel) {
    for (const [tabId, tab] of this.tabs) {
      if (tab.root.findContainer(panel)) {
        return tabId;
      }
    }
    return null;
  }

  updatePanelTitle(serverId, title) {
    // Find panel by server ID
    let targetPanel = null;
    for (const [, panel] of this.panels) {
      if (panel.serverId === serverId) {
        targetPanel = panel;
        break;
      }
    }
    if (!targetPanel) return;

    // Find which tab this panel belongs to and update tab title
    const tabId = this.findTabForPanel(targetPanel);
    if (tabId !== null) {
      const tabEl = this.tabsEl.querySelector(`[data-id="${tabId}"] .title`);
      if (tabEl) tabEl.textContent = title;

      // Update tab indicator (• for at prompt, ✱ for command running)
      const indicatorEl = this.tabsEl.querySelector(`[data-id="${tabId}"] .indicator`);
      if (indicatorEl) {
        const isAtPrompt = this.isAtPrompt(targetPanel, title);
        indicatorEl.textContent = isAtPrompt ? '•' : '✱';
      }

      // Update tab data
      const tab = this.tabs.get(tabId);
      if (tab) tab.title = title;
    }

    // Update document title and app title if this is the active panel
    if (targetPanel === this.activePanel) {
      document.title = title;
      const appTitle = document.getElementById('app-title');
      if (appTitle) appTitle.textContent = title;
      this.updateIndicatorForPanel(targetPanel, title);
    }
  }

  // Check if terminal is at prompt (title matches pwd) or running a command
  isAtPrompt(panel, title) {
    if (!panel || !panel.pwd || !title) return true;  // No pwd yet = at prompt
    const pwd = panel.pwd;
    const dirName = pwd.split('/').pop() || pwd;
    // At prompt if title contains the directory name or looks like a path
    return title.includes(dirName) || title.includes('/') || title === pwd;
  }

  updatePanelPwd(serverId, pwd) {
    // Find panel by server ID
    let targetPanel = null;
    for (const [, panel] of this.panels) {
      if (panel.serverId === serverId) {
        targetPanel = panel;
        break;
      }
    }
    if (!targetPanel) return;

    targetPanel.pwd = pwd;

    // Update tab indicator to match (both tab and title should show same state)
    const tabId = this.findTabIdForPanel(targetPanel);
    if (tabId !== null) {
      const tab = this.tabs.get(tabId);
      const currentTitle = tab?.title || '';
      const indicatorEl = this.tabsEl.querySelector(`[data-id="${tabId}"] .indicator`);
      if (indicatorEl) {
        const isAtPrompt = this.isAtPrompt(targetPanel, currentTitle);
        indicatorEl.textContent = isAtPrompt ? '•' : '✱';
      }
    }

    // If this is the active panel, update the title indicator
    if (targetPanel === this.activePanel) {
      const appTitle = document.getElementById('app-title');
      const currentTitle = appTitle ? appTitle.textContent : '';
      this.updateIndicatorForPanel(targetPanel, currentTitle);
    }
  }

  findTabIdForPanel(panel) {
    for (const [tabId, tab] of this.tabs) {
      const panels = tab.root.getAllPanels();
      if (panels.includes(panel)) return tabId;
    }
    return null;
  }

  updateIndicatorForPanel(panel, title) {
    // Format: folder + indicator (• at prompt, ✱ running)
    const isAtPrompt = this.isAtPrompt(panel, title);
    const stateIndicator = isAtPrompt ? '•' : '✱';
    const indicator = panel.pwd ? '📁' : '';
    this.updateTitleIndicator(indicator, stateIndicator);
  }

  updateTitleIndicator(indicator, stateIndicator) {
    const el = document.getElementById('title-indicator');
    if (el) el.innerHTML = indicator;
    const elState = document.getElementById('title-state-indicator');
    if (elState) elState.innerHTML = stateIndicator;
  }

  handlePanelBell(serverId) {
    // Find panel by server ID
    let targetPanel = null;
    for (const [, panel] of this.panels) {
      if (panel.serverId === serverId) {
        targetPanel = panel;
        break;
      }
    }
    if (!targetPanel) return;

    // Find which tab this panel belongs to
    const tabId = this.findTabForPanel(targetPanel);
    if (tabId !== null) {
      // Flash the tab if not active
      const tabEl = this.tabsEl.querySelector(`[data-id="${tabId}"]`);
      if (tabEl && !tabEl.classList.contains('active')) {
        tabEl.classList.add('bell');
        setTimeout(() => tabEl.classList.remove('bell'), 500);
      }
    }

    // Show bell indicator in title bar if this is the active panel
    if (targetPanel === this.activePanel) {
      this.updateTitleIndicator('🔔');
      // Reset to normal indicator after 2 seconds
      setTimeout(() => {
        const appTitle = document.getElementById('app-title');
        this.updateIndicatorForPanel(targetPanel, appTitle ? appTitle.textContent : '');
      }, 2000);
    }
  }

  // Show all tabs overview with live scaled previews
  showTabOverview() {
    const overlay = document.getElementById('tab-overview');
    const grid = document.getElementById('tab-overview-grid');
    if (!overlay || !grid) return;

    // Clear existing previews
    grid.innerHTML = '';

    // Store original parent to restore tabs later
    this.tabOverviewOriginalParent = this.panelsEl;
    this.tabOverviewTabs = [];

    // Disable resize observers during overview to prevent backend resize
    for (const [, panel] of this.panels) {
      if (panel.resizeObserver) {
        panel.resizeObserver.disconnect();
      }
    }

    // Get panels container dimensions for scaling - match aspect ratio of actual panels
    const panelsRect = this.panelsEl.getBoundingClientRect();
    const aspectRatio = panelsRect.width / panelsRect.height;
    const previewHeight = 200;
    const previewWidth = Math.round(previewHeight * aspectRatio);
    const scale = Math.min(previewWidth / panelsRect.width, previewHeight / panelsRect.height);
    const scaledWidth = panelsRect.width * scale;
    const scaledHeight = panelsRect.height * scale;

    // Create preview for each tab with live content
    for (const [tabId, tab] of this.tabs) {
      const preview = document.createElement('div');
      preview.className = 'tab-preview';
      if (tabId === this.activeTab) {
        preview.classList.add('active');
      }

      // Create content wrapper that will hold the scaled tab
      const content = document.createElement('div');
      content.className = 'tab-preview-content';
      content.style.cssText = `overflow: hidden; position: relative; width: ${scaledWidth}px; height: ${scaledHeight}px;`;

      // Create a container for the scaled content
      const scaleWrapper = document.createElement('div');
      scaleWrapper.style.cssText = `
        width: ${panelsRect.width}px;
        height: ${panelsRect.height}px;
        transform: scale(${scale});
        transform-origin: top left;
        pointer-events: none;
        position: absolute;
        top: 0;
        left: 0;
      `;

      // Move the actual tab element into the preview (will restore later)
      tab.element.style.display = 'flex';
      tab.element.style.position = 'relative';
      tab.element.style.width = '100%';
      tab.element.style.height = '100%';
      scaleWrapper.appendChild(tab.element);
      content.appendChild(scaleWrapper);

      // Store for restoration
      this.tabOverviewTabs.push({ tabId, tab, element: tab.element });

      // Create title bar (on top)
      const titleBar = document.createElement('div');
      titleBar.className = 'tab-preview-title';

      const titleText = document.createElement('span');
      titleText.className = 'tab-preview-title-text';

      // Add indicator (• for idle at prompt, * for running command)
      const indicator = document.createElement('span');
      indicator.className = 'tab-preview-indicator';
      const panels = tab.root.getAllPanels();
      const firstPanel = panels[0];
      // Check if command is running by comparing title to pwd
      const isAtPrompt = firstPanel && firstPanel.pwd && tab.title &&
        (tab.title.includes(firstPanel.pwd) || tab.title.endsWith(firstPanel.pwd.split('/').pop()));
      indicator.textContent = isAtPrompt ? '•' : '✱';

      const titleLabel = document.createElement('span');
      titleLabel.className = 'tab-preview-title-label';
      titleLabel.textContent = tab.title || '👻';

      titleText.appendChild(indicator);
      titleText.appendChild(titleLabel);

      // Spacer on left to balance close button on right (for centering title)
      const spacer = document.createElement('span');
      spacer.className = 'tab-preview-spacer';

      const closeBtn = document.createElement('span');
      closeBtn.className = 'tab-preview-close';
      closeBtn.textContent = '✕';
      closeBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        // Restore tabs first before closing
        this.restoreTabsFromOverview();
        this.closeTab(tabId);
        // Refresh the overview if still open
        if (this.tabs.size > 0) {
          this.showTabOverview();
        } else {
          this.hideTabOverview();
        }
      });

      titleBar.appendChild(closeBtn);
      titleBar.appendChild(titleText);
      titleBar.appendChild(spacer);

      // Title on top, content below
      preview.appendChild(titleBar);
      preview.appendChild(content);

      // Click to switch to tab
      preview.addEventListener('click', () => {
        this.hideTabOverview();
        this.switchToTab(tabId);
      });

      grid.appendChild(preview);
    }

    // Add "+" new tab card at the end (match preview size)
    const newTabCard = document.createElement('div');
    newTabCard.className = 'tab-preview-new';
    newTabCard.style.cssText = `width: ${scaledWidth}px; height: ${scaledHeight + 44}px;`;
    const newTabIcon = document.createElement('span');
    newTabIcon.className = 'tab-preview-new-icon';
    newTabIcon.textContent = '+';
    newTabCard.appendChild(newTabIcon);
    newTabCard.addEventListener('click', () => {
      this.hideTabOverview();
      this.createTab();
    });
    grid.appendChild(newTabCard);

    // Show overlay
    overlay.classList.add('visible');

    // Close on escape or click outside
    this.tabOverviewCloseHandler = (e) => {
      if (e.key === 'Escape' || e.target === overlay) {
        this.hideTabOverview();
      }
    };
    document.addEventListener('keydown', this.tabOverviewCloseHandler);
    overlay.addEventListener('click', this.tabOverviewCloseHandler);
  }

  // Restore tab elements back to panels container
  restoreTabsFromOverview() {
    if (!this.tabOverviewTabs) return;

    for (const { tab, element } of this.tabOverviewTabs) {
      // Reset styles
      element.style.display = '';
      element.style.position = '';
      element.style.width = '';
      element.style.height = '';
      // Move back to panels container
      this.panelsEl.appendChild(element);
    }
    this.tabOverviewTabs = null;

    // Re-enable resize observers
    for (const [, panel] of this.panels) {
      if (panel.resizeObserver && panel.element) {
        panel.resizeObserver.observe(panel.element);
      }
    }
  }

  hideTabOverview() {
    // Restore tabs first
    this.restoreTabsFromOverview();

    const overlay = document.getElementById('tab-overview');
    if (overlay) {
      overlay.classList.remove('visible');
      overlay.querySelector('#tab-overview-grid').innerHTML = '';
      // Remove event listeners
      if (this.tabOverviewCloseHandler) {
        document.removeEventListener('keydown', this.tabOverviewCloseHandler);
        overlay.removeEventListener('click', this.tabOverviewCloseHandler);
        this.tabOverviewCloseHandler = null;
      }
    }

    // Re-apply active state and refocus
    if (this.activeTab !== null) {
      const tab = this.tabs.get(this.activeTab);
      if (tab) {
        // Hide all tabs, show active
        for (const [, t] of this.tabs) {
          t.element.classList.remove('active');
        }
        tab.element.classList.add('active');
      }
    }

    // Refocus the active panel
    if (this.activePanel && this.activePanel.canvas) {
      this.activePanel.canvas.focus();
    }
  }

  // Command Palette
  getCommands() {
    const commands = [
      // Text Operations
      { title: 'Copy to Clipboard', action: 'copy_to_clipboard', description: 'Copy selected text' },
      { title: 'Paste from Clipboard', action: 'paste_from_clipboard', description: 'Paste contents of clipboard' },
      { title: 'Paste from Selection', action: 'paste_from_selection', description: 'Paste from selection clipboard' },
      { title: 'Select All', action: 'select_all', description: 'Select all text' },

      // Font Control
      { title: 'Increase Font Size', action: 'increase_font_size:1', description: 'Make text larger', shortcut: '⌘=' },
      { title: 'Decrease Font Size', action: 'decrease_font_size:1', description: 'Make text smaller', shortcut: '⌘-' },
      { title: 'Reset Font Size', action: 'reset_font_size', description: 'Reset to default size', shortcut: '⌘0' },

      // Screen Operations
      { title: 'Clear Screen', action: 'clear_screen', description: 'Clear screen and scrollback' },
      { title: 'Scroll to Top', action: 'scroll_to_top', description: 'Scroll to top of buffer' },
      { title: 'Scroll to Bottom', action: 'scroll_to_bottom', description: 'Scroll to bottom of buffer' },
      { title: 'Scroll Page Up', action: 'scroll_page_up', description: 'Scroll up one page' },
      { title: 'Scroll Page Down', action: 'scroll_page_down', description: 'Scroll down one page' },

      // Tab Management (local)
      { title: 'New Tab', action: '_new_tab', description: 'Open a new tab', shortcut: '⌘/' },
      { title: 'Close Tab', action: '_close_tab', description: 'Close current tab', shortcut: '⌘.' },
      { title: 'Show All Tabs', action: '_show_all_tabs', description: 'Show tab overview', shortcut: '⌘⇧A' },

      // Split Management (local)
      { title: 'Split Right', action: '_split_right', description: 'Split pane to the right', shortcut: '⌘D' },
      { title: 'Split Down', action: '_split_down', description: 'Split pane downward', shortcut: '⌘⇧D' },
      { title: 'Split Left', action: '_split_left', description: 'Split pane to the left' },
      { title: 'Split Up', action: '_split_up', description: 'Split pane upward' },

      // Navigation
      { title: 'Focus Split: Left', action: 'goto_split:left', description: 'Focus left split' },
      { title: 'Focus Split: Right', action: 'goto_split:right', description: 'Focus right split' },
      { title: 'Focus Split: Up', action: 'goto_split:up', description: 'Focus split above' },
      { title: 'Focus Split: Down', action: 'goto_split:down', description: 'Focus split below' },
      { title: 'Focus Split: Previous', action: 'goto_split:previous', description: 'Focus previous split' },
      { title: 'Focus Split: Next', action: 'goto_split:next', description: 'Focus next split' },
      { title: 'Toggle Split Zoom', action: 'toggle_split_zoom', description: 'Toggle zoom on current split' },
      { title: 'Equalize Splits', action: 'equalize_splits', description: 'Make all splits equal size' },

      // Terminal Control
      { title: 'Reset Terminal', action: 'reset', description: 'Reset terminal state' },
      { title: 'Toggle Read-Only Mode', action: 'toggle_readonly', description: 'Toggle read-only mode' },

      // Config
      { title: 'Reload Config', action: 'reload_config', description: 'Reload configuration' },
      { title: 'Toggle Inspector', action: '_toggle_inspector', description: 'Toggle terminal inspector', shortcut: '⌥⌘I' },

      // Title
      { title: 'Change Title...', action: '_change_title', description: 'Change the terminal title' },

      // Fun
      { title: 'Ghostty', action: 'text:👻', description: 'Add a little ghost to your terminal' },
    ];
    // Sort alphabetically by title
    return commands.sort((a, b) => a.title.localeCompare(b.title));
  }

  showCommandPalette() {
    const overlay = document.getElementById('command-palette');
    const input = document.getElementById('command-palette-input');
    const list = document.getElementById('command-palette-list');
    if (!overlay || !input || !list) return;

    this.commandPaletteSelectedIndex = 0;
    this.commandPaletteCommands = this.getCommands();

    // Render commands
    this.renderCommandList('');

    // Show overlay
    overlay.classList.add('visible');
    input.value = '';
    input.focus();

    // Handle input
    input.oninput = () => {
      this.commandPaletteSelectedIndex = 0;
      this.renderCommandList(input.value);
    };

    // Handle keyboard
    input.onkeydown = (e) => {
      const items = list.querySelectorAll('.command-item');
      if (e.key === 'ArrowDown') {
        e.preventDefault();
        this.commandPaletteSelectedIndex = Math.min(this.commandPaletteSelectedIndex + 1, items.length - 1);
        this.updateCommandSelection();
      } else if (e.key === 'ArrowUp') {
        e.preventDefault();
        this.commandPaletteSelectedIndex = Math.max(this.commandPaletteSelectedIndex - 1, 0);
        this.updateCommandSelection();
      } else if (e.key === 'Enter') {
        e.preventDefault();
        const selected = items[this.commandPaletteSelectedIndex];
        if (selected) {
          this.executeCommand(selected.dataset.action);
          this.hideCommandPalette();
        }
      } else if (e.key === 'Escape') {
        this.hideCommandPalette();
      }
    };

    // Click outside to close
    overlay.onclick = (e) => {
      if (e.target === overlay) {
        this.hideCommandPalette();
      }
    };
  }

  renderCommandList(filter) {
    const list = document.getElementById('command-palette-list');
    if (!list) return;

    const filterLower = filter.toLowerCase();
    const filtered = this.commandPaletteCommands.filter(cmd =>
      cmd.title.toLowerCase().includes(filterLower) ||
      (cmd.description && cmd.description.toLowerCase().includes(filterLower))
    );

    list.innerHTML = filtered.map((cmd, i) => `
      <div class="command-item${i === this.commandPaletteSelectedIndex ? ' selected' : ''}" data-action="${cmd.action}">
        <div>
          <div class="command-item-title">${cmd.title}</div>
          ${cmd.description ? `<div class="command-item-description">${cmd.description}</div>` : ''}
        </div>
        ${cmd.shortcut ? `<span class="command-item-shortcut">${cmd.shortcut}</span>` : ''}
      </div>
    `).join('');

    // Add click handlers
    list.querySelectorAll('.command-item').forEach((item, i) => {
      item.onclick = () => {
        this.executeCommand(item.dataset.action);
        this.hideCommandPalette();
      };
      item.onmouseenter = () => {
        this.commandPaletteSelectedIndex = i;
        this.updateCommandSelection();
      };
    });
  }

  updateCommandSelection() {
    const list = document.getElementById('command-palette-list');
    if (!list) return;
    list.querySelectorAll('.command-item').forEach((item, i) => {
      item.classList.toggle('selected', i === this.commandPaletteSelectedIndex);
    });
    // Scroll into view
    const selected = list.querySelector('.command-item.selected');
    if (selected) {
      selected.scrollIntoView({ block: 'nearest' });
    }
  }

  executeCommand(action) {
    // Local actions (start with _)
    if (action.startsWith('_')) {
      switch (action) {
        case '_new_tab': this.createTab(); break;
        case '_close_tab': this.closeActivePanel(); break;
        case '_show_all_tabs': this.showTabOverview(); break;
        case '_split_right': this.splitActivePanel('right'); break;
        case '_split_down': this.splitActivePanel('down'); break;
        case '_split_left': this.splitActivePanel('left'); break;
        case '_split_up': this.splitActivePanel('up'); break;
        case '_change_title': this.promptChangeTitle(); break;
        case '_toggle_inspector': this.toggleInspector(); break;
      }
      return;
    }

    // Send to server
    if (this.activePanel?.serverId !== null) {
      this.sendViewAction(this.activePanel.serverId, action);
    }
  }

  hideCommandPalette() {
    const overlay = document.getElementById('command-palette');
    if (overlay) {
      overlay.classList.remove('visible');
    }
    // Refocus terminal
    if (this.activePanel && this.activePanel.canvas) {
      this.activePanel.canvas.focus();
    }
  }

  // File transfer: Upload (Binary + Compression)
  // Format: [0x10][panel_id:u32][name_len:u16][name:bytes][compressed_data:bytes]
  showUploadDialog() {
    const input = document.getElementById('file-upload-input');
    if (!input) return;

    input.onchange = () => {
      if (input.files.length === 0) return;
      for (const file of input.files) {
        this.uploadFile(file);
      }
      input.value = ''; // Reset for next use
    };
    input.click();
  }

  uploadFile(file) {
    if (!this.activePanel?.serverId) {
      console.error('No active panel for upload');
      return;
    }

    const panelId = this.activePanel.serverId;
    const reader = new FileReader();

    reader.onload = () => {
      const fileData = new Uint8Array(reader.result);

      // Compress with pako (raw deflate, not zlib)
      let compressed;
      try {
        compressed = pako.deflateRaw(fileData);
      } catch (e) {
        console.error('Compression failed:', e);
        compressed = fileData; // Fallback to uncompressed
      }

      const filename = new TextEncoder().encode(file.name);

      // Build binary message: [0x10][panel_id:u32][name_len:u16][name][compressed_data]
      const msgLen = 1 + 4 + 2 + filename.length + compressed.length;
      const msg = new ArrayBuffer(msgLen);
      const view = new DataView(msg);
      const bytes = new Uint8Array(msg);

      let offset = 0;
      view.setUint8(offset, 0x10); offset += 1;  // Type: file_upload
      view.setUint32(offset, panelId, true); offset += 4;  // Panel ID (little endian)
      view.setUint16(offset, filename.length, true); offset += 2;  // Filename length
      bytes.set(filename, offset); offset += filename.length;  // Filename
      bytes.set(compressed, offset);  // Compressed data

      if (this.controlWs && this.controlWs.readyState === WebSocket.OPEN) {
        this.controlWs.send(msg);
        const ratio = ((1 - compressed.length / fileData.length) * 100).toFixed(1);
        console.log(`Uploading ${file.name}: ${fileData.length} -> ${compressed.length} bytes (${ratio}% saved)`);
      }
    };
    reader.readAsArrayBuffer(file);
  }

  // File transfer: Download
  showDownloadDialog() {
    const overlay = document.getElementById('download-dialog');
    const input = document.getElementById('download-path-input');
    if (!overlay || !input) return;

    overlay.classList.add('visible');
    input.value = '';
    input.focus();

    const confirmBtn = overlay.querySelector('.dialog-btn.confirm');
    const cancelBtn = overlay.querySelector('.dialog-btn.cancel');

    const cleanup = () => {
      overlay.classList.remove('visible');
      input.onkeydown = null;
      confirmBtn.onclick = null;
      cancelBtn.onclick = null;
      if (this.activePanel?.canvas) {
        this.activePanel.canvas.focus();
      }
    };

    const doDownload = () => {
      const path = input.value.trim();
      if (path) {
        this.requestDownload(path);
      }
      cleanup();
    };

    input.onkeydown = (e) => {
      if (e.key === 'Enter') {
        e.preventDefault();
        doDownload();
      } else if (e.key === 'Escape') {
        cleanup();
      }
    };

    confirmBtn.onclick = doDownload;
    cancelBtn.onclick = cleanup;
    overlay.onclick = (e) => {
      if (e.target === overlay) cleanup();
    };
  }

  // File transfer: Download request (Binary)
  // Format: [0x11][panel_id:u32][path_len:u16][path:bytes]
  requestDownload(path) {
    if (!this.activePanel?.serverId) {
      console.error('No active panel for download');
      return;
    }

    const panelId = this.activePanel.serverId;
    const pathBytes = new TextEncoder().encode(path);

    // Build binary message: [0x11][panel_id:u32][path_len:u16][path]
    const msgLen = 1 + 4 + 2 + pathBytes.length;
    const msg = new ArrayBuffer(msgLen);
    const view = new DataView(msg);
    const bytes = new Uint8Array(msg);

    let offset = 0;
    view.setUint8(offset, 0x11); offset += 1;  // Type: file_download
    view.setUint32(offset, panelId, true); offset += 4;  // Panel ID
    view.setUint16(offset, pathBytes.length, true); offset += 2;  // Path length
    bytes.set(pathBytes, offset);  // Path

    if (this.controlWs && this.controlWs.readyState === WebSocket.OPEN) {
      this.controlWs.send(msg);
      console.log(`Requesting download: ${path}`);
    }
  }

  // Handle binary file data from server
  // Format: [0x12][name_len:u16][name:bytes][compressed_data:bytes]
  // Or error: [0x13][error_len:u16][error:bytes]
  handleBinaryFileData(data) {
    const view = new DataView(data);
    const bytes = new Uint8Array(data);
    const msgType = view.getUint8(0);

    if (msgType === 0x13) {
      // Error response
      const errorLen = view.getUint16(1, true);
      const error = new TextDecoder().decode(bytes.slice(3, 3 + errorLen));
      alert(`Download failed: ${error}`);
      return;
    }

    if (msgType !== 0x12) {
      console.error('Unknown file message type:', msgType);
      return;
    }

    // Parse file data
    let offset = 1;
    const nameLen = view.getUint16(offset, true); offset += 2;
    const filename = new TextDecoder().decode(bytes.slice(offset, offset + nameLen)); offset += nameLen;
    const compressedData = bytes.slice(offset);

    // Decompress with pako (raw deflate, not zlib)
    let fileData;
    try {
      fileData = pako.inflateRaw(compressedData);
    } catch (e) {
      console.error('Decompression failed:', e);
      fileData = compressedData; // Fallback
    }

    // Trigger browser download
    const blob = new Blob([fileData]);
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);

    const ratio = ((1 - compressedData.length / fileData.length) * 100).toFixed(1);
    console.log(`Downloaded ${filename}: ${compressedData.length} -> ${fileData.length} bytes (${ratio}% saved)`);
  }

  promptChangeTitle() {
    // Get current title
    const tab = this.tabs.get(this.activeTab);
    const currentTitle = tab?.title || '';

    const newTitle = prompt('Enter new title:', currentTitle);
    if (newTitle !== null && this.activePanel?.serverId !== null) {
      // Send to server to change title
      this.sendViewAction(this.activePanel.serverId, `set_title:${newTitle}`);
      // Update local tab title immediately
      if (tab) {
        tab.title = newTitle;
        const tabEl = this.tabsEl.querySelector(`[data-id="${this.activeTab}"] .title`);
        if (tabEl) tabEl.textContent = newTitle || '👻';
        // Update document title
        document.title = newTitle || '👻';
        const appTitle = document.getElementById('app-title');
        if (appTitle) appTitle.textContent = newTitle || '👻';
      }
    }
  }

  // ============================================================================
  // Terminal Inspector (per-panel)
  // ============================================================================

  toggleInspector() {
    // Each panel has its own inspector - toggle the active panel's inspector
    if (this.activePanel) {
      this.activePanel.toggleInspector();
    }
  }

  formatBytes(bytes) {
    if (bytes === 0) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(1)) + ' ' + sizes[i];
  }

  toggleQuickTerminal() {
    const container = document.getElementById('quick-terminal');
    if (!container) return;

    if (container.classList.contains('visible')) {
      // Hide quick terminal (keep panel alive for persistence)
      container.classList.remove('visible');
      // Restore previous active panel
      if (this.previousActivePanel) {
        this.setActivePanel(this.previousActivePanel);
        this.previousActivePanel = null;
      }
    } else {
      // Show quick terminal
      container.classList.add('visible');
      // Save current active panel to restore later
      this.previousActivePanel = this.activePanel;
      // Create panel only if not already created
      if (!this.quickTerminalPanel) {
        const content = container.querySelector('.quick-terminal-content');
        content.innerHTML = '';
        this.quickTerminalPanel = this.createPanel(content, null);
      }
      // Set quick terminal as active panel
      this.setActivePanel(this.quickTerminalPanel);
    }
  }
}

// ============================================================================
// Init
// ============================================================================

// Parse hex color to RGB
function hexToRgb(hex) {
  const m = hex.match(/^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/i);
  return m ? { r: parseInt(m[1], 16), g: parseInt(m[2], 16), b: parseInt(m[3], 16) } : null;
}

// RGB to hex
function rgbToHex(r, g, b) {
  return `#${Math.round(r).toString(16).padStart(2,'0')}${Math.round(g).toString(16).padStart(2,'0')}${Math.round(b).toString(16).padStart(2,'0')}`;
}

// Calculate luminance (same formula as ghostty)
function luminance(hex) {
  const rgb = hexToRgb(hex);
  if (!rgb) return 0;
  return (0.299 * rgb.r / 255) + (0.587 * rgb.g / 255) + (0.114 * rgb.b / 255);
}

// Check if color is light (luminance > 0.5)
function isLightColor(hex) {
  return luminance(hex) > 0.5;
}

// Check if very dark (luminance < 0.05) - same as ghostty
function isVeryDark(hex) {
  return luminance(hex) < 0.05;
}

// Highlight color by level (like NSColor.highlight(withLevel:))
// Moves color toward white by the given fraction
function highlightColor(hex, level) {
  const rgb = hexToRgb(hex);
  if (!rgb) return hex;
  const r = rgb.r + (255 - rgb.r) * level;
  const g = rgb.g + (255 - rgb.g) * level;
  const b = rgb.b + (255 - rgb.b) * level;
  return rgbToHex(r, g, b);
}

// Shadow color by level (like NSColor.shadow(withLevel:))
// Moves color toward black by the given fraction
function shadowColor(hex, level) {
  const rgb = hexToRgb(hex);
  if (!rgb) return hex;
  const r = rgb.r * (1 - level);
  const g = rgb.g * (1 - level);
  const b = rgb.b * (1 - level);
  return rgbToHex(r, g, b);
}

// Blend color with black at given alpha (like ghostty's systemOverlayColor blend)
function blendWithBlack(hex, alpha) {
  const rgb = hexToRgb(hex);
  if (!rgb) return hex;
  const r = rgb.r * (1 - alpha);
  const g = rgb.g * (1 - alpha);
  const b = rgb.b * (1 - alpha);
  return rgbToHex(r, g, b);
}

// Apply ghostty colors to CSS variables (all derived from config)
function applyColors(colors) {
  const root = document.documentElement;
  const bg = colors.background || '#282c34';
  const fg = colors.foreground || '#ffffff';
  const isLight = isLightColor(bg);
  const veryDark = isVeryDark(bg);

  // Terminal background - toolbar matches it (like ghostty's transparent titlebar)
  root.style.setProperty('--bg', bg);
  root.style.setProperty('--toolbar-bg', bg);

  // Tabbar slightly darker than toolbar background
  // Active tab is lighter (original background)
  const tabbarBg = shadowColor(bg, 0.1);
  root.style.setProperty('--tabbar-bg', tabbarBg);

  // Active tab is the original background
  root.style.setProperty('--tab-active', bg);

  // Text colors from foreground config
  root.style.setProperty('--text', fg);

  // Overlay colors based on theme
  const overlay = isLight ? '0,0,0' : '255,255,255';
  root.style.setProperty('--tab-hover', `rgba(${overlay},0.08)`);
  root.style.setProperty('--close-hover', `rgba(${overlay},0.1)`);
  root.style.setProperty('--text-dim', `rgba(${overlay},0.5)`);

  // Accent from foreground
  root.style.setProperty('--accent', fg);
}

function setupMenus() {
  const isMobile = () => window.innerWidth < 600;

  // Menu item actions
  document.querySelectorAll('.menu-item').forEach(item => {
    item.addEventListener('click', () => {
      const action = item.dataset.action;
      const app = window.app;
      if (!app) return;

      switch (action) {
        case 'new-tab':
          app.createTab();
          break;
        case 'close-tab':
          app.closeActivePanel();
          break;
        case 'close-all-tabs':
          app.closeAllTabs();
          break;
        case 'upload':
          app.showUploadDialog();
          break;
        case 'download':
          app.showDownloadDialog();
          break;
        case 'split-right':
          if (app.activePanel) {
            app.splitActivePanel('right');
          }
          break;
        case 'split-down':
          if (app.activePanel) {
            app.splitActivePanel('down');
          }
          break;
        case 'split-left':
          if (app.activePanel) {
            app.splitActivePanel('left');
          }
          break;
        case 'split-up':
          if (app.activePanel) {
            app.splitActivePanel('up');
          }
          break;
        case 'copy':
          if (app.activePanel?.serverId !== null) {
            app.sendViewAction(app.activePanel.serverId, 'copy_to_clipboard');
          }
          break;
        case 'paste':
          navigator.clipboard.readText().then(text => {
            // Send paste to active panel
            if (app.activePanel && app.activePanel.ws) {
              const encoder = new TextEncoder();
              const textBytes = encoder.encode(text);
              const buf = new ArrayBuffer(1 + textBytes.length);
              const view = new Uint8Array(buf);
              view[0] = 0x05; // TEXT_INPUT
              view.set(textBytes, 1);
              app.activePanel.ws.send(buf);
            }
          });
          break;
        case 'paste-selection':
          // Paste from ghostty's selection clipboard
          if (app.activePanel?.serverId !== null) {
            app.sendViewAction(app.activePanel.serverId, 'paste_from_selection');
          }
          break;
        case 'select-all':
          if (app.activePanel?.serverId !== null) {
            app.sendViewAction(app.activePanel.serverId, 'select_all');
          }
          break;
        case 'zoom-in':
          if (app.activePanel?.serverId !== null) {
            app.sendViewAction(app.activePanel.serverId, 'increase_font_size:1');
          }
          break;
        case 'zoom-out':
          if (app.activePanel?.serverId !== null) {
            app.sendViewAction(app.activePanel.serverId, 'decrease_font_size:1');
          }
          break;
        case 'zoom-reset':
          if (app.activePanel?.serverId !== null) {
            app.sendViewAction(app.activePanel.serverId, 'reset_font_size');
          }
          break;
        case 'show-all-tabs':
          app.showTabOverview();
          break;
        case 'command-palette':
          app.showCommandPalette();
          break;
        case 'change-title':
          app.promptChangeTitle();
          break;
        case 'quick-terminal':
          app.toggleQuickTerminal();
          break;
        case 'toggle-inspector':
          app.toggleInspector();
          break;
      }

      // Close menu after action
      document.querySelectorAll('.menu').forEach(m => m.classList.remove('open'));
    });
  });

  // Mobile: click to toggle menu
  document.querySelectorAll('.menu-label').forEach(label => {
    label.addEventListener('click', (e) => {
      if (!isMobile()) return;
      e.stopPropagation();
      const menu = label.parentElement;
      const wasOpen = menu.classList.contains('open');
      // Close all menus
      document.querySelectorAll('.menu').forEach(m => m.classList.remove('open'));
      // Toggle this one
      if (!wasOpen) menu.classList.add('open');
    });
  });

  // Close menus when clicking outside
  document.addEventListener('click', () => {
    document.querySelectorAll('.menu').forEach(m => m.classList.remove('open'));
  });

  // Hamburger menu toggle
  const hamburger = document.getElementById('hamburger');
  if (hamburger) {
    hamburger.addEventListener('click', (e) => {
      e.stopPropagation();
      document.getElementById('menubar').classList.toggle('open');
    });
  }
}

async function init() {
  // Fetch config to get WebSocket ports and colors
  try {
    const response = await fetch('/config');
    const config = await response.json();
    PANEL_PORT = config.panelWsPort;
    CONTROL_PORT = config.controlWsPort;
    console.log('Config loaded:', config);

    // Apply colors from ghostty config
    if (config.colors) {
      applyColors(config.colors);
    }
  } catch (e) {
    console.error('Failed to fetch config:', e);
    return;
  }

  setupMenus();

  // No external dependencies - uses native DecompressionStream
  window.app = new App();
  window.app.connect();
}

init();
