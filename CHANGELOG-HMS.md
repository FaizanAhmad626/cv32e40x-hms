# HMS Changelog

HMS-specific work on top of the OpenHW CV32E40X core.

Versions are tagged `hms-v*` to keep them distinct from the upstream core
tags (`0.1.0` through `0.10.0`), which belong to OpenHW and stop at the fork
point.

## hms-v0.3.0 - 2026-09-09

- Added a SEGGER Embedded Studio build of the LED demo at
  `sw/apps/segger/led_demo`, validated on hardware as an alternative to the
  GNU toolchain
- Matched the SEGGER project to the core: `rv32imc_zicsr_zifencei`, with
  FLASH1 at `0x8000_0000` and RAM1 at `0x8000_8000`, both inside the 64 KB
  BRAM
- Set `.align 7` on `trap_entry` in SEGGER's `riscv_crt0.s`, so the
  CV32E40X `mtvec[6:2]` hardwiring cannot truncate the trap vector
- Rewrote `sw/tools/elf2coe.py` to read ELF program headers directly,
  dropping the objcopy dependency so any toolchain prefix works on any OS

## hms-v0.2.0 - 2026-08-31

- Added `obi_data_interconnect.sv`, owning all address decode and response
  muxing, and separating memory space from peripheral space
- Added `led_peripheral.sv` as a standalone MMIO register at `0x1000_0000`
- Added the bare-metal firmware stack: `crt0.S`, `link.ld`, `main.c`, and
  `sw/tools/elf2coe.py`
- LED MMIO demo running on the Genesys-2

## hms-v0.1.0 - 2026-08-30

- Added the Genesys-2 Vivado project creation script
- Replaced the separate instruction and data memories with a single unified
  BRAM and memory controller, resolving `.rodata` accessibility
- Heartbeat LED blinking on hardware
