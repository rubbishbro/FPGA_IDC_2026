`timescale 1ns/1ps
module tb_linear_modulation;
    logic clk=0,rst_n=0,valid=0,out_valid; logic [7:0] key=0;
    logic signed [31:0] c0=0,c1=0,c2=0,mod;
    int errors=0;
    logic seen;
    linear_modulation u(.clk(clk),.rst_n(rst_n),.valid(valid),.key_code(key),.c0(c0),.c1(c1),.c2(c2),.out_valid(out_valid),.mod(mod));
    always #5 clk=~clk;
    always @(posedge clk) if (out_valid) seen <= 1'b1;
    initial begin
        repeat(3) @(posedge clk); rst_n=1; repeat(2) @(posedge clk);
        seen=0;
        @(negedge clk); valid=1; key=8'd4; c0=32'sd1; c1=32'sd131072; // 2.0 Q16.16
        @(posedge clk); @(negedge clk); valid=0;
        @(posedge clk); #1;
        if (mod != 32'sd9) begin $display("FAIL mod=%0d",mod); errors++; end
        if (!seen) begin $display("FAIL valid"); errors++; end
        if (errors==0) $display("PASS tb_linear_modulation"); else $display("FAIL tb_linear_modulation errors=%0d",errors);
        $finish;
    end
endmodule
