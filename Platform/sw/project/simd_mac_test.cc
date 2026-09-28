#include "simd_mac_test.h"

#include <stdint.h>
#include <stdio.h>

#include "cfu.h"

namespace {

// Lab 1 packs lane 0 in bits [31:24] and lane 3 in bits [7:0].
uint32_t pack_int8_lanes(int8_t lane0, int8_t lane1, int8_t lane2,
                         int8_t lane3) {
  return (static_cast<uint32_t>(static_cast<uint8_t>(lane0)) << 24) |
         (static_cast<uint32_t>(static_cast<uint8_t>(lane1)) << 16) |
         (static_cast<uint32_t>(static_cast<uint8_t>(lane2)) << 8) |
         static_cast<uint32_t>(static_cast<uint8_t>(lane3));
}

int64_t signed_word(uint32_t value) {
  return (value & 0x80000000u) ? static_cast<int64_t>(value) - 0x100000000LL
                               : static_cast<int64_t>(value);
}

unsigned check_result(const char* name, uint32_t actual, int32_t expected) {
  const uint32_t expected_bits = static_cast<uint32_t>(expected);
  const bool pass = actual == expected_bits;
  printf("[%s] SIMD MAC %s: actual=%lld (0x%08lx), expected=%lld (0x%08lx)\n",
         pass ? "PASS" : "FAIL", name, static_cast<long long>(signed_word(actual)),
         static_cast<unsigned long>(actual), static_cast<long long>(expected),
         static_cast<unsigned long>(expected_bits));
  return pass ? 0 : 1;
}

}  // namespace

void simd_mac_test(void) {
  printf("\n=== Standalone SIMD INT8 MAC Test ===\n");
#if defined(__riscv) && !defined(CFU_SOFTWARE_DEFINED)
  printf("[SIMD MAC] Backend: hardware CUSTOM-0, funct3=%u.\n",
         CFU_FUNCT3_SIMD_MAC);
#else
  printf("[SIMD MAC] Backend: software fallback; FPGA instruction is not tested.\n");
#endif

  unsigned failures = 0;

  const uint32_t positive_input = pack_int8_lanes(1, 2, 3, 4);
  const uint32_t positive_filter = pack_int8_lanes(5, 6, 7, 8);
  failures += check_result("positive reset", cfu_simd_mac_reset(positive_input,
                                                                  positive_filter),
                           70);

  const uint32_t signed_input = pack_int8_lanes(1, -2, 3, -4);
  const uint32_t signed_filter = pack_int8_lanes(-5, 6, -7, 8);
  failures += check_result("signed INT8 reset",
                           cfu_simd_mac_reset(signed_input, signed_filter), -70);

  failures += check_result("accumulate reset", cfu_simd_mac_reset(positive_input,
                                                                    positive_filter),
                           70);
  const uint32_t second_input = pack_int8_lanes(1, 2, 3, 4);
  const uint32_t second_filter = pack_int8_lanes(8, 7, 6, 5);
  failures += check_result("accumulate without reset",
                           cfu_simd_mac_accumulate(second_input, second_filter),
                           130);

  failures += check_result("reset after accumulation",
                           cfu_simd_mac_reset(signed_input, signed_filter), -70);

  failures += check_result("all-zero operands",
                           cfu_simd_mac_reset(0, 0), 0);

  const uint32_t minimum_input = pack_int8_lanes(-128, -128, -128, -128);
  const uint32_t maximum_filter = pack_int8_lanes(127, 127, 127, 127);
  failures += check_result("-128 times 127",
                           cfu_simd_mac_reset(minimum_input, maximum_filter),
                           -65024);

  const uint32_t mixed_extreme_input =
      pack_int8_lanes(-128, 127, -128, 127);
  const uint32_t mixed_extreme_filter =
      pack_int8_lanes(127, -128, -128, 127);
  failures += check_result("mixed -128/127 lanes",
                           cfu_simd_mac_reset(mixed_extreme_input,
                                              mixed_extreme_filter),
                           1);

  if (failures == 0) {
    printf("[SIMD MAC] ALL PASS (8 checks).\n");
  } else {
    printf("[SIMD MAC] FAIL (%u/8 checks).\n", failures);
  }
}
