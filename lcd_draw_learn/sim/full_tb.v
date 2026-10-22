`timescale 1ns/1ps

module full_tb;

    reg         clk, rst_n, frame_pulse, lcd_valid;
    reg  [1:0]  page_sel;
    reg  [9:0]  pix_x, pix_y;
    wire [9:0]  q_y;
    wire [5:0]  lcd_r, lcd_g, lcd_b;

    data_source u_ds(
        .clk(clk), .rst_n(rst_n), .frame_pulse(frame_pulse),
        .page_sel(page_sel), .q_x(pix_x), .q_y(q_y)
    );

    lcd_draw u_draw(
        .clk(clk), .rst_n(rst_n), .frame_pulse(frame_pulse),
        .lcd_valid(lcd_valid), .pix_x(pix_x), .pix_y(pix_y),
        .page_sel(page_sel), .q_y(q_y),
        .lcd_r(lcd_r), .lcd_g(lcd_g), .lcd_b(lcd_b)
    );

    always #5 clk = ~clk;

    integer i, b, y;
    reg [9:0] max_dot;

    initial begin
        clk = 0; rst_n = 0; frame_pulse = 0; lcd_valid = 0;
        page_sel = 0; pix_x = 0; pix_y = 0;
        #20 rst_n = 1;
        #10;
        lcd_valid = 1;

        // run many frames, sweeping the raster (pix_x 0..799, pix_y 0..479)
        // and track the max dot_ram value across all bars
        max_dot = 0;
        for (i = 0; i < 20; i = i + 1) begin   // 20 frames
            // sweep one frame: pix_x 0..799 in steps (representative)
            for (b = 0; b < 800; b = b + 1) begin
                pix_x = b;
                pix_y = 100;
                #1;
                // check all bars' dot values periodically
                if (b % 64 == 0) begin
                    // sample bar14 dot
                    if (u_draw.u_fft.dot_ram[14] > max_dot) max_dot = u_draw.u_fft.dot_ram[14];
                    if (u_draw.u_fft.dot_ram[40] > max_dot) max_dot = u_draw.u_fft.dot_ram[40];
                end
            end
            // frame pulse
            frame_pulse = 1; @(posedge clk); frame_pulse = 0;
        end
        $display("MAX dot_ram value = %0d (should be <= ~139 if overshoot correct)", max_dot);
        $finish;
    end

endmodule