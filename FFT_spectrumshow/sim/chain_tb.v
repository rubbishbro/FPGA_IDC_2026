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
    wire [9:0]  wave_rd_addr;
    wire [9:0]  wave_rd_data;
    wire [39:0] curve_rd_data;
    reg  [9:0]  curve_rd_addr;

    real_audio_chain u_chain(
        .clk_core(clk_core), .rst_core_n(rst_core_n),
        .clk_pix(clk_pix), .rst_pix_n(rst_pix_n),
        .pcm_valid(pcm_valid), .pcm_data(pcm_data),
        .frame_pulse(frame_pulse),
        .rd_bar_idx(rd_bar_idx), .rd_valid(rd_valid),
        .rd_q_y(rd_q_y), .rd_q_ov(rd_q_ov),
        .wave_rd_addr(wave_rd_addr), .wave_rd_data(wave_rd_data),
        .curve_rd_addr(curve_rd_addr), .curve_rd_data(curve_rd_data)
    );
    assign wave_rd_addr = 10'd0;
    initial curve_rd_addr = 10'd0;

    always #15 clk_core = ~clk_core;   // 33.333 MHz
    always #15 clk_pix  = ~clk_pix;    // 33.333 MHz

    integer errs = 0;
    integer i;
    integer c100, c200, c300;
    integer ccur, cmax;
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

        ccur = 0;
        cmax = 0;
        for (i = 0; i < 768; i = i + 1) begin
            curve_rd_addr = i;
            @(posedge clk_pix); #1;
            if (curve_rd_data[39:30] != 0) ccur = ccur + 1;
            if (curve_rd_data[39:30] > cmax) cmax = curve_rd_data[39:30];
        end
        $display("curve nonzero=%0d maxcur=%0d", ccur, cmax);

        max_h = 0;
        c100 = 0;
        c200 = 0;
        c300 = 0;
        for (i = 0; i < 128; i = i + 1) begin
            rd_bar_idx = i; rd_valid = 1;
            @(posedge clk_pix); #1;
            if (rd_q_y > max_h) max_h = rd_q_y;
            if (rd_q_y > 100) c100 = c100 + 1;
            if (rd_q_y > 200) c200 = c200 + 1;
            if (rd_q_y > 300) c300 = c300 + 1;
        end

        if ((^curve_rd_data) === 1'bx) begin
            $display("=== CHAIN TEST FAILED (curve data X) ===");
            errs = errs + 1;
        end

        if ((^wave_rd_data) === 1'bx) begin
            $display("=== CHAIN TEST FAILED (wave data X) ===");
            errs = errs + 1;
        end

        $display("max bar height = %0d (out of 479)", max_h);
        $display("bars >100=%0d >200=%0d >300=%0d", c100, c200, c300);
        if (max_h > 0 && errs == 0)
            $display("=== CHAIN TEST PASSED (bars + wave valid) ===");
        else begin
            $display("=== CHAIN TEST FAILED (all bars 0) ===");
            errs = errs + 1;
        end
        $finish;
    end

endmodule
