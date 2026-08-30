`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: obi_data_interconnect
//
// Data-side OBI 1-to-N decode and response mux. Owns the entire address map;
// slaves themselves contain no decode logic.
//
//   MEM_BASE  .. MEM_BASE + MEM_DEPTH*4 - 1   memory_controller port B
//   LED_BASE                                  led_peripheral (one word)
//   anything else                             error response
//
// All slaves are zero-wait-state (gnt = req) and respond exactly one cycle
// after the accepted request, so the select signal is registered once and
// used to steer rdata, err and exokay during the response phase.
//
// OBI sideband signals (memtype, prot, dbg, atop) are forwarded to the memory
// slave. They carry no useful information in the current configuration
// (no cache, machine mode only, DEBUG=0, A_EXT=A_NONE) but forwarding them
// keeps the plumbing correct for when the debug module is enabled.
// led_peripheral does not need them, so they are not routed there.
//
// Adding a slave: extend the decode, add a req/rsp port group, and extend
// the response muxes.
//////////////////////////////////////////////////////////////////////////////////


module obi_data_interconnect
#(
    // Memory region. Depth must match blk_mem_gen_0 / memory_controller.
    parameter integer       MEM_DEPTH   =   16384,
    parameter logic [31:0]  MEM_BASE    =   32'h8000_0000,
    // LED register address (single word).
    parameter logic [31:0]  LED_BASE    =   32'h1000_0000
)
(
    input   logic           clk_i,
    input   logic           rst_ni,

    // -----------------------------------------------------------------------
    // Upstream: data OBI from the core
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
    output  logic           data_exokay_o,

    // -----------------------------------------------------------------------
    // Downstream: memory slave
    // -----------------------------------------------------------------------
    output  logic           mem_req_o,
    input   logic           mem_gnt_i,
    input   logic           mem_rvalid_i,
    output  logic   [31:0]  mem_addr_o,
    output  logic   [ 3:0]  mem_be_o,
    output  logic           mem_we_o,
    output  logic   [31:0]  mem_wdata_o,
    output  logic   [ 1:0]  mem_memtype_o,
    output  logic   [ 2:0]  mem_prot_o,
    output  logic           mem_dbg_o,
    output  logic   [ 5:0]  mem_atop_o,
    input   logic   [31:0]  mem_rdata_i,
    input   logic           mem_err_i,
    input   logic           mem_exokay_i,

    // -----------------------------------------------------------------------
    // Downstream: LED slave
    // -----------------------------------------------------------------------
    output  logic           led_req_o,
    input   logic           led_gnt_i,
    input   logic           led_rvalid_i,
    output  logic   [31:0]  led_addr_o,
    output  logic   [ 3:0]  led_be_o,
    output  logic           led_we_o,
    output  logic   [31:0]  led_wdata_o,
    input   logic   [31:0]  led_rdata_i,
    input   logic           led_err_i
    );

localparam  int unsigned    ADDR_WIDTH  =   $clog2(MEM_DEPTH);  // 14
// Address bits above the memory's word index identify the region.
localparam  int unsigned    MEM_TAG_LSB =   ADDR_WIDTH + 2;     // 16

// ---------------------------------------------------------------------------
// Address decode (combinational, request phase)
// ---------------------------------------------------------------------------
logic   mem_sel;
logic   led_sel;
logic   unmapped;

assign mem_sel  = (data_addr_i[31:MEM_TAG_LSB] == MEM_BASE[31:MEM_TAG_LSB]);
assign led_sel  = (data_addr_i[31:2]           == LED_BASE[31:2]);
assign unmapped = ~(mem_sel | led_sel);

// ---------------------------------------------------------------------------
// Request routing
// ---------------------------------------------------------------------------
assign mem_req_o     = data_req_i & mem_sel;
assign mem_addr_o    = data_addr_i;
assign mem_be_o      = data_be_i;
assign mem_we_o      = data_we_i;
assign mem_wdata_o   = data_wdata_i;
assign mem_memtype_o = data_memtype_i;
assign mem_prot_o    = data_prot_i;
assign mem_dbg_o     = data_dbg_i;
assign mem_atop_o    = data_atop_i;

assign led_req_o     = data_req_i & led_sel;
assign led_addr_o    = data_addr_i;
assign led_be_o      = data_be_i;
assign led_we_o      = data_we_i;
assign led_wdata_o   = data_wdata_i;

// An unmapped access is accepted immediately and answered with an error.
assign data_gnt_o    = mem_sel ? mem_gnt_i :
                       led_sel ? led_gnt_i :
                                 data_req_i;

// ---------------------------------------------------------------------------
// Response phase
//
// The address phase has passed by the time rvalid is high, so the select must
// be registered to steer rdata, err and exokay.
// ---------------------------------------------------------------------------
logic   mem_sel_q;
logic   led_sel_q;
logic   unmapped_q;

always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
        mem_sel_q  <= 1'b0;
        led_sel_q  <= 1'b0;
        unmapped_q <= 1'b0;
    end else begin
        mem_sel_q  <= data_req_i & mem_sel;
        led_sel_q  <= data_req_i & led_sel;
        unmapped_q <= data_req_i & unmapped;
    end
end

// Slave rvalids are mutually exclusive because only one slave ever sees a
// request in a given cycle.
assign data_rvalid_o = mem_rvalid_i | led_rvalid_i | unmapped_q;

assign data_rdata_o  = mem_sel_q ? mem_rdata_i :
                       led_sel_q ? led_rdata_i :
                                   32'h0000_0000;

assign data_err_o    = mem_sel_q ? mem_err_i :
                       led_sel_q ? led_err_i :
                                   unmapped_q;

// led_peripheral has no exclusive-access support, so it contributes 0.
assign data_exokay_o = mem_sel_q ? mem_exokay_i : 1'b0;

endmodule
