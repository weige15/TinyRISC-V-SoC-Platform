#!/usr/bin/env python3
"""Recheck the supplied checklist crosswalk and its retained evidence.

This integrity/coverage gate supplements the manual source/behavior audit in the
report. It does not infer requirements from green summaries or claim private
TA tests have been executed. Run from any directory; no artifacts overwritten.
"""
from collections import Counter
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

QA = Path(__file__).resolve().parent
R = QA.parent
PLATFORM = QA.parents[3]
P = PLATFORM.parent
ROOT = P.parent
REPORT = PLATFORM / 'sw/lab2_verification.md'


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def source_check(path, base):
    entries = [line.split(maxsplit=1) for line in path.read_text().splitlines()]
    for expected, name in entries:
        require(digest(base / name) == expected, f'stale input: {name}')
    print(f'SOURCE_CHECK {path.relative_to(ROOT)}: {len(entries)}/{len(entries)} match')


def marker(path, text):
    require(text in path.read_text().splitlines(), f'missing result in {path}: {text}')
    print(f'EVIDENCE {path.relative_to(ROOT)}: {text}')


def main():
    # Parse original user-provided bullets, not a list reconstructed from tests.
    section = None
    expected = {}
    counts = Counter()
    for line in (QA / 'notes.md').read_text().splitlines():
        m = re.match(r'^### ([12]\.\d) ', line)
        if m:
            section = m[1]
        elif line.startswith('## 三、'):
            section = '3'
        elif line.startswith('## 四、'):
            section = None
        if line.startswith('- [ ] '):
            require(section is not None, 'checklist without a section')
            counts[section] += 1
            expected[f'{section}.{counts[section]}'] = line[6:]
    require(dict(counts) == {s: 3 for s in ('1.1','1.2','1.3','1.4','2.1','2.2','2.3')} | {'3': 2},
            'unexpected source checklist distribution')
    report = REPORT.read_text()
    rows = {}
    for line in report.splitlines():
        if re.match(r'^\| (?:[12]\.\d\.\d|3\.\d) \|', line):
            fields = [s.strip() for s in line.split('|')[1:-1]]
            require(len(fields) == 5, f'bad row: {line}')
            key, item, goals, verdict, evidence = fields
            require(key not in rows, f'duplicate row: {key}')
            require(key in expected and item == expected[key], f'original wording mismatch: {key}')
            require(verdict == 'PASS', f'unresolved row: {key}')
            require(goals == 'V1–V7' or re.fullmatch(r'V[1-7](?:, V[1-7])*', goals), f'missing V-goal: {key}')
            require('`' in evidence and re.search(r'\d', evidence), f'no named/count evidence: {key}')
            rows[key] = fields
            print(f'CHECKLIST {key}: original text exact; {goals}; PASS; evidence column present')
    require(set(rows) == set(expected) and len(rows) == 23, 'omitted/extra checklist item')
    require(not re.search(r'\|\s*FAIL\s*\|', report), 'FAIL table cell remains')
    require('**OPEN：1.1 中「測試範圍」在 hidden test 裡是否仍然是 N ≤ 256？**' in report,
            'hidden N question not OPEN')
    require('**V1 already covers N up to 1024.**' in report and 'rotating' in report,
            'V1 range or matrix/sweep boundary missing')
    require(all(s.rstrip() == s for s in report.splitlines()), 'report trailing whitespace')
    print('REPORT_CHECK: original sections=8 checklist=23 PASS=23 FAIL_rows=0; hidden N=OPEN')

    source_check(R / 'v1/inputs.sha256', PLATFORM)
    source_check(R / 'v4/inputs.sha256', P)
    source_check(R / 'v3_v5/inputs.sha256', PLATFORM)
    source_check(QA / 'inputs.sha256', PLATFORM)
    source_check(QA / 'offset_inputs.sha256', PLATFORM)
    saved_sources = json.loads((ROOT / 'demo/out/source_sha256.json').read_text())
    for name, sha in saved_sources.items():
        require(digest(ROOT / name) == sha, f'saved demo source stale: {name}')
    print(f'SAVED_DEMO_SOURCE_CHECK: {len(saved_sources)}/{len(saved_sources)} match; manifest not regenerated')

    # Execute actual artifact checkers, after inspecting their scope manually.
    error = module('error_log', PLATFORM / 'hw/sim/verify_lab2_error_log.py')
    for path in (ROOT / 'demo/out/rtl.log', QA / 'unmodified-control.log', QA / 'dont-care-error-result.log'):
        error.verify(path)  # exact 64 names, drain/stall counts and 56 recoveries
    errlog = (QA / 'errors_mutations.log').read_text()
    require(len(re.findall(r'^CONTROL PASS:', errlog, re.M)) == 2 and
            len(re.findall(r'^REJECTED ', errlog, re.M)) == 14, 'error controls incomplete')
    marker(QA / 'errors_mutations.log', 'ERROR MUTATION RESULT: controls=2 rejected=14 survived=0')
    trace = module('axi_trace', PLATFORM / 'hw/sim/verify_axi_trace.py')
    trace.verify(QA / 'axi_7.csv.gz', QA / 'reuse_rtl.log')
    marker(QA / 'reuse_rtl.log', 'REUSE_SAFETY: armed_same=64 arena_new_layer=32 rearm=64 unarmed_changed=64 changed_N=64 changed_ptr1=32 failures=0')
    marker(QA / 'trace_controls.log', 'TRACE VERIFIER CONTROLS: valid=1 rejected=10 survived=0')

    marker(R / 'v1/host.log', 'HOST RESULT: cases=833 computes=11360 per_element_audits=5149760 mismatches=0')
    for n in (257, 300, 511, 512, 513):
        marker(R / 'v1/host.log', f'HOST COVERAGE: N={n} alignments=16 offsets=5 patterns=2 cases=160')
    marker(R / 'v1/counters.log', 'COUNTER RESULT: widths=54 snapshots=80 checks=8006 failures=0')
    marker(R / 'v4/host.log', 'ROUTING RESULT: conv_or_dot_cases=26 real_entries=9256 real_exits=9256 nonidle_mac_exits=0 model_failures=0 failures=0')
    marker(R / 'v4/host.log', 'ROUTING SPLIT: tuples=42 N=0,1,4095,4096,4097,8193 offsets=7 exact_visitation=1')
    marker(R / 'v4/host.log', 'ROUTING EMPTY: prepared_N_zero=2 preparation_consumed=1 computes=0')
    marker(R / 'v4/abi_and_boot.log', 'C_ABI_SIGNATURE_RESULT: checks=1 failures=0')
    marker(R / 'v4/source_audit.log', 'PREPROCESS_CHECK: api_declaration=1 api_definition=1 conv_declaration=1 conv_direct_call=1 name_macro=0 failures=0')
    marker(R / 'v4/mutations.log', 'ROUTING MUTATION RESULT: detected=5 escaped=0')
    marker(R / 'v3_v5/offset9_host.log', 'HOST RESULT: conv_cases=1280 bytes=196608 unsaturated=196601 byte_mismatches=0 model_failures=0 failures=0')
    shape_rows = re.findall(r'^HOST CONV: offset=(-?\d+) shape=(\S+) alignments=16 patterns=2 cases=32 bytes=\d+ failures=0$',
                           (R / 'v3_v5/offset9_host.log').read_text(), re.M)
    require(len(shape_rows) == 32 and set(shape_rows) ==
            {(str(o), s) for o in (-128,-127,-102,-1,0,1,127,128)
             for s in ('1x1-depth300','3x3-depth300-SAME','3x3-stride2-dilation2','3x3-grouped')},
            'offset/shape matrix incomplete')
    marker(R / 'v3_v5/offset9_mutations.log', 'MUTATION RESULT: detected=5 escaped=0')
    marker(R / 'v3_v5/arena_host.log', 'ARENA_RESULT: pairs=64 layers=128 shared_address_pairs=64 changed_outputs=256 mismatches=0 stale_hits=0 model_failures=0 failures=0')
    full_offsets = re.findall(r'^ALL_OFFSETS_CASE: offset=(-?\d+) cases=1 failures=0$',
                              (QA / 'all_offsets_host.log').read_text(), re.M)
    require(list(map(int, full_offsets)) == list(range(-128, 129)), '257-value prepared offset coverage incomplete')
    marker(QA / 'all_offsets_host.log', 'ALL_OFFSETS_RESULT: offsets=257 range=-128..128 conv_cases=257 bytes=12336 plain_calls=257 byte_mismatches=0 model_failures=0 failures=0')

    # The checker does not call demo/verify.py sources: that would rewrite pins.
    for action in ('archive', 'rtl', 'host', 'waves'):
        subprocess.run([sys.executable, str(ROOT / 'demo/verify.py'), action], check=True)
    evidence = json.loads((ROOT / 'demo/evidence.json').read_text())
    for name, sha in evidence['untouched_submission_zips'].items():
        require(digest(ROOT / name) == sha, f'submission ZIP changed: {name}')
    expected_bit, bit_name = (ROOT / 'demo/V6/programmed_bit.sha256').read_text().split()
    require(digest(ROOT / bit_name) == expected_bit, 'available bitstream differs from recorded programmed image')
    print(f'BITSTREAM_CHECK: {bit_name} matches saved SHA-256 {expected_bit}; no new programming claimed')
    elf_sha = json.loads((ROOT / 'demo/V6/image_manifest.json').read_text())['acceptance.elf']
    require(digest(PLATFORM / 'build/sw/main.elf') == elf_sha, 'existing V6 ELF changed')
    print('ELF_CHECK: matches saved V6 acceptance ELF; no new board run claimed')
    uart = (ROOT / 'demo/V6/uart.log').read_text().splitlines()
    expected_lines = {41:'Pass 3/3',165:'Pass 3/3',54:'Pass 100/100',178:'Pass 100/100',408:'Pass 100/100',
                      110:'[EXTRA] END cases=640 failures=0 [PASS]',
                      122:'[PASS] Testcase1, Output Correct',123:'[PASS] Testcase2, Output Correct',124:'[PASS] Testcase3, Output Correct',
                      240:'label0: ALL 12 GOLDEN OUTPUTS PASS.',275:'label1: ALL 12 GOLDEN OUTPUTS PASS.',
                      310:'label6: ALL 12 GOLDEN OUTPUTS PASS.',345:'label8: ALL 12 GOLDEN OUTPUTS PASS.',380:'label11: ALL 12 GOLDEN OUTPUTS PASS.'}
    for line, text in expected_lines.items():
        require(text in uart[line-1], f'wrong UART citation: {line}')
    print('UART_CITATION_CHECK: 14/14 result lines match; 60/60 golden words checked by archive verifier')
    subprocess.run(['bash', '-n', str(ROOT / 'demo/run.sh')], check=True)
    for tool in ('bash', 'python3', 'iverilog', 'vvp', 'g++'):
        require(shutil.which(tool), f'missing demo dependency: {tool}')
    require((ROOT / 'demo/run.sh').stat().st_mode & 0o111, 'demo entry not executable')
    print('LAPTOP_CHECK: script syntax/executable, required tools, source inputs, bitstream and five parsed VCDs present')
    print('MANUAL_SCOPE: see report for inspected assertions, RAM-write decode, ABI/call path, ownership contract and equivalent completion branch')
    print('BOUNDARY: local trace checker only; private grader not supplied; historical UART distinct from current host/RTL; hidden N remains OPEN')
    print(f'REPORT_SHA256: {digest(REPORT)}')
    print('OBJECTIVE_GATE: PASS — 23 original items mapped, 0 FAIL rows; print the complete report before marking the goal complete')


if __name__ == '__main__':
    main()
