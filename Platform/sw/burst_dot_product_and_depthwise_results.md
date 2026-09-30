# ds_cnn_stream_fe latency: NPU burst dot product (CONV_2D) and channel-blocked int8 depthwise kernel (DEPTHWISE_CONV_2D)

## Result

| Measurement (one label1 inference, `Cycles:` from the `mcycle` reads around `interpreter.Invoke()`) | Cycles |
|---|---:|
| Before this work ([`inference_latency_results.md`](inference_latency_results.md), final clean build) | 5,335,912,041 |
| Required ceiling | 2,000,000,000 |
| **Final clean build (`TFLM_SOFTWARE_CONV=0`, profiling off), FPGA, rebuilt bitstream** | **740,369,086** |
| Reduction | 4,595,542,955 (86.12%), 7.21× faster (14,807 ms at 50 MHz) |

| Operator (final profiling build, FPGA) | Cycles | Ceiling |
|---|---:|---:|
| CONV_2D (6 nodes) | 259,901,327 | 1,000,000,000 |
| DEPTHWISE_CONV_2D (5 nodes) | 132,747,507 | 400,000,000 |

All 12 raw output words equal the software/reference baseline. Menu tests a, e, c and b pass on the final image. All three iverilog testbenches pass (the new one plus the two existing misaligned-AXI ones). `make -C Platform prog` rebuilt the bitstream from the changed RTL, and post-route WNS is +1.211 ns at 50 MHz. The host checks of both kernels against upstream TFLM show 0 mismatches, and each mutated kernel fails.

The two steps were taken in order and profiled after each:

| operator | nodes | before (profiling build, previous doc) | after CONV_2D step | after DEPTHWISE_CONV_2D step (final profiling run) |
|---|---:|---:|---:|---:|
| QUANTIZE | 2 | 8,144,537 | 8,105,649 | 8,039,757 |
| RESHAPE | 2 | 85,582 | 86,331 | 85,166 |
| DEQUANTIZE | 2 | 6,722,432 | 6,713,472 | 6,744,416 |
| AudioSpectrogram | 1 | 245,738,908 | 244,949,212 | 247,055,885 |
| Mfcc | 1 | 83,738,344 | 86,223,223 | 83,839,617 |
| MUL | 1 | 143,111 | 143,339 | 142,878 |
| **CONV_2D** | 6 | **4,164,060,220** | **260,024,269** | **259,901,327** |
| **DEPTHWISE_CONV_2D** | 5 | **832,339,237** | **833,302,830** | **132,747,507** |
| AVERAGE_POOL_2D | 1 | 417,917 | 440,507 | 425,216 |
| FULLY_CONNECTED | 1 | 60,475 | 61,651 | 61,389 |
| (sum of operators) | 22 | 5,341,450,763 | 1,440,050,483 | 739,043,158 |
| (Invoke total, profiling build) | | 5,344,807,655 | 1,443,402,767 | 742,395,054 |

## Configuration (unchanged)

- Model `models/ds_cnn_stream_fe.tflite`, profile `ds_cnn_stream_fe`, `label1` board input, one sample (local `Platform/sw/project.mk`).
- Tensor arena 1,048,576 bytes: every build log shows `-DTENSOR_ARENA_SIZE=1048576`, and the board prints `Tensor arena: 1048576 bytes`.
- Clock 50 MHz: `PLATFORM_CLOCK_HZ` is unchanged, the build parsed `PLATFORM_CLOCK_HZ = 50000000 Hz`, and the post-route clock `clk_out2_MMIO_clk_wiz_0_1` has a 20.000 ns period.
- These are all unchanged: compiler flags, `Makefile`, model, input, the `mcycle` measurement around `Invoke()`, existing tests, golden data, existing results documents, and the `TFLM_SOFTWARE_CONV=1` reference path (see "Reference path").

## Files

Changed:

- `Platform/hw/srcs/NPU.v`:
  - Adds the burst dot product instruction (funct3 `100`) and instantiates `npu_burst_dot_product`.
  - The AR/R channels are muxed: the burst engine owns them in state `STATE_BURST_DOT_PRODUCT`, and the single-word AXI read owns them otherwise.
  - `M_AXI_ARLEN` comes from the engine during bursts and is 0 otherwise. The state register widens from 3 to 4 bits.
  - The existing AXI read (funct3 `001`), AXI write (`010`), SIMD MAC (`011`) and compute (`000`) paths keep their encoding and behavior. The port list is unchanged.
- `Platform/sw/tflm_patches/.../integer_ops/conv.h`: the int8 `ConvPerChannel` now uses the burst dot product ("CONV_2D step" below). The int16 kernel and the int4 wrapper are unchanged.
- `Platform/sw/project/tflm_ops.cc`: registers `Register_DEPTHWISE_CONV_2D_INT8_CHANNEL_BLOCKED()`. Under `TFLM_SOFTWARE_CONV` it keeps the upstream `AddDepthwiseConv2D()`. (`tflm_ops.h` did not need a change.)
- `Platform/sw/app/tflm_runner.cc`: only the `Convolution path:` banner text changed. The profiler and the `Invoke()` measurement are untouched.

New:

- `Platform/hw/srcs/npu_burst_dot_product.v`: the burst dot product engine (module `npu_burst_dot_product`).
- `Platform/hw/sim/npu_burst_dot_product_tb.sv`: iverilog testbench for the instruction.
- `Platform/sw/project/depthwise_conv_int8_channel_blocked.h` / `.cc`: `tflite::DepthwiseConvInt8ChannelBlocked()`, the int8 depthwise kernel.
- `Platform/sw/project/depthwise_conv_int8_channel_blocked_registration.cc`: `tflite::Register_DEPTHWISE_CONV_2D_INT8_CHANNEL_BLOCKED()`. It runs the new kernel for int8 input with int8 filter; every other type combination runs the upstream kernel. Init and Prepare are the upstream ones.

Both project `.cc` files compile only under `TFLM_MODEL_ENABLED`, because TFLM sources are not prepared in model-less builds.

Build side effect: the Vivado run rewrote four tracked block-design `.xci` files (CPU, NPU, dcache and icache bridges). The only change was the metadata field `value_permission` ("bd" → "bd_and_user"). They were restored with `git checkout` after the build and are not part of this change.

## CONV_2D step: NPU burst dot product instruction

### Instruction

CUSTOM-0 (opcode `0x0B`), funct3 = `100`:

| funct7 | operation | rs1 | rs2 | rd |
|---:|---|---|---|---|
| 0 | set vector length | length in bytes | - | rs1 |
| 1 | burst dot product | input address | filter address | Σ int8(input[i]) × int8(filter[i]), i < length (mod 2^32) |

Software wrappers are in the patched `conv.h`:

- `NpuBurstDotProductSetLength()` and `NpuBurstDotProduct()` issue the instruction on RISC-V.
- A C model replaces the instruction on host builds and with `CFU_SOFTWARE_DEFINED`.
- `CleanDataCacheRangeForNpu()` writes back (`cbo.clean`) every 32-byte line that overlaps a range, including partial first and last lines. The earlier `CleanTensorForAxi` stepped from an unaligned start and could miss the last line.

### Hardware (`npu_burst_dot_product.v`)

**Chunks.** The vectors are processed in chunks of up to 256 words (1 KB). For each chunk the address side requests the input segment first and the filter segment immediately after, so both are in flight together. The data side keeps the input words of the chunk in a 256 × 32 buffer (1 RAMB18). It multiplies each arriving filter word with the buffered input word at the same index: 4 signed 8 × 8 lanes per beat, summed, then accumulated in 32 bits.

**Bursts.** Reads are `ARSIZE` = 4 bytes, `ARBURST` = INCR, with ARLEN up to 255 (256 beats). Each burst length is min(words left in the segment, 256, words left before the next 4 KB boundary), so no burst crosses a 4 KB boundary.

**Addresses and lengths that are not multiples of 4.** Each segment fetches the word-aligned span that covers it. A funnel shifter per segment realigns the byte stream so that vector byte j lands in lane j % 4 of aligned word j / 4. This is done independently for the input and filter offsets, and lanes past the end are zeroed.

**R-channel flow control.** RREADY is high while a segment streams. It is low for the 1-cycle setup of each segment, and for 1 cycle when a misaligned segment's last aligned word has to be flushed from the funnel shifter.

**Coherence.** The engine reads DDR directly. `ConvPerChannel` calls `CleanDataCacheRangeForNpu()` on the whole input tensor and the whole filter tensor before its first NPU call. The NPU never writes, so nothing needs to be invalidated.

**Resources.** Post-route utilization (`build/reports/post_route_utilization_npu.rpt`):

| instance | LUTs | FFs | RAMB18 | DSP |
|---|---:|---:|---:|---:|
| NPU total | 1,190 | 728 | 1 | 4 |
| `u_burst_dot_product` | 916 | 465 | 1 | 0 |

### Software (`ConvPerChannel`, int8)

- **Filter depth ≥ 8.** Every in-image filter tap is one `NpuBurstDotProduct(input_tap, filter_tap)` over the filter depth, with the length set once per call. The kernel then adds `input_offset × Σfilter`, using per-(output channel, tap) sums precomputed once per call; if the 4,096-entry buffer is too small, the sum is computed directly. Bias, requantization and clamping follow. Any alignment is valid, so there is no scalar remainder loop.
- **Filter depth < 8** (node 8: 3×3, 1 input channel). The pixel's input patch is gathered once per group, with `input + input_offset` for in-image taps and 0 otherwise, and reused for all output channels of the group.
- **Shallow filter with a patch larger than 1,024 values.** Reference arithmetic.

The integer result is identical to the upstream kernel (host check below).

### Bitstream and timing

```sh
cd TinyRISC-V-SoC-Platform
source ../env.sh
make -C Platform prog      # log: /tmp/nnchip-burst-make-prog.log, SHA-256 162a3a38…1737
```

- The log shows `>> [HW] Hardware changes detected! Starting Full Synthesis...`, then `write_bitstream completed successfully`, `>> [HW] Programming FPGA with .../build/out.bit`, `End of startup status: HIGH` and `EXIT=0`.
- New `Platform/build/out.bit` was written at 21:31:30 and has SHA-256 `60a91a22ec0e82e44039972ff744f4d3cc41f3b73ea552d90f7d22d485c3c009`. The previous bitstream was `8871f97e…2b84`.
- The only critical warnings are two pre-existing block-design `util_vector_logic_3` width-mismatch warnings, which are unrelated to the NPU.
- `build/reports/post_route_timing_summary.rpt`:
  - Design timing summary: WNS 1.211 ns, TNS 0.000 ns, 0 failing endpoints; WHS 0.011 ns; "All user specified timing constraints are met."
  - `clk_out2_MMIO_clk_wiz_0_1` (CPU/NPU clock, period 20.000 ns, 50.000 MHz): WNS 1.211 ns, WHS 0.098 ns.

### Simulation (iverilog 12)

```sh
cd TinyRISC-V-SoC-Platform
for tb in npu_burst_dot_product_tb npu_misaligned_axi_read_tb npu_misaligned_axi_write_tb; do
  iverilog -g2012 -Wall -s $tb -o /tmp/nnchip-burst-sim/$tb.vvp \
    Platform/hw/srcs/NPU.v Platform/hw/srcs/npu_burst_dot_product.v Platform/hw/sim/$tb.sv \
    && vvp /tmp/nnchip-burst-sim/$tb.vvp
done
```

The existing testbenches are unchanged. `npu_burst_dot_product.v` is added to the command line because `NPU.v` now instantiates it.

| testbench | result |
|---|---|
| `npu_burst_dot_product_tb` (new) | `[PASS] All 365 burst dot product checks`, exit 0, no `FAIL` |
| `npu_misaligned_axi_read_tb` | `[PASS] All aligned/misaligned AXI read reconstruction checks`, exit 0 |
| `npu_misaligned_axi_write_tb` | `[PASS] All aligned/misaligned AXI write byte-placement and handshake checks`, exit 0 |

**The new testbench** drives the NPU through its CPU interface against an AXI4 read slave. The slave has a byte memory, accepts several outstanding bursts, returns beats in order with RLAST, holds RDATA while RREADY is low, and can randomly stall ARREADY and insert RVALID gaps.

On every AR handshake it checks:

- word alignment;
- `ARSIZE` = 4 bytes and `ARBURST` = INCR;
- no 4 KB crossing;
- ARADDR/ARLEN are stable, and ARVALID is held, while waiting for ARREADY.

Each result is compared with a reference computed from the memory, and no read data may be outstanding at `NPU_done`.

Covered cases:

- **Burst length 1:** 1- and 4-byte vectors issue ARLEN = 0 bursts (4 of them).
- **Maximum burst:** 1,024-byte aligned vectors issue exactly two ARLEN = 255 bursts.
- **4 KB crossing:** 601 bytes at `+0xF02`/`+0x2E81` and 1,024 bytes at `+0xE03`/`+0x2D00` are split at the boundary (4 bursts end exactly on a 4 KB boundary).
- **Unaligned start and tail:** all 16 input/filter byte-offset pairs × lengths 1, 2, 3, 4, 5, 7, 8, 13, 300, 301, 302, 303.
- **Signed extremes:** −128 × −128 over 1,024 bytes (16,777,216), −128 × 127, 127 × 127, mixed −128/127/−1, and a 2,598-byte multi-chunk −128 × −128 (42,544,000).
- **Multi-chunk vectors:** 2,048 and 2,500 bytes.
- **Zero length:** no bursts, result 0.
- **AR/R backpressure:** 70% ARREADY stalls and 60% RVALID gaps on max-burst, 4 KB-crossing, unaligned-tail, multi-chunk and length-1 cases. This produced 38 ARREADY stall cycles, 3,248 RVALID gap cycles, and 3 cycles where RVALID was high and the NPU held RREADY low.
- **150 random cases:** random offsets, lengths 0–2,999, random stall/gap rates.
- **Shared channel:** the single-word AXI read (aligned and misaligned) and the SIMD MAC (reset and accumulate) still work after burst operations.

Overall coverage: 847 bursts, 131 with ARLEN = 0, 58 with ARLEN = 255, 35 ending on a 4 KB boundary.

### Profile after the CONV_2D step (FPGA, profiling build)

```sh
make -j6 -C Platform/sw BUILD_DIR=/tmp/nnchip-burst-dot-product-profile-build \
  MODEL_FILE=ds_cnn_stream_fe.tflite MODEL_PROFILE=ds_cnn_stream_fe \
  TFLM_SOFTWARE_CONV=0 APP_DEFINES=-DTFLM_OPERATOR_CYCLE_PROFILE=1 all
python3 /tmp/nnchip_board_menu_runner.py /tmp/nnchip-burst-dot-product-profile-build/main.bin \
  /tmp/nnchip-burst-dot-product-profile-run.log tlaecb 3000
```

- `main.elf` SHA-256 `e7c9d38c…0e3e`. UART log SHA-256 `e46989a5…2fbd`.
- The disassembly contains two funct3 = 4 instructions of each funct7 (set-length and compute), in `ConvPerChannel` and in menu c's `RunConvTest`.
- `DEPTHWISE_CONV_2D` still used the upstream kernel in this build.
- `Invoke status: kTfLiteOk`, output words identical to the baseline, and a/e/c/b passed in the same session.

```text
Per-operator cycles (sum over nodes of each operator type):
  operator              nodes          cycles   share
  QUANTIZE                  2         8105649    0.56%
  RESHAPE                   2           86331    0.00%
  DEQUANTIZE                2         6713472    0.46%
  AudioSpectrogram          1       244949212   16.97%
  Mfcc                      1        86223223    5.97%
  MUL                       1          143339    0.00%
  CONV_2D                   6       260024269   18.01%
  DEPTHWISE_CONV_2D         5       833302830   57.73%
  AVERAGE_POOL_2D           1          440507    0.03%
  FULLY_CONNECTED           1           61651    0.00%
  (sum of operators)       22      1440050483   99.76%
  (Invoke total)                   1443402767
```

CONV_2D went from 4,164,060,220 to 260,024,269 cycles (−93.8%). Per node:

| node | shape | before | after | cycles per output |
|---:|---|---:|---:|---:|
| 8 | 3×3, 1 input channel (gathered patch) | 144,808,898 | 51,643,250 | 212 |
| 10 | 1×1, 300→300, 43×16 | 1,685,578,075 | 86,855,377 | 421 |
| 12 | 1×1, 300→300, 39×12 | 1,146,335,032 | 58,668,254 | 418 |
| 14 | 1×1, 300→300, 30×10 | 734,987,432 | 38,710,777 | 430 |
| 16 | 1×1, 300→300, 22×6 | 324,306,594 | 17,026,488 | 430 |
| 18 | 1×1, 300→300, 13×4 | 128,044,189 | 7,120,123 | 456 |

A pointwise output used to cost 75 × (2 single-word AXI reads + 1 SIMD MAC) ≈ 8,170 cycles. It is now one 300-byte burst dot product plus requantization, about 420 cycles.

## DEPTHWISE_CONV_2D step: channel-blocked int8 kernel

### Choice (from the CONV_2D-step profile)

After the CONV_2D step, DEPTHWISE_CONV_2D was 57.7% of Invoke: 833,302,830 cycles for 6.88 M MACs and 492,000 outputs, about 1,694 cycles per output with the upstream reference kernel.

The profile favors restructured software over the NPU path:

- The burst dot product costs about 420 cycles per call even for a 300-byte vector (pointwise nodes above), and much of that is the AXI round trip.
- A depthwise output reduces over only 9–30 taps, and those bytes are 300 bytes apart (NHWC with 300 channels), so there is no contiguous vector to stream.
- Even after transposing to channel-major layout, each output would need one NPU call per filter row. Each call would read 3 bytes (dilation 1) or be non-contiguous (dilation 2). That is at least 3–10 calls per output at over 100 cycles each.
- The reference kernel's cost is mostly `Offset()` index arithmetic and the per-tap `input_offset` add, which software can remove.

### Kernel (`DepthwiseConvInt8ChannelBlocked`)

1. **Once per call:** `bias + input_offset × Σ(filter over the whole window)` per output channel.
2. **Once per output pixel:** a list of (input pixel, filter tap) pointers for the in-image taps.
3. **Depth multiplier 1, whole window inside the image** (every pixel of this model): 8 channels per pass, with 8 accumulators in registers and plain int8 × int8 MACs over the tap list, then requantization.
4. **Other cases:** for padded borders, depth multiplier > 1, and the remainder channels (the remainder uses the same full-window form). Border pixels use the reference form `filter × (input + input_offset)` over the in-image taps only.
5. **Capacity fallback:** more than 2,048 channels or more than 256 taps goes to the upstream reference kernel.

Requantization is the same `MultiplyByQuantizedMultiplier` call, so the result is bit-identical.

### Host check against upstream TFLM (0 mismatches; mutated kernel fails)

The harness is outside the repository; its full source is in the appendix. `/tmp/nnchip-depthwise-host-check/depthwise_host_check.cc` has SHA-256 `787a3ada…12e3`. It links the repository kernel `depthwise_conv_int8_channel_blocked.cc` and compares its output bytes with `tflite::reference_integer_ops::DepthwiseConvPerChannel` from `tflite-micro`. Output buffers are pre-filled with different junk, so unwritten bytes also count as mismatches.

```sh
ROOT=~/NNchip/TinyRISC-V-SoC-Platform
INC="-I$ROOT/Platform/sw/project -I$ROOT/tflite-micro -I$ROOT/tflite-micro/third_party/gemmlowp \
     -I$ROOT/tflite-micro/third_party/flatbuffers/include -I$ROOT/tflite-micro/third_party/ruy"
cd /tmp/nnchip-depthwise-host-check
g++ -std=c++17 -O2 -Wall -DTFLM_MODEL_ENABLED=1 $INC -o depthwise_host_check \
  depthwise_host_check.cc $ROOT/Platform/sw/project/depthwise_conv_int8_channel_blocked.cc
./depthwise_host_check                       # exit 0
sed 's/g_full_window_bias\[out_channel\] += input_offset \* filter_tap\[out_channel\];/g_full_window_bias[out_channel] += 0 * filter_tap[out_channel];/' \
  $ROOT/Platform/sw/project/depthwise_conv_int8_channel_blocked.cc > mutated_depthwise_conv_int8_channel_blocked.cc
g++ -std=c++17 -O2 -DTFLM_MODEL_ENABLED=1 $INC -o depthwise_host_check_mutated \
  depthwise_host_check.cc mutated_depthwise_conv_int8_channel_blocked.cc
./depthwise_host_check_mutated               # exit 1
```

```text
./depthwise_host_check  (exit 0)
cases=2741 mismatching_cases=0 mismatching_bytes=0
coverage: full-window pixels=35712 border pixels=42743, cases with depth_multiplier>1=614 padding=2492 dilation>1=2364 stride>1=2446 odd depth=1372 misaligned pointers=2686 capacity fallback=2

./depthwise_host_check_mutated  (exit 1; input-offset term dropped from the full-window bias)
cases=2741 mismatching_cases=1852 mismatching_bytes=440301
```

The cases are:

- the model's five depthwise layers, exactly (45×18, 43×16, 39×12, 30×10 and 22×6 inputs with 300 channels; 3×3, 3×3 dilation 2, 10×3, 5×3 dilation 2 and 10×3 filters);
- one channel-capacity fallback (2,050 channels) and one tap-capacity fallback (17×16 taps);
- 4,000 random draws: batches 1–2, 1–12 × 1–12 inputs, 1–37 channels (plus deeper ones), depth multiplier 1–3, 1–4 × 1–4 and 10-row filters, strides 1–3, dilations 1–3, padding 0–2, with or without bias, and input, filter and output pointers misaligned by 0–3 bytes.

Draws with no valid output are skipped, which leaves 2,741 cases in total.

A similar host check of the patched `conv.h` was also run: the patched int8 `ConvPerChannel` (with the C model of the NPU instruction) against the upstream `ConvPerChannel`. It covers 2,425 cases: 1,780 on the burst path, 644 on the gathered patch path and 1 on the reference fallback. They include the model's node 8 and pointwise shapes, menu c's shapes, the tap-sum buffer fallback, groups, and misaligned pointers. Result: 0 mismatches. A mutated variant (input-offset correction sign flipped) had 1,671 mismatching cases. The harness is `/tmp/nnchip-conv-host-check/conv_host_check.cc`, SHA-256 `717cd16f…83e9`.

### Profile after the DEPTHWISE_CONV_2D step (final profiling run, FPGA)

This build uses the final sources; it differs from the final clean build only by `APP_DEFINES=-DTFLM_OPERATOR_CYCLE_PROFILE=1`. Every edited source was last written before this build (21:35:33) and before the final clean build (21:39:17).

```sh
make -j8 -C Platform/sw BUILD_DIR=/tmp/nnchip-channel-blocked-depthwise-profile-build \
  MODEL_FILE=ds_cnn_stream_fe.tflite MODEL_PROFILE=ds_cnn_stream_fe \
  TFLM_SOFTWARE_CONV=0 APP_DEFINES=-DTFLM_OPERATOR_CYCLE_PROFILE=1 all
python3 /tmp/nnchip_board_menu_runner.py /tmp/nnchip-channel-blocked-depthwise-profile-build/main.bin \
  /tmp/nnchip-channel-blocked-depthwise-profile-run.log tlaecb 3000
```

- `main.elf` SHA-256 `a549fe70…983d`. UART log SHA-256 `b5075e0e…f797`.
- `Invoke status: kTfLiteOk`, output words identical, and a/e/c/b passed in the same session.

```text
Per-operator cycles (sum over nodes of each operator type):
  operator              nodes          cycles   share
  QUANTIZE                  2         8039757    1.08%
  RESHAPE                   2           85166    0.01%
  DEQUANTIZE                2         6744416    0.90%
  AudioSpectrogram          1       247055885   33.27%
  Mfcc                      1        83839617   11.29%
  MUL                       1          142878    0.01%
  CONV_2D                   6       259901327   35.00%
  DEPTHWISE_CONV_2D         5       132747507   17.88%
  AVERAGE_POOL_2D           1          425216    0.05%
  FULLY_CONNECTED           1           61389    0.00%
  (sum of operators)       22       739043158   99.54%
  (Invoke total)                    742395054
```

DEPTHWISE_CONV_2D went from 833,302,830 to 132,747,507 cycles (−84.1%), about 270 cycles per output. The other operators moved by less than ±3%, which is run-to-run noise.

| node | filter | upstream reference | channel-blocked |
|---:|---|---:|---:|
| 9 | 3×3 | 242,298,922 | 41,463,163 |
| 11 | 3×3, dilation 2 | 165,295,404 | 28,577,276 |
| 13 | 10×3 | 301,440,018 | 43,163,275 |
| 15 | 5×3, dilation 2 | 71,688,949 | 11,694,532 |
| 17 | 10×3 | 52,579,537 | 7,849,261 |

## Final clean build and FPGA run

```sh
cd TinyRISC-V-SoC-Platform
rm -rf /tmp/nnchip-burst-final-clean-build
make -j6 -C Platform/sw BUILD_DIR=/tmp/nnchip-burst-final-clean-build \
  MODEL_FILE=ds_cnn_stream_fe.tflite MODEL_PROFILE=ds_cnn_stream_fe TFLM_SOFTWARE_CONV=0 all
python3 /tmp/nnchip_board_menu_runner.py /tmp/nnchip-burst-final-clean-build/main.bin \
  /tmp/nnchip-burst-final-clean-run.log tlaecb 3000
```

**Build.** The log `/tmp/nnchip-burst-final-clean-build.log` has SHA-256 `df42a12e…c6f8`, exit 0 and 0 warnings. It contains `-DTENSOR_ARENA_SIZE=1048576` and the Makefile's fixed message for the patched `conv.h`, `>> Selecting patched AXI + SIMD ConvPerChannel`. `TFLM_OPERATOR_CYCLE_PROFILE` does not appear, and the ELF contains no profiler strings.

| artifact | SHA-256 |
|---|---|
| `main.elf` | `f5637b5bed5651d87b4420eaebd34ad20305ba25dded3b3f8a52ddecde9e6902` |
| `main.bin` | `9709cbeca8c008d283598e3c0ef501603b3e817b037e4aea959fe37cce5e26dc` |
| build-copy `conv.h` (equals the patched source) | `4831d97f4d3d5937bdb0ac4544551faf9dc2ce761d0691deda707c1a67c3ace2` |

**Runner.** `/tmp/nnchip_board_menu_runner.py`, the helper from the previous work, is outside the repository. It:

1. programs `Platform/build/out.bit` (the rebuilt bitstream `60a91a22…c009`), which resets the CPU into the bootloader (`End of startup status: HIGH`);
2. uploads `main.bin` after `SYNC` with the repository `upload.py` functions;
3. sends `t`, `l`, `a`, `e`, `c`, `b`, each after the prompt returns.

UART transcript `/tmp/nnchip-burst-final-clean-run.log`, SHA-256 `ea0c712589ef2067343ff7c2ceac8a9386e8445250bf299d276488e56a13cdff`:

```text
=== TFLM Functional Verification ===
Model: ds_cnn_stream_fe.tflite (589000 bytes)
Convolution path: accelerated NPU burst dot product (CONV_2D), channel-blocked int8 kernel (DEPTHWISE_CONV_2D)
Tensor arena: 1048576 bytes
Profile: ds_cnn_stream_fe
Input profile: label1 board audio input
Output profile: verification skipped, tolerance=0
Samples: 1
AllocateTensors: kTfLiteOk

--- Sample 1/1 ---
input bytes=64000 type=1
Running inference...
Invoke status: kTfLiteOk
Inference complete.
Output Data:
...
Cycles: 740369086
Time (50000000 Hz): 14807 ms
```

### Output words vs. software/reference baseline

| index | baseline ([`software_inference_baseline.md`](software_inference_baseline.md)) | final FPGA run | match |
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
| c | Basic Convolution Test | Testcase1/2/3 `[PASS]` (28,771 / 207,749 / 828,865 cycles; total 1,065,385). Now runs through the burst dot product. |
| b | Accelerator AXI Misaligned Test | `[AXI] ALL PASS (6 checks).` |

The transcript contains no `FAIL`.

## Reference path

A fresh `TFLM_SOFTWARE_CONV=1` build was made in `/tmp/nnchip-burst-reference-path-build` (exit 0, 0 warnings):

- It printed `>> Selecting upstream software/reference ConvPerChannel`.
- Its build-copy `conv.h` has SHA-256 `9ebe12d5acfcebadb7c00cc38eee32f6d74b81ce4e29e664bbf590de0b28dca3`, the upstream hash recorded in the baseline.
- The ELF prints `Convolution path: software/reference (upstream TFLM ConvPerChannel)` and contains no channel-blocked symbols, because `tflm_ops.cc` registers the upstream depthwise kernel under `TFLM_SOFTWARE_CONV`.

## What the remaining time is (final profiling run)

- CONV_2D is 35.0% (259.9 M cycles). The five pointwise nodes cost about 420 cycles per output, which is one burst dot product plus requantization. Node 8 is 51.4 M.
- AudioSpectrogram and Mfcc together are 44.6% (330.9 M cycles), both soft-float on rv32im.
- DEPTHWISE_CONV_2D is 17.9% (132.7 M cycles).

## Appendix: depthwise host check harness

`/tmp/nnchip-depthwise-host-check/depthwise_host_check.cc` (SHA-256 `787a3ada919078e27852e48e8f12a31e33a1b85003c3b9a6076d013d8cd312e3`):

```cpp
// Host equivalence check: DepthwiseConvInt8ChannelBlocked (Platform/sw/project)
// against upstream TFLM reference_integer_ops::DepthwiseConvPerChannel.
// Exit status 0 only if every case matches bit for bit.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "depthwise_conv_int8_channel_blocked.h"
#include "tensorflow/lite/kernels/internal/reference/integer_ops/depthwise_conv.h"

namespace {
unsigned g_state = 20260930u;
int Rand(int n) {  // deterministic LCG, 0 <= value < n
  g_state = g_state * 1103515245u + 12345u;
  return static_cast<int>((g_state >> 8) % static_cast<unsigned>(n));
}

struct Case {
  int batches, height, width, input_depth, depth_multiplier;
  int filter_height, filter_width, stride_h, stride_w, dilation_h, dilation_w;
  int pad_h, pad_w;
  bool has_bias;
  int input_misalign, filter_misalign, output_misalign;
};

int g_cases = 0, g_mismatching_cases = 0, g_mismatching_bytes = 0;
int g_full_window_pixels = 0, g_border_pixels = 0;
int g_depth_multiplier_gt1 = 0, g_padded = 0, g_dilated = 0, g_strided = 0;
int g_odd_depth = 0, g_misaligned = 0, g_capacity_fallback = 0;

void RunCase(const Case& c, const char* label) {
  const int eff_h = (c.filter_height - 1) * c.dilation_h + 1;
  const int eff_w = (c.filter_width - 1) * c.dilation_w + 1;
  const int out_h = (c.height + 2 * c.pad_h - eff_h) / c.stride_h + 1;
  const int out_w = (c.width + 2 * c.pad_w - eff_w) / c.stride_w + 1;
  if (out_h < 1 || out_w < 1 || c.height + 2 * c.pad_h < eff_h ||
      c.width + 2 * c.pad_w < eff_w) {
    return;
  }
  const int output_depth = c.input_depth * c.depth_multiplier;
  std::vector<int8_t> input_buf(c.batches * c.height * c.width * c.input_depth + 4);
  std::vector<int8_t> filter_buf(c.filter_height * c.filter_width * output_depth + 4);
  std::vector<int32_t> bias(output_depth), multiplier(output_depth), shift(output_depth);
  const int output_size = c.batches * out_h * out_w * output_depth;
  std::vector<int8_t> out_ref(output_size + 4), out_new(output_size + 4);
  for (auto& v : input_buf) v = static_cast<int8_t>(Rand(256) - 128);
  for (auto& v : filter_buf) v = static_cast<int8_t>(Rand(256) - 128);
  for (int i = 0; i < output_depth; ++i) {
    bias[i] = Rand(200001) - 100000;
    multiplier[i] = (1 << 30) + Rand(1 << 30);
    shift[i] = -Rand(12) + (Rand(8) == 0 ? 1 : 0);
  }
  int8_t* input = input_buf.data() + c.input_misalign;
  int8_t* filter = filter_buf.data() + c.filter_misalign;
  tflite::DepthwiseParams p{};
  p.input_offset = Rand(256) - 127;
  p.output_offset = Rand(256) - 128;
  p.stride_height = c.stride_h;
  p.stride_width = c.stride_w;
  p.dilation_height_factor = c.dilation_h;
  p.dilation_width_factor = c.dilation_w;
  p.padding_values.height = c.pad_h;
  p.padding_values.width = c.pad_w;
  p.depth_multiplier = c.depth_multiplier;
  p.quantized_activation_min = (Rand(3) == 0) ? p.output_offset : -128;
  p.quantized_activation_max = (Rand(4) == 0) ? 100 : 127;
  if (p.quantized_activation_min > p.quantized_activation_max) p.quantized_activation_min = -128;
  const int32_t in_dims[4] = {c.batches, c.height, c.width, c.input_depth};
  const int32_t f_dims[4] = {1, c.filter_height, c.filter_width, output_depth};
  const int32_t b_dims[1] = {output_depth};
  const int32_t o_dims[4] = {c.batches, out_h, out_w, output_depth};
  tflite::RuntimeShape in_shape(4, in_dims), f_shape(4, f_dims), b_shape(1, b_dims), o_shape(4, o_dims);
  // Fill outputs with different junk so unwritten bytes are detected.
  std::memset(out_ref.data(), 0x5a, out_ref.size());
  std::memset(out_new.data(), 0xa5, out_new.size());
  int8_t* o_ref = out_ref.data() + c.output_misalign;
  int8_t* o_new = out_new.data() + c.output_misalign;
  const int32_t* b = c.has_bias ? bias.data() : nullptr;
  tflite::reference_integer_ops::DepthwiseConvPerChannel(
      p, multiplier.data(), shift.data(), in_shape, input, f_shape, filter,
      b_shape, b, o_shape, o_ref);
  tflite::DepthwiseConvInt8ChannelBlocked(
      p, multiplier.data(), shift.data(), in_shape, input, f_shape, filter,
      b_shape, b, o_shape, o_new);
  int bad = 0;
  for (int i = 0; i < output_size; ++i) bad += (o_ref[i] != o_new[i]);
  ++g_cases;
  if (bad) {
    ++g_mismatching_cases;
    g_mismatching_bytes += bad;
    if (g_mismatching_cases <= 5) {
      std::printf("MISMATCH %s: B=%d H=%d W=%d C=%d dm=%d f=%dx%d s=%d,%d d=%d,%d pad=%d,%d bias=%d mis=%d/%d/%d: %d of %d bytes\n",
                  label, c.batches, c.height, c.width, c.input_depth, c.depth_multiplier,
                  c.filter_height, c.filter_width, c.stride_h, c.stride_w, c.dilation_h,
                  c.dilation_w, c.pad_h, c.pad_w, c.has_bias, c.input_misalign,
                  c.filter_misalign, c.output_misalign, bad, output_size);
    }
  }
  // Coverage bookkeeping.
  for (int oy = 0; oy < out_h; ++oy) {
    for (int ox = 0; ox < out_w; ++ox) {
      bool full = true;
      for (int fy = 0; fy < c.filter_height; ++fy) {
        for (int fx = 0; fx < c.filter_width; ++fx) {
          const int iy = oy * c.stride_h - c.pad_h + fy * c.dilation_h;
          const int ix = ox * c.stride_w - c.pad_w + fx * c.dilation_w;
          if (iy < 0 || iy >= c.height || ix < 0 || ix >= c.width) full = false;
        }
      }
      (full ? g_full_window_pixels : g_border_pixels) += c.batches;
    }
  }
  g_depth_multiplier_gt1 += c.depth_multiplier > 1;
  g_padded += (c.pad_h | c.pad_w) != 0;
  g_dilated += (c.dilation_h > 1 || c.dilation_w > 1);
  g_strided += (c.stride_h > 1 || c.stride_w > 1);
  g_odd_depth += (c.input_depth & 1);
  g_misaligned += (c.input_misalign | c.filter_misalign | c.output_misalign) != 0;
  g_capacity_fallback += (output_depth > 2048 || c.filter_height * c.filter_width > 256);
}
}  // namespace

int main() {
  // The five DEPTHWISE_CONV_2D layers of ds_cnn_stream_fe (VALID, dm = 1).
  const Case model_layers[5] = {
      {1, 45, 18, 300, 1, 3, 3, 1, 1, 1, 1, 0, 0, true, 0, 0, 0},
      {1, 43, 16, 300, 1, 3, 3, 1, 1, 2, 2, 0, 0, true, 0, 0, 0},
      {1, 39, 12, 300, 1, 10, 3, 1, 1, 1, 1, 0, 0, true, 0, 0, 0},
      {1, 30, 10, 300, 1, 5, 3, 1, 1, 2, 2, 0, 0, true, 0, 0, 0},
      {1, 22, 6, 300, 1, 10, 3, 1, 1, 1, 1, 0, 0, true, 0, 0, 0},
  };
  for (const Case& c : model_layers) RunCase(c, "model layer");
  // Capacity fallbacks (more channels / taps than the static buffers hold).
  RunCase({1, 3, 3, 2050, 1, 1, 1, 1, 1, 1, 1, 0, 0, true, 1, 2, 3}, "channel capacity fallback");
  RunCase({1, 18, 17, 3, 1, 17, 16, 1, 1, 1, 1, 0, 0, true, 0, 0, 0}, "tap capacity fallback");
  // Random shapes.
  for (int t = 0; t < 4000; ++t) {
    Case c;
    c.batches = 1 + Rand(2);
    c.height = 1 + Rand(12);
    c.width = 1 + Rand(12);
    c.input_depth = 1 + Rand(37);
    if (t % 4 == 0) c.input_depth = 8 * (1 + Rand(6)) + Rand(8);
    c.depth_multiplier = (t % 3 == 0) ? 1 + Rand(3) : 1;
    c.filter_height = 1 + Rand(4);
    c.filter_width = 1 + Rand(4);
    if (t % 17 == 0) c.filter_height = 10;
    c.stride_h = 1 + Rand(3);
    c.stride_w = 1 + Rand(3);
    c.dilation_h = 1 + Rand(3);
    c.dilation_w = 1 + Rand(3);
    c.pad_h = Rand(3);
    c.pad_w = Rand(3);
    c.has_bias = Rand(8) != 0;
    c.input_misalign = Rand(4);
    c.filter_misalign = Rand(4);
    c.output_misalign = Rand(4);
    RunCase(c, "random");
  }
  std::printf("cases=%d mismatching_cases=%d mismatching_bytes=%d\n", g_cases,
              g_mismatching_cases, g_mismatching_bytes);
  std::printf("coverage: full-window pixels=%d border pixels=%d, cases with depth_multiplier>1=%d padding=%d dilation>1=%d stride>1=%d odd depth=%d misaligned pointers=%d capacity fallback=%d\n",
              g_full_window_pixels, g_border_pixels, g_depth_multiplier_gt1, g_padded,
              g_dilated, g_strided, g_odd_depth, g_misaligned, g_capacity_fallback);
  return g_mismatching_cases == 0 ? 0 : 1;
}
```
