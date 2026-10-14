#!/usr/bin/env bash
# From repo root: bash Platform/hw/sim/run_reuse_provenance_tests.sh [output-dir]
# All required cases use four-state Icarus and persist EVERY R and MAC byte.
# FULL=0 skips only the additional full Verilator regression, not acceptance.
set -euo pipefail
out=$(realpath -m "${1:-/tmp/reuse-provenance}")
cd "$(dirname "$0")/../.."
mkdir -p "$out"
ulimit -c 0
work=$(mktemp -d /tmp/reuse-provenance-build.XXXXXX)
trap 'rm -rf "$work"' EXIT
rtl=(hw/srcs/NPU.v hw/srcs/npu_burst_dot_product.v)
{
    iverilog -V 2>&1 | head -n 1 || true
    verilator --version
    g++ --version | head -n 1
    python3 --version
} > "$out/tools.txt"
verilator --lint-only --top-module NPU -Wall "${rtl[@]}" > "$out/lint.log" 2>&1
iverilog -g2012 -Ihw/sim -Wall -s npu_lab2_tb -o "$work/tb.vvp" \
    hw/sim/npu_lab2_tb.sv "${rtl[@]}" > "$out/iverilog_build.log" 2>&1
for seed in 7 20261007; do
    timeout 180 vvp -n "$work/tb.vvp" +reuse_safety_only +fail_fast +seed="$seed" \
        +axi_trace="$out/axi_$seed.csv" > "$out/rtl_$seed.log" 2>&1
    grep -E '^(REUSE_SAFETY|AXI_SCOREBOARD|RESULT:)' "$out/rtl_$seed.log"
    python3 hw/sim/verify_axi_trace.py "$out/axi_$seed.csv" "$out/rtl_$seed.log" | tee "$out/replay_$seed.log"
    gzip -f "$out/axi_$seed.csv"
done
python3 hw/sim/check_axi_trace_verifier.py | tee "$out/trace_verifier_controls.log"
python3 hw/sim/check_provenance_mutations.py "$out/mutations" | tee "$out/mutations.log"

r=../tflite-micro
oracle=tensorflow/lite/kernels/internal/reference/integer_ops/conv.h
{
    git -C .. diff --exit-code HEAD -- "tflite-micro/$oracle"
    printf 'tracked upstream blob: '; git -C .. rev-parse "HEAD:tflite-micro/$oracle"
    printf 'current upstream blob: '; git hash-object "$r/$oracle"
    sha256sum "$r/$oracle"
} > "$out/upstream.txt"
flags=(-std=c++17 -O2 -g -Wall -Wextra -Werror -fsanitize=address,undefined
       -fno-sanitize-recover=all -DTF_LITE_STATIC_MEMORY -Isw/project -Isw/app -Isw/tests
       -I"$r" -I"$r/third_party/gemmlowp" -I"$r/third_party/flatbuffers/include" -I"$r/third_party/ruy")
for file in sw/tests/reuse_arena_host_test.cc sw/tests/offset9_ref.cc sw/tests/offset9_model.cc sw/project/lab2_api.cc; do
    g++ "${flags[@]}" -c "$file" -o "$work/$(basename "${file%.cc}").o"
done > "$out/host_build.log" 2>&1
g++ "${flags[@]}" "$work/"*.o -o "$work/host"
"$work/host" > "$out/host.log" 2>&1
grep '^ARENA_RESULT:' "$out/host.log"
# Negative control: leave cached bytes alive across BOTH arm and disarm in
# the instruction model. The same test must report actual byte mismatches,
# not merely a broken counter or failed compiler. Production files untouched.
python3 - "$work/stale_model.cc" <<'PY'
from pathlib import Path
import sys
source = Path('sw/tests/offset9_model.cc').read_text()
old = 'reuse_valid = false; fc_valid = false;'
assert source.count(old) == 1
Path(sys.argv[1]).write_text(source.replace(old, '// mutant: neither arm nor disarm invalidates'))
PY
g++ "${flags[@]}" -c "$work/stale_model.cc" -o "$work/stale_model.o" >> "$out/host_build.log" 2>&1
g++ "${flags[@]}" "$work/reuse_arena_host_test.o" "$work/offset9_ref.o" "$work/lab2_api.o" \
    "$work/stale_model.o" -o "$work/host_stale"
if "$work/host_stale" > "$out/host_stale_control.log" 2>&1; then
    echo 'FAIL: host stale-cache mutation survived'; exit 1
fi
python3 - "$out/host_stale_control.log" <<'PY' | tee "$out/host_mutation.log"
from pathlib import Path
import re, sys
text = Path(sys.argv[1]).read_text()
assert re.search(r'ARENA_RESULT: .* mismatches=[1-9]\d* stale_hits=[1-9]\d* .* failures=[1-9]\d*', text), text[-2000:]
print('HOST MUTATION: stale-across-layers REJECTED (actual output mismatches)')
PY
if [[ ${FULL:-1} == 1 ]]; then
    verilator --binary --timing -Ihw/sim -j "${JOBS:-4}" -Wno-fatal --top-module npu_lab2_tb \
        --Mdir "$work/obj" hw/sim/npu_lab2_tb.sv "${rtl[@]}" > "$out/verilator_build.log" 2>&1
    timeout 300 "$work/obj/Vnpu_lab2_tb" +seed=7 +fail_fast > "$out/full_regression.log" 2>&1
    grep -E '^(REUSE_SAFETY:|COVERAGE:|AXI_SCOREBOARD:|RESULT:)' "$out/full_regression.log"
fi
# Reproducible decode/storage-write evidence; the accompanying audit explains
# why the separate Lab1 register SIMD path does not preload Lab2 operand RAM.
{
    grep -nE 'FUNCT3_|FUNCT7_|funct3_i\[2:0\]|reuse_clear|M_AXI_WDATA.*<=|simd_mac_accumulator_r.*<=' hw/srcs/NPU.v
    grep -nE '(input_buffer|in_rep\[|fc_mem\[).*<=|emit_valid =|in_rep_we =|fc_we =|reuse_hit =|reuse_valid <=' hw/srcs/npu_burst_dot_product.v
    grep -nE 'cfu_raw_op|lab2_conv_reset|ConvMacScope|lab2_reuse_arm|output_disjoint' \
        sw/project/lab2_api.cc sw/tflm_patches/"$oracle"
} > "$out/decode_and_writes.txt"
sha256sum "${rtl[@]}" hw/sim/npu_lab2_tb.sv hw/sim/npu_axi_trace_scoreboard.svh \
    hw/sim/run_reuse_provenance_tests.sh hw/sim/check_provenance_mutations.py hw/sim/verify_axi_trace.py \
    hw/sim/check_axi_trace_verifier.py \
    sw/tests/reuse_arena_host_test.cc sw/tests/offset9_model.{cc,h} sw/tests/offset9_ref.cc \
    sw/project/lab2_api.{cc,h} sw/app/cfu.h sw/tflm_patches/"$oracle" "$r/$oracle" > "$out/source_sha256.txt"
echo "REUSE PROVENANCE ACCEPTANCE: violations=0 mismatches=0; evidence: $out"
