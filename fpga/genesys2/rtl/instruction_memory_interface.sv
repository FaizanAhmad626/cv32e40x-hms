`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 06/14/2026 04:06:15 PM
// Design Name: 
// Module Name: instruction_memory_interface
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


module instruction_memory_interface
#(
    parameter integer   MEM_DEPTH   =   4096
)
(
    input   logic           clk_i,
    input   logic           rst_ni,
    input   logic           instr_req_i,
    output  logic           instr_gnt_o,
    output  logic           instr_rvalid_o,
    input   logic   [31:0]  instr_addr_i,
    input   logic   [ 1:0]  instr_memtype_i,
    input   logic   [ 2:0]  instr_prot_i,
    input   logic           instr_dbg_i,
    output  logic   [31:0]  instr_rdata_o,
    output  logic           instr_err_o
);

localparam  int unsigned    ADDR_WIDTH  =   $clog2(MEM_DEPTH);
    
logic   [ADDR_WIDTH-1:0]    bram_addr;
    
assign instr_gnt_o  = instr_req_i;  // so that BRAM never stalls
assign instr_err_o  = 1'b0;         // there is no memory error
assign bram_addr    = instr_addr_i[ADDR_WIDTH+1:2];

always_ff @(posedge clk_i) begin
    if(!rst_ni)
        instr_rvalid_o = 1'b0;
    else
        instr_rvalid_o <= instr_req_i;  // valid gets 1 after 1 cycle when core requests instruction
end  

blk_mem_gen_0 instruction_memory (
  .clka (   clk_i           ),  // input wire clka
  .addra(   bram_addr       ),  // input wire [11 : 0] addra
  .douta(   instr_rdata_o   )   // output wire [31 : 0] douta
);
endmodule
