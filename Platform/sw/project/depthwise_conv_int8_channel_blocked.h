#ifndef PLATFORM_SW_PROJECT_DEPTHWISE_CONV_INT8_CHANNEL_BLOCKED_H_
#define PLATFORM_SW_PROJECT_DEPTHWISE_CONV_INT8_CHANNEL_BLOCKED_H_

#include <stdint.h>

#include "tensorflow/lite/c/common.h"
#include "tensorflow/lite/kernels/internal/types.h"

namespace tflite {

// Int8 depthwise convolution with per-channel quantization. The result is
// bit-identical to reference_integer_ops::DepthwiseConvPerChannel.
//
// Each output pixel is computed eight channels at a time with the
// accumulators in registers, walking a per-pixel list of in-image filter
// taps. For pixels whose whole filter window is inside the image, the
// input-offset term input_offset * sum(filter) is folded into the bias once
// per call, so the inner loop is a plain int8 x int8 multiply-accumulate.
// Pixels at padded borders use the reference form filter * (input + offset).
void DepthwiseConvInt8ChannelBlocked(
    const DepthwiseParams& params, const int32_t* output_multiplier,
    const int32_t* output_shift, const RuntimeShape& input_shape,
    const int8_t* input_data, const RuntimeShape& filter_shape,
    const int8_t* filter_data, const RuntimeShape& bias_shape,
    const int32_t* bias_data, const RuntimeShape& output_shape,
    int8_t* output_data);

// DEPTHWISE_CONV_2D registration: int8 input with int8 filter runs
// DepthwiseConvInt8ChannelBlocked; every other type combination runs the
// upstream TFLM kernel.
TfLiteRegistration Register_DEPTHWISE_CONV_2D_INT8_CHANNEL_BLOCKED();

}  // namespace tflite

#endif  // PLATFORM_SW_PROJECT_DEPTHWISE_CONV_INT8_CHANNEL_BLOCKED_H_
