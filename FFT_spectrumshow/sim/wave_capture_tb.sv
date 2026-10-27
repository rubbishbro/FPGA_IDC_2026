`timescale 1ns/1ps

module wave_capture_tb;

    logic        clk;
    logic        rst_n;
    logic        start;
    wire  [9:0]  wf_addr;
    logic [23:0] wf_data;
    wire         wr_en;
    wire  [9:0]  wr_addr;
    wire  [9:0]  wr_data;
    wire         frame_done;

    logic [23:0] mem [0:1023];
    logic [9:0]  cap [0:767];

    integer errors;
    integer i;
    integer writes;

    initial clk = 1'b0;
    always #5 clk = ~clk;

    always @(posedge clk)
        wf_data <= mem[wf_addr];

    always @(posedge clk) begin
        if (wr_en) begin
            cap[wr_addr] <= wr_data;
            writes <= writes + 1;
        end
    end

    wave_capture #(.N_POINTS(768), .SCAN_MAX(255)) dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .wf_addr(wf_addr), .wf_data(wf_data),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .frame_done(frame_done)
    );

    initial begin
        errors = 0;
        writes = 0;
        rst_n = 1'b0;
        start = 1'b0;
        wf_data = 24'd0;

        for (i = 0; i < 1024; i = i + 1)
            mem[i] = (i < 16) ? -24'sd300000 : 24'sd300000;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        start = 1'b1;
        @(posedge clk);
        start = 1'b0;

        wait (frame_done == 1'b1);
        repeat (3) @(posedge clk);
        #1;

        $display("writes=%0d cap0=%0d cap1=%0d cap2=%0d", writes, cap[0], cap[1], cap[2]);
        if (writes != 768) begin
            $error("writes=%0d expected 768", writes);
            errors = errors + 1;
        end

        if (cap[0] <= 10'd240) begin
            $error("trigger did not start on negative sample: cap0=%0d", cap[0]);
            errors = errors + 1;
        end

        if (cap[2] >= 10'd240) begin
            $error("trigger did not cross to positive sample: cap2=%0d", cap[2]);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("=== WAVE CAPTURE TEST PASSED ===");
        else
            $display("=== WAVE CAPTURE TEST FAILED: %0d error(s) ===", errors);
        $finish;
    end

endmodule
