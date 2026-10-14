#!/usr/bin/env python3
"""Wait for the pinned clean build, audit it, then capture normal UART.

Never programs or resets anything. A failed build or unexpected source delta
stops the handoff. Original driver exit codes/logs remain untouched.
"""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import time
from check_build_inputs import check
from verify_capture import LIMITS, parse_resources, parse_timing

ROOT = Path(__file__).resolve().parents[2]
REPO = ROOT / 'TinyRISC-V-SoC-Platform'


def main():
    out = Path(sys.argv[1]).resolve()
    deadline = time.monotonic() + 7200
    while not (out / 'clean_prog.exit').exists():
        if time.monotonic() >= deadline:
            raise TimeoutError('Clean build driver did not finish; no retry or UART run attempted')
        time.sleep(5)
    commit = (out / 'commit.txt').read_text().strip()
    assert subprocess.check_output(['git', '-C', str(REPO), 'rev-parse', 'HEAD'], text=True).strip() == commit
    program = (out / 'program.log').read_text()
    assert 'PROGRAM_EXIT=0' in program and 'End of startup status: HIGH' in program
    assert 'Skipping Full Synthesis' not in program
    assert 'PASS: Platform/build absent after all_clean' in (out / 'clean_directory_check.log').read_text()
    audit = check(REPO, commit, json.loads((out / 'build_inputs_sha256.json').read_text()))
    (out / 'post_build_input_audit.json').write_text(json.dumps(audit, indent=2) + '\n')
    assert not audit['unexpected_changes'], audit
    assert (out / 'clean_prog.exit').read_text().strip() in ('0', '1')
    # The original driver requires byte-identical tracked XCI files. Vivado
    # rewrites exactly the recorded generated metadata; retain that failure,
    # then independently audit rather than rewrite the original status.
    if (out / 'clean_prog.exit').read_text().strip() == '1':
        assert len(audit['exact_vivado_generated_xci_changes']) == 5
    for name in ('post_route_utilization_npu.rpt', 'post_route_timing_summary.rpt'):
        src = REPO / 'Platform/build/reports' / name
        assert src.stat().st_mtime > (out / 'clean_directory_check.log').stat().st_mtime
        shutil.copy2(src, out / name)
    bit = REPO / 'Platform/build/out.bit'
    assert bit.stat().st_mtime > (out / 'clean_directory_check.log').stat().st_mtime
    shutil.copy2(bit, out / 'out.bit')
    (out / 'bitstream.sha256').write_text(hashlib.sha256(bit.read_bytes()).hexdigest() + '  ' + str(bit) + '\n')
    resources = parse_resources((out / 'post_route_utilization_npu.rpt').read_text())
    timing = parse_timing((out / 'post_route_timing_summary.rpt').read_text())
    assert all(resources[k] <= v for k, v in LIMITS.items()), resources
    assert timing['WNS_ns'] >= 0 and timing['TNS_ns'] == 0 and timing['setup_failing_endpoints'] == 0, timing
    (out / 'fresh_report_check.json').write_text(json.dumps({'resources': resources, 'timing': timing}, default=float, indent=2) + '\n')
    assert 'SW_BUILD_EXIT=0' in (out / 'sw_build_resume.log').read_text()
    for name in ('main.elf', 'main.bin'):
        assert (out / name).read_bytes() == (REPO / 'Platform/build/sw' / name).read_bytes()
    print('CLEAN_COMMANDS_AND_INPUT_AUDIT_PASS', commit, flush=True)
    print('FRESH_REPORTS', resources, timing, flush=True)
    print('Starting stock make-run capture; CPU RESET is never automatic.', flush=True)
    with (out / 'controller.log').open('x') as log:
        result = subprocess.run([sys.executable, '-u', str(ROOT / 'scratch/lab2_finalization/run_normal_capture.py'), str(out)], stdout=log, stderr=subprocess.STDOUT)
    assert result.returncode == 0, 'Capture failed; inspect controller.log'
    with (out / 'capture_check.json').open('x') as result, (out / 'capture_check.scope').open('x') as scope:
        subprocess.run([sys.executable, str(ROOT / 'scratch/lab2_finalization/verify_capture.py'), '--uart', str(out / 'uart.log'), '--npu-report', str(out / 'post_route_utilization_npu.rpt'), '--timing-report', str(out / 'post_route_timing_summary.rpt')], stdout=result, stderr=scope, check=True)
    print('COMMITTED_CLEAN_CAPTURE_CHECK_PASS (not complete Goal 8/9 or publication)', flush=True)


if __name__ == '__main__':
    main()
