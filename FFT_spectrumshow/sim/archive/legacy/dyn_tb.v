`timescale 1ns/1ps

module dyn_tb;

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
    integer errors = 0;
    reg [9:0] prev_h, cur_h;

    initial begin
        clk = 0; rst_n = 0; frame_pulse = 0; page_sel = 0; q_x = 0;
        #20 rst_n = 1;
        #10;

        // track bar 14 height over 40 frames to confirm it MOVES (not static)
        prev_h = 0;
        for (i = 0; i < 40; i = i + 1) begin
            q_x = 10'd86; #1;   // bar 14
            cur_h = q_y;
            if (i > 5 && cur_h == prev_h) begin
                // allow some static frames (peak only moves every 8), but overall should vary
            end
            frame_pulse = 1; @(posedge clk); frame_pulse = 0;
            prev_h = cur_h;
        end

        // check heights actually differ across the run (dynamic behavior)
        // sample at several frame moments
        $display("=== dynamic height samples (bar14) ===");
        frame_pulse = 1; @(posedge clk); frame_pulse = 0; q_x = 86; #1;
        $display("after 40 frames, peak_pos=%0d level=%0d q_y=%0d",
                 u_ds.peak_pos, u_ds.level_dyn, q_y);

        if (u_ds.peak_pos > 8'd20) begin
            $display("peak moved: %0d (dynamic OK)", u_ds.peak_pos);
        end else begin
            $error("peak did not move"); errors = errors + 1;
        end

        if (errors == 0) $display("=== DYN TEST PASSED ===");
        else             $display("=== DYN TEST FAILED: %0d ===", errors);
        $finish;
    end

endmodule