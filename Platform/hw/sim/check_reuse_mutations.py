#!/usr/bin/env python3
"""Negative controls for the ptr1 operand-reuse tests (npu_lab2_tb section 7).
Each mutant breaks one reuse rule in a disposable RTL copy and runs the FULL
unmodified testbench (seed 7); every mutant must report FAIL > 0. Production
sources are never edited. Usage: check_reuse_mutations.py [log-directory]
"""
import concurrent.futures, pathlib, re, subprocess, sys, tempfile

hw = pathlib.Path(__file__).resolve().parents[1]
out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '/tmp/lab2-reuse-mutations').resolve()
out.mkdir(parents=True, exist_ok=True)
top = (hw / 'srcs/NPU.v').read_text()
engine = (hw / 'srcs/npu_burst_dot_product.v').read_text()
tb = hw / 'sim/npu_lab2_tb.sv'
E = 'engine'
mutations = {
    # Reuse while disarmed (copy kept and used regardless of arming).
    'no-enable': [(E, 'wire reuse_hit = reuse_enable && reuse_valid &&', 'wire reuse_hit = reuse_valid &&'),
                  (E, 'reuse_valid <= reuse_enable && !reuse_clear &&', 'reuse_valid <= !reuse_clear &&')],
    'ignore-length': [(E, '(byte_length == reuse_length);', "1'b1;")],
    'ignore-address': [(E, '(input_address == reuse_address) &&', '')],
    'keep-after-error': [(E, '(status == 0) &&\n', '\n')],
    'arm-keeps-copy': [(E, 'if (reuse_clear) begin reuse_valid <= 0; fc_valid <= 0; end', '')],
    'reuse-wrapped-vector': [(E, "({1'b0,input_received} <= BUFFER_WORDS)", "1'b1")],
    'never-reuse': [(E, 'wire reuse_hit = reuse_enable &&', "wire reuse_hit = 1'b0 &&")],
}

def run(name, edits):
    srcs = {'top': top, 'engine': engine}
    for target, old, new in edits:
        assert srcs[target].count(old) == 1, (name, old)
        srcs[target] = srcs[target].replace(old, new)
    with tempfile.TemporaryDirectory(prefix='reuse-mut-') as tmp:
        tmp = pathlib.Path(tmp)
        for k, v in srcs.items():
            (tmp / (k + '.v')).write_text(v)
        subprocess.run(['iverilog', '-g2012', '-I', str(hw / 'sim'), '-s', 'npu_lab2_tb', '-o', str(tmp / 'r.vvp'),
                        str(tb), str(tmp / 'top.v'), str(tmp / 'engine.v')], check=True)
        r = subprocess.run(['vvp', '-n', str(tmp / 'r.vvp'), '+seed=7'], text=True,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=1800)
    (out / (name + '.log')).write_text(r.stdout)
    m = re.search(r'RESULT: PASS=(\d+) FAIL=(\d+)', r.stdout)
    return name, int(m.group(2)) if m else -1

with concurrent.futures.ThreadPoolExecutor(max_workers=len(mutations)) as ex:
    results = list(ex.map(lambda kv: run(*kv), mutations.items()))
ok = True
for name, fails in results:
    print(f'{name}: FAIL={fails} ' + ('detected' if fails != 0 else 'NOT DETECTED'))
    ok &= fails != 0
print('All reuse mutations detected.' if ok else 'Some reuse mutation survived.')
sys.exit(0 if ok else 1)
