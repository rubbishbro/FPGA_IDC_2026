`timescale 1ns/1ps

module ds_new_tb;

    reg         clk, rst_n, frame_pulse;
    reg  [1:0]  page_sel;
    reg  [9:0]  q_x;
    wire [9:0]  q_y;

    integer errors = 0;

    data_source u_ds(
        .clk(clk), .rst_n(rst_n), .frame_pulse(frame_pulse),
        .page_sel(page_sel), .q_x(q_x), .q_y(q_y)
    );

    always #5 clk = ~clk;

    // check q_y is within [exp-tol, exp+tol]
    task checkq(input [9:0] x, input [9:0] exp, input [9:0] tol, input [31:0] tag);
        begin
            q_x = x; #1;
            if (q_y > exp + tol || q_y < (exp >= tol ? exp - tol : 0)) begin
                $error("[%0s] x=%0d q_y=%0d expect %0d±%0d", tag, x, q_y, exp, tol);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        clk = 0; rst_n = 0; frame_pulse = 0; page_sel = 0; q_x = 0;
        #20 rst_n = 1;
        #10;

        // WAVE page (1): two sine sum.
        // x=0: tone1 tri=0 -> y1=120; tone2 tri=0 -> y2=180; offset=-180 -> y=60
        page_sel = 1;
        checkq(10'd0,  10'd60,  10'd8,  "wave0");
        // x=64: tone1 tri=64 -> y1=180; tone2 ph=128 tri=127 -> y2=239; y12=419-240=179
        checkq(10'd64, 10'd179, 10'd8,  "wave64");
        // x=128: tone1 tri=127->y1=239; tone2 ph=256 tri=0->y2=180; offset=-1-60=-61 -> y=179
        checkq(10'd128, 10'd179, 10'd10, "wave128");

        // FFT page (0): peaks at bar12 (x=144) and bar24 (x=288)
        page_sel = 0;
        checkq(10'd144, 10'd400, 10'd10, "fft1");
        checkq(10'd288, 10'd267, 10'd10, "fft2");
        checkq(10'd400, 10'd0,   10'd5,  "fftfar");

        if (errors == 0) $display("=== DS NEW TEST PASSED ===");
        else             $display("=== DS NEW TEST FAILED: %0d ===", errors);
        $finish;
    end

endmodule