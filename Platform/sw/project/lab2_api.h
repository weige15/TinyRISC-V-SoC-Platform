#ifndef LAB2_API_H
#define LAB2_API_H

#include<stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Legacy diagnostic symbol; production hot paths do not update it.
extern int hw_simd_mac_cnt;
int32_t hw_simd_mac(
    int8_t *ptr1, int8_t *ptr2,
    int8_t input_offset, uint32_t N
);

// ptr1 operand reuse window (see lab2_api.cc). Reserved for conv.h's
// ConvPerChannel: arm after cleaning the input tensor, disarm before return.
void hw_simd_mac_reuse_arm(void);
void hw_simd_mac_reuse_disarm(void);

#ifdef __cplusplus
}
#endif

// Only for callers that have cleaned BOTH complete ranges and fenced, and
// guarantee no intervening writes. Ordinary/test callers MUST use hw_simd_mac.
#if defined(__riscv)
#include "../app/cfu.h"
#endif
static inline __attribute__((always_inline)) int32_t hw_simd_mac_precleaned(
    int8_t* ptr1, int8_t* ptr2, int8_t input_offset, uint32_t N) {
#if defined(__riscv)
    if (N == 0) return 0;
    // CUSTOM-0 funct3=4: SET(N, offset), COMPUTE(ptr1, ptr2) -> result.
    // NPU.v latches only rs2[7:0]; no CPU mask/sign-extension is required.
    cfu_raw_op(4, 0, N, input_offset);
    return (int32_t)cfu_raw_op(4, 1, ptr1, ptr2);
#else
    return hw_simd_mac(ptr1, ptr2, input_offset, N);
#endif
}

#endif
