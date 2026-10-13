# Lab 2 latency: `interpreter.Invoke()` cycles over all labels

The average is taken over all five labels in `models/label` (label0, label1, label6, label8, label11), using the `Cycles:` line that the firmware prints around `interpreter.Invoke()`. The clock is 50 MHz. NPU resources come from the recursive NPU-only post-route report `build/reports/post_route_utilization_npu.rpt`. BRAM is counted in BRAM36 equivalents, so one RAMB18 = 0.5. WNS is the overall setup WNS in `build/reports/post_route_timing_summary.rpt`.

| # | Change | Avg cycles | vs Goal 5 | vs O1 normal baseline | LUT | FF | DSP | BRAM36 eq. (RAMB36/RAMB18) | WNS (ns) | Checks | Kept |
|---|---|---:|---:|---:|---:|---:|---:|---|---:|---|---|
| 0 | Goal 5 baseline (`results/goal5_acc_uart.log`) | 4,157,256,607 | — | — | 1267 | 757 | 4 | 0.5 (0/1) | 0.091 | Goal 5 green | baseline |
| 1 | SW only: per-conv cache clean instead of per-call clean and fences, SET skipped when N/offset are unchanged, up to 1024 B per NPU command, offset 128 computed as 127 + NPU filter tap sums | **1,817,586,108** | **−56.3%** | −0.14% | 1267 | 757 | 4 | 0.5 (0/1) | 0.091 | all green | yes |
| 2 | Merge full filter rows only at fully in-bounds output positions; 1x1 stride-1 fast path hoists row/channel pointers and quantization values; border positions use per-tap checks | **1,665,382,298** | **−59.9%** | **−8.50%** | 1267 | 757 | 4 | 0.5 (0/1) | 0.091 | host and board acceptance pass | yes |
| 3 | Stateless two-command MAC; always-clean ordinary API; explicit inline precleaned convolution path; no SET/range/counter bookkeeping | **1,470,259,856** | **−64.6%** | **−19.22%** | 1267 | 757 | 4 | 0.5 (0/1) | 0.091 | binary coverage, extended RTL, host and board acceptance pass | yes |
| 4 | RTL: overlapped maximal bursts, circular operand RAM, arrival-cycle MAC, immediate result/done retirement | **1,407,784,607** | **−66.14%** | **−22.66%** | 3090 | 685 | 4 | 0 (0/0) | 0.187 | four RTL seeds, negative controls, host and fresh board acceptance pass | yes |
| 5 | ptr1 operand reuse: NPU keeps the last AXI-fetched ptr1 vector; armed only inside `ConvPerChannel`; pointwise loop made pixel-major so 299 of 300 calls per pixel burst only ptr2 | **1,374,100,586** | **−66.95%** | **−24.51%** | 3160 | 773 | 4 | 0 (0/0) | 0.596 | four RTL seeds incl. reuse cases, reuse and stream negative controls, host and fresh board acceptance pass | yes |

Limits (Goal 6): LUT ≤ 20,000, FF ≤ 5,000, DSP ≤ 30, RAMB18 ≤ 270, RAMB36 ≤ 135, WNS ≥ 0. All are met.

## Where the time went (Goal 5 baseline)

Per-operator profile of label0, built with `APP_DEFINES=-DTFLM_OPERATOR_CYCLE_PROFILE=1`:

| Node | Op | Shape | Cycles |
|---|---|---|---:|
| 8 | CONV_2D | 3×3×1 → 300, dilation (2,1), offset −102: 729,000 calls with N = 3 | 1,091,542,417 |
| 10–18 | CONV_2D | 1×1×300 → 300, offset 128: 492,000 outputs, 2 calls each (offset split) | 1,985,835,267 |
| 9–17 | DEPTHWISE_CONV_2D | software, not in the allowed files | 838,694,364 |
| 3, 4 | AudioSpectrogram, Mfcc | software | 221,322,892 |

On-board micro-benchmark (temporary, not committed):

| Operation | Cycles |
|---|---:|
| `hw_simd_mac`, N = 1 | 884 |
| `hw_simd_mac`, N = 300 | 1341 |
| raw COMPUTE command, N = 1 | 109 |
| raw COMPUTE command, N = 300 | 258 |
| raw SET or STATUS | 13 |
| `cbo.clean` on a clean line | 12 |
| `fence rw,rw` | 54 |

`fence` is expensive on this core. A plain `fence` sets `fetch_invalid` (Control.v), which flushes and invalidates the I-cache (`Backend_top.v`, `invalidate_o = fencei_flush`). The code after it is then fetched again from DDR. The two fences per call explain most of the ~600 cycles that the parts listed above do not cover.

## Attempt 1 (kept): software-only changes

Files: `project/lab2_api.cc` and `tflm_patches/.../integer_ops/conv.h`. No RTL change, so the Goal 3–6 bitstream (`build/out.bit`, Oct 7 22:39) is unchanged.

- **Cheaper cache cleaning.** At the start of `ConvPerChannel`, `hw_simd_mac_assume_clean_begin()` (in `lab2_api.cc`) cleans the whole input and filter tensors once, between two fences. It also records the two address ranges. Until `hw_simd_mac_assume_clean_end()`, a `hw_simd_mac` call whose two vectors both lie inside those ranges skips its per-call `cbo.clean` loop, its fences and the STATUS read. The kernel enables this only when the output tensor does not overlap the input or filter tensor; the output is the only memory the kernel writes. Any other call, including every set/random test call, still cleans, fences and checks STATUS.
- **Fewer command round-trips.**
  - `lab2_api.cc` keeps a software copy of the NPU SET registers and issues SET only when N or the offset changes. In a convolution, SET is therefore almost never issued.
  - One NPU command now covers up to 1024 bytes, one full input-buffer chunk of `npu_burst_dot_product.v`. Before, the limit was 256 bytes, so N = 300 took two commands. `hw/sim/npu_lab2_tb.sv` now also sweeps N = 257..1024: every N, plus all 16 alignment pairs for N = 1021..1024.
- **Offset 128 in one pass.** The pointwise convolutions have input zero point −128, so input_offset = 128, which int8 cannot hold. They used to take two `hw_simd_mac` calls per output: 2·(x+64)·w − x·w. They now take one call:
  - `sum (x+128)·w = sum (x+127)·w + sum (0+1)·w`.
  - The filter tap sums `sum (0+1)·w` are also formed by the NPU, as `hw_simd_mac(zero_vector, tap, 1, depth)`. They are computed once per tap at the start of every convolution invocation; nothing is kept between inferences. They are added like a bias.
  - If a filter has more than 4096 taps, the kernel falls back to the two-call split.
- Row merging (`filter_width × depth` in one call when the filters are not grouped and dilation_width = 1) was already in place, so it is unchanged.

Verification (fresh output, saved under `results/`):

| Check | Result | Evidence |
|---|---|---|
| Goal 1 simulation (`iverilog -g2012`, `npu_lab2_tb.sv`, now including N ≤ 1024) | `RESULT: PASS=2859851 FAIL=0` | `results/latency_att1_sim.txt` |
| Goal 4 host test (`scratch/conv_host_test`) | `ALL PASS: 2543/2543 cases pass, 1193599 outputs compared, 0 mismatches`, NPU product-count check failures 0 (the broken-offset copy still fails: 363837 mismatches) | `results/latency_att1_host_test.txt` |
| Goal 6 limits / WNS | NPU 1267 LUT, 757 FF, 4 DSP, 0 RAMB36, 1 RAMB18; WNS 0.091 ns, "All user specified timing constraints are met." No file under `hw/srcs` is newer than `out.bit`. | `build/reports/` |
| Goal 3 set / random tests (board) | `Pass 3/3`, `Pass 100/100` | `results/latency_att1_board_uart.log` |
| Basic convolution tests (board) | 3 × `[PASS]` (2,317,190 cycles total, down from 9,027,519) | same log |
| Goal 5 labels (board) | all 5 labels: `ALL 12 GOLDEN OUTPUTS PASS` | same log |

Per-label cycles for attempt 1: label0 1,746,097,494; label1 1,857,956,233; label6 1,861,128,941; label8 1,784,760,040; label11 1,837,987,831. The total is 9,087,930,539, so the average is 1,817,586,108. That is 56.3% below the Goal 5 baseline of 4,157,256,607 and better than the required 20%, whose ceiling is 3,325,805,286.

## How to reproduce

```sh
# Goal 1 simulation
cd Platform/hw && iverilog -g2012 -o /tmp/tb.vvp sim/npu_lab2_tb.sv srcs/NPU.v srcs/npu_burst_dot_product.v && vvp -n /tmp/tb.vvp | tail -3
# Goal 4 host test
~/NNchip/scratch/conv_host_test/build_and_run.sh
# Board: build, reset by reprogramming, upload, run lab2 t/r/c and all labels
make -C Platform sw_build && ~/NNchip/scratch/board_run.sh /tmp/run.log "" trc 1
```

## Normal non-profiling board run: ranking baseline

Built from the same firmware commit with `APP_DEFINES` unset using
`make -C TinyRISC-V-SoC-Platform/Platform/sw MODEL_FILE=ds_cnn_stream_fe.tflite MODEL_PROFILE=ds_cnn_stream_fe`;
the ELF had no `OperatorCycleProfiler` symbol. Normal image SHA-256:
`bfc87b7626f3f829031ee4b21d9edac3e5f28f60c010524854bb9d171eb90a35`. The UART
run passed the 12 golden outputs for each fixture. Capture:
`~/NNchip/scratch/lab2_start/normal_inference_uart.raw`.

| Label | `Invoke()` cycles |
|---|---:|
| label0 | 1,748,565,148 |
| label1 | 1,860,636,531 |
| label6 | 1,863,805,327 |
| label8 | 1,787,225,810 |
| label11 | 1,840,641,372 |
| **Total** | **9,100,874,188** |
| **Average (ranking baseline)** | **1,820,174,837.6** (1,820,174,838 rounded) |

This fresh non-profiling average is the ranking baseline for the measurements
below; the earlier Attempt 1 figures remain as historical results.

## Operator profiling: all five labels

Built from firmware commit `70d73868db43c834c1db1c98b25afbe18b2c2c95` with
`make -C TinyRISC-V-SoC-Platform/Platform/sw MODEL_FILE=ds_cnn_stream_fe.tflite MODEL_PROFILE=ds_cnn_stream_fe APP_DEFINES=-DTFLM_OPERATOR_CYCLE_PROFILE=1`
(profiling image SHA-256
`b75c7d61fba84559034c2dcfe8cd2efaa0052d6af62cc1f6a48c36a3c48b796f`). The
profiled image ran all five fixtures; every label reported `ALL 12 GOLDEN
OUTPUTS PASS`. Full UART capture: `~/NNchip/scratch/lab2_start/profile_inference_uart.raw`.

Per-operator cycles (sum over nodes of each operator type):

| Operator (node count) | label0 | label1 | label6 | label8 | label11 |
|---|---:|---:|---:|---:|---:|
| QUANTIZE (2) | 5,646,405 | 7,798,567 | 7,895,108 | 7,471,926 | 7,349,405 |
| RESHAPE (2) | 86,304 | 84,680 | 90,608 | 84,586 | 84,608 |
| DEQUANTIZE (2) | 4,736,885 | 6,802,329 | 7,348,099 | 5,526,899 | 6,063,162 |
| AudioSpectrogram (1) | 169,028,183 | 244,400,977 | 247,019,354 | 193,752,818 | 230,330,364 |
| Mfcc (1) | 52,892,683 | 82,946,937 | 82,802,085 | 63,183,551 | 78,510,449 |
| MUL (1) | 142,057 | 144,512 | 144,096 | 143,995 | 143,952 |
| CONV_2D (6) | 675,774,662 | 676,855,315 | 676,882,400 | 676,301,635 | 676,743,344 |
| DEPTHWISE_CONV_2D (5) | 830,501,824 | 831,065,581 | 831,032,892 | 830,731,828 | 830,951,039 |
| AVERAGE_POOL_2D (1) | 425,139 | 425,079 | 425,127 | 425,136 | 425,054 |
| FULLY_CONNECTED (1) | 59,507 | 59,500 | 59,480 | 59,473 | 59,474 |

Per-node `CONV_2D` cycles:

| Node | label0 | label1 | label6 | label8 | label11 |
|---:|---:|---:|---:|---:|---:|
| 8 | 304,112,597 | 304,167,823 | 304,148,982 | 304,140,503 | 304,146,014 |
| 10 | 154,745,978 | 155,332,626 | 155,395,068 | 154,998,328 | 155,287,432 |
| 12 | 105,660,181 | 105,998,133 | 105,959,823 | 105,783,064 | 105,945,370 |
| 14 | 68,643,479 | 68,616,936 | 68,608,894 | 68,604,618 | 68,601,517 |
| 16 | 30,360,884 | 30,402,610 | 30,407,692 | 30,404,861 | 30,406,318 |
| 18 | 12,251,543 | 12,337,187 | 12,361,941 | 12,370,261 | 12,356,693 |

Profiling-build `Invoke()` totals were label0 1,742,736,370; label1
1,854,026,051; label6 1,857,143,800; label8 1,781,125,180; label11
1,834,103,514 cycles (9,069,134,915 total; 1,813,826,983 average). These
instrumented figures are diagnostic only; the ranking baseline is the separate
normal-build average above.

## Host-side `hw_simd_mac` call counts

Verified by `~/NNchip/scratch/conv_host_test/build_and_run.sh` for the six
`CONV_2D` layer shapes in `ds_cnn_stream_fe`. `O1` is the legacy per-tap call
topology (one call per in-image depth dot; two calls for input offset 128).
The new column is measured from `hw_simd_mac_cnt`. `N` values are shown as
`N × call-count`.

| Layer | O1 calls | New calls | N values used |
|---:|---:|---:|---|
| 0 | 2,187,000 | 729,000 | 3 × 729,000 |
| 1 | 412,800 | 206,700 | 300 × 206,700 |
| 2 | 280,800 | 140,700 | 300 × 140,700 |
| 3 | 180,000 | 90,300 | 300 × 90,300 |
| 4 | 79,200 | 39,900 | 300 × 39,900 |
| 5 | 31,200 | 15,900 | 300 × 15,900 |
| **Total** | **3,171,000** | **1,222,500** | `N=3`: 729,000; `N=300`: 493,500 |

The extended host test passed 2,545/2,545 cases, compared 1,157,263 outputs
with zero mismatches, and reported zero product-count and call-pattern
failures. It asserts `N=3 × 729,000` for conv 0 and specifically checks that
SAME-padded border positions stay on the per-tap path (`N=1 × 88`); fully
in-bounds positions merge their rows (`N=3 × 27`). Output is saved at
`results/conv_row_fast_host_test.txt`.

## Current kernel board verification

The non-profiling firmware was built with `make -C Platform sw_build` (default
`-O3`, no operator profiler); `main.bin` SHA-256:
`4634edd1731e6a3652fd4d48348ba149eaf467a0a34b6fd367acbd43d4c97439`.
The NPU RTL and bitstream are unchanged; only firmware was rebuilt. UART capture:
`results/conv_row_fast_board_uart.log`.

The board acceptance checks all passed: Lab 2 set tests 3/3, random tests
100/100, convolution golden tests 3/3, and all 12 golden outputs for each of
the five labels. The `Invoke()` measurements were:

| Label | `Invoke()` cycles |
|---|---:|
| label0 | 1,593,070,060 |
| label1 | 1,706,195,804 |
| label6 | 1,709,349,503 |
| label8 | 1,632,215,665 |
| label11 | 1,686,080,456 |
| **Total** | **8,326,911,488** |
| **Average** | **1,665,382,298** |

This is 8.50% below the O1 normal-build ranking baseline of 1,820,174,838
cycles (five-label average above), and 59.9% below the Goal 5 baseline.

## Lab 2 acceptance-gate audit

No standalone target or status artifact named `GATE` exists in the repository.
I audited the documented Lab 2 checks that gate this result:

| Gate | Current evidence | Result |
|---|---|---|
| Goal 1 NPU simulation | `results/conv_row_fast_goal1_sim.txt`: `RESULT: PASS=2859851 FAIL=0` | PASS |
| Goal 3 board set/random tests | `results/conv_row_fast_board_uart.log`: `Pass 3/3`, `Pass 100/100` | PASS |
| Goal 4 host convolution test | `results/conv_row_fast_host_test.txt`: 2,545/2,545, 0 mismatches, 0 product/call-pattern failures | PASS |
| Goal 5 board convolution and model goldens | Same board log: 3/3 convolution cases and 5/5 labels with 12/12 golden outputs | PASS |
| Goal 5 latency gate (at least 20% below baseline) | 1,665,382,298 cycles < 3,325,805,286 ceiling (80% of 4,157,256,607 baseline) | PASS |
| Goal 6 resource/timing limits | Unchanged bitstream report: 1,267 LUT, 757 FF, 4 DSP, 0 RAMB36, 1 RAMB18; WNS +0.091 ns | PASS |

`make validate` and the default `-O3`, non-profiling `sw_build` also passed.
Thus the repository-defined Lab 2 gates hold for this firmware. If `GATE` names
an additional external criterion, it is not specified in this repository.

Firmware revision used for the original normal-run measurements and profiling
build: `70d73868db43c834c1db1c98b25afbe18b2c2c95` (`TinyRISC-V-SoC-Platform`
HEAD). The current row-2 firmware includes the uncommitted `conv.h` changes
described above.

## Attempt 3: minimal CPU-side MAC (2026-10-12)

Board average **1,470,259,856 cycles**, total **7,351,299,280** over the same five
labels; **11.72% below row 2**. No operator profiling. UART evidence:
`results/mac_minimal_board_uart.log`. All five labels pass all 12 golden outputs;
Lab 2 set/random tests pass 3/3 and 100/100; basic convolution passes 3/3.

`lab2_api.cc` now always cleans both buffers, one clean per overlapping 32-byte
line per buffer, with no hidden precleaned-range state. Both ordering fences are
retained. It sends SET(N, offset) then COMPUTE(ptr1, ptr2), returning COMPUTE's
result directly. The existing RTL handles lengths beyond 1024 internally.
STATUS remains available for diagnostics, but is not read on the hot path.
There is no CPU chunk loop, SET cache, printf, or production counter update.
`hw_simd_mac_cnt` is retained only for source compatibility; the host model
still instruments calls independently.

The existing convolution bulk clean is retained through an **explicit**
`hw_simd_mac_precleaned` inline helper, selected only when the output is disjoint
from both complete cleaned tensors. Tap-sum zero-vector calls and ordinary Lab 2
tests still use the always-clean API. The inline convolution path executes two
CUSTOM-0 instructions without a function call or global bookkeeping. This
change is not a claim that repeatedly cleaning every convolution dot would
beat the former bulk-clean path.

Full before/after disassembly, dynamic instruction counts, verification scope,
and the prompt-to-artifact audit are in
[`results/mac_minimal_audit.md`](results/mac_minimal_audit.md).

Correction to the historical gate notes above: the current checkout has **no
`make validate` target**, at either repository or Platform level. The attempted
commands failed, so they are not claimed as current passing checks. The actual
build/environment, binary, RTL, host, and board checks are listed in the audit.

## Attempt 4: streaming RTL (2026-10-13)

Same non-profiling firmware bytes and 50-MHz clock as row 3; only the hardware
changed. The new five-label average is **1,407,784,606.8 cycles** (rounded in the
ranking table), **4.25% below row 3**. All set tests (3/3), random tests (100/100),
basic convolution cases (3/3), and all five labels' 12 golden words passed on
the newly rebuilt/programmed Arty A7. Evidence:
[`results/stream_npu/board_uart.log`](results/stream_npu/board_uart.log).

| Label | `Invoke()` cycles |
|---|---:|
| label0 | 1,334,586,475 |
| label1 | 1,449,150,613 |
| label6 | 1,452,308,693 |
| label8 | 1,374,173,213 |
| label11 | 1,428,704,040 |
| **Total** | **7,038,923,034** |
| **Average** | **1,407,784,606.8** |

### RTL call latency

Measured from the COMPUTE `NPU_start` sampling edge to the edge asserting
`NPU_done` with the result. SET/STATUS and software/cache overhead are not part
of this RTL measurement. Every row below covers all 16 independent byte-alignment
pairs. Random-stall ranges below use seed 20261007; three additional seeds also
pass. Every individual measurement is in
[`results/stream_npu/latency.csv`](results/stream_npu/latency.csv), with the actual
testbench stdout in `results/stream_npu/sim_*.log`.

| N (bytes) | Zero-wait cycles (all alignments) | Random AR/R stall cycles (all alignments) |
|---:|---:|---:|
| 1 | 5 | 5–19 |
| 3 | 5–7 | 5–21 |
| 64 | 35–37 | 38–148 |
| 256 | 131–133 | 134–663 |
| 300 | **153–155** | 154–587 |

Let `B = ceil((N + ptr1[1:0])/4) + ceil((N + ptr2[1:0])/4)`.
Zero-wait latency is **B + 3**, including tested 4-KiB and 256-beat transitions.
Every fixed cycle is accounted for:

- Edge 0: accept `NPU_start`, latch operands, present the first AR request.
- Edge 1: first AR handshake; prepare the next request without a setup state.
- Edges 2 through B+1: B consecutive R handshakes; raw input is stored and each
  filter beat enters the MAC on its arrival edge. The ptr2 AR request overlaps
  ptr1 data (for a one-beat input, it overlaps that single beat).
- Edge B+2: retire the last registered lane sum into the result.
- Edge B+3: publish `NPU_out` and `NPU_done` together, without `STATE_DONE`.

Thus the visible result/done is exactly **2 cycles after the final RLAST**.
N=300 is at most **155 < 170** cycles, including alignment overhead; the
zero-wait stream has **zero bubbles**. Random stalls may postpone an AR
handshake, but ARVALID is already offered while ptr1 data is arriving and is
held stable until accepted.

The RTL regression retains Goal 1 checks and adds long-vector/ring-wrap/error
coverage, including draining prefetched and stalled-AR requests after an error.
Four seeds each run 5,803 COMPUTEs / 17,409 commands with **0 failures**. The
final routed NPU uses **3,090 LUT, 685 FF, 4 DSP, 0 RAMB18/36**; overall setup
**WNS +0.187 ns**, with all timing constraints met. Full prompt-to-artifact
coverage, build provenance, limits, and reproduction commands:
[`results/stream_npu_audit.md`](results/stream_npu_audit.md).

## Attempt 5: ptr1 operand reuse (2026-10-13)

Five-label board average **1,374,100,586.4 cycles** (total 6,870,502,932),
**2.39% below row 4** (1,407,784,606.8). All checks green on a newly built and
programmed bitstream: set tests 3/3, random tests 100/100, basic convolution
3/3, and all 60 Actual/Golden words of the five labels match. Evidence:
[`results/operand_reuse/board_uart.log`](results/operand_reuse/board_uart.log).

| Label | `Invoke()` cycles |
|---|---:|
| label0 | 1,303,250,950 |
| label1 | 1,414,153,418 |
| label6 | 1,417,286,009 |
| label8 | 1,341,504,973 |
| label11 | 1,394,307,582 |
| **Total** | **6,870,502,932** |
| **Average** | **1,374,100,586.4** |

### Rule and implementation

Reused bytes may come only from earlier AXI bursts (confirmed 2026-10-13). They
are never written by software.

- **RTL** (`npu_burst_dot_product.v`, `NPU.v`). The raw ptr1 words of a COMPUTE
  are already stored in the circular input RAM. That RAM is written only from
  accepted, error-free R beats. The engine records the key `(ptr1, N)`. The copy
  becomes valid after an **armed**, error-free COMPUTE whose ptr1 covering words
  fit the 1024-word RAM (no ring wrap). While armed, a COMPUTE with the same
  ptr1 and N skips every ptr1 burst and fetches only ptr2. The offset may
  differ, because it is applied in the MAC. Any miss invalidates the copy
  first, because it overwrites the RAM. These also invalidate it:
  - any error;
  - arming or disarming, new CUSTOM-0 `funct3=4, funct7=3` (REUSE,
    `rs1[0]` = arm, `rd = rs1[0]`);
  - an NPU single-word AXI write.

  Reset leaves reuse disarmed. ptr2 is burst on every call; caching filters is
  left to O6.
- **Software.** `lab2_api.cc` exports `hw_simd_mac_reuse_arm()` and
  `hw_simd_mac_reuse_disarm()`. Only `conv.h`'s int8 `ConvPerChannel` calls
  them, in this order:
  1. It runs only on the output-disjoint (precleaned) path.
  2. `hw_simd_mac_assume_clean_begin()` cleans the input and filter tensors once.
  3. The tap-sum calls run, still unarmed.
  4. It arms.
  5. It disarms before both return points.

  Between arm and disarm the kernel stores only to the output tensor, which does
  not overlap the input. Standalone `hw_simd_mac`, including all Lab 2 set and
  random tests, never arms, so every call fetches both operands.
- **Kernel loop order.** The 1x1 stride-1 path is now pixel-major (`out_y`,
  `out_x`, `out_channel`). All output channels of a pixel use the same input
  vector back to back; group changes advance it. The host test counts, for
  example, 205,712 hits out of 206,700 calls in layer 1: one ptr1 fetch per
  pixel plus the 300 unarmed tap-sum calls.
- **RTL latency.** With a zero-wait slave, a hit with N=300 takes **79–80
  cycles** (all four ptr2 alignments, 75–76 beats, no gaps, done 2 cycles after
  the last RLAST). A miss takes 153–155 cycles. A hit spends one extra cycle,
  because the first ptr2 AR is issued by the scheduler and not on the start edge.
  This keeps the start path's timing short.

### Verification (current sources; hashes in `results/operand_reuse/source_sha256.txt`)

| Check | Result | Evidence |
|---|---|---|
| RTL testbench, 4 seeds (all previous checks plus new section 7) | seeds 20261007 / 7 / 314511048 / 20261013: PASS = 10,586,432 / 10,264,679 / 10,498,827 / 10,407,305, **FAIL=0** each; legacy burst, misaligned read and write benches pass; Verilator `-Wall` lint clean | `results/operand_reuse/rtl_suite.log`, `rtl/` |
| Section 7 coverage, per seed | 200 changed-memory cases (60 from reset, 60 after arm+disarm, 40 armed→disarm→mutate, 40 re-arm→mutate). Same ptr1/N/ptr2/offset; the exact AR list must refetch ptr1, and the result must match the new data. In all 120 reset/disarmed pairs, the mutation changes the expected value. Unchanged-memory calls after disarm or re-arm must also refetch. Armed sequences use N = 1…4096 and all alignments: a miss, then hits with fresh ptr2 data, self-operand, different N, neighbouring ptr1, oversize (1025 words or more, never reused), and errors on input or filter bursts. About 1,140 hits, all matching the reference with only ptr2 ARs. | `rtl/sim_*.log` (`[INFO] reuse:`) |
| Reuse negative controls | All 7 mutants fail the unmodified testbench: reuse while disarmed, ignore N, ignore ptr1, keep after error, arm keeps copy, reuse a wrapped vector, never reuse | `hw/sim/check_reuse_mutations.py`, `results/operand_reuse/mutations.log` |
| Stream negative controls | Control passes; all 6 stream mutations detected | `results/operand_reuse/stream_mutations.log` |
| Host test (reuse-aware model: a hit computes from the copied bytes) | `ALL PASS: 2540/2540 cases pass, 1172436 outputs compared, 0 mismatches`. Product-count and call-pattern failures: 0. 1,037,874 hits, 0 stale hits, 0 arms outside a clean region, 0 returns while armed. Every case also reruns on the same buffers after mutating the input: 0 mismatches. Negative controls: removing the pointwise disarm aborts; writing the input while armed gives 500,640 stale hits and FAILED. | `results/operand_reuse/host.log` |
| Goal 3 / 5 board | Pass 3/3, Pass 100/100, Testcases 1–3 Output Correct, 5 labels × 12 golden words all PASS | `results/operand_reuse/board_uart.log` |
| Goal 6 limits / WNS | NPU (recursive, one instance `MMIO_i/NPU_0/inst`): **3160 LUT ≤ 20,000, 773 FF ≤ 5,000, 4 DSP ≤ 30, 0 RAMB18 ≤ 270, 0 RAMB36 ≤ 135**. Overall setup **WNS +0.596 ns**, TNS 0; "All user specified timing constraints are met." | `results/operand_reuse/post_route_utilization_npu.rpt`, `post_route_timing_summary.rpt.gz` |
| Tested image | `out.bit` `6359419d…0e47` and `main.bin` `08de32cb…e361` were hashed before the run and match the current build. No RTL or firmware source is newer than `out.bit`. | `results/operand_reuse/board_image_sha256.txt` |

Reproduce:

```sh
bash Platform/hw/sim/run_lab2_stream_tests.sh /tmp/lab2-tests
python3 Platform/hw/sim/check_reuse_mutations.py /tmp/lab2-reuse-mutations
python3 Platform/hw/sim/check_stream_mutations.py /tmp/lab2-stream-mutations
~/NNchip/scratch/conv_host_test/build_and_run.sh
make -C Platform prog && make -C Platform run   # menu: l, t, r, c, x, t
```
