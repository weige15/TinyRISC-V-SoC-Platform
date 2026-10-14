# Offset +128 completion audit

## Concrete success criteria and evidence checklist

Paths below are relative to `Platform/` unless prefixed with `../`.
Fresh evidence is in [`sw/results/offset9/`](../../sw/results/offset9/).
This is a **host + RTL simulation** acceptance, not an FPGA-board result.

| Explicit requirement | Actual implementation/test inspected | Observed evidence / result |
|---|---|---|
| Print how 128 reaches the NPU; quote `lab2_api.cc` and `conv.h` | Source excerpts below; `sw/project/lab2_api.cc:70–82`, patched `conv.h:41–50,74,176–177,232–233,255` | Explicit helper with **int32_t** offset issues CUSTOM-0 `funct3=4, funct7=5` (SET9), then COMPUTE. No hidden offset flag. RV32 assembly and `isa_decode.log` confirm emitted fields and unmodified offset register `a2`. |
| (1) Upstream reference, not a local approximation | `sw/tests/offset9_ref.cc` separately compiles `../tflite-micro/tensorflow/lite/kernels/internal/reference/integer_ops/conv.h` | `upstream.txt`: tracked and current blobs both `5ddf04aea6e4de39dfe9021ad52437b57034407b`; no HEAD diff. Patched include is explicit in the other TU. |
| (1) Every offset **{-128,-127,-102,-1,0,1,127,128}** on **1x1 depth-300 and 3x3** | `sw/tests/offset9_host_test.cc`: explicit 8-offset × 4-shape × 16-alignment × 2-pattern grid, plus 256 additional +128 convolutions | `host.log`: all 32 offset/shape rows have `failures=0`. Shapes: 1x1 depth300; 3x3 depth300 SAME (both full rows and border taps); stride2/dilation2 3x3; grouped 3x3. **1,280 cases; 196,608 bytes; 0 byte mismatches; 0 failures.** |
| (1) Host model uses the same 9-bit path, not a shortcut | Real `lab2_api.cc` is linked. `sw/tests/offset9_model.cc` implements only `software_cfu_raw`; `host_symbols.txt` identifies the defining objects. SET8 concatenates sign bit + 8 bits; SET9 masks 9 bits; both feed the same engine latch and signed-9 decode, signed-10 sum, signed-17 product, modulo-32 accumulator. | `host.log`: every convolution compute must have its own SET9 and exactly its requested offset; exactly one NPU product per reference term. No tap-sum correction, replacement `hw_simd_mac`, or ConvParams side channel. Model protocol failures **0**. ASan/UBSan enabled, no diagnostics. |
| (2) RTL **N={1,3,4,255,256,300}**, **all alignments** | `hw/sim/npu_lab2_tb.sv`: `run_offset9_matrix`, `offset9_sequence`, `run_case`; full top-level `NPU`, not just a multiplier | `rtl_20261014.log`, `rtl_7.log`, `rtl_iverilog.log`: each N has all **4×4** ptr1/ptr2 alignments × 3 patterns × 2 reuse modes × 7 following plain offsets = **672 tuples**, credited only after all result/protocol checks pass. Total **4,032 tuples**; **6,560 SET9 computes**; **10,848 computes overall; FAIL=0** in both Verilator and four-state Icarus. |
| (2) Exact +128 results through real command/data paths | Driver issues SET9(5), COMPUTE(1), STATUS(2); asserts top and engine 9-bit latches; compares the entire unquantized 32-bit result to an independent signed reference; checks expected AXI burst list and status | Streaming, ptr1 reuse, and cached-filter paths all exercised: **2,272 reuse hits; 568 fast hits**. Random stalls, boundary-crossing addresses, random signed bytes, offset-only positive-weight pattern, and alternating -128/127 input pattern. All **0 failures**. |
| (3) Grep: 128 never stored/cast through an int8 scalar on its path | `run_offset9_tests.sh` prints positive type/dataflow grep over conv, API header/implementation, `cfu.h`, model, and RTL; negative grep for offset/128 scalar narrowing. Also inspected all source casts and the emitted RV32 helper. | `grep_path.log`: **narrowing matches=0 failures=0**. `ConvParams` is copied into int32, helper accepts int32, CFU operands use uintptr_t, RTL offset latches are 9 bits, model latches uint16. `const_cast<int8_t*>` applies to tensor pointers, not offset; `static_cast<int8_t>(acc)` applies only after output clamping. Plain API's int8 offset is intentionally a separate path. |
| (4) Plain `hw_simd_mac(ptr1,ptr2,input_offset,N)` after convolution uses only its own int8 offset | Host invokes actual ConvPerChannel, then actual plain API without any model reset. Changed operands, including the same final pointwise key/N, detect leaked reuse. Tests assert SET8 count, exact signed value and all nine latch bits. | `host.log`: **1,280 actual conv→plain alternations**; all **256 possible int8 values** directly after +128/reused pointwise convolutions; **2,624 plain calls** including direct command matrix; stale hits **0**, failures **0**. |
| (4) Alternation in RTL as well | `offset9_sequence`: conv-style unarmed +128 or armed fill→reuse +128, actual production disarm (funct7=3), mutate same-key memory, plain SET8 with its own offset. No reset between sequences. | RTL logs: **4,288 alternating plain calls**, including a separately checked complete **256-value int8 sweep**. Every result, register overwrite, refetch burst list, command/done count checked. **0 failures**. |
| Completion gate: all four shown, not just a green manifest | Re-read source, full host matrix log, individual RTL masks/count checks, disassembly, positive/negative grep, and symbol ownership; revalidated source hashes | All requirements above have concrete, current evidence. No missing required coverage. `sha256sum -c sw/results/offset9/source_sha256.txt`: all files OK; `git diff --check`: clean. |
| Stop boundary | User allowed up to 15 continuation turns | Finished in this continuation; no FPGA programming, commits, or unrelated changes required. |

## Quoted offset path

The patched file is
`sw/tflm_patches/tensorflow/lite/kernels/internal/reference/integer_ops/conv.h`.
The scalar is wide at its source (`:74`):

```cpp
const int32_t input_offset = params.input_offset;  // r = s(q - Z)
```

Its helper (`:43–50`) passes that same wide value, without narrowing:

```cpp
inline int32_t ConvDotProduct(const int8_t* input, const int8_t* filter,
                              int32_t input_offset, uint32_t n,
                              bool precleaned = false) {
  TFLITE_DCHECK_GE(input_offset, -256);
  TFLITE_DCHECK_LE(input_offset, 255);
  return hw_simd_mac_conv(const_cast<int8_t*>(input),
                          const_cast<int8_t*>(filter), input_offset, n,
                          precleaned);
}
```

`sw/project/lab2_api.cc:72–83`:

```cpp
int32_t hw_simd_mac_conv(int8_t* ptr1, int8_t* ptr2, int32_t input_offset,
                         uint32_t N, bool precleaned) {
    if (N == 0) return 0;
    if (!precleaned) {
        memory_fence();
        clean_dcache_range(reinterpret_cast<uintptr_t>(ptr1), N);
        clean_dcache_range(reinterpret_cast<uintptr_t>(ptr2), N);
        memory_fence();
    }
    cfu_raw_op(4, 5, N, input_offset);  // SET9: signed 9-bit offset, including 128
    return static_cast<int32_t>(cfu_raw_op(4, 1, ptr1, ptr2));
}
```

`cfu.h` converts instruction operands only through `CfuWord = uintptr_t`.
`NPU.v:158,309–318` declares a 9-bit register and **fully assigns** it on either SET:

```verilog
reg [ 8:0] burst_dot_product_offset_r;
// Plain SET (funct7=0):
burst_dot_product_offset_r <= {rs2_i[7], rs2_i[7:0]};
// SET9 (funct7=5):
burst_dot_product_offset_r <= rs2_i[8:0];
```

Thus +128 is `9'h080`, not the signed-int8 -128 pattern `9'h180`.
The engine input and `offset_r` are also 9 bits. `product()` receives `off[8:0]`:

```verilog
x = $signed({{2{a[7]}},a}) + $signed({off[8],off});
p = x * $signed(b);
```

`x` is signed 10-bit (also supports the full signed-9 offset range);
`p` is signed 17-bit. Both the four streaming lanes and 32 cached-filter lanes
call this same function. Host `signed_bits(...,9/10/17)` models those widths.

The plain function remains **int8_t input_offset** and uses `cfu_raw_op(4, 0,
N, input_offset)` (`lab2_api.cc:85–96`). It never depends on the previous SET9.
ConvPerChannel disarms reuse on both return paths (`conv.h:198–200,273–276`).
The offset is not a cached mode/global flag.

## Reproduce

From `TinyRISC-V-SoC-Platform/`:

```bash
bash Platform/hw/sim/run_offset9_tests.sh "$PWD/Platform/sw/results/offset9"
python3 Platform/hw/sim/check_offset9_mutations.py "$PWD/Platform/sw/results/offset9"
cd Platform
sha256sum -c sw/results/offset9/source_sha256.txt
```

The runner rebuilds the real API and the independently included reference;
uses ASan/UBSan; runs Verilator strict production-RTL lint, two directed RTL
seeds, the full regression, four-state Icarus, the grep audit, and (if the
installed cross compiler is available) the RV32 API disassembly.

Negative controls use **temporary copies**, never production files. All five
compiled and were rejected by functional assertions: host-model 8-bit decode,
API offset-int8 cast, omitted API disarm, RTL truncated SET9, RTL sticky SET8.
`mutations.log`: `detected=5 escaped=0`. Their intentional failure logs are
negative-control evidence, not failures of the production acceptance run.

Additional non-proxy regression evidence:

- `rtl_full.log`: **57,133 cases, PASS=43,520,197 FAIL=0**, including original
  length/alignment/error/reuse/filter-cache requirements.
- `host_broad.log`: historical `scratch/conv_host_test/build_and_run.sh`, updated
  to link the same real API/model: **2,582/2,582 cases**, **1,187,329 outputs**,
  **0 mismatches**, **0 stale reuse hits**, **0 changed-input rerun mismatches**.
- `legacy_host.log`: real plain API length/split test: **833 cases, 0 mismatches**.
- Existing Icarus burst-dot, aligned/misaligned AXI read/write, counter-width
  suites pass; counter report **8,006 checks, 0 failures**.
- `lint.log` is empty (strict `-Wall` lint exit 0).

**Deployment boundary:** the new SET9 instruction requires the updated RTL
bitstream as well as updated software. No existing-board bitstream, FPGA
performance, or board execution is claimed verified by these simulations.
