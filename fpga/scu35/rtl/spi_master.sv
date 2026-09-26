`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: spi_master
//
// SPI master shift engine: 8-bit frames, MSB first, all four modes.
// Pulls a byte whenever it is idle and valid_i is high, clocks it out on
// MOSI while clocking a byte in from MISO, then pulses rx_valid_o.
//
// Chip select is not handled here; the peripheral drives it from a register.
//
// Clocking
//   div_i = clk_i cycles per SCLK half period, so SCLK = fclk / (2 * div_i).
//   Values below MIN_DIV are raised to MIN_DIV. MISO passes through a
//   two-flop synchroniser, so the value sampled on an edge was on the pin
//   two cycles earlier. MIN_DIV = 4 leaves 2 cycles (40 ns at 50 MHz) for
//   SCLK to leave the FPGA, the slave to respond and MISO to come back.
//   At 50 MHz that caps SCLK at 6.25 MHz.
//
// Modes (edge 0 is the first edge after CS, the "leading" edge)
//   CPOL  SCLK idle level
//   CPHA  0: MOSI valid before edge 0, sample on even edges, shift on odd
//         1: shift on even edges, sample on odd edges
//
// div_i, cpol_i and cpha_i are used live. Change them only while idle
// (busy_o low), and change CPOL only with CS deasserted, since it moves
// SCLK immediately.
//
// All outputs come straight from flops.
//////////////////////////////////////////////////////////////////////////////////


module spi_master
#(
    parameter int unsigned  MIN_DIV     = 4
)
(
    input   logic           clk_i,
    input   logic           rst_ni,

    input   logic   [15:0]  div_i,
    input   logic           cpol_i,
    input   logic           cpha_i,

    input   logic           valid_i,    // a byte is waiting
    input   logic   [ 7:0]  data_i,
    output  logic           ready_o,    // pulses when the byte is taken

    output  logic           busy_o,     // a frame is in progress
    output  logic           rx_valid_o, // one-cycle pulse, rx_data_o is valid
    output  logic   [ 7:0]  rx_data_o,

    output  logic           sclk_o,
    output  logic           mosi_o,
    input   logic           miso_i
    );

logic   [15:0]  half;       // cycles per half period, after clamping
logic           xfer_q;     // SCLK edges still to come in this frame
logic   [ 3:0]  edge_q;     // index of the next SCLK edge, 0..15
logic   [15:0]  cnt_q;      // cycles left until the next edge
logic   [ 7:0]  tx_sh_q;    // next bit to drive is tx_sh_q[7]
logic   [ 7:0]  rx_sh_q;    // bits enter at [0]
logic           sclk_q;
logic           mosi_q;
logic           done_q;
logic           miso_s1, miso_s2;

logic           tick;       // an SCLK edge happens this cycle
logic           leading;    // ... and it is a leading (even) edge
logic           sample;     // ... and MISO is sampled on it
logic           last;       // ... and it is the 16th edge

assign half     = (div_i < 16'(MIN_DIV)) ? 16'(MIN_DIV) : div_i;
assign tick     = xfer_q & (cnt_q == '0);
assign leading  = ~edge_q[0];
assign sample   = leading ^ cpha_i;
assign last     = (edge_q == 4'd15);

assign ready_o    = ~xfer_q & ~done_q & valid_i;
assign busy_o     = xfer_q | done_q;
assign rx_valid_o = done_q;
assign rx_data_o  = rx_sh_q;
assign sclk_o     = sclk_q;
assign mosi_o     = mosi_q;

// ---------------------------------------------------------------------------
// MISO synchroniser
// ---------------------------------------------------------------------------
always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
        miso_s1 <= 1'b0;
        miso_s2 <= 1'b0;
    end else begin
        miso_s1 <= miso_i;
        miso_s2 <= miso_s1;
    end
end

// ---------------------------------------------------------------------------
// Shift engine
//
// done_q is the cycle after the 16th edge. By then rx_sh_q holds all eight
// bits in both CPHA settings (CPHA = 1 samples on that last edge). No new
// frame starts during done_q, so rx_data_o is stable while rx_valid_o is up.
// ---------------------------------------------------------------------------
always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
        xfer_q  <= 1'b0;
        edge_q  <= '0;
        cnt_q   <= '0;
        tx_sh_q <= '0;
        rx_sh_q <= '0;
        sclk_q  <= 1'b0;
        mosi_q  <= 1'b0;
        done_q  <= 1'b0;
    end else begin
        done_q <= 1'b0;

        if (!xfer_q) begin
            sclk_q <= cpol_i;
            if (ready_o) begin
                xfer_q <= 1'b1;
                edge_q <= '0;
                cnt_q  <= half - 1'b1;
                if (cpha_i) begin
                    tx_sh_q <= data_i;                  // first bit goes out on edge 0
                end else begin
                    mosi_q  <= data_i[7];               // first bit is out before edge 0
                    tx_sh_q <= {data_i[6:0], 1'b0};
                end
            end
        end else if (!tick) begin
            cnt_q <= cnt_q - 1'b1;
        end else begin
            cnt_q  <= half - 1'b1;
            sclk_q <= ~sclk_q;
            edge_q <= edge_q + 1'b1;

            if (sample) begin
                rx_sh_q <= {rx_sh_q[6:0], miso_s2};
            end else if (!last) begin                   // CPHA = 0 has nothing left to shift on edge 15
                mosi_q  <= tx_sh_q[7];
                tx_sh_q <= {tx_sh_q[6:0], 1'b0};
            end

            if (last) begin
                xfer_q <= 1'b0;
                done_q <= 1'b1;
            end
        end
    end
end

endmodule
