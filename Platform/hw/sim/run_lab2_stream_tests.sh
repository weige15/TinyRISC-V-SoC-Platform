#!/usr/bin/env bash
# Usage: bash sim/run_lab2_stream_tests.sh [output-directory]
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(realpath -m "${1:-/tmp/lab2-stream-tests}")
mkdir -p "$out"
rtl=(srcs/NPU.v srcs/npu_burst_dot_product.v)
verilator --lint-only --top-module NPU -Wall "${rtl[@]}" > "$out/lint.log" 2>&1
iverilog -g2012 -Isim -Wall -s npu_lab2_tb -o "$out/lab2.vvp" sim/npu_lab2_tb.sv "${rtl[@]}"
for seed in 20261007 7 314511048 20261013; do
    vvp -n "$out/lab2.vvp" +seed="$seed" > "$out/sim_$seed.log"
    grep 'RESULT:' "$out/sim_$seed.log"
done
for test in npu_burst_dot_product npu_misaligned_axi_read npu_misaligned_axi_write; do
    iverilog -g2012 -s "${test}_tb" -o "$out/$test.vvp" "sim/${test}_tb.sv" "${rtl[@]}"
    vvp -n "$out/$test.vvp" > "$out/$test.log"
    grep '\[PASS\] All' "$out/$test.log"
done
sha256sum "${rtl[@]}" sim/npu*tb.sv sim/npu_axi_trace_scoreboard.svh > "$out/source_sha256.txt"
echo "PASS: logs and source hashes in $out"
