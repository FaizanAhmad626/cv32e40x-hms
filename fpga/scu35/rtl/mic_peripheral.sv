`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: mic_peripheral
//
// TDM8 microphone receiver as an OBI slave. Wraps tdm_master_rx, which makes
// the FPGA the bus master: it drives BCLK and WS to the sensiBel SB-POLARIS
// board (8 SBM100B-TDM mics, through J2 on PMOD0) and shifts in DATA.
// Every received sample goes into a FIFO, tagged with its slot number.
//
// Clocking: BCLK = clk_i / CLK_DIV. In the SoC clk_i is 50 MHz and CLK_DIV is
// 8, so BCLK = 6.25 MHz (mic Normal mode) and every mic delivers
// 6.25 MHz / 256 = 24.414 kHz. That is the same bus timing that passed the
// 1 kHz tone test in mic_test (100 MHz / 16).
//
// Register map, offsets from the slot base (MIC_BASE = 0x1004_0000):
//
//   0x00  DATA    R   pop and return the FIFO head:
//                       [23:0]  sample, signed 24-bit (sign-extend in software)
//                       [26:24] slot, 0 to 7 (which mic)
//                       [31]    VALID, 1 = this read returned a sample
//                     Reads 0 (VALID = 0) and pops nothing if the FIFO is
//                     empty, so software can poll DATA alone.
//   0x04  STATUS  R   [0] RX_VALID    FIFO holds at least one sample
//                     [1] RX_FULL     FIFO has no room
//                     [2] OVERRUN     sticky: a sample arrived while RX_FULL
//                                     and was dropped
//                     [3] RUNNING     BCLK and WS are being driven (= EN)
//                 W   write 1 to [2] to clear OVERRUN
//   0x08  CTRL    RW  [0]    EN         1 starts BCLK and WS, 0 stops both low
//                                       (the mics go to sleep)
//                     [1]    FLUSH      write 1 to empty the FIFO and clear
//                                       OVERRUN; reads 0
//                     [15:8] SLOT_MASK  slots that are stored; reset 0xFF
//   0x0C  IRQ_EN  RW  [0] raise irq_o while RX_VALID
//                     [1] raise irq_o while OVERRUN
//   0x10  FRAMES  R   TDM frames since EN was set (one per 1/24.414 kHz).
//                     Held at 0 while EN = 0. Software uses it to wait out
//                     the mic start-up time and to time a capture.
//
//   any other offset in the slot -> OBI error response
//
// FIFO_DEPTH 64 holds 8 full frames of all 8 mics (328 us at 24.414 kHz),
// which is the slack software has between reads before OVERRUN.
//
// Same OBI structure as the other peripherals: no address-map decode here,
// gnt = req, rvalid one cycle later, rdata/err registered with rvalid.
//////////////////////////////////////////////////////////////////////////////////


module mic_peripheral
#(
    parameter int unsigned  CLK_DIV         = 8,    // clk_i cycles per BCLK, even, >= 4
    parameter int unsigned  CAPTURE_PHASE   = 2,    // DATA read this many clk_i cycles after BCLK falls
    parameter int unsigned  FIFO_DEPTH      = 64    // power of two
)
(
    input   logic           clk_i,
    input   logic           rst_ni,

    // -----------------------------------------------------------------------
    // OBI slave
    // -----------------------------------------------------------------------
    input   logic           req_i,
    output  logic           gnt_o,
    output  logic           rvalid_o,
    input   logic   [31:0]  addr_i,
    input   logic   [ 3:0]  be_i,
    input   logic           we_i,
    input   logic   [31:0]  wdata_i,
    output  logic   [31:0]  rdata_o,
    output  logic           err_o,

    // -----------------------------------------------------------------------
    // Pins and interrupt
    // -----------------------------------------------------------------------
    output  logic           mic_bclk_o,
    output  logic           mic_ws_o,
    input   logic           mic_sd_i,
    output  logic           irq_o       // level, not yet wired to the core
    );

localparam logic [7:0] REG_DATA   = 8'h00;
localparam logic [7:0] REG_STATUS = 8'h04;
localparam logic [7:0] REG_CTRL   = 8'h08;
localparam logic [7:0] REG_IRQ_EN = 8'h0C;
localparam logic [7:0] REG_FRAMES = 8'h10;

// ---------------------------------------------------------------------------
// Register select. Only the low byte picks the register; the rest of the
// 64 KB slot is an error rather than an alias.
// ---------------------------------------------------------------------------
logic   [7:0]   offset;
logic           in_range;
logic           sel_data, sel_status, sel_ctrl, sel_irqen, sel_frames;
logic           wr, rd;

assign offset     = addr_i[7:0];
assign in_range   = (addr_i[15:8] == 8'h00);
assign sel_data   = in_range & (offset == REG_DATA);
assign sel_status = in_range & (offset == REG_STATUS);
assign sel_ctrl   = in_range & (offset == REG_CTRL);
assign sel_irqen  = in_range & (offset == REG_IRQ_EN);
assign sel_frames = in_range & (offset == REG_FRAMES);

assign wr         = req_i &  we_i;
assign rd         = req_i & ~we_i;

assign gnt_o      = req_i;     // never stalls

// ---------------------------------------------------------------------------
// Control registers
// ---------------------------------------------------------------------------
logic           en_q;
logic   [7:0]   mask_q;
logic   [1:0]   irq_en_q;
logic           overrun_q;
logic   [31:0]  frames_q;
logic           flush;

assign flush = wr & sel_ctrl & be_i[0] & wdata_i[1];

// ---------------------------------------------------------------------------
// TDM receiver -> FIFO
// ---------------------------------------------------------------------------
logic signed [23:0] sample;
logic        [ 2:0] slot;
logic               sample_valid;
logic               frame_start;

tdm_master_rx
#(
    .CLK_DIV        (   CLK_DIV         ),
    .NUM_SLOTS      (   8               ),
    .SLOT_BITS      (   32              ),
    .DATA_BITS      (   24              ),
    .SYNC_STAGES    (   2               ),
    .CAPTURE_PHASE  (   CAPTURE_PHASE   )
)
tdm_rx
(
    .clk_i          (   clk_i           ),
    .rst_ni         (   rst_ni          ),
    .en_i           (   en_q            ),
    .slot_mask_i    (   mask_q          ),
    .bclk_o         (   mic_bclk_o      ),
    .ws_o           (   mic_ws_o        ),
    .sd_i           (   mic_sd_i        ),
    .sample_o       (   sample          ),
    .slot_o         (   slot            ),
    .sample_valid_o (   sample_valid    ),
    .frame_start_o  (   frame_start     )
);

logic           rx_pop;
logic   [26:0]  rx_head;
logic           rx_empty, rx_full;

assign rx_pop = rd & sel_data;

// FLUSH resets the FIFO pointers for one cycle.
sync_fifo #(.WIDTH(27), .DEPTH(FIFO_DEPTH)) rx_fifo (
    .clk_i   ( clk_i                    ),
    .rst_ni  ( rst_ni & ~flush          ),
    .push_i  ( sample_valid             ),
    .wdata_i ( {slot, sample}           ),
    .pop_i   ( rx_pop                   ),
    .rdata_o ( rx_head                  ),
    .empty_o ( rx_empty                 ),
    .full_o  ( rx_full                  )
);

// ---------------------------------------------------------------------------
// Register writes
// ---------------------------------------------------------------------------
always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
        en_q      <= 1'b0;
        mask_q    <= 8'hFF;
        irq_en_q  <= '0;
        overrun_q <= 1'b0;
        frames_q  <= '0;
    end else begin
        if (wr & sel_ctrl & be_i[0]) en_q   <= wdata_i[0];
        if (wr & sel_ctrl & be_i[1]) mask_q <= wdata_i[15:8];

        if (wr & sel_irqen & be_i[0]) irq_en_q <= wdata_i[1:0];

        // Set wins over clear, so a sample dropped in the same cycle is not
        // lost. sync_fifo refuses a push while full even if it pops in the
        // same cycle, so "valid while full" is exactly a dropped sample.
        if ((wr & sel_status & be_i[0] & wdata_i[2]) | flush) overrun_q <= 1'b0;
        if (sample_valid & rx_full)                           overrun_q <= 1'b1;

        if (!en_q)            frames_q <= '0;
        else if (frame_start) frames_q <= frames_q + 1'b1;
    end
end

// ---------------------------------------------------------------------------
// Read mux and response
// ---------------------------------------------------------------------------
logic   [31:0]  status;
logic   [31:0]  rdata_d;
logic           hit;

assign status = { 28'h0, en_q, overrun_q, rx_full, ~rx_empty };
assign hit    = sel_data | sel_status | sel_ctrl | sel_irqen | sel_frames;

always_comb begin
    rdata_d = 32'h0;
    if (rd) begin
        unique case (1'b1)
            sel_data:   rdata_d = rx_empty ? 32'h0 : {1'b1, 4'h0, rx_head};
            sel_status: rdata_d = status;
            sel_ctrl:   rdata_d = {16'h0, mask_q, 7'h0, en_q};
            sel_irqen:  rdata_d = {30'h0, irq_en_q};
            sel_frames: rdata_d = frames_q;
            default:    rdata_d = 32'h0;
        endcase
    end
end

always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
        rvalid_o <= 1'b0;
        rdata_o  <= '0;
        err_o    <= 1'b0;
    end else begin
        rvalid_o <= req_i;
        rdata_o  <= rdata_d;
        err_o    <= req_i & ~hit;
    end
end

assign irq_o = (irq_en_q[0] & ~rx_empty) | (irq_en_q[1] & overrun_q);

endmodule
