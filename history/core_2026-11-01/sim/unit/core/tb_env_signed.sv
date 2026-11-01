`timescale 1ns/1ps
module tb_env_signed;
logic clk=0,rst_n=0,in_valid=0,out_valid; logic signed [63:0] in_data=0,out_data;
envelope_mul u(.clk(clk),.rst_n(rst_n),.in_valid(in_valid),.in_data(in_data),.gain(16'h8000),.out_valid(out_valid),.out_data(out_data));
always #5 clk=~clk;
initial begin
 repeat(3) @(posedge clk); rst_n=1; repeat(2) @(posedge clk);
 @(negedge clk); in_valid=1; in_data=-64'sd268435456;
 @(posedge clk); @(negedge clk); in_valid=0;
 @(posedge clk); #1;
 if (out_data !== -64'sd268435456) $display("FAIL tb_env_signed=%0d",out_data); else $display("PASS tb_env_signed");
 $finish;
end
endmodule
