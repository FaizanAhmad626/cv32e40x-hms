//////////////////////////////////////////////////////////////////////////////////
// m24c64_model.sv
//
// Behavioural model of the ST M24C64 I2C EEPROM on the SCU35's I2C0 bus,
// written from the datasheet, not from the RTL it is used to test.
//
//   - memory array at DEV (0x50): two address bytes (13 bits used), 32-byte
//     page writes that wrap inside the page, sequential reads that run
//     across the whole 8 KB array
//   - identification page at ID_DEV (0x58): ACKs its address, nothing more
//   - internal write cycle: after the STOP that ends a write, the device
//     ignores its address (NACK) for T_WRITE_NS, so the host must poll
//   - write control: with wc high the device still ACKs its address and
//     the two memory-address bytes, but NACKs every data byte and writes
//     nothing. On the SCU35, WC is tied high (the EEPROM holds board ID
//     data), so the hardware behaves as wc = 1
//   - optional clock stretching: holds SCL low for stretch_ns after every
//     ACK bit while stretch_en is high (the real M24C64 never does this;
//     it stands in for slow slaves)
//
// Simulation only. Everything happens on bus edges.
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps

module m24c64_model
#(
    parameter logic [6:0]   DEV         = 7'h50,
    parameter logic [6:0]   ID_DEV      = 7'h58,
    parameter int           T_WRITE_NS  = 0
)
(
    inout   wire            scl,
    inout   wire            sda,
    input   logic           rst_n,
    input   logic           wc,         // write control: 1 = write-protected
    input   logic           stretch_en,
    input   int             stretch_ns
);

typedef enum int { M_IDLE, M_DEV, M_AHI, M_ALO, M_WR, M_RD, M_OFF } mstate_e;

logic [7:0]  mem [0:8191];
mstate_e     st    = M_IDLE;
int          bits  = 0;         // bits of the current byte seen so far
logic        in_ack = 0;        // inside the 9th clock
logic [7:0]  sh    = 0;
logic [12:0] ptr   = 0;
logic        rw    = 0;
logic        mack  = 0;         // ACK bit the host sent after a read byte
logic        wrote = 0;         // data bytes arrived in this write
realtime     busy_until = 0;    // internal write cycle
int          starts = 0, stops = 0, stretches = 0, polls_nacked = 0;

logic        sda_low = 1'b0;
logic        scl_low = 1'b0;
assign sda = sda_low ? 1'b0 : 1'bz;
assign scl = scl_low ? 1'b0 : 1'bz;

event        do_stretch;
always @(do_stretch) begin
    scl_low = 1;
    #(stretch_ns);
    scl_low = 0;
end

initial for (int i = 0; i < 8192; i++) mem[i] = 8'(i * 7 + 3);

always @(negedge sda) if (rst_n && scl === 1'b1) begin
    starts++;
    st = M_DEV; bits = 0; in_ack = 0; sda_low = 0; wrote = 0;
end

always @(posedge sda) if (rst_n && scl === 1'b1) begin
    stops++;
    if (st == M_WR && wrote) busy_until = $realtime + T_WRITE_NS;
    st = M_IDLE; sda_low = 0;
end

always @(posedge scl) begin
    if (st != M_IDLE && st != M_OFF) begin
        if (in_ack) begin
            if (st == M_RD) mack = sda;
        end else begin
            if (st != M_RD) sh = {sh[6:0], sda};
            bits++;
        end
    end
end

always @(negedge scl) begin
    if (st == M_IDLE || st == M_OFF) begin
        sda_low = 0;
    end else if (!in_ack && bits == 8) begin
        // 8 bits in: answer in the 9th clock
        in_ack = 1;
        case (st)
            M_DEV: if (sh[7:1] == DEV && $realtime >= busy_until) begin
                       rw = sh[0]; sda_low = 1;
                   end else if (sh[7:1] == ID_DEV && $realtime >= busy_until) begin
                       st = M_OFF; sda_low = 1;             // ACK, then ignore the rest
                   end else begin
                       if (sh[7:1] == DEV) polls_nacked++;
                       st = M_OFF; sda_low = 0;
                   end
            M_AHI: begin ptr[12:8] = sh[4:0]; sda_low = 1; end
            M_ALO: begin ptr[7:0]  = sh;      sda_low = 1; end
            M_WR:  if (wc) begin
                       sda_low = 0;                         // protected: NACK, keep the old byte
                   end else begin
                       mem[ptr] = sh;
                       ptr[4:0] = ptr[4:0] + 5'd1;          // wraps inside the page
                       wrote = 1;
                       sda_low = 1;
                   end
            M_RD:  sda_low = 0;                             // host answers
            default: ;
        endcase
    end else if (in_ack) begin
        // end of the 9th clock
        in_ack = 0; bits = 0;
        case (st)
            M_DEV: st = rw ? M_RD : M_AHI;
            M_AHI: st = M_ALO;
            M_ALO: st = M_WR;
            M_RD:  if (mack) st = M_OFF;                    // NACK: that was the last byte
            M_OFF: ;                                        // ID page: released above
            default: ;
        endcase
        if (st == M_RD) begin
            sh = mem[ptr];
            ptr = ptr + 13'd1;
            sda_low = ~sh[7];
        end else begin
            sda_low = 0;
        end
        if (stretch_en) begin
            stretches++;
            -> do_stretch;
        end
    end else if (st == M_RD) begin
        sda_low = ~sh[7 - bits];
    end
end

endmodule
