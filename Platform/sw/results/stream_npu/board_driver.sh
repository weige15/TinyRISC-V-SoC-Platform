#!/bin/bash
set -euo pipefail
ROOT=/home/kuotzuwei15/NNchip
D="$ROOT/scratch/stream_npu"
source "$ROOT/env.sh" >/dev/null 2>&1
cd "$ROOT/TinyRISC-V-SoC-Platform"
# The concurrently running make prog must have actually rebuilt/programmed.
for ((i=0;i<1800;i++)); do
 grep -q 'BUILD_EXIT=' "$D/build3.log" && break
 sleep 1
done
grep -q 'BUILD_EXIT=0' "$D/build3.log"
grep -q 'End of startup status: HIGH' "$D/build3.log"
lsusb > "$D/board_preflight.log"
ls -l /dev/ttyUSB* >> "$D/board_preflight.log"
grep -q '0403:6010' "$D/board_preflight.log"
python3 -c "import sys; sys.path.insert(0, 'Platform/sw'); import upload; upload.SERVER_TCL_PATH='$D/server.tcl'; upload.SERVER_LOG_PATH='$D/server.log'; upload.start_vivado_server()"
python3 - <<'PY' >> "$D/board_preflight.log"
import socket
s=socket.create_connection(('localhost',3122),2)
s.sendall(b'puts $::client_sock "TARGETS=[get_hw_targets] DEVICES=[get_hw_devices]"\n')
print(s.recv(8192).decode())
PY
sha256sum Platform/build/out.bit Platform/build/sw/main.bin > "$D/board_image_sha256.txt"
tmux new-session -d -s stream_npu -x 200 -y 50 "bash -c 'set -o pipefail; source $ROOT/env.sh >/dev/null 2>&1; cd $ROOT/TinyRISC-V-SoC-Platform; make -C Platform -o kill_server run 2>&1 | tee $D/board.raw; sleep 99999'"
wait_for() {
 for ((i=0;i<$3;i++)); do
  n=$(grep -c "$1" "$D/board.raw" 2>/dev/null || true)
  if (( ${n:-0} > $2 )); then return 0; fi
  sleep 1
 done
 echo "TIMEOUT waiting for $1; no hardware result claimed"; exit 1
}
wait_for 'Listening on' 0 150
echo 'UART listening; waiting for bootloader SYNC/menu (CPU RESET if needed).'
wait_for 'main> ' 0 90
tmux send-keys -t stream_npu l
wait_for 'lab2> ' 0 20
for key in t r c; do
 n=$(grep -c 'lab2> ' "$D/board.raw")
 tmux send-keys -t stream_npu "$key"
 wait_for 'lab2> ' "$n" 180
done
n=$(grep -c 'main> ' "$D/board.raw")
tmux send-keys -t stream_npu x
wait_for 'main> ' "$n" 20
tmux send-keys -t stream_npu t
wait_for 'Total for' 0 900
sleep 3
python3 - "$D/board.raw" "$D/board.log" <<'PY'
import re,sys
s=open(sys.argv[1]).read()
s=re.sub(r'\x1b\[[0-9;]*[A-Za-z]', '', s)
s=re.sub(r'Progress: \[[^]]*\] [0-9]*% \([0-9/]* bytes\)', '', s)
open(sys.argv[2],'w').write(s)
PY
tmux kill-session -t stream_npu
echo 'Board run complete'
