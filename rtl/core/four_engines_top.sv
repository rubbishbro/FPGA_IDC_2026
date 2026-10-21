// -----------------------------------------------------------------------------
// four_engines_top.sv -- A/B/C + ENG2 四引擎并列顶层
//
// ABC 共用一条 cfg/clr/seed 总线（cfg_engine 选 A/B/C）；
// ENG2 有独立 cfg/clr/seed 总线。
// 四个引擎各 16 slot；结果经 engine_mix_sum 汇总。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module four_engines_top #(
    parameter int NUM_SLOTS   = 16,
    parameter int N_MODES_ABC = 48,
    parameter int N_MODES_E2  = 80,
    parameter int LANES       = 4,
    parameter int REC_W       = 288,
    parameter     C_SEED_FILE = "",
    parameter int VW          = (NUM_SLOTS < 2) ? 1 : $clog2(NUM_SLOTS),
    parameter int MW_ABC      = (N_MODES_ABC < 2) ? 1 : $clog2(N_MODES_ABC),
    parameter int MW_E2       = (N_MODES_E2 < 2) ? 1 : $clog2(N_MODES_E2 + 1)
) (
    input  logic                       clk,
    input  logic                       rst_n,

    // A/B/C 共享装载总线
    input  logic                       cfg_we,
    input  logic [1:0]                 cfg_engine,
    input  logic [VW-1:0]              cfg_voice,
    input  logic [MW_ABC-1:0]          cfg_mode,
    input  logic [REC_W-1:0]           cfg_data,
    input  logic                       clr_we,
    input  logic [1:0]                 clr_engine,
    input  logic [VW-1:0]              clr_voice,
    input  logic [MW_ABC-1:0]          clr_mode,
    input  logic                       seed_we,
    input  logic [1:0]                 seed_engine,
    input  logic [VW-1:0]              seed_voice,
    input  logic [MW_ABC-1:0]          seed_mode,
    input  logic [63:0]                seed_data,

    // A
    input  logic [NUM_SLOTS-1:0]       a_note_start,
    input  logic [NUM_SLOTS-1:0]       a_gate,
    input  logic [NUM_SLOTS-1:0]       a_active,
    input  logic [NUM_SLOTS*32-1:0]    a_x,
    input  logic [NUM_SLOTS*16-1:0]    a_x_vel,
    input  logic [NUM_SLOTS*MW_ABC-1:0] a_nmodes,

    // B
    input  logic [NUM_SLOTS*256-1:0]   b_ctrl,
    input  logic [NUM_SLOTS*2-1:0]     b_class,
    input  logic [NUM_SLOTS*16-1:0]    b_vel,
    input  logic [NUM_SLOTS*16-1:0]    b_theta,
    input  logic                       b_a1_enable,
    input  logic [15:0]                b_ratio,
    input  logic [NUM_SLOTS-1:0]       b_note_start,
    input  logic [NUM_SLOTS-1:0]       b_gate,
    input  logic [NUM_SLOTS-1:0]       b_active,
    input  logic [NUM_SLOTS*MW_ABC-1:0] b_nmodes,

    // C
    input  logic [NUM_SLOTS-1:0]       c_note_start,
    input  logic [NUM_SLOTS-1:0]       c_choke,
    input  logic [NUM_SLOTS*20-1:0]    c_len,
    input  logic [NUM_SLOTS*16-1:0]    c_seed_vel,
    input  logic [NUM_SLOTS*24-1:0]    c_attack,
    input  logic [NUM_SLOTS*24-1:0]    c_release,
    input  logic [NUM_SLOTS*MW_ABC-1:0] c_nmodes,
    input  logic                       c_seed_load_start,
    input  logic [VW-1:0]              c_seed_load_voice,
    input  logic [MW_ABC-1:0]          c_seed_load_nmodes,
    input  logic [15:0]                c_seed_base,

    // ENG2 独立装载
    input  logic                       e2_cfg_we,
    input  logic [VW-1:0]              e2_cfg_voice,
    input  logic [MW_E2-1:0]           e2_cfg_mode,
    input  logic [REC_W-1:0]           e2_cfg_data,
    input  logic                       e2_clr_we,
    input  logic [VW-1:0]              e2_clr_voice,
    input  logic [MW_E2-1:0]           e2_clr_mode,
    input  logic                       e2_seed_we,
    input  logic [VW-1:0]              e2_seed_voice,
    input  logic [MW_E2-1:0]           e2_seed_mode,
    input  logic [63:0]                e2_seed_data,

    // ENG2 作业
    input  logic [NUM_SLOTS-1:0]       e2_active,
    input  logic [NUM_SLOTS-1:0]       e2_zero,
    input  logic [NUM_SLOTS*32-1:0]    e2_x,
    input  logic [NUM_SLOTS*MW_E2-1:0] e2_nmodes,

    input  logic                       start,
    output logic                       sample_ready,
    output logic                       busy,
    output logic                       done,
    output logic                       out_valid,
    output logic signed [63:0]         mix_sum
);

    logic abc_ready, abc_busy, abc_done, abc_valid;
    logic signed [63:0] abc_mix;
    logic e2_ready, e2_busy, e2_done, e2_valid;
    logic signed [63:0] e2_mix;

    abc_engines_top #(
        .NUM_SLOTS(NUM_SLOTS), .N_MODES(N_MODES_ABC),
        .LANES(LANES), .REC_W(REC_W), .C_SEED_FILE(C_SEED_FILE)
    ) u_abc (
        .clk(clk), .rst_n(rst_n),
        .cfg_we(cfg_we), .cfg_engine(cfg_engine), .cfg_voice(cfg_voice),
        .cfg_mode(cfg_mode), .cfg_data(cfg_data),
        .clr_we(clr_we), .clr_engine(clr_engine), .clr_voice(clr_voice), .clr_mode(clr_mode),
        .seed_we(seed_we), .seed_engine(seed_engine), .seed_voice(seed_voice),
        .seed_mode(seed_mode), .seed_data(seed_data),
        .a_note_start(a_note_start), .a_gate(a_gate), .a_active(a_active),
        .a_x(a_x), .a_x_vel(a_x_vel), .a_nmodes(a_nmodes),
        .b_ctrl(b_ctrl), .b_class(b_class), .b_vel(b_vel), .b_theta(b_theta),
        .b_a1_enable(b_a1_enable), .b_ratio(b_ratio),
        .b_note_start(b_note_start), .b_gate(b_gate), .b_active(b_active), .b_nmodes(b_nmodes),
        .c_note_start(c_note_start), .c_choke(c_choke), .c_len(c_len),
        .c_seed_vel(c_seed_vel), .c_attack(c_attack), .c_release(c_release), .c_nmodes(c_nmodes),
        .c_seed_load_start(c_seed_load_start), .c_seed_load_voice(c_seed_load_voice),
        .c_seed_load_nmodes(c_seed_load_nmodes), .c_seed_base(c_seed_base),
        .start(start), .sample_ready(abc_ready), .busy(abc_busy),
        .done(abc_done), .out_valid(abc_valid), .mix_sum(abc_mix)
    );

    eng2_engine_top #(
        .NUM_SLOTS(NUM_SLOTS), .N_MODES(N_MODES_E2), .LANES(LANES), .REC_W(REC_W)
    ) u_e2 (
        .clk(clk), .rst_n(rst_n),
        .cfg_we(e2_cfg_we), .cfg_voice(e2_cfg_voice), .cfg_mode(e2_cfg_mode), .cfg_data(e2_cfg_data),
        .clr_we(e2_clr_we), .clr_voice(e2_clr_voice), .clr_mode(e2_clr_mode),
        .seed_we(e2_seed_we), .seed_voice(e2_seed_voice),
        .seed_mode(e2_seed_mode), .seed_data(e2_seed_data),
        .start(start), .active_mask(e2_active), .zero_mask(e2_zero),
        .x_vec(e2_x), .n_modes_vec(e2_nmodes),
        .sample_ready(e2_ready), .done(e2_done), .busy(e2_busy),
        .out_valid(e2_valid), .mix_sum(e2_mix),
        .voice_valid(), .voice_id(), .voice_sum()
    );

    logic [1:0] in_valid;
    logic [1:0][63:0] in_mix;
    logic sum_valid;
    logic signed [63:0] sum_mix;

    assign in_valid = {e2_valid, abc_valid};
    assign in_mix[0] = abc_mix;
    assign in_mix[1] = e2_mix;

    engine_mix_sum #(.NUM_ENGINES(2)) u_sum (
        .clk(clk), .rst_n(rst_n), .start(start),
        .in_valid(in_valid), .in_mix(in_mix),
        .out_valid(sum_valid), .mix_sum(sum_mix)
    );

    assign sample_ready = abc_ready & e2_ready;
    assign busy         = abc_busy | e2_busy;
    assign done         = sum_valid;
    assign out_valid    = sum_valid;
    assign mix_sum      = sum_mix;

endmodule
