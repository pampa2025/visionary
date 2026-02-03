# Visionary + R3F: The "Renderer-First" Approach

This guide outlines an alternative integration strategy where `GaussianThreeJSRenderer` is treated as a **Render System** rather than a Scene Mesh. This aligns better with React Three Fiber's component philosophy, separating the *rendering logic* from the *scene objects*.

## Core Concept

Instead of a single "God Object" in the scene, we separate concerns:
1.  **`<GaussianSplattingSystem />`**: A singleton component that manages the WebGPU renderer, handles the render loop, and orchestration. It is **not** visible in the scene.
2.  **`<SplatModel />`**: Individual components representing Gaussian models. They can be placed anywhere in the React tree, transformed, and managed like standard R3F meshes.

---

## Architecture Overview

### 1. The Context (`GaussianContext`)
We need a context to allow `<SplatModel />` instances to register themselves with the System.

```tsx
import { createContext, useContext } from 'react';
import type { GaussianThreeJSRenderer } from './visionary/src/app/GaussianThreeJSRenderer';

interface GaussianContextValue {
  renderer: GaussianThreeJSRenderer | null;
  registerModel: (model: GaussianModel) => void;
  unregisterModel: (id: string) => void;
}

export const GaussianContext = createContext<GaussianContextValue | null>(null);
```

### 2. The System Component (`<GaussianSplattingSystem />`)

This component instantiates the renderer *once* and drives the frame loop. It does **not** add the renderer to the scene graph.

**Key Logic:**
*   Initializes `GaussianThreeJSRenderer` with an empty model list.
*   Uses `useFrame` to manually trigger the rendering pipeline.
*   Calls `renderer.onBeforeRender()` explicitly to trigger the sort/prepare phase.

```tsx
import { useFrame, useThree } from '@react-three/fiber';
import { useState, useMemo } from 'react';
import { GaussianThreeJSRenderer } from './visionary/src/app/GaussianThreeJSRenderer';

export function GaussianSplattingSystem({ children, autoDepth = true }) {
  const { gl, scene, camera } = useThree();
  const [rendererInstance, setRendererInstance] = useState<GaussianThreeJSRenderer | null>(null);

  // 1. Initialize Renderer (Singleton)
  useMemo(() => {
    if (gl instanceof THREE.WebGPURenderer) {
      // Initialize with empty array, models will register themselves
      const renderer = new GaussianThreeJSRenderer(gl, scene, []);
      renderer.setAutoDepthMode(autoDepth);
      setRendererInstance(renderer);
    }
  }, [gl, scene, autoDepth]);

  // 2. The Render Loop (Hijack)
  useFrame(() => {
    if (!rendererInstance) return;

    // A. Update Animations
    rendererInstance.updateDynamicModels(camera);

    // B. Prepare / Sort (Crucial Step!)
    // Since the renderer isn't in the scene, onBeforeRender isn't called automatically.
    // We call it manually to trigger sorting and GPU sync.
    rendererInstance.onBeforeRender(gl, scene, camera);

    // C. Render Phase 1: Depth Capture
    rendererInstance.renderThreeScene(camera);

    // D. Render Phase 2: Draw Splats
    rendererInstance.drawSplats(gl, scene, camera);
    
    // E. Overlay (Optional)
    // rendererInstance.renderOverlayScene(overlayScene, camera);

  }, 1); // Priority 1 (after standard updates)

  // 3. Context Provider for Children
  const contextValue = useMemo(() => ({
    renderer: rendererInstance,
    registerModel: (model) => rendererInstance?.appendGaussianModel(model),
    unregisterModel: (id) => rendererInstance?.removeModelById(id)
  }), [rendererInstance]);

  return (
    <GaussianContext.Provider value={contextValue}>
      {children}
    </GaussianContext.Provider>
  );
}
```

### 3. The Model Component (`<SplatModel />`)

This component wraps a loaded `GaussianModel`. It adds the model to the Three.js scene (so it has a transform) and registers it with the System.

```tsx
import { useContext, useEffect } from 'react';
import { GaussianContext } from './GaussianContext';

export function SplatModel({ model, ...props }) {
  const { registerModel, unregisterModel } = useContext(GaussianContext);

  useEffect(() => {
    // 1. Register with the renderer system
    registerModel(model);
    
    return () => {
      // 2. Cleanup
      unregisterModel(model.id); // Assuming model has an ID or we track it
    };
  }, [model, registerModel, unregisterModel]);

  // 3. Add to Scene Graph
  // GaussianModel likely extends Object3D, so we can render it as a primitive.
  // This allows R3F to handle transforms: <SplatModel position={[10, 0, 0]} />
  return <primitive object={model} {...props} />;
}
```

---

## Comparison: Mesh vs. Renderer Approach

| Feature | Mesh Approach (Previous) | Renderer Approach (Recommended) |
| :--- | :--- | :--- |
| **Structure** | Monolithic `<GaussianSplatting models={[...]} />` | Composable `<System><Model /><Model /></System>` |
| **Dynamic Loading** | Harder (requires re-creating renderer or managing state array) | **Easy** (Models mount/unmount independently) |
| **Positioning** | Transforms applied to the "God Mesh" (moves all splats) | **Individual** (Each `<SplatModel>` has its own transform) |
| **R3F Alignment** | Low (imperative management) | **High** (Declarative, component-based) |

## Implementation Roadmap

1.  **Modify `GaussianThreeJSRenderer` (Optional but recommended)**:
    *   Currently, it *extends* `Mesh`. While we can ignore this, it's cleaner if we eventually decouple it.
    *   For now, we just instantiate it `new GaussianThreeJSRenderer(...)` but **never add it to the scene**.
    *   Ensure `appendGaussianModel` works correctly for runtime additions (it does, based on code analysis).

2.  **Create the Components**:
    *   Implement `GaussianContext`.
    *   Implement `GaussianSplattingSystem`.
    *   Implement `SplatModel`.

3.  **Usage in App**:

```tsx
<Canvas>
  <GaussianSplattingSystem>
     <SceneContent />
  </GaussianSplattingSystem>
</Canvas>

function SceneContent() {
  const modelA = useLoader(GaussianLoader, 'a.ply');
  const modelB = useLoader(GaussianLoader, 'b.ply');

  return (
    <>
      <SplatModel model={modelA} position={[-5, 0, 0]} />
      <SplatModel model={modelB} position={[5, 0, 0]} rotation-y={Math.PI / 4} />
      <OrbitControls />
    </>
  );
}
```

This approach offers significantly better flexibility for complex scenes where splats need to be loaded, moved, or destroyed dynamically.
