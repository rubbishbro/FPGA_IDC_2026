// -----------------------------------------------------------------------------
// tb_engine_mix_sum.sv -- 四引擎结果求和单测
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_engine_mix_sum;

    logic clk = 0, rst_n = 0;
    logic start;
    logic [3:0] in_valid;
    logic [4*64-1:0] in_mix;
    logic out_valid;
    logic signed [63:0] mix_sum;

    int errors = 0;

    engine_mix_sum #(.NUM_ENGINES(4)) dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .in_valid(in_valid), .in_mix(in_mix),
        .out_valid(out_valid), .mix_sum(mix_sum)
    );

    always #5 clk = ~clk;

    task automatic check64(input string name, input logic signed [63:0] got,
                           input logic signed [63:0] exp);
        begin
            if (got !== exp) begin
                $display("FAIL %-12s got=%0d exp=%0d", name, got, exp);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        start = 0; in_valid = '0; in_mix = '0;
        repeat (3) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // 逐拍到达
        @(negedge clk); start = 1;
        @(posedge clk); @(negedge clk); start = 0;

        @(negedge clk); in_valid = 4'b0001; in_mix[0*64 +: 64] = 64'sd1;
        @(posedge clk);
        @(negedge clk); in_valid = 4'b0010; in_mix[1*64 +: 64] = 64'sd2;
        @(posedge clk);
        @(negedge clk); in_valid = 4'b0100; in_mix[2*64 +: 64] = 64'sd3;
        @(posedge clk);
        @(negedge clk); in_valid = 4'b1000; in_mix[3*64 +: 64] = 64'sd4;
        in_mix[3*64 +: 64] = 64'sd4;
        @(posedge clk);
        @(negedge clk); in_valid = '0;
        #1;
        if (!out_valid) begin $display("FAIL out_valid"); errors = errors + 1; end
        check64("sum_seq", mix_sum, 64'sd10);

        // 同拍到达
        @(negedge clk); start = 1;
        @(posedge clk); @(negedge clk); start = 0;
        @(negedge clk);
        in_valid = 4'b1111;
        in_mix[0*64 +: 64] = 64'sd10;
        in_mix[1*64 +: 64] = 64'sd20;
        in_mix[2*64 +: 64] = 64'sd30;
        in_mix[3*64 +: 64] = 64'sd40;
        @(posedge clk);
        @(negedge clk); in_valid = '0;
        #1;
        if (!out_valid) begin $display("FAIL out_valid same-cycle"); errors = errors + 1; end
        check64("sum_same", mix_sum, 64'sd100);

        if (errors == 0) $display("PASS tb_engine_mix_sum");
        else             $display("FAIL tb_engine_mix_sum errors=%0d", errors);
        $finish;
    end

endmodule
