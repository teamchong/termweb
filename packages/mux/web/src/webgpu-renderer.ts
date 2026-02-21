export interface CursorParams {
  x: number;      // pixel position in surface coords
  y: number;
  w: number;
  h: number;
  surfW: number;  // surface dimensions (denominator)
  surfH: number;
  r: number;      // color 0-255
  g: number;
  b: number;
  alpha: number;  // 0-1
  style: number;  // 0=bar, 1=block, 2=underline, 3=hollow
  visible: boolean;
}

export interface WebGPUFrameRenderer {
  renderFrame(frame: VideoFrame): void;
  setCursor(cursor: CursorParams | null): void;
  renderCursorOnly(): void;
  dispose(): void;
}

// Cursor uniform: rect(vec4f) + color(vec4f) + params(vec4u)
// Total: 48 bytes, 16-byte aligned
const CURSOR_UNIFORM_SIZE = 48;

const SHADER = /* wgsl */ `
@group(0) @binding(0) var mySampler: sampler;
@group(0) @binding(1) var myTexture: texture_2d<f32>;
@group(0) @binding(2) var<uniform> cursor: Cursor;

struct Cursor {
  rect: vec4f,      // left, top, right, bottom in UV [0,1]
  color: vec4f,     // r, g, b, alpha
  params: vec4u,    // style, visible, canvasW, canvasH
};

struct VertexOutput {
  @builtin(position) position: vec4f,
  @location(0) uv: vec2f,
};

@vertex
fn vs(@builtin(vertex_index) vi: u32) -> VertexOutput {
  let x = f32((vi & 1u) << 1u) - 1.0;
  let y = 1.0 - f32((vi & 2u));
  var out: VertexOutput;
  out.position = vec4f(x, y, 0.0, 1.0);
  out.uv = vec2f((x + 1.0) * 0.5, (1.0 - y) * 0.5);
  return out;
}

@fragment
fn fs(@location(0) uv: vec2f) -> @location(0) vec4f {
  var color = textureSample(myTexture, mySampler, uv);

  if (cursor.params.y == 0u) { return color; }

  let inRect = uv.x >= cursor.rect.x && uv.x <= cursor.rect.z &&
               uv.y >= cursor.rect.y && uv.y <= cursor.rect.w;
  if (!inRect) { return color; }

  let style = cursor.params.x;
  let pixelW = 1.0 / f32(cursor.params.z);
  let pixelH = 1.0 / f32(cursor.params.w);

  var draw = false;
  if (style == 0u) {
    // Bar: left 2px
    draw = uv.x < cursor.rect.x + 2.0 * pixelW;
  } else if (style == 1u) {
    // Block: entire rect
    draw = true;
  } else if (style == 2u) {
    // Underline: bottom 2px
    draw = uv.y > cursor.rect.w - 2.0 * pixelH;
  } else {
    // Hollow: 1px border
    draw = uv.x < cursor.rect.x + pixelW || uv.x > cursor.rect.z - pixelW ||
           uv.y < cursor.rect.y + pixelH || uv.y > cursor.rect.w - pixelH;
  }

  if (draw) {
    color = vec4f(mix(color.rgb, cursor.color.rgb, cursor.color.a), 1.0);
  }

  return color;
}
`;

function initCanvas2DFallback(canvas: HTMLCanvasElement): WebGPUFrameRenderer | null {
  const ctx = canvas.getContext('2d');
  if (!ctx) return null;

  let cur: CursorParams | null = null;

  return {
    renderFrame(frame: VideoFrame): void {
      ctx.drawImage(frame as any, 0, 0, canvas.width, canvas.height);
      drawCursor2D(ctx, canvas, cur);
    },
    setCursor(cursor: CursorParams | null): void { cur = cursor; },
    renderCursorOnly(): void { /* no persistent texture in 2D fallback */ },
    dispose(): void { /* nothing to clean up */ },
  };
}

function drawCursor2D(ctx: CanvasRenderingContext2D, canvas: HTMLCanvasElement, cur: CursorParams | null): void {
  if (!cur || !cur.visible || cur.surfW === 0 || cur.surfH === 0) return;

  const scaleX = canvas.width / cur.surfW;
  const scaleY = canvas.height / cur.surfH;
  const px = cur.x * scaleX;
  const py = cur.y * scaleY;
  const pw = cur.w * scaleX;
  const ph = cur.h * scaleY;
  const color = `rgba(${cur.r},${cur.g},${cur.b},${cur.alpha})`;

  ctx.fillStyle = color;
  ctx.strokeStyle = color;
  ctx.lineWidth = 1;

  switch (cur.style) {
    case 0: // bar
      ctx.fillRect(px, py, Math.min(pw, 2), ph);
      break;
    case 1: // block
      ctx.fillRect(px, py, pw, ph);
      break;
    case 2: // underline
      ctx.fillRect(px, py + ph - 2, pw, 2);
      break;
    case 3: // hollow
      ctx.strokeRect(px + 0.5, py + 0.5, pw - 1, ph - 1);
      break;
  }
}

export async function initWebGPURenderer(
  canvas: HTMLCanvasElement,
): Promise<WebGPUFrameRenderer | null> {
  // Try WebGPU first
  try {
    if (navigator.gpu) {
      const adapter = await navigator.gpu.requestAdapter();
      if (adapter) {
        const device = await adapter.requestDevice();
        const gpuCtx = canvas.getContext('webgpu');
        if (gpuCtx) {
          const format = navigator.gpu.getPreferredCanvasFormat();
          gpuCtx.configure({ device, format, alphaMode: 'opaque' });

          const shaderModule = device.createShaderModule({ code: SHADER });

          const pipeline = device.createRenderPipeline({
            layout: 'auto',
            vertex: { module: shaderModule, entryPoint: 'vs' },
            fragment: {
              module: shaderModule,
              entryPoint: 'fs',
              targets: [{ format }],
            },
            primitive: { topology: 'triangle-strip', stripIndexFormat: undefined },
          });

          const sampler = device.createSampler({ magFilter: 'linear', minFilter: 'linear' });
          const bindGroupLayout = pipeline.getBindGroupLayout(0);

          // Cursor uniform buffer (persistent, updated per frame)
          const cursorBuffer = device.createBuffer({
            size: CURSOR_UNIFORM_SIZE,
            usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
          });
          const cursorData = new ArrayBuffer(CURSOR_UNIFORM_SIZE);
          const cursorFloats = new Float32Array(cursorData, 0, 8);  // rect + color
          const cursorUints = new Uint32Array(cursorData, 32, 4);   // params

          // Persistent texture — VideoFrame is copied here each frame so we can
          // re-render for cursor blink during idle (importExternalTexture is ephemeral)
          let frameTexture: GPUTexture | null = null;
          let frameBindGroup: GPUBindGroup | null = null;
          let hasFrame = false;

          let configuredWidth = canvas.width;
          let configuredHeight = canvas.height;

          let cursorState: CursorParams | null = null;

          const colorAttachment: GPURenderPassColorAttachment = {
            view: null! as GPUTextureView,
            clearValue: { r: 0, g: 0, b: 0, a: 1 },
            loadOp: 'clear' as GPULoadOp,
            storeOp: 'store' as GPUStoreOp,
          };
          const renderPassDescriptor: GPURenderPassDescriptor = {
            colorAttachments: [colorAttachment],
          };

          function ensureTexture(w: number, h: number): void {
            if (frameTexture && frameTexture.width === w && frameTexture.height === h) return;
            if (frameTexture) frameTexture.destroy();
            frameTexture = device.createTexture({
              size: [w, h],
              format: 'rgba8unorm',
              usage: GPUTextureUsage.TEXTURE_BINDING |
                     GPUTextureUsage.COPY_DST |
                     GPUTextureUsage.RENDER_ATTACHMENT,
            });
            frameBindGroup = device.createBindGroup({
              layout: bindGroupLayout,
              entries: [
                { binding: 0, resource: sampler },
                { binding: 1, resource: frameTexture.createView() },
                { binding: 2, resource: { buffer: cursorBuffer } },
              ],
            });
          }

          function writeCursorUniform(): void {
            const c = cursorState;
            if (!c || !c.visible || c.surfW === 0 || c.surfH === 0 || configuredWidth === 0 || configuredHeight === 0) {
              // Clear visible flag
              cursorUints[1] = 0;
            } else {
              // Bar: clamp width to 2px equivalent in surface coords
              const w = c.style === 0 ? Math.min(c.w, 2 * (c.surfW / configuredWidth || 1)) : c.w;
              cursorFloats[0] = c.x / c.surfW;           // left
              cursorFloats[1] = c.y / c.surfH;           // top
              cursorFloats[2] = (c.x + w) / c.surfW;    // right
              cursorFloats[3] = (c.y + c.h) / c.surfH;  // bottom
              cursorFloats[4] = c.r / 255;               // r
              cursorFloats[5] = c.g / 255;               // g
              cursorFloats[6] = c.b / 255;               // b
              cursorFloats[7] = c.alpha;                  // alpha
              cursorUints[0] = c.style;
              cursorUints[1] = 1;                         // visible
              cursorUints[2] = configuredWidth;
              cursorUints[3] = configuredHeight;
            }
            device.queue.writeBuffer(cursorBuffer, 0, cursorData);
          }

          function submitRenderPass(): void {
            if (!frameBindGroup) return;
            if (canvas.width !== configuredWidth || canvas.height !== configuredHeight) {
              gpuCtx!.configure({ device, format, alphaMode: 'opaque' });
              configuredWidth = canvas.width;
              configuredHeight = canvas.height;
            }
            writeCursorUniform();
            const commandEncoder = device.createCommandEncoder();
            colorAttachment.view = gpuCtx!.getCurrentTexture().createView();
            const pass = commandEncoder.beginRenderPass(renderPassDescriptor);
            pass.setPipeline(pipeline);
            pass.setBindGroup(0, frameBindGroup!);
            pass.draw(4);
            pass.end();
            device.queue.submit([commandEncoder.finish()]);
          }

          function renderFrame(frame: VideoFrame): void {
            const w = frame.displayWidth;
            const h = frame.displayHeight;
            ensureTexture(w, h);

            // GPU copy VideoFrame → persistent texture (fast, no CPU readback)
            device.queue.copyExternalImageToTexture(
              { source: frame as any },
              { texture: frameTexture! },
              [w, h],
            );
            hasFrame = true;

            submitRenderPass();
          }

          function setCursor(cursor: CursorParams | null): void {
            cursorState = cursor;
          }

          // Re-render from persistent texture (for cursor blink during idle)
          function renderCursorOnly(): void {
            if (!hasFrame) return;
            submitRenderPass();
          }

          function dispose(): void {
            if (frameTexture) frameTexture.destroy();
            cursorBuffer.destroy();
            device.destroy();
          }

          console.log('[Renderer] using WebGPU');
          return { renderFrame, setCursor, renderCursorOnly, dispose };
        }
      }
    }
  } catch {
    // WebGPU failed, fall through to Canvas 2D
  }

  // Fall back to Canvas 2D (iOS Safari, older browsers)
  const fallback = initCanvas2DFallback(canvas);
  if (fallback) console.log('[Renderer] using Canvas 2D fallback');
  return fallback;
}
