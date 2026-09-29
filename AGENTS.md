# Agent instructions

## FPGA access and hardware verification

- Do not assume the Arty A7 is accessible from the agent environment. Before programming or claiming a hardware test result, check that the Digilent FTDI device is visible (`lsusb`), that the USB-UART port exists (`/dev/ttyUSB*`), and that Vivado can see a JTAG target. A Windows `usbipd` state of `Attached` is not sufficient by itself; confirm the device and serial port are visible inside the Linux/WSL environment running the commands.
- If JTAG or UART is unavailable, do not keep retrying or substitute simulation/build results for FPGA verification. Ask the user to connect/forward the board and report which required hardware tests remain unverified.
- The shared FTDI interface usually appears as `/dev/ttyUSB1` on this setup, but detect the actual port rather than hard-coding it. The upload script opens the UART at 115200 baud and waits for the bootloader's `SYNC` before uploading the application.
- Run `make -C Platform run` from the repository root (after sourcing `./env.sh` when needed). Wait for `Listening on /dev/ttyUSB...` before asking the user to press the board's CPU RESET button. On the Arty A7 this is the upper-right RESET button, not the upper-left PROG button. The bootloader sends `SYNC` after reset; capture the UART output and upload/menu results.
- `make -C Platform prog` may report that it is skipping full synthesis when `build/out.bit` is considered up to date. It still programs that existing bitstream. If the bitstream may be stale and the UART never reports `SYNC`, stop the listener and force a clean hardware build/program with:
  ```bash
  make -C Platform all_clean
  make -C Platform prog
  ```
  Then run `make -C Platform run`, wait for the listener, and press CPU RESET. Do not use the FPGA PROG button as a substitute for this sequence.
- A visible clock-heartbeat LED, USB enumeration, successful JTAG programming, or successful local build is not proof that the application booted. Treat missing `SYNC` or missing menu output as a hardware/boot blocker and request the relevant terminal output rather than claiming success.
- For accelerator changes, report FPGA test results only when the actual board menu output has been observed. Keep required misaligned/aligned AXI, SIMD MAC, and Basic Convolution tests distinct; local simulations and repository validation are useful but do not replace them.
