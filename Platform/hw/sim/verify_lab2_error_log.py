#!/usr/bin/env python3
"""Audit every named TA-matrix row, not just a green summary. Accept full logs too."""
from pathlib import Path
import re
import sys

KINDS = (
    "slverr-first", "slverr-middle", "slverr-last", "decerr-middle",
    "early-rlast", "correct-rlast", "rlast-late-1", "rlast-late-5",
)


def verify(path):
    text = Path(path).read_text()
    cases = re.findall(
        r"^ERROR_CASE (\S+) PASS accepted_beats=(\d+) ARs=(\d+) other=(\d+) "
        r"discarded=(\d+) random_stalls=(\d+)$", text, re.M)
    recoveries = re.findall(
        r"^RECOVERY (\S+) PASS exact=(-?\d+) fresh_bytes=(\d+)$", text, re.M)
    expected = {}
    for beats in (16, 256):
        for ptr in (1, 2):
            for profile in ("accepted-other", "held-other"):
                for kind in KINDS:
                    tag = f"ptr{ptr}/{kind}/B{beats}/{profile}"
                    tail = 1 if kind == "rlast-late-1" else 5 if kind == "rlast-late-5" else 0
                    taken = beats // 2 if kind == "early-rlast" else beats + tail
                    normal = kind == "correct-rlast"
                    expected[tag] = (taken, 4 if normal else ptr + 1, 0 if normal else 1, tail)
    assert len(cases) == 64 and len({r[0] for r in cases}) == 64, "missing/duplicate case rows"
    assert {r[0] for r in cases} == set(expected), "wrong case-name matrix"
    for tag, *values in cases:
        assert tuple(map(int, values[:4])) == expected[tag], f"wrong observed drain counts: {tag}"
        assert int(values[4]) > 0, f"no random RVALID stalls: {tag}"
    wanted_recoveries = {t for t in expected if "/correct-rlast/" not in t}
    assert len(recoveries) == 56 and {r[0] for r in recoveries} == wanted_recoveries, "recovery matrix"
    for tag, result, fresh in recoveries:
        beats = int(re.search(r"/B(\d+)/", tag)[1])
        assert int(fresh) == 2 * (4 * beats + 64), f"fresh-data count: {tag}"
        assert -(2**31) <= int(result) < 2**31, f"reference not int32: {tag}"
    assert "ERROR_COVERAGE: cases=64/64 recoveries=56/56 masks=ff,ff,ff,ff,ff,ff,ff,ff" in text
    assert not re.search(r"\[FAIL\]|\bFATAL\b|\bFAIL\b(?![=]0\b)", text), "failure in log"
    result = re.findall(r"^RESULT: PASS=(\d+) FAIL=(\d+) cases=(\d+)$", text, re.M)
    assert len(result) == 1 and int(result[0][0]) > 0 and int(result[0][1]) == 0, "no final zero-failure result"
    assert int(result[0][2]) >= 120, "not all computes ran"
    print(f"AUDIT PASS: {path}: 64 named cases, 56 fresh-data recoveries, 0 failures")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit(f"usage: {sys.argv[0]} LOG [LOG ...]")
    for filename in sys.argv[1:]:
        verify(filename)
