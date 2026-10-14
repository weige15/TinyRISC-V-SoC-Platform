#!/usr/bin/env bash
# From repository root: bash Platform/hw/sim/run_offset9_tests.sh [output-dir]
# Required: g++, Verilator, Icarus, Python3. Optional RISCV_PREFIX cross compiler.
# Runs host ASan/UBSan, two RTL simulators, the full RTL regression, grep audit.
set -euo pipefail
out=$(realpath -m "${1:-/tmp/lab2-offset9}")
cd "$(dirname "$0")/../.."
mkdir -p "$out"
ulimit -c 0
r=../tflite-micro
upstream=tensorflow/lite/kernels/internal/reference/integer_ops/conv.h
conv=sw/tflm_patches/$upstream
rtl=(hw/srcs/NPU.v hw/srcs/npu_burst_dot_product.v)
{
    g++ --version | head -n 1
    verilator --version
    iverilog -V 2>&1 | head -n 1 || true
} > "$out/tools.txt"
# Fail if the supposedly upstream oracle has been edited from its tracked blob.
{
    git -C .. diff --exit-code HEAD -- "tflite-micro/$upstream"
    printf 'tracked upstream blob: '; git -C .. rev-parse "HEAD:tflite-micro/$upstream"
    printf 'current upstream blob: '; git hash-object "$r/$upstream"
    sha256sum "$r/$upstream"
} > "$out/upstream.txt"
flags=(-std=c++17 -O2 -g -Wall -Wextra -Werror -fsanitize=address,undefined
       -fno-sanitize-recover=all -DTF_LITE_STATIC_MEMORY -Isw/project -Isw/app
       -I"$r" -I"$r/third_party/gemmlowp" -I"$r/third_party/flatbuffers/include"
       -I"$r/third_party/ruy")
# Separate object files expose that hw_simd_mac is defined only in REAL API.
for file in sw/tests/offset9_host_test.cc sw/tests/offset9_ref.cc sw/tests/offset9_model.cc sw/project/lab2_api.cc; do
    g++ "${flags[@]}" -c "$file" -o "$out/$(basename "${file%.cc}").o"
done > "$out/host_build.log" 2>&1
g++ "${flags[@]}" "$out/offset9_host_test.o" "$out/offset9_ref.o" "$out/offset9_model.o" "$out/lab2_api.o" -o "$out/host"
nm -C "$out/lab2_api.o" "$out/offset9_model.o" > "$out/host_symbols.txt"
"$out/host" > "$out/host.log" 2>&1
grep -E '^HOST (CONV:|COMMAND:|ALTERNATING:|RESULT:)' "$out/host.log"

verilator --lint-only --top-module NPU -Wall "${rtl[@]}" > "$out/lint.log" 2>&1
verilator --binary --timing -Ihw/sim -j "${JOBS:-4}" -Wno-fatal --top-module npu_lab2_tb \
    --Mdir "$out/obj" hw/sim/npu_lab2_tb.sv "${rtl[@]}" > "$out/rtl_build.log" 2>&1
for seed in 20261014 7; do
    "$out/obj/Vnpu_lab2_tb" +seed="$seed" +offset9_only +fail_fast > "$out/rtl_$seed.log" 2>&1
    grep -E '^(OFFSET9_|RESULT:)' "$out/rtl_$seed.log"
done
"$out/obj/Vnpu_lab2_tb" +seed=20261014 +fail_fast > "$out/rtl_full.log" 2>&1
grep -E '^(OFFSET9_RESULT:|ERROR_COVERAGE:|COVERAGE:|RESULT:)' "$out/rtl_full.log"
iverilog -g2012 -Ihw/sim -Wall -s npu_lab2_tb -o "$out/offset9.vvp" \
    hw/sim/npu_lab2_tb.sv "${rtl[@]}" > "$out/iverilog_build.log" 2>&1
vvp -n "$out/offset9.vvp" +seed=20261014 +offset9_only +fail_fast > "$out/rtl_iverilog.log" 2>&1
grep -E '^(OFFSET9_|RESULT:)' "$out/rtl_iverilog.log"

# Positive grep follows types and assignments end-to-end; negative grep tests
# direct scalar int8 narrowing of the offset/128, not int8 tensor pointers or
# the final clamped output cast. The plain API's int8 argument is intentional.
path_files=("$conv" sw/project/lab2_api.h sw/project/lab2_api.cc sw/app/cfu.h
            sw/tests/offset9_model.cc "${rtl[@]}")
{
    printf '%s\n' '$ grep -nE input_offset|offset_r|configured_bits|engine_bits|signed_bits|cfu_raw_op|CfuWord PATH_FILES'
    grep -nE 'input_offset|offset_r|configured_bits|engine_bits|signed_bits|cfu_raw_op|CfuWord' "${path_files[@]}"
    pattern='((static|reinterpret)_cast\s*<\s*(u?int8_t|signed char|char)\s*>|\(\s*(u?int8_t|signed char|char)\s*\))\s*\(?\s*(input_offset|128)\b|\b(u?int8_t|signed char|char)\s+\w+\s*=\s*128\b'
    printf '$ grep -nP %q PATH_FILES\n' "$pattern"
    if grep -nP "$pattern" "${path_files[@]}"; then
        echo 'GREP RESULT: failures=1 (offset/128 narrowed)'; exit 1
    else
        rc=$?; [[ $rc == 1 ]] || exit "$rc"
    fi
    # An int8 scalar offset inside conv.h would break even if it used an alias.
    if grep -nP '\b(u?int8_t|signed char|char)\s+\w*offset\b' "$conv"; then exit 1; else [[ $? == 1 ]]; fi
    echo 'GREP RESULT: offset/128 scalar-int8 narrowing matches=0 failures=0'
} > "$out/grep_path.log"
tail -1 "$out/grep_path.log"

# Optional ISA evidence; default location is this workspace's installed toolchain.
prefix=${RISCV_PREFIX:-/opt/riscv/bin/riscv32-unknown-elf}
if [[ -x "$prefix-g++" && -x "$prefix-objdump" ]]; then
    "$prefix-g++" -std=c++11 -O3 -march=rv32im -mabi=ilp32 -ffunction-sections \
        -Isw/project -Isw/app -c sw/project/lab2_api.cc -o "$out/lab2_api_rv32.o"
    "$prefix-objdump" -drC "$out/lab2_api_rv32.o" > "$out/lab2_api_rv32.asm"
fi
sha256sum "${path_files[@]}" hw/sim/npu_lab2_tb.sv hw/sim/npu_axi_trace_scoreboard.svh hw/sim/run_offset9_tests.sh \
    sw/tests/offset9_host_test.cc sw/tests/offset9_ref.cc sw/tests/offset9_model.h \
    "$r/$upstream" > "$out/source_sha256.txt"
echo "OFFSET9 ACCEPTANCE: failures=0; evidence: $out"
