`timescale 1ns/1ps

module frame_tb;

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

    integer x, y, f, i;

    // scan one full frame (800 x 480 pixels), pix_clk each
    task scanframe;
        begin
            for (y = 0; y < 480; y = y + 1) begin
                for (x = 0; x < 800; x = x + 1) begin
                    pix_x = x; pix_y = y;
                    @(posedge clk);
                end
            end
        end
    endtask

    initial begin
        clk = 0; rst_n = 0; frame_pulse = 0; lcd_valid = 0;
        pix_x = 0; pix_y = 0; page_sel = 0;
        #20 rst_n = 1;
        #10;
        lcd_valid = 1;

        // run several full frames; every 4 frames fire frame_pulse (song advances)
        for (f = 0; f < 40; f = f + 1) begin
            scanframe;
            if (f % 4 == 0) begin
                frame_pulse = 1; @(posedge clk); frame_pulse = 0;
                repeat (140) @(posedge clk);   // let bar RAM recalc
            end
            // every 8 frames, dump bar_h_ram and dot_ram for bars 120..127
            if (f % 8 == 0) begin
                $write("frame%0d barh[120..127]:", f);
                for (i = 120; i < 128; i = i + 1)
                    $write(" %0d", u_ds.bar_h_ram[i]);
                $write("   dots[120..127]:");
                for (i = 120; i < 128; i = i + 1)
                    $write(" %0d", u_draw.u_fft.dot_ram[i]);
                $display("");
            end
        end
        $finish;
    end

endmodule