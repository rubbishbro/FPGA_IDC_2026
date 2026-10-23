`timescale 1ns/1ps

module dump_tb;

    reg         clk, rst_n, frame_pulse;
    reg  [1:0]  page_sel;
    reg  [9:0]  q_x;
    wire [9:0]  q_y, q_ov;

    data_source u_ds(
        .clk(clk), .rst_n(rst_n), .frame_pulse(frame_pulse),
        .page_sel(page_sel), .q_x(q_x), .q_y(q_y), .q_ov(q_ov)
    );

    always #5 clk = ~clk;

    integer b, f;

    initial begin
        clk = 0; rst_n = 0; frame_pulse = 0; page_sel = 0; q_x = 0;
        #20 rst_n = 1;
        #10;

        for (f = 0; f < 3; f = f + 1) begin
            frame_pulse = 1; @(posedge clk); frame_pulse = 0;
            repeat (140) @(posedge clk);
            $display("=== frame %0d ===", f);
            for (b = 0; b < 128; b = b + 1) begin
                q_x = b * 6;
                @(posedge clk); #1;
                $display("bar%0d q_y=%0d q_ov=%0d", b, q_y, q_ov);
            end
        end
        $finish;
    end

endmodule