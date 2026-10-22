// -----------------------------------------------------------------------------
// router_frontend_top.sv -- router_frontend + engine_mux 的新架构 MVP
//
// 只接 A 路径用于验证：config/fmap -> x -> engine_mux(A/E2) -> mix。
// 系数仍通过外部 cfg 口装载；旧 loader 尚未替换。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module router_frontend_top #(
    parameter int NUM_SLOTS   = 16,
    parameter int N_MODES_ABC = 48,
    parameter int N_MODES_E2  = 80,
    parameter int LANES       = 4,
    parameter int REC_W       = 288,
    parameter int VW          = (NUM_SLOTS < 2) ? 1 : $clog2(NUM_SLOTS),
    parameter int MW_ABC      = (N_MODES_ABC < 2) ? 1 : $clog2(N_MODES_ABC),
    parameter int MW_E2       = (N_MODES_E2 < 2) ? 1 : $clog2(N_MODES_E2 + 1)
) (
    input  logic clk, rst_n,
    input  logic cfg_valid,
    input  logic [3:0] cfg_instrument,
    input  logic [3:0] cfg_voice,
    input  logic [6:0] cfg_note,
    input  logic [7:0] cfg_velocity,
    input  logic [16*8-1:0] fmap,
    input  logic fmap_valid,

    // A coefficient load (MVP: external)
    input  logic a_cfg_we,
    input  logic [VW-1:0] a_cfg_voice,
    input  logic [MW_ABC-1:0] a_cfg_mode,
    input  logic [REC_W-1:0] a_cfg_data,
    input  logic a_clr_we,
    input  logic [VW-1:0] a_clr_voice,
    input  logic [MW_ABC-1:0] a_clr_mode,
    input  logic a_seed_we,
    input  logic [VW-1:0] a_seed_voice,
    input  logic [MW_ABC-1:0] a_seed_mode,
    input  logic [63:0] a_seed_data,
    input  logic a_start,
    input  logic [NUM_SLOTS-1:0] a_active,
    input  logic [NUM_SLOTS*MW_ABC-1:0] a_nmodes,

    // E2 (MVP: external)
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
    output logic signed [63:0] mix_sum,
    output logic [3:0] instrument_id,
    output logic [1:0] engine_sel,
    output logic key_pressed,
    output logic [15:0] velocity,
    output logic signed [31:0] x
);
    logic sel_e2;
    logic [NUM_SLOTS*32-1:0] abc_x;

    router_frontend u_front (
        .clk(clk), .rst_n(rst_n),
        .cfg_valid(cfg_valid), .cfg_instrument(cfg_instrument),
        .cfg_voice(cfg_voice), .cfg_note(cfg_note), .cfg_velocity(cfg_velocity),
        .fmap(fmap), .fmap_valid(fmap_valid),
        .instrument_id(instrument_id), .engine_sel(engine_sel),
        .coeff_base(), .ram_base(), .load_req(), .load_voice(), .load_note(),
        .load_velocity(), .load_addr(), .key_pressed(key_pressed),
        .velocity(velocity), .x(x), .x_valid()
    );

    always_comb begin
        abc_x = '0;
        abc_x[0*32 +: 32] = x;          // MVP: 只把 router x 送 slot0
    end
    assign sel_e2 = (engine_sel == 2'd3) && (|e2_active) && (a_active == '0);

    engine_mux #(
        .NUM_SLOTS(NUM_SLOTS), .N_MODES_ABC(N_MODES_ABC),
        .N_MODES_E2(N_MODES_E2), .LANES(LANES), .REC_W(REC_W)
    ) u_mux (
        .clk(clk), .rst_n(rst_n), .sel_e2(sel_e2),
        .a_cfg_we(a_cfg_we), .a_cfg_voice(a_cfg_voice), .a_cfg_mode(a_cfg_mode), .a_cfg_data(a_cfg_data),
        .a_clr_we(a_clr_we), .a_clr_voice(a_clr_voice), .a_clr_mode(a_clr_mode),
        .a_seed_we(a_seed_we), .a_seed_voice(a_seed_voice), .a_seed_mode(a_seed_mode), .a_seed_data(a_seed_data),
        .a_start(a_start), .a_active(a_active), .a_x(abc_x), .a_nmodes(a_nmodes),
        .e2_cfg_we(e2_cfg_we), .e2_cfg_voice(e2_cfg_voice), .e2_cfg_mode(e2_cfg_mode), .e2_cfg_data(e2_cfg_data),
        .e2_clr_we(e2_clr_we), .e2_clr_voice(e2_clr_voice), .e2_clr_mode(e2_clr_mode),
        .e2_seed_we(e2_seed_we), .e2_seed_voice(e2_seed_voice), .e2_seed_mode(e2_seed_mode), .e2_seed_data(e2_seed_data),
        .e2_start(e2_start), .e2_active(e2_active), .e2_zero(e2_zero), .e2_x(e2_x), .e2_nmodes(e2_nmodes),
        .sample_ready(sample_ready), .busy(busy), .done(done),
        .out_valid(out_valid), .mix_sum(mix_sum)
    );
endmodule
