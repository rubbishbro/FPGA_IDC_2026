// =============================================================================
// 文件 : modal_record_pkg.sv
// 模块 : modal_record_pkg
// 功能 : 9×32 统一记录字段/掩码/函数
// 说明 : ABC 用 G,a1,a2,y1,y2；E2 用 a11,a12,a21,a22,gq,gv,wo,q,qdot。
// =============================================================================
`timescale 1ns/1ps

package modal_record_pkg;

    localparam int FLD_W = 32;
    localparam int N_FLD = 9;
    localparam int REC_W = FLD_W * N_FLD;   // 288

    // ---- ENG1 字段 --------------------------------------------------------
    localparam int E1_G   = 0;
    localparam int E1_A1  = 1;
    localparam int E1_A2  = 2;
    localparam int E1_Y1  = 3;
    localparam int E1_Y2  = 4;
    // 5..8 保留

    // ---- ENG2 字段 --------------------------------------------------------
    localparam int E2_A11 = 0;
    localparam int E2_A12 = 1;
    localparam int E2_A21 = 2;
    localparam int E2_A22 = 3;
    localparam int E2_GQ  = 4;
    localparam int E2_GV  = 5;
    localparam int E2_WO  = 6;
    localparam int E2_Q   = 7;
    localparam int E2_QD  = 8;

    // ---- 状态字段掩码（bit i = 第 i 个 32-bit 字段）-----------------------
    localparam logic [N_FLD-1:0] E1_STATE_MASK = 9'b000011000;  // y1,y2
    localparam logic [N_FLD-1:0] E2_STATE_MASK = 9'b110000000;  // q,qdot

    // ---- 纯函数：取/写字段 ------------------------------------------------
    function automatic logic [FLD_W-1:0] rec_get(
        input logic [REC_W-1:0] r,
        input int               idx
    );
        rec_get = r[idx*FLD_W +: FLD_W];
    endfunction

    function automatic logic signed [FLD_W-1:0] rec_get_s(
        input logic [REC_W-1:0] r,
        input int               idx
    );
        rec_get_s = $signed(r[idx*FLD_W +: FLD_W]);
    endfunction

    function automatic logic [REC_W-1:0] rec_set(
        input logic [REC_W-1:0] r,
        input int               idx,
        input logic [FLD_W-1:0] v
    );
        logic [REC_W-1:0] t;
        begin
            t = r;
            t[idx*FLD_W +: FLD_W] = v;
            rec_set = t;
        end
    endfunction

    // 把掩码内的字段清零，保留其他字段（用于 clear 状态）
    function automatic logic [REC_W-1:0] rec_clear_fields(
        input logic [REC_W-1:0] r,
        input logic [N_FLD-1:0] mask
    );
        logic [REC_W-1:0] t;
        begin
            t = r;
            for (int i = 0; i < N_FLD; i = i + 1)
                if (mask[i]) t[i*FLD_W +: FLD_W] = {FLD_W{1'b0}};
            rec_clear_fields = t;
        end
    endfunction

    // 写入两个状态字段（状态字段必须是相邻的；ENG1=3/4，ENG2=7/8）
    function automatic logic [REC_W-1:0] rec_set_state(
        input logic [REC_W-1:0] r,
        input int               first,
        input logic [63:0]      state
    );
        logic [REC_W-1:0] t;
        begin
            t = r;
            t[first*FLD_W +: FLD_W]         = state[31:0];
            t[(first+1)*FLD_W +: FLD_W]     = state[63:32];
            rec_set_state = t;
        end
    endfunction

endpackage
