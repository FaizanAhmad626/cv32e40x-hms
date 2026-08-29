`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 05/31/2026 11:50:39 PM
// Design Name: 
// Module Name: cv32e40x_fpga_clock_gate
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module cv32e40x_clock_gate #(parameter LIB = 0)
(
  input  logic clk_i,
  input  logic en_i,
  input  logic scan_cg_en_i,
  output logic clk_o
);
  // BUFGCE is the 7-series glitchless clock-enable buffer.
  // It routes onto a global clock net.
  BUFGCE bufgce_core_cg (
    .I  ( clk_i               ),
    .CE ( en_i | scan_cg_en_i ),
    .O  ( clk_o               )
  );
endmodule
