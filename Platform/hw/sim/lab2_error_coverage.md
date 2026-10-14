# Lab 2 error/drain contract — completion audit

## Deliverables and reproduction

The requested deliverable is RTL-simulation evidence for every listed response/
RLAST case on **ptr1 and ptr2 separately**, with random RVALID stalls, complete
error draining, exactly one done pulse, no new AR after detection, no operand
write past B, and exact fresh-data recovery after every injected error.

Implemented in `npu_lab2_tb.sv`; no production RTL changes were needed. The
pre-existing length, latency, random-error, reuse and filter-cache tests remain.
The directed matrix runs first in the full bench, or alone with `+errors_only`.

From the `TinyRISC-V-SoC-Platform` repository root:

```sh
FULL=1 bash Platform/hw/sim/run_lab2_error_tests.sh /tmp/lab2-error-tests
```

Without `FULL=1`, the runner still runs the entire requested matrix under
four-state Icarus with four seeds, strict production-RTL lint, both passing
mutation controls, and all 14 rejecting mutation controls. `FULL=1` additionally
builds and runs the complete existing bench with Verilator. Any failed assertion,
missing coverage, timeout, unexpected mutation result, or log audit exits nonzero.

Retained text evidence is in `Platform/sw/results/lab2_error_coverage/` (called
`results/` below). Binaries and temporary mutant RTL stay outside the repository.
`results/source_sha256.txt` identifies the tested RTL, bench, runner and verifiers;
check it from `Platform/hw`:

```sh
cd Platform/hw
sha256sum -c ../sw/results/lab2_error_coverage/source_sha256.txt
python3 sim/verify_lab2_error_log.py ../sw/results/lab2_error_coverage/errors_*.log
```

## Injection checklist (beat numbers here are one-based)

`run_error_matrix` runs **2 operands × 8 cases × 2 burst lengths × 2 AR profiles
= 64 named cases**, including 56 errors and eight successful correct-RLAST
controls. B is 16 or 256. Names are
`ptr{1,2}/<case>/B{16,256}/{accepted-other,held-other}`.

| Prompt item | Case name | Actual injected handshake | Expected status |
|---|---|---|---|
| (a) SLVERR first | `slverr-first` | RRESP=2 on beat 1; RLAST on B | 4 |
| (b) SLVERR mid-burst | `slverr-middle` | RRESP=2 on beat B/2+1; RLAST on B | 4 |
| (c) SLVERR last | `slverr-last` | RRESP=2 with RLAST on beat B | 4 |
| (d) DECERR mid-burst | `decerr-middle` | RRESP=3 on beat B/2+1; RLAST on B | 4 |
| (e) Early RLAST | `early-rlast` | RRESP=0; RLAST on beat B/2 | 1 |
| (f) Correct RLAST | `correct-rlast` | RRESP=0; RLAST on beat B | 0; exact result |
| (g) Missing RLAST, +1 | `rlast-late-1` | No RLAST at B; actual RLAST on B+1 | 2 |
| (g) Missing RLAST, +5 | `rlast-late-5` | No RLAST at B; actual RLAST on B+5 | 2 |

**Evidence for every row:** all four `results/errors_<seed>.log` files contain
all 64 distinct `ERROR_CASE ... PASS` lines. `watch_tick` checks RRESP and RLAST
positions on the actual accepted beats, and `watch_finish` checks the affected
burst and detection beat. Configuration alone does not earn coverage. The eight
8-bit `error_coverage` masks must all be `ff`; a bit is set only after the case
AND its recovery (if an error) have passed.

## Behavioral checklist and non-vacuity

| Explicit requirement | Concrete checker/stimulus in `npu_lab2_tb.sv` | Inspected evidence / negative control |
|---|---|---|
| Random RVALID stalls for every case | Slave draws RVALID with a per-command 25–65% send rate; each monitored burst waits for at least one genuinely random stall draw. Invalid-cycle data/RRESP/RLAST are garbage. `watch_finish` requires target `ew_random_stalls > 0`. | Every case log reports a positive `random_stalls`; four seeds. `ignore-rvalid` is rejected by the independent drain accounting. |
| RREADY usable; every beat accepted through actual RVALID && RREADY && RLAST | `watch_tick` requires RREADY high on **every** cycle with an accepted outstanding AR, including RVALID bubbles. An independent FIFO counts only external AR/R handshakes, closes a descriptor only on accepted RLAST, and checks target totals. | SLVERR/DECERR accept B beats; early accepts B/2; late cases accept B+1/B+5. `drop-rready-on-error` rejected. |
| NPU_done never precedes affected handshake | Done monitor samples after the rising-edge NBAs, before the command driver's return, and requires `ew_target_last_cycle >= 0`. No DUT status/counter decides that RLAST occurred. | `done-before-affected-rlast` rejected by this exact assertion. |
| Exactly one one-cycle done, then low | Count every post-NBA high sample; require exactly one. `watch_finish` observes 32 idle clocks **before STATUS or any next command**; the global done monitor continues through subsequent commands/idle and checks command accounting. | Both `sticky-error-done` and an eight-clock `delayed-second-done` are rejected. As with any finite simulation, the idle guarantee is over the observed interval, not a formal infinite-time proof. |
| No new AR after error detection | Detection comes from external handshakes. Every AR **offer**, not just ARREADY handshakes, is prohibited after detection except an immutable offer already pending on that edge. The one pending offer may handshake once; no later offer is permitted. | `new-unaccepted-ar-after-error` rejected with **ARREADY=0**. N=4B+64 leaves additional work, and the test asserts there was future AR work to suppress. |
| Every other already-requested burst drains before done | `accepted-other` delays the target's first R until another AR is accepted, including SLVERR-first. For ptr1 the other request is ptr2; for ptr2 it is the next ptr1 burst. `held-other` instead holds that next offer through error detection and releases it afterward. Every error checks the intended outstanding/held condition, and done requires all independent descriptors closed and no held AR. | All 56 error rows report `other=1`. `done-before-other-rlast` is rejected independently of the affected-RLAST assertion. |
| No local operand storage write after B | Write enables are checked throughout discard/stalls. After B without RLAST, `guard_input_ram` and `guard_operand_banks` snapshot and compare **all** input RAM, all eight input replicas and all eight filter-cache banks across each clock, including the late-RLAST clock. The cache is armed before each primary case to exercise ptr2 storage. Late cases require actual tail beats, actual guard cycles, and prior valid RAM writes. | `input-write-past-b`, `replica-write-past-b`, `filter-write-past-b` each bypass the real RAM write gate **without changing the monitored enable wires**; all are rejected by physical-array comparisons. `write-after-error` also rejected. |
| Do not check error NPU_out | `run_case` compares COMPUTE output only for INJ_NONE. STATUS is a separate custom command and is still checked. | Four-state `dont-care-error-result` control forces **32'hxxxxxxxx** for every error COMPUTE; all 64 cases and 56 recoveries still pass. |
| Normal command with fresh data after **each** error, exact result, no stale beats | After every error, change every byte of both disjoint operands using nonzero XORs. Reuse identical pointers, N and offset; require a changed reference. No reset, re-arm, disarm, or slave-FIFO clearing occurs between error and recovery. `run_case` requires the complete normal AR sequence, exact signed reference result, status=0, and an empty bus. | All 56 distinct `RECOVERY ... PASS exact=... fresh_bytes=...` rows. `stale-operands-after-error` and `wrong-recovery-result` rejected. |
| Print each case PASS and total 0 failures | PASS printing is conditional on unchanged failure count through all checks and recovery. Matrix masks, case/recovery totals, final command accounting and nonzero simulator exit on any failure are independent gates. | `verify_lab2_error_log.py` checks the complete name set (not just totals), beat/AR/tail counts, stalls, all recovery names and final zero failures. Six altered-log controls, including a green-summary-only log, were rejected (`results/log_verifier_controls.log`). |

An ARVALID already offered before detection cannot legally be cancelled under
AXI. Finishing that old held request is **not** a new request; both the immutable
hold rule and draining its response are asserted. This is why both AR profiles
are present instead of banning every post-error AR handshake.

## Actual verified results

Command above was run with `FULL=1`, using the versions in `results/tools.txt`:
Icarus 12.0, Verilator 5.020, Python 3.12.3.

| Run | Named matrix cases | Exact recoveries | Failures |
|---|---:|---:|---:|
| Icarus seed 20261007 | 64/64 | 56/56 | 0 |
| Icarus seed 7 | 64/64 | 56/56 | 0 |
| Icarus seed 314511048 | 64/64 | 56/56 | 0 |
| Icarus seed 20261013 | 64/64 | 56/56 | 0 |
| Verilator full regression, seed 20261007 | 64/64 | 56/56 | 0 (45,954 computes overall) |

The final focused summary in each Icarus log is:

```text
ERROR_COVERAGE: cases=64/64 recoveries=56/56 masks=ff,ff,ff,ff,ff,ff,ff,ff
ERROR_RESULT: cases=64 recoveries=56 failures=0
```

`results/mutations.log` and the individual `results/mutations/*.log` show:

```text
ERROR MUTATION RESULT: controls=2 rejected=14 survived=0
```

Strict production-RTL lint passed (`results/lint.log` is empty). Icarus's only
build warning is the existing combinational sensitivity to the `fprod` array.
The complete regression retained its 304-length, 16-alignment, five-offset,
window-end and signed-overflow coverage gates, plus latency/reuse/cache tests.
Source hashes were rechecked against the current files after the run.

**Audit outcome:** all requested error-testbench requirements have direct
stimulus, assertions, non-vacuity gates and observed passing evidence. No required
item remains unverified. These are RTL simulation results, not FPGA results.
