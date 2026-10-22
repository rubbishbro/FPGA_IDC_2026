// =============================================================================
// 文件 : envelope_mul.sv
// 模块 : envelope_mul
// 功能 : engine 后包络乘法器
// 说明 : 64-bit 数据 × UQ1.15 增益；一级流水；输出饱和。
// =============================================================================
`timescale 1ns/1ps
module envelope_mul (
    input  logic clk, rst_n,
    input  logic in_valid,
    input  logic signed [63:0] in_data,
    input  logic [15:0] gain,
    output logic out_valid,
    output logic signed [63:0] out_data
);
    logic signed [31:0] sh, sl;
    logic signed [47:0] ph, pl;
    logic signed [79:0] prod, rounded;
    logic signed [63:0] sat;

    always_comb begin
        sh = in_data[63:32];
        sl = in_data[31:0];
        ph = sh * $signed({1'b0, gain});
        pl = sl * $signed({1'b0, gain});
        prod = ($signed({{32{ph[47]}}, ph}) <<< 32) + $signed({32'b0, pl});
        rounded = (prod + 80'sd16384) >>> 15;
        if (rounded > 80'sd9223372036854775807)      sat = 64'sh7FFFFFFFFFFFFFFF;
        else if (rounded < -80'sd9223372036854775808) sat = 64'sh8000000000000000;
        else                                          sat = rounded[63:0];
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            out_data  <= 64'sd0;
        end else begin
            out_valid <= in_valid;
            if (in_valid) out_data <= sat;
        end
    end
endmodule
