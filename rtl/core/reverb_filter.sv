// -----------------------------------------------------------------------------
// reverb_filter.sv -- 简化 Schroeder/Freeverb 结构（4 comb + 2 allpass）
// 输出只有 wet；dry/wet 在外部做。系数固定，后续可由 router/flash 参数化。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module reverb_filter #(
    parameter int C1 = 1116,
    parameter int C2 = 1188,
    parameter int C3 = 1277,
    parameter int C4 = 1356,
    parameter int A1 = 556,
    parameter int A2 = 441
) (
    input  logic clk, rst_n,
    input  logic in_valid,
    input  logic signed [63:0] in_data,
    output logic out_valid,
    output logic signed [63:0] out_data
);
    logic signed [63:0] c1 [0:C1-1], c2 [0:C2-1], c3 [0:C3-1], c4 [0:C4-1];
    logic signed [63:0] a1 [0:A1-1], a2 [0:A2-1];
    logic [15:0] p1,p2,p3,p4,pa1,pa2;
    logic signed [63:0] lp1,lp2,lp3,lp4;
    logic signed [63:0] s1,s2,s3,s4, w, ap1, ap2;
    integer ii;
    initial begin
        for (ii=0; ii<C1; ii=ii+1) c1[ii]='0;
        for (ii=0; ii<C2; ii=ii+1) c2[ii]='0;
        for (ii=0; ii<C3; ii=ii+1) c3[ii]='0;
        for (ii=0; ii<C4; ii=ii+1) c4[ii]='0;
        for (ii=0; ii<A1; ii=ii+1) a1[ii]='0;
        for (ii=0; ii<A2; ii=ii+1) a2[ii]='0;
    end

    localparam int FB = 16'sd22938;   // 0.7 Q15
    localparam int DAMP = 16'sd6554;  // 0.2 Q15

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            p1<=0;p2<=0;p3<=0;p4<=0;pa1<=0;pa2<=0;
            lp1<=0;lp2<=0;lp3<=0;lp4<=0;
            out_valid<=0; out_data<=0;
        end else begin
            out_valid <= in_valid;
            if (in_valid) begin
                s1 = c1[p1]; s2 = c2[p2]; s3 = c3[p3]; s4 = c4[p4];
                lp1 <= s1 + ((DAMP * (lp1 - s1)) >>> 15);
                lp2 <= s2 + ((DAMP * (lp2 - s2)) >>> 15);
                lp3 <= s3 + ((DAMP * (lp3 - s3)) >>> 15);
                lp4 <= s4 + ((DAMP * (lp4 - s4)) >>> 15);
                c1[p1] <= in_data + ((FB * lp1) >>> 15);
                c2[p2] <= in_data + ((FB * lp2) >>> 15);
                c3[p3] <= in_data + ((FB * lp3) >>> 15);
                c4[p4] <= in_data + ((FB * lp4) >>> 15);
                p1 <= (p1+1==C1)?0:p1+1;
                p2 <= (p2+1==C2)?0:p2+1;
                p3 <= (p3+1==C3)?0:p3+1;
                p4 <= (p4+1==C4)?0:p4+1;
                w = (s1 + s2 + s3 + s4) >>> 2;
                ap1 = a1[pa1]; a1[pa1] <= w + ((16'sd16384 * ap1) >>> 15);
                pa1 <= (pa1+1==A1)?0:pa1+1;
                ap2 = a2[pa2]; a2[pa2] <= ap1 + ((16'sd16384 * ap2) >>> 15);
                pa2 <= (pa2+1==A2)?0:pa2+1;
                out_data <= ap2 - ap1;
            end
        end
    end
endmodule
