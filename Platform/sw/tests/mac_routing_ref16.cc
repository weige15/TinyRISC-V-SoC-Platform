// Separate TU: only the unmodified upstream include root is used here.
#include "tensorflow/lite/kernels/internal/reference/integer_ops/conv.h"

void routing_ref16_32(
    const tflite::ConvParams& p, const int32_t* m, const int32_t* s,
    const tflite::RuntimeShape& is, const int16_t* in,
    const tflite::RuntimeShape& fs, const int8_t* f,
    const tflite::RuntimeShape& bs, const int32_t* b,
    const tflite::RuntimeShape& os, int16_t* out) {
  tflite::reference_integer_ops::ConvPerChannel(p, m, s, is, in, fs, f, bs, b, os, out);
}
void routing_ref16_64(
    const tflite::ConvParams& p, const int32_t* m, const int32_t* s,
    const tflite::RuntimeShape& is, const int16_t* in,
    const tflite::RuntimeShape& fs, const int8_t* f,
    const tflite::RuntimeShape& bs, const int64_t* b,
    const tflite::RuntimeShape& os, int16_t* out) {
  tflite::reference_integer_ops::ConvPerChannel(p, m, s, is, in, fs, f, bs, b, os, out);
}
