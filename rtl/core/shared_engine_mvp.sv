// -----------------------------------------------------------------------------
// shared_engine_mvp.sv -- 单份 9x32 共享 RAM 的 MVP
//
// 只接 A（ENG1）和 E2 两个计算核，验证：
//   * 一份 shared_modal_ram（depth 16*20=320）
//   * A 只用 field0..4，E2 用 field0..8
//   * 一个 64-bit 尾部加法器
//   * class 选择由 sel_e2 控制，同一时刻只跑一个核
// B/C 后续复用同一个 ENG1 核，不在这里重复例化。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module shared_engine_mvp #(
    parameter int NUM_SLOTS   = 16,
    parameter int N_MODES_ABC = 48,
    parameter int N_MODES_E2  = 80,
    parameter int LANES       = 4,
    parameter int REC_W       = 288,
    parameter int VW          = (NUM_SLOTS < 2) ? 1 : $clog2(NUM_SLOTS),
    parameter int MW_A        = (N_MODES_ABC < 2) ? 1 : $clog2(N_MODES_ABC),
    parameter int MW_E2       = (N_MODES_E2 < 2) ? 1 : $clog2(N_MODES_E2 + 1),
    parameter int MW_RAM      = (N_MODES_E2 < 2) ? 1 : $clog2(N_MODES_E2 + 1),
    parameter int LOCAL_RAM   = (N_MODES_E2 + LANES - 1) / LANES,   // 20
    parameter int AW_A        = (NUM_SLOTS * LOCAL_RAM < 2) ? 1 : $clog2(NUM_SLOTS * LOCAL_RAM),
    parameter int AW_E2       = (NUM_SLOTS * ((N_MODES_E2 + LANES - 1) / LANES) < 2) ? 1 :
                                 $clog2(NUM_SLOTS * ((N_MODES_E2 + LANES - 1) / LANES)),
    parameter int AW_RAM      = (NUM_SLOTS * ((N_MODES_E2 + LANES - 1) / LANES) < 2) ? 1 :
                                 $clog2(NUM_SLOTS * ((N_MODES_E2 + LANES - 1) / LANES))
) (
    input  logic clk, rst_n,
    input  logic sel_e2,                 // 0=A, 1=E2；同一时刻只能一个

    // A load
    input  logic a_cfg_we,
    input  logic [VW-1:0] a_cfg_voice,
    input  logic [MW_A-1:0] a_cfg_mode,
    input  logic [REC_W-1:0] a_cfg_data,
    input  logic a_clr_we,
    input  logic [VW-1:0] a_clr_voice,
    input  logic [MW_A-1:0] a_clr_mode,
    input  logic a_seed_we,
    input  logic [VW-1:0] a_seed_voice,
    input  logic [MW_A-1:0] a_seed_mode,
    input  logic [63:0] a_seed_data,

    // A job
    input  logic a_start,
    input  logic [NUM_SLOTS-1:0] a_active,
    input  logic [NUM_SLOTS*32-1:0] a_x,
    input  logic [NUM_SLOTS*16-1:0] a_x_vel,
    input  logic [NUM_SLOTS*MW_A-1:0] a_nmodes,
    input  logic [NUM_SLOTS*16-1:0] a_env_gain,

    // E2 load
    input  logic e2_cfg_we,
    input  logic [VW-1:0] e2_cfg_voice,
    input  logic [MW_E2-1:0] e2_cfg_mode,
    input  logic [REC_W-1:0] e2_cfg_data,
    input  logic e2_clr_we,
    input  logic [VW-1:0] e2_clr_voice,
    input  logic [MW_E2-1:0] e2_clr_mode,
    input  logic e2_seed_we,
    input  logic [VW-1:0] e2_seed_voice,
    input  logic [MW_E2-1:0] e2_seed_mode,
    input  logic [63:0] e2_seed_data,

    // E2 job
    input  logic e2_start,
    input  logic [NUM_SLOTS-1:0] e2_active,
    input  logic [NUM_SLOTS-1:0] e2_zero,
    input  logic [NUM_SLOTS*32-1:0] e2_x,
    input  logic [NUM_SLOTS*MW_E2-1:0] e2_nmodes,

    output logic sample_ready,
    output logic busy,
    output logic done,
    output logic out_valid,
    output logic signed [63:0] mix_sum
);

    // ---- 共享 RAM 端口 ----
    logic [LANES-1:0]      rd_re;
    logic [LANES*AW_RAM-1:0] rd_addr;
    logic [LANES*REC_W-1:0]  rd_data;
    logic [LANES-1:0]      st_we;
    logic [LANES*AW_RAM-1:0] st_addr;
    logic [LANES*64-1:0]   st_data;

    logic cfg_we; logic [VW-1:0] cfg_voice; logic [MW_RAM-1:0] cfg_mode; logic [REC_W-1:0] cfg_data;
    logic clr_we; logic [VW-1:0] clr_voice; logic [MW_RAM-1:0] clr_mode;
    logic seed_we; logic [VW-1:0] seed_voice; logic [MW_RAM-1:0] seed_mode; logic [63:0] seed_data;

    assign cfg_we    = sel_e2 ? e2_cfg_we    : a_cfg_we;
    assign cfg_voice = sel_e2 ? e2_cfg_voice : a_cfg_voice;
    assign cfg_mode  = sel_e2 ? e2_cfg_mode  : {{(MW_RAM-MW_A){1'b0}}, a_cfg_mode};
    assign cfg_data  = sel_e2 ? e2_cfg_data  : a_cfg_data;
    assign clr_we    = sel_e2 ? e2_clr_we    : a_clr_we;
    assign clr_voice = sel_e2 ? e2_clr_voice : a_clr_voice;
    assign clr_mode  = sel_e2 ? e2_clr_mode  : {{(MW_RAM-MW_A){1'b0}}, a_clr_mode};
    assign seed_we    = sel_e2 ? e2_seed_we    : a_seed_we;
    assign seed_voice = sel_e2 ? e2_seed_voice : a_seed_voice;
    assign seed_mode  = sel_e2 ? e2_seed_mode  : {{(MW_RAM-MW_A){1'b0}}, a_seed_mode};
    assign seed_data  = sel_e2 ? e2_seed_data  : a_seed_data;

    shared_modal_ram #(
        .SLOTS(NUM_SLOTS), .MODES(N_MODES_E2), .LANES(LANES),
        .REC_W(REC_W), .FLD_W(32)
    ) u_ram (
        .clk(clk), .rst_n(rst_n),
        .state_first(sel_e2 ? 4'd7 : 4'd3),
        .cfg_we(cfg_we), .cfg_voice(cfg_voice), .cfg_mode(cfg_mode), .cfg_data(cfg_data),
        .st_we(st_we), .st_addr(st_addr), .st_data(st_data),
        .rd_re(rd_re), .rd_addr(rd_addr), .rd_data(rd_data),
        .clr_we(clr_we), .clr_voice(clr_voice), .clr_mode(clr_mode),
        .seed_we(seed_we), .seed_voice(seed_voice), .seed_mode(seed_mode), .seed_data(seed_data),
        .aux_re(1'b0), .aux_voice('0), .aux_mode('0), .aux_data(), .aux_valid(),
        .co_we(1'b0), .co_voice('0), .co_mode('0), .co_field('0), .co_wdata('0)
    );

    // A（ENG1）计算核
    logic [LANES-1:0] a_rd_re, a_st_we, e2_rd_re, e2_st_we;
    logic [LANES*AW_A-1:0] a_rd_addr, a_st_addr;
    logic [LANES*AW_E2-1:0] e2_rd_addr, e2_st_addr;
    logic [LANES*64-1:0] a_st_data, e2_st_data;
    logic a_ready, a_busy, a_done, a_valid;
    logic signed [63:0] a_mix;
    logic e2_ready, e2_busy, e2_done, e2_valid;
    logic signed [63:0] e2_mix;

    eng1_engine_top_ext #(
        .NUM_SLOTS(NUM_SLOTS), .N_MODES(N_MODES_ABC), .LANES(LANES),
        .LOCAL(LOCAL_RAM), .REC_W(REC_W)
    ) u_a (
        .clk(clk), .rst_n(rst_n),
        .cfg_we(a_cfg_we), .cfg_voice(a_cfg_voice), .cfg_mode(a_cfg_mode), .cfg_data(a_cfg_data),
        .clr_we(a_clr_we), .clr_voice(a_clr_voice), .clr_mode(a_clr_mode),
        .seed_we(a_seed_we), .seed_voice(a_seed_voice), .seed_mode(a_seed_mode), .seed_data(a_seed_data),
        .aux_re(1'b0), .aux_voice('0), .aux_mode('0), .aux_data(), .aux_valid(),
        .co_we(1'b0), .co_voice('0), .co_mode('0), .co_field('0), .co_wdata('0),
        .start(sel_e2 ? 1'b0 : a_start), .active_mask(a_active),
        .x_vec(a_x), .x_vel_vec(a_x_vel), .n_modes_vec(a_nmodes), .env_gain_vec(a_env_gain),
        .sample_ready(a_ready), .done(a_done), .busy(a_busy),
        .out_valid(a_valid), .mix_sum(a_mix), .sat_count(), .voice_valid(), .voice_id(), .voice_sum(),
        .ram_rd_re(a_rd_re), .ram_rd_addr(a_rd_addr), .ram_rd_data(rd_data),
        .ram_st_we(a_st_we), .ram_st_addr(a_st_addr), .ram_st_data(a_st_data)
    );

    eng2_engine_top_ext #(
        .NUM_SLOTS(NUM_SLOTS), .N_MODES(N_MODES_E2), .LANES(LANES), .REC_W(REC_W)
    ) u_e2 (
        .clk(clk), .rst_n(rst_n),
        .cfg_we(e2_cfg_we), .cfg_voice(e2_cfg_voice), .cfg_mode(e2_cfg_mode), .cfg_data(e2_cfg_data),
        .clr_we(e2_clr_we), .clr_voice(e2_clr_voice), .clr_mode(e2_clr_mode),
        .seed_we(e2_seed_we), .seed_voice(e2_seed_voice), .seed_mode(e2_seed_mode), .seed_data(e2_seed_data),
        .start(sel_e2 ? e2_start : 1'b0), .active_mask(e2_active), .zero_mask(e2_zero),
        .x_vec(e2_x), .n_modes_vec(e2_nmodes),
        .sample_ready(e2_ready), .done(e2_done), .busy(e2_busy),
        .out_valid(e2_valid), .mix_sum(e2_mix), .voice_valid(), .voice_id(), .voice_sum(),
        .ram_rd_re(e2_rd_re), .ram_rd_addr(e2_rd_addr), .ram_rd_data(rd_data),
        .ram_st_we(e2_st_we), .ram_st_addr(e2_st_addr), .ram_st_data(e2_st_data)
    );

    // 端口 mux：只把 active engine 接到共享 RAM
    assign rd_re   = sel_e2 ? e2_rd_re : a_rd_re;
    assign st_we   = sel_e2 ? e2_st_we : a_st_we;
    assign st_data = sel_e2 ? e2_st_data : a_st_data;

    // 每个 lane 单独做地址位宽扩展；不能把整个 lane 向量整体左补零。
    genvar gl;
    generate
        for (gl = 0; gl < LANES; gl = gl + 1) begin : g_addr
            assign rd_addr[gl*AW_RAM +: AW_RAM] =
                sel_e2 ? e2_rd_addr[gl*AW_E2 +: AW_E2] :
                         {{(AW_RAM-AW_A){1'b0}}, a_rd_addr[gl*AW_A +: AW_A]};
            assign st_addr[gl*AW_RAM +: AW_RAM] =
                sel_e2 ? e2_st_addr[gl*AW_E2 +: AW_E2] :
                         {{(AW_RAM-AW_A){1'b0}}, a_st_addr[gl*AW_A +: AW_A]};
        end
    endgenerate

    assign sample_ready = sel_e2 ? e2_ready : a_ready;
    assign busy         = sel_e2 ? e2_busy  : a_busy;
    assign done         = sel_e2 ? e2_done  : a_done;
    assign out_valid    = sel_e2 ? e2_valid : a_valid;

    // 一个尾部加法器；结果有效时累加
    always_ff @(posedge clk) begin
        if (!rst_n) mix_sum <= 64'sd0;
        else if (a_start || e2_start) mix_sum <= 64'sd0;
        else if (a_valid) mix_sum <= mix_sum + a_mix;
        else if (e2_valid) mix_sum <= mix_sum + e2_mix;
    end

endmodule
