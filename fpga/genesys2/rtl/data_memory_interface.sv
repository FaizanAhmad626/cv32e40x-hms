`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 06/14/2026 05:02:56 PM
// Design Name: 
// Module Name: data_memory_interface
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


module data_memory_interface
#(
    parameter integer   MEM_DEPTH   =   4096
)
(
    input   logic           clk_i,
    input   logic           rst_ni,
    input   logic           data_req_i,
    output  logic           data_gnt_o,
    output  logic           data_rvalid_o,
    input   logic   [31:0]  data_addr_i,
    input   logic   [ 3:0]  data_be_i,
    input   logic           data_we_i,
    input   logic   [31:0]  data_wdata_i,
    input   logic   [ 1:0]  data_memtype_i,
    input   logic   [ 2:0]  data_prot_i,
    input   logic           data_dbg_i,
    input   logic   [ 5:0]  data_atop_i,
    output  logic   [31:0]  data_rdata_o,
    output  logic           data_err_o,
    output  logic           data_exokay_o
    );
    
localparam  int unsigned    ADDR_WIDTH  =   $clog2(MEM_DEPTH);

logic   [ADDR_WIDTH-1:0]    bram_addr;
logic   [3:0]               bram_wea;
    
assign data_gnt_o       = data_req_i;                               // so that BRAM never stalls
assign data_err_o       = 1'b0;                                     // there is no memory error
assign data_exokay_o    = 1'b0;                                     // no exclusive transaction
assign bram_addr        = data_addr_i[ADDR_WIDTH+1:2];
assign bram_wea         = {4{data_req_i & data_we_i}} & data_be_i;

always_ff @(posedge clk_i) begin
    if(!rst_ni)
        data_rvalid_o = 1'b0;
    else
        data_rvalid_o <= data_req_i;  // valid gets 1 after 1 cycle when core requests instruction
end  
    
blk_mem_gen_1 data_memory (
  .clka (   clk_i           ),  // input wire clka
  .wea  (   data_we_i       ),  // input wire [3 : 0] wea
  .addra(   bram_addr       ),  // input wire [11 : 0] addra
  .dina (   data_wdata_i    ),  // input wire [31 : 0] dina
  .douta(   data_rdata_o    )   // output wire [31 : 0] douta
);
endmodule