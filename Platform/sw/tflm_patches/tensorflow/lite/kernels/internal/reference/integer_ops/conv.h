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

// NPU burst dot product (CUSTOM-0 funct3 = 4, Platform/hw/srcs/
// npu_burst_dot_product.v):
//   funct7 = 0: set the vector length in bytes (rs1).
//   funct7 = 1: rd = sum int8(input[i]) * int8(filter[i]) for i < length,
//               with rs1 = input address and rs2 = filter address. The NPU
//               streams both vectors with AXI INCR bursts; any byte address
//               and length are allowed.
#define NPU_FUNCT3_BURST_DOT_PRODUCT 4
#define NPU_FUNCT7_BURST_DOT_PRODUCT_SET_LENGTH 0
#define NPU_FUNCT7_BURST_DOT_PRODUCT_COMPUTE 1

#if defined(__riscv) && !defined(CFU_SOFTWARE_DEFINED)
#define NPU_BURST_DOT_PRODUCT_IN_HARDWARE 1
#else
#define NPU_BURST_DOT_PRODUCT_IN_HARDWARE 0
#endif

namespace tflite {
namespace reference_integer_ops {

// The data cache transfers 256-bit (32-byte) lines.
constexpr size_t kDCacheLineBytes = 32;

// Writes back every data-cache line that overlaps [data, data + bytes), so
// the NPU, which reads memory directly over AXI, sees the CPU's latest
// stores. The first and last lines are included even when `data` or the end
// of the range is not line aligned.
inline void CleanDataCacheRangeForNpu(const void* data, size_t bytes) {
#if defined(__riscv)
  if (bytes == 0) {
    return;
  }
  uintptr_t line = reinterpret_cast<uintptr_t>(data) &
                   ~static_cast<uintptr_t>(kDCacheLineBytes - 1);
  const uintptr_t end = reinterpret_cast<uintptr_t>(data) + bytes;
  __asm__ volatile("fence rw, rw" ::: "memory");
  for (; line < end; line += kDCacheLineBytes) {
    cbo_clean(reinterpret_cast<const volatile void*>(line));
  }
  __asm__ volatile("fence rw, rw" ::: "memory");
#else
  (void)data;
  (void)bytes;
#endif
}

// Software model of the NPU length register, used when the instruction is
// not issued (host builds and CFU_SOFTWARE_DEFINED builds).
inline uint32_t& NpuBurstDotProductModelLength() {
  static uint32_t length = 0;
  return length;
}

inline void NpuBurstDotProductSetLength(uint32_t bytes) {
#if NPU_BURST_DOT_PRODUCT_IN_HARDWARE
  (void)cfu_raw_op_hw(NPU_FUNCT3_BURST_DOT_PRODUCT,
                      NPU_FUNCT7_BURST_DOT_PRODUCT_SET_LENGTH, bytes, 0);
#else
  NpuBurstDotProductModelLength() = bytes;
#endif
}

// Signed int8 dot product of the `length` bytes at `input` and `filter`,
// computed by the NPU from AXI bursts. The caller must have cleaned both
// ranges out of the data cache.
inline int32_t NpuBurstDotProduct(const int8_t* input, const int8_t* filter) {
#if NPU_BURST_DOT_PRODUCT_IN_HARDWARE
  return static_cast<int32_t>(
      cfu_raw_op_hw(NPU_FUNCT3_BURST_DOT_PRODUCT,
                    NPU_FUNCT7_BURST_DOT_PRODUCT_COMPUTE, input, filter));
#else
  const uint32_t length = NpuBurstDotProductModelLength();
  int32_t sum = 0;
  for (uint32_t i = 0; i < length; ++i) {
    sum += static_cast<int32_t>(input[i]) * static_cast<int32_t>(filter[i]);
  }
  return sum;
#endif
}

// Filter taps with at least this many channels use the NPU burst dot
// product; shallower taps are cheaper on the CPU than one AXI round trip.
constexpr int kBurstDotProductMinDepth = 8;

inline int32_t SumFilterBytes(const int8_t* filter_tap, int count) {
  int32_t sum = 0;
  for (int i = 0; i < count; ++i) sum += filter_tap[i];
  return sum;
}

// Per-(output channel, filter tap) filter byte sums, computed once per
// convolution call. The NPU multiplies raw input bytes, so the kernel adds
// input_offset * (filter sum) to obtain sum(filter * (input + input_offset)).
constexpr int kFilterTapSumCapacity = 4096;
inline int32_t* FilterTapSumBuffer() {
  static int32_t filter_tap_sums[kFilterTapSumCapacity];
  return filter_tap_sums;
}

// One output pixel's input patch (filter taps x filter depth), with the input
// offset added and zeros for taps outside the image. Used when the filter
// depth is below kBurstDotProductMinDepth.
constexpr int kInputPatchCapacity = 1024;
inline int32_t* InputPatchBuffer() {
  static int32_t input_patch[kInputPatchCapacity];
  return input_patch;
}

inline int8_t RequantizeConvAccumulator(int32_t acc, int32_t multiplier,
                                        int32_t shift, int32_t output_offset,
                                        int32_t activation_min,
                                        int32_t activation_max) {
  acc = MultiplyByQuantizedMultiplier(acc, multiplier, shift);
  acc += output_offset;
  acc = std::max(acc, activation_min);
  acc = std::min(acc, activation_max);
  return static_cast<int8_t>(acc);
}

// Fixed-point per-channel-quantization convolution kernel. The integer
// result is identical to the upstream reference kernel:
//   * filter depth >= kBurstDotProductMinDepth: every in-image filter tap is
//     one NPU burst dot product over the filter depth, plus a precomputed
//     input_offset * sum(filter) correction;
//   * shallower filters: the pixel's input patch is gathered once per group
//     and reused for every output channel of that group;
//   * otherwise (patch larger than the buffer): reference arithmetic.
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

  const int filter_taps = filter_height * filter_width;
  const int filter_channel_stride = filter_taps * filter_input_depth;
  const int input_row_stride = input_width * input_depth;
  const int input_batch_stride = input_height * input_row_stride;

  if (filter_input_depth >= kBurstDotProductMinDepth) {
    CleanDataCacheRangeForNpu(input_data, input_shape.FlatSize());
    CleanDataCacheRangeForNpu(filter_data, filter_shape.FlatSize());
    NpuBurstDotProductSetLength(static_cast<uint32_t>(filter_input_depth));

    int32_t* filter_tap_sums = nullptr;
    if (output_depth * filter_taps <= kFilterTapSumCapacity) {
      filter_tap_sums = FilterTapSumBuffer();
      for (int i = 0; i < output_depth * filter_taps; ++i) {
        filter_tap_sums[i] = SumFilterBytes(
            filter_data + i * filter_input_depth, filter_input_depth);
      }
    }

    int8_t* output_pixel = output_data;
    for (int batch = 0; batch < batches; ++batch) {
      const int8_t* input_batch = input_data + batch * input_batch_stride;
      for (int out_y = 0; out_y < output_height; ++out_y) {
        const int in_y_origin = (out_y * stride_height) - pad_height;
        for (int out_x = 0; out_x < output_width; ++out_x) {
          const int in_x_origin = (out_x * stride_width) - pad_width;
          const int8_t* input_group = input_batch;
          int group_end = filters_per_group;
          const int8_t* filter_channel = filter_data;
          const int32_t* channel_tap_sums = filter_tap_sums;
          for (int out_channel = 0; out_channel < output_depth;
               ++out_channel) {
            if (out_channel == group_end) {
              group_end += filters_per_group;
              input_group += filter_input_depth;
            }
            int32_t acc = 0;
            int32_t filter_sum = 0;
            for (int filter_y = 0; filter_y < filter_height; ++filter_y) {
              const int in_y = in_y_origin + dilation_height_factor * filter_y;
              if (in_y < 0 || in_y >= input_height) {
                continue;  // Zero padding.
              }
              const int8_t* input_row = input_group + in_y * input_row_stride;
              for (int filter_x = 0; filter_x < filter_width; ++filter_x) {
                const int in_x = in_x_origin + dilation_width_factor * filter_x;
                if (in_x < 0 || in_x >= input_width) {
                  continue;  // Zero padding.
                }
                const int tap = filter_y * filter_width + filter_x;
                const int8_t* filter_tap =
                    filter_channel + tap * filter_input_depth;
                acc += NpuBurstDotProduct(input_row + in_x * input_depth,
                                          filter_tap);
                filter_sum += channel_tap_sums != nullptr
                                  ? channel_tap_sums[tap]
                                  : SumFilterBytes(filter_tap,
                                                   filter_input_depth);
              }
            }
            acc += input_offset * filter_sum;
            if (bias_data) {
              acc += bias_data[out_channel];
            }
            output_pixel[out_channel] = RequantizeConvAccumulator(
                acc, output_multiplier[out_channel], output_shift[out_channel],
                output_offset, output_activation_min, output_activation_max);
            filter_channel += filter_channel_stride;
            if (channel_tap_sums != nullptr) {
              channel_tap_sums += filter_taps;
            }
          }
          output_pixel += output_depth;
        }
      }
    }
    return;
  }

  if (filter_channel_stride <= kInputPatchCapacity) {
    int32_t* input_patch = InputPatchBuffer();
    int8_t* output_pixel = output_data;
    for (int batch = 0; batch < batches; ++batch) {
      const int8_t* input_batch = input_data + batch * input_batch_stride;
      for (int out_y = 0; out_y < output_height; ++out_y) {
        const int in_y_origin = (out_y * stride_height) - pad_height;
        for (int out_x = 0; out_x < output_width; ++out_x) {
          const int in_x_origin = (out_x * stride_width) - pad_width;
          for (int group = 0; group < groups; ++group) {
            int32_t* patch = input_patch;
            for (int filter_y = 0; filter_y < filter_height; ++filter_y) {
              const int in_y = in_y_origin + dilation_height_factor * filter_y;
              for (int filter_x = 0; filter_x < filter_width; ++filter_x) {
                const int in_x = in_x_origin + dilation_width_factor * filter_x;
                if (in_y < 0 || in_y >= input_height || in_x < 0 ||
                    in_x >= input_width) {
                  for (int c = 0; c < filter_input_depth; ++c) patch[c] = 0;
                } else {
                  const int8_t* input_tap = input_batch +
                                            in_y * input_row_stride +
                                            in_x * input_depth +
                                            group * filter_input_depth;
                  for (int c = 0; c < filter_input_depth; ++c) {
                    patch[c] = input_tap[c] + input_offset;
                  }
                }
                patch += filter_input_depth;
              }
            }
            const int first_channel = group * filters_per_group;
            const int8_t* filter_channel =
                filter_data + first_channel * filter_channel_stride;
            for (int out_channel = first_channel;
                 out_channel < first_channel + filters_per_group;
                 ++out_channel) {
              int32_t acc = 0;
              for (int i = 0; i < filter_channel_stride; ++i) {
                acc += input_patch[i] * filter_channel[i];
              }
              if (bias_data) {
                acc += bias_data[out_channel];
              }
              output_pixel[out_channel] = RequantizeConvAccumulator(
                  acc, output_multiplier[out_channel],
                  output_shift[out_channel], output_offset,
                  output_activation_min, output_activation_max);
              filter_channel += filter_channel_stride;
            }
          }
          output_pixel += output_depth;
        }
      }
    }
    return;
  }

  // Reference arithmetic for shallow filters with very large patches.
  for (int batch = 0; batch < batches; ++batch) {
    for (int out_y = 0; out_y < output_height; ++out_y) {
      const int in_y_origin = (out_y * stride_height) - pad_height;
      for (int out_x = 0; out_x < output_width; ++out_x) {
        const int in_x_origin = (out_x * stride_width) - pad_width;
        for (int out_channel = 0; out_channel < output_depth; ++out_channel) {
          auto group = out_channel / filters_per_group;
          int32_t acc = 0;
          for (int filter_y = 0; filter_y < filter_height; ++filter_y) {
            const int in_y = in_y_origin + dilation_height_factor * filter_y;
            for (int filter_x = 0; filter_x < filter_width; ++filter_x) {
              const int in_x = in_x_origin + dilation_width_factor * filter_x;
              const bool is_point_inside_image =
                  (in_x >= 0) && (in_x < input_width) && (in_y >= 0) &&
                  (in_y < input_height);
              if (!is_point_inside_image) {
                continue;
              }
              for (int in_channel = 0; in_channel < filter_input_depth;
                   ++in_channel) {
                const int32_t input_val = input_data[Offset(
                    input_shape, batch, in_y, in_x,
                    in_channel + group * filter_input_depth)];
                const int32_t filter_val = filter_data[Offset(
                    filter_shape, out_channel, filter_y, filter_x, in_channel)];
                acc += filter_val * (input_val + input_offset);
              }
            }
          }
          if (bias_data) {
            acc += bias_data[out_channel];
          }
          output_data[Offset(output_shape, batch, out_y, out_x, out_channel)] =
              RequantizeConvAccumulator(
                  acc, output_multiplier[out_channel],
                  output_shift[out_channel], output_offset,
                  output_activation_min, output_activation_max);
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
