# VisionaryCore Codebase Guide

This guide provides a detailed walkthrough of the VisionaryCore 3D Gaussian Splatting renderer, including specific code snippets from the source files to trace the execution flow from entry to pixel.

## 1. Entry Point & Bootstrap

The application starts in `src/main.ts`. It waits for the DOM to load, initializes the ONNX Runtime environment, and then starts the main `App`.

### File: [`src/main.ts`](src/main.ts)

```typescript
// src/main.ts

// 1. Wait for DOM
window.addEventListener('DOMContentLoaded', () => {
	const wasmPaths = getDefaultOrtWasmPaths();

	// 2. Initialize ONNX Runtime Environment
	initOrtEnvironment(wasmPaths);

	// 3. Create and Initialize App
	const app = new App();
	app.init().then(() => {
		// Expose helpers for debugging
		(window as any).loadONNXModel = (path: string) => {
			// ...
		};
	});
});
```

## 2. Application Initialization

The `App` class is the central hub. It sets up the WebGPU context and the renderer.

### File: [`src/app/app.ts`](src/app/app.ts)

```typescript
// src/app/app.ts

export class App {
	constructor() {
		// Initialize managers
		this.cameraManager = new CameraManager(this.camera);
		this.renderLoop = new RenderLoop(this);
		// ...
	}

	async init() {
		// 1. Initialize WebGPU with ONNX support
		// Request adapter with "shader-f16" feature for performance
		const { device, context } = await initWebGPU_onnx(this.canvas);
		this.webgpuContext = new WebGPUContext(device, context, this.canvas);

		// 2. Create the Gaussian Renderer
		this.renderer = new GaussianRenderer(this.webgpuContext);

		// 3. Ensure Sorter resources are allocated
		this.renderer.ensureSorter(this.webgpuContext.device);

		// 4. Start the Render Loop
		this.renderLoop.start();
	}
}
```

## 3. Data Loading (PLY to GPU)

When a model is loaded, it goes through parsing and then GPU buffer allocation.

### Step 3a: Parsing PLY Data

### File: [`src/io/ply_loader.ts`](src/io/ply_loader.ts)

```typescript
// src/io/ply_loader.ts

// Reads binary PLY data and extracts Gaussian attributes
function readHeader(buffer: ArrayBuffer): Header {
	// ... parse header ...
}

// Extracts data into a structured format
const data = new PLYGaussianData(
	pos, // positions
	opacities, // opacities
	cov3d, // covariance
	sh, // spherical harmonics
);
```

### Step 3b: Creating GPU Buffers

### File: [`src/point_cloud/point_cloud.ts`](src/point_cloud/point_cloud.ts)

The `PointCloud` class wraps the raw data and uploads it to the GPU.

```typescript
// src/point_cloud/point_cloud.ts

export class PointCloud {
	constructor(device: GPUDevice, pc: GenericGaussianPointCloudTS) {
		// 1. Create Buffer for 3D Gaussian Data (Storage Buffer)
		this.gaussianBufferGPU = device.createBuffer({
			label: 'gaussians/storage',
			size: pc.gaussianBuffer().byteLength,
			usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
		});
		// Upload data
		device.queue.writeBuffer(this.gaussianBufferGPU, 0, pc.gaussianBuffer());

		// 2. Create Buffer for SH Coefficients
		this.shBufferGPU = device.createBuffer({
			label: 'sh/storage',
			size: pc.shCoefsBuffer().byteLength,
			usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
		});
		device.queue.writeBuffer(this.shBufferGPU, 0, pc.shCoefsBuffer());

		// 3. Allocate Buffer for projected 2D Splats (Output of Compute Shader)
		this.splat2DBuffer = device.createBuffer({
			label: 'splats 2d',
			size: this.numPoints * 24, // 6 floats per point
			usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC,
		});
	}
}
```

## 4. The Render Loop

The `RenderLoop` manages the per-frame update and render cycle.

### File: [`src/app/managers/render-loop.ts`](src/app/managers/render-loop.ts)

```typescript
// src/app/managers/render-loop.ts

private frame = () => {
    // 1. Update Camera
    const dt = now - this.lastTime;
    this.app.cameraManager.update(dt);

    // 2. Update Animations
    this.app.animationManager.updateDynamicPointClouds(dt, now);

    // 3. Render the Frame
    this.renderFrame();

    // 4. Request Next Frame
    this.frameId = requestAnimationFrame(this.frame);
};

private renderFrame() {
    const device = this.app.webgpuContext.device;
    const encoder = device.createCommandEncoder();

    // 1. PREPARE Phase (Compute Shaders: Preprocess + Sort)
    this.app.renderer.prepareMulti(encoder, ...);

    // 2. RENDER Phase (Rasterization Pass)
    const pass = encoder.beginRenderPass(renderPassDescriptor);
    this.app.renderer.renderMulti(pass, ...);
    pass.end();

    // 3. Submit to GPU
    device.queue.submit([encoder.finish()]);
}
```

## 5. Rendering Pipeline Details

The renderer uses a 3-stage pipeline: **Preprocess (Compute) -> Sort (Compute) -> Rasterize (Draw)**.

### Stage A: Preprocessing (Compute)

Projects 3D Gaussians to 2D and calculates sort keys.

### Host Code: [`src/preprocess/gaussian_preprocessor.ts`](src/preprocess/gaussian_preprocessor.ts)

```typescript
// src/preprocess/gaussian_preprocessor.ts

dispatchModel(pass: GPUComputePassEncoder, model: PointCloud) {
    // Set pipeline and bind groups
    pass.setPipeline(this.pipeline);
    pass.setBindGroup(0, model.bindGroup); // Gaussian Data
    pass.setBindGroup(1, this.sortBindGroup); // Sort Buffers (Keys/Indices)
    pass.setBindGroup(2, this.cameraBindGroup); // Camera Uniforms

    // Dispatch threads (one per Gaussian)
    pass.dispatchWorkgroups(Math.ceil(model.numPoints / 256));
}
```

### Shader Code: [`src/shaders/preprocess.wgsl`](src/shaders/preprocess.wgsl)

```wgsl
// src/shaders/preprocess.wgsl

@compute @workgroup_size(256,1,1)
fn preprocess(@builtin(global_invocation_id) gid: vec3<u32>) {
  let idx = gid.x;

  // 1. Read Gaussian Data
  let pos_op = read_gaussian_pos_opacity(idx);

  // 2. Project to Screen Space
  let pos2d = camera.proj * camera.view * vec4<f32>(pos_op.xyz, 1.);
  let z = pos2d.z / pos2d.w; // Depth

  // 3. Compute 2D Covariance (Splat Shape)
  let Sigma_world = ...; // 3D Covariance
  let cov = transpose(T) * Sigma_world * T; // Projected 2D Covariance

  // 4. Store Sort Key (Depth) and Index
  let store_idx = atomicAdd(&sort_infos.keys_size, 1u);
  sort_depths[store_idx] = bitcast<u32>(z);
  sort_indices[store_idx] = store_idx;

  // 5. Write 2D Splat Data
  points_2d[store_idx].pos = pack2x16float(pos2d.xy / pos2d.w);
  // ... write color and conic ...
}
```

### Stage B: Sorting (Radix Sort)

Sorts the Gaussians from back to front using the depth keys generated in Stage A.

### Host Code: [`src/sort/radix_sort.ts`](src/sort/radix_sort.ts)

```typescript
// src/sort/radix_sort.ts

recordSortIndirect(sortStuff, dispatchBuffer, encoder) {
    // 4 Passes for 32-bit keys (8 bits per pass)

    // 1. Histogram Pass (Indirect dispatch based on visible count)
    const histoPass = encoder.beginComputePass(...);
    histoPass.setPipeline(this.histogram_p);
    histoPass.dispatchWorkgroupsIndirect(dispatchBuffer, 0);
    histoPass.end();

    // 2. Prefix Sum Pass
    this.recordPrefixHistogram(...);

    // 3. Scatter Pass (Indirect)
    const scatterPass = encoder.beginComputePass(...);
    scatterPass.setPipeline(this.scatter_even_p);
    scatterPass.dispatchWorkgroupsIndirect(dispatchBuffer, 0);
    scatterPass.end();

    // Repeat for all 4 bytes...
}
```

### Shader Code: [`src/shaders/radix_sort.wgsl`](src/shaders/radix_sort.wgsl)

```wgsl
// src/shaders/radix_sort.wgsl

// Pass 1: Histogram
@compute @workgroup_size(256)
fn calculate_histogram(...) {
    // Count occurrences of each byte value (0-255)
    atomicAdd(&histograms[...], 1u);
}

// Pass 2: Prefix Sum
@compute @workgroup_size(256)
fn prefix_histogram(...) {
    // Calculate global offsets for each bucket
    // ... parallel prefix sum logic ...
}

// Pass 3: Scatter
@compute @workgroup_size(256)
fn scatter_even(...) {
    // Move keys and indices to their sorted positions
    let new_pos = ...;
    payload_out[new_pos] = payload_in[local_id];
}
```

### Stage C: Rasterization (Draw)

Draws the sorted splats as quads.

### Host Code: [`src/renderer/gaussian_renderer.ts`](src/renderer/gaussian_renderer.ts)

```typescript
// src/renderer/gaussian_renderer.ts

renderMulti(pass: GPURenderPassEncoder, ...) {
    pass.setPipeline(this.renderPipeline);

    // Bind sorted data
    pass.setBindGroup(0, this.cameraManager.bindGroup);
    pass.setBindGroup(1, model.bindGroup); // 2D Splats
    pass.setBindGroup(2, sortBindGroup);   // Sorted Indices

    // Indirect Draw: Draw 4 vertices * Num Visible Splats
    pass.drawIndirect(indirectBuffer, 0);
}
```

### Shader Code: [`src/shaders/gaussian.wgsl`](src/shaders/gaussian.wgsl)

```wgsl
// src/shaders/gaussian.wgsl

@vertex
fn vs_main(@builtin(instance_index) in_instance_index: u32, ...) -> VertexOutput {
    // 1. Get Sorted Index
    let splat_idx = indices[in_instance_index];

    // 2. Get 2D Splat Data
    let splat = points_2d[splat_idx];

    // 3. Compute Quad Vertex Position (Billboard)
    let position = vec2<f32>(x, y) * CUTOFF;
    let offset = ... * position; // Apply 2D Covariance

    out.position = vec4<f32>(center + offset, depth, 1.);
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    // 1. Calculate Gaussian Falloff
    let a = dot(in.screen_pos, in.screen_pos);
    if (a > 2. * CUTOFF) { discard; } // Discard if outside radius

    // 2. Apply Alpha
    let alpha = exp(-a) * in.color.a;

    // 3. Output Color (Blended by pipeline state)
    return vec4<f32>(in.color.rgb, alpha);
}
```

## 6. Hybrid Rendering (Three.js Integration)

VisionaryCore can run alongside Three.js in a hybrid mode, sharing the same WebGPU context. This allows mixing standard meshes with Gaussian splats.

### Shared Context Initialization

To make them work together, we must initialize a shared `GPUDevice` that is compatible with ONNX Runtime (which has specific requirements).

### File: [`src/app/three-context.ts`](src/app/three-context.ts)

```typescript
// src/app/three-context.ts

export async function initThreeContext(canvasElement: HTMLCanvasElement) {
	// 1. Create a "smart" WebGPU device (compatible with ONNX)
	const gpu = await initWebGPU_onnx(canvasElement, {
		dummyModelUrl: DEFAULT_DUMMY_MODEL_URL,
		adapterPowerPreference: 'high-performance',
	});

	// 2. Pass this pre-created device to Three.js
	const renderer = new THREE.WebGPURenderer({
		canvas: canvasElement,
		context: gpu.context,
		device: gpu.device, // <--- Crucial: Share the device
	});

	await renderer.init();
	return renderer;
}
```

### Camera Synchronization

Three.js uses a different coordinate system and matrix format than VisionaryCore's internal renderer. The `DirectCameraAdapter` bridges this gap.

### File: [`src/three-integration/GaussianSplattingThreeWebGPU.ts`](src/three-integration/GaussianSplattingThreeWebGPU.ts)

```typescript
// src/three-integration/GaussianSplattingThreeWebGPU.ts

// Inside DirectCameraAdapter.update()
update(camera: THREE.PerspectiveCamera, viewport: [number, number]): void {
    // 1. Sync Three.js matrices
    camera.updateMatrixWorld();
    camera.updateProjectionMatrix();

    // 2. Convert View Matrix (Flip rows for coordinate system match)
    const V = camera.matrixWorldInverse.elements;
    // ... copy V to this.viewMat ...
    // Apply R_y(pi) flip to keep right-handedness
    this.viewMat[0] = -this.viewMat[0]; // Flip X
    // ... (flips rows 0 and 2)

    // 3. Convert Projection Matrix
    // Match Three's projection but compensate for the View flip
    const Pthree = camera.projectionMatrix.elements;
    // ... compute Pprime = Pthree * R ...
}
```

### Interleaved Rendering

In the render loop, we manually inject the Gaussian Splatting passes.

```typescript
// Example Usage (Conceptual)

function animate() {
	// 1. Three.js Standard Render
	renderer.render(scene, camera);

	// 2. Get resources from Three.js context
	const device = renderer.device;
	const commandEncoder = device.createCommandEncoder();
	const textureView = renderer.context.getCurrentTexture().createView();
	const depthView = renderer.depthTexture?.createView(); // Optional for occlusion

	// 3. Render Gaussian Splats (Overlay)
	gaussianSplatting.render(
		commandEncoder,
		textureView,
		camera,
		[width, height],
		depthView, // Passing depth allows splats to be occluded by meshes
	);

	// 4. Submit
	device.queue.submit([commandEncoder.finish()]);
}
```
