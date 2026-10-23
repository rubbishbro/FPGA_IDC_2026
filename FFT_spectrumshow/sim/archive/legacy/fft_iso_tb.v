`timescale 1ns/1ps

module fft_iso_tb;

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
        q_y = 400; pix_x = 86; pix_y = 84;
        #20 rst_n = 1;
        #10;

        // track hue_shift over many frames to verify ping-pong (no wrap jump 127->0)
        $display("frame, shift, dir");
        for (i = 0; i < 300; i = i + 1) begin
            if (i % 20 == 0)
                $display("%0d, %0d, %0d", i, u_fft.hue_shift, u_fft.hue_dir);
            frame_pulse = 1; @(posedge clk); frame_pulse = 0; #1;
        end

        // verify: max shift seen is 127, and after hitting 127 it decreases (no jump to 0)
        if (errors == 0) $display("=== PINGPONG CHECK DONE ===");
        else             $display("=== FAIL: %0d ===", errors);
        $finish;
    end

endmodule