`timescale 1ns/1ps

module dot_tb;

    reg         clk, rst_n, frame_pulse, dot_en;
    reg  [9:0]  q_y, q_ov, pix_x, pix_y;
    wire        fft_hit;
    wire [5:0]  fft_r, fft_g, fft_b;

    lcd_fft u_fft(
        .clk(clk), .rst_n(rst_n), .frame_pulse(frame_pulse),
        .dot_en(dot_en), .q_y(q_y), .q_ov(q_ov), .pix_x(pix_x), .pix_y(pix_y),
        .fft_hit(fft_hit), .fft_r(fft_r), .fft_g(fft_g), .fft_b(fft_b)
    );

    always #5 clk = ~clk;

    integer errs = 0;
    integer k;

    task pump(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) @(posedge clk);
        end
    endtask

    task checkdot(input integer bar, input integer exp_low, input integer exp_high, input [15:0] tag);
        integer d;
        begin
            // read dot for the given bar by scanning its column
            pix_x = bar * 6; pix_y = 0; pump(2);   // q_y lags 1 -> align
            d = u_fft.dot_ram[bar];
            if (d < exp_low || d > exp_high) begin
                $error("[%0s] bar%0d dot=%0d expected %0d..%0d", tag, bar, d, exp_low, exp_high);
                errs = errs + 1;
            end else begin
                $display("[%0s] bar%0d dot=%0d OK (range %0d..%0d)", tag, bar, d, exp_low, exp_high);
            end
        end
    endtask

    initial begin
        clk = 0; rst_n = 0; frame_pulse = 0; dot_en = 0;
        q_y = 0; q_ov = 0; pix_x = 0; pix_y = 0;
        #20 rst_n = 1;
        pump(3);
        dot_en = 1;

        // Scenario: bar rises fast from 0 -> 100 (overshoot should bash up to q_ov=120)
        pix_x = 3 * 6;                  // scan bar 3's column so dot logic targets bar 3
        pix_y = 0;
        pump(3);                        // align pxx lag
        q_y = 10'd100; q_ov = 10'd120;  // dot starts 0, 100 > 0+12 -> bash to 120
        pump(3);
        checkdot(3, 115, 125, "fastRise");   // expect ~120

        // Now bar stays at 100: dot 120 > q_y 100 -> slowly falls (60 clocks/px).
        // After enough pumps it should be back near 100 (rest on bar).
        pump(400);
        checkdot(3, 95, 121, "settle");      // 120->100 needs 20px * 60 = 1200 clk; 400 clk ~ 6px

        // Slow rise: bar 100 -> 108 (< +12). Dot was ~100-110.
        // With dead-zone removed: dot does NOT get dragged to 108.
        // It either stays > q_y (falling) or == q_y. It must NOT snap up to 108 exactly
        // and must still be able to bash when a BIG jump comes.
        q_y = 10'd108; q_ov = 10'd130;
        pump(200);
        checkdot(3, 100, 120, "slowRise");   // dot should be near q_y area, not glued at 130

        // BIG jump after settle: 108 -> 200 (>+12). Should bash up to q_ov=240.
        pump(2000);                          // let it settle near 108
        q_y = 10'd200; q_ov = 10'd240;
        pump(3);
        checkdot(3, 230, 245, "bigJump");    // expect ~240 (overshoot fires)

        if (errs == 0) $display("=== DOT TEST PASSED ===");
        else           $display("=== DOT TEST FAILED: %0d ===", errs);
        $finish;
    end

endmodule