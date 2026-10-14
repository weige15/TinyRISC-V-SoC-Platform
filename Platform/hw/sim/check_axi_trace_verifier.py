#!/usr/bin/env python3
"""Non-vacuity controls for the independent trace replayer (no RTL involved)."""
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
import tempfile
from verify_axi_trace import verify

trace = '''E,0,1,3,1
C,1,1,60000001,60001002,1,0,1,0,0
A,1,1,60000000,1
A,1,1,60001000,1
R,1,1,2,60000000,01010101,0,1,1,0,1
R,2,1,3,60001000,02020202,0,1,1,1,1
M,1,4,1,60000001,01,1,2,0
M,1,4,2,60001002,02,2,3,0
D,1,5,0,2
'''
log = '''AXI_SCOREBOARD: R_beats=2 MAC_bytes=2 stream_bytes=2 fast_bytes=0 violations=0
RESULT: PASS=1 FAIL=0 cases=1
'''
mutations = {
    'wrong-address': ('2,60000000,01010101', '2,60000004,01010101'),
    'wrong-byte': ('60000001,01,1,2,0', '60000001,ff,1,2,0'),
    'not-earlier-R': ('M,1,4,1,', 'M,1,2,1,'),
    'old-epoch': ('01010101,0,1,1,0,1', '01010101,0,1,1,0,0'),
    'error-R': ('01010101,0,1,1,0,1', '01010101,2,1,1,0,1'),
    'discarded-R': ('01010101,0,1,1,0,1', '01010101,0,1,0,0,1'),
    'no-R-source': ('60000001,01,1,2,0', '60000001,01,99,2,0'),
    'duplicate-byte': ('M,1,4,1,60000001,01,1,2,0\n', 'M,1,4,1,60000001,01,1,2,0\n' * 2),
    'omitted-byte': ('M,1,4,1,60000001,01,1,2,0\n', ''),
    'incomplete-call': ('D,1,5,0,2\n', ''),
}
with tempfile.TemporaryDirectory(prefix='trace-verifier-') as temp:
    folder = Path(temp)
    logfile, tracefile = folder / 'sim.log', folder / 'trace.csv'
    logfile.write_text(log)
    tracefile.write_text(trace)
    with redirect_stdout(StringIO()):
        verify(tracefile, logfile)
    for name, (old, new) in mutations.items():
        assert trace.count(old) == 1, name
        tracefile.write_text(trace.replace(old, new))
        try:
            with redirect_stdout(StringIO()):
                verify(tracefile, logfile)
        except AssertionError:
            print(f'TRACE VERIFIER: {name} REJECTED')
        else:
            raise AssertionError(f'verifier accepted {name}')
print(f'TRACE VERIFIER CONTROLS: valid=1 rejected={len(mutations)} survived=0')
