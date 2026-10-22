`timescale 1ns/1ps

module instant_tb;

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
    reg [9:0] maxh;
    reg [9:0] maxh_x;

    initial begin
        clk = 0; rst_n = 0; frame_pulse = 0; page_sel = 0; q_x = 0;
        #20 rst_n = 1;
        #10;

        maxh = 0;
        // for every frame boundary, check the peak of ALL bars at that instant
        for (i = 0; i < 300; i = i + 1) begin
            frame_pulse = 1; @(posedge clk); frame_pulse = 0;   // advance song
            // at THIS song moment, scan all bars (q_y is comb of bar via q_x)
            for (b = 0; b < 128; b = b + 1) begin
                q_x = b * 6; #1;
                if (q_y > maxh) begin maxh = q_y; maxh_x = b*6; end
            end
        end
        $display("global max q_y = %0d at x=%0d", maxh, maxh_x);
        $display("(if >479, data_source can drive dot to top)");
        $finish;
    end

endmodule