#!/usr/bin/env bash
# Usage: bash Platform/hw/sim/run_lab2_length_tests.sh [absolute-output-directory]
# Requires Verilator (timing support), Icarus Verilog, native g++, and Python 3.
set -euo pipefail
out=$(realpath -m "${1:-/tmp/lab2-length-tests}")
cd "$(dirname "$0")/../.."
mkdir -p "$out"
ulimit -c 0
rtl=(hw/srcs/NPU.v hw/srcs/npu_burst_dot_product.v)
{
    verilator --version
    iverilog -V 2>&1 | head -n 1 || true
    g++ --version | head -n 1
} > "$out/tools.txt"
# Strict lint is on production RTL, not the intentionally width-varied TB.
verilator --lint-only --top-module NPU -Wall "${rtl[@]}" > "$out/lint.log" 2>&1
iverilog -g2012 -Wall -s npu_lab2_counters_tb -o "$out/counters.vvp" \
    hw/sim/npu_lab2_counters_tb.sv "${rtl[@]}" > "$out/counters_build.log" 2>&1
vvp -n "$out/counters.vvp" | tee "$out/counters.log"

# Compiled simulation keeps the full matrix + original regression fast.
verilator --binary --timing -Ihw/sim -j "${JOBS:-4}" -Wno-fatal --top-module npu_lab2_tb \
    --Mdir "$out/obj" hw/sim/npu_lab2_tb.sv "${rtl[@]}" > "$out/rtl_build.log" 2>&1
for seed in 20261007 7 314511048 20261013; do
    "$out/obj/Vnpu_lab2_tb" +seed="$seed" > "$out/rtl_$seed.log"
    grep -E '^(COVERAGE:|RESULT:)' "$out/rtl_$seed.log"
done

# Secondary four-state simulator: run with FOUR_STATE=1 (several minutes).
if [[ ${FOUR_STATE:-0} == 1 ]]; then
    iverilog -g2012 -Ihw/sim -Wall -s npu_lab2_tb -o "$out/lab2.vvp" \
        hw/sim/npu_lab2_tb.sv "${rtl[@]}" > "$out/iverilog_build.log" 2>&1
    vvp -n "$out/lab2.vvp" +seed=20261007 > "$out/rtl_iverilog.log"
    grep -E '^(COVERAGE:|RESULT:)' "$out/rtl_iverilog.log"
fi

g++ -std=c++17 -O2 -g -Wall -Wextra -Werror \
    -fsanitize=address,undefined -fno-sanitize-recover=all \
    -Isw/project -Isw/app sw/tests/lab2_length_host_test.cc sw/project/lab2_api.cc \
    -o "$out/host" > "$out/host_build.log" 2>&1
"$out/host" | tee "$out/host.log"
python3 hw/sim/check_lab2_length_mutations.py "$out/mutations" | tee "$out/mutations.log"
sha256sum "${rtl[@]}" hw/sim/npu_lab2_tb.sv hw/sim/npu_axi_trace_scoreboard.svh hw/sim/npu_lab2_counters_tb.sv \
    hw/sim/run_lab2_length_tests.sh hw/sim/check_lab2_length_mutations.py \
    sw/tests/lab2_length_host_test.cc \
    sw/project/lab2_api.cc sw/project/lab2_api.h sw/app/cfu.h > "$out/source_sha256.txt"
echo "PASS: Lab 2 length/offset coverage; logs and source hashes in $out"
