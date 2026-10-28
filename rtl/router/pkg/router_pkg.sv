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

    typedef struct packed {
        logic valid;
        logic [15:0] period;
        logic [31:0] a_step;
        logic [31:0] r_step;
    } sustain_cfg_t;
    function automatic logic is_sustain(input instrument_e inst);
        return inst inside {INST_FLUTE,INST_TRUMPET,INST_CELLO,INST_VIOLIN};
    endfunction
    // Legacy 16-note resource mapping. Banked resources supply their own map.
    function automatic logic [6:0] default_note(input int slot);
        case(slot)
            0:return 40;1:return 42;2:return 44;3:return 46;
            4:return 48;5:return 50;6:return 52;7:return 54;
            8:return 56;9:return 58;10:return 60;11:return 62;
            12:return 64;13:return 67;14:return 71;15:return 76;
            default:return 0;
        endcase
    endfunction
    function automatic logic [16*7-1:0] default_note_map();
        for(int i=0;i<16;i++) default_note_map[i*7 +:7]=default_note(i);
    endfunction

    // 调制参数记录（每个 槽×模态 一条，8 个字段 = flash 记录的 +32..+60）
    //
    // 模型：揉弦主要调**弦张力**，一阶近似下所有模态频率同比例变 alpha = 1+lambda，
    // 于是每个系数都能写成"基值 + lambda * 斜率"：
    //
    //     a11 = a11_0 + lambda*S11      a12 = a12_0 + lambda*S12
    //     a22 = a22_0 + lambda*S22      wo  = wo_0  + lambda*Swo
    //     a21 = -a12                    （a21 恒等于 -a12，不单独存）
    //     S21 = -2*a12_0 - S12          （由 a21 = -alpha^2 * a12 推出来，不单独存）
    //
    // 运行时只要 4 次乘加（老方案要 cos/sin 重构、每模态 15 步），而且**幂等**
    // （基值单独存，不依赖上一次写回去的值）。
    //
    // Q：基值 a11/a22 与 coeff_t 一致（Q28）、a12 Q30、wo Q29；
    //    斜率 S* 一律 Q29（整表 max|S| ≈ 1.7，±4 的范围还留 2× 余量）。
    typedef struct packed {
        logic signed [31:0] a11;      // a11 基值，Q28
        logic signed [31:0] a12;      // a12 基值，Q30
        logic signed [31:0] a22;      // a22 基值，Q28
        logic signed [31:0] wo;       // wo 基值，Q29
        logic signed [31:0] s11;      // d a11 / d lambda，Q29
        logic signed [31:0] s12;      // d a12 / d lambda，Q29
        logic signed [31:0] s22;      // d a22 / d lambda，Q29
        logic signed [31:0] swo;      // d wo  / d lambda，Q29
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
            default:     return 48;      // eng1 首版计算前48；资源/状态仍按64模态存储
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
