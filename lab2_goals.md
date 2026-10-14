# Lab 2 goals for `/goal`

Ten goals that take Lab 2 (AXI4 burst reads for a SIMD dot product) from setup to submission. Run them in order with `/goal <condition>` in Claude Code, one at a time; each starts only after the previous one reports **Met**.

## How these are written

They follow the conventions on the [`/goal` docs page](https://code.claude.com/docs/en/goal):

- **The evaluator only reads the transcript.** It does not run commands or open files. So every condition says which command Claude must run and what its output must show, and Claude has to print that output in the conversation.
- **One measurable end state per goal.** That means a test summary, an exit code, a report value, or a `unzip -l` listing.
- **Constraints are written into the condition**, for example "the NPU port list is unchanged" or "no CPU dot-product loop".
- **Every goal has a turn bound** (`or stop after N turns`) so a stuck goal comes back to you.
- **Each condition fits the 4,000-character limit.** Paste the text inside the code block after `/goal `.
- **Run them in auto mode** so that goal turns don't stop at every tool prompt.

## Where each goal can run

| Tag | Meaning |
| --- | --- |
| **[anywhere]** | Needs only a shell with Verilator/iverilog, a host C++ compiler and the RISC-V toolchain. This works in a cloud session or WSL without the board. |
| **[Vivado]** | Needs Vivado 2024.1 (your WSL install). The board doesn't have to be attached. |
| **[board]** | Needs the Arty A7 attached through `usbipd`, `/dev/ttyUSB*` visible, and **you pressing CPU RESET** after `Listening on /dev/ttyUSB…`. Run these from Claude Code in your WSL checkout. As `AGENTS.md` says, simulation never substitutes for these results. |

All paths are relative to the platform repository root (`TinyRISC-V-SoC-Platform/`, which is the submodule inside `NNChip`).

## Things in the repo that affect Lab 2

- **The submodule still holds the Lab 1 state.** That means `hw/srcs/npu_burst_dot_product.v`, the iverilog testbenches in `Platform/hw/sim/`, and a `conv.h` that calls `NPU_FUNCT3_BURST_DOT_PRODUCT` directly. The Lab 1 burst engine is a useful starting point, but it falls short of Lab 2 in four ways:
  - It has no `input_offset`.
  - It has no `RLAST`/`RRESP` error handling (there is no `RLAST`/`RRESP` logic in the file).
  - It has no legal-range check.
  - It has no `hw_simd_mac` API.
- **Lab 2 setup step 2 replaces `Platform/sw/project`.** That deletes the Lab 1 channel-blocked depthwise kernel and its `tflm_ops.cc` registration. The submission zip ships only `conv.h` and `lab2_api.cc` on the software side anyway, so latency work has to come from `CONV_2D` through `hw_simd_mac` and from the RTL, not from extra kernels.
- **`hw_simd_mac` testcases have N ≤ 256, but convolution calls can be longer.** A tap of `filter_input_depth` channels, or a whole `filter_width × depth` row, can exceed 256. Either `hw_simd_mac` handles any N, or `conv.h` splits calls into chunks of ≤ 256. Goal 2 picks "handle any N" as the default.
- **The handout's demo section mentions "aligned staging".** Read that as staging inside the hardware (realigning the byte stream). The submission rules give zero for Parts 1 and 2 if *software* stages unaligned pointers.
- **Post-route reports go to `Platform/build/reports/`.** The files are `post_route_utilization_npu.rpt` and `post_route_timing_summary.rpt`, written by `hw/build_SoC.tcl`.

---

## Goal 0: Lab 2 tree in place and preflight green [Vivado]

```text
The Lab 2 files from nycu-caslab/AAML-Labs-2026 lab2/ are installed: Platform/sw/project is replaced by the Lab 2 version (Platform/sw/project/lab2_api.h and lab2_api.cc exist), everything from lab2 model/ is in Platform/sw/models, and project.mk (or the make command) adds APP_EXTRA_SRCS += $(wildcard models/label/label*_board.cc). Prove it by printing `ls Platform/sw/project Platform/sw/models Platform/sw/models/label` and `grep -n hw_simd_mac Platform/sw/project/lab2_api.h`. Then, from the repository root, run and show the output of: vivado -version; verilator --version; c++ --version; riscv64-unknown-elf-g++ --version; python3 -c "import serial"; make -C Platform/sw validate; make -C Platform/sw check-env MODEL_FILE=ds_cnn_stream_fe.tflite MODEL_PROFILE=ds_cnn_stream_fe. Every command must exit 0. Do not edit NPU.v, conv.h or lab2_api.cc in this goal. Commit the setup on a lab2 branch. Or stop after 10 turns and list which check failed.
```

## Goal 1: AXI4 burst engine and SIMD MAC pass a self-checking simulation [anywhere]

```text
Platform/hw/srcs/NPU.v (plus any helper modules under Platform/hw/srcs/) implements a CUSTOM-0 command set that computes sum((int8(a[i]) + input_offset) * int8(b[i])) for i < N over two byte vectors fetched only through AXI4 INCR read bursts, and a new self-checking testbench Platform/hw/sim/npu_lab2_tb.sv proves it. The testbench has an AXI slave memory model with randomly stalled ARREADY and RVALID and checks every AR handshake: ARADDR[1:0]==0, 0x60000000 <= ARADDR and ARADDR+4*B <= 0x68000000, ARADDR[11:0]+4*B <= 4096, ARLEN==B-1, ARSIZE==3'b010, ARBURST==2'b01, and ARVALID/ARADDR/ARLEN stable until ARREADY. It also checks that beats are only taken on RVALID&&RREADY, in address order, little-endian. Tests: N = 1..256 for every combination of ptr1[1:0] and ptr2[1:0] in 0..3, input_offset in {-128,-1,0,1,127} plus random values, random int8 data, vectors placed so a burst would cross a 4 KiB boundary and must be split, and at least one call where the covering span is more than one word and is fetched with ARLEN>0 (no single-beat substitution). Back-to-back commands are issued with no idle gap. NPU_done pulses exactly once per command and is low while idle. Error injection: early RLAST ends the command with NPU_done; beat B without RLAST stops writing local storage, drains beats until RLAST, then raises NPU_done; a non-OKAY RRESP is flagged as an error; each case is followed by a normal command that still returns the right result. Done when both of these are shown with their output: `verilator --lint-only -Wall` on NPU.v and helpers reports no errors, and the testbench (iverilog -g2012 or verilator --binary --timing) prints a final line with the pass count and 0 failures. The NPU module name, full port list, port directions and active-low rst_n are unchanged: show `git diff` of the module header is empty. Or stop after 40 turns and report the failing cases.
```

## Goal 2: `hw_simd_mac` service in `lab2_api.cc` [anywhere]

```text
Platform/sw/project/lab2_api.cc implements int32_t hw_simd_mac(int8_t* ptr1, int8_t* ptr2, int8_t input_offset, uint32_t N) with the exact signature and C linkage of lab2_api.h, using the cfu.h helpers to issue the Goal 1 CUSTOM-0 commands. Before starting the NPU it cleans every data-cache line that overlaps [ptr1, ptr1+N) and [ptr2, ptr2+N) with cbo_clean from cbo.h. It passes ptr1 and ptr2 to hardware unchanged, even when unaligned: no memcpy, no staging buffer, no byte shuffling in software. It contains no CPU loop that multiplies or accumulates elements; the result comes from NPU_out. It handles any N >= 1 (calls longer than the hardware limit are split, and partial sums are only added on the CPU if each part was computed by the NPU). Show the full file, a grep proving no '*' multiply of ptr1/ptr2 elements and no memcpy, and a clean build: `make -C Platform/sw` exits 0 with the RISC-V toolchain. Or stop after 15 turns.
```

## Goal 3: Lab 2 set and random tests pass on the board [board]

```text
On the Arty A7, the Lab 2 set tests and random tests both pass with the current NPU.v and lab2_api.cc. Check first that lsusb shows the FTDI 0403:6010 device, /dev/ttyUSB* exists, and Vivado sees a JTAG target; if not, stop and ask me to attach the board. Run `make -C Platform prog` then `make -C Platform run`, wait for 'Listening on /dev/ttyUSB…', and ask me to press CPU RESET (upper-right button, not PROG). Then go Main menu -> l -> 2 -> t (Lab2 set tests) and r (Lab2 random tests). Done when the captured UART output of both runs is pasted in the conversation and shows every case passing with zero failures. If a case fails, fix NPU.v or lab2_api.cc, re-run Goal 1's simulation until it is green, then reprogram and retest. Never report a board result that was not observed in UART output. Or stop after 25 turns.
```

## Goal 4: `ConvPerChannel` uses `hw_simd_mac` and matches the reference on the host [anywhere]

```text
Platform/sw/tflm_patches/tensorflow/lite/kernels/internal/reference/integer_ops/conv.h includes lab2_api.h and computes every input-channel product of the int8 ConvPerChannel through hw_simd_mac; it no longer calls NPU funct3 codes directly and has no CPU multiply-accumulate over input/filter channels. CPU code only does loop control, address math, padding checks, bias, per-channel multiplier/shift, output offset and clamping. A host test (new file under the scratch area, not submitted) compiles this conv.h with a software model of hw_simd_mac and compares the output byte-for-byte against the unmodified upstream tflite-micro reference ConvPerChannel. It covers grouped convolution (filter_input_depth < input_depth), input_offset over the full int8 range, input depths 1..300, stride 1 and 2, dilation 1 and 2, SAME and VALID padding with out-of-image taps, with and without bias, per-channel multipliers and shifts, activation clamps, batch > 1, and the actual ds_cnn_stream_fe conv shapes. Done when the host test prints a final line showing all cases pass with 0 mismatches, and a deliberately broken copy (e.g. wrong input_offset sign) fails, both shown. Or stop after 25 turns.
```

## Goal 5: Basic convolution tests and KWS labels correct on the board [board]

```text
On the Arty A7 with the Goal 3 bitstream, the accelerated conv.h produces correct results. Do the same board checks as Goal 3 and ask me to press CPU RESET when the listener is up. Step 1: `make -C Platform run` (model-free), then Main menu -> l -> c (Basic convolution tests); the UART output must show all three cases [PASS]. Step 2: `make run -C Platform/sw MODEL_FILE=ds_cnn_stream_fe.tflite MODEL_PROFILE=ds_cnn_stream_fe` and run inference for every label in Platform/sw/models/label (inference takes about 3 minutes each). Each label's model output must equal its golden answer. Print the output and the golden value side by side, plus the `interpreter.Invoke()` cycle count for each label. Done when all three conv cases show [PASS] and every label matches, with the UART output pasted. Any mismatch is a failure (it zeroes Part 2 and efficiency): fix it and re-run Goal 4's host test before retesting. Or stop after 25 turns.
```

## Goal 6: Post-route implementation fits the resource and timing limits [Vivado]

```text
`make -C Platform prog` (after `make -C Platform all_clean` if the bitstream could be stale) finishes post-route implementation for Arty-A7 100T. Platform/build/reports/post_route_utilization_npu.rpt shows exactly one recursive NPU instance, with Slice LUTs <= 20000, flip-flops <= 5000, DSP48E1 <= 30, RAMB18E1 <= 270 and RAMB36E1 <= 135. Platform/build/reports/post_route_timing_summary.rpt shows a Design Timing Summary with overall setup WNS (ns) >= 0. Done when the relevant lines of both reports are printed in the conversation, together with a short table of used vs limit. If a limit is missed, change the RTL, re-run Goal 1's simulation until it passes, and rebuild. Or stop after 15 turns.
```

## Goal 7: Lower the average `Invoke()` cycles without breaking correctness [board]

```text
Reduce the average interpreter.Invoke() cycle count over all labels in Platform/sw/models/label, starting from the Goal 5 baseline, by changes only in NPU.v (and helper RTL), lab2_api.cc, conv.h and ds_cnn_stream_fe_profile.cc. Ideas include wider SIMD lanes, merging the filter_width*depth row into one call when dilation_width is 1 and no padding applies, cheaper cache cleaning, and fewer command round-trips. Cached final outputs are not allowed. Keep a table in Platform/sw/lab2_latency.md with one row per attempt: the change, the average cycles, and the LUT/FF/DSP/BRAM and WNS figures. After each kept change, all of these must still hold, shown with fresh output: Goal 1 simulation 0 failures, Goal 4 host test 0 mismatches, Goal 6 limits met with WNS >= 0, the Goal 3 set and random tests passing, and every Goal 5 label matching its golden answer. Done when the latest table row shows the average cycles at least 20% below the Goal 5 baseline with all checks green, or stop after 40 turns and keep the best fully green version committed.
```

## Goal 8: Clean rebuild from the submission files [Vivado + board]

```text
The four submitted files rebuild and run with no source edits. Copy only NPU.v, any helper .v modules, lab2_api.cc and conv.h from the lab2 branch into a fresh checkout of the platform with the unmodified Lab 2 download applied (no Platform/build). Then, using only the documented commands, run make -C Platform prog, make -C Platform run (Lab2 t and r, Basic convolution c) and make run -C Platform/sw MODEL_FILE=ds_cnn_stream_fe.tflite MODEL_PROFILE=ds_cnn_stream_fe, asking me to press CPU RESET each time. Done when the UART output shows all three suites passing and every label matching, the reports meet the Goal 6 limits, and `git -C <fresh checkout> status` shows only those submitted files changed. Or stop after 15 turns.
```

## Goal 9: Submission zip has the exact structure [anywhere]

```text
A file aaml-lab2-<id>.zip exists (ask me for <id> if it is not known) whose `unzip -l` listing contains exactly: aaml-lab2-<id>/hw/src/NPU.v, aaml-lab2-<id>/hw/src/<each helper .v that NPU.v instantiates>, aaml-lab2-<id>/sw/conv.h and aaml-lab2-<id>/sw/lab2_api.cc, and nothing else (no Platform/build, Vivado project, .bit, logs, testbenches or host tests). The note says 'hw/src', singular. Each file is byte-identical to the version that passed Goal 8: show `unzip -l` and a sha256sum comparison. Every module that NPU.v instantiates is either in the zip or part of the stock platform: show a grep of the instantiations. Done when the listing and the matching hashes are printed. Or stop after 5 turns.
```

---

## Demo prep (no goal)

Part 4 (20%) is a live explanation, so it has no test to run. When Goal 7 is done, ask Claude for a one-page note covering:

- the AR/R state machine and how stalls are handled
- what happens on early `RLAST`, missing `RLAST` and a non-OKAY `RRESP`
- how the 4 KiB split is computed
- how unaligned pointers are realigned in hardware
- why `cbo_clean` is needed and which lines get cleaned
- how `ConvPerChannel` maps onto `hw_simd_mac`
