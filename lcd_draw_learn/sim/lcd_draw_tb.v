`timescale 1ns/1ps

module lcd_draw_tb;

    reg         clk;
    reg         rst_n;
    reg         frame_pulse;
    reg         lcd_valid;
    reg  [9:0]  pix_x;
    reg  [9:0]  pix_y;
    wire [5:0]  lcd_r, lcd_g, lcd_b;

    // also test the timing generator
    wire        lcd_en, fp_out;
    wire [9:0]  px, py;
    reg         pix_clk;

    integer errors = 0;

    lcd_draw u_draw(
        .clk(clk), .rst_n(rst_n), .frame_pulse(frame_pulse),
        .lcd_valid(lcd_valid), .pix_x(pix_x), .pix_y(pix_y),
        .lcd_r(lcd_r), .lcd_g(lcd_g), .lcd_b(lcd_b)
    );

    lcd_timing u_timing(
        .lcd_clk(pix_clk), .rst_n(rst_n),
        .lcd_en(lcd_en), .frame_pulse(fp_out),
        .pix_x(px), .pix_y(py)
    );

    initial begin
        clk = 0; pix_clk = 0; rst_n = 0;
        frame_pulse = 0; lcd_valid = 0; pix_x = 0; pix_y = 0;
        #20 rst_n = 1;
    end

    always #5 clk = ~clk;      // 100MHz test clk for draw
    always #5 pix_clk = ~pix_clk; // 10MHz-ish pixel clk

    // ---------- lcd_draw unit tests ----------
    task check_pixel(input [9:0] x, input [9:0] y, input [5:0] er, input [5:0] eg, input [5:0] eb, input [8*8:0] tag);
        begin
            pix_x = x; pix_y = y; lcd_valid = 1;
            #1;
            if (lcd_r !== er || lcd_g !== eg || lcd_b !== eb) begin
                $error("[%0s] (%0d,%0d) got %0h%0h%0h expected %0h%0h%0h", tag, x, y, lcd_r, lcd_g, lcd_b, er, eg, eb);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        #30;
        // border pixel -> white
        check_pixel(0, 240, 6'h3F, 6'h3F, 6'h3F, "border-left");
        check_pixel(799, 240, 6'h3F, 6'h3F, 6'h3F, "border-right");
        check_pixel(400, 0, 6'h3F, 6'h3F, 6'h3F, "border-top");
        check_pixel(400, 479, 6'h3F, 6'h3F, 6'h3F, "border-bottom");
        // grid line -> dim grey
        check_pixel(32, 240, 6'h08, 6'h08, 6'h08, "grid-v");
        check_pixel(400, 32, 6'h08, 6'h08, 6'h08, "grid-h");
        // background -> black
        check_pixel(100, 100, 6'h00, 6'h00, 6'h00, "bg");
        // moving square initial at x=0, y 96..127 -> green
        check_pixel(0, 100, 6'h00, 6'h3F, 6'h00, "square");
        check_pixel(31, 110, 6'h00, 6'h3F, 6'h00, "square-edge");
        check_pixel(32, 110, 6'h08, 6'h08, 6'h08, "square-out");
        // invalid region -> black
        pix_x = 0; pix_y = 0; lcd_valid = 0; #1;
        if (lcd_r !== 0 || lcd_g !== 0 || lcd_b !== 0) begin
            $error("[invalid] got %0h%0h%0h expected black", lcd_r, lcd_g, lcd_b);
            errors = errors + 1;
        end

        if (errors == 0) $display("=== TEST PASSED ===");
        else             $display("=== TEST FAILED: %0d mismatch(es) ===", errors);
        $finish;
    end

    // ---------- lcd_timing sanity checks ----------
    integer h_cnt, v_cnt;
    reg      prev_fp;
    initial begin
        prev_fp = 0;
        forever begin
            @(posedge pix_clk);
            // count how many frame pulses in 60000 pixclk (~50 frames at 1192*533 per frame)
        end
    end

    initial begin
        // wait a bit, then count frames over a known window
        #30000;
        // we just check frame_pulse happens: monitor count over 2 full frames
        // full frame = 1192 * 533 = 635,336 pixclks -> too long for sim, check partial:
        // instead verify lcd_en toggling and frame_pulse existence over 20000 clks
        v_cnt = 0;
        repeat (20000) begin
            @(posedge pix_clk);
            if (fp_out) v_cnt = v_cnt + 1;
        end
        if (v_cnt > 0) $display("frame_pulse seen %0d times in window", v_cnt);
        else begin
            $error("no frame_pulse seen");
            errors = errors + 1;
        end
        // repeat the pass/fail print so timing issues also count
        if (errors == 0) $display("=== TIMING TEST PASSED ===");
        else             $display("=== TIMING TEST FAILED ===");
        $finish;
    end

endmodule