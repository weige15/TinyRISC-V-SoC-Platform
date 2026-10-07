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

// Longest vector the NPU command is specified and verified for
// (npu_burst_dot_product.v: "exact for the Lab 2 domain N <= 256";
// npu_lab2_tb.sv sweeps N = 1..256). Longer calls are split.
constexpr uint32_t kNpuMaxBytes = 256;

// Writes back every data-cache line that overlaps [data, data + bytes) so the
// NPU, which reads DRAM directly over AXI, sees the CPU's latest stores. The
// first and last lines are included even when the range is not line aligned.
inline void clean_dcache_range(const int8_t* data, uint32_t bytes) {
    uintptr_t line = reinterpret_cast<uintptr_t>(data) & ~(kDCacheLineBytes - 1);
    const uintptr_t end = reinterpret_cast<uintptr_t>(data) + bytes;
    for (; line < end; line += kDCacheLineBytes) {
        cbo_clean(reinterpret_cast<const volatile void*>(line));
    }
}

inline void memory_fence() {
#if defined(__riscv)
    __asm__ volatile("fence rw, rw" ::: "memory");
#endif
}

}  // namespace

int hw_simd_mac_cnt = 0;  // number of NPU COMPUTE commands issued

int32_t hw_simd_mac(
    int8_t *ptr1, int8_t *ptr2,
    int8_t input_offset, uint32_t N
){
    if (N == 0) return 0;

    // Make both vectors visible to the NPU before it is started.
    memory_fence();
    clean_dcache_range(ptr1, N);
    clean_dcache_range(ptr2, N);
    memory_fence();

    // Each part is a full NPU dot product; the CPU only adds the NPU_out
    // results of the parts (modulo 2^32, like the hardware accumulator).
    uint32_t total = 0;
    uint32_t done = 0;
    while (done < N) {
        const uint32_t remaining = N - done;
        const uint32_t len = remaining < kNpuMaxBytes ? remaining : kNpuMaxBytes;

        // Unchanged (possibly unaligned) byte addresses go to the hardware.
        const CfuWord addr1 = reinterpret_cast<CfuWord>(ptr1) + done;
        const CfuWord addr2 = reinterpret_cast<CfuWord>(ptr2) + done;

        cfu_raw_op(NPU_FUNCT3_BURST_DOT_PRODUCT,
                   NPU_FUNCT7_BURST_DOT_PRODUCT_SET,
                   len, static_cast<uint8_t>(input_offset));
        const uint32_t npu_out = cfu_raw_op(NPU_FUNCT3_BURST_DOT_PRODUCT,
                                            NPU_FUNCT7_BURST_DOT_PRODUCT_COMPUTE,
                                            addr1, addr2);
        ++hw_simd_mac_cnt;

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

        total += npu_out;
        done += len;
    }
    return static_cast<int32_t>(total);
}
