// 开启 f16 扩展
// enable f16;
const KERNEL_SIZE:f32 = 0.3; // 2D 投影时的低通滤波器大小，防止过小的高斯产生走样

// 可以被外部注入覆盖的常量
override SH_LAYOUT_CHANNEL_MAJOR : bool = false; // SH 系数布局：true=Channel Major, false=Interleaved
override USE_RAW_COLOR : bool = false;           // 是否直接使用预计算的 RGB 颜色（不进行 SH 计算）

// 球谐系数常量 (Spherical Harmonics Constants)
const SH_C0:f32 = 0.28209479177387814;
const SH_C1 = 0.4886025119029199;
const SH_C2 = array<f32,5>(
    1.0925484305920792,
    -1.0925484305920792,
    0.31539156525252005,
    -1.0925484305920792,
    0.5462742152960396
);
const SH_C3 = array<f32,7>(
    -0.5900435899266435,
    2.890611442640554,
    -0.4570457994644658,
    0.3731763325901154,
    -0.4570457994644658,
    1.445305721320277,
    -0.5900435899266435
);

// 相机 Uniform 数据
struct CameraUniforms {
    view: mat4x4<f32>,      // 视图矩阵 (World -> Camera)
    view_inv: mat4x4<f32>,  // 视图逆矩阵 (Camera -> World)
    proj: mat4x4<f32>,      // 投影矩阵 (Camera -> Clip)
    proj_inv: mat4x4<f32>,  // 投影逆矩阵 (Clip -> Camera)
    
    viewport: vec2<f32>,    // 视口尺寸 (width, height)
    focal: vec2<f32>        // 焦距 (fx, fy)
};

struct Gaussian {
    pos_opacity: array<u32,2>,
    cov: array<u32,3>
}

// 2D Splat 输出结构 (对应 gaussian.wgsl 的输入)
struct Splat {
     // 4x f16 打包成 u32 (v1, v2)
    v_0: u32, v_1: u32,
    // 2x f16 打包成 u32 (NDC x,y)
    pos: u32,
    // NDC z (高精度 f32)
    posz: f32,
    // rgba 打包成 f16
    color_0: u32,color_1: u32
};

// 间接绘制参数结构体
struct DrawIndirect {
    vertex_count: u32,    // 顶点数 (总是 4)
    instance_count: atomic<u32>, // 实例数 (可见的高斯数量，由 GPU 原子操作计数)
    base_vertex: u32,
    base_instance: u32,
}

// 间接调度参数结构体 (用于排序)
struct DispatchIndirect {
    dispatch_x: atomic<u32>, // 工作组数量 X
    dispatch_y: u32,
    dispatch_z: u32,
}

// 排序信息结构体
struct SortInfos {
    keys_size: atomic<u32>,     // 需要排序的键数量 (等于可见高斯数)
    padded_size: u32,           // 填充后的大小 (用于 Radix Sort 对齐)
    passes: u32,                // 排序趟数
    even_pass: u32,             // 偶数趟标志
    odd_pass: u32,              // 奇数趟标志
}

// 渲染设置
struct RenderSettings {
    clipping_box_min: vec4<f32>, // 场景裁剪包围盒最小点
    clipping_box_max: vec4<f32>, // 场景裁剪包围盒最大点
    max_sh_deg: u32,             // 最大 SH 阶数 (0-3)
    show_env_map: u32,           // 是否显示环境贴图 (未使用)
    mip_spatting: u32,           // 是否启用 Mip-Splatting 抗锯齿
    kernel_size: f32,            // 低通滤波器核大小
    walltime: f32,               // 运行时间
    scene_extend: f32,           // 场景范围扩展
    center: vec3<f32>,           // 场景中心
}

override DISCARD_BY_WORLD_TRACE   : bool = false;  // 可选：基于世界空间协方差迹的剔除
override MAX_WORLD_TRACE          : f32  = 0.25;   // 协方差迹上限

@group(0) @binding(0)
var<uniform> camera: CameraUniforms;

// 共享高斯数据 buffer - 根据 gaussDataType 解释为不同类型
@group(1) @binding(0) 
var<storage,read> gaussians_packed : array<u32>; // 原始高斯数据 (位置, 缩放, 旋转/协方差, 不透明度)

@group(1) @binding(1)
var<storage, read> color_buffer : array<u32>; // 颜色或 SH 系数数据

@group(1) @binding(2) 
var<storage,read_write> points_2d : array<Splat>; // 输出的 2D Splat 数据

@group(2) @binding(0)
var<storage, read_write> sort_infos: SortInfos;
@group(2) @binding(1)
var<storage, read_write> sort_depths : array<u32>;  // 排序键值 (深度)
@group(2) @binding(2)
var<storage, read_write> sort_indices : array<u32>; // 排序索引 (Payload)
@group(2) @binding(3)
var<storage, read_write> sort_dispatch: DispatchIndirect;

@group(3) @binding(0)
var<uniform> render_settings: RenderSettings;

// 模型参数 (支持多模型渲染)
struct ModelParams {
    model: mat4x4<f32>,   // 模型矩阵 (Local -> World)
    baseOffset: u32,      // 全局 Buffer 中的起始偏移
    num_points: u32,      // 该模型的点数量
    gaussianScaling: f32, // 高斯缩放因子
    maxShDeg: u32,        // 球谐等级
    kernelSize: f32,      // 核大小
    opacityScale: f32,    // 透明度缩放
    cutoffScale: f32,     // 截断缩放
    rendermode: u32,      // 渲染模式: 0=颜色, 1=法线, 2=深度
    // 多精度支持配置
    gaussDataType: u32,   // 0=f32, 1=f16, 2=i8, 3=u8
    colorDataType: u32,   // 颜色数据类型
    gaussScale: f32,      // 量化缩放因子
    gaussZeroPoint: f32,  // 量化零点
    colorScale: f32,      // 颜色量化缩放
    colorZeroPoint: f32,  // 颜色量化零点
}

@group(3) @binding(1)
var<uniform> uModel: ModelParams;

// --- 辅助函数：根据精度读取高斯位置和不透明度 ---
fn read_gaussian_pos_opacity(idx: u32) -> vec4<f32> {
  if (uModel.gaussDataType == 0u) {
    // FP32: 4 个连续的 f32
    let base = idx * 10u;
    return vec4<f32>(
      bitcast<f32>(gaussians_packed[base + 0u]),
      bitcast<f32>(gaussians_packed[base + 1u]),
      bitcast<f32>(gaussians_packed[base + 2u]),
      bitcast<f32>(gaussians_packed[base + 3u])
    );
  } else {
    // FP16: 打包在 2 个 u32 中 (pos_xy + pos_z_opacity)
    let w0 = gaussians_packed[idx * 5u + 0u];
    let w1 = gaussians_packed[idx * 5u + 1u];
    let a = unpack2x16float(w0);
    let b = unpack2x16float(w1);
    return vec4<f32>(a.x, a.y, b.x, b.y);
  }
}

// --- 辅助函数：根据精度读取高斯协方差 (6 个 float) ---
fn read_gaussian_cov(idx: u32) -> array<f32,6> {
  if (uModel.gaussDataType == 0u) {
    // FP32: 从 idx*10+4 开始的 6 个 f32
    let base = idx * 10u + 4u;
    return array<f32,6>(
      bitcast<f32>(gaussians_packed[base + 0u]),
      bitcast<f32>(gaussians_packed[base + 1u]),
      bitcast<f32>(gaussians_packed[base + 2u]),
      bitcast<f32>(gaussians_packed[base + 3u]),
      bitcast<f32>(gaussians_packed[base + 4u]),
      bitcast<f32>(gaussians_packed[base + 5u])
    );
  } else {
    // FP16: 打包在 3 个 u32 中
    let a = unpack2x16float(gaussians_packed[idx * 5u + 2u]);
    let b = unpack2x16float(gaussians_packed[idx * 5u + 3u]);
    let c = unpack2x16float(gaussians_packed[idx * 5u + 4u]);
    return array<f32,6>(a.x, a.y, b.x, b.y, c.x, c.y);
  }
}

// ---- 辅助函数：计算颜色数据的起始 word 下标 ----
fn base_word_of(splat_idx: u32) -> u32 {
    if (USE_RAW_COLOR) {
        // RGB 直接颜色：每点的存储字数取决于颜色精度
        if (uModel.colorDataType == 0u) { // fp32: 3 words
            return splat_idx * 3u;
        } else if (uModel.colorDataType == 1u) { // fp16: 2 words (4 halfs)
            return splat_idx * 2u;
        } else { // int8/uint8: 1 word (4 bytes)
            return splat_idx * 1u;
        }
    }
    // SH：按精度和通道数计算
    if (uModel.colorDataType == 0u) {
      // FP32: 48 channels (degree 3) = 48 words
      return splat_idx * 48u;
    } else {
      // FP16: 48 channels = 48 halfs = 24 words
      return splat_idx * 24u;
    }
}

// 读第 word_idx 个 u32
fn read_word(splat_idx: u32, word_idx: u32) -> u32 {
  return color_buffer[base_word_of(splat_idx) + word_idx];
}

// ===== 读半精“标量”：线性 half 下标（0,1,2,3, ...）=====
fn read_half_at(splat_idx: u32, half_idx: u32) -> f32 {
  let w = read_word(splat_idx, half_idx >> 1u);
  let p = unpack2x16float(w);                 // vec2<f32>，低/高 half
  // 如果 half_idx 是奇数取高位，否则取低位
  return select(p.x, p.y, (half_idx & 1u) == 1u);
}

// ===== 连续颜色：直接读取前三个 half 作为最终 RGB =====
// 读取颜色分量（依据数据类型）
fn read_color_channel(splat_idx: u32, channel_idx: u32) -> f32 {
  if (uModel.colorDataType == 0u) {
    // fp32：每通道 1 word
    let w = read_word(splat_idx, channel_idx);
    return bitcast<f32>(w);
  } else if (uModel.colorDataType == 1u) {
    // fp16：按 half 读取
    return read_half_at(splat_idx, channel_idx);
  } else {
    // int8/uint8：从 word 中提取 8-bit，然后反量化
    let packed = read_word(splat_idx, channel_idx >> 2u);
    let byte_off = (channel_idx & 3u) * 8u;
    let q = extractBits(i32(packed), byte_off, 8u);
    return f32(q) * uModel.colorScale + uModel.colorZeroPoint;
  }
}

// 读取直接 RGB 颜色 (非 SH)
fn fetch_rgb_no_sh(splat_idx: u32) -> vec3<f32> {
  return vec3<f32>(
    read_color_channel(splat_idx, 0u),
    read_color_channel(splat_idx, 1u),
    read_color_channel(splat_idx, 2u)
  );
}

// 读取 SH 系数 (Interleaved 布局)
fn sh_coef_interleaved(splat_idx: u32, c_idx: u32) -> vec3<f32> {
  // c_idx ∈ [0 .. (deg+1)^2-1]，每个系数 3 个 half 连着
  let h0 = c_idx * 3u;
  return vec3<f32>(
    read_color_channel(splat_idx, h0 + 0u),
    read_color_channel(splat_idx, h0 + 1u),
    read_color_channel(splat_idx, h0 + 2u)
  );
}

// 读取 SH 系数 (Channel Major 布局)
fn sh_coef_channel_major(splat_idx: u32, c_idx: u32) -> vec3<f32> {
  if (c_idx == 0u) {
    // DC (直流分量) 总是连续存储
    return vec3<f32>(
      read_color_channel(splat_idx, 0u),
      read_color_channel(splat_idx, 1u),
      read_color_channel(splat_idx, 2u)
    );
  }
  // AC (交流分量)
  let m  = (uModel.maxShDeg + 1u) * (uModel.maxShDeg + 1u) - 1u; // 每通道 AC 数
  let k  = c_idx - 1u;                   // 第 k 个 AC，k ∈ [0..m-1]
  let r  = read_color_channel(splat_idx, 3u + k);
  let g  = read_color_channel(splat_idx, 3u + m + k);
  let b  = read_color_channel(splat_idx, 3u + 2u*m + k);
  return vec3<f32>(r, g, b);
}

// 统一 SH 读取入口：根据布局选择
fn sh_coef(splat_idx: u32, c_idx: u32) -> vec3<f32> {
  return select(
    sh_coef_interleaved(splat_idx, c_idx),
    sh_coef_channel_major(splat_idx, c_idx),
    SH_LAYOUT_CHANNEL_MAJOR
  );
}

// 计算 SH 颜色
fn evaluate_sh(dir: vec3<f32>, v_idx: u32, sh_deg: u32) -> vec3<f32> {
    var result = SH_C0 * sh_coef(v_idx, 0u) ; // DC 分量
    // sh_deg = 0;
    if sh_deg > 0u {

        let x = dir.x;
        let y = dir.y;
        let z = dir.z;

        // 1 阶 SH
        result += - SH_C1 * y * sh_coef(v_idx, 1u) + SH_C1 * z * sh_coef(v_idx, 2u) - SH_C1 * x * sh_coef(v_idx, 3u);

        if sh_deg > 1u {
             // 2 阶 SH
            let xx = dir.x * dir.x;
            let yy = dir.y * dir.y;
            let zz = dir.z * dir.z;
            let xy = dir.x * dir.y;
            let yz = dir.y * dir.z;
            let xz = dir.x * dir.z;

            result += SH_C2[0] * xy * sh_coef(v_idx, 4u) + SH_C2[1] * yz * sh_coef(v_idx, 5u) + SH_C2[2] * (2.0 * zz - xx - yy) * sh_coef(v_idx, 6u) + SH_C2[3] * xz * sh_coef(v_idx, 7u) + SH_C2[4] * (xx - yy) * sh_coef(v_idx, 8u);

            if sh_deg > 2u {
                // 3 阶 SH
                result += SH_C3[0] * y * (3.0 * xx - yy) * sh_coef(v_idx, 9u) + SH_C3[1] * xy * z * sh_coef(v_idx, 10u) + SH_C3[2] * y * (4.0 * zz - xx - yy) * sh_coef(v_idx, 11u) + SH_C3[3] * z * (2.0 * zz - 3.0 * xx - 3.0 * yy) * sh_coef(v_idx, 12u) + SH_C3[4] * x * (4.0 * zz - xx - yy) * sh_coef(v_idx, 13u) + SH_C3[5] * z * (xx - yy) * sh_coef(v_idx, 14u) + SH_C3[6] * x * (xx - 3.0 * yy) * sh_coef(v_idx, 15u);
            }
        }
    }
    result += 0.5; // 加上 0.5 的偏移 (因为 SH 系数通常以 0 为中心)

    return result;
}

// 计算最终颜色入口
fn evaluate_color(dir: vec3<f32>, v_idx: u32, sh_deg: u32) -> vec3<f32> {
    if (USE_RAW_COLOR) {
        // 直接颜色（0..1），不做 +0.5
        return fetch_rgb_no_sh(v_idx);
    } else {
        // 球谐路径：evaluate_sh 已经在最后加了 0.5
        return evaluate_sh(dir, v_idx, sh_deg);
    }
}

// 读取协方差系数
fn cov_coefs(v_idx: u32) -> array<f32,6> {
    return read_gaussian_cov(v_idx);
}

// 辅助：计算对称矩阵的逆
fn inverse_sym3(m: mat3x3<f32>) -> mat3x3<f32> {
    // m = [[a,b,c],[b,d,e],[c,e,f]]
    let a = m[0][0]; let b = m[0][1]; let c = m[0][2];
    let d = m[1][1]; let e = m[1][2];
    let f = m[2][2];

    let co00 = d*f - e*e;
    let co01 = c*e - b*f;
    let co02 = b*e - c*d;
    let co11 = a*f - c*c;
    let co12 = c*b - a*e;
    let co22 = a*d - b*b;

    let det = a*co00 + b*co01 + c*co02;
    let eps = 1e-12;
    let inv_det = select(1.0/det, 1.0/eps, abs(det) < eps);

    // 对称：只需填上三角
    var inv = mat3x3<f32>(
        vec3<f32>(co00, co01, co02),
        vec3<f32>(co01, co11, co12),
        vec3<f32>(co02, co12, co22)
    );
    return inv * inv_det;
}

// 通过幂迭代法求最小特征向量 (用于法线估计)
fn smallest_evec_via_power(Sigma_world: mat3x3<f32>) -> vec3<f32> {
    let invS = inverse_sym3(Sigma_world);
    // 选个稳定的初始向量（取列和可以避免退化）
    var v = normalize(invS[0] + invS[1] + invS[2]);
    // 少量迭代即可（3~5 次）
    v = normalize(invS * v);
    v = normalize(invS * v);
    v = normalize(invS * v);
    return v; // 未定向，之后可按相机翻转
}

// 视点相关的法线计算 (可选，未使用)
fn normal_view_dependent(Sigma_world: mat3x3<f32>, cam_world: vec3<f32>, x_world: vec3<f32>) -> vec3<f32> {
    let v = normalize(cam_world - x_world);                // 从点指向相机
    let invS = inverse_sym3(Sigma_world);
    var n = normalize(invS * v);                           // ∝ Σ^{-1} v
    // 使法线朝向相机（可选）
    if (dot(n, v) < 0.0) { n = -n; }
    return n;
}

// --- 计算着色器主函数 ---
@compute @workgroup_size(256,1,1)
fn preprocess(@builtin(global_invocation_id) gid: vec3<u32>, @builtin(num_workgroups) wgs: vec3<u32>) {
    let idx = gid.x;
    
    // 使用 ONNX 动态点数进行边界检查
    if idx >= uModel.num_points  {
   //     return;
    }
    // 调试用硬限制
    if idx > 500000  {
       // return;
    }
    
    let focal = camera.focal;
    let viewport = camera.viewport;
    
    // 1. 读取高斯位置和不透明度
    let pos_op = read_gaussian_pos_opacity(idx);
    let xyz_local = pos_op.xyz;
    
    // 2. 应用模型矩阵变换到世界空间
    let xyz = (uModel.model * vec4<f32>(xyz_local, 1.)).xyz;
    var opacity = pos_op.w * uModel.opacityScale;

    // 3. 变换到相机空间
    var camspace = camera.view * vec4<f32>(xyz, 1.);
    let pos2d = camera.proj * camspace;
    let bounds = 1.2 * pos2d.w;
    let z = pos2d.z / pos2d.w;

    // 4. 更新 indirect dispatch buffer (仅第一个线程执行)
    if uModel.baseOffset == 0u && idx == 0u {
        atomicAdd(&sort_dispatch.dispatch_x, 1u);   // 增加一个安全块，确保即使数据未填满也有足够的 dispatch
    }

    // 5. 简单的视锥体剔除 (Frustum Culling)
    // 检查是否在 NDC 范围内
    if z <= 0. || z >= 1. || pos2d.x < -bounds || pos2d.x > bounds || pos2d.y < -bounds || pos2d.y > bounds { return; }

    // 6. 不透明度剔除
    if (opacity < 0.02) {
        return;
    }
    if (opacity > 0.98) {
      //  return; // 可选：剔除完全不透明物体 (通常不建议)
    }

    // 7. 读取并计算协方差矩阵
    let cov_sparse = cov_coefs(idx);
    var scale_mod = 1.0;
    let scaling = uModel.gaussianScaling * scale_mod * 1.0f;

    // --- 7.1) 构建局部协方差矩阵
    let Sigma_local = mat3x3<f32>(
        cov_sparse[0], cov_sparse[1], cov_sparse[2],
        cov_sparse[1], cov_sparse[3], cov_sparse[4],
        cov_sparse[2], cov_sparse[4], cov_sparse[5]
    ) * scaling * scaling;

    // --- 7.2) 变换到世界空间: Σ_world = R * Σ_local * R^T
    // 使用模型矩阵的线性部分 (旋转+缩放)
    let A = mat3x3<f32>(
        uModel.model[0].xyz,  // 第0列
        uModel.model[1].xyz,  // 第1列
        uModel.model[2].xyz   // 第2列
    );
    let Sigma_world = A * Sigma_local * transpose(A);

    // --- 7.3) 投影到 2D 屏幕空间 (EWA Splatting)
    // J 是透视投影的雅可比矩阵 (Clip -> Screen)
    let J = mat3x3<f32>(
        focal.x / camspace.z,  0.0,                         -(focal.x * camspace.x) / (camspace.z * camspace.z),
        0.0,                  -focal.y / camspace.z,        (focal.y * camspace.y) / (camspace.z * camspace.z),
        0.0,                   0.0,                          0.0
    );

    // W 是视图矩阵的旋转部分 (World -> Camera)
    let W = transpose(mat3x3<f32>(
        camera.view[0].xyz,
        camera.view[1].xyz,
        camera.view[2].xyz
    ));

    // T = J * W
    let T   = W * J;
    
    // Σ_prime = T * Σ_world * T^T
    // 这是 2D 屏幕空间的协方差矩阵
    let cov = transpose(T) * Sigma_world * T;

    // 可选：过滤掉极端拉伸的高斯
    if (true) {
        let world_trace = Sigma_local[0][0] + Sigma_local[1][1] + Sigma_local[2][2];
        if (world_trace > 1000.0000002) {
            //return;
        }
    }

    // 8. 应用低通滤波器 (Kernel Size) 和 Mip-Splatting
    let kernel_size = uModel.kernelSize;
    if bool(render_settings.mip_spatting) {
        // Mip-Splatting 技术：根据覆盖面积调整不透明度，防止走样
        let det_0 = max(1e-6, cov[0][0] * cov[1][1] - cov[0][1] * cov[0][1]);
        let det_1 = max(1e-6, (cov[0][0] + kernel_size) * (cov[1][1] + kernel_size) - cov[0][1] * cov[0][1]);
        var coef = sqrt(det_0 / (det_1 + 1e-6) + 1e-6);

        if det_0 <= 1e-6 || det_1 <= 1e-6 {
            coef = 0.0;
        }
        opacity *= coef;
    }

    // 将低通滤波器应用到协方差对角线上
    let diagonal1 = cov[0][0] + kernel_size;
    let offDiagonal = cov[0][1];
    let diagonal2 = cov[1][1] + kernel_size;

    // 9. 计算 2D 特征值和特征向量 (用于确定椭圆的轴长和方向)
    let mid = 0.5 * (diagonal1 + diagonal2);
    let radius = length(vec2<f32>((diagonal1 - diagonal2) / 2.0, offDiagonal));
    let lambda1 = mid + radius;
    let lambda2 = max(mid - radius, 0.1);

    let diagonalVector = normalize(vec2<f32>(offDiagonal, lambda1 - diagonal1));
    
    // 计算屏幕空间的两个主轴向量 (v1, v2)，缩放 3 倍 sigma (cutoffScale)
    let v1 = sqrt(2.0 * lambda1) * diagonalVector * uModel.cutoffScale;
    let v2 = sqrt(2.0 * lambda2) * vec2<f32>(diagonalVector.y, -diagonalVector.x) * uModel.cutoffScale;

    let v_center = pos2d.xyzw / pos2d.w;

    // 10. 计算颜色 (SH 或 调试模式)
    let t = uModel.model[3].xyz;
    let cam_world = camera.view_inv[3].xyz;

    // --- 计算模型缩放 s^2 (假设各向同性缩放近似)
    let s2 = max(
        1e-12,
        (dot(A[0], A[0]) + dot(A[1], A[1]) + dot(A[2], A[2])) / 3.0
    );

    // --- 将相机位置变换到局部空间，以便计算 SH
    let cam_local = (transpose(A) * (cam_world - t)) / s2;

    // --- 计算局部视线方向
    let dir_local = normalize(xyz_local - cam_local);

    var color: vec4<f32>;
    
    // 11. 分配全局索引 (用于排序)
    // 使用原子操作获取当前可见点的唯一索引
    let store_idx = atomicAdd(&sort_infos.keys_size, 1u);
    let global_index = store_idx;
    
    // 根据渲染模式计算颜色
    if (uModel.rendermode == 0u) {
        // 模式0: 正常颜色 (SH 计算或直接 RGB)
        color = vec4<f32>(
            max(vec3<f32>(0.), evaluate_color(dir_local, idx, uModel.maxShDeg)),
            opacity
        );
    } else if (uModel.rendermode == 1u) {
        // 模式1: 法线可视化 (使用协方差矩阵的最小特征向量作为法线)
        var n_world = smallest_evec_via_power(Sigma_world);

        // 选最大幅值分量的符号作为锚点，保证符号在不同视角下保持一致
        let abs_n = abs(n_world);
        if (abs_n.x >= abs_n.y && abs_n.x >= abs_n.z) {
            if (n_world.x < 0.0) { n_world = -n_world; }
        } else if (abs_n.y >= abs_n.z) {
            if (n_world.y < 0.0) { n_world = -n_world; }
        } else {
            if (n_world.z < 0.0) { n_world = -n_world; }
        }

        // 归一化
        let n_len = length(n_world);
        if (n_len < 1e-8) {
            n_world = vec3<f32>(0.0, 0.0, 1.0);
        } else {
            n_world = n_world / n_len;
        }

        // 映射到 [0, 1] 颜色
        let n_rgb = clamp(0.5 * (n_world + vec3<f32>(1.0, 1.0, 1.0)), vec3<f32>(0.0), vec3<f32>(1.0));
        color = vec4<f32>(n_rgb, opacity);
    } else if (uModel.rendermode == 2u) {
        // 模式2: 深度可视化 (0..1)
        let depth_ndc = 1.0 - clamp(pos2d.z / pos2d.w, 0.0, 1.0);
        color = vec4<f32>(depth_ndc, depth_ndc, depth_ndc, opacity);
    } else {
        // 默认: 正常颜色
        color = vec4<f32>(
            max(vec3<f32>(0.), evaluate_color(dir_local, idx, uModel.maxShDeg)),
            1
        );
    }

    // 12. 写入 2D Splat 数据 (压缩为 f16)
    let v = vec4<f32>(v1 / viewport, v2 / viewport);
    points_2d[store_idx] = Splat(
        pack2x16float(v.xy), pack2x16float(v.zw),
        pack2x16float(v_center.xy),
        v_center.z,
        pack2x16float(color.rg), pack2x16float(color.ba),
    );
    
    // 13. 写入排序键值 (深度) 和 索引
    // 深度值取反并转为 u32，以便 Radix Sort 进行从远到近排序
    let znear = -camera.proj[3][2] / camera.proj[2][2];
    let zfar = -camera.proj[3][2] / (camera.proj[2][2] - (1.));
    sort_depths[store_idx] = bitcast<u32>(zfar - pos2d.z); 
    sort_indices[store_idx] = store_idx;

    // 14. 更新排序的 dispatch 参数
    // 每 256 * 15 个键需要一个工作组 (Radix Sort 的配置)
    let keys_per_wg = 256u * 15u;         
    if (global_index % keys_per_wg) == 0u {
        atomicAdd(&sort_dispatch.dispatch_x, 1u);
    }
}
