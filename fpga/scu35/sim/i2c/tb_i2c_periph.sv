//////////////////////////////////////////////////////////////////////////////////
// tb_i2c_periph.sv
//
// Unit test: obi_data_interconnect (2 slots) + i2c_peripheral. No core.
//
// The bus is two open-drain nets with pull-ups. On it sits m24c64_model, a
// behavioural model of the SCU35's M24C64 EEPROM written from the datasheet
// rather than from the RTL: device select 0x50, two address bytes, 32-byte
// page writes that wrap inside the page, sequential reads that run across
// the whole array. It can stretch SCL after every ACK, like a slow slave.
//
// Checks
//   - reset values, register read/write, CLKDIV clamp to 4
//   - address probe: ACK at 0x50, NACK at 0x51 (nobody there)
//   - page write, then random read (repeated START) and sequential read,
//     data checked against the model's array and against what was written
//   - page wrap inside a 32-byte page
//   - write-protected EEPROM (WC high, as on the board): data bytes NACKed
//   - a LIS2DE12 model on the same bus: WHO_AM_I, register write/readback,
//     auto-increment burst read
//   - SCL period = 4 * CLKDIV (+ a few cycles of pin/synchroniser delay),
//     SCL low time >= 2 quarters, master never moves SDA while SCL is high
//     except for START and STOP, and never within a quarter of SCL falling
//   - START and STOP counts seen by the slave match what software issued
//   - clock stretching: the master waits, data still correct
//   - STATUS pin levels, HELD, BUSY, IRQ_EN / irq_o
//   - ABORT mid-byte releases both lines
//   - OBI error for unused offsets and an unmapped address
//
// Needs no Xilinx IP. From fpga/scu35 in a Vivado shell:
//   xvlog -sv rtl/i2c_master.sv rtl/i2c_peripheral.sv rtl/obi_data_interconnect.sv \
//             sim/i2c/m24c64_model.sv sim/i2c/lis2de12_model.sv sim/i2c/tb_i2c_periph.sv
//   xelab tb_i2c_periph -s tb_i2c && xsim tb_i2c -R
// or add this file to sim_1 and set tb_i2c_periph as the simulation top.
// Prints PASS or FAIL at the end; runs in about 2.3 ms of simulated time.
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps

module tb_i2c_periph;

localparam int unsigned CLK_HZ  = 50_000_000;    // 20 ns clock, as on the board
localparam int unsigned SCL_HZ  = 400_000;       // CLKDIV reset = ceil(31.25) = 32
localparam logic [31:0] I2C     = 32'h1003_0000;
localparam logic [31:0] OTHER   = 32'h1000_0000;

localparam logic [31:0] DATA    = I2C + 32'h00;
localparam logic [31:0] CMD     = I2C + 32'h04;
localparam logic [31:0] STATUS  = I2C + 32'h08;
localparam logic [31:0] CLKDIV  = I2C + 32'h0C;
localparam logic [31:0] IRQ_EN  = I2C + 32'h10;

localparam logic [31:0] C_START = 32'h01;
localparam logic [31:0] C_STOP  = 32'h02;
localparam logic [31:0] C_WRITE = 32'h04;
localparam logic [31:0] C_READ  = 32'h08;
localparam logic [31:0] C_NACK  = 32'h10;
localparam logic [31:0] C_ABORT = 32'h80;

localparam logic [31:0] ST_BUSY = 32'h01;
localparam logic [31:0] ST_NACK = 32'h02;
localparam logic [31:0] ST_HELD = 32'h04;
localparam logic [31:0] ST_SCL  = 32'h08;
localparam logic [31:0] ST_SDA  = 32'h10;

localparam logic [6:0]  EEPROM  = 7'h50;

logic clk = 0, rst_n = 0;
always #10 clk = ~clk;

// OBI master side
logic        req = 0, gnt, rvalid, we = 0, err, exokay;
logic [31:0] addr = 0, wdata = 0, rdata;
logic [ 3:0] be = 4'hF;

// Slave side
logic [1:0]        s_req, s_gnt, s_rvalid, s_err, s_exokay;
logic              dummy_rvalid;
logic [1:0][31:0]  s_rdata;
logic [31:0]       s_addr, s_wdata;
logic [3:0]        s_be;
logic              s_we;

obi_data_interconnect #(
    .NUM_SLAVES ( 2 ),
    .SLV_BASE   ( { I2C,           OTHER         } ),
    .SLV_MASK   ( { 32'hFFFF_0000, 32'hFFFF_0000 } )
) ic (
    .clk_i(clk), .rst_ni(rst_n),
    .data_req_i(req), .data_gnt_o(gnt), .data_rvalid_o(rvalid),
    .data_addr_i(addr), .data_be_i(be), .data_we_i(we), .data_wdata_i(wdata),
    .data_memtype_i(2'b0), .data_prot_i(3'b0), .data_dbg_i(1'b0), .data_atop_i(6'b0),
    .data_rdata_o(rdata), .data_err_o(err), .data_exokay_o(exokay),
    .slv_req_o(s_req), .slv_gnt_i(s_gnt), .slv_rvalid_i(s_rvalid),
    .slv_rdata_i(s_rdata), .slv_err_i(s_err), .slv_exokay_i(s_exokay),
    .slv_addr_o(s_addr), .slv_be_o(s_be), .slv_we_o(s_we), .slv_wdata_o(s_wdata),
    .slv_memtype_o(), .slv_prot_o(), .slv_dbg_o(), .slv_atop_o()
);

// Slot 0: trivial slave that answers 0xDEADBEEF
assign s_gnt[0]    = s_req[0];
assign s_rdata[0]  = 32'hDEAD_BEEF;
assign s_err[0]    = 1'b0;
assign s_exokay    = '0;
always_ff @(posedge clk) dummy_rvalid <= rst_n & s_req[0];
assign s_rvalid[0] = dummy_rvalid;

// ---------------------------------------------------------------------------
// Open-drain bus
// ---------------------------------------------------------------------------
wire  scl, sda;
logic scl_oe, sda_oe, irq;

pullup (scl);
pullup (sda);
assign scl = scl_oe      ? 1'b0 : 1'bz;
assign sda = sda_oe      ? 1'b0 : 1'bz;

i2c_peripheral #(.CLK_HZ(CLK_HZ), .SCL_HZ(SCL_HZ)) dut (
    .clk_i(clk), .rst_ni(rst_n),
    .req_i(s_req[1]), .gnt_o(s_gnt[1]), .rvalid_o(s_rvalid[1]),
    .addr_i(s_addr), .be_i(s_be), .we_i(s_we), .wdata_i(s_wdata),
    .rdata_o(s_rdata[1]), .err_o(s_err[1]),
    .scl_i(scl), .scl_oe_o(scl_oe), .sda_i(sda), .sda_oe_o(sda_oe),
    .irq_o(irq)
);

// ---------------------------------------------------------------------------
int errors = 0;

task automatic check(input string what, input logic [31:0] got, input logic [31:0] exp);
    if (got !== exp) begin
        $display("FAIL: %s: got %h, expected %h", what, got, exp);
        errors++;
    end
endtask

// ---------------------------------------------------------------------------
// EEPROM on the bus (sim/i2c/m24c64_model.sv). Its array starts filled with
// mem[i] = i * 7 + 3, so reads of unwritten locations have known values.
// ---------------------------------------------------------------------------
logic stretch_en = 0;
int   stretch_ns = 3000;

logic wc = 0;                   // EEPROM write control (the board ties it high)

m24c64_model #(.DEV(EEPROM), .ID_DEV(7'h58), .T_WRITE_NS(0)) eeprom (
    .scl(scl), .sda(sda), .rst_n(rst_n), .wc(wc),
    .stretch_en(stretch_en), .stretch_ns(stretch_ns)
);

// A second device on the same bus (sim/i2c/lis2de12_model.sv), so the test
// also covers register-style access with auto-increment and two slaves
// sharing SDA. On the board it sits on its own bus, I2C3.
lis2de12_model #(.DEV(7'h18)) acl (
    .scl(scl), .sda(sda), .rst_n(rst_n),
    .accel_x(8'hFC), .accel_y(8'h03), .accel_z(8'h40)
);

// ---------------------------------------------------------------------------
// Bus monitor
//   - SDA driven by the master must not move while SCL is high, unless the
//     move is a START or STOP (those are counted by the model), and not
//     within a quarter period of SCL falling
//   - SCL low time, SCL period during a byte
// ---------------------------------------------------------------------------
int      quarter_ns = 32 * 20;
realtime t_scl_fall = 0, t_scl_rise = 0, t_prev_rise = 0, t_busy = 0;
realtime min_low, max_low, min_high, min_period, max_period;
int      sda_while_high = 0;        // master SDA changes with SCL high
int      sda_too_soon   = 0;        // master SDA changes too close to SCL fall
logic    measure = 0;
logic    mon_off = 0;               // ABORT deliberately breaks the rules

task automatic clear_meas();
    min_low = 1e9; max_low = 0; min_high = 1e9; min_period = 1e9; max_period = 0;
endtask

// Periods are only measured within one command; the gap while software
// polls between commands is not part of the bit timing.
always @(posedge dut.busy) t_busy = $realtime;

always @(negedge scl) if (rst_n) begin
    if (measure && t_scl_rise > t_busy) begin
        if ($realtime - t_scl_rise < min_high) min_high = $realtime - t_scl_rise;
    end
    t_scl_fall = $realtime;
end

always @(posedge scl) if (rst_n) begin
    if (measure && t_scl_fall > t_busy) begin
        if ($realtime - t_scl_fall < min_low) min_low = $realtime - t_scl_fall;
        if ($realtime - t_scl_fall > max_low) max_low = $realtime - t_scl_fall;
    end
    if (measure && t_prev_rise > t_busy) begin
        if ($realtime - t_prev_rise < min_period) min_period = $realtime - t_prev_rise;
        if ($realtime - t_prev_rise > max_period) max_period = $realtime - t_prev_rise;
    end
    t_prev_rise = $realtime;
    t_scl_rise  = $realtime;
end

// Watch the DUT's own output, so slave activity is not counted against it.
always @(sda_oe) if (rst_n && !mon_off) begin
    if (scl === 1'b1 && !scl_oe) sda_while_high++;
    else if (scl === 1'b0 && ($realtime - t_scl_fall) < quarter_ns - 25) sda_too_soon++;
end

// ---------------------------------------------------------------------------
// OBI access, driven and sampled on the falling edge (same as tb_spi_periph)
// ---------------------------------------------------------------------------
task automatic obi(input logic w, input logic [31:0] a, input logic [31:0] d,
                   output logic [31:0] rdo, output logic e);
    @(negedge clk);
    req = 1; we = w; addr = a; wdata = d;
    #1;
    while (!gnt) begin @(negedge clk); #1; end
    @(negedge clk);
    req = 0;
    while (!rvalid) @(negedge clk);
    rdo = rdata; e = err;
endtask

task automatic wr(input logic [31:0] a, input logic [31:0] d);
    logic [31:0] r; logic e;
    obi(1, a, d, r, e);
    check($sformatf("err on write %h", a), {31'b0, e}, 0);
endtask

task automatic rd(input logic [31:0] a, output logic [31:0] r);
    logic e;
    obi(0, a, 0, r, e);
    check($sformatf("err on read %h", a), {31'b0, e}, 0);
endtask

// --- driver-level helpers, the same sequence the C driver uses -------------
task automatic wait_idle();
    logic [31:0] st;
    do rd(STATUS, st); while (st & ST_BUSY);
endtask

// returns 1 if the slave ACKed
task automatic put(input logic [7:0] b, input logic [31:0] flags, output logic acked);
    logic [31:0] st;
    wr(DATA, {24'h0, b});
    wr(CMD, C_WRITE | flags);
    wait_idle();
    rd(STATUS, st);
    acked = !(st & ST_NACK);
endtask

task automatic get(input logic [31:0] flags, output logic [7:0] b);
    logic [31:0] r;
    wr(CMD, C_READ | flags);
    wait_idle();
    rd(DATA, r);
    b = r[7:0];
endtask

task automatic ee_write(input logic [12:0] a, input logic [7:0] d[], output logic ok);
    logic ack;
    ok = 1;
    put({EEPROM, 1'b0}, C_START, ack); ok &= ack;
    put({3'b0, a[12:8]}, 0, ack);      ok &= ack;
    put(a[7:0], 0, ack);               ok &= ack;
    foreach (d[i]) begin
        put(d[i], (i == d.size() - 1) ? C_STOP : 0, ack);
        ok &= ack;
    end
endtask

task automatic ee_read(input logic [12:0] a, input int n, output logic [7:0] d[], output logic ok);
    logic ack;
    ok = 1;
    d = new[n];
    put({EEPROM, 1'b0}, C_START, ack); ok &= ack;
    put({3'b0, a[12:8]}, 0, ack);      ok &= ack;
    put(a[7:0], 0, ack);               ok &= ack;
    put({EEPROM, 1'b1}, C_START, ack); ok &= ack;       // repeated START
    for (int i = 0; i < n; i++)
        get((i == n - 1) ? (C_NACK | C_STOP) : 0, d[i]);
endtask

// ---------------------------------------------------------------------------
logic [31:0] r, st;
logic        e, ack, ok;
logic [7:0]  wbuf[], rbuf[];
logic [7:0]  rbuf1;
int          s0, p0;

initial begin
    repeat (5) @(negedge clk);
    rst_n = 1;
    repeat (5) @(negedge clk);

    // --- reset values and registers ----------------------------------------
    rd(STATUS, st);  check("STATUS reset (idle, lines high)", st, ST_SCL | ST_SDA);
    rd(CLKDIV, r);   check("CLKDIV reset = ceil(50M / 1.6M)", r, 32);
    rd(IRQ_EN, r);   check("IRQ_EN reset", r, 0);
    rd(DATA, r);     check("DATA reset", r, 0);
    rd(CMD, r);      check("CMD reads 0", r, 0);
    check("lines released after reset", {30'b0, scl_oe, sda_oe}, 0);
    check("irq low after reset", {31'b0, irq}, 0);

    wr(CLKDIV, 32'h1234);  rd(CLKDIV, r); check("CLKDIV rw", r, 32'h1234);
    wr(IRQ_EN, 1);         rd(IRQ_EN, r); check("IRQ_EN rw", r, 1);
    check("irq high when idle and enabled", {31'b0, irq}, 1);
    wr(IRQ_EN, 0);

    // --- CLKDIV clamp: 1 acts as 4, SCL period = 16 cycles -----------------
    wr(CLKDIV, 1);
    quarter_ns = 4 * 20;
    measure = 1; clear_meas();
    put({7'h51, 1'b0}, C_START | C_STOP, ack);
    measure = 0;
    check("probe 0x51 at clamped div: NACK", {31'b0, ack}, 0);
    if (min_period < 16 * 20 || max_period > 16 * 20 + 5 * 20) begin
        $display("FAIL: clamped SCL period %0t..%0t ns, expected %0d..%0d",
                 min_period, max_period, 16 * 20, 21 * 20);
        errors++;
    end

    // --- normal speed from here on ------------------------------------------
    wr(CLKDIV, 32);
    quarter_ns = 32 * 20;

    // --- address probe --------------------------------------------------------
    s0 = eeprom.starts; p0 = eeprom.stops;
    put({EEPROM, 1'b0}, C_START | C_STOP, ack);
    check("probe 0x50: ACK", {31'b0, ack}, 1);
    put({7'h51, 1'b0}, C_START | C_STOP, ack);
    check("probe 0x51: NACK", {31'b0, ack}, 0);
    check("probe START count", eeprom.starts - s0, 2);
    check("probe STOP count",  eeprom.stops - p0, 2);
    rd(STATUS, st); check("idle after probe", st & ~ST_NACK, ST_SCL | ST_SDA);

    // --- HELD between commands, lines while held ------------------------------
    put({EEPROM, 1'b0}, C_START, ack);
    rd(STATUS, st);
    check("HELD after START", st & ST_HELD, ST_HELD);
    check("SCL low while held", st & ST_SCL, 0);
    wr(CMD, C_STOP); wait_idle();
    rd(STATUS, st);
    check("not HELD after STOP", st & (ST_HELD | ST_BUSY), 0);
    check("lines high after STOP", st & (ST_SCL | ST_SDA), ST_SCL | ST_SDA);

    // --- page write + random read, with timing measured -----------------------
    wbuf = new[6];
    foreach (wbuf[i]) wbuf[i] = 8'hC0 + 8'(i * 17);
    measure = 1; clear_meas();
    s0 = eeprom.starts; p0 = eeprom.stops;
    ee_write(13'h1FE0, wbuf, ok);
    check("page write all ACKed", {31'b0, ok}, 1);
    foreach (wbuf[i]) check($sformatf("model mem[1FE0+%0d]", i), {24'h0, eeprom.mem[13'h1FE0 + i]}, {24'h0, wbuf[i]});
    ee_read(13'h1FE0, 6, rbuf, ok);
    measure = 0;
    check("random read all ACKed", {31'b0, ok}, 1);
    foreach (rbuf[i]) check($sformatf("read back 1FE0+%0d", i), {24'h0, rbuf[i]}, {24'h0, wbuf[i]});
    check("write+read START count (1 + 2)", eeprom.starts - s0, 3);
    check("write+read STOP count", eeprom.stops - p0, 2);
    if (min_period < 4 * 32 * 20 || max_period > 4 * 32 * 20 + 5 * 20) begin
        $display("FAIL: SCL period %0t..%0t ns, expected %0d..%0d",
                 min_period, max_period, 4 * 32 * 20, 4 * 32 * 20 + 100);
        errors++;
    end
    if (min_high < 2 * 32 * 20) begin
        $display("FAIL: SCL high time %0t ns, expected >= %0d", min_high, 2 * 32 * 20);
        errors++;
    end
    if (min_low < 2 * 32 * 20 - 40) begin
        $display("FAIL: SCL low time %0t ns, expected >= %0d", min_low, 2 * 32 * 20 - 40);
        errors++;
    end

    // --- sequential read across a page boundary, pre-filled data -------------
    ee_read(13'h0FFC, 8, rbuf, ok);
    check("sequential read ACKed", {31'b0, ok}, 1);
    foreach (rbuf[i]) check($sformatf("seq read 0FFC+%0d", i), {24'h0, rbuf[i]}, {24'h0, 8'((13'h0FFC + i) * 7 + 3)});

    // --- page wrap: 4 bytes from offset 30 land at 30, 31, 0, 1 of the page --
    wbuf = new[4];
    wbuf = '{8'h11, 8'h22, 8'h33, 8'h44};
    ee_write(13'h005E, wbuf, ok);
    check("wrap write ACKed", {31'b0, ok}, 1);
    ee_read(13'h005E, 2, rbuf, ok);
    check("wrap 0x5E", {24'h0, rbuf[0]}, 8'h11);
    check("wrap 0x5F", {24'h0, rbuf[1]}, 8'h22);
    ee_read(13'h0040, 2, rbuf, ok);
    check("wrap 0x40", {24'h0, rbuf[0]}, 8'h33);
    check("wrap 0x41", {24'h0, rbuf[1]}, 8'h44);
    ee_read(13'h0060, 1, rbuf, ok);
    check("next page untouched", {24'h0, rbuf[0]}, {24'h0, 8'(13'h0060 * 7 + 3)});

    // --- write-protected EEPROM, as on the SCU35 -----------------------------
    // Device select and memory address are ACKed, data bytes are NACKed and
    // nothing is written.
    wc = 1;
    s0 = eeprom.starts;
    put({EEPROM, 1'b0}, C_START, ack); check("WC: address ACKed",   {31'b0, ack}, 1);
    put(8'h1F, 0, ack);                check("WC: addr hi ACKed",   {31'b0, ack}, 1);
    put(8'h00, 0, ack);                check("WC: addr lo ACKed",   {31'b0, ack}, 1);
    put(8'h5A, C_STOP, ack);           check("WC: data NACKed",     {31'b0, ack}, 0);
    check("WC: mem[1F00] unchanged", {24'h0, eeprom.mem[13'h1F00]}, {24'h0, 8'(13'h1F00 * 7 + 3)});
    rd(STATUS, st); check("WC: bus released", st & (ST_BUSY | ST_HELD), 0);
    wc = 0;

    // --- accelerometer: WHO_AM_I, CTRL_REG1 write/readback, burst read ---------
    put({7'h18, 1'b0}, C_START, ack);  check("ACL: address ACKed", {31'b0, ack}, 1);
    put(8'h0F, 0, ack);
    put({7'h18, 1'b1}, C_START, ack);
    get(C_NACK | C_STOP, rbuf1);       check("ACL: WHO_AM_I", {24'h0, rbuf1}, 32'h33);
    put({7'h18, 1'b0}, C_START, ack);
    put(8'h20, 0, ack);
    put(8'h57, C_STOP, ack);           check("ACL: CTRL_REG1 write ACKed", {31'b0, ack}, 1);
    put({7'h18, 1'b0}, C_START, ack);
    put(8'h20, 0, ack);
    put({7'h18, 1'b1}, C_START, ack);
    get(C_NACK | C_STOP, rbuf1);       check("ACL: CTRL_REG1 readback", {24'h0, rbuf1}, 32'h57);
    put({7'h18, 1'b0}, C_START, ack);
    put(8'hA8, 0, ack);                // OUT_X_L with auto-increment
    put({7'h18, 1'b1}, C_START, ack);
    for (int i = 0; i < 6; i++) begin
        get((i == 5) ? (C_NACK | C_STOP) : 0, rbuf1);
        if (i == 1) check("ACL: OUT_X_H", {24'h0, rbuf1}, 32'hFC);
        if (i == 3) check("ACL: OUT_Y_H", {24'h0, rbuf1}, 32'h03);
        if (i == 5) check("ACL: OUT_Z_H", {24'h0, rbuf1}, 32'h40);
    end

    // --- clock stretching -------------------------------------------------------
    // The model holds SCL low for 3 us after every ACK. A master that ignores
    // it would count its high quarters while SCL is still low, so the high
    // time it finally produces would be short.
    stretch_en = 1; s0 = eeprom.stretches;
    measure = 1; clear_meas();
    ee_read(13'h1FE2, 3, rbuf, ok);
    measure = 0;
    stretch_en = 0;
    check("stretched read ACKed", {31'b0, ok}, 1);
    check("stretched 1FE2", {24'h0, rbuf[0]}, {24'h0, 8'(8'hC0 + 2 * 17)});
    check("stretched 1FE3", {24'h0, rbuf[1]}, {24'h0, 8'(8'hC0 + 3 * 17)});
    check("stretched 1FE4", {24'h0, rbuf[2]}, {24'h0, 8'(8'hC0 + 4 * 17)});
    check("model stretched after all 7 bytes", eeprom.stretches - s0, 7);
    if (max_low < stretch_ns - 20) begin
        $display("FAIL: longest SCL low %0t ns, the %0d ns stretch never showed", max_low, stretch_ns);
        errors++;
    end
    if (min_high < 2 * 32 * 20 - 40) begin
        $display("FAIL: SCL high %0t ns after a stretch, expected >= %0d", min_high, 2 * 32 * 20 - 40);
        errors++;
    end

    // --- ABORT mid-byte -----------------------------------------------------------
    wr(DATA, {EEPROM, 1'b0});
    wr(CMD, C_START | C_WRITE);
    repeat (400) @(negedge clk);              // somewhere inside the byte
    rd(STATUS, st); check("busy before abort", st & ST_BUSY, ST_BUSY);
    mon_off = 1;
    wr(CMD, C_ABORT);
    repeat (2) @(negedge clk);
    mon_off = 0;
    check("abort releases both lines", {30'b0, scl_oe, sda_oe}, 0);
    rd(STATUS, st); check("idle after abort", st & (ST_BUSY | ST_HELD), 0);
    // the model saw a START and is mid-byte; a clean START+STOP resets it
    put({EEPROM, 1'b0}, C_START | C_STOP, ack);
    check("bus usable after abort", {31'b0, ack}, 1);

    // --- IRQ follows BUSY -----------------------------------------------------------
    wr(IRQ_EN, 1);
    wr(DATA, {EEPROM, 1'b0});
    wr(CMD, C_START | C_WRITE | C_STOP);
    repeat (3) @(negedge clk);
    check("irq low while busy", {31'b0, irq}, 0);
    wait_idle();
    check("irq high when done", {31'b0, irq}, 1);
    wr(IRQ_EN, 0);

    // --- CMD ignored while busy ---------------------------------------------------
    s0 = eeprom.starts;
    wr(DATA, {EEPROM, 1'b0});
    wr(CMD, C_START | C_WRITE | C_STOP);
    wr(CMD, C_START | C_WRITE | C_STOP);      // dropped
    wait_idle();
    repeat (200) @(negedge clk);
    rd(STATUS, st);
    check("second CMD dropped", eeprom.starts - s0, 1);
    check("idle after dropped CMD", st & ST_BUSY, 0);

    // --- bus errors -------------------------------------------------------------------
    obi(0, I2C + 32'h14,  0, r, e); check("err: bad offset 0x14",  {31'b0,e}, 1);
    obi(1, I2C + 32'h100, 1, r, e); check("err: offset 0x100",     {31'b0,e}, 1);
    obi(0, 32'h2000_0000, 0, r, e); check("err: unmapped address", {31'b0,e}, 1);
    obi(0, OTHER + 32'h8, 0, r, e); check("no err: slot 0",        {31'b0,e}, 0);
                                    check("slot 0 rdata", r, 32'hDEAD_BEEF);
    obi(0, CLKDIV,        0, r, e); check("no err after err",      {31'b0,e}, 0);
                                    check("CLKDIV after errors", r, 32);

    // --- protocol monitor summary --------------------------------------------------
    check("master moved SDA while SCL high (not START/STOP)", sda_while_high, eeprom.starts + eeprom.stops);
    check("master moved SDA within a quarter of SCL falling", sda_too_soon, 0);

    $display("----------------------------------------");
    if (errors == 0) $display("PASS: tb_i2c_periph (%0d STARTs, %0d STOPs)", eeprom.starts, eeprom.stops);
    else             $display("FAIL: tb_i2c_periph, %0d error(s)", errors);
    $display("----------------------------------------");
    if (errors != 0) $fatal(1);
    $finish;
end

initial begin
    #20ms;
    $display("FAIL: tb_i2c_periph timeout");
    $fatal(1);
end

endmodule
