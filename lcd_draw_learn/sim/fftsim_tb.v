`timescale 1ns/1ps

module fftsim_tb;

    reg         clk, rst, start;
    reg  [15:0] xn_re, xn_im;
    wire [9:0]  idx;
    wire [15:0] xk_re, xk_im;
    wire        sod, ipd, eod, busy, soud, opd, eoud;

    fft_sim u_dut(
        .idx(idx), .xk_re(xk_re), .xk_im(xk_im),
        .sod(sod), .ipd(ipd), .eod(eod), .busy(busy),
        .soud(soud), .opd(opd), .eoud(eoud),
        .xn_re(xn_re), .xn_im(xn_im), .start(start),
        .clk(clk), .rst(rst)
    );

    always #5 clk = ~clk;

    integer i;
    integer bins_out;

    initial begin
        clk = 0; rst = 1; start = 0; xn_re = 0; xn_im = 0;
        #20 rst = 0;   // high-active: rst=1 asserts, then release
        #10;

        // start
        start = 1; @(posedge clk); start = 0;
        $display("after start pulse: state=%0d busy=%0d", u_dut.state, u_dut.busy);

        // feed 1024 samples, watch state transitions
        for (i = 0; i < 1024; i = i + 1) begin
            xn_re = 16'sd1000;
            @(posedge clk);
            if (i < 5 || i == 511 || i == 1023)
                $display("feed[%0d]: state=%0d busy=%0d cnt=%0d", i, u_dut.state, u_dut.busy, u_dut.cnt);
        end
        $display("after feed: state=%0d busy=%0d cnt=%0d", u_dut.state, u_dut.busy, u_dut.cnt);

        // read 8 output bins, with generous window
        bins_out = 0;
        for (i = 0; i < 600; i = i + 1) begin
            @(posedge clk);
            if (u_dut.soud) begin
                $display("bin %0d: re=%0d state=%0d", u_dut.idx, u_dut.xk_re, u_dut.state);
                bins_out = bins_out + 1;
                if (bins_out >= 8) i = 599;
            end
        end
        $display("bins captured=%0d", bins_out);

        $display("=== FFTSIM TEST: bins streaming ===");
        $finish;
    end

endmodule