struct Params {
  n: u32,           // 元素总数
  colorDim: u32,    // 颜色维度 (RGB=3, SH1=16, etc.)
}

@group(0) @binding(0)
var<storage, read> gauss_f32 : array<f32>; // 输入: f32 格式的高斯数据 (位置+缩放+旋转+不透明度)

@group(0) @binding(1)
var<storage, read_write> gauss_f16_packed : array<u32>; // 输出: f16 格式打包的高斯数据

@group(0) @binding(2)
var<storage, read> color_f32 : array<f32>; // 输入: f32 格式的颜色数据

@group(0) @binding(3)
var<storage, read_write> color_f16_packed : array<u32>; // 输出: f16 格式打包的颜色数据

@group(0) @binding(4)
var<uniform> params : Params;

// 将两个 f32 值打包为一个 u32 (包含两个 f16)
fn pack2(a: f32, b: f32) -> u32 {
  return pack2x16float(vec2<f32>(a, b));
}

// 高斯数据转换: 每个点 10 个 f32 -> 5 个 u32
// 输入布局: [x, y, z, opacity, scale_x, scale_y, scale_z, rot_w, rot_x, rot_y, rot_z] (通常 10-13 floats, 这里假设 10 floats 布局或者特定的 10 元素子集)
// 注意：这里的 10 f32 -> 5 u32 看起来是假设输入已经是某种 10 元素的紧凑格式，或者只转换前 10 个属性
@compute @workgroup_size(256,1,1)
fn convert_gauss(@builtin(global_invocation_id) gid: vec3<u32>) {
  let idx = gid.x;
  if (idx >= params.n) { return; }

  let baseIn  = idx * 10u;
  let baseOut = idx * 5u;

  // 成对打包
  gauss_f16_packed[baseOut + 0u] = pack2(gauss_f32[baseIn + 0u], gauss_f32[baseIn + 1u]);
  gauss_f16_packed[baseOut + 1u] = pack2(gauss_f32[baseIn + 2u], gauss_f32[baseIn + 3u]);
  gauss_f16_packed[baseOut + 2u] = pack2(gauss_f32[baseIn + 4u], gauss_f32[baseIn + 5u]);
  gauss_f16_packed[baseOut + 3u] = pack2(gauss_f32[baseIn + 6u], gauss_f32[baseIn + 7u]);
  gauss_f16_packed[baseOut + 4u] = pack2(gauss_f32[baseIn + 8u], gauss_f32[baseIn + 9u]);
}

// 颜色数据转换: 每个点 colorDim 个 f32 -> ceil(colorDim/2) 个 u32
@compute @workgroup_size(256,1,1)
fn convert_color(@builtin(global_invocation_id) gid: vec3<u32>) {
  let idx = gid.x;
  if (idx >= params.n) { return; }

  let dim = params.colorDim;
  let inBase  = idx * dim;
  let outBase = idx * ((dim + 1u) / 2u);

  var i: u32 = 0u;
  loop {
    if (i >= dim) { break; }
    
    // 读取第一个值
    let a = color_f32[inBase + i];
    
    // 检查是否有第二个值，如果没有则补 0
    let hasB: bool = (i + 1u) < dim;
    let b = select(0.0, color_f32[inBase + i + 1u], hasB);
    
    // 打包并写入
    let w = pack2(a, b);
    color_f16_packed[outBase + (i >> 1u)] = w;
    
    i += 2u;
  }
}


