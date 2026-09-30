# Lab 1 AXI + SIMD + accelerated TFLM regression

## Result

**PASS** on TinyRISC-V-SoC-Platform commit `d589269`. The existing implementation passed the complete software/build, RTL, FPGA menu, and full-model checks. No implementation, RTL, test, golden, model, or reference changes were needed. This file records only the regression evidence.

## Fixed configuration and references

The run used the existing `Platform/sw/project.mk` configuration:

- Model: `models/ds_cnn_stream_fe.tflite`, SHA-256 `1de6e13f074e4e5c339e56c21650d09921e8886bb6121a7b08ec404ad2577e35`.
- Profile: `ds_cnn_stream_fe`, SHA-256 `51766ba60751cbad290e8ec815bd62af864e8eac3c5617d04a43dacfaa9c83d6`.
- Board input: `label1_data` in `models/label/label1_board.cc`, SHA-256 `3d495de88928ad2c9883b8d38f2c1d1b3b2f183c81ebb16470ab0fb7d2b8c529`.
- Tensor arena: 1,048,576 bytes; platform clock: 50,000,000 Hz.
- Accelerated convolution: `TFLM_SOFTWARE_CONV=0`; firmware reported `accelerated AXI + SIMD`.
- `Platform/sw/app/tflm_runner.cc` still measures only immediately around `interpreter.Invoke()` (lines 98–100).
- Fixed references were not changed: `software_inference_baseline.md` reports 15,585,938,193 cycles and `accelerated_inference_comparison.md` reports 13,469,246,096 cycles.

## Commands and results

Run from the `TinyRISC-V-SoC-Platform` repository root.

```sh
make -C Platform/sw validate
```

**PASS.** Resolved configuration showed the requested model/profile, `TENSOR_ARENA_SIZE=1048576`, and `TFLM_SOFTWARE_CONV=0`; the model and profile were listed.

```sh
make -C Platform/sw check-env \
  MODEL_FILE=ds_cnn_stream_fe.tflite \
  MODEL_PROFILE=ds_cnn_stream_fe
```

**PASS.** Reported `OK: toolchain=riscv64-unknown-elf, model=models/ds_cnn_stream_fe.tflite, profile=ds_cnn_stream_fe, arena=1048576 bytes`.

```sh
iverilog -g2012 -Wall \
  -s npu_misaligned_axi_read_tb \
  -o /tmp/npu_misaligned_axi_read_tb.vvp \
  Platform/hw/srcs/NPU.v \
  Platform/hw/sim/npu_misaligned_axi_read_tb.sv \
  && vvp /tmp/npu_misaligned_axi_read_tb.vvp
```

**PASS.** Read reconstruction passed offsets 0, 1, 2, and 3; final output: `[PASS] All aligned/misaligned AXI read reconstruction checks`.

```sh
iverilog -g2012 -Wall \
  -s npu_misaligned_axi_write_tb \
  -o /tmp/npu_misaligned_axi_write_tb.vvp \
  Platform/hw/srcs/NPU.v \
  Platform/hw/sim/npu_misaligned_axi_write_tb.sv \
  && vvp /tmp/npu_misaligned_axi_write_tb.vvp
```

**PASS.** Byte placement, addresses, strobes, channel stalls/handshakes, responses, and completion passed offsets 0–3 for both write patterns; final output: `[PASS] All aligned/misaligned AXI write byte-placement and handshake checks`.

```sh
make -j2 -C Platform/sw \
  BUILD_DIR=/tmp/nnchip-lab1-regression-build \
  MODEL_FILE=ds_cnn_stream_fe.tflite \
  MODEL_PROFILE=ds_cnn_stream_fe \
  TFLM_SOFTWARE_CONV=0 \
  all
```

**PASS.** Linked `main.elf` and generated `main.bin` in the isolated build directory. The build log says `Selecting patched AXI + SIMD ConvPerChannel`; the build-copy `conv.h` matches the patched source SHA-256 (`f6634ddfbfd37b4bd46f087d8a885e947d5815ced7710621bacd487fd34a976d`), the `conv.d` dependency points to that selected header, and `conv.o` is included in the final link. Build log: `/tmp/nnchip-lab1-regression-build.log`.

```sh
make -C Platform prog
```

**PASS.** Existing hardware flow programmed the connected Digilent target using `Platform/build/out.bit` (SHA-256 `8871f97eb3cccb3bc171f0d3c9384224497fc48c677677a760fcee1e313e2b84`). The flow reported RTL, bootloader, and config up to date and successfully ran Vivado programming.

The existing repository uploader was run through a PTY so the firmware menus could be exercised and captured:

```sh
python3 /tmp/lab1_regression_board_run.py
# The runner invokes: python3 Platform/sw/upload.py \
#   /tmp/nnchip-lab1-regression-build/main.bin
```

It uploaded and jumped to `0x60000000`, then selected `l`, `a`, `e`, `c`, `b`, `x`, and `t` through the normal firmware menus. The runner failed if required menu output, any raw output word, or the cycle gate was missing. Complete UART transcript: `/tmp/nnchip-lab1-regression-board-run.log`.

### FPGA test outcomes

| Menu test | Backend and required results | Result |
|---|---|---|
| `a` — Accelerator AXI Aligned Test | Hardware CUSTOM-0; all 16 aligned reads and 16 aligned writes matched existing golden words; `[AXI] ALL PASS (32 checks).` | **PASS** |
| `e` — Standalone SIMD INT8 MAC Test | Hardware CUSTOM-0; positive, signed, accumulation, reset, zero, and extreme-value cases; `[SIMD MAC] ALL PASS (8 checks).` | **PASS** |
| `c` — Basic Convolution Test | Existing Testcase1, Testcase2, and Testcase3 each printed `[PASS] ... Output Correct`; total reported 7,938,575 cycles. | **PASS** |
| `b` — Accelerator AXI Misaligned Test | Reads and writes at offsets 1, 2, and 3 each printed `[PASS]`; `[AXI] ALL PASS (6 checks).` | **PASS** |

### Full accelerated TFLM inference

The run reported `Convolution path: accelerated AXI + SIMD`, the 1,048,576-byte arena, the `ds_cnn_stream_fe` profile, and the label1 board input. It reported `AllocateTensors: kTfLiteOk`, `Invoke status: kTfLiteOk`, and `Inference complete.`

Raw output comparison against all 12 words in `software_inference_baseline.md`:

| Index | Software baseline | Final FPGA run | Match |
|---:|---:|---:|:---:|
| 0 | `0xc1ca25e1` | `0xc1ca25e1` | yes |
| 1 | `0x412dd8e5` | `0x412dd8e5` | yes |
| 2 | `0xc129cde6` | `0xc129cde6` | yes |
| 3 | `0xc0e267dd` | `0xc0e267dd` | yes |
| 4 | `0xbf015fec` | `0xbf015fec` | yes |
| 5 | `0xc0f293da` | `0xc0f293da` | yes |
| 6 | `0x3f420fe2` | `0x3f420fe2` | yes |
| 7 | `0xc0118bea` | `0xc0118bea` | yes |
| 8 | `0xc0918bea` | `0xc0918bea` | yes |
| 9 | `0xc0da51de` | `0xc0da51de` | yes |
| 10 | `0xc0d23be0` | `0xc0d23be0` | yes |
| 11 | `0xc10975eb` | `0xc10975eb` | yes |

All 12 words match exactly.

| Measurement | Cycles |
|---|---:|
| Fixed software/reference baseline | 15,585,938,193 |
| Previous accelerated reference | 13,469,246,096 |
| Final accelerated FPGA run | 13,470,086,324 |
| Final run below baseline | 2,115,851,869 |

The final accelerated cycle count is strictly below the fixed baseline. It is 840,228 cycles (0.006238%) above the previous accelerated result, a negligible run-to-run difference; no substantial unexplained increase or correctness issue was observed.

## Completion audit

| Explicit requirement | Evidence | Result |
|---|---|---|
| Inspect `NPU.v`, both misaligned RTL testbenches, `accelerator_test.cc`, `simd_mac_test.cc`, `conv_test.cc`, accelerated `ConvPerChannel`, and both fixed inference references before editing | Inspected current files and recent changes; repository was clean. | **PASS** |
| Validation and environment checks | Successful commands and configuration output above. | **PASS** |
| Misaligned AXI read and write RTL simulations | Both required Icarus commands passed with zero failures and the expected final messages. | **PASS** |
| Build and select/link accelerated ConvPerChannel | Successful isolated build, selector log, selected-header hash/dependency, and final link evidence above. | **PASS** |
| FPGA aligned AXI, SIMD MAC, Basic Convolution, and misaligned AXI tests | Existing menu tests ran on FPGA using the hardware CUSTOM-0 path where applicable; all 32, 8, 3, and 6 required checks passed. | **PASS** |
| Full accelerated TFLM inference, raw outputs, and cycle gate | FPGA transcript reports successful allocation/invoke/completion; all 12 words match; 13,470,086,324 < 15,585,938,193. | **PASS** |
| Preserve references, input/configuration, expected values, tests, and cycle-measurement boundaries | Fixed documents, assets, golden tests, and the `interpreter.Invoke()` measurement were unchanged; no test was weakened. | **PASS** |
| Regression fix and complete rerun | No regression was found; no implementation fix or implementation rerun was needed. | **N/A** |
| Avoid report/submission work, unrelated changes, and development-stage names | Only this functional regression-evidence document was added; no implementation or unrelated files were changed. | **PASS** |

**Files changed:** `Platform/sw/lab1_regression_results.md` only. No FPGA RTL, firmware implementation, test, golden data, baseline, or accelerated reference file was changed.
