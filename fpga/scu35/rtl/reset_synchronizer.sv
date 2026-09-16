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
	input	logic locked_i,
    output  logic rst_no
    );

logic       rst_async_n;
logic [1:0] sync_q;

always_ff @(posedge clk_i or negedge rst_async_n)
begin
    if (!rst_async_n)
        sync_q <= 2'b00;
    else
        sync_q <= {sync_q[0], 1'b1};
end

assign rst_async_n	= rst_ni & locked_i;
assign rst_no 		= sync_q[1];
    
endmodule
