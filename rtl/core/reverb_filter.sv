`timescale 1ns/1ps
module reverb_filter #(
    parameter int C1 = 1116, C2 = 1188, C3 = 1277, C4 = 1356,
    parameter int A1 = 556, A2 = 441
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
    logic signed [63:0] s1,s2,s3,s4,w,ap1,ap2;
    integer ii;
    initial begin
        for (ii=0; ii<C1; ii=ii+1) c1[ii]='0;
        for (ii=0; ii<C2; ii=ii+1) c2[ii]='0;
        for (ii=0; ii<C3; ii=ii+1) c3[ii]='0;
        for (ii=0; ii<C4; ii=ii+1) c4[ii]='0;
        for (ii=0; ii<A1; ii=ii+1) a1[ii]='0;
        for (ii=0; ii<A2; ii=ii+1) a2[ii]='0;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            p1<=0;p2<=0;p3<=0;p4<=0;pa1<=0;pa2<=0;
            lp1<=0;lp2<=0;lp3<=0;lp4<=0;
            out_valid<=0; out_data<=0;
        end else begin
            out_valid <= in_valid;
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
                w = (s1 + s2 + s3 + s4) >>> 2;
                ap1 = a1[pa1]; a1[pa1] <= w + (ap1 >>> 1);
                pa1 <= (pa1+1==A1)?0:pa1+1;
                ap2 = a2[pa2]; a2[pa2] <= ap1 + (ap2 >>> 1);
                pa2 <= (pa2+1==A2)?0:pa2+1;
                out_data <= ap2 - ap1;
            end
        end
    end
endmodule
