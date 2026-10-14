#!/usr/bin/env bash
# Build real API instrumentation separately from the patched kernel and oracle.
# Usage from repo root: bash Platform/sw/tests/run_mac_routing_tests.sh [out]
set -euo pipefail
out=$(realpath -m "${1:-/tmp/lab2-mac-routing}")
cd "$(dirname "$0")/../.."
mkdir -p "$out"
r=../tflite-micro
flags=(-std=c++17 -O2 -g -Wall -Wextra -Werror -fsanitize=address,undefined
       -fno-sanitize-recover=all -DTF_LITE_STATIC_MEMORY -Isw/project -Isw/app
       -I"$r" -I"$r/third_party/gemmlowp" -I"$r/third_party/flatbuffers/include"
       -I"$r/third_party/ruy")
# Namespace isolation is in the test; the oracle source itself stays upstream.
git -C .. diff --exit-code HEAD -- "tflite-micro/tensorflow/lite/kernels/internal/reference/integer_ops/conv.h"
for file in sw/tests/offset9_ref.cc sw/tests/mac_routing_ref16.cc sw/tests/offset9_model.cc; do
  g++ "${flags[@]}" -c "$file" -o "$out/$(basename "${file%.cc}").o"
done > "$out/build.log" 2>&1
g++ "${flags[@]}" -finstrument-functions -c sw/project/lab2_api.cc -o "$out/lab2_api.o" >> "$out/build.log" 2>&1
g++ "${flags[@]}" -c sw/tests/mac_routing_host_test.cc -o "$out/mac_routing_host_test.o" >> "$out/build.log" 2>&1
g++ "${flags[@]}" "$out/mac_routing_host_test.o" "$out/offset9_ref.o" "$out/mac_routing_ref16.o" "$out/offset9_model.o" "$out/lab2_api.o" -o "$out/host"
"$out/host" > "$out/host.log" 2>&1
grep '^ROUTING ' "$out/host.log"
nm -C "$out/lab2_api.o" > "$out/api_symbols.txt"
sha256sum sw/project/lab2_api.{cc,h} sw/tflm_patches/tensorflow/lite/kernels/internal/reference/integer_ops/conv.h sw/tests/mac_routing* sw/tests/offset9_model.{cc,h} > "$out/source_sha256.txt"
