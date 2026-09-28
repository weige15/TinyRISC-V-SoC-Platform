#include "software_cfu.h"

namespace {

uint32_t software_simd_mac_accumulator;

int32_t unpack_signed_int8(uint32_t packed, unsigned shift) {
  const uint32_t byte = (packed >> shift) & 0xffu;
  return (byte & 0x80u) ? static_cast<int32_t>(byte) - 0x100
                        : static_cast<int32_t>(byte);
}

}  // namespace

uint32_t software_cfu_raw(uint32_t funct3, uint32_t funct7, CfuWord rs1,
                          CfuWord rs2) {
  switch (funct3) {
    case CFU_FUNCT3_COMPUTE:
      return (uint32_t)rs1 + (uint32_t)rs2 + funct7;
    case CFU_FUNCT3_AXI_READ:
      if (funct7 != CFU_FUNCT7_AXI) {
        return 0;
      }
      return *reinterpret_cast<volatile uint32_t*>(rs1);
    case CFU_FUNCT3_AXI_WRITE:
      if (funct7 != CFU_FUNCT7_AXI) {
        return 0;
      }
      *reinterpret_cast<volatile uint32_t*>(rs1) = (uint32_t)rs2;
      return 0;
    case CFU_FUNCT3_SIMD_MAC: {
      if (funct7 != CFU_FUNCT7_SIMD_MAC_RESET &&
          funct7 != CFU_FUNCT7_SIMD_MAC_ACCUMULATE) {
        return 0;
      }
      uint32_t dot_product = 0;
      for (unsigned lane = 0; lane < 4; ++lane) {
        const unsigned shift = 24 - 8 * lane;
        const int32_t input = unpack_signed_int8(static_cast<uint32_t>(rs1), shift);
        const int32_t filter = unpack_signed_int8(static_cast<uint32_t>(rs2), shift);
        dot_product += static_cast<uint32_t>(input * filter);
      }
      if (funct7 == CFU_FUNCT7_SIMD_MAC_RESET) {
        software_simd_mac_accumulator = dot_product;
      } else {
        software_simd_mac_accumulator += dot_product;
      }
      return software_simd_mac_accumulator;
    }
    default:
      return 0;
  }
}

uint32_t software_cfu(CfuWord rs1, CfuWord rs2, uint32_t func) {
  switch (func) {
    case kCfuScalarCompute:
      return software_cfu_raw(CFU_FUNCT3_COMPUTE, CFU_FUNCT7_SCALAR_COMPUTE,
                              rs1, rs2);
    case kCfuAxiRead:
      return software_cfu_raw(CFU_FUNCT3_AXI_READ, CFU_FUNCT7_AXI, rs1, rs2);
    case kCfuAxiWrite:
      return software_cfu_raw(CFU_FUNCT3_AXI_WRITE, CFU_FUNCT7_AXI, rs1, rs2);
    default:
      return 0;
  }
}
