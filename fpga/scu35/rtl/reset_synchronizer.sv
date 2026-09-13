`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 06/14/2026 12:13:45 PM
// Design Name: 
// Module Name: reset_synchronizer
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


module reset_synchronizer(
    input   logic clk_i,
    input   logic rst_ni,
    output  logic rst_no
    );

always_ff @(posedge clk_i) begin
    rst_no <= rst_ni;
end    
    
endmodule
