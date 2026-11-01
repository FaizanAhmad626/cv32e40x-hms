`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// tb_tdm_master_rx
//
// Self-checking testbench: tdm_master_rx drives 8 SBM100B-TDM models.
//   * Slots 0-2 and 4-7 send {slot, frame_number}; every sample is checked.
//   * Slot 3 sends a 1 kHz sine; its samples are written to tone_slot3.txt
//     for an FFT check.
//   * Checks BCLK frequency/duty, WS width and period, slot masking.
// Override CLK_DIV / TCO / CAPTURE_PHASE with -P on the command line.
// -----------------------------------------------------------------------------
module tb_tdm_master_rx;

    parameter int  CLK_DIV       = 16;
    parameter int  CAPTURE_PHASE = 0;
    parameter real TCO           = 15.0;  // mic clock-to-out (ns)
    parameter real WIRE          = 2.0;   // one-way board/wire delay (ns)
    parameter int  FRAMES        = 64;

    localparam real CLK_NS  = 10.0;                 // 100 MHz
    localparam real BCLK_NS = CLK_NS * CLK_DIV;
    localparam real FS_HZ   = 1.0e9 / (BCLK_NS * 256.0);

    logic clk = 0, rst_n = 0, en = 0;
    logic [7:0] slot_mask = 8'hFF;
    always #(CLK_NS/2) clk = ~clk;

    // DUT pins and board
    logic bclk_o, ws_o;
    wire  sd_bus;          // shared DATA line at the mics
    wire  sd_fpga;         // DATA at the FPGA pin
    wire  bclk_mic, ws_mic;
    pulldown (sd_bus);     // keeps the High-Z bits defined in simulation
    assign #(WIRE) bclk_mic = bclk_o;
    assign #(WIRE) ws_mic   = ws_o;
    assign #(WIRE) sd_fpga  = sd_bus;

    logic signed [23:0] sample;
    logic [2:0]         slot;
    logic               valid, frame_start;

    tdm_master_rx #(.CLK_DIV(CLK_DIV), .CAPTURE_PHASE(CAPTURE_PHASE)) dut (
        .clk_i(clk), .rst_ni(rst_n), .en_i(en), .slot_mask_i(slot_mask),
        .bclk_o(bclk_o), .ws_o(ws_o), .sd_i(sd_fpga),
        .sample_o(sample), .slot_o(slot), .sample_valid_o(valid),
        .frame_start_o(frame_start)
    );

    genvar g;
    generate
        for (g = 0; g < 8; g++) begin : mics
            sbm100b_tdm_model #(
                .SLOT(g), .PATTERN(g == 3 ? 1 : 0), .TONE_HZ(1000.0),
                .FS_HZ(FS_HZ), .TCO(TCO)
            ) mic (.bclk(bclk_mic), .ws(ws_mic), .data(sd_bus));
        end
    endgenerate

    // ---------------- checks ----------------
    int errors = 0, n_samples = 0, n_frames = 0;
    int last_frame [8];
    int per_slot   [8];
    integer fd;

    initial for (int i = 0; i < 8; i++) begin last_frame[i] = -1; per_slot[i] = 0; end

    always @(posedge clk) if (valid) begin
        n_samples++;
        per_slot[slot]++;
        if (!slot_mask[slot]) begin
            $display("ERROR: sample from masked slot %0d", slot); errors++;
        end
        if (slot == 3) begin
            $fdisplay(fd, "%0d", sample);
        end else begin
            if (sample[23:21] !== slot) begin
                $display("ERROR: slot %0d carried slot id %0d (sample %h)", slot, sample[23:21], sample);
                errors++;
            end
            if (last_frame[slot] >= 0 && sample[20:0] !== last_frame[slot] + 1) begin
                $display("ERROR: slot %0d frame %0d after %0d", slot, sample[20:0], last_frame[slot]);
                errors++;
            end
            last_frame[slot] = sample[20:0];
        end
    end

    always @(posedge clk) if (frame_start) n_frames++;

    // BCLK period / duty and WS checks on the FPGA pins
    realtime t_rise, t_fall, t_prev_rise = 0, t_ws_rise = 0, t_ws_prev = 0;
    int bclk_since_ws = 0;
    always @(posedge bclk_o) begin
        t_rise = $realtime;
        if (t_prev_rise > 0 && (t_rise - t_prev_rise) != BCLK_NS) begin
            $display("ERROR: BCLK period %0.1f ns, expected %0.1f", t_rise - t_prev_rise, BCLK_NS); errors++;
        end
        t_prev_rise = t_rise;
        bclk_since_ws++;
    end
    always @(negedge bclk_o) begin
        t_fall = $realtime;
        if (en && t_rise > 0 && (t_fall - t_rise) != BCLK_NS / 2) begin
            $display("ERROR @%0t: BCLK high time %0.1f ns en=%b", $time, t_fall - t_rise, en); errors++;
        end
    end
    always @(posedge ws_o) begin
        t_ws_rise = $realtime;
        if (t_ws_prev > 0 && bclk_since_ws != 256) begin
            $display("ERROR: %0d BCLK periods between WS pulses, expected 256", bclk_since_ws); errors++;
        end
        if (bclk_o !== 1'b0) begin
            $display("ERROR: WS rose while BCLK high"); errors++;
        end
        t_ws_prev = t_ws_rise;
        bclk_since_ws = 0;
    end
    always @(negedge ws_o) begin
        if (en && ($realtime - t_ws_rise) != BCLK_NS) begin
            $display("ERROR @%0t: WS width %0.1f ns en=%b", $time, $realtime - t_ws_rise, en);
            errors++;
        end
    end

    // ---------------- stimulus ----------------
    initial begin
        fd = $fopen("tone_slot3.txt", "w");
        $display("CLK_DIV=%0d  BCLK=%0.4f MHz  fs=%0.3f kHz  TCO=%0.1f ns  CAPTURE_PHASE=%0d",
                 CLK_DIV, 1000.0 / BCLK_NS, FS_HZ / 1000.0, TCO, CAPTURE_PHASE);
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);
        en = 1;

        // all slots enabled
        repeat (FRAMES) @(posedge frame_start);

        // only slot 3 (masking test)
        @(posedge frame_start);
        slot_mask = 8'b0000_1000;
        repeat (8) @(posedge frame_start);

        // disable -> BCLK must stop low
        en = 0;
        repeat (4 * CLK_DIV) @(posedge clk);
        if (bclk_o !== 1'b0 || ws_o !== 1'b0) begin
            $display("ERROR: BCLK/WS not idle low after disable"); errors++;
        end

        $fclose(fd);
        $display("frames=%0d samples=%0d per-slot: %0d %0d %0d %0d %0d %0d %0d %0d",
                 n_frames, n_samples, per_slot[0], per_slot[1], per_slot[2], per_slot[3],
                 per_slot[4], per_slot[5], per_slot[6], per_slot[7]);
        if (errors == 0 && n_samples > 0) $display("TEST PASSED");
        else                              $display("TEST FAILED (%0d errors)", errors);
        $finish;
    end

    initial begin
        $dumpfile("tb_tdm_master_rx.vcd");
        $dumpvars(0, tb_tdm_master_rx);
    end

endmodule
