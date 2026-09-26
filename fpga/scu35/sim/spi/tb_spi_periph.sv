//////////////////////////////////////////////////////////////////////////////////
// tb_spi_periph.sv
//
// Unit test: obi_data_interconnect (2 slots) + spi_peripheral. No core.
//
// MISO comes either from MOSI (loopback, what the PMOD jumper does on the
// board) or from a behavioural SPI slave written independently of the RTL.
// The slave follows the textbook mode definitions, records every byte it
// receives, and answers with a known sequence, so both directions and all
// four modes are checked against something other than the design itself.
// Its MISO reaches the design MISO_DLY ns after the SCLK edge, standing in
// for pad, board and slave delays.
//
// Checks
//   - reset values, register read/write
//   - modes 0-3 at two clock rates, several bytes per CS assertion, both
//     directions against the slave model
//   - 16 SCLK edges per byte, SCLK idle level = CPOL, half period =
//     CLKDIV cycles, CLKDIV below 4 clamped to 4
//   - CS only changes while SCLK is idle
//   - loopback (MOSI -> MISO)
//   - TX_FULL back-pressure, RX overrun (sticky, write-1-to-clear)
//   - IRQ_EN / irq_o
//   - OBI error for unused offsets and an unmapped address
//
// Needs no Xilinx IP. From fpga/scu35 in a Vivado shell:
//   xvlog -sv rtl/sync_fifo.sv rtl/spi_master.sv rtl/spi_peripheral.sv \
//             rtl/obi_data_interconnect.sv sim/spi/tb_spi_periph.sv
//   xelab tb_spi_periph -s tb_spi && xsim tb_spi -R
// or add this file to sim_1 and set tb_spi_periph as the simulation top.
// Prints PASS or FAIL at the end; runs in about 63 us of simulated time.
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps

module tb_spi_periph;

localparam int unsigned CLK_HZ  = 100_000_000;   // 10 ns clock
localparam int unsigned SCLK_HZ = 10_000_000;    // CLKDIV reset = 5
localparam int unsigned MISO_DLY = 15;           // ns, < 2 clk cycles
localparam logic [31:0] SPI     = 32'h1002_0000;
localparam logic [31:0] OTHER   = 32'h1000_0000;

localparam logic [31:0] DATA    = SPI + 32'h00;
localparam logic [31:0] STATUS  = SPI + 32'h04;
localparam logic [31:0] CTRL    = SPI + 32'h08;
localparam logic [31:0] CLKDIV  = SPI + 32'h0C;
localparam logic [31:0] CS      = SPI + 32'h10;
localparam logic [31:0] IRQ_EN  = SPI + 32'h14;

logic clk = 0, rst_n = 0;
always #5 clk = ~clk;

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
    .SLV_BASE   ( { SPI,           OTHER         } ),
    .SLV_MASK   ( { 32'hFFFF_0000, 32'hFFFF_0000 } )
) ic (
    .clk_i(clk), .rst_ni(rst_n),
    .data_req_i(req), .data_gnt_o(gnt), .data_rvalid_o(rvalid),
    .data_addr_i(addr), .data_be_i(be), .data_we_i(we), .data_wdata_i(wdata),
    .data_memtype_i('0), .data_prot_i('0), .data_dbg_i(1'b0), .data_atop_i('0),
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

logic sclk, mosi, miso, cs_n, irq;
logic loop_en = 1'b0;
logic slv_miso = 1'b0;
assign #(MISO_DLY) miso = loop_en ? mosi : slv_miso;

spi_peripheral #(.CLK_HZ(CLK_HZ), .SCLK_HZ(SCLK_HZ), .FIFO_DEPTH(16)) dut (
    .clk_i(clk), .rst_ni(rst_n),
    .req_i(s_req[1]), .gnt_o(s_gnt[1]), .rvalid_o(s_rvalid[1]),
    .addr_i(s_addr), .be_i(s_be), .we_i(s_we), .wdata_i(s_wdata),
    .rdata_o(s_rdata[1]), .err_o(s_err[1]),
    .spi_sclk_o(sclk), .spi_mosi_o(mosi), .spi_miso_i(miso), .spi_cs_no(cs_n),
    .irq_o(irq)
);

// ---------------------------------------------------------------------------
int errors = 0;

task automatic check(input string what, input logic [31:0] got, exp);
    if (got !== exp) begin
        $display("FAIL: %s: got %h, expected %h", what, got, exp);
        errors++;
    end
endtask

// ---------------------------------------------------------------------------
// Behavioural SPI slave. Mode comes from the TB (m_cpol/m_cpha), not the DUT.
// Replies are 0xA5 ^ n for n = 0, 1, 2, ... across the whole test.
// ---------------------------------------------------------------------------
logic       m_cpol = 0, m_cpha = 0;
logic [7:0] slv_got[$];             // bytes the slave received
logic [7:0] slv_sent[$];            // bytes the slave answered with
logic [7:0] s_tx, s_rx;
int         s_out, s_in, s_n = 0;

function automatic logic [7:0] next_reply();
    logic [7:0] r = 8'hA5 ^ 8'(s_n);
    s_n++;
    return r;
endfunction

always @(negedge cs_n) if (!loop_en) begin
    s_tx = next_reply(); s_in = 0; s_rx = 0;
    if (!m_cpha) begin slv_miso = s_tx[7]; s_out = 1; end
    else         begin s_out = 0; end
end

always @(sclk) if (!cs_n && !loop_en) begin
    automatic logic leading = (sclk != m_cpol);     // moving away from idle
    automatic logic smp     = leading ^ m_cpha;
    if (smp) begin
        s_rx = {s_rx[6:0], mosi};
        if (++s_in == 8) begin
            slv_got.push_back(s_rx);
            slv_sent.push_back(s_tx);
            s_in = 0;
        end
    end else begin
        if (s_out == 8) begin s_tx = next_reply(); s_out = 0; end
        slv_miso = s_tx[7 - s_out];
        s_out++;
    end
end

// ---------------------------------------------------------------------------
// Pin monitor: edge count per CS window, shortest half period, CS vs SCLK
// ---------------------------------------------------------------------------
int      edges = 0;
realtime last_edge = 0, min_half = 1e9;
logic    in_frame = 0;

always @(sclk) if (!cs_n) begin
    if (in_frame && ($realtime - last_edge) < min_half) min_half = $realtime - last_edge;
    last_edge = $realtime;
    in_frame  = 1;
    edges++;
end

always @(cs_n) if (rst_n) begin
    if (sclk !== m_cpol) begin
        $display("FAIL: CS changed at %0t with SCLK = %b, CPOL = %b", $time, sclk, m_cpol);
        errors++;
    end
    in_frame = 0;
end

// ---------------------------------------------------------------------------
// OBI access, driven and sampled on the falling edge (same as tb_uart_periph)
// ---------------------------------------------------------------------------
task automatic obi(input logic w, input logic [31:0] a, input logic [31:0] d,
                   output logic [31:0] rd, output logic e);
    @(negedge clk);
    req = 1; we = w; addr = a; wdata = d;
    #1;
    while (!gnt) begin @(negedge clk); #1; end
    @(negedge clk);
    req = 0;
    while (!rvalid) @(negedge clk);
    rd = rdata; e = err;
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

task automatic wait_idle();
    logic [31:0] st;
    do rd(STATUS, st); while (!st[1]);
endtask

// One CS window: send n bytes, compare with the slave model both ways.
task automatic xfer_mode(input int mode, input int div, input int n);
    logic [31:0] r;
    logic [7:0]  sent[$];
    string       tag = $sformatf("mode %0d div %0d", mode, div);

    sent.delete();          // some simulators keep task-local queues between calls
    m_cpha = mode[0]; m_cpol = mode[1];
    wr(CTRL, mode);
    wr(CLKDIV, div);
    repeat (4) @(negedge clk);
    check({tag, " SCLK idle = CPOL"}, {31'b0, sclk}, {31'b0, m_cpol});

    slv_got.delete(); slv_sent.delete();
    edges = 0; min_half = 1e9;

    wr(CS, 1);
    for (int i = 0; i < n; i++) begin
        automatic logic [7:0] b = 8'h3C + 8'(mode * 16 + i * 7);
        sent.push_back(b);
        wr(DATA, b);
    end
    wait_idle();
    wr(CS, 0);

    check({tag, " SCLK edges"}, edges, 16 * n);
    check({tag, " half period"}, int'(min_half), div * 10);
    check({tag, " slave byte count"}, slv_got.size(), n);
    for (int i = 0; i < n && i < slv_got.size(); i++) begin
        check($sformatf("%s MOSI byte %0d", tag, i), slv_got[i], sent[i]);
        rd(DATA, r);
        check($sformatf("%s MISO byte %0d", tag, i), r, slv_sent[i]);
    end
    rd(STATUS, r);
    check({tag, " RX drained"}, r & 32'h4, 0);
endtask

// ---------------------------------------------------------------------------
initial begin
    logic [31:0] r, st;
    logic        e;

    repeat (5) @(posedge clk);
    rst_n = 1;

    // --- reset values and register access ---------------------------------
    rd(CLKDIV, r);  check("CLKDIV reset", r, 5);
    rd(STATUS, r);  check("STATUS reset", r, 32'h2);        // IDLE only
    rd(CTRL,   r);  check("CTRL reset",   r, 0);
    rd(CS,     r);  check("CS reset",     r, 0);
    rd(IRQ_EN, r);  check("IRQ_EN reset", r, 0);
    rd(DATA,   r);  check("DATA empty",   r, 0);
    check("cs_n idles high", {31'b0, cs_n}, 1);
    check("sclk idles low",  {31'b0, sclk}, 0);
    m_cpol = 1;                                // monitor: SCLK now idles high
    wr(CTRL,   32'hFFFF_FFFF); rd(CTRL,   r); check("CTRL rw",   r, 3);
    wr(CLKDIV, 32'hABCD_1234); rd(CLKDIV, r); check("CLKDIV rw", r, 32'h1234);
    wr(CS,     32'h3);         rd(CS,     r); check("CS rw",     r, 1);
    check("cs_n low when CS = 1", {31'b0, cs_n}, 0);
    wr(CS, 0);
    wr(CTRL, 0); m_cpol = 0;

    // --- all four modes, two rates, against the slave model ---------------
    for (int mode = 0; mode < 4; mode++) begin
        xfer_mode(mode, 4, 5);
        xfer_mode(mode, 7, 3);
    end

    // --- CLKDIV below the minimum runs at 4 -------------------------------
    begin
        m_cpha = 0; m_cpol = 0;
        wr(CTRL, 0); wr(CLKDIV, 1);
        edges = 0; min_half = 1e9; slv_got.delete(); slv_sent.delete();
        wr(CS, 1); wr(DATA, 8'h81); wait_idle(); wr(CS, 0);
        check("clamp half period", int'(min_half), 40);
        check("clamp MOSI", slv_got.size() ? slv_got[0] : 8'hxx, 8'h81);
        rd(DATA, r); check("clamp MISO", r, slv_sent.size() ? slv_sent[0] : 8'hxx);
    end

    // --- loopback, what the PMOD jumper does ------------------------------
    loop_en = 1;
    wr(CLKDIV, 5);
    for (int mode = 0; mode < 4; mode++) begin
        m_cpha = mode[0]; m_cpol = mode[1];
        wr(CTRL, mode); repeat (4) @(negedge clk);
        wr(CS, 1);
        for (int i = 0; i < 4; i++) wr(DATA, 8'h10 * mode + 8'h5A + i);
        wait_idle();
        wr(CS, 0);
        for (int i = 0; i < 4; i++) begin
            rd(DATA, r);
            check($sformatf("loopback mode %0d byte %0d", mode, i), r, 8'(8'h10 * mode + 8'h5A + i));
        end
    end
    m_cpha = 0; m_cpol = 0; wr(CTRL, 0);

    // --- IRQ ---------------------------------------------------------------
    wr(IRQ_EN, 32'h1);
    check("irq low, RX empty", {31'b0, irq}, 0);
    wr(DATA, 8'hC7); wait_idle();
    check("irq high on RX_VALID", {31'b0, irq}, 1);
    rd(DATA, r);     check("irq byte", r, 8'hC7);
    @(negedge clk);
    check("irq low after drain", {31'b0, irq}, 0);
    wr(IRQ_EN, 32'h2);
    check("irq high on IDLE", {31'b0, irq}, 1);
    wr(DATA, 8'h00); @(negedge clk);
    check("irq low while busy", {31'b0, irq}, 0);
    wait_idle(); rd(DATA, r);
    wr(IRQ_EN, 32'h0);

    // --- TX_FULL and RX overrun: send 20 bytes, read none ------------------
    begin
        int  sent = 0;
        bit  saw_full = 0;
        while (sent < 20) begin
            rd(STATUS, st);
            if (st[0]) saw_full = 1;
            else begin wr(DATA, 32'h60 + sent); sent++; end
        end
        check("TX_FULL was seen", {31'b0, saw_full}, 1);
    end
    wait_idle();
    rd(STATUS, st);
    check("RX_FULL",    st & 32'h08, 32'h08);
    check("RX_OVERRUN", st & 32'h10, 32'h10);
    for (int i = 0; i < 16; i++) begin
        rd(DATA, r); check($sformatf("overrun keep byte %0d", i), r, 32'h60 + i);
    end
    rd(STATUS, st);  check("overrun sticky", st & 32'h10, 32'h10);
    wr(STATUS, 32'h10);
    rd(STATUS, st);  check("overrun cleared", st, 32'h2);
    loop_en = 0;

    // --- bus errors --------------------------------------------------------
    obi(0, SPI + 32'h18,  0, r, e); check("err: bad offset 0x18",  {31'b0,e}, 1);
    obi(1, SPI + 32'h100, 1, r, e); check("err: offset 0x100",     {31'b0,e}, 1);
    obi(0, 32'h2000_0000, 0, r, e); check("err: unmapped address", {31'b0,e}, 1);
    obi(0, OTHER + 32'h8, 0, r, e); check("no err: slot 0",        {31'b0,e}, 0);
                                    check("slot 0 rdata", r, 32'hDEAD_BEEF);
    obi(0, CLKDIV,        0, r, e); check("no err after err",      {31'b0,e}, 0);
                                    check("CLKDIV after errors", r, 5);
    rd(STATUS, st); check("no stray TX from errored write", st, 32'h2);

    $display("----------------------------------------");
    if (errors == 0) $display("PASS: tb_spi_periph");
    else             $display("FAIL: tb_spi_periph, %0d error(s)", errors);
    $display("----------------------------------------");
    if (errors != 0) $fatal(1);
    $finish;
end

initial begin
    #20ms;
    $display("FAIL: tb_spi_periph timeout");
    $fatal(1);
end

endmodule
