# Lab 4 results

## SW mode (baseline)

Source: UART log `Platform/sw/results/lab4_sw_baseline.log`, captured with `make -C Platform run TFLM_SOFTWARE_CONV=1` on the Arty A7 (menu `t`, one sample, zero input), after a clean hardware rebuild and program (`make -C Platform all_clean && make -C Platform prog`). Output status `kTfLiteOk`.

| Item | Value |
|---|---|
| Model | mobileViT_xxs.tflite (1,212,672 bytes), tensor arena 8 MiB, 50 MHz |
| Conv mode | software/reference (upstream TFLM ConvPerChannel), `TFLM_SOFTWARE_CONV=1`; depthwise = upstream kernel |
| Build flags | `-march=rv32im -mabi=ilp32 -mcmodel=medany -O3 -g -DTFLM_MODEL_ENABLED=1 -DMODEL_NAME="mobileViT_xxs.tflite" -DTENSOR_ARENA_SIZE=8*1024*1024 -DTFLM_SOFTWARE_CONV=1`; `USE_SOFTWARE_CFU=0`; no `TFLM_OPERATOR_CYCLE_PROFILE` |
| Invoke cycles | **6,533,448,017** (130,668 ms) |
| Counter 0 (Logistic) | Total 844,295,109 cycles, **Starts 37**, avg 22,818,786 |
| Counter 1 (Transpose) | Total 7,042,050 cycles, **Starts 66**, avg 106,697 |

### Shares of Invoke (counter total / Invoke cycles)

| Operator | Cycles | Share of Invoke |
|---|---:|---:|
| Logistic (counter 0) | 844,295,109 | 12.92% |
| Transpose (counter 1) | 7,042,050 | 0.108% |

### Notes

- Counter 0 Starts = 37 matches the expected value. **Counter 1 Starts measured 66, not the expected 48.** The value is recorded as measured; the discrepancy is unexplained (the counter is incremented per Transpose kernel call in `tflm_patches/.../reference/transpose.h`).
- Earlier attempts (`lab4_sw_baseline_attempt1/2/3_*.log`) failed with `Missing registration for opcode_index 24`. A per-64KB hash of `g_model` showed DDR content differing from the file (6 of 19 blocks). After `all_clean` and `prog` (new bitstream), the same flow ran correctly. The cause of the corruption was not identified.

## Logistic-only acceleration (Logistic on NPU, Transpose on CPU)

Source: UART log `Platform/sw/results/lab4_logistic_npu.log`, captured by Claude (script `scratch/lab4/board_run_lab4.py`: waits for `SYNC`, uploads `main.bin`, then drives the menu `l` > `l,a,c,b,d,e`, then main menu `t`). Bitstream `Platform/build/out.bit` (sha256 `6d998fdb0f269a6860f859db5db2468f7585eb590dc60d10b97dde7dc900a011`, built 00:51 from `npu_logistic.v` + `NPU.v`, programmed with `make -C Platform prog`); post-route WNS +0.488 ns, WHS +0.009 ns (`build/reports/post_route_timing_summary.rpt`). SYNC arrived after programming, so no CPU RESET press was needed. Software built with `make -C Platform sw_clean && make -C Platform sw_build TFLM_SOFTWARE_CONV=1` (same Conv mode, model, input, 50 MHz and flags as the SW baseline above).

| Item | SW baseline (G1) | Logistic on NPU |
|---|---:|---:|
| Counter 0 (Logistic) Total | 844,295,109 | **8,223,236** |
| Counter 0 Starts / Average | 37 / 22,818,786 | 37 / 222,249 |
| Counter 1 (Transpose) Total / Starts | 7,042,050 / 66 | 7,035,336 / 66 (CPU, unchanged) |
| Invoke cycles | 6,533,448,017 (130,668 ms) | 5,697,410,972 (113,948 ms) |
| Operator speedup (Counter 0 Total ratio) | 1x | **102.67x** |
| Model speedup (Invoke ratio) | 1x | **1.147x** |

Checks in the same log:
- `Logistic tests: 4/4 passed` (all four `[PASS] LogisticQuantizedInt8...`).
- Model output (10 bytes): -32 114 -38 52 50 127 -120 -128 -71 80, identical to the reference (every element within +-2, error 0). Invoke status `kTfLiteOk`.
- Lab1/Lab2 menu tests: `a` AXI aligned ALL PASS (32 checks), `b` AXI misaligned ALL PASS (6 checks), `c` Basic Convolution 3/3 PASS (1,065,895 cycles total), `d` Basic platform ALL PASS (32 checks), `e` SIMD MAC ALL PASS (8 checks). No FAIL string in the log.

Design: CUSTOM-0 funct3=5 (`npu_logistic.v`): funct7=0 sets zero point and range radius, funct7=1 sets multiplier and shift and builds a 256-entry int8 table (saturation, MultiplyByQuantizedMultiplier and the gemmlowp fixed-point sigmoid evaluated per table entry, bit-exact; `NPU_done` only after all 256 entries are written), funct7=2 returns 4 packed int8 outputs for 4 packed int8 inputs. `logistic.h` int8 `Logistic()` configures once per call and processes 4 elements per instruction, with single-element head/tail; timing boundaries and Counter 0 unchanged. iverilog `npu_logistic_tb`: 10,496 outputs (41 parameter sets x 256 inputs), 0 mismatches. Table-build cost per call is part of the measured Total.

Not done in this step: Transpose acceleration (Counter 1 unchanged, Starts 66 as in baseline), and the other experiment-mode rows.

## Memory-system micro-benchmarks (AXI burst read, AXI write, cbo)

Source: UART log `Platform/sw/results/lab4_bench.log`, captured by Claude with `make -C Platform run` on the Arty A7 (bitstream already programmed; the log shows `SYNC`, upload, `Jump to 0x60000000`, then the benchmark run from the temporary menu entry lab > `z`). The measurement code is preserved as text only in `Platform/sw/results/lab4_bench_source_snapshot.cc.txt` and has been removed from `Platform/sw/project` (`git diff -- Platform/sw/project` is empty). Timing is `csrr mcycle` before/after; back-to-back `mcycle` reads differ by 1 cycle (`mcycle_overhead=1`). Clock 50 MHz, build flags as in the SW baseline (`-O3`, `rv32im`).

### AXI burst read beats/cycle (NPU burst dot product, funct3=100)

Two N-byte vectors (cleaned out of the D-cache, DDR) are fetched by the engine, so beats = 2·N/4 (input + filter). Cycles include set-length + compute instruction.

| N bytes | beats | cycles (3 runs) |
|---:|---:|---|
| 64 | 32 | 94, 91, 91 |
| 256 | 128 | 188, 187, 187 |
| 1024 | 512 | 571, 572, 571 |
| 4096 | 2048 | 2113, 2114, 2114 |

- Slope 1024→4096 bytes: 1536 beats / (2114 − 571) cycles = **0.995 beats/cycle** (about 1 beat/cycle, the AXI 32-bit data limit).
- Slope 256→1024: 384 / 384 = 1.00 beat/cycle.
- Fixed overhead (intercept) ≈ 60 cycles; whole-run average at 4096 B: 2048/2114 = 0.969 beats/cycle.

### Single-word AXI write latency (CUSTOM-0 funct3=010)

`cfu_op2` to one aligned word, 8 runs: **38 cycles** every time (includes 1 cycle mcycle overhead). For reference, single-word AXI read (funct3=001): 52, 48, 48 cycles.

### cbo.clean / cbo.invalidate (unrolled 32 lines × 32 B, no loop, address immediates)

| Case | cycles per 32 lines (4 runs) | cycles per cbo |
|---|---|---:|
| cbo.clean, lines dirty | 1278, 1281, 1276, 1278 | **≈ 39.9** |
| cbo.clean, lines already clean | 566 (cold), 302, 372, 304 | ≈ 9.4 (steady, best/typical 302–304) |
| cbo.invalidate, lines resident | 515 (cold), 240, 240, 240 | **≈ 7.5** |
| cbo.invalidate, lines not resident | 574 (cold), 241, 241, 241 | ≈ 7.5 |

Per-cbo figures include the ~1–2 address-setup instructions the compiler emits per cbo (not subtracted). The first run of each case is slower due to cold instruction cache. The 372 outlier in the clean-clean case is recorded as measured, not explained.

### Notes
- The first attempt (one run) uploaded the program but printed nothing after the clear-screen escape; the `upload.py` session was killed and restarted, and the second run printed everything. The user did not need to press CPU RESET in the successful run (SYNC was received on start). Burst results show `res=0` because the buffers were zero; only timing was measured.

## Transpose-only acceleration (Transpose on NPU, Logistic on CPU)

Source: UART log `Platform/sw/results/lab4_transpose_only_npu.log`, captured by Claude (script `Platform/sw/results/board_run_lab4.py`: waits for `SYNC`, uploads `main.bin`, drives lab menu `l,t,a,b,c,d,e`, then main menu `t`). Bitstream `Platform/build/out.bit` (sha256 `35d7f5c8c31979cb968af1d94de70c037e08fab620a757c8f3dc01aaa15034e5`, built with `make -C Platform all_clean && make -C Platform prog`); post-route **WNS +0.227 ns**, WHS +0.011 ns, 0 failing endpoints (`build/reports/post_route_timing_summary.rpt`); utilization 32,832 LUTs, 16 RAMB36 + 39 RAMB18. SYNC arrived right after programming, so no CPU RESET press was needed. Software: `make -C Platform sw_clean && make -C Platform sw_build TFLM_SOFTWARE_CONV=1` with `integer_ops/logistic.h` temporarily set to the original upstream (CPU) version, so Logistic stays on the CPU; same model, zero input, 50 MHz and flags as the SW baseline above.

| Item | SW baseline (G1) | Transpose on NPU (Transpose-only) |
|---|---:|---:|
| Counter 1 (Transpose) Total | 7,042,050 | **461,371** |
| Counter 1 Starts / Average | 66 / 106,697 | 66 / 6,990 |
| Counter 0 (Logistic, CPU) Total / Starts | 844,295,109 / 37 | 820,973,388 / 37 |
| Invoke cycles | 6,533,448,017 | 6,504,622,157 |
| Operator speedup (Counter 1 Total ratio) | 1x | **15.26x** |
| Model speedup (Invoke ratio) | 1x | 1.0044x |

Counter 1 Total 461,371 is below the G1 baseline (7,042,050) and below 500,000 cycles. Checks in the same log: `Transpose tests: 14/14 passed`; model output (10 bytes) -32 114 -38 52 50 127 -120 -128 -71 80, identical to the software reference (error 0, within +-2); Invoke `kTfLiteOk`; lab menu `a` AXI aligned ALL PASS (32), `b` AXI misaligned ALL PASS (6), `c` Basic Convolution 3/3 PASS, `d` ALL PASS (32), `e` SIMD MAC ALL PASS (8), `Logistic tests: 4/4 passed`; no FAIL string in the log. (Counter 1 Starts = 66, same as the baseline; the model has 48 Transpose ops and 18 BatchMatMul ops, which is the likely source of the other 18, not verified.)

Design (two engines selected by the CPU, same CUSTOM-0 funct3=6):
- Burst engine (`hw/srcs/npu_transpose_fast.v`, funct7=5 selects it, funct7=6 starts without waiting, funct7=7 waits, funct7=4 starts and waits): for int8 tensors <= 16 KiB, word-aligned output, total % 4 == 0 and R = product of the k innermost output extents divisible by 4 (R <= 4096). The NPU (1) reads the input with AXI INCR bursts into two 4096x32 block-RAM replicas (4 read ports), (2) concurrently builds a table of input byte offsets for the R innermost output elements, (3) gathers 4 output bytes per cycle (`offset = rowbase + table[b]`, rowbase from an odometer over the outer dimensions) and (4) writes the packed words back with AXI INCR write bursts (16 words) while the gather is still running. The CPU never loads/stores a tensor element.
- Single-beat engine (`hw/srcs/npu_transpose.v`): unchanged fallback for everything else (any element size 1..255, ranks 1-6, unaligned bases, tensors > 16 KiB, R not divisible by 4); which engine each model transpose used is recorded per call in the table at the end of this file (all 66 used the burst engine); the unit tests and the testbench exercise both.
- `transpose.h`: cleans the input lines (cbo.clean), cleans only the boundary lines of an unaligned output, starts the engine asynchronously (funct7=6), invalidates the output lines while the NPU is running, then waits (funct7=7).
- Simulation: `hw/sim/npu_transpose_tb.sv` (AXI slave model now supports INCR bursts, random stalls 0-85%, 4 KB-boundary, WLAST and strobe checks), log `results/npu_transpose_tb.log`: **500/500 cases pass**, 0 failures, 0 protocol errors, 238 cases ran on the burst engine (incl. two 16 KiB model shapes), the rest on the single-beat engine; mutation checks (wrong table lane, wrong WLAST) make it fail. The other testbenches (`npu_logistic_tb`, `npu_burst_dot_product_tb`, misaligned AXI read/write) still pass.
- History: the earlier single-beat-only implementation measured Counter 1 Total 11,383,822 (slower than the CPU baseline); the first burst-engine bitstream (synchronous start, invalidate before and after) measured 519,845; overlapping the output invalidate with the NPU run gave 461,371.

## Both accelerated (Logistic on NPU + Transpose on NPU)

Source: UART log `Platform/sw/results/lab4_both_npu.log`, captured by Claude (script `Platform/sw/results/board_run_lab4.py ... ltabcde`: waits for `SYNC`, uploads `main.bin`, lab menu `l,t,a,b,c,d,e`, then main menu `t`). Bitstream `Platform/build/out.bit` (sha256 `fc6af308910b1755d26c6aede40b711014909614e4f81060b3564328d27322bb`, built 11:40 with `make -C Platform all_clean && make -C Platform prog` from the current `NPU.v` containing `npu_logistic`, `npu_transpose_fast` and `npu_transpose`). SYNC arrived right after programming (no CPU RESET press was needed in the successful run). Software: `make -C Platform sw_clean && make -C Platform sw_build TFLM_SOFTWARE_CONV=1` with the NPU versions of `integer_ops/logistic.h` and `reference/transpose.h`; same model, zero input, 50 MHz and flags as the SW baseline.

**Post-route timing of this bitstream** (`build/reports/post_route_timing_summary.rpt`, excerpt in `Platform/sw/results/lab4_both_post_route_timing_summary.txt`): **WNS +0.227 ns**, TNS 0.000, WHS +0.011 ns, 0 failing endpoints; "All user specified timing constraints are met."

| Item | SW baseline | Logistic-only | Transpose-only | Both |
|---|---:|---:|---:|---:|
| Counter 0 (Logistic) Total | 844,295,109 | 8,223,236 | 820,973,388 | **8,254,347** |
| Counter 1 (Transpose) Total | 7,042,050 | 7,035,336 | 461,371 | **461,530** |
| Starts (C0 / C1) | 37 / 66 | 37 / 66 | 37 / 66 | 37 / 66 |
| Invoke cycles | 6,533,448,017 | 5,697,410,972 | 6,504,622,157 | **5,691,554,991** (113,831 ms) |
| Logistic operator speedup (C0 Total ratio) | 1x | 102.67x | 1.03x | **102.28x** |
| Transpose operator speedup (C1 Total ratio) | 1x | 1.00x | 15.26x | **15.26x** |
| Model speedup (Invoke ratio) | 1x | 1.147x | 1.0044x | **1.148x** |

Checks in the same log: `Logistic tests: 4/4 passed`, `Transpose tests: 14/14 passed`, AXI aligned ALL PASS (32), misaligned ALL PASS (6), Basic Convolution 3/3 PASS, platform ALL PASS (32), SIMD MAC ALL PASS (8); no FAIL string; `AllocateTensors: kTfLiteOk`, `Invoke status: kTfLiteOk`; output (10 bytes) -32 114 -38 52 50 127 -120 -128 -71 80, identical to the reference.

Notes / failed attempts (kept in `Platform/sw/results/`): `lab4_both_attempt1_model_corrupt.log` (key args mistake; inference failed with `Unsupported data type 77 in tensor`) and `lab4_both_attempt2_hang_model_corrupt.log` (garbled model-info output, inference hung). Both showed the same DDR/model corruption as the earlier baseline attempts when the app was re-uploaded repeatedly on one programming session; after `all_clean && prog` the third run was correct. The cause is not identified.


## Per-call Transpose table (diagnostic log, taken on the 461,530-cycle `transpose.h`)

Source: `Platform/sw/results/lab4_transpose_diag_uart.log`, captured by Claude over UART (`board_run_lab4.py`; only the CPU RESET press was done by the user; Both-mode bitstream `build/out.bit`). A temporary diagnostic in `reference/transpose.h` / `app/tflm_runner.cc` (removed again, see `git diff`: no `DIAG` text is left in the tree) stored shape, perm, element size, engine choice, `k`/`R` and `mcycle` deltas per call and printed them after `Invoke`. All 66 calls (48 Transpose ops + 18 more calls, e.g. BatchMatMul internals) were recorded; **every call used the burst engine (66/66), none fell back to the single-beat engine**, so no per-call fallback reason is needed. Column meaning: `cycles` = value added to Counter 1 for that call; `clean` = cycles from call start until input/boundary cache cleaning finished (includes shape/stride maths); `cfg` = programming the NPU; `inv` = CPU output-line invalidation while the NPU runs; `wait` = remaining wait for the NPU. Diagnostic run total (Counter 1) = 451,352 (includes ~4 extra `mcycle` reads per call). Phase sums: clean 281,551 (62%), cfg 36,923, inv 78,257, wait 54,621. Input cleaning dominates because the previous CPU operator left the input dirty in the D-cache (about 44 cycles per dirty 32 B line vs about 9 for a clean line, compare calls 2-4 with call 5).

| # | rank | in shape | perm | elem B | bytes | engine | k / R | cycles | clean | cfg | inv (overlaps NPU) | wait |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 0 | 4 | 1x16x16x64 | 0,3,1,2 | 1 | 16384 | burst | 1 / 16 | 31153 | 21887 | 907 | 7602 | 757 |
| 1 | 6 | 1x64x8x2x8x2 | 0,3,5,2,4,1 | 1 | 16384 | burst | 1 / 64 | 30211 | 21258 | 641 | 3997 | 4315 |
| 2 | 5 | 1x4x64x4x8 | 0,1,3,4,2 | 1 | 8192 | burst | 1 / 64 | 16369 | 11348 | 806 | 3827 | 388 |
| 3 | 5 | 1x4x64x4x8 | 0,1,3,2,4 | 1 | 8192 | burst | 1 / 8 | 15415 | 10655 | 545 | 2018 | 2197 |
| 4 | 5 | 1x4x64x4x8 | 0,1,3,2,4 | 1 | 8192 | burst | 1 / 8 | 15311 | 10533 | 563 | 2018 | 2197 |
| 5 | 5 | 1x4x4x8x64 | 0,1,2,4,3 | 1 | 8192 | burst | 1 / 8 | 6918 | 2281 | 423 | 2024 | 2190 |
| 6 | 5 | 1x4x4x64x8 | 0,1,2,4,3 | 1 | 8192 | burst | 1 / 64 | 7196 | 2550 | 432 | 2018 | 2196 |
| 7 | 5 | 1x4x4x64x8 | 0,1,3,2,4 | 1 | 8192 | burst | 1 / 8 | 10436 | 5784 | 432 | 2018 | 2202 |
| 8 | 5 | 1x4x64x4x8 | 0,1,3,2,4 | 1 | 8192 | burst | 1 / 8 | 16332 | 11204 | 866 | 3874 | 388 |
| 9 | 5 | 1x4x64x4x8 | 0,1,3,4,2 | 1 | 8192 | burst | 1 / 64 | 15492 | 10728 | 548 | 2018 | 2198 |
| 10 | 5 | 1x4x4x8x64 | 0,1,2,4,3 | 1 | 8192 | burst | 1 / 8 | 6931 | 2247 | 468 | 2024 | 2192 |
| 11 | 5 | 1x4x64x4x8 | 0,1,3,2,4 | 1 | 8192 | burst | 1 / 8 | 15546 | 10813 | 517 | 3003 | 1213 |
| 12 | 5 | 1x4x4x64x8 | 0,1,2,4,3 | 1 | 8192 | burst | 1 / 64 | 6879 | 2242 | 422 | 2018 | 2197 |
| 13 | 5 | 1x4x4x64x8 | 0,1,3,2,4 | 1 | 8192 | burst | 1 / 8 | 10585 | 5938 | 432 | 2018 | 2197 |
| 14 | 6 | 1x2x2x8x8x64 | 0,5,3,1,4,2 | 1 | 16384 | burst | 2 / 16 | 30769 | 21449 | 963 | 7601 | 756 |
| 15 | 4 | 1x64x16x16 | 0,2,3,1 | 1 | 16384 | burst | 1 / 64 | 29590 | 20942 | 338 | 3997 | 4313 |
| 16 | 4 | 1x8x8x80 | 0,3,1,2 | 1 | 5120 | burst | 1 / 8 | 10618 | 7299 | 638 | 1274 | 1407 |
| 17 | 6 | 1x80x4x2x4x2 | 0,3,5,2,4,1 | 1 | 5120 | burst | 1 / 80 | 10025 | 6749 | 596 | 1269 | 1411 |
| 18 | 5 | 1x4x16x4x8 | 0,1,3,2,4 | 1 | 2048 | burst | 1 / 8 | 5513 | 3420 | 903 | 843 | 347 |
| 19 | 5 | 1x4x16x4x8 | 0,1,3,4,2 | 1 | 2048 | burst | 1 / 16 | 4594 | 2902 | 548 | 530 | 614 |
| 20 | 5 | 1x4x4x8x16 | 0,1,2,4,3 | 1 | 2048 | burst | 1 / 8 | 2369 | 760 | 467 | 536 | 606 |
| 21 | 5 | 1x4x16x4x8 | 0,1,3,2,4 | 1 | 2048 | burst | 1 / 8 | 4914 | 3254 | 516 | 803 | 341 |
| 22 | 5 | 1x4x4x16x8 | 0,1,2,4,3 | 1 | 2048 | burst | 1 / 16 | 2273 | 708 | 422 | 530 | 613 |
| 23 | 5 | 1x4x4x16x8 | 0,1,3,2,4 | 1 | 2048 | burst | 1 / 8 | 4319 | 2739 | 432 | 530 | 618 |
| 24 | 5 | 1x4x16x4x8 | 0,1,3,4,2 | 1 | 2048 | burst | 1 / 16 | 5513 | 3457 | 865 | 850 | 341 |
| 25 | 5 | 1x4x16x4x8 | 0,1,3,2,4 | 1 | 2048 | burst | 1 / 8 | 4627 | 2937 | 547 | 530 | 613 |
| 26 | 5 | 1x4x16x4x8 | 0,1,3,2,4 | 1 | 2048 | burst | 1 / 8 | 4513 | 2810 | 561 | 530 | 612 |
| 27 | 5 | 1x4x4x8x16 | 0,1,2,4,3 | 1 | 2048 | burst | 1 / 8 | 2283 | 714 | 423 | 536 | 610 |
| 28 | 5 | 1x4x4x16x8 | 0,1,2,4,3 | 1 | 2048 | burst | 1 / 16 | 2648 | 1074 | 432 | 530 | 612 |
| 29 | 5 | 1x4x4x16x8 | 0,1,3,2,4 | 1 | 2048 | burst | 1 / 8 | 4418 | 2843 | 432 | 530 | 613 |
| 30 | 5 | 1x4x16x4x8 | 0,1,3,2,4 | 1 | 2048 | burst | 1 / 8 | 5401 | 3345 | 857 | 858 | 341 |
| 31 | 5 | 1x4x16x4x8 | 0,1,3,4,2 | 1 | 2048 | burst | 1 / 16 | 4594 | 2907 | 544 | 530 | 613 |
| 32 | 5 | 1x4x4x8x16 | 0,1,2,4,3 | 1 | 2048 | burst | 1 / 8 | 2325 | 714 | 467 | 536 | 608 |
| 33 | 5 | 1x4x16x4x8 | 0,1,3,2,4 | 1 | 2048 | burst | 1 / 8 | 5000 | 3342 | 515 | 795 | 348 |
| 34 | 5 | 1x4x4x16x8 | 0,1,2,4,3 | 1 | 2048 | burst | 1 / 16 | 2274 | 708 | 422 | 530 | 614 |
| 35 | 5 | 1x4x4x16x8 | 0,1,3,2,4 | 1 | 2048 | burst | 1 / 8 | 4522 | 2942 | 432 | 530 | 618 |
| 36 | 5 | 1x4x16x4x8 | 0,1,3,2,4 | 1 | 2048 | burst | 1 / 8 | 5420 | 3420 | 809 | 850 | 341 |
| 37 | 5 | 1x4x16x4x8 | 0,1,3,4,2 | 1 | 2048 | burst | 1 / 16 | 4656 | 2969 | 544 | 530 | 613 |
| 38 | 5 | 1x4x4x8x16 | 0,1,2,4,3 | 1 | 2048 | burst | 1 / 8 | 2326 | 714 | 468 | 536 | 608 |
| 39 | 5 | 1x4x16x4x8 | 0,1,3,2,4 | 1 | 2048 | burst | 1 / 8 | 4914 | 3256 | 515 | 795 | 348 |
| 40 | 5 | 1x4x4x16x8 | 0,1,2,4,3 | 1 | 2048 | burst | 1 / 16 | 2273 | 708 | 422 | 530 | 613 |
| 41 | 5 | 1x4x4x16x8 | 0,1,3,2,4 | 1 | 2048 | burst | 1 / 8 | 4476 | 2901 | 432 | 530 | 613 |
| 42 | 6 | 1x2x2x4x4x80 | 0,5,3,1,4,2 | 1 | 5120 | burst | 2 / 8 | 11009 | 7313 | 968 | 2364 | 364 |
| 43 | 4 | 1x80x8x8 | 0,2,3,1 | 1 | 5120 | burst | 1 / 80 | 9725 | 6707 | 338 | 1269 | 1411 |
| 44 | 4 | 1x4x4x96 | 0,3,1,2 | 1 | 1536 | burst | 1 / 4 | 4130 | 2655 | 587 | 406 | 482 |
| 45 | 6 | 1x96x2x2x2x2 | 0,3,5,2,4,1 | 1 | 1536 | burst | 1 / 96 | 3660 | 2176 | 596 | 401 | 487 |
| 46 | 5 | 1x4x4x4x8 | 0,1,3,2,4 | 1 | 512 | burst | 1 / 8 | 2842 | 1514 | 904 | 246 | 178 |
| 47 | 5 | 1x4x4x4x8 | 0,1,3,4,2 | 1 | 512 | burst | 1 / 4 | 1922 | 1000 | 546 | 158 | 218 |
| 48 | 5 | 1x4x4x8x4 | 0,1,2,4,3 | 1 | 512 | burst | 1 / 8 | 1183 | 342 | 467 | 164 | 210 |
| 49 | 5 | 1x4x4x4x8 | 0,1,3,2,4 | 1 | 512 | burst | 1 / 8 | 2161 | 1272 | 515 | 249 | 125 |
| 50 | 5 | 1x4x4x4x8 | 0,1,2,4,3 | 1 | 512 | burst | 1 / 4 | 1132 | 336 | 422 | 158 | 216 |
| 51 | 5 | 1x4x4x4x8 | 0,1,3,2,4 | 1 | 512 | burst | 1 / 8 | 1776 | 969 | 432 | 158 | 217 |
| 52 | 5 | 1x4x4x4x8 | 0,1,3,2,4 | 1 | 512 | burst | 1 / 8 | 2741 | 1509 | 811 | 288 | 133 |
| 53 | 5 | 1x4x4x4x8 | 0,1,3,4,2 | 1 | 512 | burst | 1 / 4 | 1924 | 1002 | 545 | 158 | 219 |
| 54 | 5 | 1x4x4x8x4 | 0,1,2,4,3 | 1 | 512 | burst | 1 / 8 | 1230 | 388 | 468 | 164 | 210 |
| 55 | 5 | 1x4x4x4x8 | 0,1,3,2,4 | 1 | 512 | burst | 1 / 8 | 2218 | 1329 | 515 | 193 | 181 |
| 56 | 5 | 1x4x4x4x8 | 0,1,2,4,3 | 1 | 512 | burst | 1 / 4 | 1133 | 336 | 422 | 158 | 217 |
| 57 | 5 | 1x4x4x4x8 | 0,1,3,2,4 | 1 | 512 | burst | 1 / 8 | 1775 | 968 | 432 | 158 | 217 |
| 58 | 5 | 1x4x4x4x8 | 0,1,3,2,4 | 1 | 512 | burst | 1 / 8 | 2699 | 1467 | 809 | 289 | 134 |
| 59 | 5 | 1x4x4x4x8 | 0,1,3,4,2 | 1 | 512 | burst | 1 / 4 | 1922 | 1000 | 546 | 158 | 218 |
| 60 | 5 | 1x4x4x8x4 | 0,1,2,4,3 | 1 | 512 | burst | 1 / 8 | 1186 | 342 | 468 | 164 | 212 |
| 61 | 5 | 1x4x4x4x8 | 0,1,3,2,4 | 1 | 512 | burst | 1 / 8 | 2135 | 1245 | 515 | 193 | 182 |
| 62 | 5 | 1x4x4x4x8 | 0,1,2,4,3 | 1 | 512 | burst | 1 / 4 | 1132 | 336 | 422 | 158 | 216 |
| 63 | 5 | 1x4x4x4x8 | 0,1,3,2,4 | 1 | 512 | burst | 1 / 8 | 1780 | 973 | 432 | 158 | 217 |
| 64 | 6 | 1x2x2x2x2x96 | 0,5,3,1,4,2 | 1 | 1536 | burst | 2 / 4 | 4628 | 2780 | 913 | 598 | 337 |
| 65 | 4 | 1x96x4x4 | 0,2,3,1 | 1 | 1536 | burst | 1 / 96 | 3368 | 2141 | 338 | 401 | 488 |
| **sum** | | | | | | 66 burst / 0 single-beat | | **451352** | | | | |


## Both mode, final `transpose.h` (fixed-cost reduction)

Source: UART log `Platform/sw/results/lab4_both_final.log`, captured by Claude (`board_run_lab4.py lab4_both_final.log ltacbde`; `make -C Platform prog` of the unchanged `build/out.bit`, sha256 `fc6af308910b1755d26c6aede40b711014909614e4f81060b3564328d27322bb`, SYNC arrived after programming, no button press needed). Software: `make -C Platform sw_build TFLM_SOFTWARE_CONV=1` (same Conv mode and flags as the SW baseline and the earlier Both run: log line `Convolution path: software/reference`), no diagnostic code in the build. An earlier run `lab4_both_cand1.log` of the same code accidentally used the accelerated-conv build (Counter 1 435,743, Invoke 1,392,493,612 cycles); it is kept but not used for the comparison.

Why: the diagnostic table shows a fixed cost of roughly 0.7-0.9 kcycles per call that does not depend on the tensor size (cfg 420-900, boundary/stride maths and cleaning set-up 190-340): the Transpose code runs once per ~100 kcycles of other operators, so it executes from a cold I-cache and its code size (`Transpose<signed char>` was 1,976 bytes at -O3) dominates. Changes in `tflm_patches/.../reference/transpose.h` (hardware untouched):
- `Transpose<signed char>` shrinks from 1,976 to 1,056 bytes: one right-to-left loop over the output dimensions computes the byte deltas, writes the extent/delta registers and finds the burst parameters k and R (earlier: separate stride, eligibility and register loops); `total` comes from the input strides.
- Padded hardware dimensions (extent 1, delta 0) are written only when more of them are needed than the previous call left in place (`hw_pad_known()`, starts at 0 = nothing known, so the first call writes all of them); real dimensions are always written.
- `funct7=1` (element size, selects the single-beat engine) is only issued on the single-beat path.
- The output invalidate loop is a plain one-line loop (it runs while the NPU is busy and each line takes less time than the NPU needs per line); the single-beat path (`PrepareOutputSlow`) is out of line.
- A shadow-register variant (skip writes of unchanged registers) was tried first and was not better (463,670 with the diagnostic code in, 465,562 without: `diag2.log`, `lab4_both_opt_npu.log`) because the extra code costs more cold-cache misses than the saved register writes.

| Item | Both, before | Both, final |
|---|---:|---:|
| Counter 0 (Logistic) Total | 8,254,347 | 8,259,105 |
| Counter 1 (Transpose) Total | 461,530 | **434,504** (Starts 66) |
| Transpose operator speedup vs SW baseline (7,042,050) | 15.26x | **16.21x** |
| Invoke cycles | 5,691,554,991 | 5,691,460,558 (113,829 ms) |

Checks in the same log (`lab4_both_final.log`): `Logistic tests: 4/4 passed`, **`Transpose tests: 14/14 passed`**, AXI aligned ALL PASS (32), misaligned ALL PASS (6), Basic Convolution PASS, platform ALL PASS (32), SIMD MAC ALL PASS (8), `AllocateTensors: kTfLiteOk`, `Invoke status: kTfLiteOk`. Model output (10 bytes): -32 114 -38 52 50 127 -120 -128 -71 80, identical to the reference output of the software baseline, so **all 10 outputs are within +-2 (error 0)**.
Other gates: `hw/sim/npu_transpose_tb.sv` re-run on the unchanged RTL (`iverilog -g2012 ... hw/srcs/NPU.v hw/srcs/npu_*.v`), `results/npu_transpose_tb.log`: **PASS (500/500)**, 0 failing cases, 0 protocol errors. Post-route timing of the (unchanged) bitstream: **WNS +0.227 ns** (section above, same sha256).


## Both mode, read watermark (input cleaning overlapped with the NPU fetch)

Idea: the Transpose cost is dominated by cleaning the input out of the D-cache (62% in the diagnostic table), while the NPU waited for a fully clean input before it started to fetch it. The burst engine now has a **read watermark** (`hw/srcs/npu_transpose_fast.v`, CUSTOM-0 funct3=6 funct7=8, rs1 = end address of the input bytes already cleaned): the engine is started first (funct7=6), builds its offset table, and issues AXI AR requests only for input words below the watermark (`ar_len` is clipped to `wm_avail = watermark_words - words_requested`, no AR is issued when `wm_avail` is 0; the watermark is cleared when a run completes). `transpose.h` (fast path) does: boundary-line clean of the output, configure, start, then `cbo.clean` of the input in **1 KB chunks**, writing the watermark after each chunk (the NPU fetches chunk i while the CPU cleans chunk i+1), then invalidates the output lines while the NPU gathers/writes, then waits (funct7=7). The single-beat engine path is unchanged (cleans the whole input first, no watermark).

Simulation (`hw/sim/npu_transpose_tb.sv`, `iverilog -g2012 -s npu_transpose_tb hw/sim/npu_transpose_tb.sv hw/srcs/NPU.v hw/srcs/npu_*.v`): the slave model tracks the watermark last written by the testbench "CPU" and counts a violation for every AR that ends beyond it (and returns 0xDEADBEEF for any word beyond it). Burst-engine cases use a synchronous start with the watermark preset to the end of the input, or an asynchronous start with watermark chunks of random size (random pauses up to 40/300 cycles) or 1 KB. Log `results/npu_transpose_tb.log`: **PASS (500/500)**, 0 failing cases, 0 protocol errors, **0 AR-beyond-watermark violations**, 404 watermark writes, 222 burst-engine cases. Mutation (`-DNPU_TP_NO_WM`, watermark check removed from the RTL): `results/npu_transpose_tb_mutation_no_watermark.log` **FAIL** (305 AR-beyond-watermark violations, 204 failing cases). `npu_logistic_tb`, `npu_burst_dot_product_tb`, `npu_misaligned_axi_read_tb`, `npu_misaligned_axi_write_tb` still pass.

Board: `make -C Platform all_clean && make -C Platform prog` (bitstream sha256 `00a2fa842f712b3fa1f40063bfc170fa56042a44598293058b2d276e8a32b32c`), software `make -C Platform sw_build TFLM_SOFTWARE_CONV=1` (same flags and Conv mode as before), UART log `Platform/sw/results/lab4_both_wm.log` captured by Claude (`board_run_lab4.py lab4_both_wm.log ltacbde`; SYNC arrived after programming, no button press needed). Post-route (`results/lab4_both_wm_post_route_timing_summary.rpt`): **WNS +0.267 ns**, WHS +0.011 ns, 0 failing endpoints.

| Item | Both, previous final (G10 value, `lab4_both_final.log`) | Both, watermark (`lab4_both_wm.log`) |
|---|---:|---:|
| Counter 0 (Logistic) Total | 8,259,105 | 8,257,055 |
| Counter 1 (Transpose) Total (Starts 66) | 434,504 | **393,327** |
| Transpose operator speedup vs SW baseline (7,042,050) | 16.21x | **17.90x** |
| Invoke cycles | 5,691,460,558 | 5,692,964,147 (113,859 ms) |

Checks in the same log: `Logistic tests: 4/4 passed`, **`Transpose tests: 14/14 passed`**, AXI aligned ALL PASS (32), misaligned ALL PASS (6), platform ALL PASS (32), `AllocateTensors: kTfLiteOk`, `Invoke status: kTfLiteOk`, no FAIL string. Model output (10 bytes) -32 114 -38 52 50 127 -120 -128 -71 80, identical to the software reference (all 10 within +-2, error 0). ("G10 value" is taken as the previous best Both-mode Counter 1 Total, 434,504; the plan document defines goals G0-G9 only.)


## Final summary (four modes)

All four rows come from UART logs captured by Claude in `Platform/sw/results/` (the user only pressed CPU RESET when needed; the most recent runs needed no button press). Operator speedup = SW baseline Counter Total / mode Counter Total (Totals table printed in the log); model speedup = SW baseline Invoke cycles / mode Invoke cycles (`Cycles:` line). Logs: `lab4_sw_baseline.log`, `lab4_logistic_npu.log`, `lab4_transpose_only_npu.log`, `lab4_both_wm.log`.

| Mode | Logistic Total (C0) | Transpose Total (C1) | Invoke cycles | Logistic op. speedup | Transpose op. speedup | Model speedup |
|---|---:|---:|---:|---:|---:|---:|
| SW baseline | 844,295,109 | 7,042,050 | 6,533,448,017 | 1x | 1x | 1x |
| Logistic-only | 8,223,236 | 7,035,336 | 5,697,410,972 | 102.67x | 1.00x | 1.147x |
| Transpose-only | 820,973,388 | 461,371 | 6,504,622,157 | 1.03x | 15.26x | 1.0044x |
| Both (final, `lab4_both_wm.log`) | 8,257,055 | 393,327 | 5,692,964,147 | 102.25x | 17.90x | 1.148x |

Final post-route timing of the bitstream that produced the Both row (`build/out.bit`, sha256 `00a2fa84...32b32c`): `Platform/sw/results/lab4_both_wm_post_route_timing_summary.rpt`, Design Timing Summary: **WNS +0.267 ns** (>= 0), TNS 0.000, WHS +0.011 ns, 0 failing endpoints.
