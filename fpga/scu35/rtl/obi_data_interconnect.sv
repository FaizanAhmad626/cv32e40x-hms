`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: obi_data_interconnect
//
// Data-side OBI 1-to-N decode and response mux. Owns the entire address map;
// slaves themselves contain no decode logic.
//
// The map is a table of NUM_SLAVES entries. Slave i is selected when
//     (addr & SLV_MASK[i]) == SLV_BASE[i]
// Anything that matches no entry gets an error response. Entries must not
// overlap; if they do, the lowest index wins (priority encoder below), but
// treat an overlap as a bug in the map, not a feature.
//
// Current map (set in cv32e40x_wrapper):
//   0  MEM   0x8000_0000 / 0xFFFF_0000   memory_controller port B (64 KB)
//   1  LED   0x1000_0000 / 0xFFFF_0000   led_peripheral
//   2  UART  0x1001_0000 / 0xFFFF_0000   uart_peripheral
//   3  SPI   0x1002_0000 / 0xFFFF_0000   spi_peripheral
//   4  I2C   0x1003_0000 / 0xFFFF_0000   i2c_peripheral
//
// Every peripheral gets a 64 KB slot. The slave sees the full address and
// decodes its own register offset from the low bits; that is register
// selection inside the slave, not address-map decode.
//
// All slaves are zero-wait-state (gnt = req) and respond exactly one cycle
// after the accepted request, so the select is registered once and used to
// steer rdata, err and exokay during the response phase.
//
// Request payload (addr, be, we, wdata, and the sideband memtype/prot/dbg/
// atop) is broadcast to every slave; only req is gated. That costs nothing
// in logic and keeps each slave's port list uniform. Slaves that do not
// need the sideband simply leave it unconnected.
//
// Adding a slave: bump NUM_SLAVES in the wrapper, append one entry to
// SLV_BASE / SLV_MASK, and connect index N of the slave-side arrays.
//////////////////////////////////////////////////////////////////////////////////


module obi_data_interconnect
#(
    parameter int unsigned                      NUM_SLAVES  = 3,
    parameter logic [NUM_SLAVES-1:0][31:0]      SLV_BASE    = '0,
    parameter logic [NUM_SLAVES-1:0][31:0]      SLV_MASK    = '0
)
(
    input   logic                               clk_i,
    input   logic                               rst_ni,

    // -----------------------------------------------------------------------
    // Upstream: data OBI from the core
    // -----------------------------------------------------------------------
    input   logic                               data_req_i,
    output  logic                               data_gnt_o,
    output  logic                               data_rvalid_o,
    input   logic   [31:0]                      data_addr_i,
    input   logic   [ 3:0]                      data_be_i,
    input   logic                               data_we_i,
    input   logic   [31:0]                      data_wdata_i,
    input   logic   [ 1:0]                      data_memtype_i,
    input   logic   [ 2:0]                      data_prot_i,
    input   logic                               data_dbg_i,
    input   logic   [ 5:0]                      data_atop_i,
    output  logic   [31:0]                      data_rdata_o,
    output  logic                               data_err_o,
    output  logic                               data_exokay_o,

    // -----------------------------------------------------------------------
    // Downstream: one entry per slave
    // -----------------------------------------------------------------------
    output  logic   [NUM_SLAVES-1:0]            slv_req_o,
    input   logic   [NUM_SLAVES-1:0]            slv_gnt_i,
    input   logic   [NUM_SLAVES-1:0]            slv_rvalid_i,
    input   logic   [NUM_SLAVES-1:0][31:0]      slv_rdata_i,
    input   logic   [NUM_SLAVES-1:0]            slv_err_i,
    input   logic   [NUM_SLAVES-1:0]            slv_exokay_i,

    // Broadcast request payload, shared by all slaves
    output  logic   [31:0]                      slv_addr_o,
    output  logic   [ 3:0]                      slv_be_o,
    output  logic                               slv_we_o,
    output  logic   [31:0]                      slv_wdata_o,
    output  logic   [ 1:0]                      slv_memtype_o,
    output  logic   [ 2:0]                      slv_prot_o,
    output  logic                               slv_dbg_o,
    output  logic   [ 5:0]                      slv_atop_o
    );

localparam int unsigned IDX_W = (NUM_SLAVES > 1) ? $clog2(NUM_SLAVES) : 1;

// ---------------------------------------------------------------------------
// Address decode (combinational, request phase)
// ---------------------------------------------------------------------------
logic   [NUM_SLAVES-1:0]    match;
logic   [IDX_W-1:0]         sel_idx;
logic                       hit;

always_comb begin
    for (int i = 0; i < NUM_SLAVES; i++)
        match[i] = ((data_addr_i & SLV_MASK[i]) == SLV_BASE[i]);
end

// Priority encoder: lowest matching index. Written as a downward loop so the
// last assignment (lowest i) wins.
always_comb begin
    sel_idx = '0;
    hit     = 1'b0;
    for (int i = NUM_SLAVES-1; i >= 0; i--) begin
        if (match[i]) begin
            sel_idx = IDX_W'(i);
            hit     = 1'b1;
        end
    end
end

// ---------------------------------------------------------------------------
// Request routing
// ---------------------------------------------------------------------------
always_comb begin
    slv_req_o = '0;
    if (hit)
        slv_req_o[sel_idx] = data_req_i;
end

assign slv_addr_o    = data_addr_i;
assign slv_be_o      = data_be_i;
assign slv_we_o      = data_we_i;
assign slv_wdata_o   = data_wdata_i;
assign slv_memtype_o = data_memtype_i;
assign slv_prot_o    = data_prot_i;
assign slv_dbg_o     = data_dbg_i;
assign slv_atop_o    = data_atop_i;

// An unmapped access is accepted immediately and answered with an error.
assign data_gnt_o    = hit ? slv_gnt_i[sel_idx] : data_req_i;

// ---------------------------------------------------------------------------
// Response phase
//
// The address phase has passed by the time rvalid is high, so the select
// must be registered to steer rdata, err and exokay.
// ---------------------------------------------------------------------------
logic   [IDX_W-1:0]         sel_idx_q;
logic                       hit_q;
logic                       unmapped_q;

always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
        sel_idx_q  <= '0;
        hit_q      <= 1'b0;
        unmapped_q <= 1'b0;
    end else begin
        // Only update on an accepted request; hold otherwise so the steering
        // stays valid through the response cycle.
        if (data_req_i & data_gnt_o) begin
            sel_idx_q <= sel_idx;
            hit_q     <= hit;
        end
        unmapped_q <= data_req_i & ~hit;
    end
end

// Slave rvalids are mutually exclusive because only one slave ever sees a
// request in a given cycle.
assign data_rvalid_o = (|slv_rvalid_i) | unmapped_q;

assign data_rdata_o  = hit_q ? slv_rdata_i[sel_idx_q]  : 32'h0000_0000;
assign data_err_o    = hit_q ? slv_err_i[sel_idx_q]    : unmapped_q;
assign data_exokay_o = hit_q ? slv_exokay_i[sel_idx_q] : 1'b0;

endmodule
