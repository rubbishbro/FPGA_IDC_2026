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
    //   00 = 柱状图，01 = 波形，10 = 瀑布图，11 = 设置
    input       [1:0]   page_sel,
    input       [1:0]   ui_setting_sel,
    input       [3:0]   effects,

    // ---------------- 柱状图参数 ----------------
    // q_y  ：当前柱高 0..479
    // q_ov ：当前柱子的超调目标 0..479（光点动画用）
    input       [9:0]   q_y,
    input       [9:0]   q_ov,

    // ---------------- 瀑布图读接口 ----------------
    // wf_base_row：最新历史行号
    // wf_rd_data ：当前历史单元柱高
    // wf_rd_row / wf_rd_col：要读的历史行/列
    input       [9:0]   wave_rd_data,
    output      [9:0]   wave_rd_addr,
    input       [39:0]  curve_rd_data,
    output      [9:0]   curve_rd_addr,

    // ---------------- LCD RGB 输出 ----------------
    output      [5:0]   lcd_r,
    output      [5:0]   lcd_g,
    output      [5:0]   lcd_b
);

    // ===== sub-renderers =====
    wire        bg_hit, fft_hit, wave_hit, curve_hit;
    wire [5:0]  bg_r,  bg_g,  bg_b;
    wire [5:0]  fft_r, fft_g, fft_b;
    wire [5:0]  wave_r, wave_g, wave_b;
    wire [5:0]  curve_r, curve_g, curve_b;
    wire        ui_hit;
    wire [5:0]  ui_r, ui_g, ui_b;

    lcd_background u_bg(
        .pix_x(pix_x), .pix_y(pix_y), .grid_en(effects[3]),
        .grid_hit(bg_hit), .grid_r(bg_r), .grid_g(bg_g), .grid_b(bg_b)
    );

    lcd_fft u_fft(
        .clk(clk), .rst_n(rst_n), .frame_pulse(frame_pulse),
        .dot_en(lcd_valid && (page_sel == 2'b00)),   // FFT only on page 00
        .peak_en(effects[1]), .theme(effects[2]), .smooth_en(effects[0]),
        .q_y(q_y), .q_ov(q_ov), .pix_x(pix_x), .pix_y(pix_y),
        .fft_hit(fft_hit), .fft_r(fft_r), .fft_g(fft_g), .fft_b(fft_b)
    );

    lcd_wave u_wave(
        .clk(clk), .rst_n(rst_n), .lcd_valid(lcd_valid),
        .pix_x(pix_x), .pix_y(pix_y), .theme(effects[2]),
        .wave_rd_data(wave_rd_data), .wave_rd_addr(wave_rd_addr),
        .wave_hit(wave_hit), .wave_r(wave_r), .wave_g(wave_g), .wave_b(wave_b)
    );

    lcd_curve_spectrum u_curve(
        .clk(clk), .rst_n(rst_n), .lcd_valid(lcd_valid),
        .pix_x(pix_x), .pix_y(pix_y), .theme(effects[2]),
        .curve_data(curve_rd_data), .curve_rd_addr(curve_rd_addr),
        .hit(curve_hit), .r(curve_r), .g(curve_g), .b(curve_b)
    );

    lcd_ui u_ui(
        .lcd_valid(lcd_valid),
        .pix_x(pix_x), .pix_y(pix_y),
        .page(page_sel), .setting_sel(ui_setting_sel), .effects(effects),
        .ui_hit(ui_hit), .ui_r(ui_r), .ui_g(ui_g), .ui_b(ui_b)
    );

    // ===== page selection: 00=BARS, 01=WAVE, 10=FALL, 11=SETTINGS =====
    wire        page_hit;
    wire [5:0]  page_r, page_g, page_b;

    assign page_hit = (page_sel == 2'b00) ? fft_hit :
                      (page_sel == 2'b01) ? wave_hit :
                      (page_sel == 2'b10) ? curve_hit : 1'b0;
    assign page_r   = (page_sel == 2'b00) ? fft_r   :
                      (page_sel == 2'b01) ? wave_r   :
                      (page_sel == 2'b10) ? curve_r   : 6'h00;
    assign page_g   = (page_sel == 2'b00) ? fft_g   :
                      (page_sel == 2'b01) ? wave_g   :
                      (page_sel == 2'b10) ? curve_g   : 6'h00;
    assign page_b   = (page_sel == 2'b00) ? fft_b   :
                      (page_sel == 2'b01) ? wave_b   :
                      (page_sel == 2'b10) ? curve_b   : 6'h00;

    // ===== priority: UI > page content > grid > background =====
    wire [5:0] base_r = page_hit ? page_r : bg_hit ? bg_r : 6'h00;
    wire [5:0] base_g = page_hit ? page_g : bg_hit ? bg_g : 6'h00;
    wire [5:0] base_b = page_hit ? page_b : bg_hit ? bg_b : 6'h00;
    wire [5:0] draw_r = ui_hit ? ui_r : base_r;
    wire [5:0] draw_g = ui_hit ? ui_g : base_g;
    wire [5:0] draw_b = ui_hit ? ui_b : base_b;

    assign lcd_r = lcd_valid ? draw_r : 6'b0;
    assign lcd_g = lcd_valid ? draw_g : 6'b0;
    assign lcd_b = lcd_valid ? draw_b : 6'b0;

endmodule