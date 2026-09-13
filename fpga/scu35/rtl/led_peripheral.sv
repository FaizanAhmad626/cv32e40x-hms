`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: led_peripheral
//
// Single-register OBI slave driving the board LEDs.
//   write : led_reg_o <= wdata[7:0]   (requires be[0])
//   read  : {24'h0, led_reg_o}
//
// Contains no address decode; the interconnect asserts req only when this
// slave is selected. Response timing matches the memory controller
// (gnt = req, rvalid one cycle later) so the core sees uniform behaviour
// regardless of which slave it addresses.
//////////////////////////////////////////////////////////////////////////////////


module led_peripheral
#(
    parameter integer   NUM_LEDS    =   8
)
(
    input   logic                   clk_i,
    input   logic                   rst_ni,

    // -----------------------------------------------------------------------
    // OBI slave
    // -----------------------------------------------------------------------
    input   logic                   req_i,
    output  logic                   gnt_o,
    output  logic                   rvalid_o,
    input   logic   [31:0]          addr_i,
    input   logic   [ 3:0]          be_i,
    input   logic                   we_i,
    input   logic   [31:0]          wdata_i,
    output  logic   [31:0]          rdata_o,
    output  logic                   err_o,

    // -----------------------------------------------------------------------
    // To pins
    // -----------------------------------------------------------------------
    output  logic   [NUM_LEDS-1:0]  led_o
    );

logic   [NUM_LEDS-1:0]  led_q;

assign gnt_o    = req_i;    // never stalls
assign err_o    = 1'b0;     // single register, no error conditions

always_ff @(posedge clk_i) begin
    if (!rst_ni)
        rvalid_o <= 1'b0;
    else
        rvalid_o <= req_i;
end

always_ff @(posedge clk_i) begin
    if (!rst_ni)
        led_q <= '0;
    else if (req_i & we_i & be_i[0])
        led_q <= wdata_i[NUM_LEDS-1:0];
end

assign rdata_o  = {{(32-NUM_LEDS){1'b0}}, led_q};
assign led_o    = led_q;

endmodule
