`timescale 1ns/1ps

module spectrum_map_tb;

    logic        clk;
    logic        rst_n;
    logic [15:0] xk_re;
    logic [15:0] xk_im;
    logic [9:0]  bin_idx;
    logic        bin_valid;
    logic        eoud;

    wire [6:0]  bar_addr;
    wire [9:0]  bar_w;
    wire [9:0]  ov_w;
    wire        bar_we;
    wire        frame_done;

    logic [9:0] bars [0:127];

    integer errors;
    integer i;
    integer b;

    spectrum_map dut (
        .clk_i(clk), .rst_ni(rst_n),
        .xk_re_i(xk_re), .xk_im_i(xk_im),
        .bin_idx_i(bin_idx), .bin_valid_i(bin_valid), .eoud_i(eoud),
        .bar_addr_o(bar_addr), .bar_w_o(bar_w), .ov_w_o(ov_w),
        .bar_we_o(bar_we), .frame_done_o(frame_done)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (bar_we)
            bars[bar_addr] <= bar_w;
    end

    task automatic send_frame(input integer hot_bin, input [15:0] amp);
        integer n;
        begin
            for (n = 0; n < 512; n = n + 1) begin
                bin_idx   = n[9:0];
                bin_valid = 1'b1;
                xk_re     = (n == hot_bin) ? amp : 16'd0;
                xk_im     = 16'd0;
                @(posedge clk);
            end
            bin_valid = 1'b0;
            xk_re = 16'd0;
            eoud = 1'b1;
            @(posedge clk);
            eoud = 1'b0;
            wait (frame_done == 1'b1);
            @(posedge clk);
        end
    endtask

    initial begin
        errors = 0;
        rst_n = 1'b0;
        bin_idx = 0;
        bin_valid = 1'b0;
        eoud = 1'b0;
        xk_re = 0;
        xk_im = 0;
        for (i = 0; i < 128; i = i + 1)
            bars[i] = 10'd0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        send_frame(100, 16'h4000);
        if (bars[67] < 10'd400) begin
            $error("bar67 too low: %0d", bars[67]);
            errors = errors + 1;
        end
        if (bars[66] != 0 || bars[68] != 0) begin
            $error("neighbor bars not zero: %0d %0d", bars[66], bars[68]);
            errors = errors + 1;
        end

        b = bars[67];
        send_frame(200, 16'h2000);
        if (bars[96] < 10'd400) begin
            $error("bar96 too low: %0d", bars[96]);
            errors = errors + 1;
        end
        if (bars[67] >= b) begin
            $error("old bar did not decay: old=%0d now=%0d", b, bars[67]);
            errors = errors + 1;
        end

        b = bars[96];
        send_frame(0, 16'd0);
        if (bars[96] >= b) begin
            $error("silence did not release bar96: old=%0d now=%0d", b, bars[96]);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("=== SPECTRUM MAP TEST PASSED ===");
        else
            $display("=== SPECTRUM MAP TEST FAILED: %0d error(s) ===", errors);
        $finish;
    end

endmodule
