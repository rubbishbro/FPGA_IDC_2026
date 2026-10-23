// =============================================================================
// 文件 : linear_modulation.sv
// 模块 : linear_modulation
// 功能 : 线性/二阶微调制接口
// 说明 : mod = c0 + c1*k + c2*k^2；当前为占位，未接正式顶层。
// =============================================================================
`timescale 1ns/1ps
module linear_modulation (
    input  logic clk, rst_n,
    input  logic valid,
    input  logic [7:0] key_code,
    input  logic signed [31:0] c0, c1, c2,
    output logic out_valid,
    output logic signed [31:0] mod
);
    logic signed [63:0] k, p1, p2;
    logic signed [63:0] sum;
    always_comb begin
        k  = $signed({24'b0, key_code});
        p1 = c1 * k;
        p2 = c2 * k * k;
        sum = $signed(c0) + (p1 >>> 16) + (p2 >>> 32);
        if (sum > 64'sd2147483647) mod = 32'sh7FFFFFFF;
        else if (sum < -64'sd2147483648) mod = 32'sh80000000;
        else mod = sum[31:0];
    end
    always_ff @(posedge clk) begin
        if (!rst_n) out_valid <= 1'b0;
        else out_valid <= valid;
    end
endmodule
