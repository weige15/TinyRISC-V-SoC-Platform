#!/usr/bin/env python3
"""Check the saved stream-NPU evidence against this checkout and tested images.
This complements, not replaces, the source/coverage audit in ../stream_npu_audit.md.
"""
from pathlib import Path
import csv
import gzip
import hashlib
import re

here = Path(__file__).resolve().parent
platform = here.parents[2]
hw = platform / 'hw'

def text(name):
    return (here / name).read_text()

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

for line in text('source_sha256.txt').splitlines():
    expected, name = line.split()
    assert digest(hw / name) == expected, ('source changed', name)
assert text('lint.log') == ''
for seed in (20261007, 7, 314511048, 20261013):
    log = text(f'sim_{seed}.log')
    assert re.search(r'RESULT: PASS=[1-9][0-9]* FAIL=0\n', log)
    assert '[FAIL]' not in log
    coverage = re.search(r'error-prefetch=(\d+) error-held-AR=(\d+) full-256-bursts=(\d+)', log)
    assert coverage and all(int(x) > 0 for x in coverage.groups())
    assert re.search(r'4k-boundary-bursts=[1-9][0-9]*', log)
rows = list(csv.DictReader((here / 'latency.csv').open()))
assert len(rows) == 4 * 192
for seed in (20261007, 7, 314511048, 20261013):
    raw_rows = re.findall(r'LATENCY mode=\s*(\w+) N=(\d+) align=(\d)/(\d) cycles=(\d+) beats=(\d+) gaps=(\d+) tail=(\d+) overlap=(-?\d+) offer_overlap=(-?\d+)', text(f'sim_{seed}.log'))
    fields = ('mode','N','ptr1_low','ptr2_low','cycles','beats','gaps','tail','overlap','offer_overlap')
    assert [tuple(r[k] for k in fields) for r in rows if int(r['seed']) == seed] == raw_rows
    matrix = [r for r in rows if int(r['seed']) == seed and r['case'] == 'matrix']
    keys = {(r['mode'], int(r['N']), int(r['ptr1_low']), int(r['ptr2_low'])) for r in matrix}
    assert len(matrix) == 160
    assert keys == {(m,n,a,b) for m in ('zero','random') for n in (1,3,64,256,300)
                    for a in range(4) for b in range(4)}
for r in rows:
    n, a, b = (int(r[k]) for k in ('N','ptr1_low','ptr2_low'))
    beats = (n+a+3)//4 + (n+b+3)//4
    assert int(r['beats']) == beats
    assert int(r['tail']) == 2
    assert int(r['offer_overlap']) >= 0
    if r['mode'] == 'zero':
        assert int(r['cycles']) == beats + 3
        assert int(r['gaps']) == 0 and int(r['overlap']) >= 0
        if n == 300:
            assert int(r['cycles']) <= 170
for name in ('npu_burst_dot_product','npu_misaligned_axi_read','npu_misaligned_axi_write'):
    log = text(name+'.log')
    assert '[FAIL]' not in log and '[PASS] All' in log
assert 'ALL PASS: 2545/2545 cases pass, 1157263 outputs compared, 0 mismatches' in text('host.log')
assert 'NPU product-count check failures: 0' in text('host.log')
assert 'call-pattern failures (conv 0 >729000 or border taps merged): 0' in text('host.log')
assert 'All six mutations detected; unmodified control passed.' in text('mutations.log')

board = text('board_uart.log')
assert '[FAIL]' not in board
assert 'Pass 3/3' in board and 'Pass 100/100' in board
assert set(re.findall(r'^\[PASS\] Testcase([123]), Output Correct', board, re.M)) == {'1','2','3'}
words = re.findall(r'Idx (\d+): Actual=(0x[0-9a-fA-F]+), Golden=(0x[0-9a-fA-F]+) \[PASS\]', board)
assert len(words) == 60
assert [int(x[0]) for x in words] == list(range(12)) * 5
assert all(int(x[1],16) == int(x[2],16) for x in words)
labels = re.findall(r'\[Status\] (label\d+): ALL 12 GOLDEN OUTPUTS PASS\.\s*Cycles: (\d+)', board)
assert len(labels) == 5 and {x[0] for x in labels} == {'label0','label1','label6','label8','label11'}
total = sum(int(x[1]) for x in labels)
assert int(re.search(r'Total for 5 samples:\s*Cycles: (\d+)', board)[1]) == total
average = total / 5
assert average < 1470259856  # previous row, identical firmware
assert average < 4157256607 * 0.8
assert '0403:6010' in text('board_preflight.log')
assert 'xc7a100t_0' in text('board_preflight.log') and '/dev/ttyUSB' in text('board_preflight.log')
assert 'Listening on /dev/ttyUSB' in board and 'SYNC' in board
for line in text('board_image_sha256.txt').splitlines():
    expected, name = line.split()
    assert digest(platform.parent / name) == expected, ('tested image changed', name)

build = text('hw_build.log')
assert 'BUILD_EXIT=0' in build and 'End of startup status: HIGH' in build
assert build.count('NPU utilization cell: MMIO_i/NPU_0/inst') == 1
util = text('post_route_utilization_npu.rpt')
assert util == (platform/'build/reports/post_route_utilization_npu.rpt').read_text()
assert 'Design State : Routed' in util and 'xc7a100tcsg324-1' in util
line = next(x for x in util.splitlines() if re.match(r'^\| inst +\|', x))
cols = [x.strip() for x in line.split('|')]
resources = dict(LUT=int(cols[3]), FF=int(cols[7]), RAMB36=int(cols[8]), RAMB18=int(cols[9]), DSP=int(cols[10]))
for k, limit in dict(LUT=20000, FF=5000, DSP=30, RAMB18=270, RAMB36=135).items():
    assert resources[k] <= limit, (k, resources[k])
with gzip.open(here / 'post_route_timing_summary.rpt.gz', 'rt') as f:
    timing = f.read()
assert timing == (platform/'build/reports/post_route_timing_summary.rpt').read_text()
summary = timing.split('| Design Timing Summary',1)[1]
wns = float(re.search(r'WNS\(ns\)[^\n]*\n[^\n]*\n\s*([+-]?[0-9.]+)',summary)[1])
assert wns >= 0 and 'All user specified timing constraints are met.' in summary
assert re.search(r'#define PLATFORM_CLOCK_HZ\s+50000000u', (platform/'sw/app/platform_config.h').read_text())
assert 'clk_out2_MMIO_clk_wiz_0_1' in timing
bit_time = (platform/'build/out.bit').stat().st_mtime
assert all(p.stat().st_mtime <= bit_time for p in (hw/'srcs').rglob('*') if p.is_file())

latency_doc = (platform/'sw/lab2_latency.md').read_text().split('Limits (Goal 6)')[0]
ranking = [x.split('|') for x in latency_doc.splitlines() if re.match(r'^\| \d+ \|', x)]
assert len(ranking) >= 5
new_average = int(ranking[-1][3].replace('*','').replace(',','').strip())
previous = int(ranking[-2][3].replace('*','').replace(',','').strip())
assert abs(new_average - average) <= 0.5 and new_average < previous
print(f'PASS: all 768 latency rows; four complete RTL seeds; protocol/negative controls; host and actual board acceptance.')
print(f'Board total={total:,}, average={average:,.1f}, previous={previous:,}')
print(f'NPU resources={resources}; overall WNS={wns:+.3f} ns')
print('PASS: source hashes, tested images, fresh routed reports, unchanged 50-MHz clock, lower latency row.')
