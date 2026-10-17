// -----------------------------------------------------------------------------
// string_mode_step.sv -- 弦模态递推的**无状态**一步计算模块（吉他/钢琴共用）
//
// 一个模态、一个采样步：
//
//   q' = a11*q + a12*v + gq*x
//   v' = a21*q + a22*v + gv*x
//   y  = wo*q                    ← 本模态对琴桥力的贡献（更新前的 q，与 Python 模型一致）
//
// 全部为组合逻辑，没有寄存器、没有时钟、没有复位：模态 bank 把 N 个本模块并联（或在
// 一个 MAC 上时分复用），把 y 求和后统一移位/舍入得到琴桥力。这样"多少模态、怎么调度"
// 与算法本身解耦，钢琴和吉他用同一个模块、只是系数表不同。
//
// 算术约定（与 _analysis/rtl_modal/gen_golden.py 逐位一致，TB 会按位比对）：
//   * 每个乘积先在**目标状态的小数点**上四舍五入（round-half-up：先加 2^(s-1) 再算术右移）
//   * 三项在一个 AW=64 位有符号累加器里相加
//   * 状态结果按 SATURATE 决定是否饱和到 32 位；y 不饱和（由 bank 决定最终位宽）
//
// 编译/仿真：
//   gw_sh  （SystemVerilog-2017，见同目录 synth.tcl）
//   xsim   （见同目录 run_xsim.ps1 + tb_string_mode_step.sv + golden_*.txt）
// -----------------------------------------------------------------------------

`timescale 1ns/1ps      // 仅仿真需要（xsim 要求全设计统一有 timescale；综合忽略）

module string_mode_step #(
    // 状态溢出时是否饱和。生成系数时按"每模态归一化到满量程"设计，正常情况下不会触发；
    // 但硬件里留这个保护比绕回（wrap）安全得多。
    parameter logic SATURATE = 1'b1
) (
    input  modal_step_pkg::coeff_t       c,        // 本模态 7 个常量（尾数 + 移位）
    input  logic signed [modal_step_pkg::QW-1:0] q,
    input  logic signed [modal_step_pkg::VW-1:0] qdot,
    input  logic signed [modal_step_pkg::XW-1:0] x,
    output logic signed [modal_step_pkg::QW-1:0] q_next,
    output logic signed [modal_step_pkg::VW-1:0] qdot_next,
    output logic signed [modal_step_pkg::YW-1:0] y
);

    import modal_step_pkg::*;

    // 算术（term / sat_q / sat_v）在 modal_step_pkg 里，与时分复用 bank 共用同一份实现，
    // 这样"并行一步"和"bank 里的一步"逐位一致 —— 详见包里对乘法宽度的注释。

    logic signed [AW-1:0] qn, vn;

    always_comb begin
        qn = term(q, c.a11, c.s11) + term(qdot, c.a12, c.s12) + term(x, c.gq, c.sgq);
        vn = term(q, c.a21, c.s21) + term(qdot, c.a22, c.s22) + term(x, c.gv, c.sgv);
        y  = term(q, c.wo, c.swo);

        if (SATURATE) begin
            q_next    = sat_q(qn);
            qdot_next = sat_v(vn);
        end else begin
            q_next    = qn[QW-1:0];
            qdot_next = vn[VW-1:0];
        end
    end

endmodule
