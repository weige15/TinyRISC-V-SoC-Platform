#!/usr/bin/env python3
"""Filter-cache negative controls: each mutant of npu_burst_dot_product.v must
fail the unmodified npu_lab2_tb (seed 20261007). Usage: check_fcache_mutations.py OUTDIR"""
import os, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
hw = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
out = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else '/tmp/fc-mutations'); os.makedirs(out, exist_ok=True)
src = open(os.path.join(hw, 'srcs/npu_burst_dot_product.v')).read()
M = {
 'ignore-window': ("wire fc_full_hit = fcache_enable && reuse_hit && fc_valid && fc_inside &&", "wire fc_full_hit = fcache_enable && reuse_hit && fc_valid &&"),
 'keep-on-clear': ("if (reuse_clear) begin reuse_valid <= 0; fc_valid <= 0; end", "if (reuse_clear) begin reuse_valid <= 0; end"),
 'keep-on-error': ("if (status != 0) fc_valid <= 0;", "if (1'b0) fc_valid <= 0;"),
 'no-rotate': ("wire [511:0] fc_rot_sh = fc_dbl >> {s1_rot,5'd0};", "wire [511:0] fc_rot_sh = fc_dbl;"),
 'ignore-alignment': ("(input_address[1:0] == filter_address[1:0]) &&\n                       (byte_length != 0);", "(byte_length != 0);"),
 'no-lane-mask': ("wire [16:0] pv = product(in_q[8*fl +: 8], fc_word_row[8*fl +: 8], offset_r, v);", "wire [16:0] pv = product(in_q[8*fl +: 8], fc_word_row[8*fl +: 8], offset_r, 1'b1);"),
 'append-gap': ("(fw0 <= fc_hi) &&", "(fw0 <= fc_hi + 30'd1) &&"),
 # Each fcache_enable term alone is redundant (the other one, plus "every
 # arm/disarm empties the window", still blocks fast hits under funct7=3), so
 # this mutant removes both.
 'ignore-fc-enable': [("wire fc_can_app = fcache_enable && reuse_enable &&", "wire fc_can_app = reuse_enable &&"),
                      ("wire fc_full_hit = fcache_enable && reuse_hit", "wire fc_full_hit = reuse_hit")],
}
def run(name):
    reps = M[name] if isinstance(M[name], list) else [M[name]]
    mutant = src
    for a, b in reps:
        assert mutant.count(a) == 1, name
        mutant = mutant.replace(a, b)
    d = os.path.join(out, name); os.makedirs(d, exist_ok=True)
    open(os.path.join(d, 'dut.v'), 'w').write(mutant)
    vvp = os.path.join(d, 'tb.vvp')
    subprocess.run(['iverilog', '-g2012', '-s', 'npu_lab2_tb', '-o', vvp, os.path.join(hw, 'sim/npu_lab2_tb.sv'),
                    os.path.join(hw, 'srcs/NPU.v'), os.path.join(d, 'dut.v')], check=True)
    r = subprocess.run(['vvp', '-n', vvp, '+seed=20261007'], capture_output=True, text=True)
    open(os.path.join(d, 'sim.log'), 'w').write(r.stdout + r.stderr)
    res = [l for l in r.stdout.splitlines() if 'RESULT' in l]
    caught = r.returncode != 0 or not res or 'FAIL=0' not in res[-1]
    return name, caught, res[-1] if res else 'no RESULT (fatal/timeout)'
with ThreadPoolExecutor(8) as ex:
    rs = list(ex.map(run, M))
for n, c, r in rs: print(('DETECTED ' if c else 'MISSED   ') + n + ': ' + r)
print('ALL MUTANTS DETECTED' if all(c for _, c, _ in rs) else 'SOME MUTANTS MISSED'); sys.exit(0 if all(c for _, c, _ in rs) else 1)
