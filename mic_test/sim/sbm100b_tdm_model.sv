`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// sbm100b_tdm_model  (simulation only)
//
// Behavioural model of one SBM100B-TDM microphone on a shared TDM8 bus,
// following datasheet rev 0.71 section 3.2:
//   * A frame starts on the BCLK rising edge that sees WS high.
//   * On that same rising edge the slot-0 mic launches its MSB; every mic
//     launches one bit per rising edge, TCO ns after the edge.
//   * Each mic drives DATA only during the first 24 bits of its own slot and
//     is High-Z otherwise.
//
// Data: PATTERN=0 -> {SLOT[2:0], frame_number[20:0]} (exact self-check)
//       PATTERN=1 -> sine of TONE_HZ at AMPLITUDE (FS_HZ is the frame rate)
// -----------------------------------------------------------------------------
module sbm100b_tdm_model #(
    parameter int  SLOT      = 0,
    parameter int  PATTERN   = 0,
    parameter real TONE_HZ   = 1000.0,
    parameter real FS_HZ     = 24414.0625,
    parameter real AMPLITUDE = 4000000.0,  // out of 2^23
    parameter real TCO       = 15.0        // clock-to-out, ns
) (
    input  logic bclk,
    input  logic ws,
    inout  wire  data
);
    localparam int SLOT_BITS = 32;
    localparam int DATA_BITS = 24;
    localparam int FRAME     = 256;
    localparam real PI       = 3.14159265358979;

    int   bitpos   = -1;   // bit index within frame, -1 = not synced yet
    int   frame_no = -1;
    logic [DATA_BITS-1:0] word;
    logic drive_en = 1'b0;
    logic drive_val = 1'b0;

    assign data = drive_en ? drive_val : 1'bz;

    function automatic logic [DATA_BITS-1:0] make_word(input int f);
        real v;
        if (PATTERN == 0) begin
            make_word = {SLOT[2:0], f[20:0]};
        end else begin
            v = AMPLITUDE * $sin(2.0 * PI * TONE_HZ * f / FS_HZ);
            make_word = $rtoi(v);
        end
    endfunction

    always @(posedge bclk) begin
        if (ws) begin
            bitpos   = 0;
            frame_no = frame_no + 1;
            word     = make_word(frame_no);
        end else if (bitpos >= 0) begin
            bitpos = (bitpos + 1) % FRAME;
        end

        if (bitpos >= SLOT * SLOT_BITS && bitpos < SLOT * SLOT_BITS + DATA_BITS) begin
            drive_en  <= #(TCO) 1'b1;
            drive_val <= #(TCO) word[DATA_BITS - 1 - (bitpos - SLOT * SLOT_BITS)];
        end else begin
            drive_en  <= #(TCO) 1'b0;
        end
    end
endmodule
