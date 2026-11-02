`timescale 1ns/1ps

module trail_calc_tb;

    logic        clk;
    logic        rst_n;
    logic        start;
    logic [5:0]  base_row;
    wire  [5:0]  scan_row;
    wire  [6:0]  scan_col;
    logic [9:0]  scan_data;
    wire         wr_en;
    wire  [6:0]  wr_addr;
    wire  [39:0] wr_data;
    wire         frame_done;

    logic [9:0] mem [0:63*128-1];
    logic [39:0] got [0:127];

    integer errors;
    integer i;
    integer row;
    integer col;
    integer writes;

    initial clk = 1'b0;
    always #5 clk = ~clk;

    always @(posedge clk)
        scan_data <= mem[{scan_row, scan_col}];

    always @(posedge clk) begin
        if (wr_en) begin
            got[wr_addr] <= wr_data;
            writes <= writes + 1;
        end
    end

    trail_calc dut (
        .clk(clk), .rst_n(rst_n), .start(start), .base_row(base_row),
        .scan_row(scan_row), .scan_col(scan_col), .scan_data(scan_data),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .frame_done(frame_done)
    );

    initial begin
        errors = 0;
        writes = 0;
        rst_n = 1'b0;
        start = 1'b0;
        base_row = 6'd15;
        scan_data = 10'd0;

        for (row = 0; row < 64; row = row + 1)
            for (col = 0; col < 128; col = col + 1)
                mem[row*128+col] = (15 - row) * 10 + col;

        for (row = 0; row < 16; row = row + 1)
            for (col = 0; col < 128; col = col + 1)
                mem[row*128+col] = (15 - row) * 10 + col;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        start = 1'b1;
        @(posedge clk);
        start = 1'b0;

        wait (frame_done == 1'b1);
        repeat (2) @(posedge clk);
        #1;

        if (writes != 128) begin
            $error("writes=%0d expected 128", writes);
            errors = errors + 1;
        end

        for (i = 0; i < 127; i = i + 1) begin
            if (got[i][9:0] !== (10'd30 + i[9:0]) ||
                got[i][19:10] !== (10'd70 + i[9:0]) ||
                got[i][29:20] !== (10'd150 + i[9:0]) ||
                got[i][39:30] !== i[9:0]) begin
                $error("bar %0d: got %0d/%0d/%0d", i,
                       got[i][9:0], got[i][19:10], got[i][29:20]);
                errors = errors + 1;
            end
        end

        if (got[127][9:0] !== 10'd156 || got[127][19:10] !== 10'd196 ||
            got[127][29:20] !== 10'd276 || got[127][39:30] !== 10'd126) begin
            $error("bar 127 smoothing wrong: %0d/%0d/%0d/%0d",
                   got[127][9:0], got[127][19:10], got[127][29:20], got[127][39:30]);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("=== TRAIL CALC TEST PASSED ===");
        else
            $display("=== TRAIL CALC TEST FAILED: %0d error(s) ===", errors);
        $finish;
    end

endmodule
