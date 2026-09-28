# Lab 1 development baseline

Verified 2026-09-28 against repository revision `6bce5dcca3b14df3f9bbbabfb5fe3b5464e9abe8`, using `assignments/lab1/Lab_1_Aligned_AXI_Data_on_SIMD.pdf` (model setup and preflight on p. 4) and `assignments/lab1/lab1_objectives.md` (baseline checklist) as the task sources. This records the software/model preflight needed before implementing Lab 1 AXI behavior; it does **not** claim the AXI tests or FPGA inference have passed. Course assets came from `nycu-caslab/AAML-Labs-2026` main at `cce2dc748caba09bc2694d0cf532c1b5528925b4`; the profile hash also matches the Lab 1 course-site file. The five input `.cc` arrays match the PDF-linked Drive archive.

## Initial findings and changes

Already working: tool executables/dependencies, the repository `validate` target, the existing TFLM source tree, and the existing `ad01` model/profile. From the platform repository root, `make -C Platform/sw check-env MODEL_FILE=ds_cnn_stream_fe.tflite MODEL_PROFILE=ds_cnn_stream_fe` initially failed only because `models/ds_cnn_stream_fe.tflite` was absent. The Lab 1 model, profile, input data, and local `project.mk` were not present locally.

Changed to establish this baseline: added the official model/profile/input and Lab 1 test sources; registered the five additional model operators while retaining existing operators; raised resolver capacity from 9 to 14; merged Lab 1 menu entries while keeping the prior platform test; and created the ignored local `project.mk` for model, arena, and input-source selection. The initial missing-model failure was resolved and the same check then passed. No environment component was reinstalled or upgraded.

## Completion audit

| Objective deliverable | Evidence | Result |
|---|---|---|
| Establish repository state and preserve existing work | At start, `git status --short` showed 19 pre-existing changes under `Platform/hw` (including `run_hw.sh`, `MMIO.bd`, and generated `.xci` files). Those same paths remain modified; this work did not edit `Platform/hw`, `NPU.v`, `conv.h`, cache code, or `Platform/build`. Existing `Platform/build/sw` artifacts were preserved by building into `/tmp/nnchip-lab1-build`. | Pass |
| Verify Vivado, Verilator, host C++, RISC-V C++, Python 3, and pyserial are available and usable | Exact version commands below; host and RISC-V compiler smoke builds, Verilator lint, Python serial import, and Vivado batch Tcl smoke all exited 0. Existing Vivado project artifacts also identify Vivado 2023.2. | Pass |
| Run repository software validation | `make -C Platform/sw validate` lists the `ds_cnn_stream_fe` model/profile and exits 0. | Pass |
| Install model, profile, and input data | `models/ds_cnn_stream_fe.tflite` (589,000 bytes; SHA-256 `1de6e13f074e4e5c339e56c21650d09921e8886bb6121a7b08ec404ad2577e35`), `models/ds_cnn_stream_fe_profile.cc` (1,466 bytes; SHA-256 `51766ba60751cbad290e8ec815bd62af864e8eac3c5617d04a43dacfaa9c83d6`), and five `models/label/label*_board.{cc,h}` input pairs are present. The TFLite schema reports input `FLOAT32[1,16000]`; the profile uses `label1_data`, declared as 16,000 floats. The five `.cc` input arrays match those in the PDF-linked `label.zip`; course-repository headers declare the fixed 16,000-element size. | Pass |
| Register the model's TFLM operators with correct resolver capacity | Parsing the model FlatBuffer with the repository's generated TFLite schema found 10 distinct opcodes: `QUANTIZE`, `RESHAPE`, `DEQUANTIZE`, custom `AudioSpectrogram`, custom `Mfcc`, `MUL`, `CONV_2D`, `DEPTHWISE_CONV_2D`, `AVERAGE_POOL_2D`, and `FULLY_CONNECTED`. `project/tflm_ops.cc` registers each required operator once. It retains the four existing registrations (`MaxPool2D`, `Relu`, `Relu6`, `Softmax`) for the existing `ad01` model; `kTflmResolverOpCount` is 14, matching all registrations. | Pass |
| Configure model, profile, arena, and input source registration | Local ignored `Platform/sw/project.mk` selects `ds_cnn_stream_fe`, sets `TENSOR_ARENA_SIZE := 1048576`, and adds `APP_EXTRA_SRCS += $(wildcard models/label/label*_board.cc)`. `make -pn` resolves the profile, all five label sources, and all project sources into `APP_CC_SRCS`. | Pass |
| Integrate the Lab 1 software test sources/menu without losing existing tests | Added the course `accelerator_test.*`, `conv_test.*`, and `conv_test_data.h` sources. Merged the Lab 1 AXI/convolution menu entries into `proj_menu.cc` and retained the existing platform test as an additional item. All are compiled by the software build. | Pass |
| Run Lab 1 environment check for `ds_cnn_stream_fe` | Exact command below exits 0 and reports model, profile, RISC-V toolchain, and 1,048,576-byte arena. | Pass |
| Keep out-of-scope accelerator work untouched | No AXI read/write, SIMD MAC, cache-coherence, convolution acceleration, misaligned-access, or full-model optimization was implemented. No NPU hardware logic was modified. | Pass |

## Local build configuration

`Platform/sw/project.mk` is intentionally ignored by `.gitignore`; recreate it locally with:

```make
MODEL_DIR := models
MODEL_FILE := ds_cnn_stream_fe.tflite
MODEL_PROFILE := ds_cnn_stream_fe
TENSOR_ARENA_SIZE := 1048576
TARGET_PREFIX := riscv64-unknown-elf
USE_SOFTWARE_CFU := 0
APP_EXTRA_SRCS += $(wildcard models/label/label*_board.cc)
```

The test sources under `Platform/sw/project/` are picked up by the Makefile's project-source scan. The model profile is selected as `models/ds_cnn_stream_fe_profile.cc`.

## Tool versions and verification

Run from the `TinyRISC-V-SoC-Platform` repository root. All commands below exited 0.

```sh
vivado -version
# v2023.2 (64-bit), SW Build 4029153, IP Build 4028589
verilator --version
# Verilator 5.020 2024-01-01 rev (Debian 5.020-1)
c++ --version
# c++ (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0
riscv64-unknown-elf-g++ --version
# SiFive GCC 10.1.0-2020.08.2, version 10.1.0
python3 --version
# Python 3.12.3
python3 -c "import serial"
# exit 0; pyserial 3.5

make -C Platform/sw validate
# exit 0; reports project.mk, ds_cnn_stream_fe model/profile, and ad01 assets
make -C Platform/sw check-env \
  MODEL_FILE=ds_cnn_stream_fe.tflite MODEL_PROFILE=ds_cnn_stream_fe
# OK: toolchain=riscv64-unknown-elf, model=models/ds_cnn_stream_fe.tflite,
# profile=ds_cnn_stream_fe, arena=1048576 bytes

make -j2 -C Platform/sw BUILD_DIR=/tmp/nnchip-lab1-build all
# exit 0; linked RISC-V main.elf and generated main.bin
```

Additional usability checks, also successful:

```sh
c++ -std=c++17 -Wall -Wextra -Werror /tmp/lab1_host_smoke.cc \
  -o /tmp/lab1_host_smoke && /tmp/lab1_host_smoke
riscv64-unknown-elf-g++ -std=c++11 -Wall -Wextra -Werror \
  -march=rv32im -mabi=ilp32 -c /tmp/lab1_riscv_smoke.cc \
  -o /tmp/lab1_riscv_smoke.o
verilator --lint-only --Wall /tmp/lab1_verilator_smoke.sv
vivado -mode batch -source /tmp/lab1_vivado_smoke.tcl \
  -notrace -nolog -nojournal
# Vivado Tcl smoke printed: Vivado Tcl smoke: 2023.2
```

The exact temporary smoke sources were:

```cpp
// /tmp/lab1_host_smoke.cc
#include <cstdint>
int main() { const std::uint32_t n = 4; return n == 4 ? 0 : 1; }

// /tmp/lab1_riscv_smoke.cc
#include <stdint.h>
int main(void) { volatile uint32_t value = 3; return (int)(value - 3); }
```

```systemverilog
// /tmp/lab1_verilator_smoke.sv
module lab1_verilator_smoke(input logic a, input logic b, output logic y);
  assign y = a & b;
endmodule
```

```tcl
# /tmp/lab1_vivado_smoke.tcl
puts "Vivado Tcl smoke: [version -short]"
exit
```

The RISC-V object was identified as ELF32 RISC-V (`file` and `readelf -h`). The full firmware build produced a 7,987,516-byte RISC-V ELF and a 965,692-byte binary, with no compiler warnings/errors in its log.

## Version note and scope boundary

The Lab 1 PDF lists Vivado 2024.1. This machine has Vivado 2023.2, which matches the Lab 0 environment guidance. The existing `Platform/build/hw/SoC/SoC.xpr` identifies Product Version 2023.2, and the existing `Platform/build/out.bit` and post-route timing report are from that release; the timing report header says `Vivado v.2023.2`. Vivado 2023.2 also passed the batch Tcl smoke. No upgrade was performed. If a later Lab 1 RTL/project-specific failure proves that 2023.2 is incompatible, the next action would be to obtain/use Vivado 2024.1 with approval—not to replace the working installation preemptively.

The Lab 1 AXI aligned/misaligned tests, FPGA programming, on-board inference, output comparison, and cycle comparison were not run: they are beyond this pre-implementation baseline and depend on the later accelerator work/hardware run. The successful software build is a compile/link check, not evidence that those hardware behaviors work.
