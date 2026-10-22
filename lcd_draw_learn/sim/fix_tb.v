`timescale 1ns/1ps

module fix_tb;

    reg         clk, rst_n, frame_pulse;
    reg  [1:0]  page_sel;
    reg  [9:0]  q_x;
    wire [9:0]  q_y, q_ov;

    data_source u_ds(
        .clk(clk), .rst_n(rst_n), .frame_pulse(frame_pulse),
        .page_sel(page_sel), .q_x(q_x), .q_y(q_y), .q_ov(q_ov)
    );

    always #5 clk = ~clk;

    integer i, f, b;
    reg [9:0] max_qy, max_ov;
    integer bad;

    initial begin
        clk = 0; rst_n = 0; frame_pulse = 0; page_sel = 0; q_x = 0;
        bad = 0;
        #20 rst_n = 1;
        #10;

        // ===== 1) run 40 frames; after each, verify EVERY bar's RAM:
        //        q_ov >= q_y  (overshoot target never below bar height)
        //        q_y <= 479, q_ov <= 479
        // =====
        max_qy = 0; max_ov = 0;
        for (f = 0; f < 40; f = f + 1) begin
            frame_pulse = 1; @(posedge clk); frame_pulse = 0;
            repeat (140) @(posedge clk);   // let 128-bar recalc finish
            for (b = 0; b < 128; b = b + 1) begin
                q_x = b * 6;
                @(posedge clk); #1;   // registered q_y/q_ov need a clock edge
                if (q_ov < q_y) begin
                    $error("frame %0d bar %0d: q_ov(%0d) < q_y(%0d)", f, b, q_ov, q_y);
                    bad = bad + 1;
                end
                if (q_y > 10'd479 || q_ov > 10'd479) begin
                    $error("frame %0d bar %0d: out of range q_y=%0d q_ov=%0d", f, b, q_y, q_ov);
                    bad = bad + 1;
                end
                if (q_y > max_qy) max_qy = q_y;
                if (q_ov > max_ov) max_ov = q_ov;
            end
        end
        $display("max q_y=%0d  max q_ov=%0d  (was 116/139 pre-fix; must stay bounded)", max_qy, max_ov);
        if (max_qy > 300) begin $error("q_y max %0d too high", max_qy); bad = bad + 1; end
        if (max_ov > 479) begin $error("q_ov max %0d > 479", max_ov); bad = bad + 1; end

        if (bad == 0) $display("=== FIX TEST PASSED ===");
        else          $display("=== FIX TEST FAILED: %0d issues ===", bad);
        $finish;
    end

endmodule