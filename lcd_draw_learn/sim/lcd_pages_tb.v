`timescale 1ns/1ps

module lcd_pages_tb;

    reg         clk;
    reg         rst_n;
    reg         frame_pulse;
    reg         lcd_valid;
    reg  [9:0]  pix_x;
    reg  [9:0]  pix_y;
    reg  [1:0]  page_sel;
    wire [5:0]  lcd_r, lcd_g, lcd_b;
    wire [9:0]  q_y;
    wire [9:0]  q_ov;

    integer errors = 0;

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

    // set a pixel coordinate and let it propagate through the registered pipeline
    task clockpixel(input [9:0] x, input [9:0] y);
        begin
            pix_x = x; pix_y = y;
            @(posedge clk); #1;
        end
    endtask

    task checkpx(input [9:0] x, input [9:0] y, input [5:0] er, input [5:0] eg, input [5:0] eb, input [15:0] tag);
        begin
            clockpixel(x, y);
            if (lcd_r !== er || lcd_g !== eg || lcd_b !== eb) begin
                $error("[%0s] (%0d,%0d) got %0h%0h%0h exp %0h%0h%0h", tag, x, y, lcd_r, lcd_g, lcd_b, er, eg, eb);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        clk = 0; rst_n = 0; frame_pulse = 0; lcd_valid = 0;
        pix_x = 0; pix_y = 0; page_sel = 0;
        #20 rst_n = 1;
        #10;

        // ===== populate the frame-precomputed bar RAM (131+ clocks) =====
        frame_pulse = 1; @(posedge clk); frame_pulse = 0;
        repeat (160) @(posedge clk);   // let the 128-bar recalculation finish
        lcd_valid = 1;

        // ===== Page 0 (FFT): bar14 should have a height now =====
        clockpixel(10'd86, 10'd470);
        $display("bar14 q_y=%0d q_ov=%0d", q_y, q_ov);
        if (q_ov < q_y) begin
            $error("q_ov (%0d) should be >= q_y (%0d)", q_ov, q_y);
            errors = errors + 1;
        end
        if (q_y == 10'd0) begin
            $error("bar14 should have a height, got 0");
            errors = errors + 1;
        end

        // ===== Page 1 (Wave): two-tone sum, stable values =====
        page_sel = 1; @(posedge clk); #1;
        checkpx(10'd0, 10'd60, 6'h3F, 6'h3F, 6'h00, "wave0");
        checkpx(10'd64, 10'd179, 6'h3F, 6'h3F, 6'h00, "wave64");
        // off-point away from border/grid
        checkpx(10'd105, 10'd100, 6'h00, 6'h00, 6'h00, "wavebg");

        if (errors == 0) $display("=== PAGES TEST PASSED ===");
        else             $display("=== PAGES TEST FAILED: %0d mismatch(es) ===", errors);
        $finish;
    end

endmodule