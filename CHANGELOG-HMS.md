# HMS Changelog

HMS-specific work on top of the OpenHW CV32E40X core.

Versions are tagged `hms-v*` to keep them distinct from the upstream core
tags (`0.1.0` through `0.10.0`), which belong to OpenHW and stop at the fork
point.

## hms-v0.3.2 - 2026-09-13

- Added an SCU35 FPGA project at `fpga/scu35/`, targeting the AMD Spartan
  UltraScale+ XCSU35P on the SCU35 evaluation board. Same RTL as the
  Genesys-2 build, retargeted to `xcsu35p-sbvb625-2-e` with the board's
  100 MHz LVDS clock downconverted to 50 MHz
- Post-route utilisation: 3906 LUT (24%), 2294 FF (7%), 16 BRAM (33%),
  3 DSP (6%). 45 DSP slices and 144 KB of BRAM remain free
- Timing at 50 MHz: WNS +8.197 ns over 7360 endpoints, critical path
  11.694 ns, of which 8.06 ns is routing. Slower than the Genesys-2's
  9.899 ns, but measured with large slack, so this is an upper bound on
  delay rather than the achievable floor
- Known incomplete: `fpga/scu35/constraints/` has no XDC, so `write_bitstream`
  fails on DRC NSTD-1 and UCIO-1. Pin locations, I/O standards, and an
  explicit `create_clock` are still to be written

## hms-v0.3.1 - 2026-09-10

- Linked the SEGGER build into a single memory region: replaced the stock
  `flash_placement_riscv.xml`, which assumes separate flash and RAM and
  forced the 64 KB BRAM into a fixed 32/32 split, with SEGGER's
  `sram_placement_riscv.xml`. Memory Segments is now
  `RAM1 RWX 0x80000000 0x00010000`, matching `link.ld` in the GNU flow, so
  the linker packs code and data freely
- Added `create_clock` for `clk_p_i` to `Genesys-2-Master.xdc`. Without it
  2293 register pins had no clock and 7253 endpoints were unconstrained,
  and Vivado reported all constraints met having analysed 26 flip-flops
- Measured the achievable frequency with timing actually enforced: 200 MHz
  fails at WNS -4.931 ns, 100 MHz at -0.426 ns, and the critical path is
  10.1 ns through the EX-to-ID forwarding network and the DSP48 multiplier.
  Settled at 50 MHz

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
