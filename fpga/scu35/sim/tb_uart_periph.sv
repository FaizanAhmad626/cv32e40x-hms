//////////////////////////////////////////////////////////////////////////////////
// tb_uart_periph.sv
//
// Unit test: obi_data_interconnect (2 slots) + uart_peripheral, TX looped
// back to RX. No core. Uses a fast clock/baud ratio (div = 20) so it runs
// in well under a second.
//
// Checks
//   - BAUDDIV reset value and read/write
//   - TX -> RX loopback, byte order, RX_VALID / TX_IDLE flags
//   - reading DATA with RX empty returns 0 and has no side effect
//   - TX_FULL back-pressure, RX overrun (sticky, write-1-to-clear)
//   - frame error on a low stop bit (sticky, write-1-to-clear)
//   - IRQ_EN / irq_o
//   - OBI error for an unused register offset and for an unmapped address
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps

module tb_uart_periph;

localparam int unsigned CLK_HZ = 1_000_000;
localparam int unsigned BAUD   = 50_000;        // div = 20
localparam logic [31:0] UART   = 32'h1001_0000;
localparam logic [31:0] OTHER  = 32'h1000_0000; // slot 0, a dummy slave

localparam logic [31:0] DATA    = UART + 32'h0;
localparam logic [31:0] STATUS  = UART + 32'h4;
localparam logic [31:0] BAUDDIV = UART + 32'h8;
localparam logic [31:0] IRQ_EN  = UART + 32'hC;

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
    .SLV_BASE   ( { UART,          OTHER         } ),
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

logic tx, rx, irq, loop_en = 1'b1, rx_force = 1'b1;
assign rx = loop_en ? tx : rx_force;

uart_peripheral #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .FIFO_DEPTH(16)) dut (
    .clk_i(clk), .rst_ni(rst_n),
    .req_i(s_req[1]), .gnt_o(s_gnt[1]), .rvalid_o(s_rvalid[1]),
    .addr_i(s_addr), .be_i(s_be), .we_i(s_we), .wdata_i(s_wdata),
    .rdata_o(s_rdata[1]), .err_o(s_err[1]),
    .uart_rx_i(rx), .uart_tx_o(tx), .irq_o(irq)
);

// ---------------------------------------------------------------------------
int errors = 0;

task automatic check(input string what, input logic [31:0] got, exp);
    if (got !== exp) begin
        $display("FAIL: %s: got %h, expected %h", what, got, exp);
        errors++;
    end
endtask

// One OBI transfer: hold req until gnt, then wait for rvalid.
// The TB drives and samples on the falling edge so it never races the
// design's rising-edge flops.
task automatic obi(input logic w, input logic [31:0] a, input logic [31:0] d,
                   output logic [31:0] rd, output logic e);
    @(negedge clk);
    req = 1; we = w; addr = a; wdata = d;
    #1;                             // let the combinational gnt settle
    while (!gnt) begin @(negedge clk); #1; end
    @(negedge clk);                 // accepted on the rising edge in between
    req = 0;                        // exactly one cycle, so exactly one transfer
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

task automatic wait_tx_idle();
    logic [31:0] st;
    do rd(STATUS, st); while (!st[1]);
    repeat (40) @(posedge clk);     // let RX finish the last stop bit
endtask

initial begin
    logic [31:0] r, st;
    logic        e;

    repeat (5) @(posedge clk);
    rst_n = 1;

    // --- reset values, BAUDDIV --------------------------------------------
    rd(BAUDDIV, r);  check("BAUDDIV reset", r, 20);
    rd(STATUS,  r);  check("STATUS reset",  r, 32'h2);     // TX_IDLE only
    rd(DATA,    r);  check("DATA empty",    r, 0);
    rd(STATUS,  r);  check("STATUS after empty read", r, 32'h2);
    wr(BAUDDIV, 32'd33); rd(BAUDDIV, r); check("BAUDDIV rw", r, 33);
    wr(BAUDDIV, 32'd20);

    // --- loopback ----------------------------------------------------------
    for (int i = 0; i < 5; i++) wr(DATA, 32'h41 + i);
    wait_tx_idle();
    rd(STATUS, st);  check("RX_VALID after loopback", st & 32'h4, 32'h4);
    for (int i = 0; i < 5; i++) begin
        rd(DATA, r); check($sformatf("loopback byte %0d", i), r, 32'h41 + i);
    end
    rd(STATUS, st);  check("RX drained", st & 32'h4, 0);

    // --- IRQ ---------------------------------------------------------------
    wr(IRQ_EN, 32'h1);
    check("irq low, RX empty", {31'b0, irq}, 0);
    wr(DATA, 32'h5A); wait_tx_idle();
    check("irq high on RX_VALID", {31'b0, irq}, 1);
    rd(DATA, r);      check("irq byte", r, 32'h5A);
    @(negedge clk);
    check("irq low after drain", {31'b0, irq}, 0);
    wr(IRQ_EN, 32'h2);
    check("irq high on TX_IDLE", {31'b0, irq}, 1);
    wr(IRQ_EN, 32'h0);

    // --- TX_FULL and RX overrun: send 20 bytes, read none ------------------
    begin
        int sent = 0;
        bit saw_full = 0;
        while (sent < 20) begin
            rd(STATUS, st);
            if (st[0]) saw_full = 1;
            else begin wr(DATA, 32'h60 + sent); sent++; end
        end
        check("TX_FULL was seen", {31'b0, saw_full}, 1);
    end
    wait_tx_idle();
    rd(STATUS, st);
    check("RX_FULL",     st & 32'h08, 32'h08);
    check("RX_OVERRUN",  st & 32'h10, 32'h10);
    for (int i = 0; i < 16; i++) begin
        rd(DATA, r); check($sformatf("overrun keep byte %0d", i), r, 32'h60 + i);
    end
    rd(STATUS, st);  check("overrun sticky", st & 32'h10, 32'h10);
    wr(STATUS, 32'h10);
    rd(STATUS, st);  check("overrun cleared", st & 32'h10, 0);

    // --- frame error: drive a byte with a low stop bit ---------------------
    loop_en = 0;
    rx_force = 1; repeat (40) @(posedge clk);
    rx_force = 0; repeat (20) @(posedge clk);               // start
    for (int i = 0; i < 8; i++) begin
        rx_force = (8'hC3 >> i) & 1; repeat (20) @(posedge clk);
    end
    rx_force = 0; repeat (20) @(posedge clk);               // bad stop
    rx_force = 1; repeat (60) @(posedge clk);
    rd(STATUS, st);  check("FRAME_ERR", st & 32'h20, 32'h20);
    rd(DATA, r);     check("frame err byte still delivered", r, 32'hC3);
    wr(STATUS, 32'h20);
    rd(STATUS, st);  check("FRAME_ERR cleared", st & 32'h20, 0);
    loop_en = 1;

    // --- bus errors --------------------------------------------------------
    obi(0, UART + 32'h10,  0, r, e); check("err: bad offset 0x10",   {31'b0,e}, 1);
    obi(1, UART + 32'h100, 1, r, e); check("err: offset 0x100",      {31'b0,e}, 1);
    obi(0, 32'h2000_0000,  0, r, e); check("err: unmapped address",  {31'b0,e}, 1);
    obi(0, OTHER + 32'h8,  0, r, e); check("no err: slot 0",         {31'b0,e}, 0);
                                     check("slot 0 rdata", r, 32'hDEAD_BEEF);
    obi(0, BAUDDIV,        0, r, e); check("no err after err",       {31'b0,e}, 0);
                                     check("BAUDDIV after errors", r, 20);

    // --- back-to-back transfers (req held high across cycles) --------------
    @(negedge clk);
    req = 1; we = 0; addr = OTHER;
    @(negedge clk);                         // OTHER accepted
    addr = BAUDDIV;
    check("b2b rvalid 1", {31'b0, rvalid}, 1);
    check("b2b rdata 1",  rdata, 32'hDEAD_BEEF);
    @(negedge clk);                         // BAUDDIV accepted
    req = 0;
    check("b2b rvalid 2", {31'b0, rvalid}, 1);
    check("b2b rdata 2",  rdata, 20);

    $display("----------------------------------------");
    if (errors == 0) $display("PASS: tb_uart_periph");
    else             $display("FAIL: tb_uart_periph, %0d error(s)", errors);
    $display("----------------------------------------");
    if (errors != 0) $fatal(1);
    $finish;
end

initial begin
    #200ms;
    $display("FAIL: tb_uart_periph timeout");
    $fatal(1);
end

endmodule
