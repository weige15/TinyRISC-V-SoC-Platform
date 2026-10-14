#!/usr/bin/env bash
# Usage: [FULL=1] bash Platform/hw/sim/run_lab2_error_tests.sh [output-directory]
# Icarus is mandatory: RAM guards and the don't-care control use four-state Xs.
# FULL=1 also runs the entire existing regression with Verilator (one seed).
set -euo pipefail
out=$(realpath -m "${1:-/tmp/lab2-error-tests}")
cd "$(dirname "$0")/.."
mkdir -p "$out"
ulimit -c 0
rtl=(srcs/NPU.v srcs/npu_burst_dot_product.v)
{
    iverilog -V 2>&1 | head -n 1 || true
    verilator --version
    python3 --version
} > "$out/tools.txt"
verilator --lint-only --top-module NPU -Wall "${rtl[@]}" > "$out/lint.log" 2>&1
iverilog -g2012 -Isim -Wall -s npu_lab2_tb -o "$out/errors.vvp" \
    sim/npu_lab2_tb.sv "${rtl[@]}" > "$out/iverilog_build.log" 2>&1
for seed in 20261007 7 314511048 20261013; do
    timeout 180 vvp -n "$out/errors.vvp" +errors_only +seed="$seed" | tee "$out/errors_$seed.log"
    python3 sim/verify_lab2_error_log.py "$out/errors_$seed.log"
done
python3 sim/check_lab2_error_mutations.py "$out/mutations" | tee "$out/mutations.log"
if [[ ${FULL:-0} == 1 ]]; then
    verilator --binary --timing -Isim -j "${JOBS:-4}" -Wno-fatal --top-module npu_lab2_tb \
        --Mdir "$out/obj" sim/npu_lab2_tb.sv "${rtl[@]}" > "$out/verilator_build.log" 2>&1
    timeout 300 "$out/obj/Vnpu_lab2_tb" +seed=20261007 > "$out/full_regression.log"
    python3 sim/verify_lab2_error_log.py "$out/full_regression.log"
    grep -E '^(COVERAGE:|RESULT:)' "$out/full_regression.log"
fi
sha256sum "${rtl[@]}" sim/npu_lab2_tb.sv sim/npu_axi_trace_scoreboard.svh sim/run_lab2_error_tests.sh \
    sim/check_lab2_error_mutations.py sim/verify_lab2_error_log.py > "$out/source_sha256.txt"
echo "PASS: Lab 2 error matrix; total 0 failures. Logs and source hashes: $out"
