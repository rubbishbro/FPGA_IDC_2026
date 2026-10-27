`timescale 1ns/1ps

module maxh_tb;

    reg         clk, rst_n, frame_pulse;
    reg  [1:0]  page_sel;
    reg  [9:0]  q_x;
    wire [9:0]  q_y;

    data_source u_ds(
        .clk(clk), .rst_n(rst_n), .frame_pulse(frame_pulse),
        .page_sel(page_sel), .q_x(q_x), .q_y(q_y)
    );

    always #5 clk = ~clk;

    integer i, b;
    reg [9:0] max_h;
    reg [9:0] max_x;

    initial begin
        clk = 0; rst_n = 0; frame_pulse = 0; page_sel = 0; q_x = 0;
        #20 rst_n = 1;
        #10;

        // scan all 128 bars across many frames, find max height
        max_h = 0; max_x = 0;
        for (i = 0; i < 512; i = i + 1) begin
            // advance frame
            frame_pulse = 1; @(posedge clk); frame_pulse = 0;
            // scan bars at this moment
            for (b = 0; b < 128; b = b + 1) begin
                q_x = b * 6; #1;
                if (q_y > max_h) begin
                    max_h = q_y;
                    max_x = b * 6;
                end
            end
        end
        $display("MAX height seen = %0d at x=%0d (bar=%0d)", max_h, max_x, max_x/6);
        $display("(479 = top of screen. If max is huge, bass/note overflow)");
        $finish;
    end

endmodule