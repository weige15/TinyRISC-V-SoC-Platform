// This TU deliberately includes the unmodified, tracked upstream reference.
#include "tensorflow/lite/kernels/internal/reference/integer_ops/conv.h"
void offset9_ref(const tflite::ConvParams& p, const int32_t* m, const int32_t* s,
                 const tflite::RuntimeShape& is, const int8_t* in,
                 const tflite::RuntimeShape& fs, const int8_t* f,
                 const tflite::RuntimeShape& bs, const int32_t* b,
                 const tflite::RuntimeShape& os, int8_t* out) {
  tflite::reference_integer_ops::ConvPerChannel(p, m, s, is, in, fs, f, bs, b, os, out);
}
