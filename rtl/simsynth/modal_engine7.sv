// -----------------------------------------------------------------------------
// modal_engine7.sv -- 7 乘法器并联的**纯计算**引擎（ARCH_PARALLEL7.md 第 8 节 A）
//
// 定位：只算，不存。
//   * 系数、状态、激励、结果**全部在顶层**（声部与 ping-pong 由顶层负责，见
//     modal_voice_top.sv）；
//   * 引擎对外的数据面是 5 组 SRAM 式端口（1 读 / 1 写），地址都是**本声部内的偏移**
//     （模态号 / 采样号），顶层把 {bank, 声部号} 拼到地址高位；
//   * 控制面只要 `start / st_zero / n_samples / n_modes / done`（done 是单拍脉冲）。
//
// 与 modal_bank_ram 的差别只有数据通路：
//   原来 1 个乘法器轮转 7 个乘积、移位量由运行时的 `k` 选 ⇒ 必须用桶形移位器；
//   现在 7 个乘法器**并联**，每个字段的移位量 SH_* 是编译期常量 ⇒ `>>> SH_A11` 退化成
//   连线，舍入偏置 1<<(SH-1) 也是常数。关键路径里不再有"64 位加法 + 6 级桶形移位"。
//
//     a11·q  a12·v  gq·x  -> qn
//     a21·q  a22·v  gv·x  -> vn
//     wo·q                -> y
//
// 五级流水，吞吐 1 模态/拍
// -----------------------
//   级   内容                                    序号（ri 是读指针）
//   R    给 co/st 读地址（同步 RAM）              ri
//   M    7 个 32x32 乘法 -> p_*                   ri-1
//   N    (p + 1<<(SH-1)) >>> SH -> t_*            ri-2
//   S    三路相加 -> qn_q / vn_q；t_wo 也过一级   ri-3
//   W    饱和 -> 写回状态；y_acc += two_q         ri-4
//
// 为什么必须切五级：第一版把 M/N/S/W 挤在一拍，PnR 实测最差路径 16.0 ns（64 MHz），
// 一条路径穿过 乘法 → 64 位舍入加 → 常数移位 → 三路 64 位加 → 饱和 → RAM 写口。
// 切开后每一级只有 2–4 ns。
//
// 一帧 = 1（取 x）+ 1（装配、发第 1 个读地址）+ N+4（流水排空）+ 1（y_sum 取用）
//      + 1（写结果） = N + 8 拍。N=48 时 56 拍（modal_bank_ram 是 530 拍）。
//
// 逐位等价：每个乘积"先独立舍入成整数、再相加"，整数加法可交换/结合（64 位回绕一致），
// 所以 7 路并行 + 树形相加 + 五级流水与 modal_bank_ram 的逐项累加结果完全相同。
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module modal_engine7 #(
    parameter int   N_MODES  = 48,
    parameter int   X_DEPTH  = 256,
    parameter logic SATURATE = 1'b1,
    // 0 = 不接激励（gq/gv 搬到顶层去做），7 个乘法器降到 5 个
    parameter bit   USE_X    = 1'b1
) (
    input  logic                                     clk,
    input  logic                                     rst_n,

    // ---- 作业口 ----
    //   一次 start = 递推**一个采样**：y_valid 那一拍既是结果有效，也是本作业结束。
    //   时间维的循环交给声部层（它本来就按"采样 × 声部"调度）。
    input  logic                                     start,
    input  logic                                     st_zero,      // 1 = 本作业先把状态清零（note-on）
    input  logic [$clog2(N_MODES+1)-1:0]             n_modes,

    // ---- 系数读口（同步读：地址这拍给，数据下一拍有效）----
    output logic                                     co_re,
    output logic [$clog2(N_MODES)-1:0]               co_addr,
    input  modal_step_pkg::coeff_t                   co_data,

    // ---- 状态读口 ----
    output logic                                     st_re,
    output logic [$clog2(N_MODES)-1:0]               st_addr,
    input  logic signed [modal_step_pkg::QW-1:0]     st_q,
    input  logic signed [modal_step_pkg::VW-1:0]     st_qdot,

    // ---- 状态写回口（计算侧；已饱和）----
    output logic                                     st_we,
    output logic [$clog2(N_MODES)-1:0]               st_waddr,
    output logic signed [modal_step_pkg::QW-1:0]     st_q_wdata,
    output logic signed [modal_step_pkg::VW-1:0]     st_qdot_wdata,

    // ---- 激励读口 ----
    output logic                                     x_re,
    output logic [$clog2(X_DEPTH)-1:0]               x_addr,
    input  logic signed [modal_step_pkg::XW-1:0]     x_data,

    // ---- 结果流口（每帧一个 Σ wo·q；没有地址：由顶层按"第几个声部"累加）----
    output logic                                     y_valid,
    output logic signed [modal_step_pkg::YW-1:0]     y_data
);

    import modal_step_pkg::*;

    localparam int IW = $clog2(N_MODES);
    localparam int JW = $clog2(X_DEPTH);

    // ---- 乘法与舍入 ------------------------------------------------------
    // mul64：先符号扩展到累加器宽度再乘（SV 里 a*m 的结果宽度是操作数最大宽度，
    // 32 位直接相乘只剩 32 位）。与 modal_step_pkg::term 的内核完全一致。
    function automatic logic signed [AW-1:0] mul64(
        input logic signed [XW-1:0] a,
        input logic signed [CW-1:0] m
    );
        logic signed [AW-1:0] aa, mm;
        aa    = a;
        mm    = m;
        mul64 = aa * mm;
    endfunction

    // 舍入偏置：常数（不进桶形移位器）
    localparam logic signed [AW-1:0] R_A11 = 64'sd1 <<< (SH_A11 - 1);
    localparam logic signed [AW-1:0] R_A12 = 64'sd1 <<< (SH_A12 - 1);
    localparam logic signed [AW-1:0] R_A21 = 64'sd1 <<< (SH_A21 - 1);
    localparam logic signed [AW-1:0] R_A22 = 64'sd1 <<< (SH_A22 - 1);
    localparam logic signed [AW-1:0] R_GQ  = 64'sd1 <<< (SH_GQ  - 1);
    localparam logic signed [AW-1:0] R_GV  = 64'sd1 <<< (SH_GV  - 1);
    localparam logic signed [AW-1:0] R_WO  = 64'sd1 <<< (SH_WO  - 1);

    // ---- 作业状态 ---------------------------------------------------------
    typedef enum logic [2:0] { S_IDLE, S_ZERO, S_X, S_SETUP, S_RUN, S_WB, S_YWR } state_t;
    state_t               state;
    logic [IW:0]          ri;            // 读指针 = 流水序号
    logic [IW:0]          si;            // 写回序号 = ri - 4
    logic [IW:0]          zi;            // 清零 pass 的计数
    logic [IW:0]          n_mod_lat;
    logic signed [AW-1:0] y_acc, y_sum;
    logic signed [XW-1:0] x_lat;

    assign si = ri - 4'd4;

    // ---- 流水寄存器 -------------------------------------------------------
    logic signed [AW-1:0] p_a11, p_a12, p_gq, p_a21, p_a22, p_gv, p_wo;   // M 级
    logic signed [AW-1:0] t_a11, t_a12, t_gq, t_a21, t_a22, t_gv, t_wo;   // N 级
    logic signed [AW-1:0] qn_q, vn_q, two_q;                              // S 级

    logic                 mul_en, rnd_en, sum_en, wb_en;

    always_comb begin
        // 读 = ri；乘 = ri-1；舍入 = ri-2；相加 = ri-3；写回 = ri-4
        mul_en = (state == S_RUN) && (ri >= 1) && (ri <= n_mod_lat);
        rnd_en = (state == S_RUN) && (ri >= 2) && (ri <= n_mod_lat + 1);
        sum_en = (state == S_RUN) && (ri >= 3) && (ri <= n_mod_lat + 2);
        wb_en  = (state == S_RUN) && (ri >= 4) && (ri <= n_mod_lat + 3);
    end

    // ---- M 级：乘法 -------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p_a11 <= '0; p_a12 <= '0; p_gq <= '0;
            p_a21 <= '0; p_a22 <= '0; p_gv <= '0; p_wo <= '0;
        end else if (mul_en) begin
            p_a11 <= mul64(st_q,    co_data.a11);
            p_a12 <= mul64(st_qdot, co_data.a12);
            if (USE_X) p_gq <= mul64(x_lat, co_data.gq);
            p_a21 <= mul64(st_q,    co_data.a21);
            p_a22 <= mul64(st_qdot, co_data.a22);
            if (USE_X) p_gv <= mul64(x_lat, co_data.gv);
            p_wo  <= mul64(st_q,    co_data.wo);
        end
    end

    // ---- N 级：舍入 + 常数移位 -------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            t_a11 <= '0; t_a12 <= '0; t_gq <= '0;
            t_a21 <= '0; t_a22 <= '0; t_gv <= '0; t_wo <= '0;
        end else if (rnd_en) begin
            // 移位量是编译期常量 ⇒ 综合成连线；加法只是 64 位常数偏置
            t_a11 <= (p_a11 + R_A11) >>> SH_A11;
            t_a12 <= (p_a12 + R_A12) >>> SH_A12;
            t_gq  <= (p_gq  + R_GQ ) >>> SH_GQ;
            t_a21 <= (p_a21 + R_A21) >>> SH_A21;
            t_a22 <= (p_a22 + R_A22) >>> SH_A22;
            t_gv  <= (p_gv  + R_GV ) >>> SH_GV;
            t_wo  <= (p_wo  + R_WO ) >>> SH_WO;
        end
    end

    // ---- S 级：三路相加（y 项也过一级，保证与写回同序号）-------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            qn_q  <= '0;
            vn_q  <= '0;
            two_q <= '0;
        end else if (sum_en) begin
            qn_q  <= t_a11 + t_a12 + (USE_X ? t_gq : '0);
            vn_q  <= t_a21 + t_a22 + (USE_X ? t_gv : '0);
            two_q <= t_wo;
        end
    end

    // ---- 端口接续 ---------------------------------------------------------
    always_comb begin
        // 读地址：S_SETUP 发第 0 个（此时 ri 还是上一帧排空的残值，必须强制取 0），
        //         S_RUN 每拍发 ri
        co_re   = (state == S_SETUP) || ((state == S_RUN) && (ri < n_mod_lat));
        co_addr = (state == S_SETUP) ? '0 : ri[IW-1:0];
        st_re   = co_re;
        st_addr = co_addr;

        // W 级：饱和后写回（序号 ri-4）
        // 写口两个来源：计算写回（ri-4）与 note-on 的清零 pass
        st_we         = wb_en || (state == S_ZERO);
        st_waddr      = (state == S_ZERO) ? zi[IW-1:0] : si[IW-1:0];
        st_q_wdata    = (state == S_ZERO) ? '0 : (SATURATE ? sat_q(qn_q) : qn_q[QW-1:0]);
        st_qdot_wdata = (state == S_ZERO) ? '0 : (SATURATE ? sat_v(vn_q) : vn_q[VW-1:0]);

        x_re   = (state == S_X);
        x_addr = '0;                       // 一次 start 只跑一个采样；帧号由顶层补进地址

        // 这一拍：结果有效，同时就是本作业的最后一拍
        y_valid = (state == S_YWR);
        y_data  = y_sum[YW-1:0];
    end

    // ---- 作业状态机 -------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            ri         <= '0;
            n_mod_lat  <= '0;
            y_acc      <= '0;
            y_sum      <= '0;
            x_lat      <= '0;
        end else begin

            // W 级：串行累加本帧的 y（每模态一次，与 bank_ram 的 y_acc 一致）
            if (wb_en) begin
                if (si == '0) y_acc <= two_q;
                else          y_acc <= y_acc + two_q;
            end

            case (state)
                S_IDLE: begin
                    if (start) begin
                        n_mod_lat  <= n_modes;
                        ri         <= '0;
                        y_acc      <= '0;
                        y_sum      <= '0;
                        zi         <= '0;
                        if (st_zero) state <= S_ZERO;
                        else         state <= S_X;
                    end
                end

                S_ZERO: begin
                    // 把本声部的状态清 0（note-on）：N 拍，一次性
                    if (zi + 1'b1 >= n_mod_lat) state <= S_X;
                    else                        zi    <= zi + 1'b1;
                end

                S_X: begin
                    state <= S_SETUP;
                end

                S_SETUP: begin
                    // x_data 此刻有效（S_X 的读结果），后面整帧都用它
                    x_lat <= x_data;
                    ri    <= 1'b1;          // 第 0 个读地址已在 S_SETUP 发出
                    state <= S_RUN;
                end

                S_RUN: begin
                    // ri = n_mod+3 那拍完成最后一个模态的写回；
                    // ri = n_mod+4 这拍流水已排空，可以收尾
                    if (ri == n_mod_lat + 3'd4) state <= S_WB;
                    else                        ri    <= ri + 1'b1;
                end

                S_WB: begin
                    // y_acc 已经是"本帧全部模态"的和，这里取用而不是累加
                    y_sum <= y_acc;
                    state <= S_YWR;
                end

                S_YWR: begin
                    // 这一拍 y_valid=1、y_data=y_sum；下一拍照样回到 IDLE 等下一次 start
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
