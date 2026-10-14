#!/usr/bin/env bash
# Resume only unfinished software targets after the harness command timeout.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
out=$(realpath "$1")
repo="$root/TinyRISC-V-SoC-Platform"
source "$root/env.sh" >/dev/null
trap 'status=$?; printf "%s\n" "$status" > "$out/sw_resume.exit"' EXIT
make -C "$repo/Platform" -j2 sw_build MODEL_FILE=ds_cnn_stream_fe.tflite MODEL_PROFILE=ds_cnn_stream_fe APP_DEFINES= > "$out/sw_build_resume.log" 2>&1
printf 'SW_BUILD_EXIT=0\n' >> "$out/sw_build_resume.log"
cp "$repo/Platform/build/sw/main.elf" "$repo/Platform/build/sw/main.bin" "$out/"
python3 "$root/scratch/one_boot_acceptance_fixed/check_command_boot_init.py" "$out/main.elf" > "$out/boot_init.log"
riscv64-unknown-elf-nm -C "$out/main.elf" > "$out/symbols.txt"
if grep -E 'OperatorCycleProfiler|one_boot_boundary_test|cfu_software|HwSimdMacSoftware| [Tt] hw_simd_mac\.' "$out/symbols.txt"; then exit 1; fi
sha256sum "$out/main.elf" "$out/main.bin" > "$out/image.sha256"
riscv64-unknown-elf-objdump -d --disassemble=lab2_prepared_mac "$out/main.elf" > "$out/prepared_adapter.dis"
python3 - "$root" "$out" <<'PY'
from pathlib import Path
import hashlib,json,sys
root,out=map(Path,sys.argv[1:]); repo=root/'TinyRISC-V-SoC-Platform'
for name in ['main.bin','main.elf']:
 print(name,'identical to row 13:',(out/name).read_bytes()==(root/'scratch/lab2_finalization/channel_single'/name).read_bytes())
m=json.loads((out/'build_inputs_sha256.json').read_text())
changed=[s for s,h in m.items() if hashlib.sha256((repo/s).read_bytes()).hexdigest()!=h]
assert not changed,changed
print('Full source/config input hashes unchanged:',len(m),'/',len(m))
print((out/'boot_init.log').read_text())
PY
