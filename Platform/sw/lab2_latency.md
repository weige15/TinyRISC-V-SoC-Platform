# Lab 2 latency: `interpreter.Invoke()` cycles over all labels

The average is taken over all five labels in `models/label` (label0, label1, label6, label8, label11), using the `Cycles:` line that the firmware prints around `interpreter.Invoke()`. The clock is 50 MHz. NPU resources come from the recursive NPU-only post-route report `build/reports/post_route_utilization_npu.rpt`. BRAM is counted in BRAM36 equivalents, so one RAMB18 = 0.5. WNS is the overall setup WNS in `build/reports/post_route_timing_summary.rpt`.

| # | Change | Avg cycles | vs Goal 5 | LUT | FF | DSP | BRAM36 eq. (RAMB36/RAMB18) | WNS (ns) | Checks | Kept |
|---|---|---:|---:|---:|---:|---:|---|---:|---|---|
| 0 | Goal 5 baseline (`results/goal5_acc_uart.log`) | 4,157,256,607 | — | 1267 | 757 | 4 | 0.5 (0/1) | 0.091 | Goal 5 green | baseline |
| 1 | SW only: per-conv cache clean instead of per-call clean and fences, SET skipped when N/offset are unchanged, up to 1024 B per NPU command, offset 128 computed as 127 + NPU filter tap sums | **1,817,586,108** | **−56.3%** | 1267 | 757 | 4 | 0.5 (0/1) | 0.091 | all green | yes |

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
