// -----------------------------------------------------------------------------
// dsp_probe_comb.sv -- dsp_probe.sv 的纯组合版本（对照）
//
// 与 dsp_probe.sv 功能完全相同（32×24 有符号乘 + 舍入右移），只是不插任何寄存器。
// 两次综合的差值 = "把乘法寄存器化"的代价/收益；是否被映射成 MULT27X36 也由报告给出。
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module dsp_probe_comb (
    input  logic signed [31:0] a_in,
    input  logic signed [23:0] m_in,
    input  logic        [5:0]  s_in,
    output logic signed [63:0] prod_rounded
);

    import modal_step_pkg::*;

    logic signed [AW-1:0] aa, mm, prod;

    always_comb begin
        aa   = $signed(a_in);
        mm   = $signed(m_in);
        prod = aa * mm;
        if (s_in == 0) prod_rounded = prod;
        else           prod_rounded = (prod + ({{(AW-1){1'b0}}, 1'b1} <<< (s_in - 6'd1))) >>> s_in;
    end

endmodule
