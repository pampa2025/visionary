# Visionary Renderer Deep Dive

This guide provides a technical deep dive into the rendering engine of Visionary. It explains the architecture of the WebGPU renderer, the shader pipeline, and the high-performance GPU sorting mechanism used to render millions of Gaussian splats in real-time.

## 1. Renderer Architecture Overview

The core renderer is implemented in `src/renderer/gaussian_renderer.ts`. It follows a **hybrid compute-rasterization** pipeline:

1.  **Preprocess (Compute)**: Culls invisible splats, computes depth, and generates sorting keys.
2.  **Sort (Compute)**: Sorts all visible splats by depth (back-to-front) using a parallel Radix Sort.
3.  **Rasterize (Render)**: Draws the sorted splats using hardware instancing and indirect drawing.

### Key Class: `GaussianRenderer`

The `GaussianRenderer` class orchestrates the entire pipeline. It manages:

- **GPU Resources**: Pipelines, bind groups, and global buffers.
- **Sub-systems**:
  - `GPURSSorter`: Handles the GPU-based sorting.
  - `GaussianPreprocessor`: Handles the projection and culling of Gaussians before sorting.
- **Memory Management**: Implements a "Global Buffer" strategy (`globalBuffers`) to allocate a massive shared GPU memory pool. This avoids expensive per-frame buffer re-allocation when switching between models or handling dynamic scene updates.

## 2. The Rendering Pipeline

### Phase A: Preprocessing (Compute Shader)

Before rendering, we must determine which Gaussians are visible and what their depth is relative to the camera.

- **Input**: Raw Gaussian data (Position, Rotation, Scale, Opacity, SH/Color).
- **Operation**:
  1.  Transform Gaussian center to View Space.
  2.  Check if it is inside the camera frustum (Frustum Culling).
  3.  Compute the sorting key (usually linear depth mapped to a `u32` integer).
  4.  Write the sorting key and the original index (payload) to a buffer.
- **Output**: An unsorted list of `(key, payload)` pairs.

### Phase B: GPU Radix Sort (Compute Shader)

Gaussian Splatting relies on strict back-to-front alpha blending. We use a **LSD (Least Significant Digit) Radix Sort** implemented entirely on the GPU.

**Source**: `src/sort/radix_sort.ts` & `src/shaders/radix_sort.wgsl`

The sort consists of 4 passes (for 32-bit keys, 8 bits per pass). Each pass has three stages:

1.  **Histogram**: Counts the occurrences of each radix (0-255) in the current chunk.
2.  **Prefix Sum**: Computes the global offsets for each radix.
3.  **Scatter**: Moves the keys and payloads to their new sorted positions based on the offsets.

_Optimization Note_: The sorter dynamically attempts to find the optimal **Subgroup Size** (16, 32, etc.) supported by the user's GPU during initialization to maximize parallelism.

### Phase C: Rasterization (Vertex & Fragment Shaders)

Once sorted, we draw the splats using **Indirect Drawing** (`drawIndirect`). This allows the GPU to determine the number of vertices to draw without CPU intervention.

**Source**: `src/shaders/gaussian.wgsl`

#### Vertex Shader (`vs_main`)

The vertex shader is responsible for "splatting" the 3D Gaussian into a 2D screen-space billboard (quad).

1.  **Data Fetch**: Reads the Gaussian parameters using the sorted index.
2.  **Projection**:
    - Projects the 3D covariance matrix into 2D screen space.
    - Computes the major/minor axes of the 2D ellipse.
3.  **Quad Generation**: Expands the vertex (0-3) into a quad covering the 2D ellipse (usually $\pm 3\sigma$).
4.  **Color Calculation**:
    - If using Spherical Harmonics (SH), it evaluates the SH coefficients based on the view direction.
    - Unpacks compressed color formats (FP16, RGB565) if necessary.

#### Fragment Shader (`fs_main`)

The fragment shader computes the alpha falloff for the Gaussian.

1.  **Gaussian Falloff**: Calculates the distance from the center of the splat in screen space.
    $$ \alpha' = \alpha \times e^{-(x^2 + y^2)} $$
2.  **Discard**: If the alpha is too low (outside the splat radius), the fragment is discarded.
3.  **Blending**: The GPU's fixed-function blender handles the accumulation of color (`src_alpha`, `one_minus_src_alpha`).

## 3. Data Formats & Compression

Visionary supports multiple data precisions to balance quality and bandwidth:

- **FP32 (Standard)**: High precision, large memory usage.
- **FP16 (Half)**: Standard for web rendering. Positions and colors are packed into `vec2<f16>` (stored as `u32`).
- **Quantized (Int8/Uint8)**: For experimental high-compression formats.

The shader uses helper functions like `unpack2x16float` to decode these formats on the fly.

## 4. Render Loop & Multi-Model Support

The renderer supports rendering multiple point clouds in a single pass (`renderMulti`).

1.  **Batching**: It calculates the total number of points across all models.
2.  **Global Sorting**: It performs a single global sort for _all_ models combined. This is crucial for correct transparency when multiple models overlap.
3.  **Unified Draw**: A single indirect draw call renders the entire scene, maximizing GPU throughput.

## 5. WebGPU Specifics

- **Indirect Dispatch/Draw**: Almost all commands use indirect buffers. This means the CPU doesn't know how many points are visible; the GPU counts them and writes the count to a buffer, which is then used as the argument for the next draw call.
- **Storage Buffers**: Data is stored in `read-only` storage buffers (`var<storage, read>`) for random access in the vertex shader, rather than using traditional Vertex Buffers.

---

### Further Reading

- **3D Gaussian Splatting Paper**: Kerbl et al. (SIGGRAPH 2023)
- **WebGPU Specification**: W3C
