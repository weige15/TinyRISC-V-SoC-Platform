#include"lab2_api.h"

#include<stdio.h>
#include"cfu.h"
#include"cbo.h"

// Lab 2 burst dot product on the NPU (Platform/hw/srcs/NPU.v), CUSTOM-0
// funct3 = 4:
//   funct7 = 0 (SET)    : rs1 = N (bytes), rs2[7:0] = input_offset; rd = rs1.
//   funct7 = 1 (COMPUTE): rd = sum_{i<N} (int8(mem[rs1+i]) + input_offset)
//                                          * int8(mem[rs2+i]),
//                         both vectors are fetched by the NPU itself with AXI4
//                         INCR read bursts at any byte alignment of rs1 / rs2.
//   funct7 = 2 (STATUS) : rd = error flags of the last COMPUTE (0 = success).
// The macros must expand to integer literals: cfu_raw_op() stringifies them
// into the .insn directive.
#define NPU_FUNCT3_BURST_DOT_PRODUCT 4
#define NPU_FUNCT7_BURST_DOT_PRODUCT_SET 0
#define NPU_FUNCT7_BURST_DOT_PRODUCT_COMPUTE 1
#define NPU_FUNCT7_BURST_DOT_PRODUCT_STATUS 2

namespace {

// The data cache transfers 256-bit (32-byte) lines (data_block32B.v).
constexpr uintptr_t kDCacheLineBytes = 32;

// Longest vector one NPU command covers: one input-buffer chunk of
// npu_burst_dot_product.v (CHUNK_WORDS = 256 words = 1024 bytes). The
// testbench npu_lab2_tb.sv verifies N = 1..1024. Longer calls are split.
constexpr uint32_t kNpuMaxBytes = 1024;

// Software copy of the NPU's SET registers (length, offset). Every SET goes
// through npu_set(), so the copy always matches the hardware. Length 0 is
// never programmed by npu_set(), so 0 means "unknown, program it".
uint32_t g_set_length = 0;
uint32_t g_set_offset = 0;

// Address ranges that hw_simd_mac_assume_clean_begin() has written back to
// DRAM and that the CPU promises not to store to until
// hw_simd_mac_assume_clean_end(). Calls whose two vectors both lie inside
// these ranges skip the per-call cache clean and fences.
constexpr int kMaxCleanRanges = 2;
uintptr_t g_clean_begin[kMaxCleanRanges];
uintptr_t g_clean_end[kMaxCleanRanges];
int g_clean_count = 0;

// Writes back every data-cache line that overlaps [data, data + bytes) so the
// NPU, which reads DRAM directly over AXI, sees the CPU's latest stores. The
// first and last lines are included even when the range is not line aligned.
inline void clean_dcache_range(uintptr_t data, uint32_t bytes) {
    uintptr_t line = data & ~(kDCacheLineBytes - 1);
    const uintptr_t end = data + bytes;
    for (; line < end; line += kDCacheLineBytes) {
        cbo_clean(reinterpret_cast<const volatile void*>(line));
    }
}

// Orders the cache write-backs before the following NPU command (a dirty
// cbo.clean is still in flight while later non-memory instructions run).
inline void memory_fence() {
#if defined(__riscv)
    __asm__ volatile("fence rw, rw" ::: "memory");
#endif
}

inline bool range_is_clean(uintptr_t data, uint32_t bytes) {
    for (int i = 0; i < g_clean_count; ++i) {
        if (data >= g_clean_begin[i] && data + bytes <= g_clean_end[i]) {
            return true;
        }
    }
    return false;
}

inline void npu_set(uint32_t length, int8_t input_offset) {
    const uint32_t offset = static_cast<uint8_t>(input_offset);
    if (length != g_set_length || offset != g_set_offset) {
        cfu_raw_op(NPU_FUNCT3_BURST_DOT_PRODUCT,
                   NPU_FUNCT7_BURST_DOT_PRODUCT_SET, length, offset);
        g_set_length = length;
        g_set_offset = offset;
    }
}

}  // namespace

int hw_simd_mac_cnt = 0;  // number of NPU COMPUTE commands issued

// Writes back [a, a + a_bytes) and [b, b + b_bytes) once. Until
// hw_simd_mac_assume_clean_end() the caller must not store into these ranges;
// hw_simd_mac() then skips cleaning for vectors inside them.
extern "C" void hw_simd_mac_assume_clean_begin(const void* a, uint32_t a_bytes,
                                               const void* b, uint32_t b_bytes) {
    const uintptr_t ua = reinterpret_cast<uintptr_t>(a);
    const uintptr_t ub = reinterpret_cast<uintptr_t>(b);
    memory_fence();
    clean_dcache_range(ua, a_bytes);
    clean_dcache_range(ub, b_bytes);
    memory_fence();
    g_clean_begin[0] = ua;
    g_clean_end[0] = ua + a_bytes;
    g_clean_begin[1] = ub;
    g_clean_end[1] = ub + b_bytes;
    g_clean_count = 2;
}

extern "C" void hw_simd_mac_assume_clean_end(void) {
    g_clean_count = 0;
}

int32_t hw_simd_mac(
    int8_t *ptr1, int8_t *ptr2,
    int8_t input_offset, uint32_t N
){
    if (N == 0) return 0;

    const uintptr_t base1 = reinterpret_cast<uintptr_t>(ptr1);
    const uintptr_t base2 = reinterpret_cast<uintptr_t>(ptr2);
    const bool pre_cleaned =
        g_clean_count != 0 && range_is_clean(base1, N) && range_is_clean(base2, N);

    // Make both vectors visible to the NPU before it is started.
    if (!pre_cleaned) {
        memory_fence();
        clean_dcache_range(base1, N);
        clean_dcache_range(base2, N);
        memory_fence();
    }

    // Each part is a full NPU dot product; the CPU only adds the NPU_out
    // results of the parts (modulo 2^32, like the hardware accumulator).
    uint32_t total = 0;
    uint32_t done = 0;
    while (done < N) {
        const uint32_t remaining = N - done;
        const uint32_t len = remaining < kNpuMaxBytes ? remaining : kNpuMaxBytes;

        // Unchanged (possibly unaligned) byte addresses go to the hardware.
        const CfuWord addr1 = base1 + done;
        const CfuWord addr2 = base2 + done;

        npu_set(len, input_offset);
        const uint32_t npu_out = cfu_raw_op(NPU_FUNCT3_BURST_DOT_PRODUCT,
                                            NPU_FUNCT7_BURST_DOT_PRODUCT_COMPUTE,
                                            addr1, addr2);
        ++hw_simd_mac_cnt;

        if (!pre_cleaned) {
            const uint32_t status = cfu_raw_op(NPU_FUNCT3_BURST_DOT_PRODUCT,
                                               NPU_FUNCT7_BURST_DOT_PRODUCT_STATUS,
                                               0, 0);
            if (status != 0) {
                printf("hw_simd_mac: NPU AXI read error, status=0x%lx "
                       "(ptr1=%p ptr2=%p len=%lu)\n",
                       static_cast<unsigned long>(status),
                       reinterpret_cast<void*>(addr1),
                       reinterpret_cast<void*>(addr2),
                       static_cast<unsigned long>(len));
            }
        }

        total += npu_out;
        done += len;
    }
    return static_cast<int32_t>(total);
}
