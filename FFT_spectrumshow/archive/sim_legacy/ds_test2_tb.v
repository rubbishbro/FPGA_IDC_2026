`timescale 1ns/1ps

module ds_test2_tb;

    reg         clk, rst_n, frame_pulse;
    reg  [1:0]  page_sel;
    reg  [9:0]  q_x;
    wire [9:0]  q_y;

    data_source u_ds(
        .clk(clk), .rst_n(rst_n), .frame_pulse(frame_pulse),
        .page_sel(page_sel), .q_x(q_x), .q_y(q_y)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 0; rst_n = 0; frame_pulse = 0; page_sel = 0; q_x = 0;
        #20 rst_n = 1;
        #10;

        // FFT: peak1 at bar 8 -> x=8*12=96, height should be 400
        page_sel = 0; q_x = 10'd96; #1;
        $display("FFT bar8 x=96: q_y=%0d (expect 400)", q_y);
        q_x = 10'd100; #1;
        $display("FFT bar8 x=100: q_y=%0d (expect ~350)", q_y);
        // far from peak
        q_x = 10'd200; #1;
        $display("FFT x=200: q_y=%0d (expect 0)", q_y);

        // Wave: triangle, x=0 -> 420 (bottom), x=128 -> 240+180-180=240 (mid)
        page_sel = 2; q_x = 10'd0; #1;
        $display("WAVE x=0: q_y=%0d (expect 420)", q_y);
        q_x = 10'd128; #1; $display("DEBUG t=%0d tri=%0d", u_ds.t, u_ds.tri_wave); $display("WAVE x=128: q_y=%0d (expect 240)", q_y);
        q_x = 10'd64; #1;
        $display("WAVE x=64: q_y=%0d (expect ~330)", q_y);

        page_sel = 1; q_x = 10'd0; #1; $display("LISSA x=0: q_y=%0d", q_y); q_x = 10'd64; #1; $display("LISSA x=64: q_y=%0d", q_y); q_x = 10'd128; #1; $display("LISSA x=128: q_y=%0d", q_y); $finish;
    end

endmodule