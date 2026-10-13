#include "lab2_api.h"
#include "cfu.h"

namespace {

constexpr uintptr_t kDCacheLineBytes = 32;

// Exactly one clean per overlapping line, including unaligned endpoints.
// Buffers must be valid, non-wrapping address ranges. Empty ranges touch nothing.
__attribute__((always_inline)) inline void clean_dcache_range(
    uintptr_t data, uint32_t bytes) {
    if (bytes == 0) return;
    const uintptr_t end = data + bytes;
    for (uintptr_t line = data & ~(kDCacheLineBytes - 1);
         line < end; line += kDCacheLineBytes) {
#if defined(__riscv)
        // cbo.clean, with an arbitrary rs1 (unlike cbo.h's fixed a0).
        // The installed assembler predates Zicbom mnemonic support.
        __asm__ volatile(".insn i 0x0f, 2, x0, %0, 1"
                         : : "r"(line) : "memory");
#endif
    }
}

__attribute__((always_inline)) inline void memory_fence() {
#if defined(__riscv)
    __asm__ volatile("fence rw, rw" ::: "memory");
#endif
}

}  // namespace

// Retained for source compatibility. Production calls do not update a counter;
// host-test instrumentation supplies its own implementation and counter.
int hw_simd_mac_cnt = 0;

// Explicit bulk-clean API for convolution only. No hidden range/SET state.
// The caller must prove no writes to either range until its precleaned calls end.
extern "C" void hw_simd_mac_assume_clean_begin(const void* a, uint32_t a_bytes,
                                               const void* b, uint32_t b_bytes) {
    memory_fence();
    clean_dcache_range(reinterpret_cast<uintptr_t>(a), a_bytes);
    clean_dcache_range(reinterpret_cast<uintptr_t>(b), b_bytes);
    memory_fence();
}

extern "C" void hw_simd_mac_assume_clean_end(void) {}

// ptr1 operand reuse (NPU CUSTOM-0 funct3=4, funct7=3). Only conv.h's
// ConvPerChannel arms it, after hw_simd_mac_assume_clean_begin() wrote the
// input tensor back, and disarms it before returning. While armed, a COMPUTE
// with the same ptr1 and N as the previous successful one reuses the ptr1
// bytes that the NPU fetched over AXI for that call; ptr2 is always fetched.
// Arming and disarming both invalidate the NPU copy, so data fetched outside
// the armed window is never reused. Disarmed (reset default), every call,
// including every standalone hw_simd_mac, fetches both operands.
// Arming uses funct7=4, which also enables the NPU filter cache: ptr2 words
// fetched over AXI by armed calls are kept, and a call that hits both the
// ptr1 copy and the cache issues no AXI request (16-lane local MAC). The
// kernel stores only to its output tensor (disjoint from input and filter)
// while armed, so both cached operands stay equal to memory.
extern "C" void hw_simd_mac_reuse_arm(void) {
    cfu_raw_op(4, 4, 1, 0);
}

extern "C" void hw_simd_mac_reuse_disarm(void) {
    cfu_raw_op(4, 3, 0, 0);
}

int32_t hw_simd_mac(int8_t* ptr1, int8_t* ptr2, int8_t input_offset, uint32_t N) {
    if (N == 0) return 0;
    // Retain ordering on this decoupled EX/MEM core: a CMO can still be in
    // flight while non-memory instructions execute. Never skip test cleaning.
    memory_fence();
    clean_dcache_range(reinterpret_cast<uintptr_t>(ptr1), N);
    clean_dcache_range(reinterpret_cast<uintptr_t>(ptr2), N);
    memory_fence();
    // The RTL handles chunking and 4-KiB splits internally. No CPU chunk loop,
    // status read, SET cache, counter update, stack frame, or printf is needed.
    cfu_raw_op(4, 0, N, input_offset);
    return static_cast<int32_t>(cfu_raw_op(4, 1, ptr1, ptr2));
}
