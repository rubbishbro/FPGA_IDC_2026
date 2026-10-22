// -----------------------------------------------------------------------------
// excitation_convert.sv -- pressure -> velocity -> engine.x
// 驱动只给 8-bit 原始压力；本模块把压力变成 UQ1.15 velocity 和 32-bit x。
// 目前是线性映射，后续可由 LUT/calibration 替换。
// -----------------------------------------------------------------------------
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
