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

// These helpers are implemented in the submitted lab2_api.cc. Declare them
// here so the two submitted software files work with the stock lab2_api.h;
// all channel products still call its unchanged, sole C hw_simd_mac entry.
extern "C" {
int32_t lab2_prepared_mac(const int8_t* ptr1, const int8_t* ptr2,
                          int32_t input_offset, uint32_t n, bool precleaned);
void lab2_clean_operands(const void* a, uint32_t a_bytes,
                         const void* b, uint32_t b_bytes);
void lab2_reuse_arm(void);
void lab2_conv_reset(void);
}

namespace tflite {
namespace reference_integer_ops {

// Stack-only ownership of the single NPU. Reset on entry also cancels stale
// caller state; the destructor covers every return (including empty outputs,
// the pointwise early return, aliased tensors, and the int16 overload).
class ConvMacScope {
 public:
  ConvMacScope() { lab2_conv_reset(); }
  ~ConvMacScope() { lab2_conv_reset(); }
  ConvMacScope(const ConvMacScope&) = delete;
  ConvMacScope& operator=(const ConvMacScope&) = delete;
};

// All input/filter channel products use the real C MAC entry point. The
// preparation adapter records a one-shot wide offset/clean promise, then
// tail-calls the actual non-inlined C definition; it contains no MAC body.
// Bound individual calls to 4096 bytes; split N advances BOTH operands and
// adds partials modulo 2^32. No CPU channel multiplication is used.
inline int32_t ConvDotProduct(const int8_t* input, const int8_t* filter,
                              int32_t input_offset, uint32_t n,
                              bool precleaned = false) {
  TFLITE_DCHECK_GE(input_offset, -256);
  TFLITE_DCHECK_LE(input_offset, 255);
  constexpr uint32_t kMaxMacBytes = 4096;
  uint32_t acc = 0;
  for (uint32_t done = 0; done < n;) {
    const uint32_t count = std::min(kMaxMacBytes, n - done);
    acc += static_cast<uint32_t>(lab2_prepared_mac(
        input + done, filter + done, input_offset, count, precleaned));
    done += count;
  }
  return static_cast<int32_t>(acc);
}

// An int16 value is 256*high + (low + 128), with high/low both signed int8.
// Form both byte-plane dot products on the NPU, then scale/add their sums.
// The scratch arrays change every chunk, so these calls are never precleaned
// or reuse-armed. At most 256 terms keeps each partial safely within int32.
inline int64_t ConvDotProduct16(const int16_t* input, const int8_t* filter,
                                uint32_t n) {
  constexpr uint32_t kChunk = 256;
  alignas(4) int8_t high[kChunk], low[kChunk];
  int64_t acc = 0;
  for (uint32_t done = 0; done < n;) {
    const uint32_t count = std::min(kChunk, n - done);
    for (uint32_t i = 0; i < count; ++i) {
      const uint16_t bits = static_cast<uint16_t>(input[done + i]);
      const int upper = bits >> 8;
      high[i] = static_cast<int8_t>(upper < 128 ? upper : upper - 256);
      low[i] = static_cast<int8_t>(static_cast<int>(bits & 255) - 128);
    }
    const int32_t lo = ConvDotProduct(low, filter + done, 128, count);
    const int32_t hi = ConvDotProduct(high, filter + done, 0, count);
    acc += static_cast<int64_t>(lo) + 256 * static_cast<int64_t>(hi);
    done += count;
  }
  return acc;
}

// Fixed-point per-channel-quantization convolution kernel. The result is
// identical to the upstream reference kernel. All input-channel products are
// computed by the NPU (hw_simd_mac); the CPU only does loop control, address
// math, padding checks, bias, requantization, output offset and clamping.
//
// One hw_simd_mac call covers up to 4096 channels of one filter tap. When
// the filter spans the input depth (no groups) and width dilation is 1,
// in-image taps of a filter row are contiguous in both operands, so a full
// row is merged before applying the same 4096-byte split.
//
// input_offset = 128 (int8 zero point -128) stays int32_t through
// lab2_prepared_mac -> hw_simd_mac -> CUSTOM-0 SET9 (funct3=4, funct7=5).
// The prepared command is consumed even on an empty MAC, and the stack scope
// clears it and hardware reuse on every convolution exit.
inline void ConvPerChannel(
    const ConvParams& params, const int32_t* output_multiplier,
    const int32_t* output_shift, const RuntimeShape& input_shape,
    const int8_t* input_data, const RuntimeShape& filter_shape,
    const int8_t* filter_data, const RuntimeShape& bias_shape,
    const int32_t* bias_data, const RuntimeShape& output_shape,
    int8_t* output_data) {
  const ConvMacScope mac_scope;
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
  // With a 1x1, stride-1 filter and zero padding, every output maps to an
  // in-bounds input pixel. The dedicated path below increments the input and
  // output pointers across each row and hoists channel-invariant addresses and
  // quantization parameters out of the output-x loop.
  const bool pointwise_fast_path =
      (filter_height == 1) && (filter_width == 1) && (stride_height == 1) &&
      (stride_width == 1) && (pad_height == 0) && (pad_width == 0) &&
      (output_height <= input_height) && (output_width <= input_width);

  // Write the input and filter tensors back once; the output must not
  // overlap them because it is stored to while they are declared clean.
  const uintptr_t input_begin = reinterpret_cast<uintptr_t>(input_data);
  const uintptr_t input_end =
      input_begin + static_cast<uint32_t>(batches * input_batch_stride);
  const uintptr_t filter_begin = reinterpret_cast<uintptr_t>(filter_data);
  const uintptr_t filter_end =
      filter_begin + static_cast<uint32_t>(output_depth * filter_channel_stride);
  const uintptr_t output_begin = reinterpret_cast<uintptr_t>(output_data);
  const uintptr_t output_end =
      output_begin + static_cast<uint32_t>(output_shape.FlatSize());
  const bool output_disjoint =
      (output_end <= input_begin || output_begin >= input_end) &&
      (output_end <= filter_begin || output_begin >= filter_end);
  if (output_disjoint) {
    lab2_clean_operands(input_data,
                        static_cast<uint32_t>(input_end - input_begin),
                        filter_data,
                        static_cast<uint32_t>(filter_end - filter_begin));
  }

  // Arm ptr1 reuse only for the precleaned (output-disjoint) case: the input
  // tensor was written back once above and is not stored to before the
  // matching disarm, so bytes the NPU fetched over AXI during this call stay
  // equal to memory.
  if (output_disjoint) {
    lab2_reuse_arm();
  }

  // Keep the original pixel-major ordering for aliased tensors: the fast
  // path changes the channel/width loop order and is safe only when output is
  // disjoint from both inputs and filters.
  if (pointwise_fast_path && output_disjoint) {
    // Pixel-major: all output channels of one pixel use the same input
    // vector (ptr1) and N back to back, so the NPU reuses its ptr1 bytes and
    // bursts only each channel's filter (ptr2).
    const int output_row_stride = output_width * output_depth;
    const int output_batch_stride = output_height * output_row_stride;
    const uint32_t n = static_cast<uint32_t>(filter_input_depth);
    for (int batch = 0; batch < batches; ++batch) {
      const int8_t* input_batch = input_data + batch * input_batch_stride;
      int8_t* output_batch = output_data + batch * output_batch_stride;
      for (int out_y = 0; out_y < output_height; ++out_y) {
        const int8_t* input_pixel = input_batch + out_y * input_row_stride;
        int8_t* output_pixel = output_batch + out_y * output_row_stride;
        for (int out_x = 0; out_x < output_width; ++out_x) {
          const int8_t* filter_channel = filter_data;
          const int8_t* input_group = input_pixel;
          int in_group = 0;
          for (int out_channel = 0; out_channel < output_depth; ++out_channel) {
            int32_t acc = ConvDotProduct(input_group, filter_channel,
                                         input_offset, n, true);
            if (bias_data) {
              acc += bias_data[out_channel];
            }
            acc = MultiplyByQuantizedMultiplier(
                acc, output_multiplier[out_channel], output_shift[out_channel]);
            acc += output_offset;
            acc = std::max(acc, output_activation_min);
            acc = std::min(acc, output_activation_max);
            output_pixel[out_channel] = static_cast<int8_t>(acc);
            filter_channel += filter_channel_stride;
            if (++in_group == filters_per_group) {
              in_group = 0;
              input_group += filter_input_depth;
            }
          }
          input_pixel += input_depth;
          output_pixel += output_depth;
        }
      }
    }
    return;  // mac_scope cancels preparation and disarms both operand caches
  }

  // Reorder only immutable, unpadded, non-grouped multirow windows whose
  // rows fit one MAC. Borders and all other cases retain the reference order.
  const bool block_full_rows =
      output_disjoint && merge_row_taps && pad_height == 0 && pad_width == 0 &&
      filter_height > 1 && filter_row_stride > 0 && filter_row_stride <= 4096 &&
      stride_height > 0 && stride_width > 0 && dilation_height_factor > 0;

  for (int batch = 0; batch < batches; ++batch) {
    const int8_t* input_batch = input_data + batch * input_batch_stride;
    for (int out_y = 0; out_y < output_height; ++out_y) {
      const int in_y_origin = (out_y * stride_height) - pad_height;
      for (int out_x = 0; out_x < output_width; ++out_x) {
        const int in_x_origin = (out_x * stride_width) - pad_width;
        // Merge rows only when the complete filter window is in bounds.
        // Border output positions use the reference per-tap bounds checks.
        const int last_in_y =
            in_y_origin + (filter_height - 1) * dilation_height_factor;
        const bool merge_full_rows =
            merge_row_taps && in_x_origin >= 0 &&
            in_x_origin + filter_width <= input_width && in_y_origin >= 0 &&
            last_in_y < input_height;
        int8_t* output_pixel =
            output_data + Offset(output_shape, batch, out_y, out_x, 0);
        if (block_full_rows && merge_full_rows &&
            (batch != 0 || out_y != 0 || out_x != 0)) {
          // The first pixel uses the original order below, populating the
          // contiguous filter cache with genuine work (no dummy products).
          // Each later row is reused across a bounded channel block. These
          // are transient NPU partial sums, never copied operands or cached
          // final outputs. Output stores remain in reference channel order.
          TFLITE_DCHECK_GE(input_offset, -256);
          TFLITE_DCHECK_LE(input_offset, 255);
          constexpr int kOutputBlock = 32;
          uint32_t partial[kOutputBlock];
          const uint32_t n = static_cast<uint32_t>(filter_row_stride);
          for (int base = 0; base < output_depth; base += kOutputBlock) {
            const int count = std::min(kOutputBlock, output_depth - base);
            for (int i = 0; i < count; ++i) partial[i] = 0;
            for (int filter_y = 0; filter_y < filter_height; ++filter_y) {
              const int in_y = in_y_origin + dilation_height_factor * filter_y;
              const int8_t* input_row = input_batch + in_y * input_row_stride +
                                        in_x_origin * input_depth;
              const int8_t* filter_row = filter_data + base * filter_channel_stride +
                                         filter_y * filter_row_stride;
              for (int i = 0; i < count; ++i) {
                // block_full_rows already guarantees 1 <= n <= 4096:
                // skip only the redundant chunk loop, never the real C MAC.
                partial[i] += static_cast<uint32_t>(lab2_prepared_mac(
                    input_row, filter_row + i * filter_channel_stride,
                    input_offset, n, true));
              }
            }
            for (int i = 0; i < count; ++i) {
              const int out_channel = base + i;
              int32_t acc = static_cast<int32_t>(partial[i]);
              if (bias_data) acc += bias_data[out_channel];
              acc = MultiplyByQuantizedMultiplier(
                  acc, output_multiplier[out_channel], output_shift[out_channel]);
              acc += output_offset;
              acc = std::max(acc, output_activation_min);
              acc = std::min(acc, output_activation_max);
              output_pixel[out_channel] = static_cast<int8_t>(acc);
            }
          }
          continue;
        }
        for (int out_channel = 0; out_channel < output_depth; ++out_channel) {
          const int group = out_channel / filters_per_group;
          const int8_t* input_group = input_batch + group * filter_input_depth;
          const int8_t* filter_channel =
              filter_data + out_channel * filter_channel_stride;
          int32_t acc = 0;
          if (merge_full_rows) {
            for (int filter_y = 0; filter_y < filter_height; ++filter_y) {
              const int in_y = in_y_origin + dilation_height_factor * filter_y;
              const int8_t* input_row = input_group + in_y * input_row_stride;
              const int8_t* filter_row =
                  filter_channel + filter_y * filter_row_stride;
              const uint32_t n = static_cast<uint32_t>(filter_row_stride);
              acc += ConvDotProduct(input_row + in_x_origin * input_depth,
                                    filter_row, input_offset, n, output_disjoint);
            }
          } else {
            for (int filter_y = 0; filter_y < filter_height; ++filter_y) {
              const int in_y = in_y_origin + dilation_height_factor * filter_y;
              if (in_y < 0 || in_y >= input_height) {
                continue;  // Zero padding: the whole filter row is outside.
              }
              const int8_t* input_row = input_group + in_y * input_row_stride;
              const int8_t* filter_row =
                  filter_channel + filter_y * filter_row_stride;
              for (int filter_x = 0; filter_x < filter_width; ++filter_x) {
                const int in_x =
                    in_x_origin + dilation_width_factor * filter_x;
                if (in_x < 0 || in_x >= input_width) {
                  continue;  // Zero padding.
                }
                const int8_t* in = input_row + in_x * input_depth;
                const int8_t* flt =
                    filter_row + filter_x * filter_input_depth;
                const uint32_t n =
                    static_cast<uint32_t>(filter_input_depth);
                acc += ConvDotProduct(in, flt, input_offset, n, output_disjoint);
              }
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

}  // mac_scope resets state even when output aliases an operand


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
  const ConvMacScope mac_scope;
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

              const int16_t* in = input_data + Offset(
                  input_shape, batch, in_y, in_x, group * filter_input_depth);
              const int8_t* flt = filter_data + Offset(
                  filter_shape, out_channel, filter_y, filter_x, 0);
              acc += static_cast<AccumScalar>(ConvDotProduct16(
                  in, flt, static_cast<uint32_t>(filter_input_depth)));
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
