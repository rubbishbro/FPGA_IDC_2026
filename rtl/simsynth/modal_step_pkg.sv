// -----------------------------------------------------------------------------
// modal_step_pkg.sv -- 弦模态递推一步计算所需的类型与定点格式（吉他/钢琴共用）
//
// 算法来源：sythsound/MATH.md 6.1 节（分段常力精确更新），实现与
// sythsound/sim_piano.py :: StringSim.sim_step 和 sythsound/sim_guitar.py ::
// StringSim.sim_step 完全一致。两者的递推是同一条式子，区别只有输入项：
//   * 钢琴：外力 F(t) 通过 static_weight 进入（打击）
//   * 吉他：拨弦是初始条件（q += K_n），可以同样用输入项表达（gq = K_n, x = 1）
//
// 递推（每模态、每采样一步）：
//
//   q' = a11*q + a12*v + gq*x
//   v' = a21*q + a22*v + gv*x
//   y  = wo*q                      ← 本模态对琴桥力的贡献（用更新前的 q，与 Python 一致）
//
// 其中 a12/a21 已折算 q 与 v 各自的状态定标（相似变换 sq/sv），因此四个矩阵元都是
// O(1) 量级；gq/gv/wo 跨模态动态范围很大，所以**每个常量自带指数**（尾数 + 移位），
// 这在硬件上只是移位，不花资源（见 _analysis/fpga_fixed_point.md 3.1）。
//
// 本包只放类型和格式，不含任何乐器特有的东西 —— 吉他/钢琴的差别全部在系数值里。
// -----------------------------------------------------------------------------

`timescale 1ns/1ps      // 仅仿真需要（xsim 要求全设计统一有 timescale；综合忽略）

package modal_step_pkg;

    // ---- 定点格式（v1 冻结值）------------------------------------------------
    // 系数：尾数 CW 位有符号（|mant| < 2^(CW-1)），移位 SW 位无符号（0..63）
    localparam int CW = 24;
    localparam int SW = 6;

    // 状态与激励：32 位有符号。状态的小数点由**生成系数时**决定（每模态归一化，
    // sq = 2^QF/peak_q），模块本身与格式无关，只做整数运算。
    localparam int QW = 32;         // q
    localparam int VW = 32;         // q_dot
    localparam int XW = 32;         // 激励（共享；x = x_phys * 2^XF 的整数）
    localparam int XF = 28;         // 激励的小数位（供系数生成使用，模块不关心）

    localparam int AW = 64;         // 乘加累加器
    localparam int YW = 64;         // 输出（本模态的琴桥力项；由 bank 求和后统一移位）

    // ---- 每模态系数（一个 packed 结构体 = 一个模态的常数记录）-----------------
    // 命名：aXY 是 2x2 矩阵元，sXY 是它的移位；gq/gv 是输入增益，wo 是输出权重。
    typedef struct packed {
        logic signed [CW-1:0] a11;  logic [SW-1:0] s11;
        logic signed [CW-1:0] a12;  logic [SW-1:0] s12;
        logic signed [CW-1:0] a21;  logic [SW-1:0] s21;
        logic signed [CW-1:0] a22;  logic [SW-1:0] s22;
        logic signed [CW-1:0] gq;   logic [SW-1:0] sgq;
        logic signed [CW-1:0] gv;   logic [SW-1:0] sgv;
        logic signed [CW-1:0] wo;   logic [SW-1:0] swo;
    } coeff_t;

    typedef struct packed {
        logic signed [QW-1:0] q;
        logic signed [VW-1:0] qdot;
    } mode_state_t;

    // ---- 算术（放在包里，保证"并行一步"与"时分复用 bank"逐位一致）-------------

    // (a * m) >> s，移位前四舍五入；s = 0 时不加偏置。
    //
    // 注意：两个操作数**先扩展到累加器宽度再相乘**。SV 里 `a * m` 的结果宽度是操作数
    // 宽度的最大值（不是 LHS 宽度），32 位状态乘 24 位系数会被截成 32 位，高位全丢 ——
    // 这是本目录第一版被 xsim 抓到的真实 bug。
    function automatic logic signed [AW-1:0] term(
        input logic signed [XW-1:0] a,
        input logic signed [CW-1:0] m,
        input logic        [SW-1:0] s
    );
        logic signed [AW-1:0] aa, mm, prod, half;
        aa   = a;
        mm   = m;
        prod = aa * mm;
        half = (s == 0) ? '0 : ({{(AW-1){1'b0}}, 1'b1} <<< (s - 6'd1));
        term = (prod + half) >>> s;
    endfunction

    function automatic logic signed [QW-1:0] sat_q(input logic signed [AW-1:0] v);
        if (v > $signed({1'b0, {(QW-1){1'b1}}}))       sat_q = {1'b0, {(QW-1){1'b1}}};
        else if (v < $signed({1'b1, {(QW-1){1'b0}}}))  sat_q = {1'b1, {(QW-1){1'b0}}};
        else                                          sat_q = v[QW-1:0];
    endfunction

    function automatic logic signed [VW-1:0] sat_v(input logic signed [AW-1:0] v);
        if (v > $signed({1'b0, {(VW-1){1'b1}}}))       sat_v = {1'b0, {(VW-1){1'b1}}};
        else if (v < $signed({1'b1, {(VW-1){1'b0}}}))  sat_v = {1'b1, {(VW-1){1'b0}}};
        else                                          sat_v = v[VW-1:0];
    endfunction

endpackage
