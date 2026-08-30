`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: memory_controller
//
// Generic OBI slave over a single true-dual-port BRAM (blk_mem_gen_0).
//   Port A - instruction side, read only
//   Port B - data side, read/write with byte enables
//
// Contains no address decode and no peripheral logic. The caller is
// responsible for only issuing requests that belong to this slave; addresses
// are truncated to ADDR_WIDTH word bits, so out-of-range accesses alias.
//
// Zero wait state: gnt = req. rvalid is asserted one cycle after an accepted
// request, matching the BRAM read latency of 1. This requires "Primitives
// Output Register" and "Core Output Register" to be DISABLED on both ports.
//////////////////////////////////////////////////////////////////////////////////


module memory_controller
#(
    // Must match the Write/Read Depth of blk_mem_gen_0.
    parameter integer   MEM_DEPTH   =   16384
)
(
    input   logic           clk_i,
    input   logic           rst_ni,

    // -----------------------------------------------------------------------
    // Instruction OBI slave (port A, read only)
    // -----------------------------------------------------------------------
    input   logic           instr_req_i,
    output  logic           instr_gnt_o,
    output  logic           instr_rvalid_o,
    input   logic   [31:0]  instr_addr_i,
    input   logic   [ 1:0]  instr_memtype_i,
    input   logic   [ 2:0]  instr_prot_i,
    input   logic           instr_dbg_i,
    output  logic   [31:0]  instr_rdata_o,
    output  logic           instr_err_o,

    // -----------------------------------------------------------------------
    // Data OBI slave (port B, read/write)
    // -----------------------------------------------------------------------
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

logic   [ADDR_WIDTH-1:0]    bram_addr_a;
logic   [ADDR_WIDTH-1:0]    bram_addr_b;
logic   [3:0]               bram_web;

// ---------------------------------------------------------------------------
// Request phase
// ---------------------------------------------------------------------------
assign instr_gnt_o      = instr_req_i;                          // never stalls
assign data_gnt_o       = data_req_i;                           // never stalls

assign bram_addr_a      = instr_addr_i[ADDR_WIDTH+1:2];
assign bram_addr_b      = data_addr_i [ADDR_WIDTH+1:2];

assign bram_web         = {4{data_req_i & data_we_i}} & data_be_i;

// ---------------------------------------------------------------------------
// Response phase
// ---------------------------------------------------------------------------
always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
        instr_rvalid_o <= 1'b0;
        data_rvalid_o  <= 1'b0;
    end else begin
        instr_rvalid_o <= instr_req_i;
        data_rvalid_o  <= data_req_i;
    end
end

assign instr_err_o      = 1'b0;     // no error conditions inside the memory
assign data_err_o       = 1'b0;
assign data_exokay_o    = 1'b0;     // no exclusive transactions

// ---------------------------------------------------------------------------
// Unified true-dual-port BRAM
// ---------------------------------------------------------------------------
blk_mem_gen_0 unified_memory (
  // Port A - instruction
  .clka (   clk_i           ),
  .wea  (   4'b0000         ),
  .addra(   bram_addr_a     ),
  .dina (   32'h0000_0000   ),
  .douta(   instr_rdata_o   ),
  // Port B - data
  .clkb (   clk_i           ),
  .web  (   bram_web        ),
  .addrb(   bram_addr_b     ),
  .dinb (   data_wdata_i    ),
  .doutb(   data_rdata_o    )
);

endmodule
