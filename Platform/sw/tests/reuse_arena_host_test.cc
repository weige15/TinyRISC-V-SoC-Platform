// Two consecutive REAL ConvPerChannel invocations, one shared arena address.
// A single input pixel makes the final ptr1/N of layer 0 equal the first key
// of layer 1: forgetting invalidation cannot hide behind a different pixel.
#include "offset9_model.h"
#include "lab2_api.h"
#define reference_integer_ops reuse_patched
#include "../tflm_patches/tensorflow/lite/kernels/internal/reference/integer_ops/conv.h"
#undef reference_integer_ops
#include <array>
#include <cstdio>
#include <cstring>
#include <vector>

void offset9_ref(const tflite::ConvParams&, const int32_t*, const int32_t*,
                 const tflite::RuntimeShape&, const int8_t*, const tflite::RuntimeShape&,
                 const int8_t*, const tflite::RuntimeShape&, const int32_t*,
                 const tflite::RuntimeShape&, int8_t*);
namespace {
using namespace tflite;
using offset9_model::stats;
unsigned failures = 0, mismatches = 0, layers = 0, pairs = 0, changed_outputs = 0;
void check(bool ok, const char* why) {
  if (!ok) { ++failures; std::printf("ARENA FAIL: %s\n", why); }
}
void pair(int depth, int a_low, int b_low) {
  const int32_t ids[] = {1, 1, 1, depth}, fds[] = {4, 1, 1, depth};
  const int32_t ods[] = {1, 1, 1, 4}, bds[] = {4};
  RuntimeShape is(4, ids), fs(4, fds), os(4, ods), bs(1, bds);
  std::vector<int8_t> arena(depth + 16), weights(4 * depth + 16);
  int8_t* const shared_input = arena.data() + 4 + a_low;
  int8_t* const filter = weights.data() + 4 + b_low;
  const auto shared_address = reinterpret_cast<uintptr_t>(shared_input);
  check((shared_address & 3) == unsigned(a_low), "input alignment");
  check((reinterpret_cast<uintptr_t>(filter) & 3) == unsigned(b_low), "filter alignment");
  std::array<int32_t, 4> multiplier{}, shift{};
  multiplier.fill(0x40000000);
  int scale = 0;
  for (int n = depth; n > 2; n /= 2) --scale;
  shift.fill(scale);
  ConvParams p{};
  p.input_offset = 0; p.output_offset = 0;
  p.stride_height = p.stride_width = 1;
  p.dilation_height_factor = p.dilation_width_factor = 1;
  p.quantized_activation_min = -128; p.quantized_activation_max = 127;
  std::array<int8_t, 4> old_reference{};
  offset9_model::capture_commands = true;
  for (int layer = 0; layer < 2; ++layer) {
    // No test-side arm/disarm/reset between these calls. Only production
    // ConvMacScope and lab2_api may invalidate the cached operands.
    std::memset(shared_input, layer == 0 ? 1 : 5, depth);
    const int signs[2][4] = {{1, 2, -1, -2}, {-1, 1, 2, -2}};
    for (int c = 0; c < 4; ++c) std::memset(filter + c * depth, signs[layer][c], depth);
    const auto input_before = arena, filter_before = weights;
    std::array<int8_t, 4> reference{}, actual{};
    offset9_ref(p, multiplier.data(), shift.data(), is, shared_input, fs, filter,
                bs, nullptr, os, reference.data());
    const auto hits = reuse_hits, fast = stats.fast_hits, arms = stats.arms, disarms = stats.disarms;
    offset9_model::commands.clear();
    reuse_patched::ConvPerChannel(p, multiplier.data(), shift.data(), is, shared_input,
                                  fs, filter, bs, nullptr, os, actual.data());
    unsigned bad = 0;
    for (size_t c = 0; c < actual.size(); ++c) {
      bad += actual[c] != reference[c];
      check(reference[c] > -128 && reference[c] < 127, "saturation could hide stale data");
      if (layer) changed_outputs += reference[c] != old_reference[c];
    }
    check(bad == 0, "layer differs from unmodified upstream reference");
    check(reinterpret_cast<uintptr_t>(shared_input) == shared_address, "arena address changed");
    check(arena == input_before && weights == filter_before, "kernel changed operands");
    check(reuse_hits - hits == 3, "each layer must refill then reuse ptr1 three times");
    check(stats.arms == arms + 1 && stats.disarms == disarms + 2 && !reuse_armed && lab2_mac_is_idle(),
          "production convolution did not invalidate at entry/exit and arm");
    check(offset9_model::commands.size() == 4, "expected four actual MAC commands per layer");
    for (const auto& command : offset9_model::commands)
      check(command.a == shared_address && command.n == unsigned(depth), "MAC did not use shared ptr1/N");
    old_reference = reference; mismatches += bad; ++layers;
    std::printf("ARENA_LAYER: pair=%u layer=%d N=%d align=%d/%d shared_address=1 outputs=4 mismatches=%u reuse_hits=%llu fast_hits=%llu\n",
                pairs, layer, depth, a_low, b_low, bad, (unsigned long long)(reuse_hits-hits),
                (unsigned long long)(stats.fast_hits-fast));
  }
  ++pairs;
  offset9_model::capture_commands = false;
}
}
int main() {
  for (int n : {3, 64, 300, 1024})
    for (int a = 0; a < 4; ++a) for (int b = 0; b < 4; ++b) pair(n, a, b);
  check(pairs == 64 && layers == 128 && changed_outputs == 256, "two-layer coverage/reference changes incomplete");
  check(reuse_stale == 0 && stats.failures == 0, "stale operand or instruction protocol failure");
  std::printf("ARENA_RESULT: pairs=%u layers=%u shared_address_pairs=%u changed_outputs=%u mismatches=%u stale_hits=%llu model_failures=%llu failures=%u\n",
              pairs, layers, pairs, changed_outputs, mismatches,
              (unsigned long long)reuse_stale, (unsigned long long)stats.failures, failures);
  return failures || mismatches ? 1 : 0;
}
