// -----------------------------------------------------------------------------
// eng1_engine_env_top.sv -- ENG1 引擎 + 16 voice 包络的封装
//
// 这是四引擎顶层里“一个引擎”的完整块：
//   router → cfg/clr/seed
//   note_start/gate/choke/done/class/attack/release → voice_env_bank
//   x/active/n → eng1_engine_top
//   env_gain_vec → engine 内部 voice_sum 加权
//
// A/B/C 都用同一套 core；差别由 router 给的系数、x、class、envelope 参数体现。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module eng1_engine_env_top_ext #(
    parameter int NUM_SLOTS = 16,
    parameter int N_MODES   = 48,
    parameter int LANES     = 4,
    parameter int LOCAL     = (N_MODES + LANES - 1) / LANES,
    parameter int VW        = (NUM_SLOTS < 2) ? 1 : $clog2(NUM_SLOTS),
    parameter int MW        = (N_MODES < 2) ? 1 : $clog2(N_MODES),
    parameter int AW        = (NUM_SLOTS * LOCAL < 2) ? 1 : $clog2(NUM_SLOTS * LOCAL),
    parameter int SW        = (NUM_SLOTS * N_MODES < 2) ? 1 : $clog2(NUM_SLOTS * N_MODES + 1),
    parameter int REC_W     = 288
) (
    input  logic                       clk,
    input  logic                       rst_n,

    // router
    input  logic                       cfg_we,
    input  logic [VW-1:0]              cfg_voice,
    input  logic [MW-1:0]              cfg_mode,
    input  logic [REC_W-1:0]           cfg_data,
    input  logic                       clr_we,
    input  logic [VW-1:0]              clr_voice,
    input  logic [MW-1:0]              clr_mode,
    input  logic                       seed_we,
    input  logic [VW-1:0]              seed_voice,
    input  logic [MW-1:0]              seed_mode,
    input  logic [63:0]                seed_data,

    // aux 读 / 单字段写（B a1 刷新）
    input  logic                       aux_re,
    input  logic [VW-1:0]              aux_voice,
    input  logic [MW-1:0]              aux_mode,
    input  logic [REC_W-1:0]           aux_data,
    input  logic                       aux_valid,
    input  logic                       co_we,
    input  logic [VW-1:0]              co_voice,
    input  logic [MW-1:0]              co_mode,
    input  logic [3:0]                 co_field,
    input  logic [31:0]                co_wdata,

    // 包络控制（每 voice）
    input  logic [NUM_SLOTS-1:0]       note_start_mask,
    input  logic [NUM_SLOTS-1:0]       gate_mask,
    input  logic [NUM_SLOTS-1:0]       choke_mask,
    input  logic [NUM_SLOTS-1:0]       done_mask,
    input  logic [NUM_SLOTS*2-1:0]     class_vec,
    input  logic [NUM_SLOTS*24-1:0]    attack_vec,
    input  logic [NUM_SLOTS*24-1:0]    release_vec,

    // 作业口
    input  logic                       start,
    input  logic [NUM_SLOTS-1:0]       active_mask,
    input  logic [NUM_SLOTS*32-1:0]    x_vec,
    input  logic [NUM_SLOTS*16-1:0]    x_vel_vec,
    input  logic [NUM_SLOTS*MW-1:0]    n_modes_vec,
    output logic                       sample_ready,
    output logic                       done,
    output logic                       busy,

    // 共享 RAM 端口
    output logic [LANES-1:0]           ram_rd_re,
    output logic [LANES*AW-1:0]        ram_rd_addr,
    input  logic [LANES*REC_W-1:0]     ram_rd_data,
    output logic [LANES-1:0]           ram_st_we,
    output logic [LANES*AW-1:0]        ram_st_addr,
    output logic [LANES*64-1:0]        ram_st_data,

    // 结果
    output logic                       out_valid,
    output logic signed [63:0]         mix_sum,
    output logic [SW-1:0]              sat_count,
    output logic                       voice_valid,
    output logic [VW-1:0]              voice_id,
    output logic signed [63:0]         voice_sum
);

    logic [NUM_SLOTS*16-1:0] env_gain_vec;

    voice_env_bank #(.NUM_SLOTS(NUM_SLOTS)) u_env (
        .clk(clk), .rst_n(rst_n),
        .start_mask(note_start_mask),
        .gate_mask(gate_mask),
        .choke_mask(choke_mask),
        .done_mask(done_mask),
        .class_vec(class_vec),
        .attack_vec(attack_vec),
        .release_vec(release_vec),
        .env_gain_vec(env_gain_vec)
    );

    eng1_engine_top_ext #(
        .NUM_SLOTS(NUM_SLOTS), .N_MODES(N_MODES), .LANES(LANES),
        .LOCAL(LOCAL), .VW(VW), .MW(MW), .AW(AW), .SW(SW), .REC_W(REC_W)
    ) u_engine (
        .clk(clk), .rst_n(rst_n),
        .cfg_we(cfg_we), .cfg_voice(cfg_voice),
        .cfg_mode(cfg_mode), .cfg_data(cfg_data),
        .clr_we(clr_we), .clr_voice(clr_voice), .clr_mode(clr_mode),
        .seed_we(seed_we), .seed_voice(seed_voice),
        .seed_mode(seed_mode), .seed_data(seed_data),
        .aux_re(aux_re), .aux_voice(aux_voice), .aux_mode(aux_mode),
        .aux_data(aux_data), .aux_valid(aux_valid),
        .co_we(co_we), .co_voice(co_voice), .co_mode(co_mode),
        .co_field(co_field), .co_wdata(co_wdata),
        .start(start), .active_mask(active_mask),
        .x_vec(x_vec), .x_vel_vec(x_vel_vec), .n_modes_vec(n_modes_vec),
        .env_gain_vec(env_gain_vec),
        .sample_ready(sample_ready), .done(done), .busy(busy),
        .out_valid(out_valid), .mix_sum(mix_sum), .sat_count(sat_count),
        .voice_valid(voice_valid), .voice_id(voice_id), .voice_sum(voice_sum),
        .ram_rd_re(ram_rd_re), .ram_rd_addr(ram_rd_addr), .ram_rd_data(ram_rd_data),
        .ram_st_we(ram_st_we), .ram_st_addr(ram_st_addr), .ram_st_data(ram_st_data)
    );

endmodule
