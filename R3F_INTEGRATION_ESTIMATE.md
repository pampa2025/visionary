# Visionary + React Three Fiber (R3F) Integration Estimate

Based on the analysis of `GaussianThreeJSRenderer.ts`, here is the estimated routine for integrating the Visionary core (Gaussian Splatting) into a React Three Fiber project.

## Core Concept

The `GaussianThreeJSRenderer` is a hybrid object:
1.  **It is a `THREE.Mesh`**: It can be added to the scene graph using `<primitive object={...} />`.
2.  **It is a Renderer**: It manages its own WebGPU render passes and requires manual control over the rendering sequence.

To integrate with R3F, we must **disable R3F's default render loop** and drive the `GaussianThreeJSRenderer` manually within `useFrame`.

---

## Step-by-Step Integration Routine

### 1. Prerequisites & Setup
Ensure your R3F project is using a WebGPU-compatible version of Three.js (likely r167+ as seen in the codebase).

```bash
npm install three @types/three @react-three/fiber
```

**Important**: You must configure the `Canvas` to use the WebGPU renderer (or a compatible backend). R3F doesn't default to WebGPU yet in all versions.

### 2. Model Loading (Suspense-ready)
Create a hook or loader to handle `UnifiedModelLoader` or `GaussianModel` creation. Since `GaussianThreeJSRenderer` expects an array of `GaussianModel`s in its constructor, these must be loaded *before* the renderer component is mounted.

```typescript
// useGaussianModels.ts
import { useLoader } from '@react-three/fiber';
// You might need to wrap the existing UnifiedModelLoader in a promise-compatible way
// or use simple useEffect loading if Suspense isn't strictly required.
```

### 3. The `<GaussianSplatting />` Component

This is the core wrapper. It needs to:
1.  Instantiate `GaussianThreeJSRenderer` once.
2.  Add it to the scene.
3.  Take over the render loop.

#### Draft Implementation

```tsx
import React, { useEffect, useMemo, useRef } from 'react';
import { useThree, useFrame, extend } from '@react-three/fiber';
import { GaussianThreeJSRenderer } from './visionary/src/app/GaussianThreeJSRenderer';
import { GaussianModel } from './visionary/src/app/GaussianModel';
import * as THREE from 'three/webgpu'; // Ensure correct import

interface GaussianSplattingProps {
  models: GaussianModel[];
  autoDepth?: boolean;
}

export function GaussianSplatting({ models, autoDepth = true }: GaussianSplattingProps) {
  const { gl, scene, camera, size } = useThree();
  const rendererRef = useRef<GaussianThreeJSRenderer | null>(null);

  // 1. Instantiate the renderer
  // We use useMemo to ensure it's created once per set of requirements
  const gaussianRenderer = useMemo(() => {
    if (!(gl instanceof THREE.WebGPURenderer)) {
        console.error("GaussianSplatting requires a WebGPURenderer!");
        return null;
    }
    
    const renderer = new GaussianThreeJSRenderer(gl, scene, models);
    renderer.setAutoDepthMode(autoDepth);
    return renderer;
  }, [gl, scene, models, autoDepth]);

  useEffect(() => {
    rendererRef.current = gaussianRenderer;
    // Cleanup on unmount
    return () => {
      gaussianRenderer?.disposeDepthResources();
      // Optional: dispose models if they are owned by this component
    };
  }, [gaussianRenderer]);

  // 2. Handle Resizing
  // R3F handles canvas resizing, but we might need to notify our renderer if it caches sizes
  useEffect(() => {
    if (gaussianRenderer) {
       // GaussianThreeJSRenderer.onResize is currently disabled/empty in source, 
       // but strictly speaking, we rely on gl.getDrawingBufferSize in the render loop.
       // So explicit resize calls might not be needed if the loop checks size every frame.
    }
  }, [size, gaussianRenderer]);

  // 3. The Render Loop
  // We use priority=1 to ensure this runs after standard updates but we are TAKING OVER rendering.
  useFrame(({ gl, scene, camera }) => {
    if (!gaussianRenderer) return;

    // A. Update Animations
    // You might pass 'clock.elapsedTime' or delta here
    gaussianRenderer.updateDynamicModels(camera);

    // B. Render Phase 1: Standard Scene + Depth
    // This REPLACES the default gl.render(scene, camera)
    gaussianRenderer.renderThreeScene(camera);

    // C. Render Phase 2: Splats
    // This draws the splats on top using the depth captured above
    gaussianRenderer.drawSplats(gl, scene, camera);

    // D. Overlay (Optional)
    // gaussianRenderer.renderOverlayScene(overlayScene, camera);
    
  }, 1); // Render priority

  // 4. Add to Scene Graph
  // It extends Mesh, so we can add it as a primitive. 
  // This is required for 'onBeforeRender' hooks if we were using the standard loop,
  // but since we are driving it manually, adding it to the scene is mostly for 
  // transform inheritance if we wanted to move the whole world (rare for splats).
  return gaussianRenderer ? <primitive object={gaussianRenderer} /> : null;
}
```

### 4. Configuration in `Canvas`

You must disable the default render loop of R3F to avoid double rendering (or rendering without the splat passes).

```tsx
<Canvas
  frameloop="always" // We still want a loop, but we will control what happens inside it
  gl={(canvas) => {
    // Custom WebGPURenderer instantiation
    const renderer = new THREE.WebGPURenderer({ canvas, antialias: true });
    return renderer;
  }}
>
  {/* Disable default render logic? 
      R3F's useFrame loop will still trigger global render unless we stop it.
      Actually, R3F only auto-renders if you don't use `useFrame` with `render=true` (which is default).
      
      To suppress default R3F rendering while keeping the loop running for our custom pass:
      We can use `useFrame(({ gl, scene, camera }) => { ... }, 1)` 
      AND make sure we don't return anything that R3F interprets as "I rendered".
      
      Better approach: 
      Disable auto-render globally on Canvas? 
      <Canvas frameloop="demand" /> might stop animations.
      
      Standard R3F override pattern:
      useFrame(({ gl, scene, camera }) => {
         // My custom render
         // ...
      }, 1)
      
      Note: R3F renders at priority 0. If we run at priority 1, we run AFTER. 
      But R3F would have already rendered the scene once at priority 0!
      
      SOLUTION: 
      We need to disable the default render. 
      Inside <Canvas>, use `useThree(({ set }) => set({ frameloop: 'never' }))`? 
      No, 'never' stops the loop.
      
      Correct R3F way to take over rendering:
      useFrame(({ gl, scene, camera }) => {
        // Render logic
      }, 1) 
      
      AND set `<Canvas render={() => null} />` (if supported) or simply clear the default render loop.
  */}
  <RenderLoopOverride /> 
  <GaussianSplatting models={loadedModels} />
</Canvas>
```

**Refined Strategy for Disabling Default Render**:
R3F renders automatically. To prevent the "standard" render (which would miss the splats or depth capture setup), we can inject a component that disables the default render priority.

```tsx
function RenderManager() {
  const { set } = useThree();
  useEffect(() => {
    // Disable R3F's default render loop (which usually sits at index 0)
    // Actually, setting specific render priority is tricky. 
    // Easiest way: Use `gl.autoClear = false` and handle clearing manually in our loop.
  }, []);
  return null;
}
```

*Correction*: `GaussianThreeJSRenderer.renderThreeScene()` handles clearing and rendering the scene to a target. If R3F *also* renders the scene to the screen, we waste a frame.
**Best Practice**: In R3F, you can use `useFrame` with a positive priority to override the render loop if you execute `gl.render()` yourself, effectively acting as the render pass. However, R3F default render happens at the end of the frame.
To completely replace it, we can just let `GaussianThreeJSRenderer` do the work. The issue is `renderThreeScene` renders to a *target*, then `blit` to screen.
If R3F renders normally first, it draws to screen. Then we draw to target, then blit to screen (overwriting). This is inefficient but functional.
To optimize, we should disable R3F's auto-render: `gl.autoRender = false` (not a property).
In R3F v8, we can pass `render` prop to Canvas? No.
We can use `useFrame` to render, and ensure we consume the frame.

### 5. Managing Props & Reactivity
Map the imperative setters to React props.

```tsx
useEffect(() => {
  if (gaussianRenderer) {
    models.forEach((m, i) => {
        const id = `model_${i}`;
        gaussianRenderer.setModelVisible(id, visible);
        gaussianRenderer.setModelGaussianScale(id, scale);
    });
  }
}, [visible, scale, models, gaussianRenderer]);
```

### 6. Summary of Work Required
1.  **Wrapper Component**: Create `GaussianSplatting.tsx`.
2.  **Context Check**: Ensure `WebGPURenderer` is enforced.
3.  **Render Loop Hijack**: Implement the manual render sequence (`renderThreeScene` -> `drawSplats`) inside `useFrame`.
4.  **Prop Binding**: Bind React props to `renderer.setModel*` methods.
5.  **Asset Loading**: Wrap `UnifiedModelLoader` for React consumption.

This routine provides a clean, "React-way" integration while respecting the complex hybrid rendering requirements of the Visionary engine.
