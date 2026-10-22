`timescale 1ns/1ps

module overshoot_tb;

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

    // draw bar14 with given height, report where the dot ends up
    task draw_bar(input [9:0] h, input integer n);
        begin
            q_y = h; pix_x = 86; pix_y = 84;
            repeat (n) @(posedge clk);
        end
    endtask

    initial begin
        clk = 0; rst_n = 0; frame_pulse = 0;
        q_y = 0; pix_x = 86; pix_y = 84;
        #20 rst_n = 1;
        #10;

        // bar height 116 (typical), dot should overshoot to ~139
        draw_bar(10'd116, 500);
        $display("bar=116: dot=%0d ov_c=%0d (expect ~139)", u_fft.dot_ram[14], u_fft.ov_c);
        if (u_fft.dot_ram[14] > 10'd200)
            $error("dot overshot too far: %0d for bar 116", u_fft.dot_ram[14]);

        // bar height 300: dot -> 360
        draw_bar(10'd300, 500);
        $display("bar=300: dot=%0d (expect ~360)", u_fft.dot_ram[14]);
        if (u_fft.dot_ram[14] != 10'd360)
            $error("bar 300 should overshoot to 360, got %0d", u_fft.dot_ram[14]);

        // bar height 400: dot -> 479 (clamped)
        draw_bar(10'd400, 500);
        $display("bar=400: dot=%0d (expect 479 clamped)", u_fft.dot_ram[14]);

        $display("=== OVERSHOOT CHECK DONE ===");
        $finish;
    end

endmodule