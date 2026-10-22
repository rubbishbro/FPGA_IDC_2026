`timescale 1ns/1ps

module chain_tb;

    reg         clk, rst_n, samp_en;
    reg  [6:0]  rd_bar_idx;
    reg         rd_valid;
    wire [9:0]  rd_q_y, rd_q_ov;

    real_audio_chain u_chain(
        .clk(clk), .rst_n(rst_n), .samp_en(samp_en),
        .rd_bar_idx(rd_bar_idx), .rd_valid(rd_valid),
        .rd_q_y(rd_q_y), .rd_q_ov(rd_q_ov)
    );

    always #5 clk = ~clk;

    integer errs = 0;
    integer i;
    reg [9:0] max_h;

    // samp_en: every 694 clocks
    reg [15:0] div;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin div <= 0; samp_en <= 0; end
        else begin
            samp_en <= 0;
            if (div >= 693) begin div <= 0; samp_en <= 1; end
            else div <= div + 1;
        end
    end

    initial begin
        clk = 0; rst_n = 0; samp_en = 0;
        rd_bar_idx = 0; rd_valid = 0;
        #20 rst_n = 1;
        #10;

        // let the chain run for several frames (each = 1024 samp_en ≈ 710k clk)
        // wait for FFT to finish at least once: watch u_chain.sm_frame_done
        wait (u_chain.sm_frame_done == 1'b1);
        $display("=== first frame done ===");

        // scan all 128 bars, report heights
        max_h = 0;
        for (i = 0; i < 128; i = i + 1) begin
            rd_bar_idx = i; rd_valid = 1;
            @(posedge clk); #1;
            if (rd_q_y > max_h) max_h = rd_q_y;
        end
        $display("max bar height = %0d (out of 479)", max_h);
        if (max_h > 0) $display("=== CHAIN TEST PASSED (bars have height) ===");
        else begin $display("=== CHAIN TEST FAILED (all bars 0) ==="); errs = errs+1; end
        $finish;
    end

endmodule