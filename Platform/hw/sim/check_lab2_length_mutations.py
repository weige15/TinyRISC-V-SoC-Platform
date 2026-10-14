#!/usr/bin/env python3
"""Negative controls: the length/offset gates must reject deliberately bad copies.

Usage: python3 Platform/hw/sim/check_lab2_length_mutations.py [output-directory]
Production files are never modified. Each run builds fresh copies in its output.
"""
from pathlib import Path
import re
import subprocess
import sys

platform = Path(__file__).resolve().parents[2]
out = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/lab2-length-mutations").resolve()
out.mkdir(parents=True, exist_ok=True)
npu = platform / "hw/srcs/NPU.v"
engine = platform / "hw/srcs/npu_burst_dot_product.v"
api = platform / "sw/project/lab2_api.cc"


def mutate(source, old, new, destination):
    text = source.read_text()
    if text.count(old) != 1:
        raise RuntimeError(f"mutation must have one exact anchor: {source}: {old}")
    destination.write_text(text.replace(old, new))
    return destination


def reject(name, build, run, marker):
    subprocess.run(build, check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    result = subprocess.run(run, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (out / f"{name}.log").write_text(result.stdout)
    count = re.search(marker + r"(\d+)", result.stdout)
    if result.returncode == 0 or not count or int(count[1]) == 0:
        raise RuntimeError(f"negative control survived or failed for an unrelated reason: {name}")
    print(f"REJECTED {name}: {marker}{count[1]}")


for name, source, old, new in [
    ("top-length-8bit", npu, "reg [31:0] burst_dot_product_length_r;",
     "reg [7:0] burst_dot_product_length_r;"),
    ("beat-index-8bit", engine, "reg [8:0] beat_index;", "reg [7:0] beat_index;"),
    ("cover-span-32bit", engine, "reg [32:0] span;", "reg [31:0] span;"),
]:
    mutant = mutate(source, old, new, out / f"{name}.v")
    binary = out / f"{name}.vvp"
    files = [mutant if source == npu else npu, mutant if source == engine else engine]
    reject(name, ["iverilog", "-g2012", "-s", "npu_lab2_counters_tb", "-o", str(binary),
                  str(platform / "hw/sim/npu_lab2_counters_tb.sv"), *map(str, files)],
           ["vvp", "-n", str(binary)], "failures=")

for name, new in [
    ("host-length-8bit", "cfu_raw_op(4, 0, N & 255, input_offset);"),
    ("host-missing-offset", "cfu_raw_op(4, 0, N, 0);"),
    ("host-wrong-filter-pointer", "cfu_raw_op(4, 0, N, input_offset);"),
]:
    old = "cfu_raw_op(4, 0, N, input_offset);"
    if name == "host-wrong-filter-pointer":
        old = "cfu_raw_op(4, 1, ptr1, ptr2)"
        new = "cfu_raw_op(4, 1, ptr1, ptr2 + 1)"
    mutant = mutate(api, old, new, out / f"{name}.cc")
    binary = out / name
    reject(name, ["g++", "-std=c++17", "-O2", "-I" + str(platform / "sw/project"),
                  "-I" + str(platform / "sw/app"), str(mutant),
                  str(platform / "sw/tests/lab2_length_host_test.cc"), "-o", str(binary)],
           [str(binary)], "mismatches=")
print("MUTATION RESULT: rejected=6 survived=0")
