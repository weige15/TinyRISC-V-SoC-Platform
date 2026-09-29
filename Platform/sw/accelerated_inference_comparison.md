# ds_cnn_stream_fe accelerated full-model inference

## Configuration and reference

This records a full FPGA run of `ds_cnn_stream_fe.tflite` through the existing AXI + SIMD `ConvPerChannel` path, compared with the fixed software/reference run in [`software_inference_baseline.md`](software_inference_baseline.md).

- Model: `models/ds_cnn_stream_fe.tflite`; SHA-256 `1de6e13f074e4e5c339e56c21650d09921e8886bb6121a7b08ec404ad2577e35`.
- Profile: `ds_cnn_stream_fe`; SHA-256 `51766ba60751cbad290e8ec815bd62af864e8eac3c5617d04a43dacfaa9c83d6`.
- Input: profile's `label1_data` board input from `models/label/label1_board.cc`; SHA-256 `3d495de88928ad2c9883b8d38f2c1d1b3b2f183c81ebb16470ab0fb7d2b8c529`.
- Tensor arena: 1,048,576 bytes.
- Convolution selection: `TFLM_SOFTWARE_CONV=0` (runtime reported `accelerated AXI + SIMD`). The existing `TFLM_SOFTWARE_CONV=1` reference selection is unchanged.
- Clock: 50,000,000 Hz, as reported by the firmware.
- One sample. The existing cycle counter measurement immediately before and after `interpreter.Invoke()` was not changed.

The local, ignored `Platform/sw/project.mk` selects the model, profile, 1,048,576-byte arena, and board input sources, as recorded in the baseline document. The build log also shows `-DTENSOR_ARENA_SIZE=1048576`.

## Accelerated-path change

The first complete accelerated run was correct but took 49,157,070,680 cycles. Inspection showed the accelerated int8 convolution was issuing two `cbo_clean` instructions for every four-channel MAC group. The patched `ConvPerChannel` now cleans the input and filter ranges once per 32-byte data-cache line before the NPU reads them, with fences around the clean. The AXI reads, SIMD MAC operations, scalar fallback, convolution math, and output conversion remain in the accelerated path. No model, input, arena, clock setting, cycle measurement, or output representation was changed.

## Build and FPGA run

From `/home/kuotzuwei15/NNchip`:

```sh
cd TinyRISC-V-SoC-Platform
make -j2 -C Platform/sw \
  BUILD_DIR=/tmp/nnchip-ds-cnn-accelerated-cacheline-clean-build \
  MODEL_FILE=ds_cnn_stream_fe.tflite \
  MODEL_PROFILE=ds_cnn_stream_fe \
  TFLM_SOFTWARE_CONV=0 all
```

The build selected the patched AXI + SIMD header, linked `main.elf`, and generated `main.bin`. The final artifact SHA-256 values are:

- `main.elf`: `d78cadb0796be81d173cf36c54165a4b113c3b9cc80fd321ec417b120e65b4f6`
- `main.bin`: `b14e40caf80478cb29c0eac597750dba1b7939a48e25c8c4949f90ddea175123`

The board was programmed with the repository flow:

```sh
cd TinyRISC-V-SoC-Platform
make -C Platform prog
```

The flow successfully programmed `Platform/build/out.bit` (SHA-256 `8871f97eb3cccb3bc171f0d3c9384224497fc48c677677a760fcee1e313e2b84`). Vivado identified target `Digilent/210319BE7776A`, device `xc7a100t_0`, and `hw_axi_1`.

The repository uploader command was:

```sh
cd TinyRISC-V-SoC-Platform
python3 Platform/sw/upload.py \
  /tmp/nnchip-ds-cnn-accelerated-cacheline-clean-build/main.bin
```

It received bootloader `SYNC`, uploaded the binary through JTAG AXI, and jumped to `0x60000000`. A PTY runner (`/tmp/nnchip-ds-cnn-accelerated-cacheline-clean-board-run.py`) sent `t` at the firmware `main>` menu and stopped the UART session after inference returned to the menu. The captured UART transcript is `/tmp/nnchip-ds-cnn-accelerated-cacheline-clean-board-run.log` (SHA-256 `b4bdcd859fe5c5a59a6d4989c4a768e7a58304996a5ddf6133de8f92352d0732`). It reports `AllocateTensors: kTfLiteOk`, `Invoke status: kTfLiteOk`, and `Inference complete.`

## On-board result

```text
Output Data:
0        : 0xc1ca25e1
1        : 0x412dd8e5
2        : 0xc129cde6
3        : 0xc0e267dd
4        : 0xbf015fec
5        : 0xc0f293da
6        : 0x3f420fe2
7        : 0xc0118bea
8        : 0xc0918bea
9        : 0xc0da51de
10       : 0xc0d23be0
11       : 0xc10975eb

Cycles: 13469246096
Time (50000000 Hz): 269384 ms
```

All 12 output words exactly match the recorded software/reference output. The profile's independent output verification remains skipped; this comparison is against the fixed raw-word baseline.

| Measurement | Cycles |
|---|---:|
| Software/reference baseline | 15,585,938,193 |
| Accelerated AXI + SIMD | 13,469,246,096 |
| Reduction | 2,116,692,097 (13.5808%) |

The accelerated run is **1.15715× faster** than the baseline (42.3338 seconds saved at 50 MHz) and is strictly below the baseline cycle count.

## Completion audit

| Requirement | Concrete evidence | Result |
|---|---|---|
| Hold the recorded software/reference run fixed | `software_inference_baseline.md` records the exact 12-word output and 15,585,938,193 cycles; model, profile, and label1 input hashes above match it. | Pass |
| Use the requested model, profile, label1 input, 1,048,576-byte arena, 50 MHz clock, and existing Invoke cycle region | UART transcript reports the model, profile, label1 board input, arena, and clock; build log contains `-DTENSOR_ARENA_SIZE=1048576`; `app/tflm_runner.cc` measurement region is unchanged. | Pass |
| Build/link with `TFLM_SOFTWARE_CONV=0` through AXI + SIMD `ConvPerChannel` | Build command and log show selector `0`, patched-header selection, and final link; build-copy header contains AXI and SIMD calls; runtime identifies `accelerated AXI + SIMD`. | Pass |
| Program and run on the FPGA using repository flows | `make -C Platform prog` and the `upload.py` command are recorded above; programming/JTAG logs show the connected Arty device and JTAG AXI core; UART transcript shows SYNC, 100% upload, and jump to `0x60000000`. | Pass |
| Execute full inference from the firmware menu without failure | UART transcript shows menu selection `t`, `AllocateTensors: kTfLiteOk`, `Invoke status: kTfLiteOk`, `Inference complete.`, and return to `main>`. | Pass |
| Match all reference output words and beat the baseline cycle gate | All 12 words in the UART transcript match the baseline; 13,469,246,096 cycles is 2,116,692,097 cycles below the fixed baseline. | Pass |
| Preserve the baseline selector and avoid prohibited changes | The iteration's only implementation change is the accelerated ConvPerChannel patch; `Makefile`, runner/measurement, model, profile, label1 input, and arena configuration are unchanged. | Pass |
| Profile a slow correct run and rerun full inference after the optimization | Initial accelerated run: exact output, 49,157,070,680 cycles. After batching cache cleans per 32-byte line, the full FPGA/menu inference was rerun and produced the successful result above. | Pass |
| Record reproduction commands and results | This document records build, programming, and upload/menu commands, configuration, hashes, raw outputs, baseline/accelerated cycles, reduction, and speedup. | Pass |

## Evidence files

- Build log: `/tmp/nnchip-ds-cnn-accelerated-cacheline-clean-build.log` (SHA-256 `3b1e0dfa5514bf30d84bec30f28ae60c15d75888dfa067a1a1257aa4166c8ce3`).
- FPGA programming log: `/tmp/nnchip-ds-cnn-accelerated-cacheline-clean-fpga-reset.log` (SHA-256 `22a9adcb5738d453816674a26ad7c61e4aa128b1d13112911743b1c09c2734a4`).
- JTAG target check: `/tmp/nnchip-ds-cnn-accelerated-cacheline-clean-jtag-target.log`.
- UART transcript: `/tmp/nnchip-ds-cnn-accelerated-cacheline-clean-board-run.log`.
- Earlier, correct-but-slower accelerated run: `/tmp/nnchip-ds-cnn-accelerated-full-inference-board-run.log`.
