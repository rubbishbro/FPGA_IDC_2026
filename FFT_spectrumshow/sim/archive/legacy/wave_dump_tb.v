`timescale 1ns/1ps

module wave_dump_tb;

    reg         clk, rst_n, frame_pulse;
    reg  [1:0]  page_sel;
    reg  [9:0]  q_x;
    wire [9:0]  q_y;

    data_source u_ds(
        .clk(clk), .rst_n(rst_n), .frame_pulse(frame_pulse),
        .page_sel(page_sel), .q_x(q_x), .q_y(q_y)
    );

    always #5 clk = ~clk;

    integer i;
    initial begin
        clk = 0; rst_n = 0; frame_pulse = 0; page_sel = 1; q_x = 0;
        #20 rst_n = 1;
        #10;
        $display("index, q_y, y1, y2");
        for (i = 0; i < 256; i = i + 16) begin
            q_x = i; #1;
            $display("%0d, %0d, %0d, %0d", i, q_y, u_ds.y1, u_ds.y2);
        end
        $finish;
    end

endmodule