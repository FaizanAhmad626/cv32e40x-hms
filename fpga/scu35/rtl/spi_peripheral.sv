`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: spi_peripheral
//
// SPI master as an OBI slave: 8-bit frames, MSB first, modes 0-3, one chip
// select under software control, a FIFO on each direction.
//
// Every byte written to DATA becomes one 8-clock frame, and the byte clocked
// in during that frame lands in the RX FIFO. To read from a slave, write
// dummy bytes and read back what arrives.
//
// Register map, offsets from the slot base (SPI_BASE = 0x1002_0000):
//
//   0x00  DATA    W   push wdata[7:0] into the TX FIFO
//                     (dropped if TX_FULL, so poll STATUS first)
//                 R   pop and return the RX FIFO head in [7:0]
//                     (reads 0 and pops nothing if RX is empty)
//   0x04  STATUS  R   [0] TX_FULL     TX FIFO has no room
//                     [1] IDLE        TX FIFO empty and no frame in progress
//                     [2] RX_VALID    RX FIFO holds at least one byte
//                     [3] RX_FULL     RX FIFO has no room
//                     [4] RX_OVERRUN  sticky: a frame finished while RX_FULL,
//                                     its byte was dropped
//                 W   write 1 to [4] to clear it
//   0x08  CTRL    RW  [0] CPHA
//                     [1] CPOL
//                     Change only while IDLE, and CPOL only with CS released.
//   0x0C  CLKDIV  RW  [15:0] clk_i cycles per SCLK half period,
//                     SCLK = fclk / (2 * CLKDIV). Values below 4 act as 4.
//                     Reset value = CLK_HZ / (2 * SCLK_HZ). Change only
//                     while IDLE.
//   0x10  CS      RW  [0] 1 drives spi_cs_no low (selects the slave).
//                     Wait for IDLE before releasing it.
//   0x14  IRQ_EN  RW  [0] raise irq_o while RX_VALID
//                     [1] raise irq_o while IDLE
//
//   any other offset in the slot -> OBI error response
//
// A write-only user (a display, say) can ignore RX; it fills up and sets
// RX_OVERRUN, and nothing else is affected.
//
// Same structure as uart_peripheral: no address-map decode here, the
// interconnect only asserts req when the slot matches. gnt = req, rvalid one
// cycle later, rdata/err registered with rvalid.
//////////////////////////////////////////////////////////////////////////////////


module spi_peripheral
#(
    parameter int unsigned  CLK_HZ      = 50_000_000,
    parameter int unsigned  SCLK_HZ     = 1_000_000,
    parameter int unsigned  FIFO_DEPTH  = 16
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
    output  logic           spi_sclk_o,
    output  logic           spi_mosi_o,
    input   logic           spi_miso_i,
    output  logic           spi_cs_no,
    output  logic           irq_o       // level, not yet wired to the core
    );

localparam logic [7:0] REG_DATA   = 8'h00;
localparam logic [7:0] REG_STATUS = 8'h04;
localparam logic [7:0] REG_CTRL   = 8'h08;
localparam logic [7:0] REG_CLKDIV = 8'h0C;
localparam logic [7:0] REG_CS     = 8'h10;
localparam logic [7:0] REG_IRQ_EN = 8'h14;

localparam logic [15:0] DIV_RESET = 16'(CLK_HZ / (2 * SCLK_HZ));

// ---------------------------------------------------------------------------
// Register select. Only the low byte picks the register; the rest of the
// 64 KB slot is an error rather than an alias.
// ---------------------------------------------------------------------------
logic   [7:0]   offset;
logic           in_range;
logic           sel_data, sel_status, sel_ctrl, sel_div, sel_cs, sel_irqen;
logic           wr, rd;

assign offset     = addr_i[7:0];
assign in_range   = (addr_i[15:8] == 8'h00);
assign sel_data   = in_range & (offset == REG_DATA);
assign sel_status = in_range & (offset == REG_STATUS);
assign sel_ctrl   = in_range & (offset == REG_CTRL);
assign sel_div    = in_range & (offset == REG_CLKDIV);
assign sel_cs     = in_range & (offset == REG_CS);
assign sel_irqen  = in_range & (offset == REG_IRQ_EN);

assign wr         = req_i &  we_i;
assign rd         = req_i & ~we_i;

assign gnt_o      = req_i;     // never stalls

// ---------------------------------------------------------------------------
// Control registers
// ---------------------------------------------------------------------------
logic           cpha_q, cpol_q;
logic   [15:0]  div_q;
logic           cs_q;
logic   [ 1:0]  irq_en_q;
logic           overrun_q;

// ---------------------------------------------------------------------------
// TX FIFO -> engine -> RX FIFO
// ---------------------------------------------------------------------------
logic           tx_push, tx_pop;
logic   [7:0]   tx_head;
logic           tx_empty, tx_full;
logic           busy;
logic           rx_valid;
logic   [7:0]   rx_byte;
logic           rx_pop;
logic   [7:0]   rx_head;
logic           rx_empty, rx_full;

assign tx_push = wr & sel_data & be_i[0];
assign rx_pop  = rd & sel_data;

sync_fifo #(.WIDTH(8), .DEPTH(FIFO_DEPTH)) tx_fifo (
    .clk_i   ( clk_i        ),
    .rst_ni  ( rst_ni       ),
    .push_i  ( tx_push      ),
    .wdata_i ( wdata_i[7:0] ),
    .pop_i   ( tx_pop       ),
    .rdata_o ( tx_head      ),
    .empty_o ( tx_empty     ),
    .full_o  ( tx_full      )
);

spi_master engine (
    .clk_i      ( clk_i      ),
    .rst_ni     ( rst_ni     ),
    .div_i      ( div_q      ),
    .cpol_i     ( cpol_q     ),
    .cpha_i     ( cpha_q     ),
    .valid_i    ( ~tx_empty  ),
    .data_i     ( tx_head    ),
    .ready_o    ( tx_pop     ),
    .busy_o     ( busy       ),
    .rx_valid_o ( rx_valid   ),
    .rx_data_o  ( rx_byte    ),
    .sclk_o     ( spi_sclk_o ),
    .mosi_o     ( spi_mosi_o ),
    .miso_i     ( spi_miso_i )
);

sync_fifo #(.WIDTH(8), .DEPTH(FIFO_DEPTH)) rx_fifo (
    .clk_i   ( clk_i     ),
    .rst_ni  ( rst_ni    ),
    .push_i  ( rx_valid  ),
    .wdata_i ( rx_byte   ),
    .pop_i   ( rx_pop    ),
    .rdata_o ( rx_head   ),
    .empty_o ( rx_empty  ),
    .full_o  ( rx_full   )
);

// ---------------------------------------------------------------------------
// Register writes
// ---------------------------------------------------------------------------
always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
        cpha_q    <= 1'b0;
        cpol_q    <= 1'b0;
        div_q     <= DIV_RESET;
        cs_q      <= 1'b0;
        irq_en_q  <= '0;
        overrun_q <= 1'b0;
    end else begin
        if (wr & sel_ctrl & be_i[0]) begin
            cpha_q <= wdata_i[0];
            cpol_q <= wdata_i[1];
        end

        if (wr & sel_div) begin
            if (be_i[0]) div_q[ 7:0] <= wdata_i[ 7:0];
            if (be_i[1]) div_q[15:8] <= wdata_i[15:8];
        end

        if (wr & sel_cs    & be_i[0]) cs_q     <= wdata_i[0];
        if (wr & sel_irqen & be_i[0]) irq_en_q <= wdata_i[1:0];

        // Set wins over clear, so an event in the same cycle is not lost.
        if (wr & sel_status & be_i[0] & wdata_i[4]) overrun_q <= 1'b0;
        if (rx_valid & rx_full & ~rx_pop)           overrun_q <= 1'b1;
    end
end

assign spi_cs_no = ~cs_q;

// ---------------------------------------------------------------------------
// Read mux and response
// ---------------------------------------------------------------------------
logic           idle;
logic   [31:0]  status;
logic   [31:0]  rdata_d;
logic           hit;

assign idle   = tx_empty & ~busy;
assign status = { 27'h0, overrun_q, rx_full, ~rx_empty, idle, tx_full };
assign hit    = sel_data | sel_status | sel_ctrl | sel_div | sel_cs | sel_irqen;

always_comb begin
    rdata_d = 32'h0;
    if (rd) begin
        unique case (1'b1)
            sel_data:   rdata_d = rx_empty ? 32'h0 : {24'h0, rx_head};
            sel_status: rdata_d = status;
            sel_ctrl:   rdata_d = {30'h0, cpol_q, cpha_q};
            sel_div:    rdata_d = {16'h0, div_q};
            sel_cs:     rdata_d = {31'h0, cs_q};
            sel_irqen:  rdata_d = {30'h0, irq_en_q};
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

assign irq_o = (irq_en_q[0] & ~rx_empty) | (irq_en_q[1] & idle);

endmodule
