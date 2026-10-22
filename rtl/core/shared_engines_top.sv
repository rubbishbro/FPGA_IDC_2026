// -----------------------------------------------------------------------------
// shared_engines_top.sv -- 纯 ABC 核 / E2 核 + 单份共享 RAM + 单尾部加法器
//
// A/B/C 共用 pure_engine_abc（同一递推），router 只给系数/x/n_modes。
// B/C 旧前端、a1、timer、seed 不再在本层例化。
// 同一时刻只选 ABC 或 E2；ABC 内部所有 active voice 由 pure_engine_abc TDM。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module shared_engines_top #(
    parameter int NUM_SLOTS   = 16,
    parameter int N_MODES_ABC = 48,
    parameter int N_MODES_E2  = 80,
    parameter int LANES       = 4,
    parameter int REC_W       = 288,
    parameter int LOCAL_RAM   = (N_MODES_E2 + LANES - 1) / LANES,
    parameter int VW          = (NUM_SLOTS < 2) ? 1 : $clog2(NUM_SLOTS),
    parameter int MW_ABC      = (N_MODES_ABC < 2) ? 1 : $clog2(N_MODES_ABC),
    parameter int MW_E2       = (N_MODES_E2 < 2) ? 1 : $clog2(N_MODES_E2 + 1)
) (
    input  logic clk, rst_n,

    // A/B/C 共享装载总线
    input  logic cfg_we,
    input  logic [1:0] cfg_engine,
    input  logic [VW-1:0] cfg_voice,
    input  logic [MW_ABC-1:0] cfg_mode,
    input  logic [REC_W-1:0] cfg_data,
    input  logic clr_we,
    input  logic [1:0] clr_engine,
    input  logic [VW-1:0] clr_voice,
    input  logic [MW_ABC-1:0] clr_mode,
    input  logic seed_we,
    input  logic [1:0] seed_engine,
    input  logic [VW-1:0] seed_voice,
    input  logic [MW_ABC-1:0] seed_mode,
    input  logic [63:0] seed_data,

    // A job
    input  logic [NUM_SLOTS-1:0] a_note_start,
    input  logic [NUM_SLOTS-1:0] a_gate,
    input  logic [NUM_SLOTS-1:0] a_active,
    input  logic [NUM_SLOTS*32-1:0] a_x,
    input  logic [NUM_SLOTS*16-1:0] a_x_vel,
    input  logic [NUM_SLOTS*MW_ABC-1:0] a_nmodes,

    // B job（前端已移除；x 由新 router 提供，当前顶层先接 0）
    input  logic [NUM_SLOTS*256-1:0] b_ctrl,
    input  logic [NUM_SLOTS*2-1:0] b_class,
    input  logic [NUM_SLOTS*16-1:0] b_vel,
    input  logic [NUM_SLOTS*16-1:0] b_theta,
    input  logic b_a1_enable,
    input  logic [15:0] b_ratio,
    input  logic [NUM_SLOTS-1:0] b_note_start,
    input  logic [NUM_SLOTS-1:0] b_gate,
    input  logic [NUM_SLOTS-1:0] b_active,
    input  logic [NUM_SLOTS*MW_ABC-1:0] b_nmodes,
    input  logic [NUM_SLOTS*32-1:0] b_x,

    // C job
    input  logic [NUM_SLOTS-1:0] c_note_start,
    input  logic [NUM_SLOTS-1:0] c_choke,
    input  logic [NUM_SLOTS-1:0] c_active,
    input  logic [NUM_SLOTS*20-1:0] c_len,
    input  logic [NUM_SLOTS*16-1:0] c_seed_vel,
    input  logic [NUM_SLOTS*24-1:0] c_attack,
    input  logic [NUM_SLOTS*24-1:0] c_release,
    input  logic [NUM_SLOTS*MW_ABC-1:0] c_nmodes,
    input  logic c_seed_load_start,
    input  logic [VW-1:0] c_seed_load_voice,
    input  logic [MW_ABC-1:0] c_seed_load_nmodes,
    input  logic [15:0] c_seed_base,
    input  logic [NUM_SLOTS*32-1:0] c_x,

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
    input  logic [NUM_SLOTS-1:0] e2_active,
    input  logic [NUM_SLOTS-1:0] e2_zero,
    input  logic [NUM_SLOTS*32-1:0] e2_x,
    input  logic [NUM_SLOTS*MW_E2-1:0] e2_nmodes,

    input  logic start,
    output logic sample_ready,
    output logic busy,
    output logic done,
    output logic out_valid,
    output logic signed [63:0] mix_sum
);

    // A/B/C 合成一个 ABC 作业
    logic [NUM_SLOTS-1:0] abc_active;
    logic [NUM_SLOTS*32-1:0] abc_x;
    logic [NUM_SLOTS*MW_ABC-1:0] abc_nmodes;
    logic sel_e2, abc_start, e2_start;

    assign abc_active = a_active | b_active | c_active;
    assign sel_e2 = (abc_active == '0) && (|e2_active);
    assign abc_start = start && !sel_e2 && (|abc_active);
    assign e2_start  = start &&  sel_e2;

    genvar gv;
    generate
        for (gv = 0; gv < NUM_SLOTS; gv = gv + 1) begin : g_abc_job
            always_comb begin
                if (a_active[gv]) begin
                    abc_x[gv*32 +: 32] = a_x[gv*32 +: 32];
                    abc_nmodes[gv*MW_ABC +: MW_ABC] = a_nmodes[gv*MW_ABC +: MW_ABC];
                end else if (b_active[gv]) begin
                    abc_x[gv*32 +: 32] = b_x[gv*32 +: 32];
                    abc_nmodes[gv*MW_ABC +: MW_ABC] = b_nmodes[gv*MW_ABC +: MW_ABC];
                end else begin
                    abc_x[gv*32 +: 32] = c_x[gv*32 +: 32];
                    abc_nmodes[gv*MW_ABC +: MW_ABC] = c_nmodes[gv*MW_ABC +: MW_ABC];
                end
            end
        end
    endgenerate

    engine_mux #(
        .NUM_SLOTS(NUM_SLOTS), .N_MODES_ABC(N_MODES_ABC),
        .N_MODES_E2(N_MODES_E2), .LANES(LANES), .REC_W(REC_W),
        .LOCAL_RAM(LOCAL_RAM)
    ) u_mux (
        .clk(clk), .rst_n(rst_n), .sel_e2(sel_e2),
        .a_cfg_we(cfg_we), .a_cfg_voice(cfg_voice), .a_cfg_mode(cfg_mode), .a_cfg_data(cfg_data),
        .a_clr_we(clr_we), .a_clr_voice(clr_voice), .a_clr_mode(clr_mode),
        .a_seed_we(seed_we), .a_seed_voice(seed_voice), .a_seed_mode(seed_mode), .a_seed_data(seed_data),
        .a_start(abc_start), .a_active(abc_active), .a_x(abc_x), .a_nmodes(abc_nmodes),
        .e2_cfg_we(e2_cfg_we), .e2_cfg_voice(e2_cfg_voice), .e2_cfg_mode(e2_cfg_mode), .e2_cfg_data(e2_cfg_data),
        .e2_clr_we(e2_clr_we), .e2_clr_voice(e2_clr_voice), .e2_clr_mode(e2_clr_mode),
        .e2_seed_we(e2_seed_we), .e2_seed_voice(e2_seed_voice), .e2_seed_mode(e2_seed_mode), .e2_seed_data(e2_seed_data),
        .e2_start(e2_start), .e2_active(e2_active), .e2_zero(e2_zero), .e2_x(e2_x), .e2_nmodes(e2_nmodes),
        .sample_ready(sample_ready), .busy(busy), .done(done),
        .out_valid(out_valid), .mix_sum(mix_sum)
    );

endmodule
