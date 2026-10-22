// =============================================================================
// 文件 : excitation_convert.sv
// 模块 : excitation_convert
// 功能 : 压力 → 速度 → 激励 x
// 说明 : 8-bit pressure → UQ1.15 velocity → 32-bit Q30 x；当前为线性映射。
// =============================================================================
`timescale 1ns/1ps
module excitation_convert (
    input  logic [7:0] pressure,
    input  logic valid,
    output logic [15:0] velocity,
    output logic signed [31:0] x,
    output logic out_valid
);
    logic [15:0] v;
    always_comb begin
        v = {8'b0, pressure} << 7;       // 0..255 -> 0..32640 UQ1.15
        velocity = v;
        x = $signed({1'b0, v}) <<< 15;   // 0..~1.0 in Q30
        out_valid = valid;
    end
endmodule
