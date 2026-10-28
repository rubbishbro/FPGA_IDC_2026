`timescale 1ns/1ps
// =============================================================================
// modulation0 -- 揉弦：**一阶线性化**，每个模态 4 次乘加
//
// 物理模型：揉弦主要调弦张力 -> 所有模态频率同比例变成 alpha = 1 + lambda，
// 于是每个系数写成"基值 + lambda * 斜率"（推导见 README §4.6 和
// sythsound/guitar_param_gen.py）：
//
//     a11 = a11_0 + lambda*S11      a12 = a12_0 + lambda*S12
//     a22 = a22_0 + lambda*S22      wo  = wo_0  + lambda*Swo
//     a21 = -a12                    （不单独算，取负即可；S21 同理不需要）
//
// 和老方案的区别：老方案读 c0/s0/gam/theta0/g/k12/k21 用 cos/sin 重构、每模态 15 步；
// 现在是 4 次乘加、无三角函数，而且**幂等**（基值单独存，不依赖上次写回的值）。
//
// 一个模态的时序（单乘法器串行）：
//     S_RD   给参数表地址
//     S_W    等两级读延迟，把 8 个参数锁进本地寄存器
//     4 × (S_LD -> S_MUL -> S_APPLY)   lambda * Sxx
//     S_OUT  写回 a11/a12/a21/a22/wo（5 个字段）
//
// lambda 的映射（**临时**，等上层定下来再换）：lambda = (fmap - LAM_OFF) << LAM_SH，
// 再限幅到 ±LAM_MAX(=0.03)。fmap 8 位，中心放在音符阈值附近 -> "正常按"≈0、
// "加力"往上弯。
// =============================================================================
module modulation0 #(
    parameter int SLOTS   = 16,
    parameter int N_MODES = 64,
    parameter int FS      = 48000
)(
    input  logic                      clk,
    input  logic                      rst_n,
    input  logic                      start,       // 本声部更新（一拍）
    input  logic [15:0]               n_modes,
    input  logic [7:0]                fmap_i,      // 本声部压力 -> lambda
    output logic                      busy,
    output logic                      done,

    // 参数表（8 个字段，见 router_pkg::mod_par_t）
    output logic                      p_re,
    output logic [$clog2(N_MODES)-1:0] p_mode,
    input  logic signed [31:0]        p_a11,
    input  logic signed [31:0]        p_a12,
    input  logic signed [31:0]        p_a22,
    input  logic signed [31:0]        p_wo,
    input  logic signed [31:0]        p_s11,
    input  logic signed [31:0]        p_s12,
    input  logic signed [31:0]        p_s22,
    input  logic signed [31:0]        p_swo,

    // 写回系数表：5 个字段（a11/a12/a21/a22/wo）
    output logic [4:0]                co_we,
    output logic [$clog2(N_MODES)-1:0] co_mode,
    output modal_step_pkg::coeff_t    co_wdata
);

    // ---- lambda 的临时映射（Q30）----
    localparam logic signed [31:0] LAM_MAX = 32'sd32_212_255;   // 0.03 * 2^30
    localparam logic signed [31:0] LAM_OFF = 32'sd242;          // 中心：和 NOTE_ON_TH(230) 对齐
    localparam int                 LAM_SH  = 21;                // (fmap-242)<<21 -> 覆盖 ±0.03（fmap 230..255）
    // 只调制最低 MOD_TOP 个模态（其余保持表里的基值，避免高模态被推出稳定域）
    localparam int                 MOD_TOP  = 6;    // 实测 N=6 时 lambda 到 0.0254 仍全稳定，8 及以上最高模态会 |eig|>1

    typedef enum logic [2:0] { S_IDLE, S_RD, S_W, S_LD, S_MUL, S_APPLY, S_OUT } mst_e;
    mst_e st;

    logic [1:0]  step;          // 0..3：算第几个斜率
    logic [15:0] mode;
    logic [15:0] nmod_lat;

    logic signed [31:0] lam_q;                                  // Q30
    logic signed [31:0] a11_l, a12_l, a22_l, wo_l;               // 基值
    logic signed [31:0] s11_l, s12_l, s22_l, swo_l;              // 斜率
    logic signed [31:0] mul_a_q, mul_b_q;
    logic signed [63:0] prod_q;
    logic signed [63:0] acc_q;                                  // lambda*S 的乘积寄存器

    // lambda 限幅：先算 (fmap - LAM_OFF)<<LAM_SH，再夹到 **0 .. +LAM_MAX**
    //
    // 只做**单向**（张力变大 = 音高往上弯）：
    //   * 有符号问题：`32'(fmap_i)` 是无符号，和 LAM_OFF（有符号）相减会整段按
    //     无符号解释（fmap=240 本该 -2，变成 0xFFFFFFFE），所以用 $signed 包一层；
    //   * 负方向禁用：一阶线性化在 lambda<0 那一侧会把某些高模态的 a12 推大，
    //     使 det = a11*a22 - a12*a21 > 1 -> |eig| 1.02 > 1 自激（_analysis/mod_model.py
    //     实测 fmap<=235 时 slot15 mode18 就是 1.024）。所以下限直接夹 0：
    //     fmap <= LAM_OFF(=242) 就等于不调制。
    logic signed [31:0] lam_diff;
    logic signed [31:0] lam_raw;
    always_comb begin
        lam_diff = $signed({24'd0, fmap_i}) - LAM_OFF;
        lam_raw  = lam_diff <<< LAM_SH;
        if (lam_raw < 0)             lam_q = '0;       // 负方向不调制
        else if (lam_raw > LAM_MAX)  lam_q = LAM_MAX;
        else                         lam_q = lam_raw;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st       <= S_IDLE;
            busy     <= 1'b0;
            done     <= 1'b0;
            mode     <= '0;
            nmod_lat <= '0;
            step     <= 2'd0;
            p_re     <= 1'b0;
            p_mode   <= '0;
            co_we    <= 5'b0;
            co_mode  <= '0;
            co_wdata <= '0;
            a11_l <= '0; a12_l <= '0; a22_l <= '0; wo_l  <= '0;
            s11_l <= '0; s12_l <= '0; s22_l <= '0; swo_l <= '0;
            mul_a_q <= '0; mul_b_q <= '0;
            prod_q <= '0; acc_q <= '0;
        end else begin
            done  <= 1'b0;
            co_we <= 5'b0;

            case (st)
                S_IDLE: begin
                    busy <= 1'b0;
                    p_re <= 1'b0;
                    if (start) begin
                        busy     <= 1'b1;
                        mode     <= '0;
                        nmod_lat <= n_modes;
                        step     <= 2'd0;
                        p_re     <= 1'b1;
                        p_mode   <= '0;
                        st       <= S_RD;
                    end
                end

                // 地址已经给出去了；参数 RAM 两级读延迟，再多等一拍
                S_RD: begin
                    p_re <= 1'b0;
                    st   <= S_W;
                end

                // 把 8 个参数锁进本地寄存器（乘法从 FF 出发，路径里不含 BSRAM 的 CLK->Q）
                //   只调制**最低的 MOD_TOP 个模态**：高模态的 theta 接近 pi/2，
                //   a12 = sin(theta) 已经贴着 1，一阶线性化很容易把它推出稳定域
                //   （|eig| > 1）；而揉弦的听感主要来自基频和前几个谐波，
                //   所以高模态直接不动（不写 = 保持表里的基值）。
                S_W: begin
                    a11_l <= p_a11;  a12_l <= p_a12;  a22_l <= p_a22;  wo_l  <= p_wo;
                    s11_l <= p_s11;  s12_l <= p_s12;  s22_l <= p_s22;  swo_l <= p_swo;
                    step  <= 2'd0;
                    st    <= (mode < MOD_TOP) ? S_LD : S_OUT;    // 高模态跳过 4 次乘加
                end

                // 操作数直接在这里按 step 选（寄存器输出，乘法从 FF 出发）
                //   不用组合 mux：之前那个 always_comb + always_ff 混着用，
                //   综合/仿真工具都能过，但 xvlog 编译会慢到十几分钟。
                S_LD: begin
                    case (step)
                        2'd0: begin mul_a_q <= lam_q; mul_b_q <= s11_l; end
                        2'd1: begin mul_a_q <= lam_q; mul_b_q <= s12_l; end
                        2'd2: begin mul_a_q <= lam_q; mul_b_q <= s22_l; end
                        default: begin mul_a_q <= lam_q; mul_b_q <= swo_l; end
                    endcase
                    st <= S_MUL;
                end

                S_MUL: begin
                    prod_q <= 64'(mul_a_q) * 64'(mul_b_q);
                    st     <= S_APPLY;
                end

                // step 0..3 = S11/S12/S22/Swo，每次只留**最后一步**（Swo）的结果：
                //   前面三步的结果在 S_OUT 里用 a11_l/s11_l 直接重算不划算，
                //   所以这里换成"每步算完立刻存到对应字段"的写法（见下）。
                S_APPLY: begin
                    case (step)
                        2'd0: a11_l <= a11_l + 32'(prod_q >>> 31);   // lambda*S11 -> Q28
                        2'd1: a12_l <= a12_l + 32'(prod_q >>> 29);   // lambda*S12 -> Q30
                        2'd2: a22_l <= a22_l + 32'(prod_q >>> 31);   // lambda*S22 -> Q28
                        default: wo_l <= wo_l + 32'(prod_q >>> 30);  // lambda*Swo -> Q29
                    endcase
                    if (step == 2'd3) begin
                        st <= S_OUT;
                    end else begin
                        step <= step + 2'd1;
                        st   <= S_LD;
                    end
                end

                S_OUT: begin
                    co_mode      <= mode[$clog2(N_MODES)-1:0];
                    co_wdata.a11 <= a11_l;
                    co_wdata.a12 <= a12_l;
                    // a21 = -a12，但**字段的 Q 不一样**：a12 是 Q30、a21 是 Q23
                    // （modal_step_pkg::SH_A12 / SH_A21），直接写 -a12_l 会让
                    // a21 大 2^7 倍 -> det = a11*a22 - a12*a21 > 1 -> 自激。
                    co_wdata.a21 <= -32'(a12_l >>> (modal_step_pkg::SH_A12 - modal_step_pkg::SH_A21));
                    co_wdata.a22 <= a22_l;
                    co_wdata.wo  <= wo_l;
                    co_we        <= (mode < MOD_TOP) ? 5'b11111 : 5'b00000;
                    if (mode + 1'b1 >= nmod_lat) begin
                        done <= 1'b1;
                        busy <= 1'b0;
                        st   <= S_IDLE;
                    end else begin
                        mode   <= mode + 1'b1;
                        step   <= 2'd0;
                        p_re   <= 1'b1;
                        p_mode <= mode[$clog2(N_MODES)-1:0] + 1'b1;
                        st     <= S_RD;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

    // 单乘法器的操作数 mux 已经并入 S_LD（见上），这里不再需要组合 mux

endmodule
