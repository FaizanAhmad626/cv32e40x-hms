# HMS Changelog

HMS-specific work on top of the OpenHW CV32E40X core.

Versions are tagged `hms-v*` to keep them distinct from the upstream core
tags (`0.1.0` through `0.10.0`), which belong to OpenHW and stop at the fork
point.

## hms-v0.5.0 - 2026-09-21

- UART running on the SCU35: banner, register readback and echo over the
  FT4232's second serial port (port B) at 115200 8N1, verified with PuTTY.
  The low nibble of each received character is shown on the LEDs
- Rewrote `obi_data_interconnect` as a table-driven N-slave interconnect:
  `NUM_SLAVES`, `SLV_BASE` and `SLV_MASK` parameters, parallel
  `(addr & mask) == base` decode, priority encoder, one-hot `slv_req_o` and
  a broadcast payload. The slave select is registered on `req & gnt`, so
  the response is routed correctly while the next address is on the bus.
  An unmapped address is granted and answered with `err`, so the core
  traps instead of hanging
- Added `uart_peripheral` at `0x1001_0000` in slot 2, built from new
  `uart_tx`, `uart_rx` and two 16-entry `sync_fifo`s. Registers `DATA`,
  `STATUS`, `BAUDDIV` and `IRQ_EN` at `+0x00/04/08/0C`; any other offset
  returns a bus error. `OVERRUN` and `FRAME_ERR` are sticky,
  write-1-to-clear
- `uart_rx` uses a two-flop synchroniser, re-checks the start bit at
  half a bit, and samples mid-bit. `BAUDDIV` resets to 434, which is
  115207 baud from 50 MHz (0.006% error)
- Wrapper: new `UART_BASE`, `UART_BAUD` and `SYS_CLK_HZ` parameters and
  `uart_rx_i`/`uart_tx_o` ports, with the address map expressed as
  `SLV_MEM`/`SLV_LED`/`SLV_UART` table rows over a shared 64 KB
  `SLOT_MASK`
- XDC: `uart_rx_i` on AC6 and `uart_tx_o` on AB6, `LVCMOS33` in bank 65.
  `PULLUP` on RX so a disconnected cable idles high, false paths on both
  pins, and comments on the clock, termination and UART constraints
- Software: polled driver (`uart_init`, `uart_putc`, `uart_puts`,
  `uart_puthex`, `uart_getc`, `uart_try_getc`, `uart_flush`) moved from
  `sw/bsp/scu35` into `sw/apps/uart_demo`, plus a SEGGER build at
  `sw/apps/segger/uart_demo`. `create_project_scu35.tcl` now preloads
  `uart_demo_segger.coe`
- Simulation: added `tb_uart_periph` (peripheral and interconnect alone,
  TX looped back to RX, covering overrun, framing error, interrupts and
  bus errors) and `tb_uart_soc` (whole SoC running `uart_demo`, checked at
  the pins). `tb_uart_soc` passes in Vivado xsim with the real
  `blk_mem_gen_0` and `clk_wiz_0`; about 12 minutes of wall time
- Fixed `tb_uart_soc` for xsim: carriage return is now written `\015`.
  `\r` is not a standard SystemVerilog escape, and xsim read it as the
  letter `r`
- Known: `irq_o` is not yet routed to the core, so the driver polls.
  `uart.c`/`uart.h` exist twice (GCC app and SEGGER project), and
  `SYS_CLK_HZ` is defined in both the wrapper and `uart.h`. The GCC
  `main.c` has the "Type something" prompt commented out while the SEGGER
  build keeps it, which `tb_uart_soc` depends on

## hms-v0.4.0 - 2026-09-16

- SCU35 build now runs on hardware: bitstream generates cleanly and the LED
  demo plus heartbeat run on the board. Closes the missing-XDC gap noted in
  hms-v0.3.2
- Added `fpga/scu35/constraints/EK_SCU35_RevB3.xdc`, the AMD master file with
  every line commented out except the ports in use: `clk_p_i`/`clk_n_i` as
  `LVDS` with `DIFF_TERM_ADV TERM_100`, `led_o[4:0]` and `rst_ni` as
  `LVCMOS33` (bank 45 at its default 3.3 V, J55 open)
- Clocking Wizard set to `PRIM_SOURCE No_buffer` since the wrapper's `IBUFDS`
  already buffers the clock, removing the redundant IBUF. `locked` output
  enabled; the wizard resolves to a PLL
- Replaced the single-flop `reset_synchronizer` with a two-flop
  synchroniser, asserted asynchronously and released synchronously, gated
  by `rst_ni & locked` so the core stays in reset until the clock is stable
- LED peripheral reduced to 4 bits on the SCU35; `led_o[4]` is the
  heartbeat. SEGGER demo pattern shortened to match
- Simulation run extended to 5 ms so the core leaves reset after PLL lock
- Post-route utilisation: 3643 LUT (22%), 2285 FF (7%), 16 BRAM (33%),
  3 DSP (6%)
- Timing at 50 MHz: WNS +9.080 ns over 7331 endpoints, no critical warnings
- Renamed the Genesys-2 wrapper to `cv32e40x_wrapper.sv` and removed the
  unused SCU35 `led_demo.coe`

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
