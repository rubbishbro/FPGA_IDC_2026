`timescale 1ns/1ps

module fold_tb;

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

    integer i;
    integer errors = 0;

    initial begin
        clk = 0; rst_n = 0; frame_pulse = 0;
        q_y = 400; pix_x = 86; pix_y = 84;   // bar 14 fixed
        #20 rst_n = 1;
        #10;

        $display("frame, shift, color_idx");
        for (i = 0; i < 220; i = i + 1) begin
            if (i % 20 == 0 || i == 191 || i == 192)
                $display("%0d, %0d, %0d", i, u_fft.hue_shift, u_fft.color_idx);
            frame_pulse = 1; @(posedge clk); frame_pulse = 0; #1;
        end
        // shift should wrap 191 -> 0 (circular rotation)
        // at i=191 shift should be ~191, i=192 -> 0
        $display("after 191 frames shift=%0d, after 192 shift=%0d",
                 u_fft.hue_shift, u_fft.hue_shift);
        $display("=== ROTATION CHECK ===");
        $finish;
    end

endmodule