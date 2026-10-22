`timescale 1ns/1ps

module trace_tb;

    reg         clk, rst_n, frame_pulse, lcd_valid;
    reg  [1:0]  page_sel;
    reg  [9:0]  pix_x, pix_y;
    wire [9:0]  q_y, q_ov;
    wire [5:0]  lcd_r, lcd_g, lcd_b;

    data_source u_ds(
        .clk(clk), .rst_n(rst_n), .frame_pulse(frame_pulse),
        .page_sel(page_sel), .q_x(pix_x), .q_y(q_y), .q_ov(q_ov)
    );

    lcd_draw u_draw(
        .clk(clk), .rst_n(rst_n), .frame_pulse(frame_pulse),
        .lcd_valid(lcd_valid), .pix_x(pix_x), .pix_y(pix_y),
        .page_sel(page_sel), .q_y(q_y), .q_ov(q_ov),
        .lcd_r(lcd_r), .lcd_g(lcd_g), .lcd_b(lcd_b)
    );

    always #5 clk = ~clk;

    integer x, y;

    initial begin
        clk = 0; rst_n = 0; frame_pulse = 0; lcd_valid = 0;
        pix_x = 0; pix_y = 0; page_sel = 0;
        #20 rst_n = 1;
        #10;
        lcd_valid = 1;

        // scan bar 124..128 region carefully, print bar_idx/q_y/q_ov
        for (y = 0; y < 480; y = y + 1) begin
            for (x = 740; x < 800; x = x + 1) begin
                pix_x = x; pix_y = y;
                @(posedge clk); #1;
                if (x >= 740 && x < 746)
                    $display("x=%0d bar_idx=%0d q_y=%0d q_ov=%0d dot125=%0d dot126=%0d dot127=%0d",
                        x, u_draw.u_fft.bar_idx, q_y, q_ov,
                        u_draw.u_fft.dot_ram[125], u_draw.u_fft.dot_ram[126], u_draw.u_fft.dot_ram[127]);
            end
            if (y == 2) $finish;
        end
        $finish;
    end

endmodule