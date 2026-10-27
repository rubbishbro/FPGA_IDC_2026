`timescale 1ns/1ps

module debug_1024_tb;

    reg clk_core, clk_pix;
    reg rst_core_n, rst_pix_n;
    reg samp_en, frame_pulse;
    reg [6:0] rd_bar_idx;
    reg rd_valid;
    wire [9:0] rd_q_y, rd_q_ov;

    real_audio_chain u_chain(
        .clk_core(clk_core), .rst_core_n(rst_core_n),
        .clk_pix(clk_pix), .rst_pix_n(rst_pix_n),
        .samp_en(samp_en), .frame_pulse(frame_pulse),
        .rd_bar_idx(rd_bar_idx), .rd_valid(rd_valid),
        .rd_q_y(rd_q_y), .rd_q_ov(rd_q_ov)
    );

    always #15 clk_core = ~clk_core;   // 33.333 MHz
    always #15 clk_pix  = ~clk_pix;    // 33.333 MHz

    reg [15:0] div;
    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin div <= 0; samp_en <= 0; end
        else begin
            samp_en <= 0;
            if (div >= 16'd693) begin div <= 0; samp_en <= 1; end
            else div <= div + 1;
        end
    end

    reg [19:0] fcnt;
    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin fcnt <= 0; frame_pulse <= 0; end
        else begin
            frame_pulse <= 0;
            if (fcnt == 20'd635335) begin fcnt <= 0; frame_pulse <= 1; end
            else fcnt <= fcnt + 1;
        end
    end

    integer opd_cnt = 0;
    integer nonzero = 0;
    integer yvalid_cnt = 0;
    integer feed_cnt = 0;
    integer max_re = 0;
    integer max_im = 0;

    always @(posedge clk_pix) begin
        if (u_chain.opd) begin
            opd_cnt = opd_cnt + 1;
            if (u_chain.xk_re != 0 || u_chain.xk_im != 0) nonzero = nonzero + 1;
            if (u_chain.xk_re > max_re) max_re = u_chain.xk_re;
            if (u_chain.xk_im > max_im) max_im = u_chain.xk_im;
        end
        if (u_chain.u_fft_ctrl.u_fft.y_valid) yvalid_cnt = yvalid_cnt + 1;
        if (u_chain.u_fft_ctrl.xn_valid) feed_cnt = feed_cnt + 1;
    end

    initial begin
        clk_core = 0; clk_pix = 0;
        rst_core_n = 0; rst_pix_n = 0;
        samp_en = 0; frame_pulse = 0;
        rd_bar_idx = 0; rd_valid = 0;
        #40;
        rst_core_n = 1; rst_pix_n = 1;

        wait (u_chain.sm_frame_done == 1'b1);
        #100;
        $display("frame done: opd=%0d nonzero=%0d yvalid=%0d feed=%0d max_re=%0d max_im=%0d",
                 opd_cnt, nonzero, yvalid_cnt, feed_cnt, max_re, max_im);
        $display("fft: state=%0d mem0=%h yidx=%0d yvalid=%0d done=%0d",
                 u_chain.u_fft_ctrl.u_fft.state,
                 u_chain.u_fft_ctrl.u_fft.mem[0],
                 u_chain.u_fft_ctrl.u_fft.y_idx,
                 u_chain.u_fft_ctrl.u_fft.y_valid,
                 u_chain.u_fft_ctrl.u_fft.done);
        $display("ctrl: cnt=%0d xn_re=%0d windowed=%0d hann=%0d tp=%h",
                 u_chain.u_fft_ctrl.cnt,
                 $signed(u_chain.u_fft_ctrl.xn_re),
                 $signed(u_chain.u_fft_ctrl.windowed),
                 u_chain.u_fft_ctrl.hann_coeff_r,
                 u_chain.tp_rd_data);
        $finish;
    end

endmodule
