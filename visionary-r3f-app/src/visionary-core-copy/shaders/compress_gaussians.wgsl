// 计算着色器：将未压缩的 ONNX 高斯数据压缩为渲染器期望的格式
// 转换过程：将分离的位置、缩放、旋转、不透明度数组转换为打包的 f16 格式

struct CameraUniforms {
    view: mat4x4<f32>,
    view_inv: mat4x4<f32>,
    proj: mat4x4<f32>,
    proj_inv: mat4x4<f32>,
    viewport: vec2<f32>,
    focal: vec2<f32>
};

// 渲染器期望的压缩格式
struct Gaussian {
    pos_opacity: array<u32,2>,  // 打包的 f16: [x, y, z, opacity]
    cov: array<u32,3>           // 打包的 f16: 协方差矩阵上三角 [m00, m01, m02, m11, m12, m22]
}

struct CompressionUniforms {
    num_points: u32,    // 点的数量
    sh_degree: u32,     // 球谐阶数
    _pad0: u32,
    _pad1: u32,
}

// 输入缓冲区 (未压缩的 ONNX 输出)
@group(0) @binding(0) var<storage, read> uncompressed_positions: array<vec3<f32>>;
@group(0) @binding(1) var<storage, read> uncompressed_scales: array<vec3<f32>>;
@group(0) @binding(2) var<storage, read> uncompressed_rotations: array<vec4<f32>>;  // 四元数
@group(0) @binding(3) var<storage, read> uncompressed_opacities: array<f32>;
@group(0) @binding(4) var<storage, read> uncompressed_sh_dc: array<vec3<f32>>;     // RGB DC 系数
@group(0) @binding(5) var<storage, read> uncompressed_sh_rest: array<f32>;        // 高阶 SH 系数 (可选)

// 输出缓冲区 (压缩格式)
@group(1) @binding(0) var<storage, read_write> compressed_gaussians: array<Gaussian>;
@group(1) @binding(1) var<storage, read_write> compressed_sh: array<array<u32,24>>; // 打包的 SH 系数

// Uniforms
@group(2) @binding(0) var<uniform> compression_uniforms: CompressionUniforms;

/**
 * 将四元数转换为 3x3 旋转矩阵
 * 输入: 四元数 [w, x, y, z] (归一化)
 * 输出: 3x3 旋转矩阵
 */
fn quaternion_to_rotation_matrix(q: vec4<f32>) -> mat3x3<f32> {
    let w = q.x;  // w 分量
    let x = q.y;  // x 分量  
    let y = q.z;  // y 分量
    let z = q.w;  // z 分量
    
    // 归一化四元数
    let norm = sqrt(w*w + x*x + y*y + z*z);
    let nq = q / norm;
    let nw = nq.x;
    let nx = nq.y;
    let ny = nq.z;
    let nz = nq.w;
    
    // 转换为旋转矩阵
    return mat3x3<f32>(
        // 第 0 列
        vec3<f32>(
            1.0 - 2.0 * (ny*ny + nz*nz),
            2.0 * (nx*ny + nw*nz),
            2.0 * (nx*nz - nw*ny)
        ),
        // 第 1 列
        vec3<f32>(
            2.0 * (nx*ny - nw*nz),
            1.0 - 2.0 * (nx*nx + nz*nz),
            2.0 * (ny*nz + nw*nx)
        ),
        // 第 2 列
        vec3<f32>(
            2.0 * (nx*nz + nw*ny),
            2.0 * (ny*nz - nw*nx),
            1.0 - 2.0 * (nx*nx + ny*ny)
        )
    );
}

/**
 * 将缩放和旋转转换为协方差矩阵
 * 缩放: 3D 缩放因子 [sx, sy, sz]
 * 旋转: 四元数 [w, x, y, z]
 * 输出: 3x3 协方差矩阵
 */
fn compute_covariance_matrix(scale: vec3<f32>, rotation: vec4<f32>) -> mat3x3<f32> {
    // 创建缩放矩阵
    let S = mat3x3<f32>(
        vec3<f32>(scale.x, 0.0, 0.0),
        vec3<f32>(0.0, scale.y, 0.0),
        vec3<f32>(0.0, 0.0, scale.z)
    );
    
    // 获取旋转矩阵
    let R = quaternion_to_rotation_matrix(rotation);
    
    // 计算协方差: C = R * S * S^T * R^T
    let RS = R * S;
    return RS * transpose(RS);
}

/**
 * 将 f32 转换为 f16 位 (简化版)
 */
fn f32_to_f16_bits(value: f32) -> u32 {
    let f32_bits = bitcast<u32>(value);
    let sign = (f32_bits >> 31u) & 1u;
    let exponent = ((f32_bits >> 23u) & 0xFFu);
    let mantissa = f32_bits & 0x7FFFFFu;
    
    // 处理特殊情况
    if (exponent == 0u) {
        return sign << 15u; // 零或非规格化数 -> 零
    }
    if (exponent == 0xFFu) {
        return (sign << 15u) | 0x7C00u | (mantissa >> 13u); // 无穷大或 NaN
    }
    
    // 将指数从 f32 范围转换到 f16 范围
    let new_exp = i32(exponent) - 127 + 15;
    if (new_exp <= 0) {
        return sign << 15u; // 下溢 -> 零
    }
    if (new_exp >= 31) {
        return (sign << 15u) | 0x7C00u; // 上溢 -> 无穷大
    }
    
    // 打包 f16: 符号(1) + 指数(5) + 尾数(10)
    return (sign << 15u) | (u32(new_exp) << 10u) | (mantissa >> 13u);
}

/**
 * 将两个 f32 值打包为一个 u32 (作为两个 f16)
 */
fn pack_f16_pair(a: f32, b: f32) -> u32 {
    let a_f16 = f32_to_f16_bits(a);
    let b_f16 = f32_to_f16_bits(b);
    return (b_f16 << 16u) | (a_f16 & 0xFFFFu);
}

/**
 * 打包球谐 DC 系数
 */
fn pack_sh_dc(sh_dc: vec3<f32>, sh_idx: u32) -> array<u32, 2> {
    return array<u32, 2>(
        pack_f16_pair(sh_dc.x, sh_dc.y),
        pack_f16_pair(sh_dc.z, 0.0)  // 打包并填充
    );
}

/**
 * 打包高阶球谐系数
 * 处理 DC 以外的 SH 系数 (degree > 0)
 */
fn pack_sh_rest(base_idx: u32, point_idx: u32) -> array<u32, 22> {
    var packed: array<u32, 22>;
    
    // 计算每个点有多少个高阶系数
    let sh_deg = compression_uniforms.sh_degree;
    let coeffs_per_point = (sh_deg + 1) * (sh_deg + 1) - 1;  // 排除 DC (前 3 个)
    
    // 成对打包剩余系数
    for (var i = 0u; i < 22u; i += 1u) {
        let coeff_idx = base_idx + point_idx * coeffs_per_point + i * 2u;
        
        var a = 0.0;
        var b = 0.0;
        
        if (coeff_idx < arrayLength(&uncompressed_sh_rest)) {
            a = uncompressed_sh_rest[coeff_idx];
        }
        if (coeff_idx + 1u < arrayLength(&uncompressed_sh_rest)) {
            b = uncompressed_sh_rest[coeff_idx + 1u];
        }
        
        packed[i] = pack_f16_pair(a, b);
    }
    
    return packed;
}

@compute @workgroup_size(256)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let point_idx = gid.x;
    
    // 边界检查
    if (point_idx >= compression_uniforms.num_points) {
        return;
    }
    
    // 确保不超出缓冲区边界
    if (point_idx >= arrayLength(&uncompressed_positions) ||
        point_idx >= arrayLength(&uncompressed_scales) ||
        point_idx >= arrayLength(&uncompressed_rotations) ||
        point_idx >= arrayLength(&uncompressed_opacities) ||
        point_idx >= arrayLength(&uncompressed_sh_dc)) {
        return;
    }
    
    // 读取未压缩数据
    let position = uncompressed_positions[point_idx];
    let scale = uncompressed_scales[point_idx];
    let rotation = uncompressed_rotations[point_idx];  // 四元数
    let opacity = uncompressed_opacities[point_idx];
    let sh_dc = uncompressed_sh_dc[point_idx];
    
    // 将 四元数 + 缩放 转换为 协方差矩阵
    let cov_matrix = compute_covariance_matrix(scale, rotation);
    
    // 打包位置和不透明度
    compressed_gaussians[point_idx].pos_opacity[0] = pack_f16_pair(position.x, position.y);
    compressed_gaussians[point_idx].pos_opacity[1] = pack_f16_pair(position.z, opacity);
    
    // 打包协方差矩阵 (上三角: m00, m01, m02, m11, m12, m22)
    compressed_gaussians[point_idx].cov[0] = pack_f16_pair(cov_matrix[0][0], cov_matrix[0][1]);
    compressed_gaussians[point_idx].cov[1] = pack_f16_pair(cov_matrix[0][2], cov_matrix[1][1]);
    compressed_gaussians[point_idx].cov[2] = pack_f16_pair(cov_matrix[1][2], cov_matrix[2][2]);
    
    // 打包球谐系数
    if (point_idx < arrayLength(&compressed_sh)) {
        // 打包 DC 系数 (前 2 个 u32)
        let sh_dc_packed = pack_sh_dc(sh_dc, point_idx);
        compressed_sh[point_idx][0] = sh_dc_packed[0];
        compressed_sh[point_idx][1] = sh_dc_packed[1];
        
        // 打包高阶系数 (剩余 22 个 u32)
        if (compression_uniforms.sh_degree > 0u && arrayLength(&uncompressed_sh_rest) > 0u) {
            let sh_rest_packed = pack_sh_rest(0u, point_idx);
            for (var i = 0u; i < 22u; i += 1u) {
                compressed_sh[point_idx][i + 2u] = sh_rest_packed[i];
            }
        } else {
            // 如果没有高阶系数，填充零
            for (var i = 2u; i < 24u; i += 1u) {
                compressed_sh[point_idx][i] = 0u;
            }
        }
    }
}