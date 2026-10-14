# O5 operand-reuse safety: completion audit

## Objective / acceptance criteria

Prove the current Lab2 reuse path has no register-to-operand-RAM preload path,
check each consumed operand byte against earlier AXI R evidence at its full
address, and demonstrate freshness for (a) armed same-key reuse, (b) arena-address
reuse across convolution calls, (c) unarmed changed memory, and (d) changes of N
or ptr1 while armed. Run actual consecutive host `ConvPerChannel` calls sharing
an input address; require zero reference mismatches and zero scoreboard violations.

**Scope:** the production NPU's default RAM configuration and documented software
ownership/coherence contract. This is a source-level invariant argument plus
executable RTL/host checks, not an exhaustive formal model-checking claim. Memory
must remain unchanged while its cached copy is eligible for reuse. Arbitrary CPU
or DMA writes during an armed interval without invalidation are NOT coherent;
the hardware cannot observe them. `ConvPerChannel` satisfies this contract by
cleaning operands, arming only for output-disjoint tensors, and invalidating on
entry and every exit. This audit does not claim a new FPGA/board measurement.

## Reproduction

From `TinyRISC-V-SoC-Platform/`:

```sh
bash Platform/hw/sim/run_reuse_provenance_tests.sh \
  "$PWD/Platform/sw/results/reuse_provenance"
cd Platform
sha256sum -c sw/results/reuse_provenance/source_sha256.txt
python3 hw/sim/verify_axi_trace.py \
  sw/results/reuse_provenance/axi_7.csv.gz \
  sw/results/reuse_provenance/rtl_7.log
```

The runner uses Icarus (four-state, seeds 7 and 20261007), independently replays
both traces, runs mutation controls, builds the host test with ASan/UBSan, and
runs the full Verilator regression. `FULL=0` omits only the extra full regression.
Manual compilation of `npu_lab2_tb.sv` needs `-IPlatform/hw/sim` (or the equivalent
path from the working directory) for the new scoreboard include.

All evidence below is under `Platform/sw/results/reuse_provenance/`. The source
hash file was checked against the actual current files; the upstream oracle's
tracked and current git blobs also match (`upstream.txt`).

## Prompt-to-artifact checklist

| Explicit requirement | Implementation / check inspected | Actual evidence |
|---|---|---|
| Extend the RTL testbench with an AXI trace scoreboard | `npu_lab2_tb.sv` includes `npu_axi_trace_scoreboard.svh`; `provenance_tick` runs before the slave updates its queue | `rtl_7.log`, `rtl_20261007.log`: each 194,516 accepted R beats, **0 violations** |
| Log **every** R beat | Independent public AR FIFO; on every `RVALID && RREADY`, log sequence, call, cycle, full address, data, RRESP, RLAST, usable flag, operand and epoch; final count equals slave `total_beats` | `axi_7.csv.gz`, `axi_20261007.csv.gz`; replay totals equal simulation totals; errors/tails are logged too when injected |
| Every consumed byte came from earlier R at its represented address | Actual stream `input_word`/RDATA and local `in_q`/`fc_word_row` checked bytewise; address is `ptr1+i` or `ptr2+i`; epoch and miss-cycle floor prohibit old facts, even if values happen to match | Each directed run: **856,256** MAC bytes (838,416 streaming, 17,840 local); `replay_*.log`: **0 violations** |
| No software register path writes local operand bytes; show decode | Exhaustive decode table and all three operand-RAM assignment sites below | `decode_and_writes.txt`; inspected `NPU.v` and `npu_burst_dot_product.v` |
| (a) Armed same ptr1 across calls matches reference | `run_reuse_safety`, `a-armed-same-key` and `a-new-layer-hit`; exact AR list (no ptr1 refill), reference sum and STATUS; both funct7=3 and 4 | `REUSE_SAFETY`: `armed_same=64`, failures=0 per seed |
| (b) Same address, new memory across conv scopes; arm/disarm invalidates | `b-conv-arena-new-layer`: disarm, mutate all input bytes at same ptr1/N, arm, refetch; reference is asserted to change. Separate arm-only tests, including **unchanged** bytes, require refetch too | `arena_new_layer=32 rearm=64`, failures=0 per seed; actual software conv pair evidence in `host.log` |
| (c) Unarmed same address with changed memory always refetches | `c-disarm-changed`, `c-unarmed-changed-again`; independent AR list requires both operands again | `unarmed_changed=64`, failures=0 per seed |
| (d) Different N **or** ptr1 while armed refetches | `d-different-N`, `d-old-N-again`, `d-different-ptr1`; exact AR list and byte checks | `changed_N=64 changed_ptr1=32`, failures=0 per seed |
| Host: two consecutive convolution layers with shared input address and different contents; both match reference | `sw/tests/reuse_arena_host_test.cc`, real patched `ConvPerChannel` + real `lab2_api.cc`, instruction-boundary `offset9_model.cc`, separately compiled untouched upstream `offset9_ref.cc` | `host.log`: **64 pairs / 128 layers, 0 mismatches, 0 stale hits, 0 model failures, 0 failures** |
| Non-vacuity: tests actually detect stale/non-AXI data | Mutate the input RAM to use a CPU register, corrupt input replica/filter cache, ignore RVALID, retain copies on invalidation, ignore N/address/enable | `mutations.log`: unmodified control passes, **8 rejected, 0 survived**; first four rejected by the byte/handshake scoreboard itself |
| Non-vacuity: host would catch stale arena reuse | Disposable model omits invalidation on both arm and disarm | `host_stale_control.log`: **256 actual output mismatches, 256 stale hits**; `host_mutation.log`: rejected |
| Non-vacuity: trace replay is a real gate | Positive fixture plus wrong-address/value, same-cycle R, old epoch, error/discarded/missing R, duplicate/missing byte, incomplete call controls | `trace_verifier_controls.log`: **1 valid, 10 rejected, 0 survived** |
| Final success: all cases pass; scoreboard and host zero | Directed coverage checked inside TB, not inferred from total pass count; both seeds replayed | `rtl_*.log`: **384/384 COMPUTEs, FAIL=0**; `full_regression.log`: **57,105 COMPUTEs, FAIL=0**, **26,204,362 MAC bytes, 5,817,496 R beats, 0 violations** |

The directed Cartesian product covers both arm modes and all 16 alignment pairs;
N includes 3, 64, 300 and 4093, with spans crossing 4-KiB boundaries. The existing
full suite additionally exercises ring wrap, oversize non-reuse, error recovery,
filter-window reuse, and all required length/offset matrices. Its scoreboard is
active throughout; persistent per-beat CSVs are retained for the directed runs.

## Scoreboard semantics (not a final-result proxy)

* Reference sums still come from `mem[]`, but **provenance facts never do**.
  Facts originate exclusively from accepted public AR/R handshakes, with the
  complete 32-bit address. The memory slave's 64-KiB alias cannot hide an address
  mismatch. Descriptor operand identity comes from the independently checked AR
  schedule, not the DUT's queue or operand counters.
* Every enabled multiplier input byte is compared, even if the other factor is
  zero or the final sum would coincidentally agree. Leading/trailing masked
  lanes are checked as masks, not counted as consumed bytes.
* The streaming filter is multiplied on its R handshake. Its registered product
  reaches the accumulator the next cycle: the `M` record is at **MAC retirement**,
  so its referenced `R` cycle is strictly earlier. Local operand R evidence must
  already predate the multiply edge. The 32-lane local path is checked too.
* Independent per-call cursors determine represented addresses. The expected
  MAC pipeline verifies valid pulses and sums, and a successful call must consume
  exactly N bytes of **each** operand. Offline replay additionally rejects any
  duplicate or omitted byte and requires every call to complete.
* Arm/disarm increments the evidence epoch. Unarmed calls and key misses require
  new input evidence at or after that COMPUTE's start; filter streaming uses that
  call's R data. Thus merely finding an old, numerically equal byte is not enough.

## Exhaustive software decode: no operand preload

`NPU.v` decodes `funct3_i[2:0]` in `STATE_IDLE`; bit 3 of its port is unused.
`funct7_i` comparisons are full-width equality. These are all branches:

| funct3 | funct7 | Register effect / service | Local operand RAM write? |
|---|---|---|---|
| `000` | any | Register arithmetic: rs1 + rs2 + funct7 | No |
| `001` | any | AXI single-word read, rs1 is address; data to rd | No |
| `010` | any | AXI **external-memory** write: rs1 address, rs2 WDATA; invalidates both caches | No (a later AXI read is required) |
| `011` | `0` / `1` | Lab1 packed-register SIMD accumulate/reset, separate `simd_mac_accumulator_r` | No; this separate MAC is intentionally register-fed and cannot preload Lab2 |
| `011` | other | No accumulator update | No |
| `100` | `0` | SET: N=rs1, signed int8 offset=rs2[7:0] | No |
| `100` | `1` | COMPUTE: rs1/rs2 are memory **addresses** | Only through subsequent accepted R beats |
| `100` | `2` | STATUS to rd | No |
| `100` | `3` | Arm/disarm ptr1 reuse via rs1[0], filter reuse off; **both copies invalidated on either value** | No |
| `100` | `4` | Arm/disarm ptr1 + filter reuse; **both copies invalidated on either value** | No |
| `100` | `5` | SET9: N=rs1, signed offset=rs2[8:0] | No |
| `100` | other | Done, no configuration or operand write | No |
| `101`–`111` | any | Done, no configuration or operand write | No |

Offsets are arithmetic parameters, not operand bytes or cache preload data.
The burst engine has no software-data input port. Its only operand-storage writes
(`npu_burst_dot_product.v:196–219`) are:

```verilog
if (emit_valid && !is_filter)
    input_buffer[input_received[IB-1:0]] <= m_axi_rdata;
// in_rep_we = emit_valid && !is_filter && input_received < 1024
if (in_rep_we && input_received[2:0] == bk)
    in_rep[input_received[9:3]] <= m_axi_rdata;
// fc_we = emit_valid && is_filter && fc_app
if (fc_we && fc_wrel[2:0] == bk)
    fc_mem[fc_wrel[14:3]] <= m_axi_rdata;
```

`emit_valid = r_fire && !discard && !failed`, where
`r_fire = m_axi_rvalid && m_axi_rready`; `failed` includes current response/length
errors and sticky status. No reset, register instruction, or other assignment
initializes these RAMs with usable operand data. Read pipeline registers only
copy these RAMs. Validity masks, not RAM initialization, prevent unfilled use.

## Freshness invariant / software boundary argument

1. After reset, `reuse_valid=0`, `fc_valid=0` and reuse is disarmed. A miss clears
   input validity and records the new key. Only a successful armed call with a
   nonempty input covering at most 1024 words can make ptr1 reusable; ring-wrapped
   vectors are excluded. The retained words came only from the R write sites.
2. A ptr1 hit requires **armed AND valid AND exact address AND exact N**
   (`npu_burst_dot_product.v:73–75`). The fast path additionally requires a valid
   covering filter window and equal byte alignments. Errors invalidate both
   copies before the next instruction can use them.
3. Any accepted funct7=3/4 command asserts `reuse_clear`, independently of the
   new arm bit (`NPU.v:166–170`). The engine clears both valid flags at line 310;
   software cannot overlap COMPUTE with that command. An NPU AXI write also
   invalidates. Old physical RAM bits may remain, but cannot satisfy a hit.
4. `ConvMacScope` resets on construction and destruction, including early
   returns (`conv.h:31–36`). `lab2_conv_reset()` sends `(funct3,funct7,rs1)=(4,3,0)`;
   `lab2_reuse_arm()` sends `(4,4,1)`. The output-disjoint branch bulk-cleans and
   fences the operands before arming. No CPU channel multiply or cache preload
   is substituted for `hw_simd_mac`; it sends N/offset then operand addresses.
5. Therefore, within an owned convolution the immutable cached bytes remain
   equal to the cleaned memory. Across calls, even if the TFLM arena reuses the
   identical address and N, exit/entry/arm invalidate eligibility before any
   new compute. New R beats must populate the next invocation's operands.
   Without arming, every call misses and refetches both vectors.

The host test deliberately uses a **single pixel** so the final key of layer 0
is exactly the initial key of layer 1. It overwrites every logical input byte,
changes layer filters, keeps the input allocation/address fixed, performs no
test-side reset between the actual calls, asserts four MAC commands per layer
with that same ptr1/N, and requires one refill followed by three reuse hits.
All four reference outputs change and remain unsaturated. Thus allocator luck,
a different first pixel, a cache miss caused by a changed N, or saturation
cannot mask a forgotten cross-layer invalidation.

## Completion decision

All explicit requirements above have current source and executed evidence.
No required RTL case, byte-provenance check, decode branch, or host layer-pair
check remains uncovered. The invalidation/coherence precondition is explicit;
no claim is made for software violating an armed interval or for unrun hardware.
