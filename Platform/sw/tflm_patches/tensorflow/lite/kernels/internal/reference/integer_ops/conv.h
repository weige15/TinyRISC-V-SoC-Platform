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
#include <stddef.h>
#include <stdint.h>

#include "cbo.h"
#include "cfu.h"
#include "tensorflow/lite/kernels/internal/common.h"
#include "tensorflow/lite/kernels/internal/portable_tensor_utils.h"

namespace tflite {
namespace reference_integer_ops {

// The data cache transfers 256-bit (32-byte) lines. Clean each line in the
// read-only convolution inputs once before the NPU reads them, rather than
// issuing two slow-path CBO operations for every four-channel MAC group.
constexpr size_t kDCacheLineBytes = 32;
inline void CleanTensorForAxi(const int8_t* data, size_t bytes) {
#if defined(__riscv)
  __asm__ volatile("fence rw, rw" ::: "memory");
  for (size_t offset = 0; offset < bytes; offset += kDCacheLineBytes) {
    cbo_clean(data + offset);
  }
  __asm__ volatile("fence rw, rw" ::: "memory");
#else
  (void)data;
  (void)bytes;
#endif
}

inline bool IsWordAligned(const int8_t* pointer) {
  return (reinterpret_cast<uintptr_t>(pointer) & 3u) == 0;
}

// Sum of the signed filter bytes that the SIMD MAC consumes for one filter
// tap. The SIMD MAC multiplies raw input bytes, so the convolution adds
// input_offset * (this sum) to obtain sum(filter * (input + input_offset)).
inline int32_t SumFilterBytes(const int8_t* filter_tap, int count) {
  int32_t sum = 0;
  for (int i = 0; i < count; ++i) sum += filter_tap[i];
  return sum;
}

// Per-(output channel, filter tap) filter byte sums, computed once per
// convolution call instead of once per four-channel group per output pixel.
constexpr int kFilterTapSumCapacity = 4096;
inline int32_t* FilterTapSumBuffer() {
  static int32_t filter_tap_sums[kFilterTapSumCapacity];
  return filter_tap_sums;
}

// Dot product of `simd_depth` (a multiple of four, > 0) int8 channels. Both
// operands are fetched by the NPU over AXI and multiplied by the SIMD MAC.
// SIMD lane k of the input word is paired with lane k of the filter word, so
// the AXI byte order can be used directly for both operands: the lane
// permutation is the same for both and does not change the dot product.
inline uint32_t AxiSimdDotProduct(const int8_t* input, const int8_t* filter,
                                  int simd_depth, bool continue_accumulator) {
  uint32_t input_word = cfu_op1(CFU_FUNCT7_AXI, (CfuWord)input, 0);
  uint32_t filter_word = cfu_op1(CFU_FUNCT7_AXI, (CfuWord)filter, 0);
  uint32_t result = continue_accumulator
                        ? cfu_simd_mac_accumulate(input_word, filter_word)
                        : cfu_simd_mac_reset(input_word, filter_word);
  for (int channel = 4; channel < simd_depth; channel += 4) {
    input_word = cfu_op1(CFU_FUNCT7_AXI, (CfuWord)(input + channel), 0);
    filter_word = cfu_op1(CFU_FUNCT7_AXI, (CfuWord)(filter + channel), 0);
    result = cfu_simd_mac_accumulate(input_word, filter_word);
  }
  return result;
}

// Fixed-point per-channel-quantization convolution kernel. Groups of four
// channels at word-aligned addresses are read by the NPU over AXI and
// multiplied by the SIMD MAC; remaining channels use the scalar reference
// arithmetic. The integer result is identical to the reference kernel.
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
  if (filter_shape.Dims(3) >= 4) {
    CleanTensorForAxi(input_data, input_shape.FlatSize());
    CleanTensorForAxi(filter_data, filter_shape.FlatSize());
  }

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

  // Channels [0, simd_depth) of each filter tap go through AXI + SIMD when
  // both operand addresses are word aligned; the rest are scalar.
  const int simd_depth = filter_input_depth >= 4 ? (filter_input_depth & ~3) : 0;
  const int filter_taps = filter_height * filter_width;
  const int filter_tap_stride = filter_input_depth;
  const int filter_channel_stride = filter_taps * filter_input_depth;
  const int input_row_stride = input_width * input_depth;
  const int input_batch_stride = input_height * input_row_stride;
  const int output_pixel_stride = output_depth;

  int32_t* filter_tap_sums = nullptr;
  if (simd_depth > 0 && output_depth * filter_taps <= kFilterTapSumCapacity) {
    filter_tap_sums = FilterTapSumBuffer();
    for (int out_channel = 0; out_channel < output_depth; ++out_channel) {
      for (int tap = 0; tap < filter_taps; ++tap) {
        filter_tap_sums[out_channel * filter_taps + tap] = SumFilterBytes(
            filter_data + out_channel * filter_channel_stride +
                tap * filter_tap_stride,
            simd_depth);
      }
    }
  }

  int8_t* output_pixel = output_data;
  for (int batch = 0; batch < batches; ++batch) {
    const int8_t* input_batch = input_data + batch * input_batch_stride;
    for (int out_y = 0; out_y < output_height; ++out_y) {
      const int in_y_origin = (out_y * stride_height) - pad_height;
      for (int out_x = 0; out_x < output_width; ++out_x) {
        const int in_x_origin = (out_x * stride_width) - pad_width;
        for (int out_channel = 0; out_channel < output_depth; ++out_channel) {
          const int group = out_channel / filters_per_group;
          const int8_t* input_group_base =
              input_batch + group * filter_input_depth;
          const int8_t* filter_channel =
              filter_data + out_channel * filter_channel_stride;
          int32_t acc = 0;
          int32_t input_offset_correction = 0;
          uint32_t simd_result = 0;
          bool simd_accumulator_started = false;
          for (int filter_y = 0; filter_y < filter_height; ++filter_y) {
            const int in_y = in_y_origin + dilation_height_factor * filter_y;
            if (in_y < 0 || in_y >= input_height) {
              continue;  // Zero padding.
            }
            for (int filter_x = 0; filter_x < filter_width; ++filter_x) {
              const int in_x = in_x_origin + dilation_width_factor * filter_x;
              if (in_x < 0 || in_x >= input_width) {
                continue;  // Zero padding.
              }
              const int tap = filter_y * filter_width + filter_x;
              const int8_t* input_tap =
                  input_group_base + in_y * input_row_stride + in_x * input_depth;
              const int8_t* filter_tap = filter_channel + tap * filter_tap_stride;

              int first_scalar_channel = 0;
              if (simd_depth > 0 && IsWordAligned(input_tap) &&
                  IsWordAligned(filter_tap)) {
                simd_result = AxiSimdDotProduct(input_tap, filter_tap, simd_depth,
                                                simd_accumulator_started);
                simd_accumulator_started = true;
                input_offset_correction +=
                    input_offset *
                    (filter_tap_sums != nullptr
                         ? filter_tap_sums[out_channel * filter_taps + tap]
                         : SumFilterBytes(filter_tap, simd_depth));
                first_scalar_channel = simd_depth;
              }
              for (int in_channel = first_scalar_channel;
                   in_channel < filter_input_depth; ++in_channel) {
                const int32_t input_val = input_tap[in_channel];
                const int32_t filter_val = filter_tap[in_channel];
                acc += filter_val * (input_val + input_offset);
              }
            }
          }

          if (simd_accumulator_started) {
            acc += static_cast<int32_t>(simd_result);
          }
          acc += input_offset_correction;
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
        output_pixel += output_pixel_stride;
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
