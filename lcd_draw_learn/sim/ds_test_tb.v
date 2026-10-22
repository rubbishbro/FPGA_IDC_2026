`timescale 1ns/1ps

module ds_test_tb;

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

        page_sel = 2'b10;  // wave page
        q_x = 10'd0; #1;
        $display("WAVE x=0: q_y=%0d (expect 240)", q_y);
        q_x = 10'd100; #1;
        $display("WAVE x=100: q_y=%0d", q_y);
        q_x = 10'd400; #1;
        $display("WAVE x=400: q_y=%0d", q_y);

        page_sel = 2'b01;  // lissajous
        q_x = 10'd400; #1;
        $display("LISSA x=400: q_y=%0d (expect ~440)", q_y);

        page_sel = 2'b00;  // fft
        q_x = 10'd2; #1;
        $display("FFT x=2: q_y=%0d (expect ~300)", q_y);

        $finish;
    end

endmodule