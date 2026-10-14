# Lab 2 verification — TA Q&A crosswalk (blocked)

## Objective and current status

Deliverable: list **every individual checklist item** in the TA Q&A notes,
sections **1.1, 1.2, 1.3, 1.4, 2.1, 2.2, 2.3 and 3**, with its covering V-goal,
PASS/FAIL verdict, and a named test with counts or an exact UART log line.
Keep the hidden-test N-range question OPEN; print the finished file with no
FAIL rows. Work is limited to five continuation turns.

**Not complete: the original TA Q&A notes were not supplied or located.**
The repository, assignment documents, existing verification audits, and
available same-project conversation text were searched. The V-goal objectives and evidence were found,
but not the numbered TA checklist. `assignments/lab2/lab_2.md` is the assignment,
not those notes; its headings do not supply the requested section mapping.
Inventing section titles or equating green tests with complete checklist
coverage would not satisfy the objective.

**Next input needed:** paste the notes for the eight sections, or supply their
file path. Then expand the source-coverage rows below into one row per original
checklist item, retaining its numbering and wording, and audit the evidence for
each before changing its verdict.

All evidence paths below are relative to the NNchip parent repository.
`P/` abbreviates `TinyRISC-V-SoC-Platform/`.

## Required TA-source coverage

These are eight unresolved **source-coverage gates**, not reconstructed TA
checklist items and not observed hardware failures. A V-goal cannot be assigned
reliably until the corresponding original items are available.

| TA section | Checklist items | Covering V-goal | Verdict | Evidence / blocker |
|---|---|---|---|---|
| 1.1 | Original text required | Unassigned | FAIL | Section text not found; item enumeration and coverage cannot be verified. |
| 1.2 | Original text required | Unassigned | FAIL | Section text not found; item enumeration and coverage cannot be verified. |
| 1.3 | Original text required | Unassigned | FAIL | Section text not found; item enumeration and coverage cannot be verified. |
| 1.4 | Original text required | Unassigned | FAIL | Section text not found; item enumeration and coverage cannot be verified. |
| 2.1 | Original text required | Unassigned | FAIL | Section text not found; item enumeration and coverage cannot be verified. |
| 2.2 | Original text required | Unassigned | FAIL | Section text not found; item enumeration and coverage cannot be verified. |
| 2.3 | Original text required | Unassigned | FAIL | Section text not found; item enumeration and coverage cannot be verified. |
| 3 | Original text required | Unassigned | FAIL | Section text not found; item enumeration and coverage cannot be verified. |

## V-goal evidence index

This index preserves completed work for the eventual crosswalk. Its scope is
**observed test results**, not a claim that all absent TA checklist items pass.

| V-goal | Verification subject | Existing detailed audit |
|---|---|---|
| V1 | Lengths, independent alignments, signed offsets, boundaries, counter widths and split/unsplit results | `P/Platform/hw/sim/lab2_length_coverage.md`; current host/counter revalidation below |
| V2 | RRESP/RLAST errors, draining, done pulse and fresh-data recovery | `P/Platform/hw/sim/lab2_error_coverage.md` |
| V3 | +128 offset path, no int8 narrowing, conv/plain-call alternation | Current V3/V5 revalidation below; `P/Platform/hw/sim/offset9_audit.md` and later real-entry routing update in V4 |
| V4 | Sole legacy C MAC definition, all convolution product paths, global-state cleanup | Current-source revalidation below; historical detail in `scratch/mac_call_audit/routed/AUDIT.md` |
| V5 | AXI byte provenance, reuse invalidation, changed-memory/arena reuse | `P/Platform/hw/sim/reuse_provenance_audit.md`; current two-layer host revalidation below |
| V6 | Single-boot FPGA set/random/edge/conv/model sequence | `demo/V6/AUDIT.md` and `demo/V6/uart.log` |
| V7 | Laptop regression, five waveform examples, saved UART/reports, explanation notes | `demo/AUDIT.md`, `demo/run.sh`, `demo/NOTES.md` |

### Rechecked saved evidence (2026-10-14)

The saved demo's **22/22 source hashes match current files**. This was a
comparison against the existing `demo/out/source_sha256.json`, not regeneration
of a manifest to hide differences. The verifier source, relevant testbench
stimulus/oracle/coverage code, current API and convolution entry path, and the
cited logs were inspected. These commands rechecked the existing artifacts:

```sh
python3 demo/verify.py archive
python3 demo/verify.py rtl
python3 demo/verify.py host
python3 demo/verify.py waves
```

All four exited zero. This saved-evidence recheck did not execute a new
simulation, host test or FPGA run. Separate fresh V1 host/counter, V4 routing,
and V3/V5 host runs are recorded below. The archive check verified 14 saved
copies, actual UART counts and 60 equal Actual/Golden words; the waveform check parsed actual
handshakes rather than trusting filenames. Neither checker can compare this
report with the missing TA notes.

| Evidence scope | V-goal | Result | Named test and count / exact log evidence |
|---|---|---|---|
| Full current-source RTL regression | V1, V2, V3, V5 | PASS | `npu_lab2_tb`, `demo/out/rtl.log:403`: `RESULT: PASS=43806036 FAIL=0 cases=57255`. PASS counts are assertions; cases are COMPUTEs. |
| Length/alignment/offset and window-end matrix | V1 | PASS | `length_matrix`, `demo/out/rtl.log:400`: 304 lengths (`1..300,511,512,513,1024`) × 16 alignments × 5 offsets = **24,320** cases; **12,160** window-end cases; **2** signed-wrap cases. |
| Separate ptr1/ptr2 error injection and recovery | V2 | PASS | `run_error_matrix`, `demo/out/rtl.log:16–136`: **64/64** named cases, **56/56** recoveries, eight `ff` coverage masks; final RTL failures=0. Covers first/middle/last SLVERR, middle DECERR, early/correct RLAST and RLAST 1/5 beats late, B=16/256, accepted/held other AR. |
| Wide-offset path and subsequent plain calls | V3 | PASS | `run_offset9_matrix`, `demo/out/rtl.log:15`: `tuples=4032 wide=6560 alternating_plain=4288 int8_sweep=256 reuse_hits=2272 fast_hits=568 failures=0`. |
| Reuse invalidation cases | V5 | PASS | `run_reuse_safety`, `demo/out/rtl.log:8`: `armed_same=64 arena_new_layer=32 rearm=64 unarmed_changed=64 changed_N=64 changed_ptr1=32 failures=0`. |
| Consumed-byte AXI provenance | V5 | PASS | `npu_axi_trace_scoreboard.svh`, `demo/out/rtl.log:401`: `R_beats=5824786 MAC_bytes=26438836 stream_bytes=25311838 fast_bytes=1126998 violations=0`. |
| Broad convolution comparison with upstream | V3, V4, V5, V7 | PASS | `scratch/conv_host_test`, `demo/out/conv_host.log`: **2,582/2,582** cases, **1,187,329** outputs, **0 mismatches**; product-count/call-pattern failures=0; stale hits/armed returns/changed-input rerun mismatches=0. This is not by itself proof of V4's sole-symbol requirement. |
| Set tests before and after convolution, saved FPGA run | V6 | PASS | `demo/V6/uart.log:41,165`: `Pass 3/3` each time. |
| Random tests before/after convolution and after model, saved FPGA run | V6 | PASS | `demo/V6/uart.log:54,178,408`: `Pass 100/100` each time. |
| Boundary/length/offset/alignment sweep, saved FPGA run | V6 | PASS | `demo/V6/uart.log:110`: `[EXTRA] END cases=640 failures=0 [PASS]`; 40 N/offset rows each have 16 alignments. |
| Three convolution goldens, saved FPGA run | V6 | PASS | `demo/V6/uart.log:122–124`: `[PASS] Testcase1, Output Correct, Cycles=25985`; Testcase2 **177217** cycles; Testcase3 **712911** cycles. |
| All available model labels, saved FPGA run | V6 | PASS | `demo/V6/uart.log:240,275,310,345,380`: `[Status] label{0,1,6,8,11}: ALL 12 GOLDEN OUTPUTS PASS.` **5/5** labels, **60/60** golden words. |
| Five actual waveform examples | V7 | PASS | `demo/out/{aligned,unaligned,split_4k,slverr,missing_rlast}.log` and `waves/*.vcd`: respectively **267, 578, 292, 1,364, 314,585** passing assertions, **1 COMPUTE each**, zero failures; parsed traces have respectively **32,33,34,48,51** accepted R beats. |

### Current-source V1 host/counter revalidation — continuation 3 of 5

The remaining V1 host/counter evidence was refreshed on 2026-10-14 using the
current RTL and real API, including the `.bss` fix. The already source-matched
full RTL sweep was **not rerun**. Text evidence is retained under
`P/Platform/sw/results/lab2_verification/v1/` (`V1/` below).

These are the focused phases of `run_lab2_length_tests.sh`; run from
`P/Platform/` to reproduce without repeating its full four-seed regression:

```bash
set -euo pipefail
out=$(mktemp -d /tmp/lab2-verification-v1.XXXXXX)
rtl=(hw/srcs/NPU.v hw/srcs/npu_burst_dot_product.v)
verilator --lint-only --top-module NPU -Wall "${rtl[@]}"
iverilog -g2012 -Wall -s npu_lab2_counters_tb -o "$out/counters.vvp" \
  hw/sim/npu_lab2_counters_tb.sv "${rtl[@]}"
vvp -n "$out/counters.vvp"
g++ -std=c++17 -O2 -g -Wall -Wextra -Werror \
  -fsanitize=address,undefined -fno-sanitize-recover=all \
  -Isw/project -Isw/app sw/tests/lab2_length_host_test.cc \
  sw/project/lab2_api.cc -o "$out/host"
"$out/host"
python3 hw/sim/check_lab2_length_mutations.py "$out/mutations"
```

| V1 requirement / check | Verdict | Named test and observed counts |
|---|---|---|
| Unaligned standalone calls and 256-byte partition/recombination at N=257,300,511,512,513 | PASS | `lab2_length_host_test`, `V1/host.log:1–6`: **160 cases per N** (16 alignment pairs × 5 offsets × 2 patterns), **800 matrix cases**; whole and partitioned calls match an independent int64 unsplit oracle modulo 2^32. |
| Each element and input_offset visited exactly once; raw pointer progression and read-only operands | PASS | Same test: **5,149,760 per-element audits**, **11,360 COMPUTEs**, **0 mismatches**; both pointer progressions, unchanged operands and redzones are asserted. Offsets are `-128,-1,0,1,127`; the offset-only pattern prevents signed random cancellation from hiding duplicate offsets. |
| Actual signed wraparound and empty API call | PASS | Same **833-case** host result includes **32** N=70,000 signed-overflow cases (both signs × 16 alignments) and **1** N=0 call; the wide oracle must actually exceed int32 bounds. |
| Counter widths and N=256 / maximum encoded-N initialization | PASS | `npu_lab2_counters_tb`, `V1/counters.log:3–57`: **54 width entries**, **80 SET/COMPUTE snapshots**, **8,006 checks**, **0 failures**; includes all 16 alignments and all 1,024 page-word positions at seven remaining-length boundaries. |
| The gates reject narrowing, lost offsets and wrong pointer progression | PASS | `check_lab2_length_mutations.py`, `V1/mutations.log`: **6/6 rejected**, survived=0: top-length-8bit, beat-index-8bit, cover-span-32bit, host-length-8bit, host-missing-offset, host-wrong-filter-pointer. Nonzero matching functional failure counts are required; unrelated build/runtime failures do not count. |

The counter test reads `$bits` from the actual instantiated NPU hierarchy,
checks `covering_words` and `burst_size` against independent 64-bit bounds, and
observes the real SET/COMPUTE initialization. Length fields are **32 bits**;
remaining/issued/received word counters are **31 bits**; covering spans and byte
positions are **33 bits**; burst counts and `beat_index` are **9 bits**;
**8-bit ARLEN encodes B−1**, not B or N. For N=256 with low pointer bits up to 3,
at most **65 covering words** are needed, so no N=256 truncation is hidden.

**Limit distinction:** the encoded maximum is `0xffffffff`; the largest legal
whole-window vector is `0x08000000` bytes at `0x60000000`. UINT32_MAX cannot fit
the legal AXI window. Huge-length snapshots hold ARREADY low and reset after
checking initialization; they are **not completed giant-vector transactions**.
All 54 actual widths and their conservative bounds are printed in
`V1/counters.log`. These facts neither resolve the hidden-test N question nor
claim exhaustive functional simulation of every encoded N.

Strict production-RTL lint exited zero (`V1/lint.log` is empty). All **9/9**
source hashes, captured before these runs, still matched afterwards
(`V1/inputs.sha256`, checked relative to `P/Platform/`, and
`V1/inputs_recheck.log`). Both test sources and their mutation controls were
inspected. The native test models instructions, not the physical cache or AXI
bus; those properties need the separate RTL/UART evidence. No source or prior
result was changed.

### Current-source V4 revalidation — continuation 2 of 5

The old routing results predated the `.bss` startup-state fix. Rather than
assuming that change was harmless, the real current API was freshly compiled
and tested on 2026-10-14. Text evidence is retained under
`P/Platform/sw/results/lab2_verification/v4/` (abbreviated `V4/` below).
Production code, test sources and prior logs were not edited.

Reproduce the functional and negative-control runs from `P/`:

```bash
set -euo pipefail
out=$(mktemp -d /tmp/lab2-verification-v4.XXXXXX)
bash Platform/sw/tests/run_mac_routing_tests.sh "$out"
python3 Platform/sw/tests/check_mac_routing_mutations.py "$out"
```

The runner compiles **the real `lab2_api.cc`** with function-entry/exit
instrumentation and ASan/UBSan. Only the CUSTOM-0 instruction boundary is
modeled. Independent upstream int8/int16 references, exact call/product counts,
split pointer/N/offset observations, deliberately armed entry state and an
ordinary MAC after every convolution check more than final arithmetic.
The mutation runner accepts a rejection only on the expected functional
assertion and exit code, not a compile error, crash or timeout.

| V4 requirement / check | Verdict | Direct evidence |
|---|---|---|
| Real MAC entry on fast, merged, border/grouped, dilated, aliased, split, empty and int16 routes | PASS | `mac_routing_host_test`, `V4/host.log:1–29`: **26** convolution/dot cases; **9,256** real entries and **9,256** exits; model failures=0 and failures=0. |
| Split visits each element once, advancing both pointers and preserving offset | PASS | `V4/host.log:14`: **42 tuples**, N=`0,1,4095,4096,4097,8193`, **7 offsets**, `exact_visitation=1`; entry/COMPUTE/product counts also asserted. |
| Clear every preparation field and disarm reuse on all convolution returns | PASS | Every `ROUTING CASE` has `software_idle=1 reuse_armed=0`; final `nonidle_mac_exits=0`. `V4/host.log:28` additionally verifies **2 prepared N=0 calls**, consumed preparation and no COMPUTE. |
| Routing/cleanup checks detect real defects | PASS | `V4/mutations.log`: **5/5** detected, escaped=0: bypass-real-entry, drop-scope-exit, skip-split-term, skip-empty-consumption and clear-only-pending. Individual failing-mutant logs are retained in `V4/mutations/`; these are expected negative controls, not production failures. |
| Exact legacy signature and C linkage; one current API definition, no renamed MAC macro | PASS | `V4/abi_and_boot.log`: cross-compiled C11 `_Generic` signature check **1/1**; fresh RV32 object has **one GLOBAL FUNC** `hw_simd_mac`. `V4/source_audit.log`: preprocessed API has one declaration/definition, convolution has one declaration/direct call, name macros=0; source occurrence inventory was inspected. |
| One symbol in the existing V6 firmware, and initialized command state | PASS | `V4/abi_and_boot.log`: **one** `600030e0 T hw_simd_mac`, GLOBAL not WEAK. Existing ELF SHA-256 `6e2ac65f9551a4cefe75b6fe972d2587855cdcf0fc89daf504e4660d1b529096`; command object `[0x6031ce40,0x6031ce48)` lies wholly within startup's zeroed `[0x60132000,0x60323b24)`. This ELF was inspected, not rebuilt or run again. |

Current source call paths (not the historical audit's pre-fix API line numbers):
`conv.h:212–213` fast, `266–267` merged rows and `289` border/grouped/dilated
fallback all enter `ConvDotProduct:44–59`, then its real call at `54–56`, then
`lab2_api.cc:92–110`. Int16 uses `conv.h:397–398` -> `ConvDotProduct16:62–85`
-> the same route; the packed-int4 wrapper at `318–322` delegates to int8.
CPU byte-plane recombination is not an input/filter channel MAC. Out-of-image
padding has no product to execute. The inspected preprocessor output preserves
the real function name; no inline MAC substitute, overload or weak definition
was found.

| Global / retained state | Setter | Clearer | Value at a ConvPerChannel return |
|---|---|---|---|
| `lab2_api.cc:6` `kDCacheLineBytes` | Constant initialization | None | `32`, immutable |
| `lab2_api.cc:18` `g_conv_command` (`offset`, `precleaned`, `pending`) | Startup-zeroed `.bss`; `lab2_prepare_mac:81–82` | MAC entry `94–95`, before the N=0 return; `lab2_conv_reset:76–79` | `{0,false,false}`; all fields, not just `pending` |
| `lab2_api.cc:47` `hw_simd_mac_cnt` | Zero initialization; host model increments on COMPUTE | Not a scope-clear field | Production: unchanged entry value; host: diagnostic count of modeled COMPUTEs. Not an arm flag. |
| `conv.h` | No globals or function-local static state | Stack `ConvMacScope` at `108` / `335`; destructor at `34` calls reset | No retained kernel state; fast early return at `234` also destroys scope |
| Hardware reuse/filter-cache arm bits (not C++ globals) | `lab2_reuse_arm:72–74`, CUSTOM-0 `(4,4,1,0)` | `lab2_conv_reset:78`, CUSTOM-0 `(4,3,0,0)`; inspected `NPU.v:165–170,327–331` | Both zero and operand validity invalidated; subsequent unprepared MAC uses its own SET8 offset |

The current-source manifest is `V4/inputs.sha256`; the runner's seven input
hashes were also rechecked after execution (`V4/source_recheck.log`). These
host/source/ELF results do **not** establish physical cache coherence or fill in
missing TA requirements. They remove the stale-V4-evidence uncertainty without
changing any unresolved section-coverage verdict.

### Current-source V3/V5 host revalidation — continuation 4 of 5

The focused offset and shared-arena host tests were freshly rebuilt with
ASan/UBSan on 2026-10-14, linking the **real current API** and modeling only its
custom-instruction boundary. The separate upstream reference translation unit
still uses the unchanged tracked convolution header (`upstream.log`). The
positive full RTL regression and FPGA runs were not repeated. Evidence is in
`P/Platform/sw/results/lab2_verification/v3_v5/` (`V35/` below).

The commands used the host compile/link phases of `run_offset9_tests.sh` and
`run_reuse_provenance_tests.sh`, sharing newly compiled `offset9_ref.o`,
`offset9_model.o` and `lab2_api.o` between the two separate executables. Both
were built with `-O2 -Wall -Wextra -Werror -fsanitize=address,undefined
-fno-sanitize-recover=all`, then executed. The existing
`check_offset9_mutations.py` was run against those objects; the arena stale-cache
negative control was the same temporary model mutation used by the existing
reuse-provenance runner. No production or test source was modified.

| Evidence scope | V-goal | Verdict | Named test and observed counts |
|---|---|---|---|
| Required offsets on depth-300 pointwise and 3×3 convolutions, plus stride/dilation and grouped shapes | V3 | PASS | `offset9_host_test`, `V35/offset9_host.log:1–32`: **8 offsets** (`-128,-127,-102,-1,0,1,127,128`) × **4 shapes** × **16 alignments** × **2 patterns** = **1,024 matrix cases**. All 32 named offset/shape rows report failures=0. |
| Byte-exact upstream comparison and actual conv/plain alternation | V3 | PASS | `V35/offset9_host.log:39–40`: **1,280 convolutions**, **196,608 bytes**, **196,601 unsaturated outputs**, **0 byte mismatches**, model failures=0 and failures=0. Every convolution is followed by a plain MAC; all **256 int8 offsets** follow an actual +128 convolution. |
| Direct +128 command path, all independent pointer alignments, with/without reuse | V3 | PASS | `V35/offset9_host.log:33–38`: N=`1,3,4,255,256,300`, **112 tuples per N** (16 alignments × 7 plain offsets). Each tuple alternates prepared +128 and plain calls, including cached repeats; **2,624 plain calls** overall, **19,104 reuse hits**, **4,392 fast hits**, stale=0. |
| Offset/state defects cannot pass the checks | V3 | PASS | `V35/offset9_mutations.log`: **5/5 detected**, escaped=0: model-truncate-offset8, api-truncate-offset8, api-drop-disarm, rtl-truncate-set9 and rtl-sticky-set8. The last two run temporary RTL mutants with `+offset9_only +fail_fast`; no positive full RTL rerun is claimed. |
| Consecutive convolution layers reuse the same input address with different data | V5 | PASS | `reuse_arena_host_test`, `V35/arena_host.log:1–129`: N=`3,64,300,1024` × 16 alignment pairs = **64 pairs / 128 layers**, **256 changed reference outputs**, **0 mismatches**, stale hits=0, model failures=0, failures=0. Each layer refills then reuses ptr1 three times; only production scope entry/exit performs invalidation. |
| Stale-cache defect causes observable output errors | V5 | PASS | `V35/arena_mutation.log`: removing both arm/disarm invalidations in a temporary model is rejected with exit **1**, **256 actual byte mismatches**, **256 stale hits**, **129 failed assertions**. This is an expected negative control, not a production failure. |

Current +128 path, inspected end-to-end:

1. `conv.h:44–59` accepts an **int32_t** offset, calls
   `lab2_prepare_mac(input_offset, precleaned)`, then the real `hw_simd_mac`.
   Its legacy int8 argument is `0`, deliberately unused for a prepared call;
   +128 is **not** cast to that int8 argument.
2. `lab2_api.cc:10–18,81–82` retains the offset in the **int32_t** command field.
   The real MAC at `92–110` consumes/zeros all fields, emits
   `cfu_raw_op(4, 5, N, command.offset)` for SET9, then COMPUTE on the raw pointers.
   An unprepared call instead emits SET8 with its own int8 offset.
3. `cfu.h` transports `rs2` as `uintptr_t`; `NPU.v:313–320` latches SET9 from
   `rs2_i[8:0]`, whereas SET8 overwrites all nine bits with sign-extended int8.
   The host model uses the same SET8/SET9 selection, nine-bit engine latch,
   signed ten-bit input-plus-offset and signed seventeen-bit product—not a
   direct ConvParams shortcut or a replacement MAC.
4. `V35/offset_path.log` preserves the positive type/dataflow grep and reports
   **0 direct scalar-int8 narrowing matches** for input_offset, command.offset
   or 128. This lexical check is supplemented by source inspection and the
   independently detected narrowing mutations; it is not a stand-alone proof.

`V35/evidence_audit.log` additionally checks the complete 32-row offset/shape
set, six command rows, and all 128 exact length/alignment/layer combinations,
not just the final totals. All **17/17 pre-run source hashes** still matched
post-run (`V35/inputs.sha256`, relative to `P/Platform/`, and
`V35/inputs_recheck.log`). The model source, both tests and mutation controls
were inspected for the actual assertions described above. The V5 host test
proves freshness through modeled commands, not physical AXI provenance; the
separate current-source RTL scoreboard evidence remains in the earlier table.

## Open question — hidden-test N range

**OPEN:** What N range will the TA's hidden tests use? The published assignment
states `1 <= N <= 256` (`assignments/lab2/lab_2.md`, “Testcase Input Limits”),
but that does not resolve the requested clarification about hidden tests.

**V1 already covers N up to 1024.** The inspected testbench runs every N=1..300
with all 16 alignment pairs and five offsets, plus the same full matrix for
511, 512, 513 and 1024. Its additional `long-sweep` runs every N=257..1024 with
rotating alignments/offsets. Thus it does not claim the full Cartesian matrix
for every intermediate N=301..1023. `demo/out/rtl.log:400,403` records the
coverage and zero failures. Neither 1024 nor the tested maximum should be
presented as a TA-confirmed hidden-test limit.

## Final completion audit — stopped at turn 5 of 5

**Outcome: incomplete, stopped at the requested turn limit.** The original TA
checklist remains the blocking input; the active goal was not marked complete.
V4 was freshly revalidated on turn 2, V1's host/counter gates on turn 3, and
V3/V5 focused host gates on turn 4. Turn 5 audited the actual report, retained
sources/results and exact cited UART lines, then printed the final file.

Audit output: `P/Platform/sw/results/lab2_verification/final_audit.log`.
The evidence checks succeeded, but the objective gate deliberately exited **1**
with `OBJECTIVE_GATE: BLOCKED`: **30 evidence PASS rows do not resolve the
8 missing-source FAIL rows**. These counts describe this report, not the
unknown number of original TA checklist items.

### Prompt-to-artifact checklist

| Explicit requirement | Actual inspected artifact / evidence | Audit decision |
|---|---|---|
| Named file `Platform/sw/lab2_verification.md` | This file in the platform subrepository; final contents printed after the audit. | File delivered; crosswalk incomplete |
| Every checklist item in 1.1, 1.2, 1.3, 1.4, 2.1, 2.2, 2.3 and 3 | Each required section has a source-coverage row above, but no original section text was supplied or located. The assignment and previous V-goal audits are not substitutes for the TA notes. | Blocked for all eight sections |
| Covering V-goal and PASS/FAIL for each original item | V1–V7 evidence index and current-source test tables exist; the eight original-section mappings remain `Unassigned` / `FAIL`. | Not met; cannot infer missing items |
| Evidence is a named test and count, or UART log line | Test sources and controls were inspected; current/saved counts checked; all **14 cited UART result lines** and **60/60 Actual/Golden words** matched. | Available evidence verified; completeness against missing notes unknown |
| Hidden-test N-range question is open | The preceding OPEN section distinguishes the published 1..256 range from the unanswered hidden-test question. | Met |
| Explicitly note V1 covers N up to 1024 | Current testbench matrix/long-sweep and `demo/out/rtl.log:400,403`; full matrix versus rotating sweep accurately distinguished. | Met |
| Do not rely on green proxies alone | Final audit rechecked **9/9 V1**, **14/14 V4**, **17/17 V3/V5** source hashes; **22/22** saved demo sources; **14/14** archive copies; existing V6 ELF; exact error/recovery name sets and UART lines; actual VCD handshakes. It still rejects checklist completion because source requirements are absent. | Evidence integrity established, not objective completeness |
| File printed with no FAIL rows | Final printed draft retains **8 unresolved source-coverage FAIL rows**. | Not met |
| Stop after five turns | This is the fifth continuation; no further tests, implementation changes or completion claim follow. | Stop condition reached, not success |

### Handoff

Provide the original TA Q&A notes for the eight sections, or their file path.
Then enumerate each original checklist item, map it to a V-goal and the specific
retained evidence, and check for omissions or additional tests before assigning
PASS. Keep the hidden-test N question OPEN unless a separate authoritative TA
answer is supplied. Print and re-audit the completed crosswalk only after no
required item remains uncovered.

No production source, test source, golden, submission ZIP or prior evidence was
changed. Only this report and new text evidence under
`P/Platform/sw/results/lab2_verification/` were added.
