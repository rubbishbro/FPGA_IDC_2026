`timescale 1ns/1ps

module sp_tb;

    reg         clk, rst_n, frame_pulse, lcd_valid;
    reg  [9:0]  pix_x, pix_y;
    wire [9:0]  q_y, q_ov;
    wire [5:0]  lcd_r, lcd_g, lcd_b;

    spectrum_player u_sp(
        .clk(clk), .rst_n(rst_n), .frame_pulse(frame_pulse),
        .pix_x(pix_x), .q_y(q_y), .q_ov(q_ov)
    );

    lcd_draw u_draw(
        .clk(clk), .rst_n(rst_n), .frame_pulse(frame_pulse),
        .lcd_valid(lcd_valid), .pix_x(pix_x), .pix_y(pix_y),
        .page_sel(2'b00), .q_y(q_y), .q_ov(q_ov),
        .lcd_r(lcd_r), .lcd_g(lcd_g), .lcd_b(lcd_b)
    );

    always #5 clk = ~clk;

    integer errs = 0;

    task pump(input integer n);
        integer i;
        for (i = 0; i < n; i = i + 1) @(posedge clk);
    endtask

    task clockpix(input [9:0] x, input [9:0] y);
        begin
            pix_x = x; pix_y = y;
            @(posedge clk); #1;
        end
    endtask

    initial begin
        clk = 0; rst_n = 0; frame_pulse = 0; lcd_valid = 0;
        pix_x = 0; pix_y = 0;
        #20 rst_n = 1;
        pump(3);
        lcd_valid = 1;

        // frame 0, bar0 area: expect high q_y (low bins strong)
        clockpix(10'd3, 10'd400);   // bar0
        $display("frame0 bar0 q_y=%0d q_ov=%0d", q_y, q_ov);
        if (q_y < 100) begin $error("bar0 should be tall, got %0d", q_y); errs = errs+1; end
        if (q_ov < q_y) begin $error("q_ov(%0d)<q_y(%0d)", q_ov, q_y); errs = errs+1; end

        // frame 0, bar60 area: expect medium height
        clockpix(10'd360, 10'd400);  // bar60
        $display("frame0 bar60 q_y=%0d", q_y);
        if (q_y > 900) begin $error("bar60 too tall %0d", q_y); errs = errs+1; end

        // out-of-range bar (>127) -> black
        clockpix(10'd790, 10'd400);  // bar131 -> clamp 127 (may have value)
        $display("x790 q_y=%0d (right edge)", q_y);

        // advance a frame, blob should move
        frame_pulse = 1; @(posedge clk); frame_pulse = 0;
        pump(3);
        clockpix(10'd3, 10'd400);
        $display("frame1 bar0 q_y=%0d", q_y);

        if (errs == 0) $display("=== SP TEST PASSED ===");
        else           $display("=== SP TEST FAILED: %0d ===", errs);
        $finish;
    end

endmodule