`timescale 1ns/1ps

module chain_tb;

    reg         clk_core, clk_pix;
    reg         rst_core_n, rst_pix_n;
    reg         samp_en;
    reg         pcm_valid;
    reg  [23:0] pcm_data;
    reg         frame_pulse;
    reg  [6:0]  rd_bar_idx;
    reg         rd_valid;
    wire [9:0]  rd_q_y, rd_q_ov;
    wire [5:0]  wf_base_row;
    wire [5:0]  wf_rd_row;
    wire [6:0]  wf_rd_col;
    wire [9:0]  wf_rd_data;

    real_audio_chain u_chain(
        .clk_core(clk_core), .rst_core_n(rst_core_n),
        .clk_pix(clk_pix), .rst_pix_n(rst_pix_n),
        .pcm_valid(pcm_valid), .pcm_data(pcm_data),
        .frame_pulse(frame_pulse),
        .rd_bar_idx(rd_bar_idx), .rd_valid(rd_valid),
        .rd_q_y(rd_q_y), .rd_q_ov(rd_q_ov),
        .wf_base_row(wf_base_row),
        .wf_rd_row(wf_rd_row), .wf_rd_col(wf_rd_col), .wf_rd_data(wf_rd_data)
    );

    always #15 clk_core = ~clk_core;   // 33.333 MHz
    always #15 clk_pix  = ~clk_pix;    // 33.333 MHz

    integer errs = 0;
    integer i;
    reg [9:0] max_h;

    // 48k tick in the pixel domain: 33.333 MHz / 694 ~= 48.03 kHz
    reg [15:0] div;
    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin div <= 0; samp_en <= 0; end
        else begin
            samp_en <= 0;
            if (div >= 16'd693) begin div <= 0; samp_en <= 1; end
            else div <= div + 1;
        end
    end


    // 仿真用音频 ROM：只给 testbench 提供 PCM，不参与综合。
    reg [15:0] audio_mem [0:287999];
    reg [18:0] rom_addr;
    initial $readmemh("ode_to_joy.mem", audio_mem);

    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            rom_addr  <= 0;
            pcm_valid <= 1'b0;
            pcm_data  <= 24'd0;
        end
        else begin
            pcm_valid <= samp_en;
            if (samp_en) begin
                pcm_data <= {audio_mem[rom_addr], 8'b0};
                rom_addr <= (rom_addr == 19'd287999) ? 19'd0 : rom_addr + 1'b1;
            end
        end
    end    // Pixel frame pulse: 1192 * 533 pix clocks.
    reg [19:0] fcnt;
    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            fcnt <= 0;
            frame_pulse <= 0;
        end
        else begin
            frame_pulse <= 0;
            if (fcnt == 20'd635335) begin
                fcnt <= 0;
                frame_pulse <= 1;
            end
            else fcnt <= fcnt + 1;
        end
    end

    initial begin
        clk_core = 0; clk_pix = 0;
        rst_core_n = 0; rst_pix_n = 0;
        samp_en = 0; frame_pulse = 0;
        rd_bar_idx = 0; rd_valid = 0;
        #40;
        rst_core_n = 1;
        rst_pix_n  = 1;

        wait (u_chain.sm_frame_done == 1'b1);
        $display("=== first frame done ===");

        // Wait for the frame buffer to publish into the pixel domain.
        wait (frame_pulse == 1'b1);
        @(posedge clk_pix); #1;

        max_h = 0;
        for (i = 0; i < 128; i = i + 1) begin
            rd_bar_idx = i; rd_valid = 1;
            @(posedge clk_pix); #1;
            if (rd_q_y > max_h) max_h = rd_q_y;
        end

        $display("max bar height = %0d (out of 479)", max_h);
        if (max_h > 0)
            $display("=== CHAIN TEST PASSED (bars have height) ===");
        else begin
            $display("=== CHAIN TEST FAILED (all bars 0) ===");
            errs = errs + 1;
        end
        $finish;
    end

endmodule
