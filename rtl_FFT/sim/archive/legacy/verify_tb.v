`timescale 1ns/1ps

module verify_tb;

    reg         clk, rst_n, frame_pulse;
    reg  [1:0]  page_sel;
    reg  [9:0]  q_x;
    wire [9:0]  q_y, q_ov;

    data_source u_ds(
        .clk(clk), .rst_n(rst_n), .frame_pulse(frame_pulse),
        .page_sel(page_sel), .q_x(q_x), .q_y(q_y), .q_ov(q_ov)
    );

    always #5 clk = ~clk;

    integer b;

    initial begin
        clk = 0; rst_n = 0; frame_pulse = 0; page_sel = 0; q_x = 0;
        #20 rst_n = 1;
        #10;
        frame_pulse = 1; @(posedge clk); frame_pulse = 0;
        repeat (160) @(posedge clk);

        // check right-edge columns (768..799) that map to bar_raw 128..133
        // and the valid bar127 column (762..767)
        for (b = 762; b < 800; b = b + 8) begin
            q_x = b;
            @(posedge clk); #1;
            $display("pix_x=%0d bar_raw=%0d bar(clamped)=%0d q_y=%0d", b, b/6, (b/6>127)?127:b/6, q_y);
        end
        $finish;
    end

endmodule