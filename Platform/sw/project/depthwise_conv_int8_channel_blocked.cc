// Int8 depthwise convolution kernel; see depthwise_conv_int8_channel_blocked.h.
// Built only in TFLM builds (the TFLM sources are not prepared otherwise).
#if defined(TFLM_MODEL_ENABLED)

#include "depthwise_conv_int8_channel_blocked.h"

#include <algorithm>

#include "tensorflow/lite/kernels/internal/common.h"
#include "tensorflow/lite/kernels/internal/reference/integer_ops/depthwise_conv.h"

namespace tflite {
namespace {

// Shapes beyond these capacities use the upstream reference kernel.
constexpr int kDepthwiseChannelCapacity = 2048;
constexpr int kDepthwiseTapCapacity = 256;

// Per call: bias + input_offset * (sum of the channel's filter over the whole
// filter window).
int32_t g_full_window_bias[kDepthwiseChannelCapacity];
// Per output pixel: input pixel and filter tap of every in-image filter tap.
const int8_t* g_tap_input[kDepthwiseTapCapacity];
const int8_t* g_tap_filter[kDepthwiseTapCapacity];

inline int8_t RequantizeDepthwiseAccumulator(int32_t acc, int32_t multiplier,
                                             int32_t shift,
                                             int32_t output_offset,
                                             int32_t activation_min,
                                             int32_t activation_max) {
  acc = MultiplyByQuantizedMultiplier(acc, multiplier, shift);
  acc += output_offset;
  acc = std::max(acc, activation_min);
  acc = std::min(acc, activation_max);
  return static_cast<int8_t>(acc);
}

// Depth multiplier 1, whole filter window inside the image: eight channels
// per pass with the accumulators in registers.
void AccumulateFullWindowDepthMultiplierOne(
    int tap_count, int depth, const int32_t* output_multiplier,
    const int32_t* output_shift, int32_t output_offset,
    int32_t activation_min, int32_t activation_max, int8_t* output_pixel) {
  const int8_t* const* const tap_input_end = g_tap_input + tap_count;
  int channel = 0;
  for (; channel + 8 <= depth; channel += 8) {
    int32_t acc0 = g_full_window_bias[channel + 0];
    int32_t acc1 = g_full_window_bias[channel + 1];
    int32_t acc2 = g_full_window_bias[channel + 2];
    int32_t acc3 = g_full_window_bias[channel + 3];
    int32_t acc4 = g_full_window_bias[channel + 4];
    int32_t acc5 = g_full_window_bias[channel + 5];
    int32_t acc6 = g_full_window_bias[channel + 6];
    int32_t acc7 = g_full_window_bias[channel + 7];
    const int8_t* const* tap_filter = g_tap_filter;
    for (const int8_t* const* tap_input = g_tap_input;
         tap_input != tap_input_end; ++tap_input, ++tap_filter) {
      const int8_t* in = *tap_input + channel;
      const int8_t* f = *tap_filter + channel;
      acc0 += in[0] * f[0];
      acc1 += in[1] * f[1];
      acc2 += in[2] * f[2];
      acc3 += in[3] * f[3];
      acc4 += in[4] * f[4];
      acc5 += in[5] * f[5];
      acc6 += in[6] * f[6];
      acc7 += in[7] * f[7];
    }
    const int32_t accs[8] = {acc0, acc1, acc2, acc3, acc4, acc5, acc6, acc7};
    for (int i = 0; i < 8; ++i) {
      output_pixel[channel + i] = RequantizeDepthwiseAccumulator(
          accs[i], output_multiplier[channel + i], output_shift[channel + i],
          output_offset, activation_min, activation_max);
    }
  }
  for (; channel < depth; ++channel) {
    int32_t acc = g_full_window_bias[channel];
    for (int tap = 0; tap < tap_count; ++tap) {
      acc += g_tap_input[tap][channel] * g_tap_filter[tap][channel];
    }
    output_pixel[channel] = RequantizeDepthwiseAccumulator(
        acc, output_multiplier[channel], output_shift[channel], output_offset,
        activation_min, activation_max);
  }
}

// Any depth multiplier; the pixel may be at a padded border (tap_count <
// filter taps), in which case the reference form is used.
void AccumulateGeneral(int tap_count, bool full_window, int input_depth,
                       int depth_multiplier, int32_t input_offset,
                       const int32_t* bias_data,
                       const int32_t* output_multiplier,
                       const int32_t* output_shift, int32_t output_offset,
                       int32_t activation_min, int32_t activation_max,
                       int8_t* output_pixel) {
  for (int in_channel = 0; in_channel < input_depth; ++in_channel) {
    for (int m = 0; m < depth_multiplier; ++m) {
      const int out_channel = in_channel * depth_multiplier + m;
      int32_t acc;
      if (full_window) {
        acc = g_full_window_bias[out_channel];
        for (int tap = 0; tap < tap_count; ++tap) {
          acc += g_tap_input[tap][in_channel] * g_tap_filter[tap][out_channel];
        }
      } else {
        acc = bias_data ? bias_data[out_channel] : 0;
        for (int tap = 0; tap < tap_count; ++tap) {
          acc += g_tap_filter[tap][out_channel] *
                 (g_tap_input[tap][in_channel] + input_offset);
        }
      }
      output_pixel[out_channel] = RequantizeDepthwiseAccumulator(
          acc, output_multiplier[out_channel], output_shift[out_channel],
          output_offset, activation_min, activation_max);
    }
  }
}

}  // namespace

void DepthwiseConvInt8ChannelBlocked(
    const DepthwiseParams& params, const int32_t* output_multiplier,
    const int32_t* output_shift, const RuntimeShape& input_shape,
    const int8_t* input_data, const RuntimeShape& filter_shape,
    const int8_t* filter_data, const RuntimeShape& bias_shape,
    const int32_t* bias_data, const RuntimeShape& output_shape,
    int8_t* output_data) {
  const int stride_width = params.stride_width;
  const int stride_height = params.stride_height;
  const int dilation_width_factor = params.dilation_width_factor;
  const int dilation_height_factor = params.dilation_height_factor;
  const int pad_width = params.padding_values.width;
  const int pad_height = params.padding_values.height;
  const int depth_multiplier = params.depth_multiplier;
  const int32_t input_offset = params.input_offset;
  const int32_t output_offset = params.output_offset;
  const int32_t output_activation_min = params.quantized_activation_min;
  const int32_t output_activation_max = params.quantized_activation_max;

  TFLITE_DCHECK_EQ(input_shape.DimensionsCount(), 4);
  TFLITE_DCHECK_EQ(filter_shape.DimensionsCount(), 4);
  TFLITE_DCHECK_EQ(output_shape.DimensionsCount(), 4);
  TFLITE_DCHECK_LE(output_activation_min, output_activation_max);
  const int batches = MatchingDim(input_shape, 0, output_shape, 0);
  const int output_depth = MatchingDim(filter_shape, 3, output_shape, 3);
  const int input_height = input_shape.Dims(1);
  const int input_width = input_shape.Dims(2);
  const int input_depth = input_shape.Dims(3);
  const int filter_height = filter_shape.Dims(1);
  const int filter_width = filter_shape.Dims(2);
  const int output_height = output_shape.Dims(1);
  const int output_width = output_shape.Dims(2);
  TFLITE_DCHECK_EQ(output_depth, input_depth * depth_multiplier);
  TFLITE_DCHECK_EQ(bias_shape.FlatSize(), output_depth);
  const int filter_taps = filter_height * filter_width;

  if (output_depth > kDepthwiseChannelCapacity ||
      filter_taps > kDepthwiseTapCapacity) {
    reference_integer_ops::DepthwiseConvPerChannel(
        params, output_multiplier, output_shift, input_shape, input_data,
        filter_shape, filter_data, bias_shape, bias_data, output_shape,
        output_data);
    return;
  }

  for (int out_channel = 0; out_channel < output_depth; ++out_channel) {
    g_full_window_bias[out_channel] = bias_data ? bias_data[out_channel] : 0;
  }
  for (int tap = 0; tap < filter_taps; ++tap) {
    const int8_t* filter_tap = filter_data + tap * output_depth;
    for (int out_channel = 0; out_channel < output_depth; ++out_channel) {
      g_full_window_bias[out_channel] += input_offset * filter_tap[out_channel];
    }
  }

  const int input_row_stride = input_width * input_depth;
  const int input_batch_stride = input_height * input_row_stride;
  int8_t* output_pixel = output_data;
  for (int batch = 0; batch < batches; ++batch) {
    const int8_t* input_batch = input_data + batch * input_batch_stride;
    for (int out_y = 0; out_y < output_height; ++out_y) {
      const int in_y_origin = (out_y * stride_height) - pad_height;
      for (int out_x = 0; out_x < output_width; ++out_x) {
        const int in_x_origin = (out_x * stride_width) - pad_width;
        int tap_count = 0;
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
            g_tap_input[tap_count] =
                input_batch + in_y * input_row_stride + in_x * input_depth;
            g_tap_filter[tap_count] =
                filter_data + (filter_y * filter_width + filter_x) * output_depth;
            ++tap_count;
          }
        }
        const bool full_window = (tap_count == filter_taps);
        if (full_window && depth_multiplier == 1) {
          AccumulateFullWindowDepthMultiplierOne(
              tap_count, output_depth, output_multiplier, output_shift,
              output_offset, output_activation_min, output_activation_max,
              output_pixel);
        } else {
          AccumulateGeneral(tap_count, full_window, input_depth,
                            depth_multiplier, input_offset, bias_data,
                            output_multiplier, output_shift, output_offset,
                            output_activation_min, output_activation_max,
                            output_pixel);
        }
        output_pixel += output_depth;
      }
    }
  }
}

}  // namespace tflite

#endif  // TFLM_MODEL_ENABLED
