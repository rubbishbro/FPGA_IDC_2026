module lcd_draw (
    // 33.333 MHz 像素时钟与低有效复位
    input               clk,
    input               rst_n,

    // frame_pulse：每帧一个脉冲，给颜色/光点动画用
    input               frame_pulse,

    // lcd_valid：当前像素在有效显示区
    // pix_x/pix_y：当前像素坐标
    input               lcd_valid,
    input       [9:0]   pix_x,
    input       [9:0]   pix_y,

    // page_sel：页面选择
    //   00 = 柱状图，01 = 旧波形占位，10 = 瀑布图
    input       [1:0]   page_sel,

    // ---------------- 柱状图参数 ----------------
    // q_y  ：当前柱高 0..479
    // q_ov ：当前柱子的超调目标 0..479（光点动画用）
    input       [9:0]   q_y,
    input       [9:0]   q_ov,

    // ---------------- 瀑布图读接口 ----------------
    // wf_base_row：最新历史行号
    // wf_rd_data ：当前历史单元柱高
    // wf_rd_row / wf_rd_col：要读的历史行/列
    input       [5:0]   wf_base_row,
    input       [9:0]   wf_rd_data,
    output      [5:0]   wf_rd_row,
    output      [6:0]   wf_rd_col,

    // ---------------- LCD RGB 输出 ----------------
    output      [5:0]   lcd_r,
    output      [5:0]   lcd_g,
    output      [5:0]   lcd_b
);

    // ===== sub-renderers =====
    wire        bg_hit, fft_hit, wave_hit, wf_hit;
    wire [5:0]  bg_r,  bg_g,  bg_b;
    wire [5:0]  fft_r, fft_g, fft_b;
    wire [5:0]  wave_r, wave_g, wave_b;
    wire [5:0]  wf_r, wf_g, wf_b;

    lcd_background u_bg(
        .pix_x(pix_x), .pix_y(pix_y),
        .grid_hit(bg_hit), .grid_r(bg_r), .grid_g(bg_g), .grid_b(bg_b)
    );

    lcd_fft u_fft(
        .clk(clk), .rst_n(rst_n), .frame_pulse(frame_pulse),
        .dot_en(lcd_valid && (page_sel == 2'b00)),   // FFT only on page 00
        .q_y(q_y), .q_ov(q_ov), .pix_x(pix_x), .pix_y(pix_y),
        .fft_hit(fft_hit), .fft_r(fft_r), .fft_g(fft_g), .fft_b(fft_b)
    );

    lcd_wave u_wave(
        .q_y(q_y), .pix_x(pix_x), .pix_y(pix_y),
        .wave_hit(wave_hit), .wave_r(wave_r), .wave_g(wave_g), .wave_b(wave_b)
    );

    lcd_waterfall u_wf(
        .clk(clk), .rst_n(rst_n), .lcd_valid(lcd_valid),
        .pix_x(pix_x), .pix_y(pix_y),
        .wf_base_row(wf_base_row), .wf_rd_data(wf_rd_data),
        .wf_rd_row(wf_rd_row), .wf_rd_col(wf_rd_col),
        .wf_hit(wf_hit), .wf_r(wf_r), .wf_g(wf_g), .wf_b(wf_b)
    );

    // ===== page selection: 00=FFT, 01=Wave, 10=Waterfall =====
    wire        page_hit;
    wire [5:0]  page_r, page_g, page_b;

    assign page_hit = (page_sel == 2'b00) ? fft_hit :
                      (page_sel == 2'b01) ? wave_hit : wf_hit;
    assign page_r   = (page_sel == 2'b00) ? fft_r   :
                      (page_sel == 2'b01) ? wave_r   : wf_r;
    assign page_g   = (page_sel == 2'b00) ? fft_g   :
                      (page_sel == 2'b01) ? wave_g   : wf_g;
    assign page_b   = (page_sel == 2'b00) ? fft_b   :
                      (page_sel == 2'b01) ? wave_b   : wf_b;

    // ===== priority: page content > grid > background =====
    wire [5:0] draw_r = page_hit ? page_r : bg_hit ? bg_r : 6'h00;
    wire [5:0] draw_g = page_hit ? page_g : bg_hit ? bg_g : 6'h00;
    wire [5:0] draw_b = page_hit ? page_b : bg_hit ? bg_b : 6'h00;

    assign lcd_r = lcd_valid ? draw_r : 6'b0;
    assign lcd_g = lcd_valid ? draw_g : 6'b0;
    assign lcd_b = lcd_valid ? draw_b : 6'b0;

endmodule