`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: i2c_master
//
// I2C master byte engine, single master, 7-bit addressing done in software.
// One command = an optional START, then an optional byte (WRITE or READ),
// then an optional STOP, executed in that order. Software strings commands
// together to build a transaction:
//
//   START+WRITE(addr<<1|0)  WRITE(reg)  START+WRITE(addr<<1|1)  READ+NACK+STOP
//
// A START while the bus is already held is a repeated START.
//
// Timing
//   div_i = clk_i cycles per quarter SCL period. Every bit is four quarters:
//     q0  SCL low,  SDA set up      (start, data, stop each set SDA here)
//     q1  SCL released, high         (waits here while a slave stretches)
//     q2  SCL high                   (SDA sampled at the q1/q2 boundary)
//     q3  SCL pulled low
//   so SCL = fclk / (4 * div_i), 50 % duty, and SDA only moves a full quarter
//   after SCL falls and a full quarter before it rises. Values below MIN_DIV
//   are raised to MIN_DIV.
//
//   The quarter counter only starts in q1 once SCL is seen high through the
//   two-flop synchroniser. That is clock stretching, and it also means the
//   high phase is a few cycles longer than 2 * div_i (about 3 cycles of pin
//   and synchroniser delay), so the real SCL rate is a hair under nominal.
//
//   At 50 MHz: div 125 -> 100 kHz (tLOW 5 us), div 33 -> 379 kHz
//   (tLOW 1.32 us, the first value that meets the 1.3 us Fast-mode minimum).
//
// Pins are open drain. scl_oe_o / sda_oe_o = 1 pulls the line low, 0 lets
// the pull-up take it high. The tri-state buffer lives outside this module
// (in the wrapper), so the engine has no vendor primitives or inout ports.
// Both outputs come straight from flops.
//
// Not supported: multi-master arbitration, 10-bit addressing (possible in
// software), Hs-mode. abort_i drops everything and releases both lines at
// once; it is for recovering a hung transfer, not a clean STOP.
//////////////////////////////////////////////////////////////////////////////////


module i2c_master
#(
    parameter int unsigned  MIN_DIV     = 4
)
(
    input   logic           clk_i,
    input   logic           rst_ni,

    input   logic   [15:0]  div_i,

    input   logic           cmd_valid_i,    // taken only while idle
    input   logic           cmd_start_i,
    input   logic           cmd_stop_i,
    input   logic           cmd_write_i,
    input   logic           cmd_read_i,     // ignored if cmd_write_i is set
    input   logic           cmd_nack_i,     // READ only: answer NACK instead of ACK
    input   logic   [ 7:0]  cmd_data_i,     // WRITE only: the byte to send
    input   logic           abort_i,

    output  logic           busy_o,         // a command is executing
    output  logic           held_o,         // between our START and STOP
    output  logic           done_o,         // one-cycle pulse when a command ends
    output  logic           rx_nack_o,      // ACK bit seen after the last WRITE (1 = NACK)
    output  logic   [ 7:0]  rx_data_o,      // byte from the last READ
    output  logic           scl_o,          // synchronised pin levels, for status
    output  logic           sda_o,

    input   logic           scl_i,
    input   logic           sda_i,
    output  logic           scl_oe_o,
    output  logic           sda_oe_o
    );

typedef enum logic [1:0] {
    S_IDLE,
    S_START,
    S_DATA,     // 8 data bits + 1 ACK bit
    S_STOP
} state_e;

state_e         state_q;
logic   [ 1:0]  qtr_q;          // quarter within the current bit
logic   [ 3:0]  bit_q;          // 0..7 data, 8 = ACK
logic   [15:0]  cnt_q;          // cycles left in this quarter
logic   [ 7:0]  sh_q;           // WRITE: next bit is sh_q[7]; READ: bits enter at [0]
logic   [ 7:0]  rx_q;
logic           do_stop_q, do_write_q, do_read_q, nack_q;
logic           held_q;
logic           rx_nack_q;
logic           done_q;
logic           scl_oe_q, sda_oe_q;
logic           scl_s1, scl_s, sda_s1, sda_s;

logic   [15:0]  quarter;
logic           running;
logic           stretch;
logic           tick;           // the current quarter ends this cycle
logic           scl_oe_d, sda_oe_d;
logic           drive_low;      // DATA: what SDA should be this bit

assign quarter  = (div_i < 16'(MIN_DIV)) ? 16'(MIN_DIV) : div_i;
assign running  = (state_q != S_IDLE);
// q1 always releases SCL; if it is still low, someone is holding it.
assign stretch  = running & (qtr_q == 2'd1) & ~scl_s;
assign tick     = running & ~stretch & (cnt_q == '0);

// ---------------------------------------------------------------------------
// Pin synchronisers. Reset high, which is the idle bus level.
// ---------------------------------------------------------------------------
always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
        scl_s1 <= 1'b1; scl_s <= 1'b1;
        sda_s1 <= 1'b1; sda_s <= 1'b1;
    end else begin
        scl_s1 <= scl_i; scl_s <= scl_s1;
        sda_s1 <= sda_i; sda_s <= sda_s1;
    end
end

// ---------------------------------------------------------------------------
// Quarter-period counter. Held at full while idle or while SCL is stretched,
// so every quarter is a full quarter measured from when it really started.
// ---------------------------------------------------------------------------
always_ff @(posedge clk_i) begin
    if (!rst_ni)
        cnt_q <= '0;
    else if (!running || stretch || tick)
        cnt_q <= quarter - 16'd1;
    else
        cnt_q <= cnt_q - 16'd1;
end

// ---------------------------------------------------------------------------
// Sequencer
// ---------------------------------------------------------------------------
always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
        state_q    <= S_IDLE;
        qtr_q      <= '0;
        bit_q      <= '0;
        sh_q       <= '0;
        rx_q       <= '0;
        do_stop_q  <= 1'b0;
        do_write_q <= 1'b0;
        do_read_q  <= 1'b0;
        nack_q     <= 1'b0;
        held_q     <= 1'b0;
        rx_nack_q  <= 1'b0;
        done_q     <= 1'b0;
    end else begin
        done_q <= 1'b0;

        if (abort_i) begin
            state_q <= S_IDLE;
            held_q  <= 1'b0;
            done_q  <= running;
        end else if (state_q == S_IDLE) begin
            if (cmd_valid_i) begin
                do_stop_q  <= cmd_stop_i;
                do_write_q <= cmd_write_i;
                do_read_q  <= cmd_read_i & ~cmd_write_i;
                nack_q     <= cmd_nack_i;
                sh_q       <= cmd_data_i;
                qtr_q      <= '0;
                bit_q      <= '0;
                if (cmd_start_i)                    state_q <= S_START;
                else if (cmd_write_i | cmd_read_i)  state_q <= S_DATA;
                else if (cmd_stop_i)                state_q <= S_STOP;
                // an empty command does nothing
            end
        end else if (tick) begin
            qtr_q <= qtr_q + 2'd1;

            // Sample at the end of q1: SCL has been high for a full quarter.
            if (state_q == S_DATA && qtr_q == 2'd1) begin
                if (bit_q == 4'd8) begin
                    if (do_write_q) rx_nack_q <= sda_s;
                end else if (do_read_q) begin
                    sh_q <= {sh_q[6:0], sda_s};
                end
            end

            if (qtr_q == 2'd3) begin
                unique case (state_q)
                    S_START: begin
                        held_q <= 1'b1;
                        if (do_write_q | do_read_q) state_q <= S_DATA;
                        else if (do_stop_q)         state_q <= S_STOP;
                        else begin                  state_q <= S_IDLE; done_q <= 1'b1; end
                    end
                    S_DATA: begin
                        if (bit_q == 4'd8) begin
                            bit_q <= '0;
                            if (do_read_q) rx_q <= sh_q;
                            if (do_stop_q) state_q <= S_STOP;
                            else begin     state_q <= S_IDLE; done_q <= 1'b1; end
                        end else begin
                            bit_q <= bit_q + 4'd1;
                            if (do_write_q) sh_q <= {sh_q[6:0], 1'b0};
                        end
                    end
                    S_STOP: begin
                        held_q  <= 1'b0;
                        state_q <= S_IDLE;
                        done_q  <= 1'b1;
                    end
                    default: ;
                endcase
            end
        end
    end
end

// ---------------------------------------------------------------------------
// Line drive (1 = pull low), decoded from state and registered below.
// ---------------------------------------------------------------------------
always_comb begin
    if (bit_q == 4'd8) drive_low = do_write_q ? 1'b0 : ~nack_q;    // ACK is a low
    else               drive_low = do_write_q ? ~sh_q[7] : 1'b0;   // READ releases SDA
end

always_comb begin
    // Idle: while we hold the bus between commands, keep SCL low so no slave
    // sees a clock, and leave SDA released. After STOP, release both.
    scl_oe_d = held_q;
    sda_oe_d = 1'b0;
    unique case (state_q)
        S_START: unique case (qtr_q)
            2'd0: begin scl_oe_d = held_q; sda_oe_d = 1'b0; end  // SDA up (for a repeated START)
            2'd1: begin scl_oe_d = 1'b0;   sda_oe_d = 1'b0; end  // SCL up
            2'd2: begin scl_oe_d = 1'b0;   sda_oe_d = 1'b1; end  // SDA falls with SCL high: START
            2'd3: begin scl_oe_d = 1'b1;   sda_oe_d = 1'b1; end
        endcase
        S_DATA: begin
            scl_oe_d = (qtr_q == 2'd0) | (qtr_q == 2'd3);
            sda_oe_d = drive_low;
        end
        S_STOP: unique case (qtr_q)
            2'd0: begin scl_oe_d = 1'b1;   sda_oe_d = 1'b1; end  // SDA down while SCL low
            2'd1: begin scl_oe_d = 1'b0;   sda_oe_d = 1'b1; end  // SCL up
            2'd2: begin scl_oe_d = 1'b0;   sda_oe_d = 1'b0; end  // SDA rises with SCL high: STOP
            2'd3: begin scl_oe_d = 1'b0;   sda_oe_d = 1'b0; end  // bus free time
        endcase
        default: ;
    endcase
end

always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
        scl_oe_q <= 1'b0;
        sda_oe_q <= 1'b0;
    end else begin
        scl_oe_q <= scl_oe_d;
        sda_oe_q <= sda_oe_d;
    end
end

assign scl_oe_o  = scl_oe_q;
assign sda_oe_o  = sda_oe_q;
assign busy_o    = running;
assign held_o    = held_q;
assign done_o    = done_q;
assign rx_nack_o = rx_nack_q;
assign rx_data_o = rx_q;
assign scl_o     = scl_s;
assign sda_o     = sda_s;

endmodule
