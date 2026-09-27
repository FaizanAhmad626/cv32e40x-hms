`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: i2c_peripheral
//
// I2C master as an OBI slave. Byte-at-a-time and polled: software writes the
// byte to DATA, issues a command in CMD, waits for BUSY to drop, then checks
// RX_NACK (after a write) or reads DATA (after a read). No FIFOs: at 100 to
// 400 kHz one byte takes 22 to 90 us, far longer than a poll loop.
//
// Register map, offsets from the slot base (I2C_BASE = 0x1003_0000):
//
//   0x00  DATA    W   [7:0] byte for the next WRITE command. Latched when
//                     the command starts, so it may be loaded while busy.
//                 R   [7:0] byte received by the last READ command
//   0x04  CMD     W   [0] START   START first (repeated START if HELD)
//                     [1] STOP    STOP last
//                     [2] WRITE   send DATA, then read the slave's ACK bit
//                     [3] READ    receive a byte, then send the ACK bit
//                     [4] NACK    with READ: answer NACK (last byte of a read)
//                     [7] ABORT   drop the command and release both lines now
//                     Order within one command is START, byte, STOP. WRITE
//                     wins if both WRITE and READ are set. Ignored while BUSY
//                     (except ABORT), so poll STATUS first.
//                 R   0
//   0x08  STATUS  R   [0] BUSY     a command is executing
//                     [1] RX_NACK  ACK bit after the last WRITE was high:
//                                  nobody answered, or the slave refused
//                     [2] HELD     we own the bus (after START, before STOP)
//                     [3] SCL      live SCL pin level (synchronised)
//                     [4] SDA      live SDA pin level (synchronised)
//                     With the bus idle, SCL = SDA = 1. A 0 there means a
//                     missing pull-up or a slave stuck mid-byte.
//   0x0C  CLKDIV  RW  [15:0] clk_i cycles per quarter SCL period,
//                     SCL = fclk / (4 * CLKDIV). Values below 4 act as 4.
//                     Reset value = ceil(CLK_HZ / (4 * SCL_HZ)). Change only
//                     while not BUSY.
//   0x10  IRQ_EN  RW  [0] raise irq_o while not BUSY (command done)
//
//   any other offset in the slot -> OBI error response
//
// Same OBI structure as spi_peripheral: no address-map decode here, gnt = req,
// rvalid one cycle later, rdata/err registered with rvalid.
//////////////////////////////////////////////////////////////////////////////////


module i2c_peripheral
#(
    parameter int unsigned  CLK_HZ      = 50_000_000,
    parameter int unsigned  SCL_HZ      = 100_000
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
    // Open-drain pins (oe = 1 pulls low) and interrupt
    // -----------------------------------------------------------------------
    input   logic           scl_i,
    output  logic           scl_oe_o,
    input   logic           sda_i,
    output  logic           sda_oe_o,
    output  logic           irq_o       // level, not yet wired to the core
    );

localparam logic [7:0] REG_DATA   = 8'h00;
localparam logic [7:0] REG_CMD    = 8'h04;
localparam logic [7:0] REG_STATUS = 8'h08;
localparam logic [7:0] REG_CLKDIV = 8'h0C;
localparam logic [7:0] REG_IRQ_EN = 8'h10;

// Round up so the reset rate is never above the requested one.
localparam logic [15:0] DIV_RESET = 16'((CLK_HZ + 4 * SCL_HZ - 1) / (4 * SCL_HZ));

// ---------------------------------------------------------------------------
// Register select
// ---------------------------------------------------------------------------
logic   [7:0]   offset;
logic           in_range;
logic           sel_data, sel_cmd, sel_status, sel_div, sel_irqen;
logic           wr, rd;

assign offset     = addr_i[7:0];
assign in_range   = (addr_i[15:8] == 8'h00);
assign sel_data   = in_range & (offset == REG_DATA);
assign sel_cmd    = in_range & (offset == REG_CMD);
assign sel_status = in_range & (offset == REG_STATUS);
assign sel_div    = in_range & (offset == REG_CLKDIV);
assign sel_irqen  = in_range & (offset == REG_IRQ_EN);

assign wr         = req_i &  we_i;
assign rd         = req_i & ~we_i;

assign gnt_o      = req_i;     // never stalls

// ---------------------------------------------------------------------------
// Registers
// ---------------------------------------------------------------------------
logic   [ 7:0]  txd_q;
logic   [15:0]  div_q;
logic           irq_en_q;

always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
        txd_q    <= '0;
        div_q    <= DIV_RESET;
        irq_en_q <= 1'b0;
    end else begin
        if (wr & sel_data & be_i[0]) txd_q <= wdata_i[7:0];
        if (wr & sel_div) begin
            if (be_i[0]) div_q[ 7:0] <= wdata_i[ 7:0];
            if (be_i[1]) div_q[15:8] <= wdata_i[15:8];
        end
        if (wr & sel_irqen & be_i[0]) irq_en_q <= wdata_i[0];
    end
end

// ---------------------------------------------------------------------------
// Engine
// ---------------------------------------------------------------------------
logic           cmd_wr;
logic           busy, held, rx_nack, scl_s, sda_s;
logic   [ 7:0]  rx_data;

assign cmd_wr = wr & sel_cmd & be_i[0];

i2c_master engine (
    .clk_i       ( clk_i                  ),
    .rst_ni      ( rst_ni                 ),
    .div_i       ( div_q                  ),
    .cmd_valid_i ( cmd_wr & ~wdata_i[7]   ),
    .cmd_start_i ( wdata_i[0]             ),
    .cmd_stop_i  ( wdata_i[1]             ),
    .cmd_write_i ( wdata_i[2]             ),
    .cmd_read_i  ( wdata_i[3]             ),
    .cmd_nack_i  ( wdata_i[4]             ),
    .cmd_data_i  ( txd_q                  ),
    .abort_i     ( cmd_wr &  wdata_i[7]   ),
    .busy_o      ( busy                   ),
    .held_o      ( held                   ),
    .done_o      (                        ),
    .rx_nack_o   ( rx_nack                ),
    .rx_data_o   ( rx_data                ),
    .scl_o       ( scl_s                  ),
    .sda_o       ( sda_s                  ),
    .scl_i       ( scl_i                  ),
    .sda_i       ( sda_i                  ),
    .scl_oe_o    ( scl_oe_o               ),
    .sda_oe_o    ( sda_oe_o               )
);

// ---------------------------------------------------------------------------
// Read mux and response
// ---------------------------------------------------------------------------
logic   [31:0]  status;
logic   [31:0]  rdata_d;
logic           hit;

assign status = { 27'h0, sda_s, scl_s, held, rx_nack, busy };
assign hit    = sel_data | sel_cmd | sel_status | sel_div | sel_irqen;

always_comb begin
    rdata_d = 32'h0;
    if (rd) begin
        unique case (1'b1)
            sel_data:   rdata_d = {24'h0, rx_data};
            sel_cmd:    rdata_d = 32'h0;
            sel_status: rdata_d = status;
            sel_div:    rdata_d = {16'h0, div_q};
            sel_irqen:  rdata_d = {31'h0, irq_en_q};
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

assign irq_o = irq_en_q & ~busy;

endmodule
