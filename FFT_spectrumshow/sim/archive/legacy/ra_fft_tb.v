`timescale 1ns/1ps

module ra_fft_tb;

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

    integer i;
    reg [9:0] max_h;

    initial begin
        clk = 0; rst_n = 0; samp_en = 0;
        rd_bar_idx = 0; rd_valid = 0;
        #20 rst_n = 1;
        #10;

        // feed samp_en pulses to capture a frame. To keep sim fast,
        // use a tight divider (e.g. 10 clk per samp) - NOT the real 694.
        // need >= 1024 samples -> >= 10240 clocks
        for (i = 0; i < 10400; i = i + 1) begin
            samp_en = (i % 10 == 0);
            @(posedge clk);
            if (i % 2000 == 0)
                $display("i=%0d cap_active=%0d cap_cnt=%0d frame_ready=%0d",
                    i, u_chain.cap_active, u_chain.cap_cnt, u_chain.frame_ready);
        end
        samp_en = 0;
        $display("after feed: cap_active=%0d cap_cnt=%0d frame_ready=%0d",
            u_chain.cap_active, u_chain.cap_cnt, u_chain.frame_ready);

        // let fft_sim + spectrum_map finish (1024 load + 512 out + 128 flush)
        repeat (5000) @(posedge clk);
        $display("final: sm.phase=%0d sm.bin_cnt=%0d sm.flush_cnt=%0d sm.frame_done=%0d",
            u_chain.u_sm.phase, u_chain.u_sm.bin_cnt, u_chain.u_sm.flush_cnt, u_chain.sm_frame_done);
        $display("dbg_frames=%0d dbg_soud=%0d", u_chain.dbg_frames, u_chain.dbg_soud);
        // check if frame_done EVER pulsed
        // (hierarchical probe: count edges via re-wait below is complex; print pong sel)
        $display("pong wr_sel=%0d rd_sel=%0d", u_chain.wr_sel, u_chain.u_pp.rd_sel);

        // scan bars 6..127 (skip dbg overlay bars 0..5)
        max_h = 0;
        for (i = 6; i < 128; i = i + 1) begin
            rd_bar_idx = i; rd_valid = 1;
            @(posedge clk); #1;
            if (rd_q_y > max_h) max_h = rd_q_y;
        end
        $display("max bar height (bar6+) = %0d", max_h);
        // probe pong block 0 contents
        $write("pong[0][0..10]=");
        for (i = 0; i < 11; i = i + 1) $write(" %0d", u_chain.u_pp.bar_ram[0][i]);
        $display("");
        $write("pong[1][0..10]=");
        for (i = 0; i < 11; i = i + 1) $write(" %0d", u_chain.u_pp.bar_ram[1][i]);
        $display("");
        // probe spectrum_map bar_max contents
        $write("sm.bar_max[0..10]=");
        for (i = 0; i < 11; i = i + 1) $write(" %0d", u_chain.u_sm.bar_max[i]);
        $display("");
        if (max_h > 0 && max_h <= 479 && u_chain.wr_sel >= 1)
            $display("=== RA_FFT TEST PASSED ===");
        else
            $display("=== RA_FFT TEST FAILED ===");
        $finish;
    end

endmodule