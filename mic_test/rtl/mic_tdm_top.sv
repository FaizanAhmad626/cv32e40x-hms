`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// mic_tdm_top
//
// Hardware tone test: SCU35 as TDM master for the SB-POLARIS board through J2.
//
// Wiring (SB-POLARIS J2 -> SCU35 PMOD0, all 3.3 V):
//   3.3 V -> PMOD0 3.3 V (switched rail, enabled by pmod_3v3_on_o)
//   GND   -> PMOD0 GND
//   BCLK  -> PMOD0_P1  (R4)
//   WS    -> PMOD0_P2  (R3)
//   DATA  -> PMOD0_P3  (W3)
//
// Sequence after configuration:
//   1. pmod_3v3_on_o goes high: POLARIS powers up (green D2 LED).
//   2. After POWER_WAIT_CYC, BCLK and WS start (orange D1 LED).
//   3. tdm_master_rx delivers one 24-bit sample per slot per frame
//      (100 MHz / 16 = 6.25 MHz BCLK, Normal mode, fs = 24.414 kHz).
//
// The ILA (tdm_ila) records sample, slot and valid, plus the raw pins.
// Set its capture control to "sample_valid == 1" (and "slot == N" for one
// mic) so every stored entry is a sample instead of an idle clock cycle.
// -----------------------------------------------------------------------------
module mic_tdm_top #(
    parameter int CLK_DIV        = 16,          // 6.25 MHz BCLK from 100 MHz
    parameter int CAPTURE_PHASE  = 3,           // sample DATA 30 ns after BCLK fall
    parameter int POWER_WAIT_CYC = 5_000_000    // 50 ms between 3.3 V on and BCLK
) (
    input  logic clk_p,
    input  logic clk_n,

    output logic pmod_3v3_on_o,   // PMOD 3.3 V load switch enable
    output logic mic_bclk_o,      // J2 BCLK
    output logic mic_ws_o,        // J2 WS
    input  logic mic_sd_i         // J2 DATA
);

    // -------------------------------------------------------------------------
    // 100 MHz system clock
    // -------------------------------------------------------------------------
    logic clk;

    IBUFDS #(
        .IOSTANDARD("LVDS")
    ) u_ibufds_sysclk (
        .I  (clk_p),
        .IB (clk_n),
        .O  (clk)
    );

    // -------------------------------------------------------------------------
    // Power-on reset (no button needed): hold reset for 256 cycles
    // -------------------------------------------------------------------------
    logic [7:0] por_cnt = '0;
    logic       rst_n   = 1'b0;

    always_ff @(posedge clk) begin
        if (por_cnt != 8'hFF) por_cnt <= por_cnt + 1'b1;
        rst_n <= (por_cnt == 8'hFF);
    end

    // -------------------------------------------------------------------------
    // Power sequencing: 3.3 V on first, BCLK only once the rail has settled
    // -------------------------------------------------------------------------
    logic [$clog2(POWER_WAIT_CYC+1)-1:0] pwr_cnt;
    logic                                mic_en;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pmod_3v3_on_o <= 1'b0;
            pwr_cnt       <= '0;
            mic_en        <= 1'b0;
        end else begin
            pmod_3v3_on_o <= 1'b1;
            if (pwr_cnt != POWER_WAIT_CYC) pwr_cnt <= pwr_cnt + 1'b1;
            else                           mic_en  <= 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // TDM8 master / receiver
    // -------------------------------------------------------------------------
    logic signed [23:0] sample;
    logic [2:0]         slot;
    logic               sample_valid;
    logic               frame_start;

    tdm_master_rx #(
        .CLK_DIV       (CLK_DIV),
        .NUM_SLOTS     (8),
        .SLOT_BITS     (32),
        .DATA_BITS     (24),
        .SYNC_STAGES   (2),
        .CAPTURE_PHASE (CAPTURE_PHASE)
    ) u_tdm (
        .clk_i          (clk),
        .rst_ni         (rst_n),
        .en_i           (mic_en),
        .slot_mask_i    (8'hFF),
        .bclk_o         (mic_bclk_o),
        .ws_o           (mic_ws_o),
        .sd_i           (mic_sd_i),
        .sample_o       (sample),
        .slot_o         (slot),
        .sample_valid_o (sample_valid),
        .frame_start_o  (frame_start)
    );

    // -------------------------------------------------------------------------
    // ILA
    // -------------------------------------------------------------------------
    tdm_ila u_ila (
        .clk    (clk),
        .probe0 (sample),        // [23:0] signed sample
        .probe1 (slot),          // [2:0]  slot number
        .probe2 (sample_valid),  // [0:0]
        .probe3 (frame_start),   // [0:0]
        .probe4 (mic_bclk_o),    // [0:0]
        .probe5 (mic_ws_o),      // [0:0]
        .probe6 (mic_sd_i)       // [0:0]  raw DATA pin
    );

endmodule
