// =============================================================================
// 文件 : comb_reverb.sv
// 模块 : comb_reverb
// 功能 : 4-comb 简化混响
// 说明 : 只输出 wet；反馈用移位/加法；为 100MHz 时序去掉 allpass。
// =============================================================================
`timescale 1ns/1ps
module comb_reverb #(
    parameter int C1 = 1116,
    parameter int C2 = 1188,
    parameter int C3 = 1277,
    parameter int C4 = 1356
) (
    input  logic clk, rst_n,
    input  logic in_valid,
    input  logic signed [63:0] in_data,
    output logic out_valid,
    output logic signed [63:0] out_data
);
    logic signed [63:0] c1 [0:C1-1], c2 [0:C2-1], c3 [0:C3-1], c4 [0:C4-1];
    logic [15:0] p1,p2,p3,p4;
    logic signed [63:0] lp1,lp2,lp3,lp4;
    logic signed [63:0] s1,s2,s3,s4;
    logic signed [65:0] sum4;
    logic sum_v, valid_d;
    integer ii;
    initial begin
        for (ii=0; ii<C1; ii=ii+1) c1[ii]='0;
        for (ii=0; ii<C2; ii=ii+1) c2[ii]='0;
        for (ii=0; ii<C3; ii=ii+1) c3[ii]='0;
        for (ii=0; ii<C4; ii=ii+1) c4[ii]='0;
    end
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            p1<=0;p2<=0;p3<=0;p4<=0; lp1<=0;lp2<=0;lp3<=0;lp4<=0;
            out_valid<=0; out_data<=0; sum4<=0; sum_v<=0; valid_d<=0;
        end else begin
            sum_v <= in_valid;
            valid_d <= sum_v;
            out_valid <= valid_d;
            if (in_valid) begin
                s1 = c1[p1]; s2 = c2[p2]; s3 = c3[p3]; s4 = c4[p4];
                lp1 <= s1 + ((lp1 - s1) >>> 3);
                lp2 <= s2 + ((lp2 - s2) >>> 3);
                lp3 <= s3 + ((lp3 - s3) >>> 3);
                lp4 <= s4 + ((lp4 - s4) >>> 3);
                c1[p1] <= in_data + (lp1 >>> 1) + (lp1 >>> 2) - (lp1 >>> 5);
                c2[p2] <= in_data + (lp2 >>> 1) + (lp2 >>> 2) - (lp2 >>> 5);
                c3[p3] <= in_data + (lp3 >>> 1) + (lp3 >>> 2) - (lp3 >>> 5);
                c4[p4] <= in_data + (lp4 >>> 1) + (lp4 >>> 2) - (lp4 >>> 5);
                p1 <= (p1+1==C1)?0:p1+1;
                p2 <= (p2+1==C2)?0:p2+1;
                p3 <= (p3+1==C3)?0:p3+1;
                p4 <= (p4+1==C4)?0:p4+1;
                sum4 <= s1 + s2 + s3 + s4;
            end
            out_data <= sum4 >>> 2;
        end
    end
endmodule
