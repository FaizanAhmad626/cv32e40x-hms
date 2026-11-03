# HMS Changelog

HMS-specific work on top of the OpenHW CV32E40X core.

Versions are tagged `hms-v*` to keep them distinct from the upstream core
tags (`0.1.0` through `0.10.0`), which belong to OpenHW and stop at the fork
point.

## hms-v0.9.0 - 2026-11-03 - TDM microphone receiver in the SoC, 1 kHz tone verified on all 8 mics from C

- The 8-mic capture proven in `mic_test` (hms-v0.8.0) is now a CV32E40X
  peripheral: `mic_demo` on the SCU35 records 1024 samples from each mic
  and reports them over FT4232 port B at 115200 8N1. With a 1 kHz phone
  tone every mic reads 1000.2 to 1000.7 Hz at -67.2 to -56.5 dBFS (the
  spread follows where each mic sits relative to the phone), with no FIFO
  overrun and LEDs 0, 1 and 2 lit. In a quiet room the same mics read
  about -90 dBFS, so the tone sits 23 to 33 dB above the broadband noise
- Added `mic_peripheral` at `0x1004_0000` in slot 5, wrapping
  `tdm_master_rx` with a 64-entry FIFO (8 frames of all 8 mics, 328 us).
  `DATA` (+0x00) pops `{VALID, slot[2:0], sample[23:0]}` and reads 0 when
  empty, so software can poll it alone. `STATUS` (+0x04) has RX_VALID,
  RX_FULL, OVERRUN (sticky, write 1 to clear) and RUNNING. `CTRL` (+0x08)
  has EN, FLUSH and an 8-bit SLOT_MASK. `IRQ_EN` (+0x0C) covers RX_VALID
  and OVERRUN. `FRAMES` (+0x10) counts TDM frames since EN, which software
  uses to wait out mic start-up. Any other offset returns a bus error
- Bus timing matches the mic_test build: BCLK = 50 MHz / 8 = 6.25 MHz (mic
  Normal mode, 24.414 kHz per mic), DATA read 2 cycles (40 ns) after the
  BCLK falling edge
- Wrapper: new `MIC_BASE`, `MIC_BCLK_DIV` and `MIC_CAPTURE_PHASE`
  parameters, `SLV_MIC` table row, ports `mic_bclk_o`, `mic_ws_o` and
  `mic_sd_i`. Interrupt not yet routed to the core
- Constraints: PMOD0 R4 (BCLK), R3 (WS) and W3 (DATA) active, `LVCMOS33`,
  same wiring to the POLARIS J2 connector as hms-v0.8.0. Every active pin
  assignment now ends with where it goes on the board (part reference,
  header and silkscreen pin, board net name)
- `tdm_master_rx.sv` copied into `fpga/scu35/rtl/` and the SBM100B model
  into `fpga/scu35/sim/mic/`, so the SoC does not depend on `mic_test/`,
  which stays a standalone project. The copies are independent
- `create_project_scu35.tcl` preloads `mic_demo_segger.coe`
- Added `sim/mic/tb_mic_periph.sv`: interconnect plus `mic_peripheral`
  against 8 SBM100B models at 50 MHz. Checks reset values, bus errors,
  BCLK period, WS width and spacing, 600 frames of tagged samples with
  frame continuity, a 1 kHz tone on one slot, FRAMES, SLOT_MASK, FLUSH,
  OVERRUN and RX_FULL, interrupts, and that EN = 0 stops BCLK and WS low.
  Passes with up to 20 ns of board delay each way. Runs in xsim or
  Verilator; Icarus 12 cannot elaborate `obi_data_interconnect`
- Also run before hardware: the full SoC in Verilator (core, interconnect,
  all peripherals, IP replaced by behavioural stand-ins) running a short
  build of `mic_demo` against 8 mic models 6 dB apart. It printed
  999.8 to 1000.1 Hz and levels exactly 6 dB apart
- Added SEGGER app `sw/apps/segger/mic_demo`: `mic.c`/`mic.h` driver
  (start, stop, flush, wait frames), capture of every mic into a 32 KB
  buffer, and per mic the DC-removed RMS level in dBFS, the peak, and the
  tone frequency from rising zero crossings with hysteresis and
  interpolation. Integer math only. Press 0 to 7 to print one mic's raw
  samples between BEGIN and END lines. LED0 = no overrun, LED1 = all mics
  giving data, LED2 = all mics agree on the tone within 1 %

## hms-v0.8.0 - 2026-11-01 - TDM microphone capture on the SCU35, FPGA as bus master, 1 kHz tone verified on all 8 mics

- Standalone mic test in `mic_test/`, separate from the SoC: the
  SCU35 drives the sensiBel SB-POLARIS P002 kit (8 SBM100B-TDM mics) as TDM
  master and records the samples with an ILA. Not yet connected to the
  CV32E40X; the receiver is written to become an OBI peripheral later
- Wiring: the POLARIS top board is detached from its TDM-to-USB board and
  driven through its 20-pin J2 connector, which sensiBel
  confirmed is a 3.3 V plug-and-play interface with no enable or direction
  pins; the board makes its own 1.8 V and level-shifts the mic side. J2 to
  PMOD0, by board silkscreen: BCLK (row 1 right) to 1, WS (row 3 right) to
  3, DATA (row 4 right) to 5, GND (rows 6 and 7 right) to 9 and 10, 3.3 V
  (rows 1 and 2 left) to 11 and 12. FPGA pins R4, R3 and W3, `LVCMOS33`.
  The PMOD 3.3 V rail is behind a load switch, enabled by F4
- Added `tdm_master_rx`: TDM8 master and receiver. BCLK = clk / CLK_DIV
  (100 MHz / 16 = 6.25 MHz, mic Normal mode), WS high for one BCLK at bit 0
  of every 256-BCLK frame, so 24.414 kHz per mic. DATA passes a two-flop
  synchroniser, is read CAPTURE_PHASE cycles after the BCLK falling edge
  (3, so 30 ns, with the synchroniser delay counted in) and shifted MSB first
  into a 24-bit register. After bit 23 of a slot it outputs the signed
  sample, the slot number and a one-cycle `sample_valid`; bits 24 to 31
  (High-Z) are ignored. `slot_mask_i` selects slots, `en_i` stops BCLK and
  WS low
- Added `mic_tdm_top`: IBUFDS on the 100 MHz board clock, a 256-cycle
  power-on reset, then the PMOD 3.3 V switch is turned on and BCLK starts
  50 ms later, so the mics are powered before they are clocked (green D2,
  then orange D1 on the POLARIS board). `tdm_ila` (8192 deep, capture
  control on, 2 comparators) records sample, slot, sample_valid,
  frame_start, BCLK, WS and DATA
- Constraints: `constraints/EK_SCU35_RevB3.XDC`, the board XDC with the
  clock, F4, R4, R3 and W3 lines active
- `scripts/create_project_mic_test.tcl` builds the Vivado project from
  scratch in `mic_test/vivado` (git-ignored): adds the RTL, sim and
  constraint files, generates `tdm_ila` from its settings, sets the tops and
  an unlimited xsim run time. It warns when the implementation temp path
  passes 146 characters
- Simulation: `sim/tb_tdm_master_rx` with `sim/sbm100b_tdm_model`, a
  behavioural SBM100B-TDM written from the datasheet (rev 0.71), eight of
  them on one shared DATA line with 2 ns wire delay each way and 15 ns
  clock-to-out. Slots send {slot ID, frame number}, slot 3 a 1 kHz sine.
  Checks BCLK period and duty, WS spacing, width and edge, slot IDs, frame
  numbers, masking and disable. Vivado xsim: TEST PASSED, 73 frames, 520
  samples, 0 errors
- Hardware, ILA with capture control off: BCLK period 16 clocks, WS one
  BCLK wide, and the decoded samples match the DATA bits bit for bit. With
  capture control on (store when `sample_valid` = 1), a capture holds 1024
  samples per slot. A 1 kHz phone tone (`data/iladata.csv`) peaks at
  1001.4 Hz on every slot, 76.7 to 82.4 dB above the noise floor, at -65.6
  to -60.6 dBFS
- `scripts/plot_ila_tdm.m`: reads an ILA CSV export or an .ila file,
  converts the hex samples to signed 24-bit, splits them by slot, removes
  DC, and plots each slot's waveform and spectrum (saved as `data/time.png`
  and `data/spectrum.png`) with the level, peak frequency and noise margin
  per slot
- Post-route: 1670 LUT (10%), 2781 FF (9%), 7.5 BRAM (16%), 0 DSP, most of
  it the ILA. Timing at 100 MHz: WNS +5.904 ns, no critical warnings
- Earlier attempts: sniffing the kit's J5 header with the kit as master.
  On a PMOD the signals were corrupt (J5 is 1.8 V, PMOD banks are 3.3 V); on
  RASP_HAT1 (J14) with J55 set to 1.8 V, BCLK (12.288 MHz) and DATA were
  correct but WS stayed low, most likely a contact problem at J5. Driving
  J2 from the FPGA replaced both
- Lesson: Vivado cannot insert the ILA debug hub (`dbg_hub`, Chipscope
  16-302) when the `impl_1/.Xil` temp path is longer than 146 characters.
  The project first sat in `fpga/scu35/mic_test/vivado_proj` (159); moving
  it to `mic_test/vivado` brings it to about 143. `subst` to a drive letter
  gives more margin
- Known: the sample rate is 24.414 kHz, while the classification model
  expects 22,050 Hz (BCLK 5.6448 MHz, needs an MMCM). No I2C configuration
  of the mics yet; they run in their default mode

## hms-v0.7.0 - 2026-09-27 - I2C master on the SCU35, verified in simulation and on the on-board accelerometer, final pins on PMOD2

- I2C running on the SCU35: `i2c_demo` passes every test at 100 kHz and at
  378 kHz against the on-board LIS2DE12 accelerometer (board bus I2C3, 0x18).
  It scans the bus, reads WHO_AM_I = 0x33, writes and reads back four patterns
  in INT1_THS plus a two-byte auto-increment burst (restoring the originals),
  and measures gravity at about 1 g. Results go over FT4232 port B at 115200
  8N1 and on the LEDs (0x0F), followed by live X/Y/Z readings in mg. On
  PMOD2 the same demo runs the accelerometer tests only if a LIS2DE12
  answers at 0x18 or 0x19; with any other module (or none) it checks the
  idle bus levels, lists every address that answers, and reports
  `bus OK, N device(s) answered` with LED0 lit
- Added `i2c_master`: single-master byte engine, 7-bit addressing in
  software, repeated START, clock stretching. Every bit is four quarters of
  CLKDIV cycles (q0 set SDA, q1 release SCL, q2 SCL high, q3 pull SCL low),
  so SCL = fclk / (4 * CLKDIV) and SDA always moves a full quarter away from
  an SCL edge. The quarter counter freezes in q1 until the synchronised SCL
  reads high, which is the whole of clock-stretching support. SCL is held
  low between commands while the bus is owned, so software speed never
  matters. CLKDIV below 4 acts as 4. `ABORT` releases both lines at once.
  Pad enables come from flops, SCL/SDA pass two-flop synchronisers
- Added `i2c_peripheral` at `0x1003_0000` in slot 4: `DATA`, `CMD`,
  `STATUS`, `CLKDIV` and `IRQ_EN` at `+0x00` to `+0x10`. One command is an
  optional START, an optional byte (WRITE or READ, with NACK for the last
  read byte) and an optional STOP. `STATUS` reports BUSY, RX_NACK, HELD and
  the live SCL/SDA levels, so a missing pull-up shows up as a 0 on an idle
  bus. `CLKDIV` resets to 125 (100 kHz); 33 gives 378 kHz with tLOW 1.32 us.
  Byte at a time and polled, no FIFOs. Any other offset returns a bus error
- Wrapper: new `I2C_BASE` and `I2C_SCL_HZ` parameters, `SLV_I2C` table row,
  `i2c_scl_io`/`i2c_sda_io` inout ports driven as `oe ? 1'b0 : 1'bz` (Vivado
  infers IOBUFs, an ASIC flow maps them to open-drain pads). The engine
  itself has no inout ports or vendor primitives
- XDC, final: SCL on PMOD2 pin 3 (U2) and SDA on PMOD2 pin 4 (AA1), the
  Digilent Pmod I2C (Type 6) order, so a standard I2C Pmod module plugs
  straight in; pin 5 is GND and pin 6 is the switched Pmod 3.3 V rail.
  PMOD2 is header J10 on the board. On
  the board silkscreen (odd numbers on the upper row) these are pins 5, 7, 9
  and 11. `LVCMOS33` with the weak internal `PULLUP`, which is too weak for
  I2C on its own: the module or the wiring must add real pull-ups (e.g.
  4.7 kOhm to 3.3 V). The on-board I2C0 and I2C3 lines are commented out
  again. `create_project_scu35.tcl` now preloads `i2c_demo_segger.coe`
- Pin history: the controller was verified on the on-board buses first
  (I2C0 at L1/K1, then I2C3 at J2/H2, see below), then moved to PMOD2 so the
  bus is free for external modules. Only the XDC and comments changed; the
  RTL, the address map and the driver are the same
- Software: SEGGER project `sw/apps/segger/i2c_demo` with a polled driver
  (`i2c_init`, `i2c_bus_idle_ok`, `i2c_probe`, `i2c_write`, `i2c_read`,
  `i2c_write_read`, `i2c_reg_write`, `i2c_reg_read`) built from two helpers
  that each issue one command and poll BUSY. On a NACK the driver sends STOP,
  on a timeout ABORT, so the bus is always left free. Timing uses `mcycle`,
  after clearing `mcountinhibit`
- Simulation: new `fpga/scu35/sim/i2c/` with `tb_i2c_periph` and two
  behavioural slave models written from their datasheets, `m24c64_model`
  (EEPROM with page wrap, write cycle and a WC write-protect input) and
  `lis2de12_model` (register file with auto-increment and X/Y/Z inputs).
  The test runs both on one open-drain bus with pull-ups and checks probes,
  page writes, random and sequential reads, write protection, register
  write/readback, burst reads, clock stretching, ABORT, IRQ, bus errors and
  the CLKDIV clamp, while a bus monitor checks SCL timing and that SDA never
  moves while SCL is high except for START and STOP. Four deliberately broken
  RTL variants all fail it. A whole-SoC run with the real core executing
  the demo passes at both speeds, and with an empty bus (pull-ups only, as
  on a bare PMOD2) it reports bus OK and no devices. `tb_uart_soc` connects
  the new ports
- Post-route (I2C3 build): 4218 LUT (26%), 2635 FF (8%), 16 BRAM (33%),
  3 DSP. Timing at 50 MHz: WNS +8.587 ns over 8627 endpoints, no critical
  warnings. The PMOD2 build moves two pins and should differ only in
  placement noise
- First hardware target was the board's I2C0 EEPROM (M24C64, 0x50/0x58).
  Reads were exact at both speeds: bytes 0 to 7 are an FRU board-ID header
  whose checksum sums to 0x00. Writes were refused: the EEPROM ACKed its
  address and memory address, then NACKed every data byte, which is the
  datasheet behaviour with WC held high. AMD ties WC high to protect the
  board ID and it has no FPGA pin, so the controller moved to I2C3
- Lesson: after rebuilding firmware under the same COE name, Vivado does
  not re-synthesize the BRAM IP, because it tracks the COE by file name. The
  first run after the move had the new pins (the scan found 0x18) but still
  ran the old EEPROM firmware. Regenerate the `blk_mem_gen_0` output products,
  or rerun `create_project_scu35.tcl`, after every firmware change
- PMOD2 checked on hardware with no module fitted: with pin 3 (silkscreen
  5) jumpered to GND, `i2c_demo` reports `SCL=0 SDA=1` in its bus check,
  which confirms the header and the pin mapping; with the jumper removed the
  bus idles high on the internal pull-ups, the scan finds nothing, and the
  result is `bus OK, 0 device(s) answered` (LED0) at both speeds. A full
  transfer on PMOD2 still needs an I2C module with pull-ups
- Lesson: the board's Pmod header numbering does not follow UG1713, which
  lists J10 to J13 as PMOD0 to PMOD3. PMOD2 is J10 and PMOD1 is J13 (found
  during SPI bring-up). Identify a header with a jumper test, not the guide
- Known: `irq_o` of UART, SPI and I2C is still not routed to the core, so
  the drivers poll. `uart.c`/`uart.h` now exist four times

## hms-v0.6.0 - 2026-09-26 - SPI master on the SCU35, verified in xsim and over a PMOD loopback on hardware

- SPI running on the SCU35: with a jumper from MOSI to MISO on PMOD1 (J13,
  silkscreen pins 3 and 5), `spi_demo` passes all four modes at 1 MHz and at
  6.25 MHz, reported over FT4232 port B at 115200 8N1 and on the LEDs
- Added `spi_master`: 8-bit MSB-first shift engine for modes 0 to 3, all
  outputs from flops. SCLK = fclk / (2 * CLKDIV), with CLKDIV raised to 4
  when set lower, because MISO passes a two-flop synchroniser and the
  remaining 2 cycles (40 ns at 50 MHz) are the round-trip budget. Ceiling
  6.25 MHz. One XOR covers the modes: `sample = leading ^ cpha`
- Added `spi_peripheral` at `0x1002_0000` in slot 3: `DATA`, `STATUS`,
  `CTRL`, `CLKDIV`, `CS` and `IRQ_EN` at `+0x00` to `+0x14`, two 16-entry
  `sync_fifo`s (the UART's), `RX_OVERRUN` sticky and write-1-to-clear, chip
  select driven from a register. `CLKDIV` resets to 25 (1 MHz). Any other
  offset returns a bus error
- Wrapper: new `SPI_BASE` and `SPI_SCLK_HZ` parameters, `SLV_SPI` table row,
  `spi_sclk_o`/`spi_mosi_o`/`spi_miso_i`/`spi_cs_no` ports, and
  `pmod_3v3_on_o` tied high to switch on the Pmod 3.3 V load switch (U81),
  which is off at power-up
- XDC: PMOD1 in the Digilent Pmod SPI order, CS on U1, MOSI on T1, MISO on
  P4 with `PULLUP`, SCLK on P5, `PMOD_3V3_ON` on F4, all `LVCMOS33`. The
  pull-up makes a missing connection read as `0xFF` rather than noise
- Software: SEGGER project `sw/apps/segger/spi_demo` with a polled driver
  (`spi_init`, `spi_select`, `spi_deselect`, `spi_xfer`, `spi_xfer_buf`,
  `spi_wait_idle`). `spi_xfer_buf` keeps at most 16 bytes in flight so RX
  cannot overrun. The demo sends a 16-byte pattern per mode and rate, and
  any key re-runs it. `create_project_scu35.tcl` now preloads
  `spi_demo_segger.coe`
- Simulation: `fpga/scu35/sim/` split per peripheral (`uart/`, `spi/`,
  `sum/`); the Verilator runner `run_sim.sh` and `xilinx_sim_models.sv` are
  removed and xsim is the flow; `create_project_scu35.tcl` points at the
  moved `.wcfg`. New `tb_spi_periph` checks all four modes against an
  independent SPI slave model with 15 ns of MISO delay, plus the CLKDIV
  clamp, loopback, overrun, interrupts and bus errors; passes in xsim.
  `tb_uart_soc` connects the new ports
- Post-route: 4089 LUT (25%), 2539 FF (8%), 16 BRAM (33%). Timing at
  50 MHz: WNS +8.762 ns over 8385 endpoints, no critical warnings
- `.gitignore`: SEGGER build output under `sw/apps/segger/*/Output/`
- Lesson: the board silkscreen numbers each Pmod header odd/even across
  the two rows (1 upper, 2 below it), while the Pmod standard numbers 1 to
  6 along the upper row. Pmod pins 2 and 3 are silkscreen pins 3 and 5;
  the first loopback on silkscreen 2 and 3 read `0xFF`. `spi_demo` now
  names the position by silkscreen number
- Known: `irq_o` of both UART and SPI is still not routed to the core, so
  the drivers poll. `uart.c`/`uart.h` now exist three times (GCC
  `uart_demo`, SEGGER `uart_demo`, SEGGER `spi_demo`)

## hms-v0.5.0 - 2026-09-21 - UART peripheral on the SCU35, table-driven interconnect, verified in xsim and on hardware

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

## hms-v0.4.0 - 2026-09-16 - SCU35 running on hardware: XDC, two-flop reset synchroniser, LED demo and heartbeat

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

## hms-v0.3.2 - 2026-09-13 - SCU35 Vivado project added; synthesises, but no XDC yet

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

## hms-v0.3.1 - 2026-09-10 - SEGGER single memory region, clock constraint added, settled at 50 MHz

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

## hms-v0.3.0 - 2026-09-09 - SEGGER Embedded Studio build of the LED demo

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

## hms-v0.2.0 - 2026-08-31 - OBI data interconnect, LED MMIO peripheral, bare-metal firmware stack

- Added `obi_data_interconnect.sv`, owning all address decode and response
  muxing, and separating memory space from peripheral space
- Added `led_peripheral.sv` as a standalone MMIO register at `0x1000_0000`
- Added the bare-metal firmware stack: `crt0.S`, `link.ld`, `main.c`, and
  `sw/tools/elf2coe.py`
- LED MMIO demo running on the Genesys-2

## hms-v0.1.0 - 2026-08-30 - Genesys-2 project, unified BRAM, heartbeat LED

- Added the Genesys-2 Vivado project creation script
- Replaced the separate instruction and data memories with a single unified
  BRAM and memory controller, resolving `.rodata` accessibility
- Heartbeat LED blinking on hardware
