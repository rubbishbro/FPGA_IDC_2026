// -----------------------------------------------------------------------------
// b_x_pool.sv -- B 类多声部激励池（Round 9）
//
// 每个 B 声部一个 b_voice_ctrl；Control 记录里解析：
//   base_inc   = ctrl[95:64]   （UQ0.32，Round 9 新增的 B 保留区字段）
//   attack     = ctrl[39:16]   （UQ0.24）
//   release    = ctrl[63:40]   （UQ0.24）
//   period_T   = ctrl[15:0]    （L0 用；本模块不消费）
//   velocity   = vel_vec[voice]（UQ1.15，来自事件/voice runtime）
// 只有 class==1 的声部输出 x；A 的 x 由外部 mux，C 恒 0。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module b_x_pool #(
    parameter int NUM_VOICES = 32,
    parameter int VW = (NUM_VOICES < 2) ? 1 : $clog2(NUM_VOICES)
) (
    input  logic                      clk,
    input  logic                      rst_n,

    input  logic [NUM_VOICES*256-1:0] ctrl_vec,
    input  logic [NUM_VOICES*2-1:0]   class_vec,
    input  logic [NUM_VOICES*16-1:0]  vel_vec,
    input  logic [NUM_VOICES-1:0]     start_mask,
    input  logic [NUM_VOICES-1:0]     gate_mask,
    input  logic [15:0]               ratio,      // UQ1.15，1.0=0x8000

    output logic [NUM_VOICES*32-1:0]  x_vec
);

    genvar gv;
    generate
        for (gv = 0; gv < NUM_VOICES; gv = gv + 1) begin : g_voice
            wire [255:0] c        = ctrl_vec[gv*256 +: 256];
            wire [1:0]   cls      = class_vec[gv*2 +: 2];
            wire [31:0]  base_inc = c[95:64];
            wire [23:0]  atk      = c[39:16];
            wire [23:0]  rel      = c[63:40];
            wire [15:0]  vel      = vel_vec[gv*16 +: 16];
            wire         is_b     = (cls == 2'd1);

            logic signed [31:0] bx;
            logic               bimp;

            b_voice_ctrl u_ctrl (
                .clk(clk),
                .rst_n(rst_n),
                .start(start_mask[gv] && is_b),
                .gate(gate_mask[gv] && is_b),
                .base_inc(base_inc),
                .ratio(ratio),
                .attack_step(atk),
                .release_step(rel),
                .vel_q(vel),
                .x(bx),
                .imp(bimp)
            );

            assign x_vec[gv*32 +: 32] = is_b ? bx : 32'sd0;
        end
    endgenerate

endmodule
