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

    // ---- 定点格式 ------------------------------------------------------------
    // 系数：尾数 CW 位有符号（|mant| < 2^(CW-1)）。小数点由**字段**决定（编译期常量），
    // 所以系数记录里没有移位字段 —— 7 个字段各一个 Q，见下面的 SH_*。
    localparam int CW = 32;

    // 注意：尾数上限由 fxp_pkg 的 64 位载体决定 —— 32 位状态 x 32 位尾数 = 64 位
    // 正好装满；36 位尾数会得到 68 位乘积而被截断（实测会导致数值不符）。
    //
    // 逐字段 Q（小数位）。取值依据（`tools/piano_flash.py --verify` 实测整张表）：
    //   字段        整表 max|v|   "刚好装下 +2x 余量"的 Q   现在用的 Q   用掉 int32
    //   a11/a22     1.00         30                        28          12.5%
    //   a12         1.00         30                        30          50%
    //   a21         1.00         30                        23           0.4%
    //   gq          1.36e-2      36                        31           1.4%
    //   gv          2.53e-2      35                        27           0.1%
    //   wo          0.99         30                        15           0.0%
    // 也就是说：a12 顶到 50%，其余都还很松 —— 松的代价只是"少几位精度"，
    // 不会溢出；要收紧就按上表调，**记得同时改 tools/piano_flash.py 的 SH**。
    localparam int SH_A11 = 28;
    localparam int SH_A12 = 30;
    localparam int SH_A21 = 23;
    localparam int SH_A22 = 28;
    // gq/gv/wo 只有引擎读、只有系数表写（modulation 不碰），所以按实测余量收紧了：
    //   gq 原来 Q31 只用 1.4% -> Q35（22%）
    //   gv 原来 Q27 只用 0.1% -> Q34（16%）
    //   wo 原来 Q15 只用 0.0% -> Q29（25%）
    // a11/a12/a21/a22 **不动**：`parts/modulation.sv` 会写这四个字段，它的内部链路
    // 是按 Q30/Q23 调的，改 Q 必须连它的输出移位一起改 —— 等吉他系数表能跑通再说。
    localparam int SH_GQ  = 35;
    localparam int SH_GV  = 34;
    localparam int SH_WO  = 29;

    // 状态与激励：32 位有符号。状态的小数点由**生成系数时**决定（每模态归一化），
    // 模块本身与格式无关，只做整数运算。
    localparam int QW = 32;         // q
    localparam int VW = 32;         // q_dot
    localparam int XW = 32;         // 激励（共享；x = x_phys * 2^XF 的整数）
    // **XF 必须等于 QF**：RTL 里 gq·x 是 (x_int*gq_int)>>>SH_GQ，结果直接被加进
    // q_int；若 XF≠QF，注入量就差 2^(XF−QF)。实测 XF=28/QF=24 时状态峰值是
    // Python 模型的 16.3 倍（0.452 vs 0.0277），改回 24 后一致。
    // 改了 XF 记得同步 exc_router 的 SHIFT（物理激励 x = fmap<<SHIFT / 2^XF）。
    localparam int XF = 24;

    localparam int AW = 64;         // 乘加累加器
    localparam int YW = 64;         // 输出（本模态的琴桥力项；由 bank 求和后统一移位）

    // ---- 二进制点 ------------------------------------------------------------
    // 三个点统一成 Q24（以前 XF=28 / YF=40 是占位值）：
    //   q / q' : s8.24
    //   x      : s8.24
    //   y      : s(64-24).24   —— y = Σ wo·q，量级 ≈ 0.1~0.7，正好用满 Q24
    // 实测：单音一个音 Σ|y| 峰值 ≈ 0.27，16 键齐按 ≈ 0.68（都在 ±1 内）。
    localparam int QF = 24;
    localparam int YF = 24;

    // ---- 每模态系数（一个 packed 结构体 = 一个模态的常数记录）-----------------
    // 命名：aXY 是 2x2 矩阵元，sXY 是它的移位；gq/gv 是输入增益，wo 是输出权重。
    typedef struct packed {
        logic signed [CW-1:0] a11;
        logic signed [CW-1:0] a12;
        logic signed [CW-1:0] a21;
        logic signed [CW-1:0] a22;
        logic signed [CW-1:0] gq;
        logic signed [CW-1:0] gv;
        logic signed [CW-1:0] wo;
    } coeff_t;

    typedef struct packed {
        logic signed [QW-1:0] q;
        logic signed [VW-1:0] qdot;
    } mode_state_t;

    // ---- 算术（放在包里，保证"并行一步"与"时分复用 bank"逐位一致）-------------
    //
    // 舍入与饱和**直接用 rtl/math 的 fxp_pkg**：那份算术与 CORDIC/坐标变换共用，
    // 由 rtl/math/tb/tb_fp_ops.sv 证明与本文件原实现逐位一致（4060 项随机＋定点平局）。
    //
    // 注意两点：
    //  1. 这里只借用 fx_shift_rnd / fx_sat，**没有**用 fxp_pkg::fx_mul_rnd —— 后者的
    //     操作数是 64 位载体，两个信号相乘会变成 64×64 乘法器；我们保持 32×24 的窄乘法器。
    //  2. 不能 `import fxp_pkg::*`：它内部也有 CW（=64），会与本包的 CW（=32）冲突，
    //     所以一律用 `fxp_pkg::` 限定调用。

    // (a * m) >> s，移位前四舍五入（round-half-up，平局向 +∞）。
    //
    // 乘法前两个操作数先扩展到累加器宽度：SV 里 `a * m` 的结果宽度是操作数宽度的最大值
    // （不是 LHS 宽度），32 位状态乘 24 位系数会被截成 32 位，高位全丢。
    //
    // 这里整段都交给 rtl/math：fx_mul_rnd 的 64 位只是**载体**，实际操作数是 32/24 位，
    // 综合器会把未用到的位裁掉（本包此前用窄乘法 + fx_shift_rnd，两种写法的综合结果
    // 见 README 的对照表）。
    // 舍入 + 算术右移。**不直接**用 fxp_pkg::fx_shift_rnd 吃 int：它的 d 是 int，
    // 会把 6 位移位量拓宽成 32 位，综合出更宽的桶形移位器（实测 Fmax 掉约 13%）。
    // 语义与 fx_shift_rnd 完全一致（见 rtl/math/tb/tb_fp_ops.sv 的逐位比对）。
    function automatic logic signed [AW-1:0] term(
        input logic signed [XW-1:0] a,
        input logic signed [CW-1:0] m,
        input logic        [5:0]    s          // 字段 Q（6 位：TDM 里 k 是运行量）
    );
        logic signed [AW-1:0] aa, mm, prod;
        aa   = a;
        mm   = m;
        prod = aa * mm;
        term = (prod + ((s == 0) ? 64'sd0 : (64'sd1 <<< (s - 1)))) >>> s;
    endfunction

    // 饱和到 QW / VW 位有符号（fx_sat 的 qi=qo=0 即"不换小数点，只钳位"）
    function automatic logic signed [QW-1:0] sat_q(input logic signed [AW-1:0] v);
        sat_q = fxp_pkg::fx_sat(v, 0, 0, QW);
    endfunction

    function automatic logic signed [VW-1:0] sat_v(input logic signed [AW-1:0] v);
        sat_v = fxp_pkg::fx_sat(v, 0, 0, VW);
    endfunction

endpackage
