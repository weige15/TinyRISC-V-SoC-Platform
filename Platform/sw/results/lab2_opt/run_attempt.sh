#!/bin/bash
# usage: run_attempt.sh OUTDIR   -- rebuild bitstream+sw, program, run board GATE, summarize
set -uo pipefail
ROOT=/home/kuotzuwei15/NNchip
D=$1; mkdir -p "$D"
P=$ROOT/TinyRISC-V-SoC-Platform/Platform
source "$ROOT/env.sh" >/dev/null 2>&1
cd "$ROOT/TinyRISC-V-SoC-Platform"
tmux kill-session -t lab2opt 2>/dev/null
make -C Platform prog > "$D/hw_build.log" 2>&1; echo "BUILD_EXIT=$?" >> "$D/hw_build.log"
grep -q 'BUILD_EXIT=0' "$D/hw_build.log" || { echo "BUILD FAILED"; tail -30 "$D/hw_build.log"; exit 1; }
grep -q 'End of startup status: HIGH' "$D/hw_build.log" || { echo "PROGRAM FAILED"; exit 1; }
cp $P/build/reports/post_route_utilization_npu.rpt "$D/"
gzip -c $P/build/reports/post_route_timing_summary.rpt > "$D/post_route_timing_summary.rpt.gz"
make -C Platform sw_build > "$D/sw_build.log" 2>&1 || { echo "SW BUILD FAILED"; exit 1; }
sha256sum $P/build/out.bit $P/build/sw/main.bin > "$D/board_image_sha256.txt"
tmux new-session -d -s lab2opt -x 200 -y 50 "bash -c 'source $ROOT/env.sh >/dev/null 2>&1; cd $ROOT/TinyRISC-V-SoC-Platform; make -C Platform -o kill_server run 2>&1 | tee $D/board.raw; sleep 99999'"
wait_for() {
 for ((i=0;i<$3;i++)); do
  n=$(grep -c "$1" "$D/board.raw" 2>/dev/null || true)
  if (( ${n:-0} > $2 )); then return 0; fi
  sleep 1
 done
 echo "TIMEOUT waiting for $1"; tmux kill-session -t lab2opt; exit 1
}
wait_for 'main> ' 0 300
tmux send-keys -t lab2opt l; wait_for 'lab2> ' 0 20
for key in t r c; do
 n=$(grep -c 'lab2> ' "$D/board.raw"); tmux send-keys -t lab2opt "$key"; wait_for 'lab2> ' "$n" 300
done
n=$(grep -c 'main> ' "$D/board.raw"); tmux send-keys -t lab2opt x; wait_for 'main> ' "$n" 20
tmux send-keys -t lab2opt t; wait_for 'Total for' 0 1200
sleep 3
tmux kill-session -t lab2opt; killall -9 vivado hw_server 2>/dev/null
python3 - "$D" <<'PY'
import re,sys,gzip
d=sys.argv[1]
s=open(d+'/board.raw',errors='replace').read()
s=re.sub(r'\x1b\[[0-9;]*[A-Za-z]','',s); s=re.sub(r'Progress: \[[^]]*\] [0-9]*% \([0-9/]* bytes\)','',s)
open(d+'/board_uart.log','w').write(s)
cyc=[int(x) for x in re.findall(r'^Cycles: (\d+)',s,re.M)][:5]
labels=re.findall(r'\[Status\] (label\d+): ALL 12 GOLDEN OUTPUTS PASS',s)
out=[]
out.append('set: '+str(re.findall(r'Pass \d+/3\b',s))+' random: '+str(re.findall(r'Pass \d+/100',s)))
out.append('conv PASS lines: %d, FAIL lines: %d'%(len(re.findall(r'\[PASS\] Testcase',s)),len(re.findall(r'\[FAIL\]',s))))
out.append('labels all-pass: %s'%labels)
out.append('cycles: %s'%cyc)
if cyc: out.append('total %d avg %.1f'%(sum(cyc),sum(cyc)/len(cyc)))
u=open(d+'/post_route_utilization_npu.rpt').read()
m=re.search(r'\|\s*inst\s*\|\s*NPU\s*\|\s*(\d+)\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*(\d+)\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|\s*(\d+)',u)
out.append('NPU LUT %s FF %s RAMB36 %s RAMB18 %s DSP %s'%m.groups())
t=gzip.open(d+'/post_route_timing_summary.rpt.gz','rt').read()
m=re.search(r'WNS\(ns\).*?\n.*?\n\s*(-?[\d.]+)',t); out.append('WNS %s'%m.group(1))
out.append('timing met: %s'%('All user specified timing constraints are met' in t))
open(d+'/summary.txt','w').write('\n'.join(out)+'\n'); print('\n'.join(out))
PY
