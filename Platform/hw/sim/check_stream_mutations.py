#!/usr/bin/env python3
"""Negative controls for the stream assertions; never edits production RTL.
Run from any directory. Logs go to the supplied directory (default /tmp).
"""
import pathlib
import subprocess
import sys
import tempfile

hw = pathlib.Path(__file__).resolve().parents[1]
out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '/tmp/lab2-stream-mutations').resolve()
out.mkdir(parents=True, exist_ok=True)
top = (hw / 'srcs/NPU.v').read_text()
engine = (hw / 'srcs/npu_burst_dot_product.v').read_text()
tb = (hw / 'sim/npu_lab2_tb.sv').read_text()
# A small, fail-fast subset using the SAME scoreboard/assertions as the suite.
tb = tb.replace('if (fail_count <= 40) $display("[FAIL] t=%0t %s", $time, what);',
                '$fatal(1,"[FAIL] t=%0t %s", $time, what);')
tb = tb.replace('        // Latency matrix:', '''        run_case(32'h60000400,32'h60002400,-128,1024,INJ_NONE,0,0,0,"maximal");
        run_case(32'h60000400,32'h60002400,127,64,INJ_BAD_RESP,0,2,3'b100,"error-drain");
        // Latency matrix:''')
tb = tb.replace('        check(latency_rows == 160,"latency matrix incomplete");', '''        check(latency_rows == 160,"latency matrix incomplete");
        $display("CONTROL PASS");
        $finish;''')

mutations = {
    'control': (None, None, None),
    'serialized-ar': ('engine', 'count_after < 2', 'count_after < 1'),
    'short-bursts': ('engine', 'parameter integer MAX_BURST_BEATS = 256',
                     'parameter integer MAX_BURST_BEATS = 128'),
    'extra-done-cycle': ('top', "NPU_out <= burst_dot_product_result;\n                        NPU_done <= 1'b1;\n                        state_r <= STATE_IDLE;",
                         'NPU_out <= burst_dot_product_result;\n                        state_r <= STATE_DONE;'),
    'ignore-rvalid': ('engine', 'wire r_fire = m_axi_rvalid && m_axi_rready;',
                     'wire r_fire = m_axi_rready;'),
    'write-after-error': ('engine', 'r_fire && !discard && !failed;',
                          'r_fire && !discard && !error_now;'),
    'wrong-alignment': ('engine', 'shift_bytes = input_low - filter_low;',
                        "shift_bytes = 2'd0;"),
}
with tempfile.TemporaryDirectory(prefix='lab2-mutations-') as tmp:
    tmp = pathlib.Path(tmp)
    (tmp / 'tb.sv').write_text(tb)
    for name, (target, old, new) in mutations.items():
        sources = {'top': top, 'engine': engine}
        if target:
            assert sources[target].count(old) == 1, name
            sources[target] = sources[target].replace(old, new)
        for key, source in sources.items():
            (tmp / (key + '.v')).write_text(source)
        subprocess.run(['iverilog', '-g2012', '-s', 'npu_lab2_tb', '-o', str(tmp/'run.vvp'),
                        str(tmp/'tb.sv'), str(tmp/'top.v'), str(tmp/'engine.v')], check=True)
        result = subprocess.run(['vvp','-n',str(tmp/'run.vvp')], text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
        (out / (name + '.log')).write_text(result.stdout)
        if name == 'control':
            assert result.returncode == 0 and 'CONTROL PASS' in result.stdout, result.stdout
        else:
            assert result.returncode != 0 and '[FAIL]' in result.stdout, (name, result.stdout)
        print(name + ': ' + ('PASS' if name == 'control' else 'detected'))
print('All six mutations detected; unmodified control passed.')
