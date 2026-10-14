#!/usr/bin/env python3
"""Red controls for the SAME error matrix/checkers, plus an X-result control.

Only copies under the output directory are changed. A compile failure, timeout,
or unrelated assertion does NOT count as detecting a mutation.
"""
from pathlib import Path
import subprocess
import sys

from verify_lab2_error_log import verify

hw = Path(__file__).resolve().parents[1]
out = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/lab2-error-mutations").resolve()
out.mkdir(parents=True, exist_ok=True)
sources = {
    "top": (hw / "srcs/NPU.v").read_text(),
    "engine": (hw / "srcs/npu_burst_dot_product.v").read_text(),
    "tb": (hw / "sim/npu_lab2_tb.sv").read_text(),
}
# name, [(file, unique old, replacement)], expected first assertion substring
mutations = [
    ("unmodified-control", [], None),
    ("dont-care-error-result", [("top", "NPU_out <= burst_dot_product_result;",
      "NPU_out <= (burst_dot_product_status != 0) ? 32'hxxxx_xxxx : burst_dot_product_result;")], None),
    ("drop-rready-on-error", [("engine", "assign m_axi_rready = active && (q_count != 0);",
      "assign m_axi_rready = active && (q_count != 0) && (status == 0);")], "RREADY unusable before RLAST"),
    ("ignore-rvalid", [("engine", "wire r_fire = m_axi_rvalid && m_axi_rready;",
      "wire r_fire = m_axi_rready;")], "RREADY unusable before RLAST"),
    ("done-before-affected-rlast", [("top", "if (burst_dot_product_done) begin",
      "if (burst_dot_product_done || (burst_dot_product_status != 0)) begin")], "NPU_done before affected RLAST"),
    ("done-before-other-rlast", [("top", "if (burst_dot_product_done) begin",
      "if (burst_dot_product_done || ((burst_dot_product_status != 0) && M_AXI_RVALID && M_AXI_RREADY && M_AXI_RLAST)) begin")],
      "NPU_done before other requested bursts drained"),
    ("sticky-error-done", [("top", "STATE_IDLE: begin\n                    NPU_done <= 1'b0;",
      "STATE_IDLE: begin\n                    NPU_done <= NPU_done && (burst_dot_product_status != 0);")],
      "NPU_done repeated or wider than one cycle"),
    ("delayed-second-done", [
      ("top", "reg [3:0] state_r;", "reg [3:0] state_r;\n    reg [7:0] delayed_error_done = 0;\n"
       "    always @(posedge clk) if (!rst_n) delayed_error_done <= 0;\n"
       "    else delayed_error_done <= {delayed_error_done[6:0],\n"
       "        burst_dot_product_done && (burst_dot_product_status != 0)};"),
      ("top", "STATE_IDLE: begin\n                    NPU_done <= 1'b0;",
       "STATE_IDLE: begin\n                    NPU_done <= delayed_error_done[7];")],
      "NPU_done repeated or wider than one cycle"),
    ("new-unaccepted-ar-after-error", [
      ("engine", "!failed && can_schedule", "can_schedule"),
      ("tb", "arready <= (($urandom % 100) < ar_ready_pct);",
       "arready <= !ew_failed && (($urandom % 100) < ar_ready_pct);")],
      "new AR offer after error ARREADY=0"),
    # The public-handshake provenance gate now rejects these before the
    # older storage-enable assertion; keep the expected failure specific.
    ("ignore-decerr", [("engine", "wire bad_resp = r_fire && (m_axi_rresp != 0);",
      "wire bad_resp = r_fire && (m_axi_rresp == 2'b10);")], "AXI_PROVENANCE: DUT used non-AXI/error data"),
    ("write-after-error", [("engine", "r_fire && !discard && !failed;",
      "r_fire && !discard && !error_now;")], "AXI_PROVENANCE: DUT used non-AXI/error data"),
    # Bypass the real RAM write conditions WITHOUT changing emit_valid or the
    # monitored write-enable wires. Only the physical-memory guards catch these.
    ("input-write-past-b", [("engine", "if (emit_valid && !is_filter)",
      "if ((emit_valid || (r_fire && discard)) && !is_filter)")], "physical input_buffer changed after beat B"),
    ("replica-write-past-b", [("engine", "if (in_rep_we && input_received[2:0] == bk)",
      "if ((in_rep_we || (r_fire && discard && !is_filter)) && input_received[2:0] == bk)")],
      "physical input replica changed after beat B"),
    ("filter-write-past-b", [("engine", "if (fc_we && fc_wrel[2:0] == bk)",
      "if ((fc_we || (r_fire && discard && is_filter)) && fc_wrel[2:0] == bk)")],
      "physical filter cache changed after beat B"),
    ("stale-operands-after-error", [("engine", "reuse_enable && !reuse_clear && (status == 0) &&",
      "reuse_enable && !reuse_clear &&")], "AR #0 got"),
    ("wrong-recovery-result", [("top", "NPU_out <= burst_dot_product_result;",
      "NPU_out <= burst_dot_product_result ^ ((burst_dot_product_status == 0) ? 32'd1 : 32'd0);")],
      "/recovery p1="),
]

rejected = controls = 0
for name, changes, marker in mutations:
    folder = out / name
    folder.mkdir(exist_ok=True)
    texts = dict(sources)
    for target, old, new in changes:
        if texts[target].count(old) != 1:
            raise RuntimeError(f"{name}: mutation needs one exact anchor: {old}")
        texts[target] = texts[target].replace(old, new)
    paths = []
    for target, text in texts.items():
        path = folder / f"{target}.sv"
        path.write_text(text)
        paths.append(str(path))
    binary = folder / "test.vvp"
    with (folder / "build.log").open("w") as log:
        subprocess.run(["iverilog", "-g2012", "-I", str(hw / "sim"), "-s", "npu_lab2_tb", "-o", str(binary), *paths],
                       check=True, stdout=log, stderr=subprocess.STDOUT, timeout=60)
    result = subprocess.run(["vvp", "-n", str(binary), "+errors_only", "+fail_fast", "+seed=20261007"],
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
    logfile = folder / "run.log"
    logfile.write_text(result.stdout)
    if marker is None:
        if result.returncode != 0:
            raise RuntimeError(f"control failed: {logfile}")
        verify(logfile)
        controls += 1
        print(f"CONTROL PASS: {name}", flush=True)
    else:
        failures = [line for line in result.stdout.splitlines() if "[FAIL]" in line]
        if result.returncode == 0 or not failures or marker not in failures[0]:
            raise RuntimeError(f"survived or failed for unrelated reason: {name}: {logfile}\n{result.stdout[-2500:]}")
        rejected += 1
        print(f"REJECTED {name}: {failures[0]}", flush=True)
print(f"ERROR MUTATION RESULT: controls={controls} rejected={rejected} survived=0")
