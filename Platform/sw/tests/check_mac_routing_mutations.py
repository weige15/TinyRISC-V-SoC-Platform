#!/usr/bin/env python3
"""Negative controls after run_mac_routing_tests.sh. Never edits production.
Compilation errors, crashes and timeouts are NOT accepted as detections.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

platform = Path(__file__).resolve().parents[2]
out = Path(sys.argv[1]).resolve()
logs = out / "mutations"
logs.mkdir(exist_ok=True)
r = platform.parent / "tflite-micro"
flags = ["g++", "-std=c++17", "-O2", "-g", "-fsanitize=address,undefined",
         "-fno-sanitize-recover=all", "-DTF_LITE_STATIC_MEMORY", "-Isw/project",
         "-Isw/app", "-Isw/tests", f"-I{r}", f"-I{r}/third_party/gemmlowp",
         f"-I{r}/third_party/flatbuffers/include", f"-I{r}/third_party/ruy"]

def change(text, old, new):
    assert text.count(old) == 1, f"nonunique/missing anchor: {old}"
    return text.replace(old, new)

def run(cmd, log, marker=None):
    p = subprocess.run(cmd, cwd=platform, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, text=True, timeout=120)
    log.write_text(p.stdout)
    if marker:
        assert p.returncode == 1 and marker in p.stdout, (cmd, p.returncode, p.stdout[-1500:])
    else:
        assert p.returncode == 0, (cmd, p.returncode, p.stdout[-1500:])

conv = (platform / "sw/tflm_patches/tensorflow/lite/kernels/internal/reference/integer_ops/conv.h").read_text()
api = (platform / "sw/project/lab2_api.cc").read_text()
call = """    acc += static_cast<uint32_t>(lab2_prepared_mac(
        input + done, filter + done, input_offset, count, precleaned));"""
bypass = """    cfu_raw_op(4, 5, count, input_offset);
    acc += static_cast<uint32_t>(cfu_raw_op(4, 1, input + done, filter + done));"""
consume = """    const uint32_t command = g_conv_command;
    g_conv_command = 0;
    if (N == 0) return 0;"""
mutants = [
    ("bypass-real-entry", "conv", '#include "cfu.h"\n' + change(conv, call, bypass), "definition not entered"),
    ("drop-scope-exit", "conv", change(conv, "~ConvMacScope() { lab2_conv_reset(); }", "~ConvMacScope() {}"), "hardware reuse left armed"),
    ("skip-split-term", "conv", change(conv, "    done += count;\n  }\n  return static_cast<int32_t>(acc);", "    done += count + 1;\n  }\n  return static_cast<int32_t>(acc);"), "channel products skipped/duplicated"),
    ("skip-empty-consumption", "api", change(api, consume, "    if (N == 0) return 0;\n    const uint32_t command = g_conv_command;\n    g_conv_command = 0;"), "software preparation fields not all zero"),
    ("clear-only-prepared-bit", "api", change(api, consume, "    const uint32_t command = g_conv_command;\n    g_conv_command &= ~kPrepared;\n    if (N == 0) return 0;"), "nonidle real API returns"),
]
with tempfile.TemporaryDirectory(prefix="mac-routing-mutations-") as work:
    work = Path(work)
    for name, kind, source, marker in mutants:
        path = work / (name + (".h" if kind == "conv" else ".cc"))
        path.write_text(source)
        obj, exe = work / (name + ".o"), work / name
        if kind == "conv":
            cmd = flags + [f'-DMAC_ROUTING_CONV="{path}"', "-c", "sw/tests/mac_routing_host_test.cc", "-o", str(obj)]
        else:
            cmd = flags + ["-finstrument-functions", "-c", str(path), "-o", str(obj)]
        run(cmd, logs / (name + "-build.log"))
        objects = [str(obj if (kind == "conv" and part == "mac_routing_host_test") or
                       (kind == "api" and part == "lab2_api") else out / (part + ".o"))
                   for part in ("mac_routing_host_test", "lab2_api", "offset9_model", "offset9_ref", "mac_routing_ref16")]
        run(flags + objects + ["-o", str(exe)], logs / (name + "-link.log"))
        run([str(exe)], logs / (name + ".log"), marker)
        print(f"ROUTING MUTATION: {name} DETECTED (functional assertions)")
print(f"ROUTING MUTATION RESULT: detected={len(mutants)} escaped=0")
