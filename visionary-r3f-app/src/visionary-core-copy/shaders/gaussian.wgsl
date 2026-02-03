// 我们在 alpha 值为 1/255 时进行截断
const CUTOFF:f32 = 2.3539888583335364; // = sqrt(log(255))

// 顶点着色器输出结构体
struct VertexOutput {
    @builtin(position) position: vec4<f32>, // 裁剪空间坐标
    @location(0) screen_pos: vec2<f32>,     // 屏幕空间坐标 (用于计算高斯衰减)
    @location(1) color: vec4<f32>,          // 顶点颜色
};

// 顶点着色器输入结构体（未使用，直接从 storage buffer 读取）
struct VertexInput {
    @location(0) v: vec4<f32>,
    @location(1) pos: vec4<f32>,
    @location(2) color: vec4<f32>,
};

// Splat 结构体：对应于预处理阶段写入 points_2d 的数据
struct Splat {
     // 4x f16 打包成 u32 (存储了两个 2D 轴向量 v1, v2)
    v_0: u32, v_1: u32,
    // 2x f16 打包成 u32 (NDC 坐标 x, y)
    pos: u32,
    // NDC z (高精度 f32)
    posz: f32,
    // rgba 打包成 f16 (存储在两个 u32 中)
    color_0: u32,color_1: u32,
};

// 绑定组 0，绑定 2：2D Splat 数据（只读）
@group(0) @binding(2)
var<storage, read> points_2d : array<Splat>;

// 绑定组 1，绑定 4：排序后的索引（只读）
@group(1) @binding(4)
var<storage, read> indices : array<u32>;

@vertex
fn vs_main(
    @builtin(vertex_index) in_vertex_index: u32,     // 顶点索引 (0-3，用于绘制四边形)
    @builtin(instance_index) in_instance_index: u32  // 实例索引 (对应第几个 Gaussian Splat)
) -> VertexOutput {
    var out: VertexOutput;

    // 通过排序后的索引获取当前要绘制的 Splat 数据
    let vertex = points_2d[indices[in_instance_index] + 0u];

    // 解包屏幕空间中的特征向量 (v1, v2)
    // 这些向量定义了 2D 高斯椭圆的形状和方向
    let v1 = unpack2x16float(vertex.v_0);
    let v2 = unpack2x16float(vertex.v_1);

    // 解包中心点坐标 (NDC XY) 和 Z 深度
    let v_center_xy = unpack2x16float(vertex.pos);
    let v_center_z = vertex.posz;

    // 生成四边形顶点坐标 (-1 到 1)
    // 0: (-1, -1), 1: (1, -1), 2: (-1, 1), 3: (1, 1)
    // 这里的逻辑是用 vertex_index 生成一个覆盖 (-1,-1) 到 (1,1) 的矩形
    let x = f32(in_vertex_index % 2u == 0u) * 2. - (1.);
    let y = f32(in_vertex_index < 2u) * 2. - (1.);

    // 根据截断阈值放大四边形，确保覆盖高斯分布的有效区域
    let position = vec2<f32>(x, y) * CUTOFF;

    // 计算当前顶点相对于中心的偏移量
    // offset = 2 * [v1, v2] * position
    // 这里利用了特征向量将单位圆变换为目标椭圆
    let offset = 2. * mat2x2<f32>(v1, v2) * position;
    
    // 限制 Z 深度在 0.0 到 1.0 之间
    let z_ndc = clamp(v_center_z, 0.0, 1.0);
    
    // 输出最终裁剪空间坐标
    // 注意：offset 是在 NDC 空间中直接加到中心点的
    out.position = vec4<f32>(v_center_xy + offset, z_ndc, 1.);
    
    // 传递屏幕空间坐标给片段着色器，用于计算高斯 alpha
    out.screen_pos = position;
    
    // 解包颜色并传递
    out.color = vec4<f32>(unpack2x16float(vertex.color_0), unpack2x16float(vertex.color_1));
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    // 计算当前像素点距离中心的距离平方 (x^2 + y^2)
    // in.screen_pos 是相对于中心的坐标，范围大约在 [-CUTOFF, CUTOFF]
    let a = dot(in.screen_pos, in.screen_pos);
    
    // 如果超出截断范围，丢弃该像素
    if a > 2. * CUTOFF {
        discard;
    }
    
    // 计算高斯 alpha 值：alpha = exp(-dist^2) * base_alpha
    // min(0.99, ...) 是为了防止 alpha 变为 1.0 导致的某些混合问题（可选）
    let b = min(0.99, exp(-a) * in.color.a);
    
    // 输出最终颜色 (预乘 Alpha 混合通常在混合状态中设置，这里输出 RGB 和调整后的 Alpha)
    // 注意：这里没有预乘 alpha，依赖渲染管线的 blend state
    return vec4<f32>(in.color.rgb, 1.) * b;
}