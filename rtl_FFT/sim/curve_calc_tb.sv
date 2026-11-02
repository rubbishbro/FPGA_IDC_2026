`timescale 1ns/1ps

module curve_calc_tb;

    logic        clk;
    logic        rst_n;
    logic        start;
    wire  [6:0]  scan_addr;
    logic [39:0] scan_data;
    wire         wr_en;
    wire  [9:0]  wr_addr;
    wire  [39:0] wr_data;
    wire         frame_done;

    logic [39:0] mem [0:127];
    logic [39:0] got [0:767];

    integer errors;
    integer i;
    integer writes;

    initial clk = 1'b0;
    always #5 clk = ~clk;

    always @(posedge clk)
        scan_data <= mem[scan_addr];

    always @(posedge clk) begin
        if (wr_en) begin
            got[wr_addr] <= wr_data;
            writes <= writes + 1;
        end
    end

    curve_calc dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .scan_addr(scan_addr), .scan_data(scan_data),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .frame_done(frame_done)
    );

    initial begin
        errors = 0;
        writes = 0;
        rst_n = 1'b0;
        start = 1'b0;
        scan_data = 40'd0;

        for (i = 0; i < 128; i = i + 1)
            mem[i] = {10'd100 + i[9:0], 10'd200 + i[9:0],
                      10'd150 + i[9:0], 10'd120 + i[9:0]};

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        start = 1'b1;
        @(posedge clk);
        start = 1'b0;

        wait (frame_done == 1'b1);
        repeat (3) @(posedge clk);
        #1;

        if (writes != 768) begin
            $error("writes=%0d expected 768", writes);
            errors = errors + 1;
        end

        if (got[0][39:30] !== 10'd100 || got[0][29:20] !== 10'd200 ||
            got[0][19:10] !== 10'd150 || got[0][9:0] !== 10'd120) begin
            $error("x0 curve wrong: %0d/%0d/%0d/%0d",
                   got[0][39:30], got[0][29:20], got[0][19:10], got[0][9:0]);
            errors = errors + 1;
        end

        if (got[3][39:30] !== 10'd100) begin
            $error("center0 current wrong: %0d", got[3][39:30]);
            errors = errors + 1;
        end

        if (got[9][39:30] !== 10'd101) begin
            $error("center1 current wrong: %0d", got[9][39:30]);
            errors = errors + 1;
        end

        if (got[765][39:30] !== 10'd227) begin
            $error("tail current wrong: %0d", got[765][39:30]);
            errors = errors + 1;
        end

        if (got[767][39:30] !== 10'd227) begin
            $error("last current wrong: %0d", got[767][39:30]);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("=== CURVE CALC TEST PASSED ===");
        else
            $display("=== CURVE CALC TEST FAILED: %0d error(s) ===", errors);
        $finish;
    end

endmodule
