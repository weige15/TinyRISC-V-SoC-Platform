#!/usr/bin/env python3
"""Negative controls in disposable copies; compiler failures/timeouts are NOT passes."""
from pathlib import Path
import subprocess
import sys

hw = Path(__file__).resolve().parents[1]
out = Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=True)
engine = (hw / 'srcs/npu_burst_dot_product.v').read_text()
mutations = {
    'cpu-register-preload': [
        ('input_buffer[input_received[IB-1:0]] <= m_axi_rdata;',
         'input_buffer[input_received[IB-1:0]] <= input_address;')],
    'corrupt-input-replica': [
        ('in_rep[input_received[9:3]] <= m_axi_rdata;',
         "in_rep[input_received[9:3]] <= m_axi_rdata ^ 32'd1;")],
    'corrupt-filter-cache': [
        ('fc_mem[fc_wrel[14:3]] <= m_axi_rdata;',
         "fc_mem[fc_wrel[14:3]] <= m_axi_rdata ^ 32'd1;")],
    'accept-without-rvalid': [
        ('wire r_fire = m_axi_rvalid && m_axi_rready;', 'wire r_fire = m_axi_rready;')],
    'arm-disarm-keep-copy': [
        ('if (reuse_clear) begin reuse_valid <= 0; fc_valid <= 0; end', '')],
    'ignore-N': [('(byte_length == reuse_length);', "1'b1;")],
    'ignore-ptr1': [('(input_address == reuse_address) &&', '')],
    'reuse-while-unarmed': [
        ('wire reuse_hit = reuse_enable && reuse_valid &&', 'wire reuse_hit = reuse_valid &&'),
        ('reuse_valid <= reuse_enable && !reuse_clear &&', 'reuse_valid <= !reuse_clear &&')],
}
for name, edits in [('control', [])] + list(mutations.items()):
    folder = out / name
    folder.mkdir(exist_ok=True)
    text = engine
    for old, new in edits:
        assert text.count(old) == 1, (name, old)
        text = text.replace(old, new)
    rtl = folder / 'engine.v'
    rtl.write_text(text)
    binary = folder / 'tb.vvp'
    with (folder / 'build.log').open('w') as log:
        subprocess.run(['iverilog', '-g2012', '-I', str(hw / 'sim'), '-s', 'npu_lab2_tb',
                        '-o', str(binary), str(hw / 'sim/npu_lab2_tb.sv'),
                        str(hw / 'srcs/NPU.v'), str(rtl)], check=True,
                       stdout=log, stderr=subprocess.STDOUT, timeout=60)
    result = subprocess.run(['vvp', '-n', str(binary), '+seed=7', '+reuse_safety_only', '+fail_fast'],
                            capture_output=True, text=True, timeout=180)
    log = result.stdout + result.stderr
    (folder / 'run.log').write_text(log)
    if name == 'control':
        assert result.returncode == 0 and 'violations=0' in log and 'FAIL=0' in log, log[-2000:]
        print('PROVENANCE CONTROL: PASS', flush=True)
    else:
        first = next((s for s in log.splitlines() if '[FAIL]' in s), '')
        marker = 'AXI_PROVENANCE:' if name in list(mutations)[:4] else 'AR #0 got'
        assert result.returncode != 0 and marker in first, (name, log[-2000:])
        print(f'PROVENANCE MUTATION: {name} REJECTED {first}', flush=True)
print(f'PROVENANCE MUTATIONS: controls=1 rejected={len(mutations)} survived=0')
