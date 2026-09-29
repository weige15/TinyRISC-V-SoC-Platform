# ds_cnn_stream_fe software inference baseline

This records one full on-board TFLM inference through the upstream software/reference convolution path. The 12 raw words below are the measured software output reference for later comparison; the profile has no golden output, so this is **not** an independently verified correctness result.

## Configuration

- Model: `models/ds_cnn_stream_fe.tflite` (589,000 bytes; SHA-256 `1de6e13f074e4e5c339e56c21650d09921e8886bb6121a7b08ec404ad2577e35`).
- Profile: `models/ds_cnn_stream_fe_profile.cc` (SHA-256 `51766ba60751cbad290e8ec815bd62af864e8eac3c5617d04a43dacfaa9c83d6`).
- Single input sample: profile's `label1_data` from `models/label/label1_board.cc` (SHA-256 `3d495de88928ad2c9883b8d38f2c1d1b3b2f183c81ebb16470ab0fb7d2b8c529`), 16,000 float values; the runtime reports 64,000 input bytes. No other labels were run.
- Tensor arena: 1,048,576 bytes.
- Output: float32 `[1, 12]` (48 bytes).
- Existing project operator registrations were retained; no model-asset or operator-registration changes were made for this baseline.
- The pre-existing, ignored `Platform/sw/project.mk` selected the model/profile, arena, RISC-V toolchain, and board-input sources:

  ```make
  MODEL_DIR := models
  MODEL_FILE := ds_cnn_stream_fe.tflite
  MODEL_PROFILE := ds_cnn_stream_fe
  TENSOR_ARENA_SIZE := 1048576
  TARGET_PREFIX := riscv64-unknown-elf
  USE_SOFTWARE_CFU := 0
  APP_EXTRA_SRCS += $(wildcard models/label/label*_board.cc)
  ```

## Convolution selection and software-only evidence

Build with `TFLM_SOFTWARE_CONV=1`. The Makefile copies the normal TFLM source tree and its existing patches, then restores the original TFLM `reference/integer_ops/conv.h` in the build copy. Thus the baseline uses the upstream `ConvPerChannel`; it does not replace or duplicate the TFLM source tree. The firmware also reports the selected path at runtime.

For the successful software build, the selected build-copy header had the same SHA-256 as the upstream header (`9ebe12d5acfcebadb7c00cc38eee32f6d74b81ce4e29e664bbf590de0b28dca3`) and contained no `cfu_op1`, SIMD MAC, or `cbo_clean` references. The TFLM `conv.cc` dependency file points to that selected build-copy header. The normal patched AXI + SIMD header remains at `Platform/sw/tflm_patches/.../conv.h` (SHA-256 `c1869aa69786514caeb71150459d14311fbb2766d9985b5a9312b9142ded0d92`). Switching the selector in one build directory was also checked in both directions: `0` selected that patched header and `1` restored the upstream header.

`TFLM_SOFTWARE_CONV` defaults to `0`, preserving the normal accelerated path. A separate clean build with `TFLM_SOFTWARE_CONV=0` selected the patched AXI + SIMD header and linked successfully; it was **not run**.

## Environment check and firmware builds

From the `TinyRISC-V-SoC-Platform` repository root, the required environment check passed:

```sh
make -C Platform/sw check-env \
  MODEL_FILE=ds_cnn_stream_fe.tflite \
  MODEL_PROFILE=ds_cnn_stream_fe
```

It reported the model/profile and `arena=1048576 bytes`.

The software firmware was built in a fresh isolated build directory with:

```sh
make -j2 -C Platform/sw \
  BUILD_DIR=/tmp/nnchip-ds-cnn-software-build \
  MODEL_FILE=ds_cnn_stream_fe.tflite \
  MODEL_PROFILE=ds_cnn_stream_fe \
  TFLM_SOFTWARE_CONV=1 all
```

The command exited successfully, linked `main.elf`, and generated `main.bin`. The ELF is RISC-V ELF32 with entry point `0x60000000`. SHA-256: `main.elf` `a7e4a9afc4f82c72fba826b05420ce07ee578c910354e893405a5327f4d365f9`; `main.bin` `616eb0dbd14558479d87285827aa20cf399321a6c6563b827cf6865f8712abb4`. The full build log was `/tmp/nnchip-ds-cnn-software-build.log`.

For the compile-only accelerated-path preservation check, a separate fresh build used the same command with `BUILD_DIR=/tmp/nnchip-ds-cnn-accelerated-build` and `TFLM_SOFTWARE_CONV=0`; it selected the patched AXI + SIMD header and linked. No accelerated inference or benchmark was performed.

## On-board run

The FPGA was programmed using the existing bitstream and repository hardware flow. From `TinyRISC-V-SoC-Platform`:

```sh
cd Platform && ./hw/run_hw.sh
```

The command exited successfully, reported RTL/bootloader/config up to date, skipped synthesis, and programmed `Platform/build/out.bit` (SHA-256 `8871f97eb3cccb3bc171f0d3c9384224497fc48c677677a760fcee1e313e2b84`) through the connected Digilent device.

The repository uploader was then run against the software-only binary:

```sh
python3 Platform/sw/upload.py /tmp/nnchip-ds-cnn-software-build/main.bin
```

It listened on `/dev/ttyUSB1`, completed the upload, and jumped to `0x60000000`. At the firmware's `main>` menu, the TFLM inference command was invoked with `t`; the terminal was stopped after inference returned to the menu. The uploader was launched in a pseudo-terminal to provide these menu keystrokes. The `make run` wrapper's `sudo` step required a password unavailable to this session, so the same repository `upload.py` flow was invoked directly; the serial device was accessible. Runtime transcript: `/tmp/nnchip-ds-cnn-software-run.log`.

Runtime evidence from that run:

```text
Model: ds_cnn_stream_fe.tflite (589000 bytes)
Convolution path: software/reference (upstream TFLM ConvPerChannel)
Tensor arena: 1048576 bytes
Profile: ds_cnn_stream_fe
Input profile: label1 board audio input
Samples: 1
AllocateTensors: kTfLiteOk
Invoke status: kTfLiteOk
Inference complete.
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
Cycles: 15585938193
Time (50000000 Hz): 311718 ms
```

The cycle counter reads immediately before and after `interpreter.Invoke()`. This is the single observed inference measurement and the baseline value; it has not been averaged or normalized. Output verification was skipped by the existing model profile, so no independent golden-output verification is claimed.

## Files changed

- `Platform/sw/Makefile` — add the `TFLM_SOFTWARE_CONV` source-selection option and report it in build configuration/help.
- `Platform/sw/app/tflm_runner.cc` — report allocation/invoke status and selected convolution path; print all 12 float output bit patterns after successful inference.
- `Platform/sw/software_inference_baseline.md` — record configuration, build/run commands, output, cycle count, and evidence.

The accelerated ConvPerChannel patch and hardware/AXI/SIMD implementation were preserved; only the software/reference inference was run.