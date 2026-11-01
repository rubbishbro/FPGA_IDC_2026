// =============================================================================
// 文件 : tb_post_handshake.sv
// 模块 : tb_post_handshake
// 功能 : post_chain 连续 valid/ready 握手不丢样本
// =============================================================================
`timescale 1ns/1ps
module tb_post_handshake;
logic clk=0,rst_n=0,in_valid=0; logic signed [63:0] in_data=0,out_data;
logic out_valid; logic in_ready; int in_cnt=0,out_cnt=0;
post_chain u(.clk(clk),.rst_n(rst_n),.in_valid(in_valid),.in_ready(in_ready),.in_data(in_data),
 .env_gain(16'h8000),.gd(16'h4000),.gw(16'h4000),.out_valid(out_valid),.out_data(out_data));
always #5 clk=~clk;
always @(posedge clk) begin
 if (in_valid && in_ready) in_cnt <= in_cnt+1;
 if (out_valid) out_cnt <= out_cnt+1;
end
initial begin
 repeat(3) @(posedge clk); rst_n=1; repeat(2) @(posedge clk);
 @(negedge clk); in_valid=1; in_data=64'sd268435456;
 repeat(20) @(posedge clk);
 @(negedge clk); in_valid=0;
 repeat(5000) @(posedge clk);
 if (in_cnt != out_cnt) $display("FAIL in=%0d out=%0d",in_cnt,out_cnt);
 else if (in_cnt == 0) $display("FAIL no transfers");
 else $display("PASS handshake in=%0d out=%0d",in_cnt,out_cnt);
 $finish;
end
endmodule
