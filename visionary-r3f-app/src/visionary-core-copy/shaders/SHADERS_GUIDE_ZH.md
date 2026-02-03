# Visionary Shader 教程

本文档详细介绍了 Visionary 项目中核心 WGSL 着色器的功能、原理和实现细节。这些着色器共同构成了一个基于 WebGPU 的高性能 3D Gaussian Splatting 渲染管线。

## 目录

1. [概览](#1-概览)
2. [核心渲染管线](#2-核心渲染管线)
   - [preprocess.wgsl (预处理)](#preprocesswgsl)
   - [radix_sort.wgsl (排序)](#radix_sortwgsl)
   - [gaussian.wgsl (光栅化)](#gaussianwgsl)
3. [辅助工具](#3-辅助工具)
   - [compress_gaussians.wgsl (数据压缩)](#compress_gaussianswgsl)
   - [convert_precision.wgsl (精度转换)](#convert_precisionwgsl)

---

## 1. 概览

Visionary 的渲染管线采用了混合计算 (Compute) 和图形 (Graphics) 的方式。为了处理数百万个半透明的高斯球体，必须对它们进行严格的从后到前 (Back-to-Front) 排序。传统的 CPU 排序无法满足实时性要求，因此本项目实现了一套完整的 GPU 排序管线。

**数据流向：**
1. **Raw Data** (CPU/ONNX) -> **GPU Buffers**
2. **Preprocess** (Compute): 计算可见性、投影、生成排序键值。
3. **Sort** (Compute): 使用 Radix Sort 对键值进行排序。
4. **Rasterize** (Vertex/Fragment): 根据排序后的索引绘制高斯球体。

---

## 2. 核心渲染管线

### preprocess.wgsl

**功能**：这是渲染管线的第一步。它负责将 3D 高斯数据投影到 2D 屏幕空间，并生成用于排序的键值。

**核心逻辑**：
1. **数据读取**：从全局 Buffer 中读取高斯的位置、缩放、旋转（四元数）和不透明度。
2. **变换**：
   - 将高斯从局部空间变换到世界空间。
   - 将高斯从世界空间变换到相机空间。
3. **剔除 (Culling)**：
   - **视锥体剔除**：检查高斯中心是否在 NDC (Normalized Device Coordinates) 范围内。
   - **透明度剔除**：丢弃 alpha 值过低的高斯。
4. **协方差计算**：
   - 构建局部 3D 协方差矩阵 $\Sigma_{local}$。
   - 变换到世界空间 $\Sigma_{world} = R \Sigma_{local} R^T$。
   - 投影到 2D 屏幕空间 $\Sigma_{2d} = T \Sigma_{world} T^T$ (EWA Splatting)。
5. **特征分解**：
   - 计算 2D 协方差矩阵的特征值和特征向量。
   - 这决定了屏幕上 2D 椭圆的长轴、短轴方向和长度。
6. **颜色计算**：
   - 支持球谐函数 (Spherical Harmonics, SH) 计算，根据视线方向动态计算颜色。
   - 支持调试模式（法线、深度可视化）。
7. **数据写入**：
   - 将 2D 渲染所需的数据（位置、轴向量、颜色）打包写入 `points_2d` 缓冲区。
   - 生成排序键值（通常是线性深度），写入 `sort_depths`。
   - 生成排序索引（Payload），写入 `sort_indices`。

**关键代码片段**：
```wgsl
// 投影到 2D 屏幕空间 (EWA Splatting)
let T = W * J; // J 是投影雅可比矩阵，W 是视图矩阵
let cov = transpose(T) * Sigma_world * T;
```

### radix_sort.wgsl

**功能**：实现了一个高性能的并行 GPU 基数排序 (Radix Sort)。用于对 `preprocess` 生成的深度键值进行排序。

**算法原理**：
使用的是 **LSD (Least Significant Digit) Radix Sort**。对于 32 位整数键值，将其分为 4 个 8 位的 Pass 进行处理。

**每个 Pass 的步骤**：
1. **Histogram (直方图)**：
   - 每个线程块统计自己负责的数据块中，每个基数 (0-255) 出现的次数。
   - 使用共享内存 (Shared Memory) 加速统计。
2. **Prefix Sum (前缀和)**：
   - 对全局直方图进行前缀和扫描 (Scan)。
   - 计算出每个基数在输出数组中的全局起始偏移量。
3. **Scatter (散射)**：
   - 根据前缀和计算出的偏移量，将键值和 Payload 移动到目标位置。
   - 这是最复杂的一步，涉及到 warp/subgroup 级别的并行操作和 Lookback 策略以处理块间的依赖。

**特点**：
- 完全在 GPU 上执行，无需 CPU 回读。
- 使用 Indirect Dispatch，适应动态数量的高斯点。

### gaussian.wgsl

**功能**：负责将排序后的高斯光栅化到屏幕上。

**Vertex Shader (`vs_main`)**：
- **输入**：`vertex_index` (0-3)，`instance_index` (高斯索引)。
- **逻辑**：
  - 从 `indices` 缓冲区读取排序后的高斯索引。
  - 从 `points_2d` 缓冲区读取该高斯的 2D 参数（中心、轴向量、颜色）。
  - 利用轴向量 (v1, v2) 将一个单位四边形变换为覆盖该高斯的椭圆包围盒。
  - 输出裁剪空间坐标和屏幕空间坐标。

**Fragment Shader (`fs_main`)**：
- **输入**：屏幕空间坐标、颜色。
- **逻辑**：
  - 计算当前像素距离高斯中心的距离平方 $d^2 = x^2 + y^2$。
  - 如果 $d^2 > \text{CUTOFF}$，丢弃像素。
  - 计算 Alpha 衰减：$\alpha' = \alpha \times e^{-d^2}$。
  - 输出最终颜色。

---

## 3. 辅助工具

### compress_gaussians.wgsl

**功能**：将未压缩的训练数据（通常来自 Python 导出的 ONNX 模型）转换为渲染器所需的紧凑格式。

**主要转换**：
- **四元数 -> 协方差**：将旋转四元数和缩放因子转换为 3x3 协方差矩阵的上三角部分。
- **f32 -> f16**：将所有浮点数据打包为 f16（两个 f16 存入一个 u32），以减少显存带宽占用。
- **SH 系数打包**：将球谐系数重新排列并打包。

### convert_precision.wgsl

**功能**：通用的精度转换工具。

**逻辑**：
- 提供简单的 `f32` 到 `f16` 的并行转换能力。
- 用于在加载某些原始 PLY 文件或非压缩模型时进行预处理。

---

## 调试与开发

- **Render Modes**: 在 `preprocess.wgsl` 中修改 `uModel.rendermode` 可以切换显示模式（颜色、法线、深度）。
- **Culling**: 可以通过调整 `preprocess.wgsl` 中的不透明度阈值或视锥体判断逻辑来优化性能。
- **Sorting**: 如果遇到排序错误（闪烁、深度错误），通常需要检查 `radix_sort.wgsl` 中的 `histogram_wg_size` 等常量是否与宿主代码 (`radix_sort.ts`) 匹配。
