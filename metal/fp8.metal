// Native GLM FP8 model-weight kernels.
//
// The converter stores each E4M3FN weight matrix as a raw GGUF I8 tensor and
// emits the source F32 *_scale_inv matrix immediately after it.  GGUF dims are
// reversed for the engine's row-major matmul convention, but the source byte
// order is preserved: scale rows therefore remain indexed as
// [output_block][input_block].

static inline float ds4_native_fp8_e4m3fn_value(uchar code) {
    const uint absolute = (uint)code & 0x7fu;
    if (absolute == 0u) return 0.0f;
    const uint exponent = ((uint)code >> 3u) & 0x0fu;
    const uint mantissa = (uint)code & 0x07u;
    constant float exp_scale[16] = {
        0.0f, 0.015625f, 0.03125f, 0.0625f,
        0.125f, 0.25f, 0.5f, 1.0f,
        2.0f, 4.0f, 8.0f, 16.0f,
        32.0f, 64.0f, 128.0f, 256.0f,
    };
    const float value = exponent == 0u
        ? (float)mantissa * 0.001953125f
        : (1.0f + (float)mantissa * 0.125f) * exp_scale[exponent];
    return (code & 0x80u) != 0u ? -value : value;
}

struct ds4_metal_native_fp8_matmul_args {
    uint in_dim;
    uint out_dim;
    uint n_rows;
    uint scale_in_blocks;
};

static inline float ds4_native_fp8_weight_value(
        device const uchar *weights,
        device const float *scales,
        uint row,
        uint col,
        uint in_dim,
        uint scale_in_blocks) {
    const ulong weight_index = (ulong)row * (ulong)in_dim + col;
    const ulong scale_index = (ulong)(row >> 7u) * scale_in_blocks + (col >> 7u);
    return ds4_native_fp8_e4m3fn_value(weights[weight_index]) * scales[scale_index];
}

kernel void kernel_ds4_native_fp8_matmul_f32(
        constant ds4_metal_native_fp8_matmul_args &args,
        device const uchar *weights,
        device const float *scales,
        device const float *x,
        device float *out,
        uint2 gid [[thread_position_in_grid]]) {
    const uint row = gid.x;
    const uint token = gid.y;
    if (row >= args.out_dim || token >= args.n_rows) return;

    device const float *xr = x + (ulong)token * args.in_dim;
    float sum = 0.0f;
    for (uint col = 0; col < args.in_dim; col++) {
        sum = fma(ds4_native_fp8_weight_value(
                      weights, scales, row, col,
                      args.in_dim, args.scale_in_blocks),
                  xr[col], sum);
    }
    out[(ulong)token * args.out_dim + row] = sum;
}

kernel void kernel_ds4_native_fp8_get_rows_f32(
        constant ds4_metal_native_fp8_matmul_args &args,
        device const uchar *weights,
        device const float *scales,
        device const int *tokens,
        device float *out,
        uint2 gid [[thread_position_in_grid]]) {
    const uint col = gid.x;
    const uint row = gid.y;
    if (col >= args.in_dim || row >= args.n_rows) return;
    const int token = tokens[row];
    if (token < 0 || (uint)token >= args.out_dim) {
        out[(ulong)row * args.in_dim + col] = 0.0f;
        return;
    }
    const uint source_row = (uint)token;
    out[(ulong)row * args.in_dim + col] = ds4_native_fp8_weight_value(
        weights, scales, source_row, col, args.in_dim, args.scale_in_blocks);
}

struct ds4_metal_native_fp8_moe_args {
    uint in_dim;
    uint mid_dim;
    uint out_dim;
    uint n_total_expert;
    uint n_expert_used;
    uint n_tokens;
    uint mid_token_stride;
    uint gate_scale_in_blocks;
    uint up_scale_in_blocks;
    uint down_scale_in_blocks;
    uint gate_scale_row_elems;
    uint up_scale_row_elems;
    uint down_scale_row_elems;
    uint64_t gate_expert_bytes;
    uint64_t gate_row_bytes;
    uint64_t up_expert_bytes;
    uint64_t up_row_bytes;
    uint64_t down_expert_bytes;
    uint64_t down_row_bytes;
    uint64_t gate_scale_expert_bytes;
    uint64_t up_scale_expert_bytes;
    uint64_t down_scale_expert_bytes;
    float swiglu_clamp;
    int32_t tp_rank;
    int32_t tp_world;
    int32_t tp_expert_base;
};

static inline bool ds4_native_fp8_moe_owns_expert(
        int expert, constant ds4_metal_native_fp8_moe_args &args) {
    if (expert < 0 || (uint)expert >= args.n_total_expert) return false;
    if (args.tp_world <= 1) return true;
    const int per_rank = (int)args.n_total_expert / args.tp_world;
    const int first = args.tp_rank * per_rank;
    const int last = args.tp_rank + 1 == args.tp_world
        ? (int)args.n_total_expert
        : first + per_rank;
    return expert >= first && expert < last;
}

static inline float ds4_native_fp8_moe_swiglu(float gate, float up, float clamp_value) {
    if (clamp_value > 1.0e-6f) {
        gate = min(gate, clamp_value);
        up = clamp(up, -clamp_value, clamp_value);
    }
    return (gate / (1.0f + exp(-gate))) * up;
}

// Compute gate/up for each selected expert and directly write the routed
// SwiGLU result into the normal [token][selected_slot][mid] activation buffer.
kernel void kernel_ds4_native_fp8_moe_pair_swiglu_f32(
        constant ds4_metal_native_fp8_moe_args &args,
        device const uchar *gate,
        device const uchar *up,
        device const float *gate_scales,
        device const float *up_scales,
        device const float *x,
        device const int32_t *selected,
        device const float *weights,
        device float *mid,
        threadgroup float *scratch [[threadgroup(0)]],
        uint3 tgpig [[threadgroup_position_in_grid]],
        uint tid [[thread_index_in_threadgroup]],
        uint ntg [[threads_per_threadgroup]]) {
    const uint row = tgpig.x;
    const uint slot = tgpig.y;
    const uint token = tgpig.z;
    if (row >= args.mid_dim || slot >= args.n_expert_used || token >= args.n_tokens) return;

    const ulong selected_index = (ulong)token * args.n_expert_used + slot;
    const int expert = selected[selected_index];
    const ulong mid_index = (ulong)token * args.mid_token_stride +
                            (ulong)slot * args.mid_dim + row;
    if (!ds4_native_fp8_moe_owns_expert(expert, args)) {
        if (tid == 0u) mid[mid_index] = 0.0f;
        return;
    }
    const uint local_expert = (uint)(expert - args.tp_expert_base);
    device const uchar *gate_row = gate +
        (ulong)local_expert * args.gate_expert_bytes +
        (ulong)row * args.gate_row_bytes;
    device const uchar *up_row = up +
        (ulong)local_expert * args.up_expert_bytes +
        (ulong)row * args.up_row_bytes;
    device const float *gate_scale_row = gate_scales +
        (ulong)local_expert * args.gate_scale_expert_bytes +
        (ulong)(row >> 7u) * args.gate_scale_row_elems;
    device const float *up_scale_row = up_scales +
        (ulong)local_expert * args.up_scale_expert_bytes +
        (ulong)(row >> 7u) * args.up_scale_row_elems;
    device const float *xr = x + (ulong)token * args.in_dim;

    float gate_sum = 0.0f;
    float up_sum = 0.0f;
    for (uint col = tid; col < args.in_dim; col += ntg) {
        gate_sum = fma(ds4_native_fp8_e4m3fn_value(gate_row[col]) *
                           gate_scale_row[col >> 7u], xr[col], gate_sum);
        up_sum = fma(ds4_native_fp8_e4m3fn_value(up_row[col]) *
                         up_scale_row[col >> 7u], xr[col], up_sum);
    }
    scratch[tid] = gate_sum;
    scratch[ntg + tid] = up_sum;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint stride = ntg >> 1u; stride != 0u; stride >>= 1u) {
        if (tid < stride) {
            scratch[tid] += scratch[tid + stride];
            scratch[ntg + tid] += scratch[ntg + tid + stride];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (tid == 0u) {
        mid[mid_index] = ds4_native_fp8_moe_swiglu(
            scratch[0], scratch[ntg], args.swiglu_clamp) * weights[selected_index];
    }
}

// Accumulate all selected experts' down projections directly into the final
// routed output. The route weight is already folded into mid by the pair
// kernel, so this kernel only performs the selected-expert sum.
kernel void kernel_ds4_native_fp8_moe_down_sum_f32(
        constant ds4_metal_native_fp8_moe_args &args,
        device const uchar *down,
        device const float *down_scales,
        device const float *mid,
        device const int32_t *selected,
        device float *out,
        threadgroup float *scratch [[threadgroup(0)]],
        uint2 tgpig [[threadgroup_position_in_grid]],
        uint tid [[thread_index_in_threadgroup]],
        uint ntg [[threads_per_threadgroup]]) {
    const uint row = tgpig.x;
    const uint token = tgpig.y;
    if (row >= args.out_dim || token >= args.n_tokens) return;

    float sum = 0.0f;
    for (uint slot = 0; slot < args.n_expert_used; slot++) {
        const ulong selected_index = (ulong)token * args.n_expert_used + slot;
        const int expert = selected[selected_index];
        if (!ds4_native_fp8_moe_owns_expert(expert, args)) continue;
        const uint local_expert = (uint)(expert - args.tp_expert_base);
        device const uchar *row_ptr = down +
            (ulong)local_expert * args.down_expert_bytes +
            (ulong)row * args.down_row_bytes;
        device const float *scale_row = down_scales +
            (ulong)local_expert * args.down_scale_expert_bytes +
            (ulong)(row >> 7u) * args.down_scale_row_elems;
        device const float *mid_row = mid +
            (ulong)token * args.mid_token_stride +
            (ulong)slot * args.mid_dim;
        for (uint col = tid; col < args.mid_dim; col += ntg) {
            sum = fma(ds4_native_fp8_e4m3fn_value(row_ptr[col]) *
                          scale_row[col >> 7u], mid_row[col], sum);
        }
    }
    scratch[tid] = sum;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint stride = ntg >> 1u; stride != 0u; stride >>= 1u) {
        if (tid < stride) scratch[tid] += scratch[tid + stride];
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (tid == 0u) out[(ulong)token * args.out_dim + row] = scratch[0];
}
