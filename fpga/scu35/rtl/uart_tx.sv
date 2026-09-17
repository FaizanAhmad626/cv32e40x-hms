`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: uart_tx
//
// 8N1 transmitter. Pulls a byte whenever it is idle and valid_i is high,
// then shifts out: start (0), 8 data bits LSB first, stop (1).
//
// div_i is the number of clk_i cycles per bit (fclk / baud, rounded).
// It is sampled at the start of every bit, so changing it mid-frame only
// takes effect on the next bit; software should change it while idle.
//////////////////////////////////////////////////////////////////////////////////


module uart_tx
(
    input   logic           clk_i,
    input   logic           rst_ni,

    input   logic   [19:0]  div_i,

    input   logic           valid_i,    // a byte is waiting
    input   logic   [ 7:0]  data_i,
    output  logic           ready_o,    // pulses when the byte is taken

    output  logic           busy_o,     // a frame is on the wire
    output  logic           tx_o
    );

logic   [ 9:0]  shift_q;    // {stop, data[7:0], start}, LSB goes out first
logic   [ 3:0]  bits_q;     // bits still to send in this frame
logic   [19:0]  cnt_q;      // cycles left in the current bit

assign busy_o   = (bits_q != 4'd0);
assign ready_o  = ~busy_o & valid_i;
assign tx_o     = busy_o ? shift_q[0] : 1'b1;     // line idles high

always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
        shift_q <= '1;
        bits_q  <= '0;
        cnt_q   <= '0;
    end else if (!busy_o) begin
        if (valid_i) begin
            shift_q <= {1'b1, data_i, 1'b0};
            bits_q  <= 4'd10;
            cnt_q   <= div_i - 1'b1;
        end
    end else if (cnt_q != '0) begin
        cnt_q   <= cnt_q - 1'b1;
    end else begin
        shift_q <= {1'b1, shift_q[9:1]};
        bits_q  <= bits_q - 1'b1;
        cnt_q   <= div_i - 1'b1;
    end
end

endmodule
