#include "tflm_ops.h"

void tflm_register_project_ops(ProjectOpResolver* resolver) {
  resolver->AddAveragePool2D();
  resolver->AddAudio_Spectrogram();
  resolver->AddConv2D();
  resolver->AddDequantize();
  resolver->AddDepthwiseConv2D();
  resolver->AddFullyConnected();
  resolver->AddMFCC();
  resolver->AddMul();
  resolver->AddQuantize();
  resolver->AddReshape();
}
