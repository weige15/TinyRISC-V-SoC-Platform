#!/usr/bin/env python3
"""Replay the public R-beat log against every actual MAC operand byte.

No DUT memory, mem[] oracle, or expected numeric results are used here.
A missing trace/summary, duplicate byte, old epoch, wrong address/value,
non-OKAY beat, same/future-cycle R, or incomplete call is a hard failure.
Usage: verify_axi_trace.py TRACE.csv[.gz] SIM.log
"""
import gzip
from pathlib import Path
import re
import sys


def verify(trace, log):
    beats = {}  # sequence -> immutable, actually accepted R evidence
    calls = {}
    r_count = m_count = fast_count = done_count = 0
    epoch = 0
    opener = gzip.open if str(trace).endswith('.gz') else open
    with opener(trace, 'rt') as source:
        for line_no, line in enumerate(source, 1):
            if line.startswith('#'):
                continue
            row = line.strip().split(',')
            kind = row[0]
            try:
                if kind == 'E':
                    _, cycle, epoch_s, f7, on = row
                    epoch = int(epoch_s)
                    assert int(f7) in (3, 4) and int(on) in (0, 1)
                elif kind == 'C':
                    _, cid, cycle, a, b, n, off, ce, hit, fast = row
                    cid = int(cid)
                    assert cid not in calls and int(ce) == epoch
                    calls[cid] = dict(a=int(a, 16), b=int(b, 16), n=int(n),
                                      epoch=epoch, hit=int(hit), fast=int(fast),
                                      cycle=int(cycle), seen=(set(), set()), done=False)
                elif kind == 'R':
                    _, seq, cid, cyc, addr, data, resp, last, good, side, be = row
                    seq, cid = int(seq), int(cid)
                    r_count += 1
                    assert seq == r_count and cid in calls and not calls[cid]['done']
                    assert int(be) == calls[cid]['epoch']
                    beats[seq] = dict(call=cid, cycle=int(cyc), address=int(addr, 16),
                                      data=int(data, 16), resp=int(resp), good=int(good), epoch=int(be))
                elif kind == 'M':
                    _, cid, cyc, side, addr, data, seq, rcycle, local = row
                    cid, side, seq = int(cid), int(side), int(seq)
                    addr, data, cyc, local = int(addr, 16), int(data, 16), int(cyc), int(local)
                    call, beat = calls[cid], beats[seq]
                    assert side in (1, 2) and not call['done']
                    assert beat['good'] == 1 and beat['resp'] == 0
                    assert beat['address'] == addr & ~3
                    assert ((beat['data'] >> (8 * (addr & 3))) & 255) == data
                    assert beat['cycle'] == int(rcycle) < cyc
                    assert beat['epoch'] == call['epoch']
                    if (side == 1 and not call['hit']) or (side == 2 and not local):
                        assert beat['call'] == cid and beat['cycle'] >= call['cycle']
                    index = addr - call['a' if side == 1 else 'b']
                    assert 0 <= index < call['n'] and index not in call['seen'][side-1]
                    call['seen'][side-1].add(index)
                    m_count += 1
                    fast_count += local
                elif kind == 'D':
                    _, cid, cycle, failed, byte_count = row
                    call = calls[int(cid)]
                    assert not call['done']
                    seen = sum(map(len, call['seen']))
                    assert int(byte_count) == seen
                    if not int(failed):
                        assert all(len(s) == call['n'] for s in call['seen'])
                    call['done'] = True
                    done_count += 1
                else:
                    assert kind == 'A', f'unknown record {kind}'
            except (AssertionError, KeyError, ValueError) as exc:
                raise AssertionError(f'{trace}:{line_no}: invalid provenance: {line.strip()}') from exc
    text = Path(log).read_text()
    summary = re.search(r'AXI_SCOREBOARD: R_beats=(\d+) MAC_bytes=(\d+) stream_bytes=(\d+) fast_bytes=(\d+) violations=0\b', text)
    assert summary, 'missing zero-violation scoreboard summary'
    assert tuple(map(int, summary.groups())) == (r_count, m_count, m_count-fast_count, fast_count)
    assert r_count and m_count and done_count == len(calls) and all(c['done'] for c in calls.values())
    assert re.search(r'RESULT: PASS=\d+ FAIL=0 cases=' + str(done_count) + r'\b', text)
    print(f'TRACE_REPLAY: R_beats={r_count} MAC_bytes={m_count} calls={done_count} violations=0')


if __name__ == '__main__':
    verify(*sys.argv[1:])
