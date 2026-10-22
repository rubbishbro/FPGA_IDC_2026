// -----------------------------------------------------------------------------
// router_pkg.sv -- router 的统一 instrument 编号/地址映射
//
// 注意：instrument_class 映射是当前 MVP 的约定，后续可由 config/LUT 替换。
// 不再使用 engine_id 做二次分发；engine_sel 由 instrument_id 派生。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
package router_pkg;

    typedef enum logic [1:0] {
        ENGINE_A  = 2'd0,
        ENGINE_B  = 2'd1,
        ENGINE_C  = 2'd2,
        ENGINE_E2 = 2'd3
    } engine_class_t;

    localparam int INSTRUMENT_W = 4;
    localparam int COEFF_STRIDE = 16'd8192;
    localparam int RAM_STRIDE   = 16'd320;

    function automatic engine_class_t engine_class_of(input logic [INSTRUMENT_W-1:0] id);
        // MVP: 0/1/2/3 对应 A/B/C/E2；后续用 config 表替换。
        case (id)
            4'd0: engine_class_of = ENGINE_A;
            4'd1: engine_class_of = ENGINE_B;
            4'd2: engine_class_of = ENGINE_C;
            4'd3: engine_class_of = ENGINE_E2;
            default: engine_class_of = ENGINE_A;
        endcase
    endfunction

    function automatic logic [15:0] coeff_base_of(input logic [INSTRUMENT_W-1:0] id);
        coeff_base_of = {{(16-INSTRUMENT_W){1'b0}}, id} * COEFF_STRIDE;
    endfunction

    function automatic logic [15:0] ram_base_of(input logic [INSTRUMENT_W-1:0] id);
        ram_base_of = {{(16-INSTRUMENT_W){1'b0}}, id} * RAM_STRIDE;
    endfunction

endpackage
