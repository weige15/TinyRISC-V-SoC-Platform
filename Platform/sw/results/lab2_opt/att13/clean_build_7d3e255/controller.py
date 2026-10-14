#!/usr/bin/env python3
"""Capture one normal stock make-run session; never program or reset the CPU.

Requires a prepared output folder containing successful live JTAG/program logs,
source_sha256.json, bitstream.sha256, and the inspected main.bin/main.elf.
No source edits or temporary menu entries. Waits for the user's CPU RESET after
printing the actual UART Listening line. This is a diagnostic baseline driver,
not proof of a final committed clean build or the complete GATE.
"""
import hashlib
import json
import os
from pathlib import Path
import pty
import re
import select
import shlex
import signal
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
REPO = ROOT / "TinyRISC-V-SoC-Platform"
PLATFORM = REPO / "Platform"
sys.path.insert(0, str(PLATFORM / "sw"))
import upload
from serial.tools import list_ports


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    out = Path(sys.argv[1]).resolve()
    require("PREFLIGHT_PASS" in (out / "jtag_preflight.log").read_text(), "live JTAG preflight missing")
    programmed = (out / "program.log").read_text()
    require("PROGRAM_EXIT=0" in programmed and "End of startup status: HIGH" in programmed,
            "successful programming evidence missing")
    bit_hash = (out / "bitstream.sha256").read_text().split()[0]
    require(digest(PLATFORM / "build/out.bit") == bit_hash, "bitstream changed")
    sources = json.loads((out / "source_sha256.json").read_text())

    def check_sources():
        for name, want in sources.items():
            require(digest(REPO / name) == want, "source changed: " + name)

    check_sources()
    ports = [p for p in list_ports.comports()
             if p.vid == 0x0403 and p.pid == 0x6010 and
             p.serial_number == "210319BE7776" and
             p.location and p.location.endswith(":1.1")]
    require(len(ports) == 1, "expected one actual Digilent UART interface")
    port = ports[0].device
    require(upload.find_port() == port, "stock uploader selects another UART")
    expected_bin = digest(out / "main.bin")
    expected_elf = digest(out / "main.elf")
    raw = (out / "board_console.raw").open("xb", buffering=0)
    events = (out / "events.jsonl").open("x", buffering=1)
    buffer = bytearray()

    def event(name, **fields):
        record = dict(event=name, time=time.time(), raw_offset=len(buffer), **fields)
        events.write(json.dumps(record) + "\n")
        print(name, fields, flush=True)

    master, slave = pty.openpty()
    command = ("source " + shlex.quote(str(ROOT / "env.sh")) +
               " >/dev/null && PYTHONUNBUFFERED=1 make -C Platform run "
               "MODEL_FILE=ds_cnn_stream_fe.tflite MODEL_PROFILE=ds_cnn_stream_fe APP_DEFINES=")
    child = subprocess.Popen(["bash", "-c", command], cwd=REPO,
                             stdin=slave, stdout=slave, stderr=slave,
                             start_new_session=True)
    os.close(slave)
    event("START", command=command, pid=child.pid, port=port,
          bitstream_sha256=bit_hash, image_sha256=expected_bin, elf_sha256=expected_elf)

    def pump():
        ready, _, _ = select.select([master], [], [], 0.2)
        if ready:
            try:
                data = os.read(master, 65536)
            except OSError:
                data = b""
            if data:
                raw.write(data)
                buffer.extend(data)
                return
        require(child.poll() is None, "make/upload process exited unexpectedly")

    def wait_for(pattern, start, timeout):
        regex = re.compile(pattern)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            match = regex.search(bytes(buffer[start:]))
            if match:
                return match
            pump()
        raise TimeoutError("No " + repr(pattern) + " within " + str(timeout) + " seconds")

    def stage(name, key, prompt, expected=(), timeout=180):
        start = len(buffer)
        event("SEND", stage=name, key=key)
        os.write(master, key.encode("ascii"))
        wait_for(re.escape(prompt.encode("ascii")), start, timeout)
        text = bytes(buffer[start:]).decode("utf-8", "replace").replace("\r", "")
        require("[FAIL]" not in text and not re.search(r"\bWA\b", text), name + " failed in UART")
        for token in expected:
            require(token in text, name + " missing actual UART result: " + token)
        event("RETURN", stage=name, start=start, end=len(buffer))

    try:
        found = wait_for(rb"Listening on (/dev/ttyUSB[0-9]+) \.\.\.", 0, 180)
        require(found.group(1).decode() == port, "wrong actual listener")
        require(digest(PLATFORM / "build/sw/main.bin") == expected_bin, "make run changed BIN")
        require(digest(PLATFORM / "build/sw/main.elf") == expected_elf, "make run changed ELF")
        event("IMAGE_VERIFIED", actual_bin_sha256=expected_bin, actual_elf_sha256=expected_elf)
        check = subprocess.run([sys.executable, str(ROOT / "scratch/one_boot_acceptance_fixed/check_command_boot_init.py"),
                                str(PLATFORM / "build/sw/main.elf")], text=True,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (out / "actual_boot_init.log").write_text(check.stdout)
        require(check.returncode == 0, "actual ELF command state is not startup initialized")
        event("LISTENING", message=found.group(0).decode())
        print(found.group(0).decode(), flush=True)
        print("Waiting for user CPU RESET / bootloader SYNC; no automatic reset is issued.", flush=True)
        wait_for(rb"SYNC", 0, 1800)
        event("SYNC_OBSERVED")
        wait_for(rb"main> ", 0, 180)
        event("BOOT_MENU")
        stage("enter_lab", "l", "lab2> ")
        stage("set", "t", "lab2> ", ("Pass 3/3",))
        stage("random", "r", "lab2> ", ("Pass 100/100",))
        stage("conv", "c", "lab2> ", tuple(f"[PASS] Testcase{i}, Output Correct" for i in range(1, 4)), 600)
        stage("exit_lab", "x", "main> ")
        stage("all_labels", "t", "main> ",
              tuple(f"[Status] label{i}: ALL 12 GOLDEN OUTPUTS PASS." for i in (0, 1, 6, 8, 11)), 1800)
        stage("reenter_lab", "l", "lab2> ")
        stage("random_after_model", "r", "lab2> ", ("Pass 100/100",))
        check_sources()
        text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", buffer.decode("utf-8", "replace")).replace("\r", "")
        (out / "uart.log").write_text(text)
        event("SEQUENCE_RETURNED")
        os.write(master, b"\x03")  # exits host keyboard terminal, NOT CPU RESET
        try:
            child.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass
        event("CAPTURE_END", process_status=child.poll())
    except Exception as exc:
        event("BLOCKED", reason=str(exc))
        raise
    finally:
        if child.poll() is None:
            os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
        os.close(master)
        raw.close()
        events.close()


if __name__ == "__main__":
    main()
