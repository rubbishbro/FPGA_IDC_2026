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
        INST_PIANO    = 4'd0,   // 模态引擎 + 无揉弦
        INST_GUITAR   = 4'd1,   // 模态引擎 + 揉弦（aftertouch）
        INST_E_PIANO  = 4'd2,
        INST_MARIMBA  = 4'd3,
        INST_VIBES    = 4'd4,
        INST_BASS     = 4'd5,   // 模态引擎 + 揉弦
        INST_CELESTA  = 4'd6,
        INST_PAD      = 4'd7,
        INST_NONE     = 4'hF
    } instrument_e;

    // 引擎选择：0 = modal_engine7，1 = eng_alt（队友的引擎，接口相同）
    // 现阶段只是占位分配，后面按乐器真实的合成方式调整
    function automatic logic eng_sel(input instrument_e inst);
        case (inst)
            INST_CELESTA, INST_PAD: return 1'b1;
            default:                return 1'b0;
        endcase
    endfunction

    // 是否挂揉弦（aftertouch）模块
    function automatic logic has_expr(input instrument_e inst);
        case (inst)
            INST_GUITAR, INST_BASS: return 1'b1;
            default:                return 1'b0;
        endcase
    endfunction

    // 参数表基地址 = 乐器号 × TABLE_SIZE（TABLE_SIZE 固定为钢琴表大小）
    function automatic int unsigned table_base(input instrument_e inst);
        return 32'(inst) * 32'd80;      // TODO: 正式值 = 每个乐器的槽数 x 模态数，先按 80 占位
    endfunction

endpackage

`endif
