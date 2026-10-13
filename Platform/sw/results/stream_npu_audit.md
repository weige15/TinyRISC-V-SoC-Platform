# Streaming NPU: completion audit (2026-10-13)

## Objective / concrete deliverables

1. Fetch both operands using maximal legal 32-bit INCR bursts (256-beat cap,
   4-KiB splits, vector-end tails), with overlapping ptr2 address issuance.
2. Consume arriving beats without master bubbles; publish result and NPU_done
   together no later than two cycles after the final RLAST.
3. Preserve Goal 1 arithmetic, alignment, protocol, error/drain, command-pulse,
   and back-to-back behavior.
4. Report start-to-done latency for N=1,3,64,256,300, all 4x4 alignments, both
   zero-wait and random stalls; no failures and N=300 zero-wait <=170 cycles.
5. Preserve the documented Lab 2 GATE, including actual board acceptance,
   host convolution coverage, resource limits and non-negative routed WNS.
6. Add a lower five-label average to `Platform/sw/lab2_latency.md`.

**Final outcome: all six deliverables verified.** Detailed evidence is under
[`stream_npu/`](stream_npu/); reproducible checks are below. GATE means the
repository's documented Goals 1/3/4/5/6 checks, as in the preceding
`mac_minimal_audit.md`; there is no separate executable target called GATE.
No `make validate` result is claimed.

## Prompt-to-artifact checklist

| Requirement | Inspected implementation and actual evidence | Result |
|---|---|---|
| Both operands fetched from AXI, maximal bursts | `hw/srcs/npu_burst_dot_product.v`: independent input/filter cursors and `burst_size = min(words_left, MAX_BURST_BEATS, words_to_4KiB)`, default limit 256. Buffer credits delay scheduling, never shorten a burst. `npu_lab2_tb.sv` compares every ARADDR/ARLEN to independently enumerated maximal covering spans. No chunk-edge rereads. Four seed logs include 1,568–1,583 full 256-beat bursts each, directed page/window edges and long/ring-wrap vectors. | PASS |
| ptr2 address overlaps ptr1 data | Two-entry in-order descriptor FIFO; next request prepared on the first AR handshake, not after RLAST. All 768 latency records assert ARVALID offer overlap, including random AR stalls. Zero-wait records additionally assert handshake overlap. A one-beat input overlaps ptr2 AR on its single R beat. | PASS |
| Beat-rate streaming, no operand seam bubbles | `m_axi_rready` stays asserted for outstanding responses; raw input RAM write and filter MAC enable use the current `RVALID && RREADY`. Every arriving R beat is checked for no master stall; all 448 zero-wait measurements across four seeds have `gaps=0`, including 4-KiB and 256-beat transitions at N=300/8193. | PASS |
| Arrival-cycle MAC / result and done <=last RLAST+2 | Products use current RDATA and asynchronous input RAM lanes, followed by a single registered lane sum. Engine retires that sum at last+1; `NPU.v` publishes result and done together at last+2, bypassing STATE_DONE for COMPUTE. All 768 latency records have tail=2. Source inspection confirms no input-word staging or realignment-flush state. | PASS |
| N=1,3,64,256,300 x all 16 alignments x both modes | First 160 measurements per seed are exactly the required Cartesian product. Four independent seeds; individual stdout plus `latency.csv` (768 rows including boundary/long extensions). | PASS |
| N=300 <=ceil(300/4)*2+20 | 153 cycles aligned, 154 with one unaligned operand, 155 with both unaligned. Max 155 <170; page splits also add no bubbles. Formula B+3 and every fixed edge explained in `lab2_latency.md`. | PASS |
| Goal 1 arithmetic / independent alignment / tails | Byte-wise signed reference; N=1..256 x 4x4; N=257..1024 sweep; all alignments at 1021..1025, 2047..2049,4097; repeated circular-RAM wrap at 16385; offset extremes; random memory and placements; zero length; top/bottom legal window edges. Legacy burst bench adds signed extreme products and shared AXI/SIMD commands. | PASS |
| Goal 1 AXI protocol | Exact address/length sequence, 4-byte alignment, address-window bounds, 4-KiB bounds, ARSIZE/ARBURST, AR stability through stalls, RVALID gating with garbage during invalid cycles, no AXI writes. Legacy bench retains explicit receiver-stall/slave-hold checks by injecting RREADY stalls (production RTL intentionally no longer inserts any). | PASS |
| Goal 1 errors with overlapping requests | Early RLAST, missing RLAST with extra beats, SLVERR/DECERR on either operand, plus errors after multiple 256-beat bursts. Bad and subsequent beats cannot write storage/MAC. Held ARVALID is not cancelled; all accepted/pending requests drain through actual RLAST before done. New AR issuance after error is rejected except the already held request. Per seed: 63–71 errors with prefetched AR, 2–6 with held AR. Follow-up successful commands verify recovery/status clearing. | PASS |
| Exactly one done / back-to-back / latched arguments | Per seed: 5,803 COMPUTEs, 17,409 commands, 17,408 back-to-back commands. Start/done accounting and idle/write monitors run continuously. CPU arguments are randomized immediately after the start edge. | PASS |
| Testbench 0 failures | Four final-source runs: seed 20261007 PASS=6528781; seed 7 PASS=6675529; seed 314511048 PASS=6647872; seed 20261013 PASS=6487589; all FAIL=0. `rtl_suite.log`, `sim_*.log`; fatal nonzero exit on failure/timeout. | PASS |
| Test coverage is sensitive to violations | `check_stream_mutations.py` uses the same scoreboard on disposable RTL copies. Unmodified control passes; serial AR, 128-beat cap, extra done cycle, ignored RVALID, writes after error, and wrong alignment each fail. `mutations.log` and six individual diagnostic logs. No production source is mutated. | PASS |
| Legacy functions preserved | 366 burst/SIMD/shared-read checks; separate aligned/misaligned AXI read and write suites all pass. Complete NPU port list, active-low reset, SET/COMPUTE/STATUS encoding and software ABI retained. These are RTL results, not claims of unavailable Lab 1 board menu entries. | PASS |
| Goal 3 real board set/random | `board_uart.log`: Pass 3/3 and Pass 100/100 with the final newly programmed bitstream and ordinary always-clean API. | PASS |
| Goal 4 host convolution / hardware product coverage | `host.log`: 2545/2545 cases, 1,157,263 outputs, 0 mismatches, 0 product-count and call-pattern failures. Existing convolution/API implementation unchanged by this work. | PASS |
| Goal 5 board basic convolution / model | `board_uart.log`: Testcases 1–3 Output Correct; labels 0,1,6,8,11 each have 12 matching raw Actual/Golden words (60 pairs independently checked), and all golden statuses pass. | PASS |
| Goal 5 latency and lower new row | Board total 7,038,923,034; average 1,407,784,606.8 < previous 1,470,259,856 (4.25% lower), and <80% of Goal 5 baseline 4,157,256,607. `lab2_latency.md` row 4 has the rounded average 1,407,784,607. | PASS |
| Goal 6 resources / part / one recursive NPU | Final routed `post_route_utilization_npu.rpt`: xc7a100tcsg324-1, exactly one selected cell `MMIO_i/NPU_0/inst` in build log. Recursive totals: LUT 3090<=20000, FF 685<=5000, DSP 4<=30, RAMB18 0<=270, RAMB36 0<=135. The report's repeated aggregate `inst` rows are not separate selected NPU instances. | PASS |
| Goal 6 overall WNS | Full final report archived losslessly as `post_route_timing_summary.rpt.gz`: WNS +0.187 ns, TNS 0, zero failing setup endpoints; all user timing constraints met. CPU/NPU remains 20 ns / 50 MHz; no constraints/clock changes. | PASS |
| Actual hardware, not a build proxy | FTDI 0403:6010 and /dev/ttyUSB1 visible; Vivado sees target 210319BE7776A / xc7a100t_0; final build/program reports startup HIGH; UART capture contains listener, bootloader SYNC, uploaded application/menu, and all actual test output. `board_preflight.log`, `hw_build.log`, `board_uart.log`. | PASS |
| Current source / tested image provenance | `source_sha256.txt` matches current RTL and all four testbench sources. `board_image_sha256.txt` matches current out.bit/main.bin. All hardware sources predate final out.bit. Firmware is byte-for-byte identical to row 3, with no operator profiler; normal -O3 build and check-env pass. | PASS |

## Fixed latency and implementation boundaries

The measured operation is the COMPUTE instruction (N and offset already set),
not software cache maintenance or SET/STATUS overhead. For B raw covering words
across both operands, zero-wait completion is B+3 cycles: AR at edge 1, data at
edges 2..B+1, final sum at B+2, public result/done at B+3. There is no hidden
per-burst or alignment flush cost. The zero-wait slave accepts an AR each cycle
and can return the next burst immediately after the preceding RLAST. Random
stalls are independent ARREADY/RVALID probabilities, not master throttling.

Raw input words use a circular 1024-word distributed RAM with two read ports.
Filter lanes select the corresponding bytes from a pair of raw input words;
invalid leading/trailing filter lanes contribute zero. Credits retain the
preceding input word and prevent reuse before consumption. The two outstanding
requests share one ordered response stream; this implementation does not claim
to support reordering different AXI IDs. Buffer size must be a power of two and
at least 2*MAX_BURST_BEATS+2, checked at elaboration.

Only `NPU.v` and the helper engine are functional RTL changes. The pre-existing
software optimizations and model bytes were preserved. The incidental Vivado
XCI simulation-metadata regeneration was restored; no clock/XDC/bus topology
change was used to pass the gate.

## Timing iterations (no waived limits)

The initial implementation routed at +0.150 ns. Moving descriptor writes out
of the asynchronous-reset control block removed synthesis set/reset warnings,
but that build routed at **-0.004 ns**. Its successful board run was **not**
accepted as GATE evidence and is not the retained latency row.

The final RTL simplifies the critical scheduler calculation algebraically:
for a nonfinal filter burst ending at raw word F, required input words are
`F + (input_low > filter_low)`; a final burst requires all input requests to
have been scheduled. This removes byte subtraction/clamping/conversion carry
chains, without changing the AR sequence or cycle counts. A third complete
`make -C Platform prog` rebuilt/routed/programmed this RTL, producing the final
+0.187 ns report. RTL, negative controls and the board suite were rerun on it.
Intermediate logs/bitstreams remain under `~/NNchip/scratch/stream_npu/` only.

## Reproduce / inspect

From the repository root, with the project environment sourced:

```sh
bash Platform/hw/sim/run_lab2_stream_tests.sh /tmp/lab2-stream-tests
python3 Platform/hw/sim/check_stream_mutations.py /tmp/lab2-stream-mutations
~/NNchip/scratch/conv_host_test/build_and_run.sh
make -C Platform sw_build
make -C Platform/sw check-env
make -C Platform prog
make -C Platform run
# Wait for Listening; CPU RESET if needed, then menu: l, t, r, c, x, t.
python3 Platform/sw/results/stream_npu/verify.py
```

The saved `stream_npu/board_driver.sh` records the actual automated board menu
sequence and private uploader-server workaround for root-owned /tmp files.
It uses `make -C Platform -o kill_server run` after initializing its private
server, so the run target does not kill that server. It waits for SYNC/menu
rather than treating USB/JTAG/programming as application verification.

Tested image SHA-256:

- out.bit: `53e252fa71279178feb44c01dffa9459e029a9805923f2daa34aeecb8771e6b9`
- main.bin: `946f27f2a535d70db426980d4ff2cf0514a35f9c16aeb5030d46198aac07e79b`

`verify.py` independently checks matrix coverage, every latency row, raw board
golden words and totals, resource/timing limits, the lower ranking row, source
hashes and current tested images. It does not substitute a manifest or green
summary for the source/coverage inspection above. Final audit found no remaining
unverified requirement within the documented goal/GATE scope.
