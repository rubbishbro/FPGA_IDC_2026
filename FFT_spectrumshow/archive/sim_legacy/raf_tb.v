`timescale 1ns/1ps

module raf_tb;

    reg         clk, rst_n;
    reg         samp_en;
    wire [15:0] xk_re, xk_im;
    wire [9:0]  bin_idx;
    wire        bin_valid, fft_busy, fft_done;

    real_audio_fft u_dut(
        .clk(clk), .rst_n(rst_n), .samp_en(samp_en),
        .xk_re(xk_re), .xk_im(xk_im), .bin_idx(bin_idx),
        .bin_valid(bin_valid), .fft_busy(fft_busy), .fft_done(fft_done)
    );

    always #5 clk = ~clk;

    integer errs = 0;
    integer cnt;
    reg [15:0] max_bin_re;
    reg [9:0]  max_bin_idx;

    // samp_en divider: 48k from 33.33M -> ~694 clocks
    reg [15:0] div;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin div <= 16'd0; samp_en <= 1'b0; end
        else begin
            samp_en <= 1'b0;
            if (div >= 16'd693) begin
                div <= 16'd0;
                samp_en <= 1'b1;
            end
            else div <= div + 16'd1;
        end
    end

    initial begin
        clk = 0; rst_n = 0;
        #20 rst_n = 1;
        #10;

        // let playback capture run, wait for first FFT output
        // 1024 samples * 694 clk ≈ 710k clk + FFT time
        wait (fft_done) begin
            $display("=== first FFT done ===");
        end
        // now collect the first 512 bins, find max
        max_bin_re = 0; max_bin_idx = 0; cnt = 0;
        while (cnt < 512) begin
            @(posedge clk);
            if (u_dut.out_valid) begin
                cnt = cnt + 1;
                if (u_dut.out_xk_re > max_bin_re) begin
                    max_bin_re = u_dut.out_xk_re;
                    max_bin_idx = u_dut.out_bin;
                end
                if (cnt % 64 == 0)
                    $display("bin %0d re=%0d", u_dut.out_bin, u_dut.out_xk_re);
            end
        end
        $display("=== max bin=%0d re=%0d (synth.wav, expect strong low-mid bins) ===", max_bin_idx, max_bin_re);
        if (max_bin_re > 0) $display("=== RAF TEST PASSED (FFT produces output) ===");
        else begin $display("=== RAF TEST FAILED ==="); errs = errs + 1; end
        $finish;
    end

endmodule