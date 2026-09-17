`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: uart_peripheral
//
// 8N1 UART as an OBI slave, with a FIFO on each direction.
//
// Register map, offsets from the slot base (UART_BASE = 0x1001_0000):
//
//   0x00  DATA    W   push wdata[7:0] into the TX FIFO
//                     (dropped if TX_FULL, so poll STATUS first)
//                 R   pop and return the RX FIFO head in [7:0]
//                     (reads 0 and pops nothing if RX is empty)
//   0x04  STATUS  R   [0] TX_FULL     TX FIFO has no room
//                     [1] TX_IDLE     TX FIFO empty and nothing on the wire
//                     [2] RX_VALID    RX FIFO holds at least one byte
//                     [3] RX_FULL     RX FIFO has no room
//                     [4] RX_OVERRUN  sticky: a byte arrived while RX_FULL
//                     [5] FRAME_ERR   sticky: a byte had a low stop bit
//                 W   write 1 to [4] or [5] to clear it
//   0x08  BAUDDIV RW  [19:0] clk_i cycles per bit = round(fclk / baud)
//                     Reset value = round(CLK_HZ / BAUD). Change it only
//                     while TX_IDLE is set.
//   0x0C  IRQ_EN  RW  [0] raise irq_o while RX_VALID
//                     [1] raise irq_o while TX_IDLE
//
//   any other offset in the slot -> OBI error response
//
// Contains no address-map decode (the interconnect only asserts req when
// the slot matches); addr_i[7:0] only selects the register within the slot.
//
// Timing matches every other slave: gnt = req, rvalid one cycle later, and
// rdata/err are registered with rvalid.
//////////////////////////////////////////////////////////////////////////////////


module uart_peripheral
#(
    parameter int unsigned  CLK_HZ      = 50_000_000,
    parameter int unsigned  BAUD        = 115_200,
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
    input   logic           uart_rx_i,
    output  logic           uart_tx_o,
    output  logic           irq_o       // level, not yet wired to the core
    );

localparam logic [7:0] REG_DATA    = 8'h00;
localparam logic [7:0] REG_STATUS  = 8'h04;
localparam logic [7:0] REG_BAUDDIV = 8'h08;
localparam logic [7:0] REG_IRQ_EN  = 8'h0C;

localparam logic [19:0] DIV_RESET  = 20'((CLK_HZ + BAUD/2) / BAUD);

// ---------------------------------------------------------------------------
// Register select
//
// Only the low byte picks the register. Bits [15:8] of the slot are unused,
// so e.g. 0x1001_0100 is an error rather than an alias of DATA.
// ---------------------------------------------------------------------------
logic   [7:0]   offset;
logic           in_range;
logic           sel_data, sel_status, sel_baud, sel_irqen;
logic           wr, rd;

assign offset     = addr_i[7:0];
assign in_range   = (addr_i[15:8] == 8'h00);
assign sel_data   = in_range & (offset == REG_DATA);
assign sel_status = in_range & (offset == REG_STATUS);
assign sel_baud   = in_range & (offset == REG_BAUDDIV);
assign sel_irqen  = in_range & (offset == REG_IRQ_EN);

assign wr         = req_i &  we_i;
assign rd         = req_i & ~we_i;

assign gnt_o      = req_i;     // never stalls

// ---------------------------------------------------------------------------
// Control registers
// ---------------------------------------------------------------------------
logic   [19:0]  div_q;
logic   [ 1:0]  irq_en_q;
logic           overrun_q;
logic           frame_err_q;

// ---------------------------------------------------------------------------
// TX path: FIFO -> uart_tx
// ---------------------------------------------------------------------------
logic           tx_push, tx_pop;
logic   [7:0]   tx_head;
logic           tx_empty, tx_full;
logic           tx_busy;

assign tx_push = wr & sel_data & be_i[0];

sync_fifo #(.WIDTH(8), .DEPTH(FIFO_DEPTH)) tx_fifo (
    .clk_i   ( clk_i     ),
    .rst_ni  ( rst_ni    ),
    .push_i  ( tx_push   ),
    .wdata_i ( wdata_i[7:0] ),
    .pop_i   ( tx_pop    ),
    .rdata_o ( tx_head   ),
    .empty_o ( tx_empty  ),
    .full_o  ( tx_full   )
);

uart_tx tx_inst (
    .clk_i   ( clk_i     ),
    .rst_ni  ( rst_ni    ),
    .div_i   ( div_q     ),
    .valid_i ( ~tx_empty ),
    .data_i  ( tx_head   ),
    .ready_o ( tx_pop    ),
    .busy_o  ( tx_busy   ),
    .tx_o    ( uart_tx_o )
);

// ---------------------------------------------------------------------------
// RX path: uart_rx -> FIFO
// ---------------------------------------------------------------------------
logic           rx_valid;
logic   [7:0]   rx_byte;
logic           rx_ferr;
logic           rx_pop;
logic   [7:0]   rx_head;
logic           rx_empty, rx_full;

uart_rx rx_inst (
    .clk_i       ( clk_i     ),
    .rst_ni      ( rst_ni    ),
    .div_i       ( div_q     ),
    .rx_i        ( uart_rx_i ),
    .valid_o     ( rx_valid  ),
    .data_o      ( rx_byte   ),
    .frame_err_o ( rx_ferr   )
);

// A read of DATA consumes the head. The value returned is the head as it
// is this cycle, captured into rdata below, so pop and read are consistent.
assign rx_pop = rd & sel_data;

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
        div_q       <= DIV_RESET;
        irq_en_q    <= '0;
        overrun_q   <= 1'b0;
        frame_err_q <= 1'b0;
    end else begin
        if (wr & sel_baud) begin
            if (be_i[0]) div_q[ 7: 0] <= wdata_i[ 7: 0];
            if (be_i[1]) div_q[15: 8] <= wdata_i[15: 8];
            if (be_i[2]) div_q[19:16] <= wdata_i[19:16];
        end

        if (wr & sel_irqen & be_i[0])
            irq_en_q <= wdata_i[1:0];

        // Set wins over clear, so an event in the same cycle is not lost.
        if (wr & sel_status & be_i[0] & wdata_i[4]) overrun_q   <= 1'b0;
        if (wr & sel_status & be_i[0] & wdata_i[5]) frame_err_q <= 1'b0;
        if (rx_valid & rx_full & ~rx_pop)           overrun_q   <= 1'b1;
        if (rx_valid & rx_ferr)                     frame_err_q <= 1'b1;
    end
end

// ---------------------------------------------------------------------------
// Read mux and response
// ---------------------------------------------------------------------------
logic   [31:0]  status;
logic   [31:0]  rdata_d;
logic           hit;

assign status = { 26'h0,
                  frame_err_q,
                  overrun_q,
                  rx_full,
                  ~rx_empty,
                  tx_empty & ~tx_busy,
                  tx_full };

assign hit = sel_data | sel_status | sel_baud | sel_irqen;

always_comb begin
    rdata_d = 32'h0;
    if (rd) begin
        unique case (1'b1)
            sel_data:   rdata_d = rx_empty ? 32'h0 : {24'h0, rx_head};
            sel_status: rdata_d = status;
            sel_baud:   rdata_d = {12'h0, div_q};
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

assign irq_o = (irq_en_q[0] & ~rx_empty) |
               (irq_en_q[1] & tx_empty & ~tx_busy);

endmodule
