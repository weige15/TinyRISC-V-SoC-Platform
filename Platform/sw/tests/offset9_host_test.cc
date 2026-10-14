#include "offset9_model.h"
#include "lab2_api.h"
// Explicit patched path; the upstream TU has ONLY the tflite-micro include root.
#define reference_integer_ops offset9_patched
#include "../tflm_patches/tensorflow/lite/kernels/internal/reference/integer_ops/conv.h"
#undef reference_integer_ops
#include <array>
#include <cstdio>
#include <cstring>
#include <random>
#include <vector>

void offset9_ref(const tflite::ConvParams&, const int32_t*, const int32_t*,
                 const tflite::RuntimeShape&, const int8_t*, const tflite::RuntimeShape&,
                 const int8_t*, const tflite::RuntimeShape&, const int32_t*,
                 const tflite::RuntimeShape&, int8_t*);
namespace {
using namespace tflite;
using offset9_model::stats;
uint64_t failures = 0, conv_cases = 0, compared_bytes = 0, mismatches = 0, plain_cases = 0;
uint64_t unsaturated = 0, alternating_cases = 0;
std::mt19937 random(20261014);
void check(bool ok, const char* message) {
  if (!ok) { ++failures; if (failures <= 30) std::printf("HOST FAIL: %s\n", message); }
}
uint32_t oracle(const int8_t* a, const int8_t* b, int off, unsigned n) {
  int64_t acc = 0;
  for (unsigned i = 0; i < n; ++i) acc += (int64_t(a[i]) + off) * int64_t(b[i]);
  return static_cast<uint32_t>(acc);
}
void plain(int8_t* a, int8_t* b, int off, unsigned n) {
  check(off >= -128 && off <= 127, "invalid plain test argument");
  const auto sets = stats.set8, wide = stats.set9, hits = reuse_hits, fast = stats.fast_hits;
  const uint32_t expected = oracle(a, b, off, n);
  const auto result = static_cast<uint32_t>(hw_simd_mac(a, b, static_cast<int8_t>(off), n));
  check(result == expected, "plain MAC result / leaked offset or stale operands");
  check(stats.set8 == sets + 1 && stats.set9 == wide, "plain call did not use its own SET8");
  check(stats.last_offset == off && stats.engine_bits == (static_cast<unsigned>(off) & 511),
        "plain offset did not overwrite all 9 engine bits");
  check(!reuse_armed && reuse_hits == hits && stats.fast_hits == fast, "plain call inherited reuse");
  ++plain_cases;
}

// Shape 0 hits the depth-300 1x1 fast path; 1 hits both merged 3x3 rows
// and border taps; 2 uses stride/dilation; 3 uses grouped 3x3 tap calls.
void convolution(int shape, int off, unsigned low1, unsigned low2, int pattern, int plain_off) {
  const int depth = shape == 2 ? 7 : 300;
  const int fd = shape == 3 ? 100 : depth;
  const int fh = shape == 0 ? 1 : 3, fw = fh;
  const int ih = shape == 0 ? 2 : 5, iw = shape == 0 ? 3 : 6;
  const int oc = shape == 3 ? 6 : 4, batch = 2;
  const int stride = shape == 2 ? 2 : 1, dilation = shape == 2 ? 2 : 1;
  const int pad = shape == 0 ? 0 : dilation;
  const int oh = (ih + stride - 1) / stride, ow = (iw + stride - 1) / stride;
  const int32_t id[] = {batch, ih, iw, depth}, fdim[] = {oc, fh, fw, fd};
  const int32_t od[] = {batch, oh, ow, oc}, bd[] = {oc};
  RuntimeShape is(4, id), fs(4, fdim), os(4, od), bs(1, bd);
  std::vector<int8_t> ai(is.FlatSize() + 16, 83), bi(fs.FlatSize() + 16, 37);
  int8_t* a = ai.data() + 4 + low1; int8_t* b = bi.data() + 4 + low2;
  check((reinterpret_cast<uintptr_t>(a) & 3) == low1 &&
        (reinterpret_cast<uintptr_t>(b) & 3) == low2, "host alignment allocation");
  for (int i = 0; i < is.FlatSize(); ++i)
    a[i] = static_cast<int8_t>(pattern ? ((i % 3 == 0) ? -128 : (i % 3 == 1) ? 127 : 0)
                                     : int(random() % 256) - 128);
  for (int i = 0; i < fs.FlatSize(); ++i)
    b[i] = static_cast<int8_t>(pattern ? 1 : int(random() % 256) - 128);
  const auto saved_a = ai, saved_b = bi;
  std::vector<int32_t> bias(oc), mul(oc), shifts(oc);
  for (int c = 0; c < oc; ++c) {
    bias[c] = c * 113 - 197;
    mul[c] = 0x50000000 + c * 0x07000000;
    shifts[c] = pattern ? (shape == 0 ? -10 : -13) : (shape == 0 ? -12 : -14);
  }
  ConvParams p{};
  p.input_offset = off; p.output_offset = -7;
  p.stride_height = p.stride_width = stride;
  p.dilation_height_factor = p.dilation_width_factor = dilation;
  p.padding_values.height = p.padding_values.width = pad;
  p.quantized_activation_min = -128; p.quantized_activation_max = 127;
  std::vector<int8_t> expected(os.FlatSize(), 85), actual(os.FlatSize() + 8, 42);
  const int32_t* bias_ptr = pattern ? nullptr : bias.data();
  offset9_ref(p, mul.data(), shifts.data(), is, a, fs, b, bs, bias_ptr, os, expected.data());
  const auto calls = stats.computes, set8 = stats.set8, set9 = stats.set9;
  const auto offset_calls = stats.offset_calls[off], products = hw_simd_mac_bytes;
  const auto arms = stats.arms, disarms = stats.disarms;
  offset9_patched::ConvPerChannel(p, mul.data(), shifts.data(), is, a, fs, b, bs,
                                 bias_ptr, os, actual.data());
  check(std::memcmp(expected.data(), actual.data(), expected.size()) == 0, "ConvPerChannel byte mismatch");
  for (size_t i = 0; i < expected.size(); ++i) {
    mismatches += expected[i] != actual[i];
    unsaturated += expected[i] > -128 && expected[i] < 127;
  }
  for (size_t i = expected.size(); i < actual.size(); ++i) check(actual[i] == 42, "output redzone changed");
  check(ai == saved_a && bi == saved_b, "convolution modified an operand");
  const auto computes = stats.computes - calls;
  check(computes > 0 && stats.set8 == set8 && stats.set9 - set9 == computes &&
        stats.offset_calls[off] - offset_calls == computes,
        "convolution bypassed SET9 / offset correction shortcut");
  uint64_t expected_products = 0;
  for (int y = 0; y < oh; ++y) for (int x = 0; x < ow; ++x)
    for (int fy = 0; fy < fh; ++fy) for (int fx = 0; fx < fw; ++fx) {
      int iy = y * stride - pad + fy * dilation, ix = x * stride - pad + fx * dilation;
      if (iy >= 0 && iy < ih && ix >= 0 && ix < iw) expected_products += fd * oc * batch;
    }
  check(hw_simd_mac_bytes - products == expected_products, "not exactly one NPU product per reference term");
  check(!reuse_armed && stats.arms == arms + 1 && stats.disarms == disarms + 2, "unbalanced convolution entry/exit reset");
  ++conv_cases; compared_bytes += expected.size();
  // Probe the SAME ptr1, ptr2 and N as the final convolution MAC. Change both
  // operands after return, so forgotten disarm cannot hide behind a cache miss.
  const int in_index = ((batch - 1) * ih * iw + (oh - 1) * stride * iw + (ow - 1) * stride) * depth;
  // For the pointwise shape the last call is exactly this vector.
  int8_t* pa = shape == 0 ? a + in_index : a;
  int8_t* pb = shape == 0 ? b + (oc - 1) * fd : b;
  for (int i = 0; i < fd; ++i) { pa[i] = static_cast<int8_t>(int(random() % 256) - 128); pb[i] = 1; }
  plain(pa, pb, plain_off, fd);
  ++alternating_cases;
}

void command_matrix() {
  alignas(64) std::array<int8_t, 320> aa{}, bb{};
  uint64_t tuples = 0;
  for (unsigned n : {1u, 3u, 4u, 255u, 256u, 300u}) {
    const auto start = tuples;
    for (unsigned a_low = 0; a_low < 4; ++a_low) for (unsigned b_low = 0; b_low < 4; ++b_low)
      for (int off : {-128, -127, -102, -1, 0, 1, 127}) {
        int8_t* a = aa.data() + 4 + a_low; int8_t* b = bb.data() + 4 + b_low;
        for (unsigned i = 0; i < n; ++i) { a[i] = static_cast<int8_t>(int(i % 256) - 128); b[i] = 1; }
        // Conv-style without reuse, then plain; with reuse+filter-cache, then
        // plain. Second wide call must use +128 even if it uses cached words.
        for (bool armed : {false, true}) {
          if (armed) lab2_reuse_arm();
          for (int repeat = 0; repeat < (armed ? 2 : 1); ++repeat) {
            const auto sets = stats.set9;
            lab2_prepare_mac(128, false);
            check(static_cast<uint32_t>(hw_simd_mac(a, b, 0, n)) == oracle(a, b, 128, n), "prepared command result");
            check(stats.set9 == sets + 1 && stats.engine_bits == 128 && stats.last_offset == 128, "wide latch path");
          }
          if (armed) lab2_conv_reset();
          a[0] = a[0] == 127 ? -128 : a[0] + 1; b[0] = 2;
          plain(a, b, off, n);
        }
        ++tuples;
      }
    check(tuples - start == 16 * 7, "command matrix coverage missing");
    std::printf("HOST COMMAND: N=%u alignments=16 plain_offsets=7 tuples=%llu\n", n, (unsigned long long)(tuples-start));
  }
}
}
int main() {
  const int offsets[] = {-128, -127, -102, -1, 0, 1, 127, 128};
  const int plain_offsets[] = {-128, -127, -102, -1, 0, 1, 127};
  for (int off : offsets) for (int shape = 0; shape < 4; ++shape) {
    const auto before = conv_cases, bad = failures, bytes = compared_bytes;
    for (unsigned a = 0; a < 4; ++a) for (unsigned b = 0; b < 4; ++b)
      for (int pattern = 0; pattern < 2; ++pattern)
        convolution(shape, off, a, b, pattern, plain_offsets[(a * 4 + b + pattern) % 7]);
    check(conv_cases - before == 32, "conv matrix coverage missing");
    std::printf("HOST CONV: offset=%d shape=%s alignments=16 patterns=2 cases=%llu bytes=%llu failures=%llu\n",
                off, shape == 0 ? "1x1-depth300" : shape == 1 ? "3x3-depth300-SAME" :
                shape == 2 ? "3x3-stride2-dilation2" : "3x3-grouped", (unsigned long long)(conv_cases-before),
                (unsigned long long)(compared_bytes-bytes), (unsigned long long)(failures-bad));
  }
  // Every possible plain int8 argument immediately follows an actual +128
  // convolution which exercised reuse. No reset of model state between them.
  for (int off = -128; off <= 127; ++off) convolution(0, 128, off & 3, (off >> 2) & 3, 0, off);
  command_matrix();
  check(reuse_hits > 0 && stats.fast_hits > 0 && reuse_stale == 0, "reuse coverage/staleness");
  check(conv_cases == 1280 && alternating_cases == conv_cases && unsaturated > compared_bytes / 2,
        "conv coverage incomplete or outputs mostly saturated");
  check(stats.failures == 0, "model protocol failures");
  std::printf("HOST ALTERNATING: actual_convolutions=%llu each_followed_by_plain=1 post128_plain_int8_values=256 plain_calls=%llu reuse_hits=%llu fast_hits=%llu stale=%llu\n",
              (unsigned long long)alternating_cases, (unsigned long long)plain_cases,
              (unsigned long long)reuse_hits, (unsigned long long)stats.fast_hits, (unsigned long long)reuse_stale);
  std::printf("HOST RESULT: conv_cases=%llu bytes=%llu unsaturated=%llu byte_mismatches=%llu model_failures=%llu failures=%llu\n",
              (unsigned long long)conv_cases, (unsigned long long)compared_bytes, (unsigned long long)unsaturated,
              (unsigned long long)mismatches, (unsigned long long)stats.failures, (unsigned long long)failures);
  return failures || mismatches ? 1 : 0;
}
