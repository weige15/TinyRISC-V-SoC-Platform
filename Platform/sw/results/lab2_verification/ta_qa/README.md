# TA checklist evidence

`notes.md` is the user-supplied original Q&A text. `previous_blocked_report.md`
and the parent `final_audit.log` preserve the earlier missing-notes stop; neither
is the current verdict. The final crosswalk is `../../../lab2_verification.md`.

`completion_audit.log` is from `audit_report.py`: exact 23-item wording/IDs,
source freshness, complete named error cases, trace replay, all 257 prepared
offsets, other focused test results, saved demo/VCDs and 14 UART citations. This
mechanical gate supplements the manual source/assertion audit in the report;
it does not certify the private TA grader or a new FPGA run.

## Recheck retained evidence (NNchip root)

```sh
PYTHONDONTWRITEBYTECODE=1 python3 \
  TinyRISC-V-SoC-Platform/Platform/sw/results/lab2_verification/ta_qa/audit_report.py
```

## Reproduce the new focused runs

Use a new temporary output directory, not these retained logs. From NNchip:

```bash
set -euo pipefail
repo="$PWD/TinyRISC-V-SoC-Platform"
qa="$repo/Platform/sw/results/lab2_verification/ta_qa"
out=$(mktemp -d /tmp/lab2-ta-recheck.XXXXXX)

# Two passing four-state controls (including X for error NPU_out),
# and 14 mutations rejected by specific functional assertions.
python3 "$repo/Platform/hw/sim/check_lab2_error_mutations.py" \
  "$out/errors" | tee "$out/errors_mutations.log"

cd "$repo/Platform"
iverilog -g2012 -Ihw/sim -Wall -s npu_lab2_tb -o "$out/tb.vvp" \
  hw/sim/npu_lab2_tb.sv hw/srcs/NPU.v hw/srcs/npu_burst_dot_product.v
vvp -n "$out/tb.vvp" +reuse_safety_only +fail_fast +seed=7 \
  +axi_trace="$out/axi_7.csv" > "$out/reuse_rtl.log"
python3 hw/sim/verify_axi_trace.py "$out/axi_7.csv" "$out/reuse_rtl.log"
python3 hw/sim/check_axi_trace_verifier.py

# Every -128..128 offset through the real ConvPerChannel/API/SET9 path.
# Reuses the unchanged upstream-reference test assertions, no golden changes.
r=../tflite-micro
flags=(-std=c++17 -O2 -g -Wall -Wextra -Werror
       -fsanitize=address,undefined -fno-sanitize-recover=all
       -DTF_LITE_STATIC_MEMORY -Isw/project -Isw/app -Isw/tests
       -I"$r" -I"$r/third_party/gemmlowp"
       -I"$r/third_party/flatbuffers/include" -I"$r/third_party/ruy")
g++ "${flags[@]}" "$qa/all_offsets_host.cc" sw/tests/offset9_ref.cc \
  sw/tests/offset9_model.cc sw/project/lab2_api.cc -o "$out/all_offsets"
"$out/all_offsets" | tee "$out/all_offsets_host.log"
```

Expected: error controls=2, rejected=14, survived=0; trace calls=384,
R_beats=194516, MAC_bytes=856256, violations=0; full-offset conv_cases=257,
bytes=12336, plain_calls=257, mismatches/model_failures/failures=0.

No fresh FPGA execution is implied. Saved UART, bitstream and ELF retain their
original V6 provenance. Existing production/test files and archives are unchanged.
