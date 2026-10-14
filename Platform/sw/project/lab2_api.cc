#include "lab2_api.h"
#include "cfu.h"

namespace {

constexpr uintptr_t kDCacheLineBytes = 32;

// One-shot command, consumed and cleared by the real MAC entry point before
// any work/early return. SET9 reads only bits [8:0]. Bit 9 distinguishes a
// prepared zero offset from idle; bit 31 permits a cheap RV32 preclean test.
constexpr uint32_t kOffsetMask = 0x1ffu;
constexpr uint32_t kPrepared = 1u << 9;
constexpr uint32_t kPrecleaned = 1u << 31;
// crt0 clears .bss, but this platform linker leaves .sbss as an orphan.
// Keep the entire command in the startup-zeroed range even with small data.
uint32_t g_conv_command __attribute__((section(".bss"))) = 0;

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
// the host instruction-boundary model increments this diagnostic instead.
int hw_simd_mac_cnt = 0;

// Explicit bulk clean, with no retained range state. The caller must prove
// no writes to either range until its precleaned calls end.
extern "C" void lab2_clean_operands(const void* a, uint32_t a_bytes,
                                    const void* b, uint32_t b_bytes) {
    memory_fence();
    clean_dcache_range(reinterpret_cast<uintptr_t>(a), a_bytes);
    clean_dcache_range(reinterpret_cast<uintptr_t>(b), b_bytes);
    memory_fence();
}

// ptr1 operand reuse (NPU CUSTOM-0 funct3=4, funct7=3). ConvPerChannel
// arms it after bulk cleaning, and its stack scope resets it before returning.
// While armed, a COMPUTE
// with the same ptr1 and N as the previous successful one reuses the ptr1
// bytes that the NPU fetched over AXI for that call; ptr2 is always fetched.
// Arming and disarming both invalidate the NPU copy, so data fetched outside
// the armed window is never reused. Disarmed (reset default), every call,
// including every standalone hw_simd_mac, fetches both operands.
// Arming uses funct7=4, which also enables the NPU filter cache: ptr2 words
// fetched over AXI by armed calls are kept, and a call that hits both the
// ptr1 copy and the cache issues no AXI request (32-lane local MAC). The
// kernel stores only to its output tensor (disjoint from input and filter)
// while armed, so both cached operands stay equal to memory.
extern "C" void lab2_reuse_arm(void) {
    cfu_raw_op(4, 4, 1, 0);
}

extern "C" void lab2_conv_reset(void) {
    g_conv_command = 0;
    cfu_raw_op(4, 3, 0, 0);
}

extern "C" void lab2_prepare_mac(int32_t input_offset, bool precleaned) {
    g_conv_command = (static_cast<uint32_t>(input_offset) & kOffsetMask) |
                     kPrepared | (precleaned ? kPrecleaned : 0u);
}

extern "C" bool lab2_mac_is_idle(void) {
    return g_conv_command == 0;
}

// The sole MAC definition, with exactly the legacy C declaration's signature.
// Both prepared convolution calls and ordinary calls enter this function.
// The preparation adapter below must tail-call this actual entry, not inline
// its body or route through a compiler-generated constant-propagation clone.
extern "C" __attribute__((noinline, noclone))
int32_t hw_simd_mac(int8_t* ptr1, int8_t* ptr2,
                               int8_t input_offset, uint32_t N) {
    const uint32_t command = g_conv_command;
    g_conv_command = 0;
    if (N == 0) return 0;
    if ((command & kPrecleaned) == 0) {
        // Retain ordering on the decoupled EX/MEM core; a CMO can otherwise
        // still be in flight when COMPUTE starts reading external memory.
        memory_fence();
        clean_dcache_range(reinterpret_cast<uintptr_t>(ptr1), N);
        clean_dcache_range(reinterpret_cast<uintptr_t>(ptr2), N);
        memory_fence();
    }
    if (command != 0) {
        // SET9 ignores the metadata above bit 8; +128 is not narrowed.
        cfu_raw_op(4, 5, N, command);
    } else {
        cfu_raw_op(4, 0, N, input_offset);    // legacy SET8, all int8 values
    }
    return static_cast<int32_t>(cfu_raw_op(4, 1, ptr1, ptr2));
}

// Fuse preparation with the call site to avoid a second kernel-side ABI call.
// No CFU operation or MAC body is duplicated here: every product still runs
// inside the sole legacy C definition above, including prepared empty calls.
extern "C" int32_t lab2_prepared_mac(const int8_t* ptr1, const int8_t* ptr2,
                                      int32_t input_offset, uint32_t N,
                                      bool precleaned) {
    lab2_prepare_mac(input_offset, precleaned);
    return hw_simd_mac(const_cast<int8_t*>(ptr1), const_cast<int8_t*>(ptr2), 0, N);
}
