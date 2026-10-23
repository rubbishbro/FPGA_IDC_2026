`timescale 1ns/1ps
module tb_comb_reverb;
    logic clk=0,rst_n=0,in_valid=0,out_valid; logic signed [63:0] in_data=0,out_data;
    int errors=0; int nz=0;
    comb_reverb u(.clk(clk),.rst_n(rst_n),.in_valid(in_valid),.in_data(in_data),.out_valid(out_valid),.out_data(out_data));
    always #5 clk=~clk;
    initial begin
        repeat(3) @(posedge clk); rst_n=1; repeat(2) @(posedge clk);
        @(negedge clk); in_valid=1; in_data=64'sd1073741824;
        @(posedge clk); @(negedge clk); in_valid=1; in_data=0;
        for (int i=0;i<6000;i++) begin
            @(posedge clk);
            if (out_valid && out_data != 0) nz++;
        end
        if (nz == 0) begin $display("FAIL reverb no nonzero output"); errors++; end
        if (errors==0) $display("PASS tb_comb_reverb");
        else $display("FAIL tb_comb_reverb errors=%0d",errors);
        $finish;
    end
endmodule
