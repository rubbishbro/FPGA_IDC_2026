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

    // ---- 二进制点（与 gen_golden.py 的 QF/XF/YF 一致）-----------------------
    // 以前这些数字只存在于 Python 系数生成器里；改用 rtl/math 的 sfp 接口声明
    // 静态格式信号后，必须在这里显式写出来，否则"格式"就又变成隐式约定。
    //   q / q' : s(32-24).24 = s8.24
    //   x      : s(32-28).28 = s4.28
    //   y      : s(64-40).40 = s24.40
    localparam int QF = 24;
    localparam int YF = 40;

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
    //
    // 舍入与饱和**直接用 rtl/math 的 fxp_pkg**：那份算术与 CORDIC/坐标变换共用，
    // 由 rtl/math/tb/tb_fp_ops.sv 证明与本文件原实现逐位一致（4060 项随机＋定点平局）。
    //
    // 注意两点：
    //  1. 这里只借用 fx_shift_rnd / fx_sat，**没有**用 fxp_pkg::fx_mul_rnd —— 后者的
    //     操作数是 64 位载体，两个信号相乘会变成 64×64 乘法器；我们保持 32×24 的窄乘法器。
    //  2. 不能 `import fxp_pkg::*`：它内部也有 CW（=64），会与本包的 CW（=24）冲突，
    //     所以一律用 `fxp_pkg::` 限定调用。

    // (a * m) >> s，移位前四舍五入（round-half-up，平局向 +∞）。
    //
    // 乘法前两个操作数先扩展到累加器宽度：SV 里 `a * m` 的结果宽度是操作数宽度的最大值
    // （不是 LHS 宽度），32 位状态乘 24 位系数会被截成 32 位，高位全丢。
    //
    // 这里整段都交给 rtl/math：fx_mul_rnd 的 64 位只是**载体**，实际操作数是 32/24 位，
    // 综合器会把未用到的位裁掉（本包此前用窄乘法 + fx_shift_rnd，两种写法的综合结果
    // 见 README 的对照表）。
    function automatic logic signed [AW-1:0] term(
        input logic signed [XW-1:0] a,
        input logic signed [CW-1:0] m,
        input logic        [SW-1:0] s
    );
        // 值 = a·m·2^-s；fx_mul_rnd 的 (fa,fb,fout) 放在整数标度上：0+0-(-s) = s
        term = fxp_pkg::fx_mul_rnd(a, m, 0, 0, -int'(s));
    endfunction

    // 饱和到 QW / VW 位有符号（fx_sat 的 qi=qo=0 即"不换小数点，只钳位"）
    function automatic logic signed [QW-1:0] sat_q(input logic signed [AW-1:0] v);
        sat_q = fxp_pkg::fx_sat(v, 0, 0, QW);
    endfunction

    function automatic logic signed [VW-1:0] sat_v(input logic signed [AW-1:0] v);
        sat_v = fxp_pkg::fx_sat(v, 0, 0, VW);
    endfunction

endpackage
