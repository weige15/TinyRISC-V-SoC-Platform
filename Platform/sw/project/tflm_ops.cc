#include "tflm_ops.h"

#ifndef TFLM_SOFTWARE_CONV
#include "depthwise_conv_int8_channel_blocked.h"
#endif

void tflm_register_project_ops(ProjectOpResolver* resolver) {
  resolver->AddAveragePool2D();
  resolver->AddAudio_Spectrogram();
  resolver->AddConv2D();
  resolver->AddDequantize();
#ifdef TFLM_SOFTWARE_CONV
  // Software/reference path: upstream TFLM depthwise kernel.
  resolver->AddDepthwiseConv2D();
#else
  // int8 x int8: project/depthwise_conv_int8_channel_blocked.cc; other types
  // fall back to the upstream kernel inside the registration.
  resolver->AddDepthwiseConv2D(
      tflite::Register_DEPTHWISE_CONV_2D_INT8_CHANNEL_BLOCKED());
#endif
  resolver->AddFullyConnected();
  resolver->AddMFCC();
  resolver->AddMul();
  resolver->AddQuantize();
  resolver->AddReshape();
}
