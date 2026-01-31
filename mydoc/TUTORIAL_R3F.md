# Integration with React Three Fiber (R3F)

This tutorial guides you through integrating **Visionary** into a React Three Fiber project. Since Visionary is built on **WebGPU**, there are specific requirements for setting up the R3F `<Canvas>`.

## 1. Prerequisites

-   A React project with `@react-three/fiber`.
-   **Three.js** version compatible with WebGPU (e.g., `three/webgpu` imports).
-   The **Visionary** source code available in your project (e.g., in a `src/visionary` folder).

## 2. Setting up the WebGPURenderer

Visionary **requires** `THREE.WebGPURenderer`. Standard R3F defaults to `WebGLRenderer`. You must explicitly configure the `gl` prop on the `<Canvas>`.

```jsx
import { Canvas } from '@react-three/fiber'
import * as THREE from 'three/webgpu'

function App() {
  return (
    <Canvas
      // Create a WebGPURenderer instead of the default WebGLRenderer
      gl={canvas => {
        const renderer = new THREE.WebGPURenderer({ 
            canvas,
            antialias: true,
            alpha: true 
        });
        renderer.init().then(() => {
            console.log('WebGPURenderer initialized');
        });
        return renderer;
      }}
      camera={{ position: [0, 0, 5], fov: 60 }}
    >
      <Scene />
    </Canvas>
  )
}
```

## 3. Creating the Visionary Component

We will create a `<VisionaryInstancedScene />` component that wraps the `loadGaussianModels` function. This component will:
1.  Access the `renderer` and `scene` from R3F context.
2.  Load the Gaussian Splatting models.
3.  Add them to the scene graph.

Create a file named `VisionaryScene.jsx` (or `.tsx`):

```tsx
import React, { useEffect, useRef, useState } from 'react'
import { useThree, useFrame } from '@react-three/fiber'
import * as THREE from 'three/webgpu'

// Import from your local copy of Visionary
// Adjust the path according to your project structure
import { loadGaussianModels } from './visionary/src/app' 

export function VisionaryInstancedScene({ modelPaths }) {
  const { gl, scene } = useThree()
  const groupRef = useRef(null)
  const [gsRenderer, setGsRenderer] = useState(null)

  useEffect(() => {
    if (!gl || !groupRef.current) return

    let active = true
    let rendererInstance = null

    const load = async () => {
      try {
        // loadGaussianModels takes:
        // 1. renderer (WebGPURenderer)
        // 2. scene (THREE.Scene)
        // 3. frame (THREE.Group) -> We pass our ref here so models are added to this group
        // 4. modelPaths (string[])
        rendererInstance = await loadGaussianModels(
          gl, 
          scene, 
          groupRef.current, 
          modelPaths
        )

        if (active && rendererInstance) {
          setGsRenderer(rendererInstance)
          // Note: loadGaussianModels automatically adds the 'renderer' mesh to the scene.
          // We might want to manually manage its parent if needed, but for now we let it be.
        }
      } catch (err) {
        console.error("Failed to load Gaussian models:", err)
      }
    }

    load()

    // Cleanup function
    return () => {
      active = false
      if (rendererInstance) {
        // Remove the renderer mesh from the scene to prevent memory leaks/ghost objects
        rendererInstance.removeFromParent()
        
        // If there's a dispose method, call it (check implementation)
        // rendererInstance.dispose?.() 
      }
      
      // The models attached to groupRef will be unmounted automatically by React/R3F
      // when the group is removed, but we should ensure clean disposal if possible.
    }
  }, [gl, scene, modelPaths]) // Re-run if these change

  // Optional: Hook into the render loop if you need to do per-frame updates manually
  // Visionary usually handles its own rendering via the mesh's render method or hooks.
  useFrame(() => {
    // If you need to sync anything
  })

  return (
    <group ref={groupRef}>
      {/* Models will be added here by loadGaussianModels */}
    </group>
  )
}
```

## 4. Using the Component

Now you can use it in your main App:

```jsx
import { Suspense } from 'react'
import { OrbitControls } from '@react-three/drei'
import { VisionaryInstancedScene } from './VisionaryScene'

export default function Scene() {
  return (
    <>
      <ambientLight intensity(0.5) />
      <OrbitControls />
      
      <Suspense fallback={null}>
        <VisionaryInstancedScene 
          modelPaths={[
            '/models/point_cloud.ply',
            '/models/avatar.onnx'
          ]} 
        />
      </Suspense>
      
      {/* You can mix standard R3F objects */}
      <mesh position={[2, 0, 0]}>
        <boxGeometry />
        <meshStandardMaterial color="orange" />
      </mesh>
    </>
  )
}
```

## 5. Important Considerations

### Path Resolution
Ensure your `modelPaths` are accessible from your public directory (e.g., in Vite, put them in `/public/models`).

### Dependencies
Make sure you have installed the necessary dependencies that Visionary relies on:
```bash
npm install gl-matrix onnxruntime-web
```
And any other deps listed in Visionary's `package.json`.

### TypeScript Configuration
If you are using TypeScript, you may need to update your `tsconfig.json` to handle the imports and WebGPU types.

### Performance
Since Visionary uses WebGPU, it is highly performant. However, mixing heavy standard Three.js rendering with heavy Gaussian Splatting can still tax the GPU. Use the `PerformanceMonitor` from `@react-three/drei` to manage quality if needed.
