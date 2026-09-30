# ds_cnn_stream_fe inference latency: per-operator profiling and AXI + SIMD convolution restructure

## Result

| Measurement (one label1 inference, `Cycles:` around `interpreter.Invoke()`) | Cycles |
|---|---:|
| Accelerated AXI + SIMD before this work ([`accelerated_inference_comparison.md`](accelerated_inference_comparison.md)) | 13,469,246,096 |
| Required ceiling (at least 25% lower) | 10,101,934,572 |
| **Final clean build (`TFLM_SOFTWARE_CONV=0`, profiling disabled), FPGA** | **5,335,912,041** |
| Reduction | 8,133,334,055 (60.38%), 2.524× faster |

The output is bit-identical to the software/reference baseline, and menu tests a, e, c, and b all pass on the FPGA. No RTL changed, so the existing bitstream was used.

## Configuration (unchanged)

- Model `models/ds_cnn_stream_fe.tflite`, profile `ds_cnn_stream_fe`, profile `label1_data` board input, one sample. These come from the local `Platform/sw/project.mk` recorded in [`software_inference_baseline.md`](software_inference_baseline.md).
- Tensor arena 1,048,576 bytes (the build log shows `-DTENSOR_ARENA_SIZE=1048576`). Clock 50,000,000 Hz.
- Compiler flags, `Makefile`, model, input, golden/baseline documents, tests, and the `TFLM_SOFTWARE_CONV=1` reference selection are unchanged. The `mcycle` reads immediately before and after `interpreter.Invoke()` are unchanged.
- Bitstream `Platform/build/out.bit` SHA-256 `8871f97eb3cccb3bc171f0d3c9384224497fc48c677677a760fcee1e313e2b84`. This is the same bitstream as the earlier accelerated run, and `Platform/hw` has no changes.

## Files changed

- `Platform/sw/app/tflm_runner.cc`: adds the per-operator cycle profiler `OperatorCycleProfiler`, which implements `tflite::MicroProfilerInterface` and reads `mcycle`. It is compiled only when the build defines `TFLM_OPERATOR_CYCLE_PROFILE`. It prints a live per-node line during Invoke, then a per-node table and a per-operator table (node count, cycles, share of Invoke). Without the define, the runner is functionally the same as before: same interpreter construction, same measurement, and no profiler code in the image. The profiler is a stack object because this runtime runs no global constructors (the ELF has no `.init_array`). A static instance had a null vtable and hung on the first `BeginEvent`.
- `Platform/sw/tflm_patches/tensorflow/lite/kernels/internal/reference/integer_ops/conv.h`: restructures the int8 AXI + SIMD `ConvPerChannel`. Details are in "Optimization" below. The int16 kernel and the int4 wrapper are unchanged.

## Measurement before optimizing

To enable profiling, build with `APP_DEFINES=-DTFLM_OPERATOR_CYCLE_PROFILE=1`. This is only for profiling builds; the final measured build does not use it.

```sh
cd TinyRISC-V-SoC-Platform
make -j8 -C Platform/sw BUILD_DIR=/tmp/nnchip-operator-profile-build \
  MODEL_FILE=ds_cnn_stream_fe.tflite MODEL_PROFILE=ds_cnn_stream_fe \
  TFLM_SOFTWARE_CONV=0 APP_DEFINES=-DTFLM_OPERATOR_CYCLE_PROFILE=1 all
```

The first profiled run used the unchanged accelerated `conv.h` from `accelerated_inference_comparison.md`. The UART log is `/tmp/nnchip-operator-profile-accelerated-run.log`, SHA-256 `4b05cc05…da4e`. Invoke total was 13,569,656,899 cycles. That is 0.7% above the unprofiled 13,469,246,096 because of the live UART lines. Output words were identical.

| operator | nodes | cycles | share |
|---|---:|---:|---:|
| QUANTIZE | 2 | 8,210,145 | 0.06% |
| RESHAPE | 2 | 85,421 | 0.00% |
| DEQUANTIZE | 2 | 6,777,807 | 0.04% |
| AudioSpectrogram | 1 | 247,041,247 | 1.82% |
| Mfcc | 1 | 83,286,564 | 0.61% |
| MUL | 1 | 142,866 | 0.00% |
| **CONV_2D** | 6 | **12,391,576,612** | **91.31%** |
| DEPTHWISE_CONV_2D | 5 | 828,630,518 | 6.10% |
| AVERAGE_POOL_2D | 1 | 407,631 | 0.00% |
| FULLY_CONNECTED | 1 | 61,168 | 0.00% |
| (sum of operators) | 22 | 13,566,219,979 | 99.97% |
| (Invoke total) | | 13,569,656,899 | |

CONV_2D per node: node 8 (3×3, 1 input channel) 400,954,121. Pointwise 1×1×300→300 nodes: node 10 5,030,032,243; node 12 3,420,759,096; node 14 2,193,849,964; node 16 965,692,469; node 18 380,288,719.

Node 10 has 688 pixels × 300 output channels × 75 four-channel groups, which works out to **325 cycles per 4-channel group**. A one-off on-board latency probe was run as a temporary change in a profiling build and then removed. Per operation, including loop overhead, it measured:

- NPU AXI read: 50 cycles
- SIMD MAC: 8 cycles
- cached `lw`: 6 cycles
- `cbo_clean`: 9 cycles

So the two AXI reads plus one SIMD MAC account for about 108 of the 325 cycles. About 217 cycles per group came from software in the kernel:

- The kernel iterated once per input channel (4 iterations per group).
- It computed two 4-D `Offset()` index multiplications and alignment checks per group.
- It byte-reversed both words.
- It ran a 4-lane filter-sum loop and an `input_offset` multiply for every group of every output pixel.

## Optimization: int8 AXI + SIMD `ConvPerChannel` restructure (chosen from the CONV_2D row)

The kernel still feeds every word-aligned 4-channel group through two NPU AXI reads and one SIMD MAC. Unaligned taps and the remaining channels still use scalar reference arithmetic. Input and filter are still cleaned per 32-byte line before the NPU reads them. The changes:

1. **One inner loop per filter tap** (`AxiSimdDotProduct`). It advances pointers by 4 channels and issues AXI read, AXI read, SIMD MAC. The first group uses SIMD reset, and later groups accumulate. There is no per-channel iteration and no `Offset()` in the inner loop; tap/row/pixel pointers are computed incrementally.
2. **No byte reversal.** The SIMD MAC pairs lane k of `rs1` with lane k of `rs2`. Feeding both AXI words unreversed applies the same lane permutation to both operands, so the dot product is unchanged.
3. **Input-offset correction precomputed once per convolution.** The SIMD MAC multiplies raw input bytes, so the kernel adds `input_offset × Σfilter`. The per-(output channel, tap) filter sums are computed once per call into a 4,096-entry buffer and added once per in-image tap. If the buffer is too small, the kernel computes the tap sum directly. Integer results are exact, so the output is identical.

Host equivalence check (outside the repository). The patched kernel, compiled in a renamed namespace so the linker cannot fold the two inline definitions, was compared against the upstream TFLM kernel with the software CFU model. It was tested on 2,573 random shapes: batch, padding, stride, dilation, groups, odd depths, misaligned input/filter, no bias, the tap-sum-buffer fallback (520 channels × 3×3), and the model's 13×4×300→300 pointwise shape. Result: 0 mismatches. A deliberately mutated kernel (correction sign flipped) produced 1,553 mismatches, which confirms the check can detect errors.

### Per-operator table after the change (profiling build, FPGA)

UART log `/tmp/nnchip-operator-profile-simd-restructure-run.log`, SHA-256 `fa1600bf…36c8`. Invoke total 5,344,807,655 cycles. Output words identical, and tests a/e/c/b passed in the same session.

| operator | nodes | before | after | change |
|---|---:|---:|---:|---:|
| QUANTIZE | 2 | 8,210,145 | 8,144,537 | noise |
| RESHAPE | 2 | 85,421 | 85,582 | noise |
| DEQUANTIZE | 2 | 6,777,807 | 6,722,432 | noise |
| AudioSpectrogram | 1 | 247,041,247 | 245,738,908 | noise (−0.5%) |
| Mfcc | 1 | 83,286,564 | 83,738,344 | noise (+0.5%) |
| MUL | 1 | 142,866 | 143,111 | noise |
| **CONV_2D** | 6 | **12,391,576,612** | **4,164,060,220** | **−8,227,516,392 (−66.4%)** |
| DEPTHWISE_CONV_2D | 5 | 828,630,518 | 832,339,237 | noise (+0.4%) |
| AVERAGE_POOL_2D | 1 | 407,631 | 417,917 | noise |
| FULLY_CONNECTED | 1 | 61,168 | 60,475 | noise |
| (sum of operators) | 22 | 13,566,219,979 | 5,341,450,763 | −8,224,769,216 |
| (Invoke total) | | 13,569,656,899 | 5,344,807,655 | −60.6% |

CONV_2D per node after the change (before → after):

- node 8 (scalar, 1 channel): 400,954,121 → 144,808,898
- node 10: 5,030,032,243 → 1,685,578,075 (109 cycles per group, close to the 2 × 50 + 8 AXI + SIMD floor)
- node 12: 3,420,759,096 → 1,146,335,032
- node 14: 2,193,849,964 → 734,987,432
- node 16: 965,692,469 → 324,306,594
- node 18: 380,288,719 → 128,044,189

The whole gain comes from the CONV_2D row. The other operators changed by less than ±0.6%, which is run-to-run noise.

**What the remaining time is:**

- CONV_2D is 77.9%. It is now bound by the two 50-cycle single-word NPU AXI reads per 4-channel group.
- DEPTHWISE_CONV_2D is 15.6%, using the upstream reference kernel.
- AudioSpectrogram and Mfcc together are 6.1% (soft-float on rv32im).

No further change was needed to reach the target.

## Final clean build and FPGA run

```sh
cd TinyRISC-V-SoC-Platform
rm -rf /tmp/nnchip-final-clean-build
make -j8 -C Platform/sw BUILD_DIR=/tmp/nnchip-final-clean-build \
  MODEL_FILE=ds_cnn_stream_fe.tflite MODEL_PROFILE=ds_cnn_stream_fe \
  TFLM_SOFTWARE_CONV=0 all
```

- Build log `/tmp/nnchip-final-clean-build.log`, SHA-256 `0bd33470…da71`. It contains `Selecting patched AXI + SIMD ConvPerChannel` and `-DTENSOR_ARENA_SIZE=1048576`. `TFLM_OPERATOR_CYCLE_PROFILE` does not appear, and the ELF contains no profiler strings.
- `main.elf` SHA-256 `82cb98f105f3c45673e9141e72412ebfcf5f872d6d0662f19b6ae331bf392ec4`.
- `main.bin` SHA-256 `7b5ad82a87fbe0f118adce4356c4cc8eac591b52c687e2d3dec68934b683d6fb`.
- The build-copy `conv.h` equals the patched source: SHA-256 `cc837bcdd176968c2822d705676834c2124fc185f6dc7708341869058dc59ac9`.

Board run:

```sh
python3 /tmp/nnchip_board_menu_runner.py /tmp/nnchip-final-clean-build/main.bin \
  /tmp/nnchip-final-clean-board-run.log tlaecb 3000
```

The runner is a helper outside the repository. It does four things:

1. Opens the UART.
2. Programs `Platform/build/out.bit` with `Platform/hw/program.tcl`. This resets the CPU into the bootloader; the program log reports `End of startup status: HIGH`.
3. After the bootloader's `SYNC`, uploads `main.bin` with the repository `Platform/sw/upload.py` functions (`start_vivado_server`, `do_upload`, then `D`).
4. Sends the menu keys, each after the firmware prompt returns: `t`, then `l`, `a`, `e`, `c`, `b`.

UART transcript `/tmp/nnchip-final-clean-board-run.log`, SHA-256 `ba4e9d12c146d8e054d1399707c17858ccec4b4f343b02b57caebcb22a459857`:

```text
Convolution path: accelerated AXI + SIMD
Tensor arena: 1048576 bytes
Profile: ds_cnn_stream_fe
Input profile: label1 board audio input
AllocateTensors: kTfLiteOk
Invoke status: kTfLiteOk
Inference complete.
Cycles: 5335912041
Time (50000000 Hz): 106718 ms
```

### Output words vs. software/reference baseline

| index | baseline (`software_inference_baseline.md`) | final FPGA run | match |
|---:|---|---|---|
| 0 | 0xc1ca25e1 | 0xc1ca25e1 | yes |
| 1 | 0x412dd8e5 | 0x412dd8e5 | yes |
| 2 | 0xc129cde6 | 0xc129cde6 | yes |
| 3 | 0xc0e267dd | 0xc0e267dd | yes |
| 4 | 0xbf015fec | 0xbf015fec | yes |
| 5 | 0xc0f293da | 0xc0f293da | yes |
| 6 | 0x3f420fe2 | 0x3f420fe2 | yes |
| 7 | 0xc0118bea | 0xc0118bea | yes |
| 8 | 0xc0918bea | 0xc0918bea | yes |
| 9 | 0xc0da51de | 0xc0da51de | yes |
| 10 | 0xc0d23be0 | 0xc0d23be0 | yes |
| 11 | 0xc10975eb | 0xc10975eb | yes |

### Lab menu tests (same session, same image)

| menu | test | result |
|---|---|---|
| a | Accelerator AXI Aligned Test | `[AXI] ALL PASS (32 checks).` |
| e | Standalone SIMD INT8 MAC Test | `[SIMD MAC] ALL PASS (8 checks).` |
| c | Basic Convolution Test | Testcase1/2/3 `[PASS]`, total 3,588,299 cycles |
| b | Accelerator AXI Misaligned Test | `[AXI] ALL PASS (6 checks).` |

## Simulation and reference-path checks

```sh
cd TinyRISC-V-SoC-Platform
iverilog -g2012 -Wall -s npu_misaligned_axi_read_tb -o /tmp/npu_misaligned_axi_read_tb.vvp \
  Platform/hw/srcs/NPU.v Platform/hw/sim/npu_misaligned_axi_read_tb.sv \
  && vvp /tmp/npu_misaligned_axi_read_tb.vvp
iverilog -g2012 -Wall -s npu_misaligned_axi_write_tb -o /tmp/npu_misaligned_axi_write_tb.vvp \
  Platform/hw/srcs/NPU.v Platform/hw/sim/npu_misaligned_axi_write_tb.sv \
  && vvp /tmp/npu_misaligned_axi_write_tb.vvp
```

- Read testbench: `[PASS] All aligned/misaligned AXI read reconstruction checks`.
- Write testbench: `[PASS] All aligned/misaligned AXI write byte-placement and handshake checks`.
- iverilog 12; both exit 0 and contain no `FAIL`.
- No RTL changed: `git diff` is empty for `Platform/hw`. The bitstream was not rebuilt, and the existing post-route report still shows WNS 1.135 ns at the 50 MHz clock.
- Reference path: a fresh `TFLM_SOFTWARE_CONV=1` build (`/tmp/nnchip-reference-path-check-build`) printed `Selecting upstream software/reference ConvPerChannel` and linked. Its build-copy `conv.h` SHA-256 is `9ebe12d5acfcebadb7c00cc38eee32f6d74b81ce4e29e664bbf590de0b28dca3`, the upstream hash recorded in the baseline.
