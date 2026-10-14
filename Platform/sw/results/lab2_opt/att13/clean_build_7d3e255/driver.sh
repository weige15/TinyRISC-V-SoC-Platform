#!/usr/bin/env bash
# Fresh hardware build/program at a pinned commit. No CPU reset is issued.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
repo="$root/TinyRISC-V-SoC-Platform"
out=$(realpath "$1")
commit=$2
source "$root/env.sh" >/dev/null
trap 'status=$?; printf "%s\n" "$status" > "$out/clean_prog.exit"' EXIT
[[ $(git -C "$repo" rev-parse HEAD) == "$commit" ]]
git -C "$repo" diff --exit-code HEAD -- Platform/hw Platform/sw/project Platform/sw/tflm_patches
lsusb | grep '0403:6010' > "$out/usb_preflight.log"
compgen -G '/dev/ttyUSB*' > "$out/uart_devices.log"
vivado -mode batch -source "$root/scratch/one_boot_acceptance_fixed/preflight.tcl" -notrace -nolog -nojournal > "$out/jtag_preflight.log" 2>&1
grep '^PREFLIGHT_' "$out/jtag_preflight.log"
grep -q '^PREFLIGHT_PASS' "$out/jtag_preflight.log"
printf '%s\n' "$commit" > "$out/commit.txt"
printf 'make -C Platform all_clean\nmake -C Platform prog\n' > "$out/commands.log"
(cd "$repo" && make -C Platform all_clean) > "$out/all_clean.log" 2>&1
[[ ! -e "$repo/Platform/build" ]]
printf 'PASS: Platform/build absent after all_clean\n' > "$out/clean_directory_check.log"
(cd "$repo" && make -C Platform prog) > "$out/program.log" 2>&1
printf 'PROGRAM_EXIT=0\n' >> "$out/program.log"
grep -q 'End of startup status: HIGH' "$out/program.log"
if grep -q 'Skipping Full Synthesis' "$out/program.log"; then
    echo 'ERROR: unexpectedly reused a bitstream after all_clean' >&2
    exit 1
fi
[[ $(git -C "$repo" rev-parse HEAD) == "$commit" ]]
git -C "$repo" diff --exit-code HEAD -- Platform/hw Platform/sw/project Platform/sw/tflm_patches
sha256sum "$repo/Platform/build/out.bit" > "$out/bitstream.sha256"
cp -p "$repo/Platform/build/out.bit" "$out/out.bit"
cp -p "$repo/Platform/build/reports/post_route_utilization_npu.rpt" "$out/"
cp -p "$repo/Platform/build/reports/post_route_timing_summary.rpt" "$out/"
printf 'PASS: committed all_clean -> prog completed without source changes.\n'
