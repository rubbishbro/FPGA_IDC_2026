// -----------------------------------------------------------------------------
// resonator.sv -- 一个二阶 IIR mode，定点。
//
//   y[n] = G*x[n] - a1*y[n-1] - a2*y[n-2]
//
// 格式（rtl/DECISIONS.md C，更新为 FS=30）：
//   a1  Q2.20  signed   22 bit     -> 通过 <<4 重新缩放到 2^24 系数标度
//   a2  UQ0.24 unsigned 24 bit     （系数标度 24）
//   G   Q2.24  signed   26 bit     （系数标度 24）
//   y   Q2.30  signed   32 bit     （状态；从小数 24 加宽以消除 DC trap）
//   x   Q2.30  signed   32 bit     （excitation 与状态同标度）
//
// 算术（必须与 python/modal_sim/fixed_point.py 逐位一致）：
//   acc = G*x - (a1<<4)*y1 - a2*y2          // 每个乘积携带 2^(24+30)
//   y   = round_half_up(acc / 2^24)         // (acc + 2^23) >>> 24 -> 标度 2^30
//         然后饱和到 Q2.30 [-2^31, 2^31-1]
//
// 每个 valid_in 脉冲一个采样。load 锁存系数并清除状态。
// y_out 是新计算的 y（寄存）；valid_out 标记它。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module resonator #(
    parameter int YW   = 32,   // y / x 宽度
    parameter int YF   = 30,   // y / x 小数位
    parameter int GW   = 26,   // G 宽度（Q2.24）
    parameter int A1W  = 22,   // a1 宽度（Q2.20）
    parameter int A1F  = 20,   // a1 小数位
    parameter int A2W  = 24,   // a2 宽度（UQ0.24 unsigned）
    parameter int CF   = 24,   // 系数小数位（a2 / G 标度）
    parameter int ACCW = 64    // 累加器宽度（见 DECISIONS G1）
) (
    input  logic                 clk,
    input  logic                 rst_n,

    input  logic                 load,
    input  logic signed [A1W-1:0] a1_in,
    input  logic        [A2W-1:0] a2_in,
    input  logic signed [GW-1:0]  g_in,

    input  logic                 valid_in,
    input  logic signed [YW-1:0]  x_in,

    output logic signed [YW-1:0]  y_out,
    output logic                 valid_out,
    output logic                 sat_out
);

    localparam int SH = CF - A1F;                      // 4
    localparam logic signed [ACCW-1:0] YMIN = -(1 <<< (YW-1));
    localparam logic signed [ACCW-1:0] YMAX =  (1 <<< (YW-1)) - 1;
    localparam logic signed [ACCW-1:0] ROUND = 1 <<< (CF-1);   // signed：保持 >>> 算术

    logic signed [A1W-1:0] a1_r;
    logic        [A2W-1:0] a2_r;
    logic signed [GW-1:0]  g_r;
    logic signed [YW-1:0]  y1, y2;

    // a1 重新缩放到 2^24 系数标度；a2 零扩展，使乘积为 signed
    logic signed [YW-1:0] a1q24;
    logic signed [A2W:0]  a2s;
    assign a1q24 = a1_r <<< SH;
    assign a2s   = {1'b0, a2_r};

    // 乘积，加宽到累加器，使减法不会溢出
    logic signed [ACCW-1:0] p1, p2, p3, acc, shifted;
    assign p1 = g_r * x_in;
    assign p2 = a1q24 * y1;
    assign p3 = a2s * y2;
    assign acc = p1 - p2 - p3;
    assign shifted = (acc + ROUND) >>> CF;

    logic sat_now;
    logic signed [YW-1:0] ynew;
    assign sat_now = (shifted > YMAX) || (shifted < YMIN);
    assign ynew = sat_now ? (shifted[ACCW-1] ? YMIN[YW-1:0] : YMAX[YW-1:0])
                          : shifted[YW-1:0];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            a1_r <= '0; a2_r <= '0; g_r <= '0;
            y1 <= '0; y2 <= '0;
            y_out <= '0; valid_out <= 1'b0; sat_out <= 1'b0;
        end else if (load) begin
            a1_r <= a1_in; a2_r <= a2_in; g_r <= g_in;
            y1 <= '0; y2 <= '0;
            valid_out <= 1'b0; sat_out <= 1'b0;
        end else begin
            valid_out <= valid_in;
            if (valid_in) begin
                y1 <= ynew;
                y2 <= y1;
                y_out <= ynew;
                sat_out <= sat_now;
            end else begin
                sat_out <= 1'b0;          // status 仅在 valid_out 时有意义
            end
        end
    end

endmodule
