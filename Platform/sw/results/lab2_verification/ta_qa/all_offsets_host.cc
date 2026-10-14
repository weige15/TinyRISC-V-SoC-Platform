// Focused TA 2.2.3 witness: reuse the existing upstream-reference assertions,
// but exercise EVERY offset -128..128 through actual ConvPerChannel + SET9.
// The existing test and production sources are not modified.
#define main original_offset9_matrix_main
#include "../../../tests/offset9_host_test.cc"
#undef main

int main() {
  for (int off = -128; off <= 128; ++off) {
    const auto before = failures;
    // Depth-300 pointwise convolution; rotating independent alignments,
    // alternating random/extreme patterns; a plain MAC follows each conv.
    const unsigned i = static_cast<unsigned>(off + 128);
    convolution(0, off, i & 3, (i >> 2) & 3, i & 1,
                off == 128 ? -128 : off);
    std::printf("ALL_OFFSETS_CASE: offset=%d cases=1 failures=%llu\n",
                off, static_cast<unsigned long long>(failures - before));
  }
  check(conv_cases == 257 && alternating_cases == 257 && plain_cases == 257,
        "all-offset range incomplete");
  check(compared_bytes == 12336 && unsaturated > compared_bytes / 2,
        "all-offset comparison vacuous");
  check(!reuse_armed && reuse_stale == 0 && stats.failures == 0,
        "all-offset state/protocol failure");
  std::printf("ALL_OFFSETS_RESULT: offsets=257 range=-128..128 conv_cases=%llu "
              "bytes=%llu plain_calls=%llu byte_mismatches=%llu "
              "model_failures=%llu failures=%llu\n",
              static_cast<unsigned long long>(conv_cases),
              static_cast<unsigned long long>(compared_bytes),
              static_cast<unsigned long long>(plain_cases),
              static_cast<unsigned long long>(mismatches),
              static_cast<unsigned long long>(stats.failures),
              static_cast<unsigned long long>(failures));
  return failures || mismatches || stats.failures ? 1 : 0;
}
