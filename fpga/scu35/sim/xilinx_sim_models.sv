//////////////////////////////////////////////////////////////////////////////////
// xilinx_sim_models.sv
//
// Behavioural stand-ins for the Vivado primitives and IP the SCU35 wrapper
// instantiates, so the SoC can be simulated outside Vivado (Verilator).
// SIMULATION ONLY. Vivado never sees this directory.
//
//   IBUFDS         O = I
//   clk_wiz_0      clk_out1 = clk_in1 / 2 (100 -> 50 MHz), locked after 16 edges
//   blk_mem_gen_0  true dual port, read latency 1, READ_FIRST,
//                  preloaded from +MEM_HEX=<file> (one 32-bit word per line)
//////////////////////////////////////////////////////////////////////////////////

module IBUFDS #(parameter IOSTANDARD = "DEFAULT") (
    input  logic I,
    input  logic IB,
    output logic O
);
    assign O = I;
endmodule


module clk_wiz_0 (
    input  logic clk_in1,
    output logic clk_out1,
    output logic locked
);
    logic       div_q  = 1'b0;
    logic [4:0] cnt_q  = '0;

    always_ff @(posedge clk_in1) begin
        div_q <= ~div_q;
        if (!cnt_q[4]) cnt_q <= cnt_q + 1'b1;
    end

    assign clk_out1 = div_q;
    assign locked   = cnt_q[4];
endmodule


module blk_mem_gen_0 (
    input  logic        clka,
    input  logic [3:0]  wea,
    input  logic [13:0] addra,
    input  logic [31:0] dina,
    output logic [31:0] douta,
    input  logic        clkb,
    input  logic [3:0]  web,
    input  logic [13:0] addrb,
    input  logic [31:0] dinb,
    output logic [31:0] doutb
);
    logic [31:0] mem [16384];
    string       hex;

    initial begin
        for (int i = 0; i < 16384; i++) mem[i] = 32'h0;
        if ($value$plusargs("MEM_HEX=%s", hex)) begin
            $readmemh(hex, mem);
            $display("[blk_mem_gen_0] loaded %s", hex);
        end else begin
            $fatal(1, "[blk_mem_gen_0] no +MEM_HEX=<file> given");
        end
    end

    // Port A is read-only in this design (wea tied to 0).
    always_ff @(posedge clka) douta <= mem[addra];

    always_ff @(posedge clkb) begin
        doutb <= mem[addrb];                // READ_FIRST
        for (int b = 0; b < 4; b++)
            if (web[b]) mem[addrb][8*b +: 8] <= dinb[8*b +: 8];
    end
endmodule
