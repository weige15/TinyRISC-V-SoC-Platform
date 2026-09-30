// TFLM registration for DEPTHWISE_CONV_2D that runs
// DepthwiseConvInt8ChannelBlocked for int8 input with int8 filter and the
// upstream TFLM kernel for every other type combination. Init and Prepare are
// the upstream ones, so node data (OpDataConv) is shared with the fallback.
// Built only in TFLM builds.
#if defined(TFLM_MODEL_ENABLED)

#include "depthwise_conv_int8_channel_blocked.h"

#include "tensorflow/lite/c/builtin_op_data.h"
#include "tensorflow/lite/c/common.h"
#include "tensorflow/lite/kernels/kernel_util.h"
#include "tensorflow/lite/micro/kernels/depthwise_conv.h"
#include "tensorflow/lite/micro/kernels/kernel_util.h"

namespace tflite {
namespace {

void* DepthwiseConvInt8ChannelBlockedInit(TfLiteContext* context,
                                          const char* buffer, size_t length) {
  (void)buffer;
  (void)length;
  TFLITE_DCHECK(context->AllocatePersistentBuffer != nullptr);
  return context->AllocatePersistentBuffer(context, sizeof(OpDataConv));
}

TfLiteStatus DepthwiseConvInt8ChannelBlockedEval(TfLiteContext* context,
                                                 TfLiteNode* node) {
  TFLITE_DCHECK(node->user_data != nullptr);
  TFLITE_DCHECK(node->builtin_data != nullptr);

  const TfLiteEvalTensor* input =
      tflite::micro::GetEvalInput(context, node, kDepthwiseConvInputTensor);
  const TfLiteEvalTensor* filter =
      tflite::micro::GetEvalInput(context, node, kDepthwiseConvWeightsTensor);
  if (input->type != kTfLiteInt8 || filter->type != kTfLiteInt8) {
    return Register_DEPTHWISE_CONV_2D().invoke(context, node);
  }

  const auto& params =
      *(reinterpret_cast<TfLiteDepthwiseConvParams*>(node->builtin_data));
  const OpDataConv& data = *(static_cast<const OpDataConv*>(node->user_data));
  TfLiteEvalTensor* output =
      tflite::micro::GetEvalOutput(context, node, kDepthwiseConvOutputTensor);
  const TfLiteEvalTensor* bias =
      (NumInputs(node) == 3)
          ? tflite::micro::GetEvalInput(context, node, kDepthwiseConvBiasTensor)
          : nullptr;

  DepthwiseConvInt8ChannelBlocked(
      DepthwiseConvParamsQuantized(params, data),
      data.per_channel_output_multiplier, data.per_channel_output_shift,
      tflite::micro::GetTensorShape(input),
      tflite::micro::GetTensorData<int8_t>(input),
      tflite::micro::GetTensorShape(filter),
      tflite::micro::GetTensorData<int8_t>(filter),
      tflite::micro::GetTensorShape(bias),
      tflite::micro::GetOptionalTensorData<int32_t>(bias),
      tflite::micro::GetTensorShape(output),
      tflite::micro::GetTensorData<int8_t>(output));
  return kTfLiteOk;
}

}  // namespace

TfLiteRegistration Register_DEPTHWISE_CONV_2D_INT8_CHANNEL_BLOCKED() {
  return tflite::micro::RegisterOp(DepthwiseConvInt8ChannelBlockedInit,
                                   DepthwiseConvPrepare,
                                   DepthwiseConvInt8ChannelBlockedEval);
}

}  // namespace tflite

#endif  // TFLM_MODEL_ENABLED
