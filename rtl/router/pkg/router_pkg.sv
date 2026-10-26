// -----------------------------------------------------------------------------
// router_pkg.sv -- 路由器用的枚举与选择函数
//
//   乐器号 = 一个枚举。两个"路由点"（引擎 / 激励预处理）各自按它决定怎么走，
//   所以没有单独的 route 信号。
// -----------------------------------------------------------------------------

`ifndef ROUTER_PKG_SV
`define ROUTER_PKG_SV

package router_pkg;

    typedef enum logic [3:0] {
        INST_PIANO      = 4'd0, // 模态引擎 + 无揉弦
        INST_GUITAR     = 4'd1, // 模态引擎 + 揉弦（aftertouch）
        INST_FLUTE      = 4'd2,
        INST_TRUMPET    = 4'd3,
        INST_CELLO      = 4'd4,
        INST_VIOLIN     = 4'd5,
        INST_OBOE       = 4'd6,
        INST_DRUMS      = 4'd7, // iir引擎
        INST_BANJO      = 4'd8,
        INST_MANDOLIN   = 4'd9,
        INST_NONE       = 4'hF
    } instrument_e;

    typedef enum logic [1:0] {
        REVERB_BATHROOM,
        REVERB_HALL,
        REVERB_NONE
    } reverb_preset;

    // 调制参数记录（每个 槽×模态 一条，5 个字段）
    typedef struct packed {
        logic signed [31:0] c0;       // cos(theta0), Q1.30
        logic signed [31:0] s0;       // sin(theta0), Q1.30
        logic signed [31:0] gam;      // gamma, Q16.16
        logic signed [31:0] theta0;   // theta0 = omega0*dt, Q1.30
        logic signed [31:0] g;        // dt/theta0, Q1.30
        logic signed [31:0] k12;      // a12 的状态归一化系数 sq/sv, Q1.30
        logic signed [31:0] k21;      // a21 的状态归一化系数 sv/sq, Q1.30
    } mod_par_t;

    // 注意：**没有** table_base()。flash 的基地址公式在 loader 里（唯一契约）：
    //   base = inst * (SLOTS * N_MODES * 64)
    //   以前这里有个占位的 table_base()（内部写死 80），从没被调用过，已删 ——
    //   留着的话谁拿来用就会静默算错基地址。

    // 引擎选择：0 = eng0，1 = eng1（队友的引擎，接口相同）
    // 每个乐器实际用多少个模态（N_MODES 是表的物理深度，这个才是"用多少"）。
    // 加乐器/调模态数只改这里 —— 顶层不再有 n_modes 端口。
    function automatic int unsigned n_modes_of(input instrument_e inst);
        case (inst)
            INST_PIANO:  return 64;      // 2 x 32 = 64
            INST_GUITAR: return 20;      
            default:     return 64;      // 其余乐器还没有系数表，先按满配
        endcase
    endfunction

    function automatic logic eng_sel(input instrument_e inst);
        case (inst)
            INST_PIANO, INST_GUITAR: return 1'b0;
            default:                 return 1'b1;
        endcase
    endfunction

endpackage

`endif
