// =============================================================================
// 文件 : tb_post_data_order.sv
// 模块 : tb_post_data_order
// 功能 : post_chain 连续不同数据按握手顺序进入 body，不串位
// =============================================================================
`timescale 1ns/1ps
module tb_post_data_order;
logic clk=0,rst_n=0,in_valid=0; logic signed [63:0] in_data=0,out_data;
logic in_ready,out_valid; int exp_q[$]; int got_q[$]; int errors=0;
post_chain u(.clk(clk),.rst_n(rst_n),.in_valid(in_valid),.in_ready(in_ready),.in_data(in_data),
 .env_gain(16'h8000),.gd(16'h4000),.gw(16'h4000),.out_valid(out_valid),.out_data(out_data));
always #5 clk=~clk;
always @(posedge clk) if (u.body_in_v && u.body_in_ready) got_q.push_back(u.env_pending_data);
initial begin
 repeat(3) @(posedge clk); rst_n=1; repeat(2) @(posedge clk);
 for (int i=1;i<=4;i++) begin
   exp_q.push_back(i*111);
   @(negedge clk); in_valid=1; in_data=i*111;
   @(posedge clk); while (!in_ready) @(posedge clk);
   @(negedge clk); in_valid=0;
   repeat(2) @(posedge clk);
 end
 repeat(5000) @(posedge clk);
 if (got_q.size()!=4) begin $display("FAIL got %0d",got_q.size()); errors++; end
 else for (int i=0;i<4;i++) if (got_q[i]!=exp_q[i]) begin $display("FAIL idx%0d got%0d exp%0d",i,got_q[i],exp_q[i]); errors++; end
 if (errors==0) $display("PASS tb_post_data_order"); else $display("FAIL tb_post_data_order");
 $finish;
end
endmodule
