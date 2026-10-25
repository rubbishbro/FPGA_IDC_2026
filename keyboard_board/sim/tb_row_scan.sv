`timescale 1ns/1ps

module tb_row_scan;

    import clk_rst_pkg::*;
    import pad_driver_pkg::*;

    logic       clk;
    logic       rst_n;
    logic [4:0] div;
    logic       clk_en;
    logic [3:0] row_s;
    logic [2:0] ch_s;
    logic       dat;

    clk_rst     cr;
    led_param   led_p;
    input_param input_p;

    time t0, t1, t2, t3, t4;

    pad_driver u_pad (
        .cr      (cr),
        .led_p   (led_p),
        .dat     (dat),
        .input_p (input_p)
    );

    initial clk = 1'b0;
    always #10 clk = ~clk;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            div <= 5'd0;
        else if (div == 5'd19)
            div <= 5'd0;
        else
            div <= div + 5'd1;
    end

    assign clk_en = (div == 5'd19);

    assign row_s = input_p.row_s;

    assign cr.clk    = clk;
    assign cr.clk_en = clk_en;
    assign cr.rst_n  = rst_n;

    initial begin
        rst_n = 1'b0;
        led_p = '0;

        repeat (10) @(posedge clk);
        rst_n = 1'b1;

        wait (row_s == 4'b0100);
        t1 = $time;
        $display("row0 -> row1 at %0t", t1);

        wait (row_s == 4'b0010);
        t2 = $time;
        $display("row1 -> row2 at %0t, delta=%0t ns", t2, t2 - t1);

        wait (row_s == 4'b0001);
        t3 = $time;
        $display("row2 -> row3 at %0t, delta=%0t ns", t3, t3 - t2);

        wait (row_s == 4'b1000);
        t4 = $time;
        $display("row3 -> row0 at %0t, delta=%0t ns", t4, t4 - t3);

        if ((t2 - t1) < 400_000 || (t2 - t1) > 420_000) begin
            $display("=== ROW SCAN TEST FAILED: first row interval wrong ===");
            $finish;
        end
        if ((t3 - t2) < 400_000 || (t3 - t2) > 420_000) begin
            $display("=== ROW SCAN TEST FAILED: second row interval wrong ===");
            $finish;
        end
        if ((t4 - t3) < 400_000 || (t4 - t3) > 420_000) begin
            $display("=== ROW SCAN TEST FAILED: third row interval wrong ===");
            $finish;
        end

        $display("=== ROW SCAN TEST PASSED: ~409.6 us per row ===");
        $finish;
    end

    always @(posedge clk) begin
        if (rst_n && row_s != 4'b1000 && row_s != 4'b0100 &&
            row_s != 4'b0010 && row_s != 4'b0001) begin
            $display("=== ROW SCAN TEST FAILED: row_s not one-hot: %b ===", row_s);
            $finish;
        end
    end

endmodule
