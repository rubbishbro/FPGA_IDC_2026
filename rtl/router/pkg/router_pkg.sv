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
        INST_PIANO_ABC  = 4'd10, // piano2: ABC; piano1 keeps its original ID/engine
        INST_GUITAR_ABC = 4'd11, // guitar2: F coefficients
        INST_NONE       = 4'hF
    } instrument_e;

    // GM notes remain external; compact resource slots follow ascending GM order.
    // 3'd7 is invalid. This lookup does not enable the drum resource/channel.
    function automatic logic [2:0] drum_index_of(input logic [7:0] gm_note);
        case (gm_note)
            8'd36: return 3'd0; // kick
            8'd38: return 3'd1; // snare
            8'd42: return 3'd2; // closed hi-hat
            8'd45: return 3'd3; // low tom
            8'd49: return 3'd4; // crash
            8'd59: return 3'd5; // ride
            default: return 3'd7;
        endcase
    endfunction

    function automatic logic [6:0] drum_note_of(input logic [2:0] index);
        case(index)
            0:return 36;1:return 38;2:return 42;3:return 45;4:return 49;5:return 59;
            default:return 127;
        endcase
    endfunction
    function automatic logic [4:0] resource_index_of(input instrument_e inst,input logic [7:0] note);
        return inst==INST_DRUMS ? {2'b0,drum_index_of(note)} : 5'(note-{1'b0,note_first(inst)});
    endfunction

    typedef enum logic [1:0] {
        REVERB_NONE     = 2'd0,
        REVERB_HALL     = 2'd1,
        REVERB_BATHROOM = 2'd2,
        REVERB_CHAMBER  = 2'd3
    } reverb_preset;

    // Validate the full transport/config value BEFORE narrowing to the enum.
    function automatic logic reverb_value_valid(input logic [31:0] value);
        case (value)
            32'(REVERB_NONE), 32'(REVERB_HALL),
            32'(REVERB_BATHROOM), 32'(REVERB_CHAMBER): return 1'b1;
            default: return 1'b0;
        endcase
    endfunction

    typedef struct packed {
        logic valid;
        logic [15:0] period;
        logic [31:0] a_step;
        logic [31:0] r_step;
    } sustain_cfg_t;
    function automatic logic is_sustain(input instrument_e inst);
        return inst==INST_FLUTE || inst==INST_TRUMPET ||
               inst==INST_CELLO || inst==INST_VIOLIN || inst==INST_OBOE;
    endfunction
    // Pitch modulation is independent of sustained vs plucked excitation.
    function automatic logic uses_mod1(input instrument_e inst);
        case(inst)
            INST_FLUTE,INST_TRUMPET,INST_CELLO,INST_VIOLIN,INST_OBOE,
            INST_BANJO,INST_MANDOLIN,INST_GUITAR_ABC:return 1'b1;
            default:return 1'b0; // both pianos, matrix guitar and drums
        endcase
    endfunction
    // Frozen per-instrument 32-note windows (通信协议约定 §3.2.1).
    // Slot index is relative to this first MIDI; it is never sent as the MIDI note.
    function automatic logic [6:0] note_first(input instrument_e inst);
        case(inst)
            INST_PIANO,INST_PIANO_ABC:return 44;
            INST_GUITAR,INST_GUITAR_ABC:return 44;
            INST_BANJO:return 48;
            INST_MANDOLIN,INST_VIOLIN:return 55;
            INST_FLUTE:return 60;
            INST_TRUMPET:return 51;
            INST_CELLO:return 44;
            INST_OBOE:return 58;
            default:return 0;
        endcase
    endfunction
    function automatic logic note_in_range(input instrument_e inst,input logic [7:0] note);
        if(inst==INST_DRUMS)return drum_index_of(note)<6;
        return inst!=INST_NONE && inst<=INST_GUITAR_ABC &&
               {1'b0,note_first(inst)}<=note && 9'(note)<9'(note_first(inst))+9'd32;
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
    // B类P1T1复用该存储：a11=lower, a12=a1_nom(Q24), a22=upper,
    // s12=K(signed25 Q3.22), swo=P1T1标记；其它字段为0。
    // 以下矩阵/斜率Q格式仅描述eng0吉他。
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
            INST_PIANO:return 64;
            INST_GUITAR:return 20;
            // 48 ABC + two 2-slot noise branches; each Flash seed independently
            // enables a branch. Zero seeds keep this fixed layout silent.
            INST_DRUMS:return 52;
            default:     return 48;      // eng1 首版计算前48；资源/状态仍按64模态存储
        endcase
    endfunction

    function automatic logic eng_sel(input instrument_e inst);
        case (inst)
            INST_PIANO, INST_GUITAR: return 1'b0;
            default:                 return 1'b1;
        endcase
    endfunction

    // Per-instrument output gain, signed Q4.12 (unity=4096).
    // Python calibration: MIDI69 for every pitched instrument, full level255,
    // single voice, modulation off, body enabled, reverb NONE; sliding20ms
    // max RMS=-12dBFS, full scale=1.0 Q24, PCM_HEADROOM_BITS=0.
    // Drums use rise3/pw8, loudest of six accepted-method hits (kick), one common trim.
    // Reference-note calibration does not guarantee full-range/polyphonic peaks.
    // Calculation artifact: build/reference_gain_calibration/results.json.
    function automatic logic signed [15:0] gain_q12_of(input instrument_e inst);
        case (inst)
            INST_PIANO:      return 16'sd18420;
            INST_GUITAR:     return 16'sd12843;
            INST_FLUTE:      return 16'sd1882;
            INST_TRUMPET:    return 16'sd2494;
            INST_CELLO:      return 16'sd1029;
            INST_VIOLIN:     return 16'sd1390;
            INST_OBOE:       return 16'sd3321;
            INST_DRUMS:      return 16'sd453; // rise3/pw8; kick=max20ms reference; production drum group trim.
            INST_BANJO:      return 16'sd1097;
            // TODO: MIDI69 calibrated peak is about +0.69dBFS at headroom0.
            // Accepted temporary overshoot; retain the requested RMS target.
            INST_MANDOLIN:   return 16'sd1543;
            INST_PIANO_ABC:  return 16'sd10992;
            INST_GUITAR_ABC: return 16'sd1165;
            default:         return 16'sd4096;
        endcase
    endfunction

endpackage

`endif
