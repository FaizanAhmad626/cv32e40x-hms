`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// tdm_master_rx
//
// TDM8 bus master and receiver for sensiBel SBM100B-TDM microphones.
// The FPGA drives BIT_CLOCK (bclk_o) and WORD_SELECT (ws_o) and samples DATA.
//
// Protocol (SBM100B-TDM datasheet rev 0.71, section 3.2):
//   * Frame = NUM_SLOTS x SLOT_BITS bit clocks (8 x 32 = 256).
//   * WS is high for one BCLK period at the start of the frame. It changes on
//     the BCLK falling edge.
//   * Each mic launches its data on the BCLK rising edge, MSB first. The MSB
//     of slot 0 is launched on the rising edge that occurs while WS is high.
//   * The host samples on the BCLK falling edge (1.8 V direct connection).
//   * Each slot carries DATA_BITS (24) bits; the remaining bits are High-Z.
//   * Sample rate = f_BCLK / 256. The mic picks its operating mode from f_BCLK:
//       Eco   2.6 - 3.6 MHz  (12 kHz)
//       Normal 5.1 - 7.3 MHz (24 kHz)
//       High-Perf 10.2 - 12.5 MHz (48 kHz)
//
// Clocking: everything runs on clk_i. BCLK = clk_i / CLK_DIV (CLK_DIV even).
//   100 MHz / 16 = 6.25 MHz  -> Normal mode, fs = 24.414 kHz
//   100 MHz /  8 = 12.5 MHz  -> High-Perf mode, fs = 48.828 kHz (at the max)
//    50 MHz /  8 = 6.25 MHz  -> Normal mode, fs = 24.414 kHz
//
// Sampling point: sd_i passes through a SYNC_STAGES flop synchronizer. The
// bit is taken from the pin as it was CAPTURE_PHASE clk cycles after this
// block's BCLK falling edge (0 = exactly at the falling edge).
//
// Output: one sample_valid_o pulse per enabled slot per frame, carrying the
// signed 24-bit sample and its slot number.
// -----------------------------------------------------------------------------
module tdm_master_rx #(
    parameter int CLK_DIV       = 16,  // clk_i cycles per BCLK, even, >= 4
    parameter int NUM_SLOTS     = 8,
    parameter int SLOT_BITS     = 32,
    parameter int DATA_BITS     = 24,
    parameter int SYNC_STAGES   = 2,
    parameter int CAPTURE_PHASE = 0
) (
    input  logic                          clk_i,
    input  logic                          rst_ni,
    input  logic                          en_i,         // 0: BCLK stopped (mic sleep)
    input  logic [NUM_SLOTS-1:0]          slot_mask_i,  // which slots produce samples

    output logic                          bclk_o,
    output logic                          ws_o,
    input  logic                          sd_i,

    output logic signed [DATA_BITS-1:0]   sample_o,
    output logic [$clog2(NUM_SLOTS)-1:0]  slot_o,
    output logic                          sample_valid_o,
    output logic                          frame_start_o  // pulses when WS goes high
);

    localparam int HALF       = CLK_DIV / 2;
    localparam int FRAME_BITS = NUM_SLOTS * SLOT_BITS;
    localparam int DIV_W      = $clog2(CLK_DIV);
    localparam int BIT_W      = $clog2(FRAME_BITS);
    localparam int POS_W      = $clog2(SLOT_BITS);
    localparam int SLOT_W     = $clog2(NUM_SLOTS);
    localparam int CAP_CNT    = SYNC_STAGES - 1 + CAPTURE_PHASE;

    // Parameter checks (elaboration time)
    initial begin
        if ((CLK_DIV % 2) != 0 || CLK_DIV < 4)
            $fatal(1, "tdm_master_rx: CLK_DIV must be even and >= 4");
        if (CAP_CNT >= CLK_DIV)
            $fatal(1, "tdm_master_rx: SYNC_STAGES + CAPTURE_PHASE too large for CLK_DIV");
        if (DATA_BITS > SLOT_BITS)
            $fatal(1, "tdm_master_rx: DATA_BITS must be <= SLOT_BITS");
    end

    // -------------------------------------------------------------------------
    // BCLK / WS generation
    // One BCLK period runs from falling edge (div_cnt 0) to the next falling edge.
    // BCLK is low for div_cnt 0 .. HALF-1 and high for HALF .. CLK_DIV-1.
    // -------------------------------------------------------------------------
    logic [DIV_W-1:0] div_cnt;
    logic [BIT_W-1:0] bit_cnt;   // index of the current BCLK period in the frame
    logic             running;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            div_cnt <= '0;
            bit_cnt <= BIT_W'(FRAME_BITS - 1);  // first period after enable is bit 0
            bclk_o  <= 1'b0;
            ws_o    <= 1'b0;
            running <= 1'b0;
        end else if (!en_i) begin
            div_cnt <= '0;
            bit_cnt <= BIT_W'(FRAME_BITS - 1);
            bclk_o  <= 1'b0;
            ws_o    <= 1'b0;
            running <= 1'b0;
        end else begin
            running <= 1'b1;
            if (div_cnt == DIV_W'(CLK_DIV - 1)) begin
                // falling edge: start of a new BCLK period
                div_cnt <= '0;
                bclk_o  <= 1'b0;
                if (bit_cnt == BIT_W'(FRAME_BITS - 1)) begin
                    bit_cnt <= '0;
                    ws_o    <= 1'b1;
                end else begin
                    bit_cnt <= bit_cnt + 1'b1;
                    ws_o    <= 1'b0;
                end
            end else begin
                div_cnt <= div_cnt + 1'b1;
                if (div_cnt == DIV_W'(HALF - 1))
                    bclk_o <= 1'b1;  // rising edge: mics launch the next bit
            end
        end
    end

    // -------------------------------------------------------------------------
    // DATA synchronizer
    // -------------------------------------------------------------------------
    logic [SYNC_STAGES-1:0] sd_sync;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) sd_sync <= '0;
        else         sd_sync <= {sd_sync[SYNC_STAGES-2:0], sd_i};
    end

    // -------------------------------------------------------------------------
    // Capture
    // At the clk edge where div_cnt == CAP_CNT, sd_sync[MSB] holds the pin value
    // from CAPTURE_PHASE cycles after the falling edge that ended the previous
    // BCLK period. That period's frame index is bit_cnt - 1.
    // -------------------------------------------------------------------------
    logic             first_period;  // no completed period yet after enable
    logic [BIT_W-1:0] cap_idx;
    logic [POS_W-1:0] cap_pos;
    logic [SLOT_W-1:0] cap_slot;
    logic             cap_tick;
    logic [DATA_BITS-1:0] shreg;

    assign cap_idx  = (bit_cnt == '0) ? BIT_W'(FRAME_BITS - 1) : bit_cnt - 1'b1;
    assign cap_pos  = cap_idx[POS_W-1:0];
    assign cap_slot = cap_idx[BIT_W-1:POS_W];
    assign cap_tick = running && !first_period && (div_cnt == DIV_W'(CAP_CNT));

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            first_period   <= 1'b1;
            shreg          <= '0;
            sample_o       <= '0;
            slot_o         <= '0;
            sample_valid_o <= 1'b0;
            frame_start_o  <= 1'b0;
        end else begin
            sample_valid_o <= 1'b0;
            frame_start_o  <= 1'b0;

            if (!en_i) begin
                first_period <= 1'b1;
            end else if (running && div_cnt == DIV_W'(CLK_DIV - 1)) begin
                first_period <= 1'b0;  // the first period (bit 0) is now complete
                if (bit_cnt == BIT_W'(FRAME_BITS - 1))
                    frame_start_o <= 1'b1;
            end

            if (cap_tick && cap_pos < POS_W'(DATA_BITS)) begin
                shreg <= {shreg[DATA_BITS-2:0], sd_sync[SYNC_STAGES-1]};
                if (cap_pos == POS_W'(DATA_BITS - 1)) begin
                    sample_o       <= {shreg[DATA_BITS-2:0], sd_sync[SYNC_STAGES-1]};
                    slot_o         <= cap_slot;
                    sample_valid_o <= slot_mask_i[cap_slot];
                end
            end
        end
    end

endmodule
