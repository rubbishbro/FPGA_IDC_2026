`timescale 1ns/1ps

module pll_test_tb;

    reg         clk;
    wire        clkout0;

    Gowin_PLL u_pll(
        .clkout0(clkout0),
        .clkin(clk)
    );

    integer n_pos = 0;
    real     period_ns;

    initial begin
        clk = 0;
        // drive 50MHz input
        forever #10 clk = ~clk;
    end

    // measure clkout0 period after lock
    initial begin
        #1000;   // wait for PLL to settle
        n_pos = 0;
        wait (clkout0 === 1'b1);
        // count 100 rising edges
        repeat (100) begin
            @(posedge clkout0);
        end
        period_ns = 20.0 * 100.0 / 100.0;  // 100 edges * 20ns sim... 
        // actually measure using $time difference over 100 cycles
        $display("=== PLL output measured ===");
        // simpler: measure 100 cycles
    end

    real t_start, t_end;
    initial begin
        #2000;
        wait (clkout0 === 1'b1);
        t_start = $time;
        repeat (100) @(posedge clkout0);
        t_end = $time;
        $display("100 cycles from %0t to %0t = %0t ns, period = %0t ns, freq = %0.3f MHz",
                 t_start, t_end, (t_end-t_start), (t_end-t_start)/100.0, 1000.0*100.0/(t_end-t_start));
        $finish;
    end

endmodule