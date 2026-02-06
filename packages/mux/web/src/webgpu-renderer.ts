export interface WebGPUFrameRenderer {
  renderFrame(frame: VideoFrame): void;
  dispose(): void;
}

const SHADER = /* wgsl */ `
@group(0) @binding(0) var mySampler: sampler;
@group(0) @binding(1) var myTexture: texture_external;

struct VertexOutput {
  @builtin(position) position: vec4f,
  @location(0) uv: vec2f,
};

@vertex
fn vs(@builtin(vertex_index) vi: u32) -> VertexOutput {
  // Fullscreen quad via triangle-strip (4 vertices, no vertex buffer)
  let x = f32((vi & 1u) << 1u) - 1.0;   // -1, 1, -1, 1
  let y = 1.0 - f32((vi & 2u));          //  1, 1, -1, -1
  var out: VertexOutput;
  out.position = vec4f(x, y, 0.0, 1.0);
  out.uv = vec2f((x + 1.0) * 0.5, (1.0 - y) * 0.5);
  return out;
}

@fragment
fn fs(@location(0) uv: vec2f) -> @location(0) vec4f {
  return textureSampleBaseClampToEdge(myTexture, mySampler, uv);
}
`;

export async function initWebGPURenderer(
  canvas: HTMLCanvasElement,
): Promise<WebGPUFrameRenderer | null> {
  try {
    if (!navigator.gpu) return null;

    const adapter = await navigator.gpu.requestAdapter();
    if (!adapter) return null;

    const device = await adapter.requestDevice();

    const gpuCtx = canvas.getContext('webgpu');
    if (!gpuCtx) return null;

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

    function renderFrame(frame: VideoFrame): void {
      const externalTexture = device.importExternalTexture({ source: frame as any });

      const bindGroup = device.createBindGroup({
        layout: bindGroupLayout,
        entries: [
          { binding: 0, resource: sampler },
          { binding: 1, resource: externalTexture },
        ],
      });

      const commandEncoder = device.createCommandEncoder();
      const textureView = gpuCtx!.getCurrentTexture().createView();

      const passEncoder = commandEncoder.beginRenderPass({
        colorAttachments: [
          {
            view: textureView,
            clearValue: { r: 0, g: 0, b: 0, a: 1 },
            loadOp: 'clear' as GPULoadOp,
            storeOp: 'store' as GPUStoreOp,
          },
        ],
      });

      passEncoder.setPipeline(pipeline);
      passEncoder.setBindGroup(0, bindGroup);
      passEncoder.draw(4);
      passEncoder.end();

      device.queue.submit([commandEncoder.finish()]);
    }

    function dispose(): void {
      device.destroy();
    }

    return { renderFrame, dispose };
  } catch {
    return null;
  }
}
