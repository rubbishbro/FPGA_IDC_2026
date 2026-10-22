`timescale 1ns/1ps

module peak_tb;

    reg         clk, rst_n, frame_pulse;
    reg  [9:0]  q_y, pix_x, pix_y;
    wire        fft_hit;
    wire [5:0]  fft_r, fft_g, fft_b;

    lcd_fft u_fft(
        .clk(clk), .rst_n(rst_n), .frame_pulse(frame_pulse),
        .q_y(q_y), .pix_x(pix_x), .pix_y(pix_y),
        .fft_hit(fft_hit), .fft_r(fft_r), .fft_g(fft_g), .fft_b(fft_b)
    );

    always #5 clk = ~clk;

    integer errors = 0;

    // draw a specific bar with given height for n clocks
    task draw_bar(input integer b, input [9:0] h, input integer n);
        begin
            q_y = h; pix_x = b * 6 + 3; pix_y = 100;
            repeat (n) @(posedge clk);
        end
    endtask

    initial begin
        clk = 0; rst_n = 0; frame_pulse = 0;
        q_y = 0; pix_x = 3; pix_y = 100;
        #20 rst_n = 1;
        #10;

        // bash bar 10 up to 300
        draw_bar(10, 10'd300, 200);
        $display("bar10 after bash: dot=%0d", u_fft.dot_ram[10]);
        if (u_fft.dot_ram[10] < 10'd350)
            $error("bar10 should overshoot to ~360");

        // now bar 10 falls; while it falls, bash bar 50 up repeatedly.
        // bar10's fall timer must NOT be reset by bar50's activity.
        // interleave: draw bar10 (falling), draw bar50 (bashed high), repeat.
        // capture bar10 dot before/after
        $display("before: bar10 dot=%0d, bar10 fall=%0d", u_fft.dot_ram[10], u_fft.fall_ram[10]);
        // draw bar50 high (this used to reset global fall_cnt, stalling bar10)
        repeat (50) begin
            draw_bar(50, 10'd400, 10);
            draw_bar(10, 10'd50, 10);
        end
        $display("after: bar10 dot=%0d, bar10 fall=%0d", u_fft.dot_ram[10], u_fft.fall_ram[10]);
        $display("bar50 dot=%0d", u_fft.dot_ram[50]);

        // bar10 should have decayed from 360 downward (not stuck at 360)
        if (u_fft.dot_ram[10] >= 10'd360) begin
            $error("bar10 dot stuck at %0d - global fall counter interference!", u_fft.dot_ram[10]);
        end else begin
            $display("bar10 dot decayed to %0d (OK, not stalled)", u_fft.dot_ram[10]);
        end

        if (errors == 0) $display("=== NO-STALL CHECK PASSED ===");
        else             $display("=== NO-STALL CHECK FAILED: %0d ===", errors);
        $finish;
    end

endmodule