`timescale 1ns/1ps

module glitch_tb;

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
    reg [9:0] max_qy;
    reg [9:0] max_x;
    reg [9:0] prev_song;

    initial begin
        clk = 0; rst_n = 0; frame_pulse = 0; page_sel = 0; q_x = 0;
        #20 rst_n = 1;
        #10;

        max_qy = 0;
        // run many frames; every frame, check all bars and find max q_y
        // also specifically watch note_idx transition
        for (i = 0; i < 300; i = i + 1) begin
            // advance one frame
            frame_pulse = 1; @(posedge clk); frame_pulse = 0;

            // at THIS song moment, scan every bar, track max q_y
            for (q_x = 0; q_x < 800; q_x = q_x + 1) begin
                #1;
                if (q_y > max_qy) begin max_qy = q_y; max_x = q_x; end
            end
        end
        $display("OVER 300 frames: max q_y = %0d at x=%0d", max_qy, max_x);
        $display("(should be <= 200ish. If >300, glitch at note switch)");
        $finish;
    end

endmodule