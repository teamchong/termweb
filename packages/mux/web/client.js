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

    this.element = document.createElement('div');
    this.element.className = 'panel';
    this.element.appendChild(this.canvas);
    container.appendChild(this.element);

    this.setupInputHandlers();
    this.initGPU();
    this.setupResizeObserver();
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
      this.handleFrame(event.data);
    };

    this.ws.onclose = () => {
      console.log(`Panel ${this.id}: Disconnected`);
    };

    this.ws.onerror = (err) => {
      console.error(`Panel ${this.id}: Error`, err);
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
    const rect = this.canvas.getBoundingClientRect();
    const scaleX = this.canvas.width / rect.width;
    const scaleY = this.canvas.height / rect.height;
    return {
      x: (e.clientX - rect.left) * scaleX,
      y: (e.clientY - rect.top) * scaleY
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
    }
    this.disconnect();
    this.element.remove();
  }

  // Reparent panel to a new container
  reparent(newContainer) {
    this.container = newContainer;
    newContainer.appendChild(this.element);
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
      this.promoteChild(this.second);
      return true;
    }

    if (this.second && this.second.panel === panel) {
      // Second child is the panel to remove - promote first
      this.promoteChild(this.first);
      return true;
    }

    // Recurse into children
    if (this.first && this.first.removePanel(panel)) return true;
    if (this.second && this.second.removePanel(panel)) return true;

    return false;
  }

  promoteChild(child) {
    // Replace this split with the remaining child
    if (child.direction !== null) {
      // Child is also a split - adopt its structure
      this.direction = child.direction;
      this.first = child.first;
      this.second = child.second;
      this.ratio = child.ratio;
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
      this.divider = null;

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
    this.activePanel = null;
    this.activeTab = null;          // Current tab ID
    this.nextLocalId = 1;
    this.nextTabId = 1;

    this.tabsEl = document.getElementById('tabs');
    this.panelsEl = document.getElementById('panels');
    this.statusEl = document.getElementById('status');

    document.getElementById('new-tab').addEventListener('click', () => {
      this.createTab();
    });

    // Global keyboard shortcuts (use capture phase to run before canvas handler)
    document.addEventListener('keydown', (e) => {
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
  
  connect(host = 'localhost') {
    this.controlWs = new WebSocket(`ws://${host}:${CONTROL_PORT}`);
    
    this.controlWs.onopen = () => {
      this.statusEl.textContent = 'Connected';
      console.log('Control channel connected');
      // Wait for panel_list to decide whether to create or connect
    };
    
    this.controlWs.onmessage = (event) => {
      this.handleControlMessage(JSON.parse(event.data));
    };
    
    this.controlWs.onclose = () => {
      this.statusEl.textContent = 'Disconnected';
      console.log('Control channel disconnected');
    };
    
    this.controlWs.onerror = (err) => {
      this.statusEl.textContent = 'Connection error';
      console.error('Control error:', err);
    };
  }
  
  handleControlMessage(msg) {
    console.log('Control message:', msg);

    switch (msg.type) {
      case 'panel_list':
        // Initial panel list from server
        console.log('Panel list received:', msg.panels);
        if (msg.panels && msg.panels.length > 0) {
          // Connect to existing panels - each in its own tab for now
          console.log('Connecting to', msg.panels.length, 'existing panels');
          for (const p of msg.panels) {
            this.createTabWithServerId(p.id);
          }
        } else {
          // No panels on server - create one
          console.log('No panels on server, creating new one');
          this.createTab();
        }
        break;

      case 'panel_created':
        // New panel created on server - update local panel's serverId
        for (const [, panel] of this.panels) {
          if (panel.serverId === null) {
            panel.serverId = msg.panel_id;
            console.log(`Local panel ${panel.id} assigned server ID ${msg.panel_id}`);
            break;
          }
        }
        break;
        
      case 'panel_closed':
        this.removePanel(msg.panel_id);
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

    // Create tab content container
    const tabContent = document.createElement('div');
    tabContent.className = 'tab-content';
    tabContent.dataset.tabId = tabId;
    this.panelsEl.appendChild(tabContent);

    // Create panel in the tab content
    const panel = this.createPanel(tabContent, null);

    // Create root split container with the panel
    const root = SplitContainer.createLeaf(panel, null);
    tabContent.appendChild(root.element);

    // Store tab info
    this.tabs.set(tabId, { root, element: tabContent, title: 'Terminal' });

    // Add tab to tab bar
    this.addTabUI(tabId, 'Terminal');

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
    this.tabs.set(tabId, { root, element: tabContent, title: 'Terminal' });

    // Add tab to tab bar
    this.addTabUI(tabId, 'Terminal');

    // Switch to tab if no active tab
    if (!this.activeTab) {
      this.switchToTab(tabId);
    }

    return tabId;
  }

  // Split the active panel
  splitActivePanel(direction) {
    if (!this.activePanel || this.activeTab === null) return;

    const tab = this.tabs.get(this.activeTab);
    if (!tab) return;

    // Find the container holding the active panel
    const container = tab.root.findContainer(this.activePanel);
    if (!container) return;

    // Create new panel for the split
    const newPanel = this.createPanel(document.createElement('div'), null);

    // Perform the split
    const newContainer = container.split(direction, newPanel);
    if (newContainer) {
      // Focus the new panel
      this.setActivePanel(newPanel);
    }
  }

  // Close the active panel (or tab if last panel in tab)
  closeActivePanel() {
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

    // Switch to another tab if this was active
    if (this.activeTab === tabId) {
      this.activeTab = null;
      this.activePanel = null;
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

    // Update title
    this.updateTitleForPanel(panel);
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
    // Hide current tab
    if (this.activeTab !== null) {
      const oldTab = this.tabs.get(this.activeTab);
      if (oldTab) {
        oldTab.element.classList.remove('active');
        // Pause all panels in old tab
        for (const panel of oldTab.root.getAllPanels()) {
          panel.hide();
        }
      }
    }

    // Show new tab
    const tab = this.tabs.get(tabId);
    if (tab) {
      tab.element.classList.add('active');
      this.activeTab = tabId;
      this.updateTabUIActive(tabId);

      // Resume all panels in new tab
      const tabPanels = tab.root.getAllPanels();
      for (const panel of tabPanels) {
        panel.show();
      }

      // Set active panel to first panel if none set
      if (!this.activePanel || !tabPanels.includes(this.activePanel)) {
        this.activePanel = tabPanels[0] || null;
      }

      // Update title
      if (this.activePanel) {
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
        const title = tabEl ? tabEl.textContent : 'Terminal';
        document.title = title + ' - termweb';
        const appTitle = document.getElementById('app-title');
        if (appTitle) appTitle.textContent = title;
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

    tab.innerHTML = `<span class="close">×</span><span class="title">${title}</span><span class="hotkey">${hotkeyHint}</span>`;

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

      // Update tab data
      const tab = this.tabs.get(tabId);
      if (tab) tab.title = title;
    }

    // Update document title and app title if this is the active panel
    if (targetPanel === this.activePanel) {
      document.title = title + ' - termweb';
      const appTitle = document.getElementById('app-title');
      if (appTitle) appTitle.textContent = title;
      this.updateIndicatorForPanel(targetPanel, title);
    }
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

    // If this is the active panel, update the indicator
    if (targetPanel === this.activePanel) {
      const appTitle = document.getElementById('app-title');
      const currentTitle = appTitle ? appTitle.textContent : '';
      this.updateIndicatorForPanel(targetPanel, currentTitle);
    }
  }

  updateIndicatorForPanel(panel, title) {
    // Determine if a command is running:
    // - If title contains path characters or looks like a path, we're at prompt
    // - Otherwise, a command is probably running
    let indicator = '';

    if (panel.pwd) {
      // Check if we're at prompt (title matches directory) or running a command
      // If title is a path-like string, we're at prompt - just show folder
      const titleLooksLikePrompt = title.includes('/') ||
                                    title.startsWith('~') ||
                                    title === '';
      if (!titleLooksLikePrompt && title.length > 0) {
        // Title looks like a running command - show folder + asterisk
        indicator = '📁 *';
      } else {
        // At prompt - just show folder, no dot or asterisk
        indicator = '📁';
      }
    } else {
      // No pwd yet - show small ghost emoji as default
      indicator = '<span style="font-size:10px">👻</span>';
    }

    this.updateTitleIndicator(indicator);
  }

  updateTitleIndicator(indicator) {
    const el = document.getElementById('title-indicator');
    if (el) el.innerHTML = indicator;
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
