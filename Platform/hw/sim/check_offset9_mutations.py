#!/usr/bin/env python3
"""Negative controls, using temporary copies only. Run after run_offset9_tests.sh.
Usage: python3 Platform/hw/sim/check_offset9_mutations.py RESULT_DIRECTORY
A compilation error or timeout is NOT a detected functional mutation.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

platform = Path(__file__).resolve().parents[2]
out = Path(sys.argv[1]).resolve()
logs = out / "mutations"
logs.mkdir(exist_ok=True)

def change(source, old, new):
    assert source.count(old) == 1, f"mutation anchor not unique: {old}"
    return source.replace(old, new)

def run(cmd, log, expected_failure=False):
    with log.open("w") as f:
        p = subprocess.run(cmd, cwd=platform, stdout=f, stderr=subprocess.STDOUT, timeout=180)
    text = log.read_text()
    if expected_failure:
        assert p.returncode == 1 and ("HOST FAIL:" in text or "[FAIL]" in text), (cmd, p.returncode, text[-500:])
    else:
        assert p.returncode == 0, (cmd, text[-2000:])
    return text

flags = ["g++", "-std=c++17", "-O2", "-g", "-fsanitize=address,undefined",
         "-fno-sanitize-recover=all", "-Isw/project", "-Isw/app", "-Isw/tests"]
with tempfile.TemporaryDirectory(prefix="offset9-mutations-") as tmp:
    tmp = Path(tmp)
    model = (platform / "sw/tests/offset9_model.cc").read_text()
    api = (platform / "sw/project/lab2_api.cc").read_text()
    host_mutants = [
        ("model-truncate-offset8", "offset9_model", change(model, "signed_bits(stats.engine_bits, 9)", "signed_bits(stats.engine_bits, 8)")),
        ("api-truncate-offset8", "lab2_api", change(api, "cfu_raw_op(4, 5, N, command)", "cfu_raw_op(4, 5, N, static_cast<int8_t>(command))")),
        ("api-drop-disarm", "lab2_api", change(api, "    cfu_raw_op(4, 3, 0, 0);", "    // mutant: disarm omitted")),
    ]
    for name, obj, source in host_mutants:
        cc, oo, exe = tmp / (name + ".cc"), tmp / (name + ".o"), tmp / name
        cc.write_text(source)
        run(flags + ["-c", str(cc), "-o", str(oo)], logs / (name + "-build.log"))
        objects = [str(oo if part == obj else out / (part + ".o"))
                   for part in ("offset9_host_test", "offset9_ref", "offset9_model", "lab2_api")]
        run(flags + objects + ["-o", str(exe)], logs / (name + "-link.log"))
        run([str(exe)], logs / (name + ".log"), True)
        print(f"MUTATION: {name} DETECTED (functional assertions)")

    top = (platform / "hw/srcs/NPU.v").read_text()
    rtl_mutants = [
        ("rtl-truncate-set9", change(top, "burst_dot_product_offset_r <= rs2_i[8:0];", "burst_dot_product_offset_r <= {rs2_i[7], rs2_i[7:0]};")),
        ("rtl-sticky-set8", change(top, "burst_dot_product_offset_r <= {rs2_i[7], rs2_i[7:0]};", "burst_dot_product_offset_r <= burst_dot_product_offset_r;")),
    ]
    for name, source in rtl_mutants:
        rtl, exe = tmp / (name + ".v"), tmp / (name + ".vvp")
        rtl.write_text(source)
        run(["iverilog", "-g2012", "-Ihw/sim", "-s", "npu_lab2_tb", "-o", str(exe),
             "hw/sim/npu_lab2_tb.sv", str(rtl), "hw/srcs/npu_burst_dot_product.v"],
            logs / (name + "-build.log"))
        run(["vvp", "-n", str(exe), "+seed=20261014", "+offset9_only", "+fail_fast"],
            logs / (name + ".log"), True)
        print(f"MUTATION: {name} DETECTED (functional assertions)")
print("MUTATION RESULT: detected=5 escaped=0")
