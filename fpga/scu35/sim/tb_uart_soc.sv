//////////////////////////////////////////////////////////////////////////////////
// tb_uart_soc.sv
//
// Whole-SoC test for the UART: runs the real uart_demo firmware on the
// CV32E40X and checks the pins.
//
//   1. Decode uart_tx_o and wait for the banner line.
//   2. Send "Hi\r" into uart_rx_i and check the echo "Hi\r\n> ".
//   3. Check the LEDs show 0xD, the low nibble of the last character sent
//      ('\r'). A trap would show 0xA instead (crt0 writes 0xAA).
//
// PASS/FAIL is printed and the exit code is non-zero on failure.
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps

module tb_uart_soc;

localparam real CLK_PERIOD_NS = 10.0;           // 100 MHz board clock
localparam int  BAUD          = 115200;
localparam real BIT_NS        = 1.0e9 / BAUD;   // 8680.6 ns

logic       clk_p = 1'b0;
logic       rst_n = 1'b0;
logic [4:0] led;
logic       uart_rx = 1'b1;     // host -> FPGA
logic       uart_tx;            // FPGA -> host

always #(CLK_PERIOD_NS/2) clk_p = ~clk_p;

cv32e40x_wrapper dut (
    .clk_p_i   ( clk_p   ),
    .clk_n_i   ( ~clk_p  ),
    .rst_ni    ( rst_n   ),
    .led_o     ( led     ),
    .uart_rx_i ( uart_rx ),
    .uart_tx_o ( uart_tx )
);

// ---------------------------------------------------------------------------
// Host-side receiver: decodes uart_tx into a string
// ---------------------------------------------------------------------------
string rx_log = "";

initial begin : host_rx
    logic [7:0] b;
    forever begin
        @(negedge uart_tx);
        #(BIT_NS * 1.5);                        // middle of bit 0
        for (int i = 0; i < 8; i++) begin
            b[i] = uart_tx;
            #(BIT_NS);
        end
        if (uart_tx !== 1'b1)
            $display("[%0t] host: FRAMING ERROR on byte 0x%02h", $time, b);
        rx_log = {rx_log, string'(b)};
        // Echo to the console, prefixing each line so it stands out.
        if      (b == 8'h0A) $write("\nhost < ");
        else if (b != 8'h0D) $write("%s", string'(b));
    end
end

// ---------------------------------------------------------------------------
// Host-side transmitter
// ---------------------------------------------------------------------------
task automatic host_send(input byte c);
    uart_rx = 1'b0;             #(BIT_NS);
    for (int i = 0; i < 8; i++) begin
        uart_rx = c[i];         #(BIT_NS);
    end
    uart_rx = 1'b1;             #(BIT_NS);
endtask

function automatic bit contains(string hay, string needle);
    if (needle.len() > hay.len()) return 0;
    for (int i = 0; i <= hay.len() - needle.len(); i++)
        if (hay.substr(i, i + needle.len() - 1) == needle) return 1;
    return 0;
endfunction

// ---------------------------------------------------------------------------
// Test sequence
// ---------------------------------------------------------------------------
int errors = 0;

task automatic wait_for(string s, int timeout_ms);
    real waited = 0.0;
    // Written as forever+return rather than while(!contains(...)):
    // the simulator (Verilator 5.020) does not re-evaluate a while condition containing a
    // function call across a timing control inside the loop body.
    forever begin
        bit found;
        found = contains(rx_log, s);
        if (found) return;
        if (waited > real'(timeout_ms) * 1.0e6) begin
            $display("\nFAIL: timed out waiting for \"%s\"", s);
            $write("received:");
            for (int k = 0; k < rx_log.len(); k++) $write(" %02h", rx_log[k]);
            $display("");
            errors++;
            return;
        end
        #(BIT_NS);
        waited += BIT_NS;
    end
endtask

initial begin
    $display("tb_uart_soc: 115200 8N1, board clock 100 MHz");
    #(CLK_PERIOD_NS * 20);
    rst_n = 1'b1;

    // Banner: ~130 chars at ~11.5 kchar/s is ~12 ms of wire time.
    wait_for("Type something, it will be echoed.\r\n> ", 60);
    if (!contains(rx_log, "BAUDDIV = 0x000001B2")) begin
        $display("\nFAIL: BAUDDIV readback wrong (expected 0x1B2 = 434)");
        errors++;
    end
    // STATUS bits 5:2 (RX and error flags) must be clear. Bits 1:0 depend
    // on how full the TX FIFO was at the time of the read, which is fine.
    if (!contains(rx_log, "STATUS  = 0x0000000")) begin
        $display("\nFAIL: unexpected STATUS readback");
        errors++;
    end

    rx_log = "";
    host_send("H");
    host_send("i");
    host_send(8'h0D);
    wait_for("Hi\r\n> ", 10);

    if (led[3:0] !== 4'hD) begin
        $display("\nFAIL: LEDs show %h, expected D (low nibble of CR)", led[3:0]);
        errors++;
    end

    $display("\n----------------------------------------");
    if (errors == 0) $display("PASS: tb_uart_soc");
    else             $display("FAIL: tb_uart_soc, %0d error(s)", errors);
    $display("----------------------------------------");
    if (errors != 0) $fatal(1);
    $finish;
end

endmodule
