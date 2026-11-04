#pragma once
#include "rknn_api.h"
#include <cmath>
// Validate the quantized detector tensor layout before postprocessing.
inline bool model_contract(const rknn_input_output_num &io, const rknn_tensor_attr *in,
                           const rknn_tensor_attr *out) {
    if (io.n_input != 1 || io.n_output != 9 || !in || !out)
        return false;
    if (in[0].n_dims != 4 || in[0].dims[0] != 1)
        return false;
    const bool nchw = in[0].fmt == RKNN_TENSOR_NCHW && in[0].dims[1] == 3 && in[0].dims[2] == 640 &&
                      in[0].dims[3] == 640;
    const bool nhwc = in[0].fmt == RKNN_TENSOR_NHWC && in[0].dims[1] == 640 &&
                      in[0].dims[2] == 640 && in[0].dims[3] == 3;
    if (!nchw && !nhwc)
        return false;
    const unsigned channels[3] = {64, 80, 1};
    for (unsigned i = 0; i < 9; ++i) {
        const auto &a = out[i];
        const unsigned grid = 80u >> (i / 3);
        if (a.n_dims != 4 || a.fmt != RKNN_TENSOR_NCHW || a.dims[0] != 1 ||
            a.dims[1] != channels[i % 3] || a.dims[2] != grid || a.dims[3] != grid ||
            a.n_elems != channels[i % 3] * grid * grid || a.type != RKNN_TENSOR_INT8 ||
            a.qnt_type != RKNN_TENSOR_QNT_AFFINE_ASYMMETRIC || !std::isfinite(a.scale) ||
            a.scale <= 0 || a.zp < -128 || a.zp > 127)
            return false;
    }
    return true;
}
