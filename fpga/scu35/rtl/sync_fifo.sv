`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: sync_fifo
//
// Single-clock first-word-fall-through FIFO. rdata_o shows the head entry
// whenever empty_o is low; pop_i consumes it.
//
// DEPTH must be a power of two. Pointers carry one extra bit so full and
// empty are told apart without a separate counter.
//
// Plain flops, no vendor primitives, so it maps to an ASIC unchanged. At the
// small depths used by the UART, Vivado infers LUTRAM or flops on its own.
//
// Push when full and pop when empty are ignored. The owner is expected to
// check the flags; the UART records a dropped RX byte as an overrun.
//////////////////////////////////////////////////////////////////////////////////


module sync_fifo
#(
    parameter int unsigned  WIDTH   = 8,
    parameter int unsigned  DEPTH   = 16
)
(
    input   logic               clk_i,
    input   logic               rst_ni,

    input   logic               push_i,
    input   logic   [WIDTH-1:0] wdata_i,
    input   logic               pop_i,
    output  logic   [WIDTH-1:0] rdata_o,

    output  logic               empty_o,
    output  logic               full_o
    );

localparam int unsigned PTR_W = $clog2(DEPTH);

logic   [WIDTH-1:0]     mem [DEPTH];
logic   [PTR_W:0]       wptr_q;
logic   [PTR_W:0]       rptr_q;

logic                   do_push;
logic                   do_pop;

assign empty_o  = (wptr_q == rptr_q);
assign full_o   = (wptr_q[PTR_W] != rptr_q[PTR_W]) &&
                  (wptr_q[PTR_W-1:0] == rptr_q[PTR_W-1:0]);

assign do_push  = push_i & ~full_o;
assign do_pop   = pop_i  & ~empty_o;

always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
        wptr_q <= '0;
        rptr_q <= '0;
    end else begin
        if (do_push) wptr_q <= wptr_q + 1'b1;
        if (do_pop)  rptr_q <= rptr_q + 1'b1;
    end
end

// Storage has no reset: contents are don't-care until written.
always_ff @(posedge clk_i) begin
    if (do_push)
        mem[wptr_q[PTR_W-1:0]] <= wdata_i;
end

assign rdata_o  = mem[rptr_q[PTR_W-1:0]];

endmodule
