//////////////////////////////////////////////////////////////////////////////////
// tb_mic_periph.sv
//
// Unit test: obi_data_interconnect (2 slots) + mic_peripheral, with eight
// SBM100B-TDM behavioural models on the shared DATA line. No core.
//
// Clock is 50 MHz, the SoC frequency, and CLK_DIV = 8, so BCLK = 6.25 MHz
// and each mic runs at 24.414 kHz, exactly as on the board. BCLK/WS reach
// the mics and DATA comes back through a WIRE ns board delay each way, and
// the models launch DATA TCO ns after the BCLK rising edge.
//
// Mics 0-2 and 4-7 send {slot[2:0], frame_number[20:0]}, so every sample is
// checked exactly (right slot, no frame skipped or repeated). Mic 3 sends a
// 1 kHz sine; its frequency is measured from the samples read over OBI.
//
// Checks
//   - reset values of every register, DATA reads 0 with VALID = 0 when empty
//   - OBI error for an unused offset and for an offset outside the low byte
//   - BCLK period = 8 clocks, WS one BCLK wide, once every 256 BCLKs
//   - 600 frames of samples read over OBI: slot tags, frame continuity,
//     sign extension, and the 1 kHz tone on slot 3
//   - FRAMES counts TDM frames
//   - SLOT_MASK and FLUSH
//   - OVERRUN when nobody reads (sticky, write-1-to-clear), RX_FULL,
//     FLUSH clears both
//   - IRQ_EN / irq_o
//   - EN = 0 stops BCLK and WS low and zeroes FRAMES
//
// Needs no Xilinx IP. From fpga/scu35 in a Vivado shell:
//   xvlog -sv rtl/sync_fifo.sv rtl/tdm_master_rx.sv rtl/mic_peripheral.sv \
//             rtl/obi_data_interconnect.sv sim/mic/sbm100b_tdm_model.sv \
//             sim/mic/tb_mic_periph.sv
//   xelab tb_mic_periph -s tb_mic && xsim tb_mic -R
// or with Verilator 5 (Icarus 12 cannot elaborate obi_data_interconnect's
// 2-D packed parameters):
//   verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style \
//             --top-module tb_mic_periph rtl/sync_fifo.sv rtl/tdm_master_rx.sv \
//             rtl/mic_peripheral.sv rtl/obi_data_interconnect.sv \
//             sim/mic/sbm100b_tdm_model.sv sim/mic/tb_mic_periph.sv
//   ./obj_dir/Vtb_mic_periph
// Prints PASS or FAIL at the end; runs in about 29 ms of simulated time.
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps

module tb_mic_periph;

localparam int unsigned CLK_DIV       = 8;
localparam int unsigned CAPTURE_PHASE = 2;
localparam int unsigned FIFO_DEPTH    = 64;
localparam real         CLK_NS        = 20.0;                       // 50 MHz
localparam real         FS_HZ         = 1.0e9 / (CLK_NS * CLK_DIV * 256.0);
localparam real         TCO           = 15.0;                       // mic clock-to-out, ns
localparam real         WIRE          = 3.0;                        // board delay each way, ns
localparam int          TONE_SLOT     = 3;

localparam logic [31:0] MIC     = 32'h1004_0000;
localparam logic [31:0] OTHER   = 32'h1000_0000;

localparam logic [31:0] DATA    = MIC + 32'h00;
localparam logic [31:0] STATUS  = MIC + 32'h04;
localparam logic [31:0] CTRL    = MIC + 32'h08;
localparam logic [31:0] IRQ_EN  = MIC + 32'h0C;
localparam logic [31:0] FRAMES  = MIC + 32'h10;

localparam logic [31:0] ST_RX_VALID = 32'h1;
localparam logic [31:0] ST_RX_FULL  = 32'h2;
localparam logic [31:0] ST_OVERRUN  = 32'h4;
localparam logic [31:0] ST_RUNNING  = 32'h8;

logic clk = 0, rst_n = 0;
always #(CLK_NS/2) clk = ~clk;

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
    .SLV_BASE   ( { MIC,           OTHER         } ),
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

// ---------------------------------------------------------------------------
// DUT and board
// ---------------------------------------------------------------------------
logic bclk, ws, irq;
wire  sd_bus;               // shared DATA line at the mics
wire  sd_fpga;              // DATA at the FPGA pin
wire  bclk_mic, ws_mic;

pulldown (sd_bus);          // keeps the High-Z bits defined in simulation
assign #(WIRE) bclk_mic = bclk;
assign #(WIRE) ws_mic   = ws;
assign #(WIRE) sd_fpga  = sd_bus;

mic_peripheral #(
    .CLK_DIV(CLK_DIV), .CAPTURE_PHASE(CAPTURE_PHASE), .FIFO_DEPTH(FIFO_DEPTH)
) dut (
    .clk_i(clk), .rst_ni(rst_n),
    .req_i(s_req[1]), .gnt_o(s_gnt[1]), .rvalid_o(s_rvalid[1]),
    .addr_i(s_addr), .be_i(s_be), .we_i(s_we), .wdata_i(s_wdata),
    .rdata_o(s_rdata[1]), .err_o(s_err[1]),
    .mic_bclk_o(bclk), .mic_ws_o(ws), .mic_sd_i(sd_fpga),
    .irq_o(irq)
);

genvar g;
generate
    for (g = 0; g < 8; g++) begin : mics
        sbm100b_tdm_model #(
            .SLOT(g), .PATTERN(g == TONE_SLOT ? 1 : 0), .TONE_HZ(1000.0),
            .FS_HZ(FS_HZ), .TCO(TCO)
        ) mic (.bclk(bclk_mic), .ws(ws_mic), .data(sd_bus));
    end
endgenerate

// ---------------------------------------------------------------------------
int errors = 0;

task automatic check(input string what, input logic [31:0] got, exp);
    if (got !== exp) begin
        $display("FAIL: %s: got %h, expected %h", what, got, exp);
        errors++;
    end
endtask

// ---------------------------------------------------------------------------
// Pin monitor: BCLK period, WS width and spacing (in BCLK periods)
// ---------------------------------------------------------------------------
realtime last_rise = 0;
real     bclk_min = 1e9, bclk_max = 0;
int      bclk_n = 0, ws_high = 0, ws_gap = 0, ws_seen = 0;
int      ws_bad_width = 0, ws_bad_gap = 0;
bit      ws_sync = 0;          // a WS has been seen since the last enable

always @(posedge bclk) begin
    if (bclk_n > 0) begin
        if ($realtime - last_rise < bclk_min) bclk_min = $realtime - last_rise;
        if ($realtime - last_rise > bclk_max) bclk_max = $realtime - last_rise;
    end
    last_rise = $realtime;
    bclk_n++;

    if (ws) begin
        ws_high++;
        if (ws_sync && ws_gap != 256) ws_bad_gap++;
        ws_gap  = 1;
        ws_sync = 1;
        ws_seen++;
    end else begin
        if (ws_high > 1) ws_bad_width++;
        ws_high = 0;
        ws_gap++;
    end
end

// A restart after EN = 0 begins a new BCLK and WS sequence; don't count the
// pause as a long BCLK period or a long WS gap.
always @(negedge dut.en_q) begin
    ws_sync = 0;
    bclk_n  = 0;
end

// ---------------------------------------------------------------------------
// OBI access, driven and sampled on the falling edge (same as tb_spi_periph)
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

// ---------------------------------------------------------------------------
// Sample checking
// ---------------------------------------------------------------------------
int  per_slot  [8];
int  last_frm  [8];
real tone      [$];

task automatic clear_counts();
    for (int i = 0; i < 8; i++) begin per_slot[i] = 0; last_frm[i] = -1; end
endtask

// Check one DATA word that had VALID set.
task automatic take(input logic [31:0] v);
    automatic int          s   = v[26:24];
    automatic logic [23:0] smp = v[23:0];
    automatic int          sx  = $signed({{8{smp[23]}}, smp});   // what software does
    check("DATA [30:27]", {28'h0, v[30:27]}, 0);
    per_slot[s]++;
    if (s == TONE_SLOT) begin
        tone.push_back(real'(sx));
    end else begin
        check($sformatf("slot %0d tag", s), {29'h0, smp[23:21]}, s);
        if (last_frm[s] >= 0 && int'(smp[20:0]) != last_frm[s] + 1) begin
            $display("FAIL: slot %0d frame %0d after %0d", s, smp[20:0], last_frm[s]);
            errors++;
        end
        last_frm[s] = smp[20:0];
    end
endtask

// Read DATA for n_frames TDM frames (counted by WS), keeping up with the bus.
task automatic drain(input int n_frames);
    logic [31:0] v;
    automatic int start = ws_seen;
    while (ws_seen < start + n_frames) begin
        rd(DATA, v);
        if (v[31]) take(v);
    end
endtask

// Frequency from positive zero crossings, interpolated between samples.
function automatic real tone_hz();
    real mean = 0, t_first = -1, t_last = -1;
    int  n_cross = 0;
    foreach (tone[i]) mean += tone[i];
    mean /= tone.size();
    for (int i = 1; i < tone.size(); i++) begin
        real a = tone[i-1] - mean, b = tone[i] - mean;
        if (a < 0 && b >= 0) begin
            real t = (i - 1) + a / (a - b);
            if (t_first < 0) t_first = t;
            t_last = t;
            n_cross++;
        end
    end
    if (n_cross < 2) return 0;
    return (n_cross - 1) * FS_HZ / (t_last - t_first);
endfunction

// ---------------------------------------------------------------------------
// Test sequence
// ---------------------------------------------------------------------------
logic [31:0] r;
logic        e;
real         f;
int          frames_before;

initial begin
    clear_counts();
    repeat (5) @(negedge clk);
    rst_n = 1;

    // ---- reset values ----
    rd(STATUS, r);  check("STATUS reset", r, 0);
    rd(CTRL,   r);  check("CTRL reset",   r, 32'h0000_FF00);
    rd(IRQ_EN, r);  check("IRQ_EN reset", r, 0);
    rd(FRAMES, r);  check("FRAMES reset", r, 0);
    rd(DATA,   r);  check("DATA empty",   r, 0);
    check("irq reset", {31'h0, irq}, 0);
    check("BCLK idle", {31'h0, bclk}, 0);

    // ---- errors ----
    obi(0, MIC + 32'h14,  0, r, e); check("err offset 0x14",  {31'h0, e}, 1);
    obi(0, MIC + 32'h100, 0, r, e); check("err offset 0x100", {31'h0, e}, 1);
    obi(0, 32'h2000_0000, 0, r, e); check("err unmapped",     {31'h0, e}, 1);
    obi(0, OTHER, 0, r, e);         check("other slave",      r, 32'hDEAD_BEEF);

    // ---- enable, all 8 slots ----
    wr(CTRL, 32'h0000_FF01);
    rd(CTRL, r);    check("CTRL after enable", r, 32'h0000_FF01);
    rd(STATUS, r);  check("RUNNING", r & ST_RUNNING, ST_RUNNING);

    drain(600);                                 // about 24.6 ms of audio
    for (int i = 0; i < 8; i++)
        if (per_slot[i] < 590) begin
            $display("FAIL: slot %0d only %0d samples in 600 frames", i, per_slot[i]);
            errors++;
        end
    f = tone_hz();
    $display("slot %0d tone: %0d samples, %.2f Hz", TONE_SLOT, tone.size(), f);
    if (f < 990.0 || f > 1010.0) begin
        $display("FAIL: tone frequency %.2f Hz, expected 1000", f);
        errors++;
    end

    rd(FRAMES, r);
    if (r < 600 || r > 603) begin
        $display("FAIL: FRAMES = %0d after 600 frames", r);
        errors++;
    end
    rd(STATUS, r);  check("no OVERRUN while draining", r & ST_OVERRUN, 0);

    // ---- slot mask and flush: keep slots 0 and 5 only ----
    wr(CTRL, 32'h0000_2103);                    // mask 0x21, FLUSH, EN
    rd(STATUS, r);  check("FLUSH empties", r & ST_RX_VALID, 0);
    clear_counts();
    drain(20);
    for (int i = 0; i < 8; i++) begin
        if ((i == 0 || i == 5) && per_slot[i] < 19) begin
            $display("FAIL: masked-in slot %0d only %0d samples", i, per_slot[i]);
            errors++;
        end
        if (!(i == 0 || i == 5) && per_slot[i] != 0) begin
            $display("FAIL: masked-out slot %0d gave %0d samples", i, per_slot[i]);
            errors++;
        end
    end

    // ---- overrun: all slots, nobody reads for 10 frames (FIFO holds 8) ----
    wr(IRQ_EN, 32'h2);                          // irq on OVERRUN only
    wr(CTRL, 32'h0000_FF03);
    check("irq before overrun", {31'h0, irq}, 0);
    frames_before = ws_seen;
    wait (ws_seen == frames_before + 10);
    rd(STATUS, r);
    check("RX_FULL",  r & ST_RX_FULL, ST_RX_FULL);
    check("OVERRUN",  r & ST_OVERRUN, ST_OVERRUN);
    check("irq on overrun", {31'h0, irq}, 1);

    // write-1-to-clear while stopped, so nothing sets it again
    wr(CTRL, 32'h0000_FF00);                    // EN = 0, FIFO kept
    wr(STATUS, ST_OVERRUN);
    rd(STATUS, r);
    check("OVERRUN cleared", r & ST_OVERRUN, 0);
    check("still full",      r & ST_RX_FULL, ST_RX_FULL);
    check("irq after clear", {31'h0, irq}, 0);

    // the 64 kept samples are intact and in order
    clear_counts();
    for (int i = 0; i < FIFO_DEPTH; i++) begin
        rd(DATA, r);
        check("VALID in full FIFO", {31'h0, r[31]}, 1);
        take(r);
    end
    rd(DATA, r);    check("DATA after drain", r, 0);

    // ---- RX_VALID interrupt ----
    wr(IRQ_EN, 32'h1);
    check("irq empty", {31'h0, irq}, 0);
    wr(CTRL, 32'h0000_FF01);
    tone.delete();
    wait (dut.rx_empty == 1'b0);
    @(negedge clk);
    check("irq RX_VALID", {31'h0, irq}, 1);
    wr(IRQ_EN, 32'h0);
    check("irq disabled", {31'h0, irq}, 0);

    // ---- disable: BCLK and WS stop low, FRAMES back to 0 ----
    wr(CTRL, 32'h0000_FF02);                    // EN = 0 and FLUSH
    repeat (4 * CLK_DIV) @(negedge clk);
    check("BCLK stopped low", {31'h0, bclk}, 0);
    check("WS stopped low",   {31'h0, ws},   0);
    rd(FRAMES, r);  check("FRAMES after disable", r, 0);
    rd(STATUS, r);  check("STATUS after disable", r, 0);

    // ---- pin timing summary ----
    if (bclk_min != CLK_NS * CLK_DIV || bclk_max != CLK_NS * CLK_DIV) begin
        $display("FAIL: BCLK period %.1f to %.1f ns, expected %.1f",
                 bclk_min, bclk_max, CLK_NS * CLK_DIV);
        errors++;
    end
    check("WS wider than 1 BCLK", ws_bad_width, 0);
    check("WS not every 256 BCLKs", ws_bad_gap, 0);

    $display("BCLK %.3f MHz, fs %.3f kHz, %0d frames seen",
             1.0e3 / bclk_min, FS_HZ / 1.0e3, ws_seen);
    if (errors == 0) $display("PASS");
    else             $display("FAIL: %0d errors", errors);
    $finish;
end

// Watchdog
initial begin
    #50ms;
    $display("FAIL: timeout");
    $finish;
end

endmodule
