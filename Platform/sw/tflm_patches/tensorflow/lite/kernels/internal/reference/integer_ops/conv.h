/* Copyright 2019 The TensorFlow Authors. All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
==============================================================================*/
#ifndef TENSORFLOW_LITE_KERNELS_INTERNAL_REFERENCE_INTEGER_OPS_CONV_H_
#define TENSORFLOW_LITE_KERNELS_INTERNAL_REFERENCE_INTEGER_OPS_CONV_H_

#include <algorithm>
#include <stdint.h>

#include "lab2_api.h"
#include "tensorflow/lite/kernels/internal/common.h"
#include "tensorflow/lite/kernels/internal/portable_tensor_utils.h"

namespace tflite {
namespace reference_integer_ops {

// sum_{i < n} (input[i] + input_offset) * filter[i], computed by the NPU
// through hw_simd_mac (lab2_api.h), which takes an int8 input offset.
//
// For int8 tensors input_offset = -zero_point lies in [-127, 128]; 128 (zero
// point -128) does not fit in int8. Offsets outside int8 are split as
// input_offset = o1 + o2 with o1, o2 in int8, using
//   (x + o1 + o2) * w = (x + o1) * w + (x + o2) * w - x * w,
// so every product is still formed by the NPU and the CPU only adds the three
// results (modulo 2^32, like the int32 reference accumulator).
inline int32_t ConvDotProduct(const int8_t* input, const int8_t* filter,
                              int32_t input_offset, uint32_t n) {
  int8_t* in = const_cast<int8_t*>(input);
  int8_t* flt = const_cast<int8_t*>(filter);
  if (input_offset >= -128 && input_offset <= 127) {
    return hw_simd_mac(in, flt, static_cast<int8_t>(input_offset), n);
  }
  TFLITE_DCHECK_GE(input_offset, -256);
  TFLITE_DCHECK_LE(input_offset, 254);
  const int32_t o1 = input_offset / 2;
  const int32_t o2 = input_offset - o1;
  const uint32_t a =
      static_cast<uint32_t>(hw_simd_mac(in, flt, static_cast<int8_t>(o1), n));
  // o1 == o2 for the common offset 128, so (x + 64) * w is formed once.
  const uint32_t b =
      o2 == o1 ? a
               : static_cast<uint32_t>(
                     hw_simd_mac(in, flt, static_cast<int8_t>(o2), n));
  const uint32_t c = static_cast<uint32_t>(hw_simd_mac(in, flt, 0, n));
  return static_cast<int32_t>(a + b - c);
}

// Fixed-point per-channel-quantization convolution kernel. The result is
// identical to the upstream reference kernel. All input-channel products are
// computed by the NPU (hw_simd_mac); the CPU only does loop control, address
// math, padding checks, bias, requantization, output offset and clamping.
//
// One hw_simd_mac call covers the filter depth of one filter tap. When the
// filter spans the whole input depth (no groups) and the width dilation is 1,
// the in-image taps of a filter row are contiguous in both the input and the
// filter tensor, so they are covered by a single call.
inline void ConvPerChannel(
    const ConvParams& params, const int32_t* output_multiplier,
    const int32_t* output_shift, const RuntimeShape& input_shape,
    const int8_t* input_data, const RuntimeShape& filter_shape,
    const int8_t* filter_data, const RuntimeShape& bias_shape,
    const int32_t* bias_data, const RuntimeShape& output_shape,
    int8_t* output_data) {
  // Get parameters.
  const int32_t input_offset = params.input_offset;  // r = s(q - Z)
  const int stride_width = params.stride_width;
  const int stride_height = params.stride_height;
  const int dilation_width_factor = params.dilation_width_factor;
  const int dilation_height_factor = params.dilation_height_factor;
  const int pad_width = params.padding_values.width;
  const int pad_height = params.padding_values.height;
  const int32_t output_offset = params.output_offset;

  // Set min and max value of the output.
  const int32_t output_activation_min = params.quantized_activation_min;
  const int32_t output_activation_max = params.quantized_activation_max;

  // Consistency check.
  TFLITE_DCHECK_LE(output_activation_min, output_activation_max);
  TFLITE_DCHECK_EQ(input_shape.DimensionsCount(), 4);
  TFLITE_DCHECK_EQ(filter_shape.DimensionsCount(), 4);
  TFLITE_DCHECK_EQ(output_shape.DimensionsCount(), 4);
  const int batches = MatchingDim(input_shape, 0, output_shape, 0);
  const int input_depth = input_shape.Dims(3);
  const int output_depth = MatchingDim(filter_shape, 0, output_shape, 3);
  if (bias_data) {
    TFLITE_DCHECK_EQ(bias_shape.FlatSize(), output_depth);
  }

  // Check dimensions of the tensors.
  const int input_height = input_shape.Dims(1);
  const int input_width = input_shape.Dims(2);
  const int filter_height = filter_shape.Dims(1);
  const int filter_width = filter_shape.Dims(2);
  const int filter_input_depth = filter_shape.Dims(3);
  const int groups = input_depth / filter_input_depth;
  TFLITE_DCHECK_EQ(input_depth % filter_input_depth, 0);
  const int filters_per_group = output_depth / groups;
  const int output_height = output_shape.Dims(1);
  const int output_width = output_shape.Dims(2);

  const int filter_row_stride = filter_width * filter_input_depth;
  const int filter_channel_stride = filter_height * filter_row_stride;
  const int input_row_stride = input_width * input_depth;
  const int input_batch_stride = input_height * input_row_stride;
  const bool merge_row_taps =
      (filter_input_depth == input_depth) && (dilation_width_factor == 1);

  for (int batch = 0; batch < batches; ++batch) {
    const int8_t* input_batch = input_data + batch * input_batch_stride;
    for (int out_y = 0; out_y < output_height; ++out_y) {
      const int in_y_origin = (out_y * stride_height) - pad_height;
      for (int out_x = 0; out_x < output_width; ++out_x) {
        const int in_x_origin = (out_x * stride_width) - pad_width;
        int8_t* output_pixel =
            output_data + Offset(output_shape, batch, out_y, out_x, 0);
        for (int out_channel = 0; out_channel < output_depth; ++out_channel) {
          const int group = out_channel / filters_per_group;
          const int8_t* input_group = input_batch + group * filter_input_depth;
          const int8_t* filter_channel =
              filter_data + out_channel * filter_channel_stride;
          int32_t acc = 0;
          for (int filter_y = 0; filter_y < filter_height; ++filter_y) {
            const int in_y = in_y_origin + dilation_height_factor * filter_y;
            if (in_y < 0 || in_y >= input_height) {
              continue;  // Zero padding: the whole filter row is outside.
            }
            const int8_t* input_row = input_group + in_y * input_row_stride;
            const int8_t* filter_row = filter_channel + filter_y * filter_row_stride;
            if (merge_row_taps) {
              // In-image taps: in_x = in_x_origin + filter_x in [0, width).
              const int first_x = std::max(0, -in_x_origin);
              const int end_x =
                  std::min(filter_width, input_width - in_x_origin);
              if (first_x < end_x) {
                acc += ConvDotProduct(
                    input_row + (in_x_origin + first_x) * input_depth,
                    filter_row + first_x * filter_input_depth, input_offset,
                    static_cast<uint32_t>((end_x - first_x) *
                                          filter_input_depth));
              }
              continue;
            }
            for (int filter_x = 0; filter_x < filter_width; ++filter_x) {
              const int in_x = in_x_origin + dilation_width_factor * filter_x;
              if (in_x < 0 || in_x >= input_width) {
                continue;  // Zero padding.
              }
              acc += ConvDotProduct(input_row + in_x * input_depth,
                                    filter_row + filter_x * filter_input_depth,
                                    input_offset,
                                    static_cast<uint32_t>(filter_input_depth));
            }
          }
          if (bias_data) {
            acc += bias_data[out_channel];
          }
          acc = MultiplyByQuantizedMultiplier(
              acc, output_multiplier[out_channel], output_shift[out_channel]);
          acc += output_offset;
          acc = std::max(acc, output_activation_min);
          acc = std::min(acc, output_activation_max);
          output_pixel[out_channel] = static_cast<int8_t>(acc);
        }
      }
    }
  }
}

inline void ConvPerChannelWithPackedInt4Weights(
    const ConvParams& params, const int32_t* output_multiplier,
    const int32_t* output_shift, const RuntimeShape& input_shape,
    const int8_t* input_data, const RuntimeShape& filter_shape,
    const int8_t* filter_input, int8_t* unpacked_filter_data,
    const RuntimeShape& bias_shape, const int32_t* bias_data,
    const RuntimeShape& output_shape, int8_t* output_data) {
  TFLITE_DCHECK(unpacked_filter_data != nullptr);
  tflite::tensor_utils::UnpackDenseInt4IntoInt8(
      filter_input, filter_shape.FlatSize(), unpacked_filter_data);
  ConvPerChannel(params, output_multiplier, output_shift, input_shape,
                 input_data, filter_shape, unpacked_filter_data, bias_shape,
                 bias_data, output_shape, output_data);
}

// Fixed-point per-channel-quantization convolution reference kernel.
// 16-bit data and 8-bit filter
template <typename AccumScalar>
inline void ConvPerChannel(
    const ConvParams& params, const int32_t* output_multiplier,
    const int32_t* output_shift, const RuntimeShape& input_shape,
    const int16_t* input_data, const RuntimeShape& filter_shape,
    const int8_t* filter_data, const RuntimeShape& bias_shape,
    const AccumScalar* bias_data, const RuntimeShape& output_shape,
    int16_t* output_data) {
  // Get parameters.
  const int stride_width = params.stride_width;
  const int stride_height = params.stride_height;
  const int dilation_width_factor = params.dilation_width_factor;
  const int dilation_height_factor = params.dilation_height_factor;
  const int pad_width = params.padding_values.width;
  const int pad_height = params.padding_values.height;

  // Set min and max value of the output.
  const int32_t output_activation_min = params.quantized_activation_min;
  const int32_t output_activation_max = params.quantized_activation_max;

  // Consistency check.
  TFLITE_DCHECK_LE(output_activation_min, output_activation_max);
  TFLITE_DCHECK_EQ(input_shape.DimensionsCount(), 4);
  TFLITE_DCHECK_EQ(filter_shape.DimensionsCount(), 4);
  TFLITE_DCHECK_EQ(output_shape.DimensionsCount(), 4);
  const int batches = MatchingDim(input_shape, 0, output_shape, 0);
  const int input_depth = input_shape.Dims(3);
  const int output_depth = MatchingDim(filter_shape, 0, output_shape, 3);
  if (bias_data) {
    TFLITE_DCHECK_EQ(bias_shape.FlatSize(), output_depth);
  }

  // Check dimensions of the tensors.
  const int input_height = input_shape.Dims(1);
  const int input_width = input_shape.Dims(2);
  const int filter_height = filter_shape.Dims(1);
  const int filter_width = filter_shape.Dims(2);
  const int filter_input_depth = filter_shape.Dims(3);
  const int groups = input_depth / filter_input_depth;
  TFLITE_DCHECK_EQ(input_depth % filter_input_depth, 0);
  const int filters_per_group = output_depth / groups;
  const int output_height = output_shape.Dims(1);
  const int output_width = output_shape.Dims(2);
  for (int batch = 0; batch < batches; ++batch) {
    for (int out_y = 0; out_y < output_height; ++out_y) {
      const int in_y_origin = (out_y * stride_height) - pad_height;
      for (int out_x = 0; out_x < output_width; ++out_x) {
        const int in_x_origin = (out_x * stride_width) - pad_width;
        for (int out_channel = 0; out_channel < output_depth; ++out_channel) {
          auto group = out_channel / filters_per_group;
          AccumScalar acc = 0;
          for (int filter_y = 0; filter_y < filter_height; ++filter_y) {
            const int in_y = in_y_origin + dilation_height_factor * filter_y;
            for (int filter_x = 0; filter_x < filter_width; ++filter_x) {
              const int in_x = in_x_origin + dilation_width_factor * filter_x;

              // Zero padding by omitting the areas outside the image.
              const bool is_point_inside_image =
                  (in_x >= 0) && (in_x < input_width) && (in_y >= 0) &&
                  (in_y < input_height);

              if (!is_point_inside_image) {
                continue;
              }

              for (int in_channel = 0; in_channel < filter_input_depth;
                   ++in_channel) {
                int32_t input_val =
                    input_data[Offset(input_shape, batch, in_y, in_x,
                                      in_channel + group * filter_input_depth)];
                int32_t filter_val = filter_data[Offset(
                    filter_shape, out_channel, filter_y, filter_x, in_channel)];
                // Accumulate with 64 bits accumulator.
                // int64_t += int8_t * int16_t so the highest value we can
                // get from each accumulation is [-127, 127] * ([-32768,
                // 32767] -
                // [-32768, 32767]), which is [-8322945, 8322945].
                // log2(8322945) = 22.99.
                acc += filter_val * input_val;
              }
            }
          }
          if (bias_data) {
            acc += bias_data[out_channel];
          }
          int32_t scaled_acc = MultiplyByQuantizedMultiplier(
              acc, output_multiplier[out_channel], output_shift[out_channel]);
          scaled_acc = std::max(scaled_acc, output_activation_min);
          scaled_acc = std::min(scaled_acc, output_activation_max);
          output_data[Offset(output_shape, batch, out_y, out_x, out_channel)] =
              static_cast<int16_t>(scaled_acc);
        }
      }
    }
  }
}

}  // namespace reference_integer_ops
}  // namespace tflite

#endif  // TENSORFLOW_LITE_KERNELS_INTERNAL_REFERENCE_INTEGER_OPS_CONV_H_
