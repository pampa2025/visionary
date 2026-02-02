# VisionaryCore Three.js Integration Guide

This guide explains how to integrate the `visionary-core` library into an existing Three.js project to render 3D Gaussian Splatting models using WebGPU.

## Prerequisites

Your project must be using a WebGPU-compatible version of Three.js.

**Required Peer Dependencies:**
*   `three` (>= 0.171.0)
*   `gl-matrix`
*   `onnxruntime-web` (if using ONNX models)

## Installation

### 1. Install Dependencies

```bash
npm install three gl-matrix onnxruntime-web
```

### 2. Install VisionaryCore

You can install the built library directly from a local path or by copying the `dist` folder.

**Option A: Local Path (Recommended for development)**
```bash
npm install /path/to/visionary/visionary-core-1.0.1.tgz
# Or directly link the folder
npm install /path/to/visionary
```

**Option B: Copy Files**
Copy the `dist` folder from `visionary` to your project (e.g., `libs/visionary-core`) and import from there.

## Basic Usage

The library relies on WebGPU. You must initialize the WebGPU context using the library's helper to ensure compatibility between Three.js and ONNX Runtime.

### 1. Initialize WebGPU Context

Replace the standard `THREE.WebGPURenderer` instantiation with `initThreeContext`:

```typescript
import * as THREE from 'three/webgpu';
import { initThreeContext } from 'visionary-core';

const canvas = document.querySelector('#canvas') as HTMLCanvasElement;

// This initializes WebGPU for both Three.js and ONNX Runtime
const renderer = await initThreeContext(canvas);

if (!renderer) {
    throw new Error("WebGPU initialization failed");
}

// Configure renderer as needed
renderer.setSize(window.innerWidth, window.innerHeight);
```

### 2. Loading Models

Use the `UnifiedModelLoader` to load Gaussian Splatting models (`.ply`, `.splat`, `.ksplat`) or other 3D formats (`.onnx`, `.fbx`, `.glb`).

```typescript
import { UnifiedModelLoader } from 'visionary-core';

// Create the loader
const loader = new UnifiedModelLoader(renderer, scene);

// Load a Gaussian Splatting PLY file
try {
    const result = await loader.loadModel('/path/to/model.ply', {
        type: 'gaussian', // Optional: explicitly specify type
        onProgress: (p) => console.log(`Loading: ${(p * 100).toFixed(0)}%`)
    });
    
    console.log(`Loaded ${result.info.name}`);
    // The model is automatically added to the scene
    
} catch (e) {
    console.error("Failed to load model", e);
}
```

### 3. Complete Example

Here is a full example setup:

```typescript
import * as THREE from 'three/webgpu';
import { OrbitControls } from 'three/examples/jsm/controls/OrbitControls.js';
import { initThreeContext, UnifiedModelLoader } from 'visionary-core';

async function main() {
    // 1. Setup Canvas
    const canvas = document.getElementById('canvas') as HTMLCanvasElement;
    
    // 2. Initialize WebGPU Renderer
    const renderer = await initThreeContext(canvas);
    if (!renderer) return;

    // 3. Setup Scene
    const scene = new THREE.Scene();
    scene.background = new THREE.Color(0x333333);
    
    const camera = new THREE.PerspectiveCamera(60, window.innerWidth / window.innerHeight, 0.1, 500);
    camera.position.set(0, 5, 10);
    
    const controls = new OrbitControls(camera, canvas);
    
    // 4. Add Helpers
    scene.add(new THREE.GridHelper(20, 20));
    scene.add(new THREE.AxesHelper(5));
    const light = new THREE.DirectionalLight(0xffffff, 1);
    light.position.set(1, 2, 3);
    scene.add(light);

    // 5. Load Gaussian Model
    const loader = new UnifiedModelLoader(renderer, scene);
    await loader.loadModel('./models/scene.ply', {
        type: 'gaussian'
    });

    // 6. Render Loop
    renderer.setAnimationLoop(() => {
        controls.update();
        renderer.render(scene, camera);
    });
    
    // 7. Handle Resize
    window.addEventListener('resize', () => {
        camera.aspect = window.innerWidth / window.innerHeight;
        camera.updateProjectionMatrix();
        renderer.setSize(window.innerWidth, window.innerHeight);
    });
}

main();
```

## Advanced Features

### ONNX Models
To load ONNX-based Gaussian models, ensure you have the `.onnx` file and specify the camera matrix if needed.

```typescript
await loader.loadModel('./model.onnx', {
    cameraMatrix: myFloat32Array // Optional custom view matrix
});
```

### Direct Access
You can also import specific classes if you need lower-level control:

```typescript
import { 
    GaussianRenderer, 
    GaussianModel,
    ModelManager 
} from 'visionary-core';
```

## Troubleshooting

*   **"WebGPU not supported"**: Ensure you are using a browser with WebGPU support (Chrome 113+, Edge 113+).
*   **"Shader compilation error"**: Check that your `three` version matches the peer dependency requirement.
*   **ONNX Runtime errors**: Ensure `onnxruntime-web` is installed and the `.wasm` files are served correctly by your build tool (Vite/Webpack).
