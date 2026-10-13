# Minimal MAC: evidence and completion audit

## Objective / success criteria

Minimize one MAC's CPU work without losing dirty-buffer cache coverage: aligned
32-byte line loops, at most two CUSTOM-0 instructions, no division, internal
calls, or extra loads/stores. Show built-main.elf disassembly and before/after
instruction counts. Preserve Lab 2 acceptance/resource/timing gates and add a
board-measured latency row lower than its predecessor. No RTL implementation
change or fabricated board measurement.

## Built binary and exact instruction counts

Command (source `~/NNchip/env.sh` first):

```sh
riscv64-unknown-elf-objdump -d Platform/build/sw/main.elf
```

The complete function extracts are `mac_minimal_before.dis` and
`mac_minimal_after.dis` in this directory. The before ELF and full dumps are
preserved under `~/NNchip/scratch/mac_minimal/`.

Counts include the return but exclude the caller's call instruction and operand
setup. They are dynamic architectural instruction counts, **not clock cycles**.
The before state is an ordinary call with no active clean ranges; successful
AXI response, aligned pointers, and cold SET registers unless noted.

| Case | Before | After | Before CUSTOM-0 | After CUSTOM-0 |
|---|---:|---:|---:|---:|
| N=0 | 3 | 3 | 0 | 0 |
| N=3, cold SET | 85 | 18 | 3 | 2 |
| N=3, matching SET | 84 | 18 | 2 | 2 |
| N=300, cold SET | 157 | 72 | 3 | 2 |
| N=300, matching SET | 156 | 72 | 2 | 2 |
| N=1025 | 362 | 210 | 6 | 2 |
| Static function size (all paths) | 165 instructions / 660 B | 20 instructions / 80 B | — | — |

For N>0, let `L1 = ceil(((ptr1 & 31)+N)/32)` and likewise L2. The after
count is exactly **12 + 3*(L1+L2)**: clean/add/branch per line, plus 12 fixed
instructions. These mathematical ceil expressions are explanatory, not CPU
division instructions. The before ordinary cold-SET count for N<=1024 is
`77 + 4*(L1+L2)` (matching SET: `76 + 4*(L1+L2)`). The former precleaned
matching-SET path executes 84 instructions at N=3 or 300, including 22 loads
and 14 stores. The new convolution precleaned helper is inlined and emits SET
and COMPUTE directly, with no ABI call/return or global-state accesses.

After disassembly (raw output; old objdump does not name CUSTOM-0/Zicbom):

```asm
600034b4 <hw_simd_mac>:
600034b4: 04068463  beqz a3,600034fc <hw_simd_mac+0x48>
600034b8: 0330000f  fence rw,rw
600034bc: 00d50733  add a4,a0,a3
600034c0: fe057793  andi a5,a0,-32
600034c4: 00e7f863  bgeu a5,a4,600034d4 <hw_simd_mac+0x20>
600034c8: 0017a00f  0x17a00f
600034cc: 02078793  addi a5,a5,32
600034d0: fee7ece3  bltu a5,a4,600034c8 <hw_simd_mac+0x14>
600034d4: 00d58733  add a4,a1,a3
600034d8: fe05f793  andi a5,a1,-32
600034dc: 00e7f863  bgeu a5,a4,600034ec <hw_simd_mac+0x38>
600034e0: 0017a00f  0x17a00f
600034e4: 02078793  addi a5,a5,32
600034e8: fee7ece3  bltu a5,a4,600034e0 <hw_simd_mac+0x2c>
600034ec: 0330000f  fence rw,rw
600034f0: 00c6c68b  0xc6c68b
600034f4: 02b5450b  0x2b5450b
600034f8: 00008067  ret
600034fc: 00000513  li a0,0
60003500: 00008067  ret
```

`0017a00f` = cbo.clean (a5); `00c6c68b` = CUSTOM-0 funct3=4,
funct7=0 SET(a3,a2); `02b5450b` = funct3=4, funct7=1 COMPUTE(a0,a1),
result a0. Two is the minimum for arbitrary N/offset/pointers under the existing
NPU.v contract: SET configures two operands, COMPUTE supplies the other two.
No CPU loads/stores, stack frame, division, or internal calls exist. The ordinary
external API retains its necessary call/return; the convolution hot path uses
the always-inline precleaned helper instead.

The loops start at `ptr & ~31`, advance 32, and stop at `ptr+N`. Empty ranges
return without touching memory. Thus every overlapping line is cleaned once
**per buffer**, including both partial endpoints. Valid non-wrapping buffers
are required. If buffers share a physical line, each buffer's loop visits it;
this API does not attempt cross-buffer deduplication. Two fences preserve
ordering on the decoupled EX/MEM core. They have not been removed merely to
improve timing.

## Prompt-to-artifact checklist and gate

| Requirement | Actual evidence and scope | Result |
|---|---|---|
| `lab2_api.cc`: line-aligned starts, line-size stride, no byte work | Source and exact after disassembly above; `mac_minimal_disasm_checks.log` | PASS |
| Every line of both dirty buffers cleaned, including unaligned ends | 16,384 executions of actual instruction words across all 32x32 offsets and 16 lengths (0..4097 representative boundaries); exact address sequence checked; board set/random tests do not preclean | PASS |
| At most 2 CUSTOM-0 and final command returns result | Word decoding and execution checks; RTL SET/COMPUTE contract inspected in NPU.v; N>1024 internal chunking verified in extended testbench | PASS |
| No division, internal function overhead, extra loads/stores | Whole 20-instruction leaf inspected; binary execution asserts no loads/stores/internal calls; precleaned convolution emits inline commands | PASS |
| Before and after built `main.elf` disassembly and per-call instruction counts | Before/after `.dis`, counts above, reproducible `mac_minimal_check_disasm.py` and log | PASS |
| Goal 1 AXI alignment, lengths, boundary splits, backpressure, errors | `mac_minimal_sim.log`: PASS=3316702 FAIL=0, including new 1025/2047/2048/2049/4097 cases at all byte-alignment pairs | PASS |
| Goal 3 actual board set/random | `mac_minimal_board_uart.log`: Pass 3/3 and Pass 100/100 | PASS |
| Goal 4 host convolution semantics and product/call topology | `mac_minimal_host.log`: 2545/2545, 1,157,263 outputs, zero mismatches/product-count/call-pattern failures | PASS |
| Goal 5 basic convolution and five model labels on actual board | Same UART log: 3 convolution PASS and 5 labels x 12 golden outputs PASS | PASS |
| Goal 5 latency <80% of 4,157,256,607 | 1,470,259,856 < 3,325,805,285.6 | PASS |
| Goal 6 LUT/FF/DSP/RAM/timing | Unchanged out.bit and reports: 1267 LUT <=20000, 757 FF <=5000, 4 DSP <=30, 0 RAMB36 <=135, 1 RAMB18 <=270, WNS +0.091 >=0 | PASS |
| New `lab2_latency.md` board row lower than previous | Row 3: 1,470,259,856 < row 2: 1,665,382,298; five-label total 7,351,299,280 | PASS |
| Build and environment | sw_build and sw/check-env pass; no OperatorCycleProfiler symbol | PASS |

The repository has no independently defined `GATE` executable/target. Here GATE
means the documented Lab 2 Goals 1/3/4/5/6 acceptance rows above, consistent with
the prior latency audit. A build or host test alone is **not** sufficient: host
stubs do not model cache/AXI; the binary checker does not model hardware timing;
RTL simulation does not model CPU cache coherence. Actual board results cover
the integrated path. There is no `make validate` target in this checkout; the
historical assertion of that command passing is not relied upon.

## Board provenance and reproduction

Digilent 0403:6010 and /dev/ttyUSB1 were visible; Vivado enumerated target
210319BE7776A and device xc7a100t_0 before programming. The existing bitstream
was programmed (End of startup status HIGH), then firmware uploaded and the
actual board menu ran `l`, `t`, `r`, `c`, `x`, `t`.

The first upload failed before UART due to root-owned `/tmp/vivado_jtag_server.*`.
The successful run used a private server TCL/log under scratch/mac_minimal,
then `make -C Platform -o kill_server run` to preserve that newly initialized
server. No application/hardware source was changed to work around the uploader.
The raw capture, driver, build logs, and baseline ELF remain in scratch/mac_minimal.

SHA-256 of the tested images:

- Board-run main.elf: `830b828c9841460fa52adf068fc02ff2ae693e731b46f2ac141fbfef49bf9450`
- Final rebuilt main.elf: `284d5b04606456a8923abb6092d0acb66c1fecf973458826dca1174081125231`
- main.bin: `946f27f2a535d70db426980d4ff2cf0514a35f9c16aeb5030d46198aac07e79b`
- out.bit: `83ebd9bcf2d7608ee3241bfbb0f1a0ef3825fa9a9da858142518aae6b5a49fa2`

```sh
# From repository root, with environment sourced:
make -C Platform sw_build
make -C Platform/sw check-env
python3 Platform/sw/results/mac_minimal_check_disasm.py \
  Platform/sw/results/mac_minimal_before.dis \
  Platform/sw/results/mac_minimal_after.dis
(cd Platform/hw && iverilog -g2012 -o /tmp/mac.vvp sim/npu_lab2_tb.sv \
  srcs/NPU.v srcs/npu_burst_dot_product.v && vvp -n /tmp/mac.vvp)
~/NNchip/scratch/conv_host_test/build_and_run.sh
```

No new RTL datapath change: only the simulation scoreboard/tests were extended.
Current post-route reports therefore remain applicable; no hw/srcs file is newer
than the bitstream. API and convolution edits are software-only.

Final audit also checked the native software-CFU fallback. The ordinary API now
invokes the two CFU macros directly rather than forwarding through the native
precleaned wrapper (which forwards ordinary calls to the host model). A native
smoke test verified ordinary/precleaned results, two commands, and empty calls.
After this source-only correction, rebuilding changed ELF debug information,
but **main.bin remained byte-for-byte identical to the board-tested image**,
and the extracted `hw_simd_mac` disassembly remained identical. Thus the board
measurement still applies to the final executable bytes.
