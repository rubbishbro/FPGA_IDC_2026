module lcd_draw (
    input               clk,
    input               rst_n,
    input               frame_pulse,
    input               lcd_valid,
    input       [9:0]   pix_x,
    input       [9:0]   pix_y,
    input       [1:0]   page_sel,
    input       [9:0]   q_y,        // from data_source
    input       [9:0]   q_ov,       // overshoot target from data_source

    output      [5:0]   lcd_r,
    output      [5:0]   lcd_g,
    output      [5:0]   lcd_b
);

    // ===== sub-renderers =====
    wire        bg_hit, fft_hit, wave_hit;
    wire [5:0]  bg_r,  bg_g,  bg_b;
    wire [5:0]  fft_r, fft_g, fft_b;
    wire [5:0]  wave_r, wave_g, wave_b;

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

    // ===== page selection: 00=FFT, 01=Wave =====
    wire        page_hit;
    wire [5:0]  page_r, page_g, page_b;

    assign page_hit = (page_sel == 2'b00) ? fft_hit : wave_hit;
    assign page_r   = (page_sel == 2'b00) ? fft_r   : wave_r;
    assign page_g   = (page_sel == 2'b00) ? fft_g   : wave_g;
    assign page_b   = (page_sel == 2'b00) ? fft_b   : wave_b;

    // ===== priority: page content > grid > background =====
    wire [5:0] draw_r = page_hit ? page_r : bg_hit ? bg_r : 6'h00;
    wire [5:0] draw_g = page_hit ? page_g : bg_hit ? bg_g : 6'h00;
    wire [5:0] draw_b = page_hit ? page_b : bg_hit ? bg_b : 6'h00;

    assign lcd_r = lcd_valid ? draw_r : 6'b0;
    assign lcd_g = lcd_valid ? draw_g : 6'b0;
    assign lcd_b = lcd_valid ? draw_b : 6'b0;

endmodule