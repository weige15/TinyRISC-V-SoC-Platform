# Lab 2 length, alignment, offset and counter audit

## Deliverables / reproduction

The required outcomes are (1) reference-correct RTL for the specified length ×
alignment × offset matrix, including boundary placements and safe AR spans;
(2) actual counter widths and non-overflow bounds at N=256 and the hardware
maximum; (3) a native test of the real host API whose partitioned results match
an unsplit reference, with exactly one offset application per element.

From the `TinyRISC-V-SoC-Platform` root:

```sh
bash Platform/hw/sim/run_lab2_length_tests.sh /tmp/lab2-length-tests
# Optional independent four-state run of the same complete RTL testbench:
FOUR_STATE=1 bash Platform/hw/sim/run_lab2_length_tests.sh /tmp/lab2-length-tests
```

The runner uses strict Verilator RTL lint, Icarus for hierarchical `$bits` and
command-initialization checks, four seeded Verilator timing simulations, native
ASan+UBSan host testing, and six negative controls. Failures exit nonzero.
Text evidence is retained under `Platform/sw/results/lab2_length_coverage/`.
The source manifest binds the results to the actual RTL, testbenches, host API,
CFU header, and runner; it is not itself a coverage proof.

## Prompt-to-artifact completion checklist

| Requirement | Implementation / gate | Observed evidence |
|---|---|---|
| RTL N={1,2,3,4,5,7,8,15,16,17,31,32,33,63,64,65,127,128,129,255,256} | All are in the **full** 1..300 matrix in `npu_lab2_tb.sv::required_length` / `length_matrix` | Each seed's `COVERAGE` and `RESULT` lines; 304 separate 80-bit coverage masks checked at end |
| Every N=1..300 at least once; N={511,512,513,1024} | Every one of these 304 lengths runs 80 tuples, not just one rotating offset/alignment | `matrix=24320`; additional legacy sweep also tests every N through 1024 |
| All 16 ptr1[1:0] × ptr2[1:0] combinations; offsets {-128,-1,0,1,127}; random int8 data | Nested 4×4×5 loops; `pick_offset(0..4)`; fresh `$urandom` bytes before each reference | Coverage bits are credited only after a correct COMPUTE and zero STATUS; all 80 bits required for each N |
| int32 wraparound reference | Signed product temporary followed by 32-bit modular addition; independent known-answer sign-extension checks | Zero failures; actual positive overflow at N=70000 and negative overflow at N=140000, each checked by a 64-bit oracle before running |
| Buffers just below a 4 KiB boundary | Matrix placements `0x60000ffc+o1` / `0x60008ffc+o2`, plus original directed split tests | Exact burst-sequence, 4 KiB split and multi-beat checks run on every accepted AR; boundary coverage remains nonzero |
| Buffers ending exactly at 0x67FFFFFF | For every required N, place **each** operand at `0x68000000-N`, for all five offsets and all four alignments of the other operand | `window_end=12160`; separate 40-bit coverage mask for each N must be full |
| No AR request leaves 0x60000000..0x67FFFFFF | Check **offered** ARVALID, including stalled requests, as well as every handshake; 33-bit exclusive end calculation | All seeds have FAIL=0; no address addition can wrap a 32-bit end and bypass the monitor |
| Widths of every length/beat/byte counter in NPU.v; N=256 and maximum cannot overflow | `npu_lab2_counters_tb.sv` prints `$bits` of the top-level length/byte selectors and instantiated engine counters, derived byte/word spans, FIFO and RAM indices | `counters.log`: 54 width entries, 80 SET/COMPUTE snapshots, 8006 checks, 0 failures; proof below |
| Host N={257,300,511,512,513}, unaligned pointers | `sw/tests/lab2_length_host_test.cc`, **linked with production `sw/project/lab2_api.cc`**; all 16 alignment pairs, all five offsets, random and offset-only data | Five `HOST COVERAGE` lines, 160 cases per requested N |
| Split equals unsplit reference; input_offset once per element | Each whole-vector API call and its 256-byte partition both compared with an independent int64 oracle modulo 2^32; CFU seam audits both pointer progressions, configured offsets and exact visitation | 5,149,760 per-element audits; 833 total cases (800 matrix, 32 real signed-overflow, 1 empty); 0 mismatches |
| Tests genuinely detect relevant defects | Fresh-copy mutations: 8-bit top length, 8-bit beat index, 32-bit covering span, truncated host N, missing host offset, shifted filter pointer | `mutations.log`: rejected=6, survived=0; failures must be reported by the relevant counter/host gate, not just a crash |
| Required completion output | `RESULT: ... FAIL=0 cases=...`, `HOST RESULT: ... mismatches=0`, `COUNTER RESULT: ... failures=0` | See recorded results below |

Ending exactly at the window's last byte fixes that operand's alignment to
`(-N) mod 4`; all 16 alignments cannot simultaneously have that same end for a
fixed N. The tests cover all 16 pairs in the ordinary/boundary matrix and all
**possible** pairs separately for each ending operand.

## Counter bounds, including the actual hardware maximum

There is **no 256-byte or 1024-byte hardware length limit**. In `NPU.v`, SET
latches all 32 bits of rs1 into `burst_dot_product_length_r`; the instantiated
`npu_burst_dot_product.v` streams using a circular RAM. Thus:

- Largest *encoded/accepted* N: `0xffffffff = 4,294,967,295`.
- Largest *legal non-wrapping vector in this AXI window*: `0x08000000 =
  134,217,728`, starting at `0x60000000`. For arbitrary ptr1/ptr2, the legal
  bound is `min(0x68000000-ptr1, 0x68000000-ptr2)`.
- These are distinct. The hardware does not validate arbitrary caller address
  ranges. A UINT32_MAX-byte vector cannot fit this window. The maximum-length
  snapshots therefore hold ARREADY low, inspect initialization, and reset;
  they do **not** claim a completed multi-gigabyte memory transaction.

Let `l` be a pointer's low two bits. With `0 <= l <= 3`:

```
W(N,l) = floor((N+l+3)/4) = ceil((N+l)/4)
N=256:        W <= 65
N=0xffffffff: W <= 1,073,741,825 < 2^31
N+l+3 <= 4,294,967,301 < 2^33
4*W <= 4,294,967,300 < 2^33
N+l <= 4,294,967,298 < 2^33
```

These maxima bound **all** smaller encodable lengths, not just the simulated
small-N set. The audit compares these bounds to the actual elaborated widths:

| Fields | Bits | Why safe |
|---|---:|---|
| `NPU.burst_dot_product_length_r`, engine `byte_length`, `length_r`, `reuse_length` | 32 | Preserve the entire SET domain, including 256 and UINT32_MAX |
| `input_left`, `filter_left`, `input_issued`, `filter_issued`, `input_received`, `filter_received`, cover counts | 31 | At most W above. Scheduling moves B from left to issued with 0<B<=left; accepted usable R beats increment received at most up to issued. Errors only stop/discard beats |
| `covering_words.span`, `filter_position`, `filter_limit` | 33 | Widen before addition/shift; the maxima above fit |
| `input_beats`, `filter_beats`, `first_beats`, `q_beats[0:1]`, `beat_index` | 9 | Burst size <=256. On missing RLAST, beat_index may reach **256**, then discard freezes it until RLAST |
| ARLEN fields | 8 | Store **beats minus one**, i.e. 0..255, not a byte count. A 256-beat burst encodes 255 |
| `burst_size.boundary` | 11 | 1..1024 words to a 4 KiB boundary; burst limit further clamps to 256 |
| `needed_increment` / `needed_words` | 10 / 31 | <=257 / W+1 respectively |
| `q_count` / `count_after` | 2 / 3 | At most two outstanding descriptors; head/tail are intentional modulo-two indices |
| `fast_rows`, `fast_k`, `s1_k` | 9 | Fast path requires a reusable input of <=1024 words; <=128 eight-word rows regardless of streaming N |
| RAM/byte selectors | 1..15 | Full inventory in `counters.log`; circular addressing is intentionally modular, not a total-length counter |

At the legal whole-window maximum, the exact cover is 33,554,432 words. The
report conservatively uses 33,554,433 (hypothetically allowing low=3 even at
that N), also safely within 31 bits. The product accumulator is deliberately
32-bit modular and is **not** supposed to prevent arithmetic result overflow.
Address cursors and cache word addresses are addresses, not total-byte/beat
counters; valid buffer endpoints ensure their aligned exclusive ends remain
at or below `0x68000000`. Compile-time generate/for indices are not hardware
length counters.

## Host split scope

Production `hw_simd_mac` now issues one SET/COMPUTE for any nonzero N: splitting
and 4 KiB handling happen in RTL. Adding an unnecessary CPU split loop would
regress that path. The host test instead checks both the real unsplit API and
recombination of real API calls over successive <=256-byte slices. Only
`software_cfu_raw` is modeled; **hw_simd_mac itself is not stubbed**. A visit
count of exactly one is checked even for offset zero, and offset-only vectors
with positive weights prevent accidental cancellation from hiding duplicates.
No `conv.h`, production host code, RTL or FPGA bitstream was changed.

## Recorded results

Verilator seeds and total COMPUTE case counts (includes the original latency,
error-injection, reuse and filter-cache regressions, so totals vary by seed):

| Seed | Cases | Failures |
|---:|---:|---:|
| 20261007 | 45349 | 0 |
| 7 | 45916 | 0 |
| 314511048 | 45621 | 0 |
| 20261013 | 45811 | 0 |

All four report `matrix=24320 window_end=12160 signed_wrap=2`.
The independent Icarus four-state run (seed 20261007) also completes with
`RESULT: PASS=33342316 FAIL=0 cases=46073` and the same full coverage masks.
Simulator PRNGs differ, so the legacy randomized regression counts differ.
The native test reports `cases=833 ... mismatches=0` under ASan+UBSan.
The counter audit reports `widths=54 snapshots=80 checks=8006 failures=0`.
The six negative controls are all rejected. Strict production RTL lint is clean.
The original standalone regressions also pass: 366 burst dot-product checks,
aligned/misaligned AXI read reconstruction, and AXI write byte placement /
handshakes (`npu_burst_dot_product.log`, `npu_misaligned_axi_read.log`,
`npu_misaligned_axi_write.log`). All ten manifest entries were rechecked with
`sha256sum -c` against the current source files; all report OK.

These are simulation/native-host results, not FPGA/board measurements. The
finite functional sweep plus full-domain counter bounds are explicit here;
no claim is made of exhaustive functional simulation of all 2^32 lengths.
