// -----------------------------------------------------------------------------
// dsp_probe.sv -- 只为回答"引入 DSP 能省多少资源"的对照模块
//
// 内容就是 bank 里的那一次乘法拍：32 位状态 × 24 位系数（有符号），带舍入与移位。
// 本模块把**乘法的两个操作数与乘积都寄存**（也就是流水线化的写法），而 modal_bank_seq
// 里同一段算术是纯组合的。两次综合的差值就是"把乘法交给 DSP"的收益。
//
// 不参与功能验证，只用于综合测量。
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module dsp_probe (
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic signed [31:0]      a_in,
    input  logic signed [23:0]      m_in,
    input  logic        [5:0]       s_in,
    output logic signed [63:0]      prod_rounded
);

    import modal_step_pkg::*;

    logic signed [AW-1:0] aa, mm, prod;
    logic        [SW-1:0] s_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aa <= '0; mm <= '0; s_r <= '0;
        end else begin
            aa  <= $signed(a_in);          // 乘法器输入寄存
            mm  <= $signed(m_in);
            s_r <= s_in;
        end
    end

    always_ff @(posedge clk) prod <= aa * mm;      // 乘积寄存（两端都寄存 ⇒ 利于 DSP 映射）

    always_ff @(posedge clk) begin
        // 与包里 term() 相同的舍入与算术右移
        if (s_r == 0) prod_rounded <= prod;
        else          prod_rounded <= (prod + ({{(AW-1){1'b0}}, 1'b1} <<< (s_r - 6'd1))) >>> s_r;
    end

endmodule
