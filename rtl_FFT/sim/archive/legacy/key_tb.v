`timescale 1ns/1ps

module key_tb;

    reg         clk;
    reg         rst_n;
    reg         key_in;
    wire        key_pulse;

    integer errors = 0;
    integer pulses = 0;

    key_debounce #(.DEBOUNCE_CNT(20'd200)) u_kd(
        .clk(clk), .rst_n(rst_n), .key_in(key_in), .key_pulse(key_pulse)
    );

    always #5 clk = ~clk;   // 100MHz

    always @(posedge clk) begin
        if (key_pulse) pulses = pulses + 1;
    end

    task wait_clks(input integer n);
        begin
            repeat (n) @(posedge clk);
        end
    endtask

    initial begin
        clk = 0; rst_n = 0; key_in = 1;
        #20 rst_n = 1;
        wait_clks(5);

        // --- press: hold low for 500 clks (debounce=200) -> 1 pulse ---
        key_in = 0;
        wait_clks(500);
        if (pulses != 1) begin
            $error("after first press: pulses=%0d expect 1", pulses);
            errors = errors + 1;
        end

        // --- release ---
        key_in = 1;
        wait_clks(500);
        if (pulses != 1) begin
            $error("release should not add pulses: got %0d", pulses);
            errors = errors + 1;
        end

        // --- press again ---
        key_in = 0;
        wait_clks(500);
        if (pulses != 2) begin
            $error("second press: pulses=%0d expect 2", pulses);
            errors = errors + 1;
        end
        key_in = 1;
        wait_clks(200);

        // --- bounces: quick toggles shorter than debounce -> no new pulse ---
        key_in = 0; wait_clks(10);
        key_in = 1; wait_clks(10);
        key_in = 0; wait_clks(10);
        key_in = 1; wait_clks(10);
        wait_clks(400);   // settled released
        if (pulses != 2) begin
            $error("bounces should not add pulses: got %0d", pulses);
            errors = errors + 1;
        end

        if (errors == 0) $display("=== KEY TEST PASSED (pulses=%0d) ===", pulses);
        else             $display("=== KEY TEST FAILED: %0d ===", errors);
        $finish;
    end

endmodule