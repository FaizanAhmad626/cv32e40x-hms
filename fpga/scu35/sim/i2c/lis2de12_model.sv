//////////////////////////////////////////////////////////////////////////////////
// lis2de12_model.sv
//
// Behavioural model of the ST LIS2DE12 accelerometer on the SCU35's I2C3
// bus, written from the datasheet (DocID025056), not from the RTL.
//
//   - 7-bit address DEV (0x18 with SA0 low, as on the SCU35)
//   - write: address byte, register sub-address, then data bytes
//   - read: write the sub-address, repeated START, read bytes
//   - sub-address bit 7 set = auto-increment across a multi-byte access
//   - WHO_AM_I (0x0F) = 0x33, CTRL_REG1 (0x20) resets to 0x07, and
//     CTRL_REG1..CTRL_REG6 (0x20..0x25) read back what was written
//   - STATUS_REG (0x27) reports ZYXDA once CTRL_REG1 selects a data rate
//   - OUT_X_H/OUT_Y_H/OUT_Z_H (0x29/0x2B/0x2D) hold the accel_x/y/z inputs
//     (8-bit two's complement, 15.6 mg/digit at +-2 g); they read 0 while
//     the device is powered down (ODR = 0)
//   - every other register reads 0, writes to read-only registers are
//     ACKed and ignored
//
// Simulation only. Everything happens on bus edges.
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps

module lis2de12_model
#(
    parameter logic [6:0]   DEV         = 7'h18
)
(
    inout   wire            scl,
    inout   wire            sda,
    input   logic           rst_n,
    input   logic [7:0]     accel_x,    // what the sensor "feels", in LSB
    input   logic [7:0]     accel_y,
    input   logic [7:0]     accel_z
);

typedef enum int { A_IDLE, A_DEV, A_SUB, A_WR, A_RD, A_OFF } astate_e;

logic [7:0]  regs [0:63];
astate_e     st     = A_IDLE;
int          bits   = 0;
logic        in_ack = 0;
logic [7:0]  sh     = 0;
logic [5:0]  sub    = 0;
logic        inc    = 0;        // auto-increment requested
logic        rw     = 0;
logic        mack   = 0;
int          writes = 0;        // register writes accepted

logic        sda_low = 1'b0;
assign sda = sda_low ? 1'b0 : 1'bz;

initial begin
    for (int i = 0; i < 64; i++) regs[i] = 8'h00;
    regs[6'h0F] = 8'h33;        // WHO_AM_I
    regs[6'h20] = 8'h07;        // CTRL_REG1: power-down, X/Y/Z enabled
end

function automatic logic [7:0] rd_reg(input logic [5:0] a);
    logic on = (regs[6'h20][7:4] != 4'h0);
    case (a)
        6'h27:   return on ? 8'h08 : 8'h00;             // STATUS_REG.ZYXDA
        6'h29:   return on ? accel_x : 8'h00;
        6'h2B:   return on ? accel_y : 8'h00;
        6'h2D:   return on ? accel_z : 8'h00;
        default: return regs[a];
    endcase
endfunction

function automatic logic writable(input logic [5:0] a);
    return (a >= 6'h1E && a <= 6'h25) || (a >= 6'h2E && a <= 6'h3F);
endfunction

always @(negedge sda) if (rst_n && scl === 1'b1) begin
    st = A_DEV; bits = 0; in_ack = 0; sda_low = 0;
end

always @(posedge sda) if (rst_n && scl === 1'b1) begin
    st = A_IDLE; sda_low = 0;
end

always @(posedge scl) begin
    if (st != A_IDLE && st != A_OFF) begin
        if (in_ack) begin
            if (st == A_RD) mack = sda;
        end else begin
            if (st != A_RD) sh = {sh[6:0], sda};
            bits++;
        end
    end
end

always @(negedge scl) begin
    if (st == A_IDLE || st == A_OFF) begin
        sda_low = 0;
    end else if (!in_ack && bits == 8) begin
        in_ack = 1;
        case (st)
            A_DEV: if (sh[7:1] == DEV) begin rw = sh[0]; sda_low = 1; end
                   else begin st = A_OFF; sda_low = 0; end
            A_SUB: begin sub = sh[5:0]; inc = sh[7]; sda_low = 1; end
            A_WR:  begin
                       if (writable(sub)) begin regs[sub] = sh; writes++; end
                       if (inc) sub = sub + 6'd1;
                       sda_low = 1;
                   end
            A_RD:  sda_low = 0;
            default: ;
        endcase
    end else if (in_ack) begin
        in_ack = 0; bits = 0;
        case (st)
            A_DEV: st = rw ? A_RD : A_SUB;
            A_SUB: st = A_WR;
            A_RD:  if (mack) st = A_OFF;
            default: ;
        endcase
        if (st == A_RD) begin
            sh = rd_reg(sub);
            if (inc) sub = sub + 6'd1;
            sda_low = ~sh[7];
        end else begin
            sda_low = 0;
        end
    end else if (st == A_RD) begin
        sda_low = ~sh[7 - bits];
    end
end

endmodule
