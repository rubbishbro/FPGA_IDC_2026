`timescale 1ns/1ps
module tb_post_chain_top;
    logic clk=0,rst_n=0,in_valid=0,out_valid; logic signed [63:0] in_data=0,out_data;
    int errors=0; int nz=0;
    post_chain u(.clk(clk),.rst_n(rst_n),.in_valid(in_valid),.in_data(in_data),
      .env_gain(16'h8000),.gd(16'h4000),.gw(16'h4000),.out_valid(out_valid),.out_data(out_data));
    always #5 clk=~clk;
    initial begin
        repeat(3) @(posedge clk); rst_n=1; repeat(2) @(posedge clk);
        // 持续送 4096 个样本，前 8 个为脉冲，其余 0
        for (int i=0;i<4096;i++) begin
            @(negedge clk); in_valid=1; in_data = 64'sd107374182;
            @(posedge clk);
            if (out_valid && out_data != 0) nz++;
        end
        @(negedge clk); in_valid=0;
        for (int i=0;i<2000;i++) begin @(posedge clk); if (out_valid && out_data != 0) nz++; end
        if (nz == 0) begin $display("FAIL post chain no output"); errors++; end
        if (errors==0) $display("PASS tb_post_chain_top");
        else $display("FAIL tb_post_chain_top errors=%0d",errors);
        $finish;
    end
endmodule
