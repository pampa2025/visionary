# Visionary Framework Tutorial

Welcome to **Visionary**, a WebGPU-based framework for rendering and editing 3D Gaussian Splatting (3DGS) scenes directly in the browser. This tutorial will guide you through the project structure, installation, usage, and key code components to help you understand and extend the framework.

## 1. Introduction

Visionary is designed to be a "World Model Carrier," supporting:

- **Real-time Rendering**: High-performance rendering of millions of Gaussian splats using WebGPU.
- **Multiple Formats**: Supports PLY, SPLAT, KSplat, and ONNX for dynamic models (4DGS, Avatars).
- **Web-Native**: Built with TypeScript and runs in modern browsers with WebGPU support.
- **Extensible**: Modular architecture allowing custom loaders, rendering logic, and post-processing.

## 2. Prerequisites

Before you begin, ensure you have:

- **Node.js** (v18 or higher) installed.
- A browser with **WebGPU** support (e.g., Chrome 113+, Edge, or Firefox Nightly).
- A discrete GPU (NVIDIA/AMD) is recommended for best performance.

## 3. Installation & Running

1.  **Clone the repository**:

    ```bash
    git clone https://github.com/Visionary-Laboratory/visionary.git
    cd visionary
    ```

2.  **Install dependencies**:

    ```bash
    npm install
    ```

3.  **Start the development server**:

    ```bash
    npm run dev
    ```

4.  **Open the demo**:
    Visit `http://localhost:3000/demo/simple/index.html` to see the basic viewer.

## 4. Project Structure

The codebase is organized in the `src` directory. Here's a high-level overview:

- [src/main.ts](src/main.ts): The application entry point. It initializes the `App` and sets up global window functions.
- [src/app](src/app): Contains the core application logic.
  - [App](src/app/app.ts): The main class that orchestrates the viewer.
  - [managers](src/app/managers): specialized managers for Models, Camera, Animation, Files, and ONNX.
- [src/renderer](src/renderer): The WebGPU rendering engine.
  - [GaussianRenderer](src/renderer/gaussian_renderer.ts): Handles the rendering pipeline, sorting, and drawing of splats.
- [src/io](src/io): Loaders for various file formats (PLY, SPLAT, etc.).
- [src/ONNX](src/ONNX): Logic for loading and inferencing ONNX models (for dynamic avatars).
- [src/shaders](src/shaders): WGSL shader files for compute and fragment shaders.
- [src/webgpu-context.ts](src/app/webgpu-context.ts): Manages the WebGPU device and context.

## 5. Code Walkthrough

### 5.1 Application Initialization

The application starts in [main.ts](src/main.ts). It waits for the DOM content to load, initializes the ONNX environment, and then creates an instance of the `App` class.

```typescript
// src/main.ts
const app = new App();
app.init().then(() => {
	// Expose app to window for debugging/scripting
	window.gaussianApp = app;
});
```

The [App](src/app/app.ts) class initializes the key managers:

```typescript
// src/app/app.ts
constructor() {
    this.modelManager = new ModelManager(MAX_MODELS);
    this.cameraManager = new CameraManager('orbit');
    this.renderLoop = new RenderLoop(this.modelManager, ...);
    // ...
}
```

### 5.2 Loading Models

Model loading is handled by the [FileLoader](src/app/managers/file-loader.ts) and [ModelManager](src/app/managers/model-manager.ts). The `io` module provides specific loaders for different formats.

For example, `src/io/ply_loader.ts` handles standard PLY files. The [unified-model-loader.ts](src/app/unified-model-loader.ts) (or `FileLoader`) helps determine which loader to use based on the file extension.

To load a model programmatically:

```typescript
// Example usage (if you have access to the app instance)
await app.loadONNXModelPublic('path/to/model.onnx', 'MyModel');
```

### 5.3 Rendering Pipeline

The rendering logic resides in [GaussianRenderer](src/renderer/gaussian_renderer.ts). It performs the following steps:

1.  **Sort**: Sorts the Gaussian splats based on camera distance (using [Radix Sort](src/sort/radix_sort.ts)).
2.  **Preprocess**: Prepares the splat data for rendering (using [GaussianPreprocessor](src/preprocess/gaussian_preprocessor.ts)).
3.  **Draw**: Executes the render pass to draw the splats to the screen.

The shaders are located in `src/shaders`. For example, [gaussian.wgsl](src/shaders/gaussian.wgsl) contains the vertex and fragment shaders for rendering the splats.

### 5.4 ONNX Integration

For dynamic scenes (like 4DGS or avatars), the framework uses ONNX Runtime. The [ONNXManager](src/app/managers/onnx-manager.ts) handles loading `.onnx` files and running inference to update the Gaussian positions/attributes per frame.

## 6. Creating a Custom Demo

To create your own demo, you can duplicate the `demo/simple` folder and modify `index.html`.

1.  **Create a new HTML file**: `demo/my-demo/index.html`.
2.  **Import the main script**: Ensure you point to `src/main.ts` (or your custom entry point).
    ```html
    <script type="module" src="../../src/main.ts"></script>
    ```
3.  **Customize UI**: You can add your own buttons and hook them up to the global `window.gaussianApp` instance or modify `src/main.ts` to expose more functionality.

### Advanced Example: Showcase

For a more complex example involving scene configurations and multiple assets, check out the **Showcase Demo** in [demo/showcase](demo/showcase). It uses:

- [ShowcaseScene.ts](demo/showcase/scripts/ShowcaseScene.ts): Manages scene logic.
- [sceneConfigs.ts](demo/showcase/scripts/sceneConfigs.ts): Defines presets for different scenes.

## 7. Key Files to Explore

- **If you want to change how models are rendered**: Look at [src/renderer/gaussian_renderer.ts](src/renderer/gaussian_renderer.ts) and [src/shaders/gaussian.wgsl](src/shaders/gaussian.wgsl).
- **If you want to add a new file format**: Check [src/io](src/io) and implement a new loader following the existing patterns.
- **If you want to modify the UI**: Check [src/app/ui-controller.ts](src/app/ui-controller.ts).
- **If you are debugging WebGPU**: [src/app/webgpu-context.ts](src/app/webgpu-context.ts) is a good place to start.

---

Happy Coding with Visionary!
