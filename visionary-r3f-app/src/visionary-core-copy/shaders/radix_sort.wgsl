// 实现 GPU Radix Sort 的计算着色器
// 更多信息请参考 gpu_rs.rs 的开头部分
// 
// 注意：workgroup sizes 会在预处理阶段动态添加
// 在管线启动前，以下常量定义会被预置到此着色器代码中：
//
// const histogram_sg_size : u32       // 直方图子组大小
// const histogram_wg_size : u32       // 直方图工作组大小
// const rs_radix_log2 : u32           // 基数对数 (通常为 8，即 256 进制)
// const rs_radix_size : u32           // 基数大小 (2^8 = 256)
// const rs_keyval_size : u32          // 键值大小 (32位键 / 8位基数 = 4 pass)
// const rs_histogram_block_rows : u32 // 直方图块行数
// const rs_scatter_block_rows : u32   // 散射块行数

struct GeneralInfo{
    keys_size: u32,     // 需要排序的键的总数
    padded_size: u32,   // 填充后的大小
    passes: u32,        // 总趟数 (通常为 4)
    even_pass: u32,     // 当前是否为偶数趟 (0 或 1)
    odd_pass: u32,      // 当前是否为奇数趟 (0 或 1)
};

@group(0) @binding(0)
var<storage, read_write> infos: GeneralInfo;
@group(0) @binding(1)
var<storage, read_write> histograms : array<atomic<u32>>; // 全局直方图缓冲区
@group(0) @binding(2)
var<storage, read_write> keys : array<u32>;      // 输入键缓冲区 (Ping-Pong A)
@group(0) @binding(3)
var<storage, read_write> keys_b : array<u32>;    // 输出键缓冲区 (Ping-Pong B)
@group(0) @binding(4)
var<storage, read_write> payload_a : array<u32>; // 输入负载缓冲区 (Ping-Pong A，通常是索引)
@group(0) @binding(5)
var<storage, read_write> payload_b : array<u32>; // 输出负载缓冲区 (Ping-Pong B)

// 直方图缓冲区的内存布局：
//   +---------------------------------+ <-- 0
//   | histograms[keyval_size]         | 每一趟的直方图数据
//   +---------------------------------+ <-- keyval_size * histo_size
//   | partitions[scatter_blocks_ru-1] | 散射阶段的分区前缀和
//   +---------------------------------+ 
//   | workgroup_ids[keyval_size]      | 
//   +---------------------------------+ 

// --------------------------------------------------------------------------------------------------------------
// 0. 初始化：将直方图清零，并填充默认键值（同时重置 pass 信息）
// --------------------------------------------------------------------------------------------------------------
@compute @workgroup_size({histogram_wg_size})
fn zero_histograms(@builtin(global_invocation_id) gid : vec3<u32>, @builtin(num_workgroups) nwg: vec3<u32>) {
    if gid.x == 0u {
        infos.even_pass = 0u;
        infos.odd_pass = 1u;    // 必须为 1，因为第一次调用 even pass 后会计算 (0+1)%2
    }
    
    // 计算需要清零的范围
    let scatter_wg_size = histogram_wg_size;
    let scatter_block_kvs = scatter_wg_size * rs_scatter_block_rows;
    let scatter_blocks_ru = (infos.keys_size + scatter_block_kvs - 1u) / scatter_block_kvs;
    
    let histo_size = rs_radix_size;
    var n = (rs_keyval_size + scatter_blocks_ru - 1u) * histo_size;
    let b = n;
    
    // 处理填充区域
    if infos.keys_size < infos.padded_size {
        n += infos.padded_size - infos.keys_size;
    }
    
    // 并行清零
    let line_size = nwg.x * {histogram_wg_size}u;
    for (var cur_index = gid.x; cur_index < n; cur_index += line_size){
        if cur_index >= n {
            return;
        }
            
        if cur_index  < rs_keyval_size * histo_size {
            atomicStore(&histograms[cur_index], 0u);
        }
        else if cur_index < b {
            atomicStore(&histograms[cur_index], 0u);
        }
        else {
            // 将填充区域的键设置为最大值 (0xFFFFFFFF)，确保它们排序后排在最后
            keys[infos.keys_size + cur_index - b] = 0xFFFFFFFFu;
        }
    }
}

// --------------------------------------------------------------------------------------------------------------
// 1. 直方图计算阶段：统计每个基数桶中的元素数量
// --------------------------------------------------------------------------------------------------------------
var<workgroup> smem : array<atomic<u32>, rs_radix_size>; // 共享内存：本地直方图
var<private> kv : array<u32, rs_histogram_block_rows>;   // 私有寄存器：当前线程处理的键

// 清空共享内存
fn zero_smem(lid: u32) {
    if lid < rs_radix_size {
        atomicStore(&smem[lid], 0u);
    }
}

// 处理一个 pass 的直方图统计
fn histogram_pass(pass_: u32, lid: u32) {
    zero_smem(lid);
    workgroupBarrier();
    
    // 统计当前线程持有的键的基数
    for (var j = 0u; j < rs_histogram_block_rows; j++) {
        let u_val = bitcast<u32>(kv[j]);
        // 提取当前 pass 对应的 8 位基数
        let digit = extractBits(u_val, pass_ * rs_radix_log2, rs_radix_log2);
        atomicAdd(&smem[digit], 1u);
    }
    
    workgroupBarrier();
    
    // 将本地直方图累加到全局直方图
    let histogram_offset = rs_radix_size * pass_ + lid;
    if lid < rs_radix_size && atomicLoad(&smem[lid]) >= 0u {
        atomicAdd(&histograms[histogram_offset], atomicLoad(&smem[lid]));
    }
}

// 从全局内存加载键到寄存器
fn fill_kv(wid: u32, lid: u32) {
    let rs_block_keyvals : u32 = rs_histogram_block_rows * histogram_wg_size;
    let kv_in_offset = wid * rs_block_keyvals + lid;
    for (var i = 0u; i < rs_histogram_block_rows; i++) {
        let pos = kv_in_offset + i * histogram_wg_size;
        kv[i] = keys[pos];
    }
}

@compute @workgroup_size({histogram_wg_size})
fn calculate_histogram(@builtin(workgroup_id) wid : vec3<u32>, @builtin(local_invocation_id) lid : vec3<u32>) {
    // 高效加载多个值
    fill_kv(wid.x, lid.x);
    
    // 为每个 pass 累积并存储直方图 (这里硬编码了 4 个 pass，对应 32 位键)
    histogram_pass(3u, lid.x);
    histogram_pass(2u, lid.x);
    // if infos.passes > 2u {
        histogram_pass(1u, lid.x);
    // }
    // if infos.passes > 3u {
        histogram_pass(0u, lid.x);
    // }
}

// --------------------------------------------------------------------------------------------------------------
// 2. 前缀和计算阶段 (Prefix Sum / Scan)：计算全局偏移量
// --------------------------------------------------------------------------------------------------------------
// 在共享内存中进行前缀和归约
fn prefix_reduce_smem(lid: u32) {
    var offset = 1u;
    // 上行阶段 (Up-Sweep)
    for (var d = rs_radix_size >> 1u; d > 0u; d = d >> 1u) { 
        workgroupBarrier();
        if lid < d {
            let ai = offset * (2u * lid + 1u) - 1u;
            let bi = offset * (2u * lid + 2u) - 1u;
            atomicAdd(&smem[bi], atomicLoad(&smem[ai]));
        }
        offset = offset << 1u;
    }
    
    // 清除最后一个元素
    if lid == 0u { 
        atomicStore(&smem[rs_radix_size - 1u], 0u);
    } 
        
    // 下行阶段 (Down-Sweep)
    for (var d = 1u; d < rs_radix_size; d = d << 1u) {
        offset = offset >> 1u;
        workgroupBarrier();
        if lid < d {
            let ai = offset * (2u * lid + 1u) - 1u;
            let bi = offset * (2u * lid + 2u) - 1u;
            
            let t     = atomicLoad(&smem[ai]);
            atomicStore(&smem[ai], atomicLoad(&smem[bi]));
            atomicAdd(&smem[bi], t);
        }
    }
}

@compute @workgroup_size({prefix_wg_size})
fn prefix_histogram(@builtin(workgroup_id) wid: vec3<u32>, @builtin(local_invocation_id) lid : vec3<u32>) {
    // workgroup id 对应 pass，这里进行了倒序映射，使得 pass 3 在 buffer 的第一个位置
    let histogram_base = (rs_keyval_size - 1u - wid.x) * rs_radix_size;
    let histogram_offset = histogram_base + lid.x;
    
    // 加载直方图数据到共享内存
    // 每个线程负责加载 2 个数据，因为 prefix_wg_size = radix_size / 2
    atomicStore(&smem[lid.x], atomicLoad(&histograms[histogram_offset]));
    atomicStore(&smem[lid.x + {prefix_wg_size}u], atomicLoad(&histograms[histogram_offset + {prefix_wg_size}u]));

    // 执行前缀和
    prefix_reduce_smem(lid.x);
    workgroupBarrier();
    
    // 将结果写回全局内存
    atomicStore(&histograms[histogram_offset], atomicLoad(&smem[lid.x]));
    atomicStore(&histograms[histogram_offset + {prefix_wg_size}u], atomicLoad(&smem[lid.x + {prefix_wg_size}u]));
}

// --------------------------------------------------------------------------------------------------------------
// 3. 散射阶段 (Scatter)：将键值移动到排序后的位置
// --------------------------------------------------------------------------------------------------------------
// 注意：这里需要大量的共享内存
var<workgroup> scatter_smem: array<u32, rs_mem_dwords>; 

// 辅助函数定义
fn partitions_base_offset() -> u32 { return rs_keyval_size * rs_radix_size;}
fn smem_prefix_offset() -> u32 { return rs_radix_size + rs_radix_size;}
fn rs_prefix_sweep_0(idx: u32) -> u32 { return scatter_smem[smem_prefix_offset() + rs_mem_sweep_0_offset + idx];}
fn rs_prefix_sweep_1(idx: u32) -> u32 { return scatter_smem[smem_prefix_offset() + rs_mem_sweep_1_offset + idx];}
fn rs_prefix_sweep_2(idx: u32) -> u32 { return scatter_smem[smem_prefix_offset() + rs_mem_sweep_2_offset + idx];}
fn rs_prefix_load(lid: u32, idx: u32) -> u32 { return scatter_smem[rs_radix_size + lid + idx];}
fn rs_prefix_store(lid: u32, idx: u32, val: u32) { scatter_smem[rs_radix_size + lid + idx] = val;}
fn is_first_local_invocation(lid: u32) -> bool { return lid == 0u;}
fn histogram_load(digit: u32) -> u32 {
    return atomicLoad(&smem[digit]);
}
fn histogram_store(digit: u32, count: u32) { 
    atomicStore(&smem[digit], count);
} 

const rs_partition_mask_status : u32 = 0xC0000000u; // 分区状态掩码
const rs_partition_mask_count : u32 = 0x3FFFFFFFu;  // 分区计数掩码
var<private> kr : array<u32, rs_scatter_block_rows>; // 键的 rank
var<private> pv : array<u32, rs_scatter_block_rows>; // 负载 (Payload)

// 从 keys 加载数据 (偶数 pass)
fn fill_kv_even(wid: u32, lid: u32) {
    let subgroup_id = lid / histogram_sg_size;
    let subgroup_invoc_id = lid - subgroup_id * histogram_sg_size;
    let subgroup_keyvals = rs_scatter_block_rows * histogram_sg_size;
    let rs_block_keyvals : u32 = rs_histogram_block_rows * histogram_wg_size;
    let kv_in_offset = wid * rs_block_keyvals + subgroup_id * subgroup_keyvals + subgroup_invoc_id;
    for (var i = 0u; i < rs_histogram_block_rows; i++) {
        let pos = kv_in_offset + i * histogram_sg_size;
        kv[i] = keys[pos];
    }
    for (var i = 0u; i < rs_histogram_block_rows; i++) {
        let pos = kv_in_offset + i * histogram_sg_size;
        pv[i] = payload_a[pos];
    }
}

// 从 keys_b 加载数据 (奇数 pass)
fn fill_kv_odd(wid: u32, lid: u32) {
    let subgroup_id = lid / histogram_sg_size;
    let subgroup_invoc_id = lid - subgroup_id * histogram_sg_size;
    let subgroup_keyvals = rs_scatter_block_rows * histogram_sg_size;
    let rs_block_keyvals : u32 = rs_histogram_block_rows * histogram_wg_size;
    let kv_in_offset = wid * rs_block_keyvals + subgroup_id * subgroup_keyvals + subgroup_invoc_id;
    for (var i = 0u; i < rs_histogram_block_rows; i++) {
        let pos = kv_in_offset + i * histogram_sg_size;
        kv[i] = keys_b[pos];
    }
    for (var i = 0u; i < rs_histogram_block_rows; i++) {
        let pos = kv_in_offset + i * histogram_sg_size;
        pv[i] = payload_b[pos];
    }
}

// 核心散射逻辑
fn scatter(pass_: u32, lid: vec3<u32>, gid: vec3<u32>, wid: vec3<u32>, nwg: vec3<u32>, partition_status_invalid: u32, partition_status_reduction: u32, partition_status_prefix: u32) {
    let partition_mask_invalid = partition_status_invalid << 30u;
    let partition_mask_reduction = partition_status_reduction << 30u;
    let partition_mask_prefix = partition_status_prefix << 30u;

    // 1. 本地直方图计算和排名 (Local Ranking)
    // 模拟子组广播操作，计算每个键在子组内的排名
    let subgroup_id = lid.x / histogram_sg_size;
    let subgroup_offset = subgroup_id * histogram_sg_size;
    let subgroup_tid = lid.x - subgroup_offset;
    let subgroup_count = {scatter_wg_size}u / histogram_sg_size;
    
    for (var i = 0u; i < rs_scatter_block_rows; i++) {
        let u_val = bitcast<u32>(kv[i]);
        let digit = extractBits(u_val, pass_ * rs_radix_log2, rs_radix_log2);
        
        atomicStore(&smem[lid.x], digit);
        workgroupBarrier(); // Ensure all threads have written their digit

        var count = 0u;
        var rank = 0u;
        
        // 遍历子组内的所有线程，统计当前 digit 的出现次数和排名
        for (var j = 0u; j < histogram_sg_size; j++) {
            if atomicLoad(&smem[subgroup_offset + j]) == digit {
                count += 1u;
                if j <= subgroup_tid {
                    rank += 1u;
                }
            }
        }
        workgroupBarrier(); // Ensure all threads have read before next iteration writes
        
        // 存储结果：高16位为总数，低16位为排名
        kr[i] = (count << 16u) | rank;
    }
    
    zero_smem(lid.x);   
    workgroupBarrier();

    // 2. 计算工作组内的直方图 (Workgroup Histogram)
    for (var i = 0u; i < subgroup_count; i++) {
        for (var j = 0u; j < rs_scatter_block_rows; j++) {
            if subgroup_id == i {
                let v = bitcast<u32>(kv[j]);
                let digit = extractBits(v, pass_ * rs_radix_log2, rs_radix_log2);
                let prev = histogram_load(digit);
                let rank = kr[j] & 0xFFFFu;
                let count = kr[j] >> 16u;
                
                // 更新 kr 为局部偏移量
                kr[j] = prev + rank;

                if rank == count {
                    histogram_store(digit, (prev + count));
                }
            }
            workgroupBarrier();
        }
    }
    
    // 3. 链式扫描 (Chained Scan) / Lookback
    // 计算当前工作组的全局偏移量
    let partition_offset = lid.x + partitions_base_offset();
    let partition_base = wid.x * rs_radix_size;
    
    if wid.x == 0u {
        // 第一个工作组：直接存储前缀和
        let hist_offset = pass_ * rs_radix_size + lid.x;
        if lid.x < rs_radix_size {
            let exc = atomicLoad(&histograms[hist_offset]);
            let red = histogram_load(lid.x);
            
            scatter_smem[lid.x] = exc;
            
            let inc = exc + red;
            atomicStore(&histograms[partition_offset], inc | partition_mask_prefix);
        }
    }
    else {
        // 后续工作组：需要查找前序工作组的状态
        
        // 存储 reduction 状态
        if lid.x < rs_radix_size && wid.x < nwg.x - 1u {
            let red = histogram_load(lid.x);
            atomicStore(&histograms[partition_offset + partition_base], red | partition_mask_reduction);
        }
        
        // Lookback 循环：向前查找直到找到 PREFIX 状态，并累加中间的 REDUCTION
        if lid.x < rs_radix_size {
            var partition_base_prev = partition_base - rs_radix_size;
            var exc                 = 0u;

            while true {
                let prev = atomicLoad(&histograms[partition_base_prev + partition_offset]);
                
                // 状态无效，自旋等待
                if (prev & rs_partition_mask_status) == partition_mask_invalid {
                    continue;
                }
                
                exc += prev & rs_partition_mask_count;
                
                // 如果是 REDUCTION 状态，继续向前
                if (prev & rs_partition_mask_status) != partition_mask_prefix {
                    partition_base_prev -= rs_radix_size;
                    continue;
                }

                // 找到 PREFIX 状态，计算结束
                scatter_smem[lid.x] = exc;

                // 如果不是最后一个工作组，更新当前状态为 PREFIX
                if wid.x < nwg.x - 1u { 
                    atomicAdd(&histograms[partition_offset + partition_base], exc | (1u << 30u));
                }
                break;
            }
        }
    }
    
    // 4. 计算本地独占前缀和
    prefix_reduce_smem(lid.x);
    workgroupBarrier();

    // 5. 将键值排名转换为本地索引
    for (var i = 0u; i < rs_scatter_block_rows; i++) {
        let v = bitcast<u32>(kv[i]);
        let digit = extractBits(v, pass_ * rs_radix_log2, rs_radix_log2);
        let exc   = histogram_load(digit);
        let idx   = exc + kr[i];
        
        kr[i] |= (idx << 16u);
    }
    workgroupBarrier();
    
    // 6. 重新排序 (Reorder)
    // 利用共享内存将键值和 Payload 交换到正确顺序
    let smem_reorder_offset = rs_radix_size;
    let smem_base = smem_reorder_offset + lid.x;
  
    // --- 键值 ---
    for (var j = 0u; j < rs_scatter_block_rows; j++) {
        let smem_idx = smem_reorder_offset + (kr[j] >> 16u) - 1u;
        scatter_smem[smem_idx] = bitcast<u32>(kv[j]);
    }
    workgroupBarrier();
    for (var j = 0u; j < rs_scatter_block_rows; j++) {
        kv[j] = scatter_smem[smem_base + j * {scatter_wg_size}u];
    }
    workgroupBarrier();
    
    // --- Payload ---
    for (var j = 0u; j < rs_scatter_block_rows; j++) {
        let smem_idx = smem_reorder_offset + (kr[j] >> 16u) - 1u;
        scatter_smem[smem_idx] = pv[j];
    }
    workgroupBarrier();
    for (var j = 0u; j < rs_scatter_block_rows; j++) {
        pv[j] = scatter_smem[smem_base + j * {scatter_wg_size}u];
    }
    workgroupBarrier();
    
    // --- 排名 ---
    for (var i = 0u; i < rs_scatter_block_rows; i++) {
        let smem_idx = smem_reorder_offset + (kr[i] >> 16u) - 1u;
        scatter_smem[smem_idx] = kr[i];
    }
    workgroupBarrier();
    for (var i = 0u; i < rs_scatter_block_rows; i++) {
        kr[i] = scatter_smem[smem_base + i * {scatter_wg_size}u] & 0xFFFFu;
    }
    
    // 7. 将本地索引转换为全局索引
    for (var i = 0u; i < rs_scatter_block_rows; i++) {
        let v = bitcast<u32>(kv[i]);
        let digit = extractBits(v, pass_ * rs_radix_log2, rs_radix_log2);
        let exc   = scatter_smem[digit];

        kr[i] += exc - 1u;
    }
}

// 偶数 Pass 的散射入口
@compute @workgroup_size({scatter_wg_size})
fn scatter_even(@builtin(workgroup_id) wid: vec3<u32>, @builtin(local_invocation_id) lid: vec3<u32>, @builtin(global_invocation_id) gid: vec3<u32>, @builtin(num_workgroups) nwg: vec3<u32>) {
    if gid.x == 0u {
        infos.odd_pass = (infos.odd_pass + 1u) % 2u; // 更新下一次 Pass 的标志
    }
    let cur_pass = infos.even_pass * 2u;
    
    // 从 keys 读取，写入 keys_b
    fill_kv_even(wid.x, lid.x);
    
    let partition_status_invalid = 0u;
    let partition_status_reduction = 1u;
    let partition_status_prefix = 2u;
    scatter(cur_pass, lid, gid, wid, nwg, partition_status_invalid, partition_status_reduction, partition_status_prefix);

    // 写入结果到全局内存
    for (var i = 0u; i < rs_scatter_block_rows; i++) {
        keys_b[kr[i]] = kv[i];
    }
    for (var i = 0u; i < rs_scatter_block_rows; i++) {
        payload_b[kr[i]] = pv[i];
    }
}

// 奇数 Pass 的散射入口
@compute @workgroup_size({scatter_wg_size})
fn scatter_odd(@builtin(workgroup_id) wid: vec3<u32>, @builtin(local_invocation_id) lid: vec3<u32>, @builtin(global_invocation_id) gid: vec3<u32>, @builtin(num_workgroups) nwg: vec3<u32>) {
    if gid.x == 0u {
        infos.even_pass = (infos.even_pass + 1u) % 2u; 
    }
    let cur_pass = infos.odd_pass * 2u + 1u;

    // 从 keys_b 读取，写入 keys
    fill_kv_odd(wid.x, lid.x);

    let partition_status_invalid = 2u;
    let partition_status_reduction = 3u;
    let partition_status_prefix = 0u;
    scatter(cur_pass, lid, gid, wid, nwg, partition_status_invalid, partition_status_reduction, partition_status_prefix);

    // 写入结果到全局内存
    for (var i = 0u; i < rs_scatter_block_rows; i++) {
        keys[kr[i]] = kv[i];
    }
    for (var i = 0u; i < rs_scatter_block_rows; i++) {
        payload_a[kr[i]] = pv[i];
    }
}
