// =============================================================================
// 文件 : pure_engine_abc.sv
// 模块 : pure_engine_abc
// 功能 : A/B/C 纯计算核封装
// 说明 : abc_engine + unity envelope；不含 b_front/b_a1/voice_env。
// =============================================================================
`timescale 1ns/1ps

module pure_engine_abc #(
    parameter int NUM_SLOTS = 16,
    parameter int N_MODES   = 48,
    parameter int LANES     = 4,
    parameter int LOCAL     = (N_MODES + LANES - 1) / LANES,
    parameter int REC_W     = 288,
    parameter int VW        = (NUM_SLOTS < 2) ? 1 : $clog2(NUM_SLOTS),
    parameter int MW        = (N_MODES < 2) ? 1 : $clog2(N_MODES),
    parameter int AW        = (NUM_SLOTS * LOCAL < 2) ? 1 : $clog2(NUM_SLOTS * LOCAL)
) (
    input  logic clk, rst_n,

    input  logic cfg_we,
    input  logic [VW-1:0] cfg_voice,
    input  logic [MW-1:0] cfg_mode,
    input  logic [REC_W-1:0] cfg_data,
    input  logic clr_we,
    input  logic [VW-1:0] clr_voice,
    input  logic [MW-1:0] clr_mode,
    input  logic seed_we,
    input  logic [VW-1:0] seed_voice,
    input  logic [MW-1:0] seed_mode,
    input  logic [63:0] seed_data,

    input  logic start,
    input  logic [NUM_SLOTS-1:0] active_mask,
    input  logic [NUM_SLOTS*32-1:0] x_vec,
    input  logic [NUM_SLOTS*MW-1:0] n_modes_vec,

    output logic sample_ready,
    output logic done,
    output logic busy,
    output logic out_valid,
    output logic signed [63:0] mix_sum,

    output logic [LANES-1:0] ram_rd_re,
    output logic [LANES*AW-1:0] ram_rd_addr,
    input  logic [LANES*REC_W-1:0] ram_rd_data,
    output logic [LANES-1:0] ram_st_we,
    output logic [LANES*AW-1:0] ram_st_addr,
    output logic [LANES*64-1:0] ram_st_data
);

    abc_engine #(
        .NUM_SLOTS(NUM_SLOTS), .N_MODES(N_MODES), .LANES(LANES),
        .LOCAL(LOCAL), .REC_W(REC_W)
    ) u_engine (
        .clk(clk), .rst_n(rst_n),
        .cfg_we(cfg_we), .cfg_voice(cfg_voice), .cfg_mode(cfg_mode), .cfg_data(cfg_data),
        .clr_we(clr_we), .clr_voice(clr_voice), .clr_mode(clr_mode),
        .seed_we(seed_we), .seed_voice(seed_voice), .seed_mode(seed_mode), .seed_data(seed_data),
        .aux_re(1'b0), .aux_voice('0), .aux_mode('0), .aux_data('0), .aux_valid(1'b0),
        .co_we(1'b0), .co_voice('0), .co_mode('0), .co_field('0), .co_wdata('0),
        .start(start), .active_mask(active_mask), .x_vec(x_vec),
        .x_vel_vec({NUM_SLOTS{16'h8000}}),
        .n_modes_vec(n_modes_vec),
        .env_gain_vec({NUM_SLOTS{16'h8000}}),   // 包络已移到 engine 外
        .sample_ready(sample_ready), .done(done), .busy(busy),
        .out_valid(out_valid), .mix_sum(mix_sum), .sat_count(),
        .voice_valid(), .voice_id(), .voice_sum(),
        .ram_rd_re(ram_rd_re), .ram_rd_addr(ram_rd_addr), .ram_rd_data(ram_rd_data),
        .ram_st_we(ram_st_we), .ram_st_addr(ram_st_addr), .ram_st_data(ram_st_data)
    );

endmodule
