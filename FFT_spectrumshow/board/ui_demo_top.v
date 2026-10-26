module ui_demo_top #(
    parameter       SWEEP_MODE = 1'b0
) (
    input           clk,
    input           rst_n,
    input           key0,
    input           key1,
    output          lcd_clk,
    output          lcd_en,
    output  [5:0]   lcd_r,
    output  [5:0]   lcd_g,
    output  [5:0]   lcd_b
);

    import ui_pkg::*;

    wire        pix_clk;
    wire        locked;
    wire        lcd_en_w;
    wire        frame_pulse;
    wire [9:0]  pix_x;
    wire [9:0]  pix_y;

    wire        ev_valid;
    wire [2:0]  ev;
    wire        ev0_valid;
    wire [2:0]  ev0;
    wire        ev1_valid;
    wire [2:0]  ev1;
    wire [1:0]  page;
    wire [1:0]  setting_sel;
    wire [3:0]  effects;

    wire [9:0]  q_y;
    wire [9:0]  q_ov;
    wire [39:0] curve_rd_data;
    wire [9:0]  curve_rd_addr;
    wire [9:0]  wave_rd_addr;
    wire [9:0]  wave_rd_data;
    wire [5:0]  lcd_r_w;
    wire [5:0]  lcd_g_w;
    wire [5:0]  lcd_b_w;

    wire        pcm_valid_w;
    wire [23:0] pcm_data_w;
    wire        clk_wr_w;
    wire        rst_wr_n_w;
    wire        pcm_ready_w;

    Gowin_PLL Gowin_PLL_inst (
        .clkout0 (pix_clk),
        .clkin   (clk),
        .lock    (locked)
    );

    wire rst_sys_n = rst_n & locked;

    reg [2:0] rst_sync;
    always @(posedge pix_clk or negedge rst_sys_n) begin
        if (!rst_sys_n)
            rst_sync <= 3'b000;
        else
            rst_sync <= {rst_sync[1:0], 1'b1};
    end
    wire rst_pix_n = rst_sync[2];

    assign lcd_clk = pix_clk;

    lcd_timing u_timing (
        .lcd_clk     (pix_clk),
        .rst_n       (rst_pix_n),
        .lcd_en      (lcd_en_w),
        .frame_pulse (frame_pulse),
        .pix_x       (pix_x),
        .pix_y       (pix_y)
    );

    assign lcd_en = lcd_en_w;

    key_ui_event #(
        .DEBOUNCE_CNT (660_000),
        .LONG_CNT     (26_666_667),
        .SHORT_EVENT  (UI_EV_NEXT),
        .LONG_EVENT   (UI_EV_OK)
    ) u_key0 (
        .clk      (pix_clk),
        .rst_n    (rst_pix_n),
        .key_in   (key0),
        .ev_valid (ev0_valid),
        .ev       (ev0)
    );

    key_ui_event #(
        .DEBOUNCE_CNT (660_000),
        .LONG_CNT     (26_666_667),
        .SHORT_EVENT  (UI_EV_PREV),
        .LONG_EVENT   (UI_EV_BACK)
    ) u_key1 (
        .clk      (pix_clk),
        .rst_n    (rst_pix_n),
        .key_in   (key1),
        .ev_valid (ev1_valid),
        .ev       (ev1)
    );

    assign ev_valid = ev0_valid | ev1_valid;
    assign ev       = ev0_valid ? ev0 : ev1;

    ui_ctrl u_ctrl (
        .clk         (pix_clk),
        .rst_n       (rst_pix_n),
        .ev_valid    (ev_valid),
        .ev          (ev),
        .page        (page),
        .setting_sel (setting_sel),
        .effects     (effects)
    );

    reg [15:0] div48k;
    reg        samp_en;
    always @(posedge pix_clk or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            div48k  <= 16'd0;
            samp_en <= 1'b0;
        end
        else begin
            samp_en <= 1'b0;
            if (div48k >= 16'd693) begin
                div48k  <= 16'd0;
                samp_en <= 1'b1;
            end
            else begin
                div48k <= div48k + 16'd1;
            end
        end
    end

    logic [15:0] sine_rom [0:255];
    initial $readmemh("sine256.mem", sine_rom);

    generate
        if (SWEEP_MODE) begin : g_sweep
            // Separate 100 MHz PLL for the PCM source domain.
            wire src_clk;
            wire locked_src;

            Gowin_PLL_SRC Gowin_PLL_SRC_inst (
                .clkout0 (src_clk),
                .clkin   (clk),
                .lock    (locked_src)
            );

            wire rst_sys_src_n = rst_n & locked_src;
            reg [2:0] rst_src_sync;

            always @(posedge src_clk or negedge rst_sys_src_n) begin
                if (!rst_sys_src_n)
                    rst_src_sync <= 3'b000;
                else
                    rst_src_sync <= {rst_src_sync[1:0], 1'b1};
            end

            wire rst_src_n = rst_src_sync[2];

            // 48 kHz average sample tick in the 100 MHz source domain.
            reg [31:0] acc48k;
            reg        samp_en_src;

            always @(posedge src_clk or negedge rst_src_n) begin
                if (!rst_src_n) begin
                    acc48k     <= 32'd0;
                    samp_en_src <= 1'b0;
                end
                else if (acc48k + 32'd48000 >= 32'd100_000_000) begin
                    acc48k     <= acc48k + 32'd48000 - 32'd100_000_000;
                    samp_en_src <= 1'b1;
                end
                else begin
                    acc48k     <= acc48k + 32'd48000;
                    samp_en_src <= 1'b0;
                end
            end

            wire [7:0] sweep_idx;

            sweep_source u_sweep (
                .clk        (src_clk),
                .rst_n      (rst_src_n),
                .samp_en    (samp_en_src),
                .phase_idx  (sweep_idx),
                .phase      (),
                .freq_inc   (),
                .sweep_done ()
            );

            reg [23:0] pcm_data_src;
            reg        pcm_valid_src;

            always @(posedge src_clk or negedge rst_src_n) begin
                if (!rst_src_n) begin
                    pcm_data_src  <= 24'd0;
                    pcm_valid_src <= 1'b0;
                end
                else begin
                    pcm_valid_src <= samp_en_src;
                    if (samp_en_src)
                        pcm_data_src <= {sine_rom[sweep_idx], 8'b0};
                end
            end

            assign clk_wr_w    = src_clk;
            assign rst_wr_n_w  = rst_src_n;
            assign pcm_valid_w = pcm_valid_src;
            assign pcm_data_w  = pcm_data_src;
        end
        else begin : g_three_tone
            reg [31:0] phase1, phase2, phase3;

            always @(posedge pix_clk or negedge rst_pix_n) begin
                if (!rst_pix_n) begin
                    phase1 <= 32'd0;
                    phase2 <= 32'd0;
                    phase3 <= 32'd0;
                end
                else if (samp_en) begin
                    phase1 <= phase1 + 32'd39370533;
                    phase2 <= phase2 + 32'd78741066;
                    phase3 <= phase3 + 32'd118111599;
                end
            end

            wire signed [15:0] s1 = sine_rom[phase1[31:24]];
            wire signed [15:0] s2 = sine_rom[phase2[31:24]];
            wire signed [15:0] s3 = sine_rom[phase3[31:24]];
            wire signed [17:0] mix = s1 + (s2 >>> 1) + (s3 >>> 2);

            assign clk_wr_w    = pix_clk;
            assign rst_wr_n_w  = rst_pix_n;
            assign pcm_valid_w = samp_en;
            assign pcm_data_w  = {mix, 6'b0};
        end
    endgenerate

    reg [2:0] xmod_d;
    reg [6:0] bar_idx_disp_r;
    always @(posedge pix_clk or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            xmod_d         <= 3'd0;
            bar_idx_disp_r <= 7'd0;
        end
        else if (pix_x == 10'd0) begin
            xmod_d         <= 3'd0;
            bar_idx_disp_r <= 7'd0;
        end
        else if (xmod_d == 3'd5) begin
            xmod_d <= 3'd0;
            if (bar_idx_disp_r < 7'd127)
                bar_idx_disp_r <= bar_idx_disp_r + 1'b1;
        end
        else begin
            xmod_d <= xmod_d + 1'b1;
        end
    end

    wire [6:0] bar_idx_disp = bar_idx_disp_r;
    wire       rd_valid     = (pix_x < 10'd768);

    real_audio_chain u_chain (
        .clk_core    (pix_clk),
        .rst_core_n  (rst_pix_n),
        .clk_pix     (pix_clk),
        .rst_pix_n   (rst_pix_n),
        .clk_wr      (clk_wr_w),
        .rst_wr_n    (rst_wr_n_w),
        .pcm_valid   (pcm_valid_w),
        .pcm_data    (pcm_data_w),
        .pcm_ready   (pcm_ready_w),
        .frame_pulse (frame_pulse),
        .rd_bar_idx  (bar_idx_disp),
        .rd_valid    (rd_valid),
        .rd_q_y      (q_y),
        .rd_q_ov     (q_ov),
        .curve_rd_addr(curve_rd_addr),
        .curve_rd_data(curve_rd_data),
        .wave_rd_addr(wave_rd_addr),
        .wave_rd_data(wave_rd_data)
    );

    lcd_draw u_draw (
        .clk             (pix_clk),
        .rst_n           (rst_pix_n),
        .frame_pulse     (frame_pulse),
        .lcd_valid       (lcd_en_w),
        .pix_x           (pix_x),
        .pix_y           (pix_y),
        .page_sel        (page),
        .ui_setting_sel  (setting_sel),
        .effects         (effects),
        .q_y             (q_y),
        .q_ov            (q_ov),
        .curve_rd_data   (curve_rd_data),
        .curve_rd_addr   (curve_rd_addr),
        .wave_rd_data    (wave_rd_data),
        .wave_rd_addr    (wave_rd_addr),
        .lcd_r           (lcd_r_w),
        .lcd_g           (lcd_g_w),
        .lcd_b           (lcd_b_w)
    );

    reg [5:0] lcd_r_r, lcd_g_r, lcd_b_r;
    always @(posedge pix_clk or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            lcd_r_r <= 6'd0;
            lcd_g_r <= 6'd0;
            lcd_b_r <= 6'd0;
        end
        else begin
            lcd_r_r <= lcd_r_w;
            lcd_g_r <= lcd_g_w;
            lcd_b_r <= lcd_b_w;
        end
    end

    assign lcd_r = lcd_r_r;
    assign lcd_g = lcd_g_r;
    assign lcd_b = lcd_b_r;

endmodule
