// =============================================================================
// 文件 : engine_mux.sv
// 模块 : engine_mux
// 功能 : ABC/E2 二选一 + 共享 RAM + 尾部加法器
// 说明 : sel_e2 选择计算核；同一时刻只接一个核；唯一尾部加法器。
// =============================================================================
`timescale 1ns/1ps

module engine_mux #(
    parameter int NUM_SLOTS   = 16,
    parameter int N_MODES_ABC = 48,
    parameter int N_MODES_E2  = 80,
    parameter int LANES       = 4,
    parameter int REC_W       = 288,
    parameter int LOCAL_RAM   = (N_MODES_E2 + LANES - 1) / LANES,
    parameter int VW          = (NUM_SLOTS < 2) ? 1 : $clog2(NUM_SLOTS),
    parameter int MW_A        = (N_MODES_ABC < 2) ? 1 : $clog2(N_MODES_ABC),
    parameter int MW_E2       = (N_MODES_E2 < 2) ? 1 : $clog2(N_MODES_E2 + 1),
    parameter int MW_RAM      = (N_MODES_E2 < 2) ? 1 : $clog2(N_MODES_E2 + 1),
    parameter int AW_RAM       = (NUM_SLOTS * LOCAL_RAM < 2) ? 1 : $clog2(NUM_SLOTS * LOCAL_RAM)
) (
    input  logic clk, rst_n,
    input  logic sel_e2,
    input  logic cfg_sel_e2,

    // ABC load
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
    input  logic a_start,
    input  logic [NUM_SLOTS-1:0] a_active,
    input  logic [NUM_SLOTS*32-1:0] a_x,
    input  logic [NUM_SLOTS*MW_A-1:0] a_nmodes,

    // E2 load/job
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

    logic [LANES-1:0] abc_rd_re, abc_st_we, e2_rd_re, e2_st_we;
    logic [LANES*AW_RAM-1:0] abc_rd_addr, abc_st_addr, e2_rd_addr, e2_st_addr;
    logic [LANES*REC_W-1:0] rd_data;
    logic [LANES*64-1:0] abc_st_data, e2_st_data;
    logic abc_ready, abc_busy, abc_done, abc_valid, e2_ready, e2_busy, e2_done, e2_valid;
    logic signed [63:0] abc_mix, e2_mix;

    // shared RAM ports
    logic cfg_we, clr_we, seed_we;
    logic [VW-1:0] cfg_voice, clr_voice, seed_voice;
    logic [MW_RAM-1:0] cfg_mode, clr_mode, seed_mode;
    logic [REC_W-1:0] cfg_data; logic [63:0] seed_data;
    logic [3:0] state_first;

    assign cfg_we    = cfg_sel_e2 ? e2_cfg_we    : a_cfg_we;
    assign cfg_voice = cfg_sel_e2 ? e2_cfg_voice : a_cfg_voice;
    assign cfg_mode  = cfg_sel_e2 ? e2_cfg_mode  : {{(MW_RAM-MW_A){1'b0}}, a_cfg_mode};
    assign cfg_data  = cfg_sel_e2 ? e2_cfg_data  : a_cfg_data;
    assign clr_we    = cfg_sel_e2 ? e2_clr_we    : a_clr_we;
    assign clr_voice = cfg_sel_e2 ? e2_clr_voice : a_clr_voice;
    assign clr_mode  = cfg_sel_e2 ? e2_clr_mode  : {{(MW_RAM-MW_A){1'b0}}, a_clr_mode};
    assign seed_we    = cfg_sel_e2 ? e2_seed_we    : a_seed_we;
    assign seed_voice = cfg_sel_e2 ? e2_seed_voice : a_seed_voice;
    assign seed_mode  = cfg_sel_e2 ? e2_seed_mode  : {{(MW_RAM-MW_A){1'b0}}, a_seed_mode};
    assign seed_data  = cfg_sel_e2 ? e2_seed_data  : a_seed_data;
    assign state_first = cfg_sel_e2 ? 4'd7 : 4'd3;

    logic [LANES-1:0] ram_rd_re, ram_st_we;
    logic [LANES*AW_RAM-1:0] ram_rd_addr, ram_st_addr;
    logic [LANES*64-1:0] ram_st_data;

    assign ram_rd_re   = sel_e2 ? e2_rd_re   : abc_rd_re;
    assign ram_rd_addr = sel_e2 ? e2_rd_addr : abc_rd_addr;
    assign ram_st_we   = sel_e2 ? e2_st_we   : abc_st_we;
    assign ram_st_addr = sel_e2 ? e2_st_addr : abc_st_addr;
    assign ram_st_data = sel_e2 ? e2_st_data : abc_st_data;

    shared_modal_ram #(
        .SLOTS(NUM_SLOTS), .MODES(N_MODES_E2), .LANES(LANES),
        .REC_W(REC_W), .FLD_W(32)
    ) u_ram (
        .clk(clk), .rst_n(rst_n), .state_first(state_first),
        .cfg_we(cfg_we), .cfg_voice(cfg_voice), .cfg_mode(cfg_mode), .cfg_data(cfg_data),
        .st_we(ram_st_we), .st_addr(ram_st_addr), .st_data(ram_st_data),
        .rd_re(ram_rd_re), .rd_addr(ram_rd_addr), .rd_data(rd_data),
        .clr_we(clr_we), .clr_voice(clr_voice), .clr_mode(clr_mode),
        .seed_we(seed_we), .seed_voice(seed_voice), .seed_mode(seed_mode), .seed_data(seed_data),
        .aux_re(1'b0), .aux_voice('0), .aux_mode('0), .aux_data(), .aux_valid(),
        .co_we(1'b0), .co_voice('0), .co_mode('0), .co_field('0), .co_wdata('0)
    );

    pure_engine_abc #(
        .NUM_SLOTS(NUM_SLOTS), .N_MODES(N_MODES_ABC), .LANES(LANES),
        .LOCAL(LOCAL_RAM), .REC_W(REC_W)
    ) u_abc (
        .clk(clk), .rst_n(rst_n),
        .cfg_we(a_cfg_we), .cfg_voice(a_cfg_voice), .cfg_mode(a_cfg_mode), .cfg_data(a_cfg_data),
        .clr_we(a_clr_we), .clr_voice(a_clr_voice), .clr_mode(a_clr_mode),
        .seed_we(a_seed_we), .seed_voice(a_seed_voice), .seed_mode(a_seed_mode), .seed_data(a_seed_data),
        .start(sel_e2 ? 1'b0 : a_start), .active_mask(a_active),
        .x_vec(a_x), .n_modes_vec(a_nmodes),
        .sample_ready(abc_ready), .done(abc_done), .busy(abc_busy),
        .out_valid(abc_valid), .mix_sum(abc_mix),
        .ram_rd_re(abc_rd_re), .ram_rd_addr(abc_rd_addr), .ram_rd_data(rd_data),
        .ram_st_we(abc_st_we), .ram_st_addr(abc_st_addr), .ram_st_data(abc_st_data)
    );

    e2_engine #(
        .NUM_SLOTS(NUM_SLOTS), .N_MODES(N_MODES_E2), .LANES(LANES),
        .LOCAL(LOCAL_RAM), .REC_W(REC_W)
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

    assign sample_ready = sel_e2 ? e2_ready : abc_ready;
    assign busy         = sel_e2 ? e2_busy  : abc_busy;
    assign done         = sel_e2 ? e2_done  : abc_done;
    // 唯一尾部加法器；out_valid 与 mix_sum 同拍寄存，避免 valid 早一拍。
    logic out_valid_r;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            mix_sum    <= 64'sd0;
            out_valid_r <= 1'b0;
        end else begin
            out_valid_r <= !(a_start || e2_start) && (sel_e2 ? e2_valid : abc_valid);
            if (a_start || e2_start) mix_sum <= 64'sd0;
            else if (abc_valid) mix_sum <= mix_sum + abc_mix;
            else if (e2_valid)  mix_sum <= mix_sum + e2_mix;
        end
    end
    assign out_valid = out_valid_r;

endmodule
