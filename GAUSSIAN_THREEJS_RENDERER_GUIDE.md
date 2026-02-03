# GaussianThreeJSRenderer.ts: The Core of Hybrid Rendering

This guide provides a detailed walkthrough of `GaussianThreeJSRenderer.ts`, the central component responsible for integrating Gaussian Splatting (3DGS) with the Three.js WebGPU renderer in the Visionary engine.

## Overview

`GaussianThreeJSRenderer` is a specialized class that bridges the gap between standard Three.js scene graphs and the custom WebGPU pipeline required for high-performance Gaussian Splatting. It ensures that 3DGS models are rendered correctly within a Three.js scene, respecting depth occlusion from standard meshes and supporting dynamic updates.

### Key Responsibilities

1.  **Hybrid Rendering Pipeline**: Coordinates the rendering of standard Three.js meshes and Gaussian Splats.
2.  **Depth Integration**: Captures depth from the Three.js scene to ensure Gaussian splats are correctly occluded by standard geometry.
3.  **Dynamic Model Management**: Handles updates for dynamic 4D Gaussian models (animation playback).
4.  **WebGPU Resource Management**: Manages GPU devices, textures, buffers, and bind groups for the Gaussian renderer.
5.  **Gizmo/Overlay Rendering**: Supports rendering overlay scenes (like transform gizmos) on top of the main content.

---

## Core Architecture

The renderer extends `THREE.Mesh` but operates primarily through direct WebGPU calls rather than standard Three.js geometry/material pipelines.

```typescript
export class GaussianThreeJSRenderer extends THREE.Mesh {
    // ...
}
```

### 1. Initialization

The constructor takes the Three.js WebGPU renderer, the scene, and an array of `GaussianModel` instances. It initializes the internal `GaussianRenderer` (the low-level engine) and sets up the WebGPU context.

**Key Configuration:**
- `frustumCulled = false`: Essential setting. Since the renderer itself doesn't have standard geometry bounds, we disable frustum culling to ensure `onBeforeRender` is always called.

### 2. The Rendering Loop

The rendering process is split into distinct phases to handle the hybrid nature of the content.

#### Phase 1: Depth Capture (`renderThreeScene`)

Before drawing splats, we need to know where the standard 3D objects are. `renderThreeScene` renders the standard Three.js scene into a `THREE.RenderTarget` with a depth texture.

*   **Auto Depth Mode**: By default (`autoDepthMode = true`), it captures the full scene.
*   **Format Handling**: Uses `THREE.HalfFloatType` (16-bit float) for the render target to support linear filtering, which avoids WebGPU validation errors on some platforms.
*   **Color Space**: Maintains `LinearSRGBColorSpace` internally and converts to sRGB only during the final blit to canvas, ensuring correct HDR rendering.

#### Phase 2: Preparation (`onBeforeRender`)

Called by Three.js before rendering the mesh. This is where we prepare the Gaussian data for the GPU.

*   **Filtering**: Identifies visible `PointCloud` or `DynamicPointCloud` instances.
*   **Transform Sync**: Syncs Three.js model matrices (position, rotation, scale) to the GPU.
*   **Sorting**: Calls `renderer.prepareMulti` to sort splats based on camera distance (crucial for alpha blending).

#### Phase 3: Drawing Splats (`drawSplats`)

This is where the actual Gaussian rendering happens.

*   **Depth Injection**: Retrieves the depth texture from Phase 1 and passes it to the `GaussianRenderer`.
*   **Render Pass**: Creates a WebGPU render pass that loads the existing color buffer (with the Three.js scene) and draws the sorted splats on top.
*   **Depth Testing**: Enables depth testing against the injected depth buffer so splats hidden behind standard meshes are not drawn.

#### Phase 4: Overlay (`renderOverlayScene`)

Renders auxiliary content (like gizmos) that should appear on top of everything else. It renders to a separate target and composites it onto the main canvas.

---

## Key Methods Explained

### `renderThreeScene(camera: THREE.Camera)`

**Purpose**: Renders the standard scene to capture depth and color.

**Why it's important**: Standard Three.js rendering doesn't automatically expose the depth buffer to custom WebGPU passes in a way we can easily use. This method explicitly renders to a target we control.

**Implementation Details**:
- Checks for resize events.
- Creates/Updates `sceneDepthRT` (Render Target).
- Renders the scene.
- Blits the result to the screen (so the user sees the standard scene).

### `updateDynamicModels(camera: THREE.Camera, time?: number)`

**Purpose**: Updates 4D Gaussian models for animation.

**Mechanism**:
- Uses `CameraAdapter` to get view/projection matrices.
- Iterates through all models and calls their `update` method.
- Handles time-based updates for playback.

### `drawSplats(...)`

**Purpose**: The main draw call for Gaussians.

**Workflow**:
1.  Validates the camera (must be `PerspectiveCamera`).
2.  Acquires the WebGPU device and context.
3.  **Depth Access**: Attempts to get the native WebGPU texture from the `sceneDepthTexture`.
4.  **Pipeline Configuration**: Sets up depth testing based on whether depth is available.
5.  **Execution**: Creates a command encoder and executes `renderer.renderMulti`.

### `blitRenderTargetToCanvas(...)`

**Purpose**: Copies the off-screen render target (from Phase 1) to the visible canvas.

**Technical Note**: It uses a custom shader with a full-screen triangle. Crucially, it handles the **Linear to sRGB** conversion to ensure colors look correct on the monitor.

---

## Dynamic Model & Parameter API

The class exposes a comprehensive API for manipulating individual models at runtime. These methods typically take a `modelId` (e.g., "model_0") and a value.

### Common Operations

*   **Visibility**: `setModelVisible(id, boolean)`
*   **Scaling**: `setModelGaussianScale(id, scale)` - Adjusts splat size.
*   **Visualization**: `setModelRenderMode(id, mode)` - Switch between different debug views (e.g., depth, normal).
*   **Cropping**: `setModelCutoffScale`, `setModelOpacityScale`.

### Animation Control

For 4D models:
*   `startModelAnimation(id, speed)`
*   `pauseModelAnimation(id)`
*   `setModelTimeScale(id, scale)`
*   `setModelAnimationIsLoop(id, boolean)`

---

## Usage Example

How this class is typically used in the application:

```typescript
// 1. Setup Three.js
const renderer = new THREE.WebGPURenderer({ ... });
const scene = new THREE.Scene();

// 2. Load Models
const models = await loader.loadModels(files);

// 3. Create the Hybrid Renderer
const gaussianRenderer = new GaussianThreeJSRenderer(renderer, scene, models);
scene.add(gaussianRenderer); // Add to scene so onBeforeRender is called

// 4. Animation Loop
function animate() {
    // A. Update logic (animations, controls)
    controls.update();
    gaussianRenderer.updateDynamicModels(camera, time);

    // B. Render
    // Instead of just renderer.render(), we use the hybrid pipeline:
    
    // Step 1: Render standard scene & capture depth
    gaussianRenderer.renderThreeScene(camera);
    
    // Step 2: Draw Splats (internally handles sorting and drawing)
    gaussianRenderer.drawSplats(renderer, scene, camera);
    
    // Step 3: Optional Overlay
    gaussianRenderer.renderOverlayScene(overlayScene, camera);
}
```

## Best Practices & Gotchas

1.  **Frustum Culling**: Never enable frustum culling on this mesh (`frustumCulled = false`). The bounding box of the splats is managed internally, and Three.js's automatic culling will likely hide the model incorrectly.
2.  **Camera Type**: Only `THREE.PerspectiveCamera` is fully supported. Orthographic cameras may cause projection issues.
3.  **Depth Format**: The renderer uses `HalfFloatType` for depth textures. This balances precision and performance while avoiding "UnfilterableFloat" errors on some WebGPU implementations.
4.  **Context Loss**: While WebGPU is robust, handle device loss scenarios by checking `renderer.backend.device`.

## Debugging

The class includes several debug flags accessible via global scope (for development):
- `GS_DEBUG_FLAG`: Log transform syncs.
- `GS_DEPTH_DEBUG`: Log depth texture creation and access details.
- `GS_VIDEO_EXPORT_DEBUG`: Debug video export/rendering issues.

Use `diagnoseDepth()` in the console to print the current status of depth resources and modes.
