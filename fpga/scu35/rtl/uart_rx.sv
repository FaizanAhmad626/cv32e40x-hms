`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: uart_rx
//
// 8N1 receiver.
//
//   1. rx_i is an asynchronous pin, so it goes through two flops first.
//   2. A falling edge on the idle line starts a frame.
//   3. Wait half a bit and check the line is still low. If not, it was a
//      glitch and the receiver goes back to idle.
//   4. Sample every full bit period after that, which lands in the middle
//      of each data bit and then the stop bit.
//   5. Stop bit low -> frame error. The byte is still delivered, flagged.
//
// div_i is clk_i cycles per bit, same meaning as in uart_tx.
//////////////////////////////////////////////////////////////////////////////////


module uart_rx
(
    input   logic           clk_i,
    input   logic           rst_ni,

    input   logic   [19:0]  div_i,
    input   logic           rx_i,

    output  logic           valid_o,    // one-cycle pulse per received byte
    output  logic   [ 7:0]  data_o,
    output  logic           frame_err_o // qualifies valid_o
    );

typedef enum logic [1:0] { IDLE, START, DATA, STOP } state_e;

state_e         state_q;
logic   [ 2:0]  sync_q;         // [0],[1] = synchroniser, [2] = previous
logic   [19:0]  cnt_q;
logic   [ 2:0]  bit_q;
logic   [ 7:0]  shift_q;

logic           rx_s;
logic           fall_s;

assign rx_s   = sync_q[1];
assign fall_s = sync_q[2] & ~sync_q[1];

always_ff @(posedge clk_i) begin
    if (!rst_ni)
        sync_q <= 3'b111;       // idle-high so reset is not seen as a start
    else
        sync_q <= {sync_q[1:0], rx_i};
end

always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
        state_q     <= IDLE;
        cnt_q       <= '0;
        bit_q       <= '0;
        shift_q     <= '0;
        valid_o     <= 1'b0;
        data_o      <= '0;
        frame_err_o <= 1'b0;
    end else begin
        valid_o <= 1'b0;

        unique case (state_q)
            IDLE: begin
                if (fall_s) begin
                    state_q <= START;
                    cnt_q   <= (div_i >> 1) - 1'b1;     // to mid start bit
                end
            end

            START: begin
                if (cnt_q != '0) begin
                    cnt_q <= cnt_q - 1'b1;
                end else if (rx_s) begin
                    state_q <= IDLE;                    // glitch, not a start
                end else begin
                    state_q <= DATA;
                    bit_q   <= '0;
                    cnt_q   <= div_i - 1'b1;
                end
            end

            DATA: begin
                if (cnt_q != '0) begin
                    cnt_q <= cnt_q - 1'b1;
                end else begin
                    shift_q <= {rx_s, shift_q[7:1]};    // LSB first
                    cnt_q   <= div_i - 1'b1;
                    bit_q   <= bit_q + 1'b1;
                    if (bit_q == 3'd7)
                        state_q <= STOP;
                end
            end

            STOP: begin
                if (cnt_q != '0) begin
                    cnt_q <= cnt_q - 1'b1;
                end else begin
                    // Return to IDLE at mid stop bit. That leaves half a bit
                    // of margin to catch the next start edge, which is what
                    // tolerates a transmitter running slightly fast.
                    state_q     <= IDLE;
                    valid_o     <= 1'b1;
                    data_o      <= shift_q;
                    frame_err_o <= ~rx_s;
                end
            end

            default: state_q <= IDLE;
        endcase
    end
end

endmodule
