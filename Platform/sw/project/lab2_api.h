#ifndef LAB2_API_H
#define LAB2_API_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Legacy diagnostic symbol; production hot paths do not update it.
extern int hw_simd_mac_cnt;
int32_t hw_simd_mac(
    int8_t *ptr1, int8_t *ptr2,
    int8_t input_offset, uint32_t N
);

// Optional one-shot convolution command for the NEXT call to the function
// above. The signed 9-bit offset is kept wide (including +128); its legacy
// int8 argument is ignored for that one prepared call. Preparation is consumed
// and zeroed on entry, even for N=0. Unprepared calls retain SET8 semantics.
// precleaned requires both ranges cleaned/fenced and unchanged until completion.
// Single-owner NPU: no intervening/reentrant MAC is allowed after preparation.
void lab2_prepare_mac(int32_t input_offset, bool precleaned);

// Stateless bulk clean; no address ranges are retained.
void lab2_clean_operands(const void* a, uint32_t a_bytes,
                         const void* b, uint32_t b_bytes);
// Arm only after cleaning disjoint operands. Reset cancels any preparation
// AND disarms/invalidates both hardware operand caches. Conv scopes reset at
// entry and exit, including aliased tensors, empty outputs and early returns.
void lab2_reuse_arm(void);
void lab2_conv_reset(void);
// Diagnostic: all SOFTWARE preparation fields are zero (not a hardware read).
bool lab2_mac_is_idle(void);

#ifdef __cplusplus
}
#endif

#endif
