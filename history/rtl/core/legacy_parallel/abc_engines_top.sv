// -----------------------------------------------------------------------------
// abc_engines_top.sv -- A/B/C 三个新引擎并行 + 求和
//
// 每个引擎 16 slot、4 lane、9×32 RAM；全局 16 voice 的分配交给上层 router。
// cfg/clr/seed 是共享总线，由 cfg_engine[1:0] 选目标引擎。
// 结果经 engine_mix_sum 锁存/求和；ENG2 暂未接入（R5）。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module abc_engines_top #(
    parameter int NUM_SLOTS = 16,
    parameter int N_MODES   = 48,
    parameter int LANES     = 4,
    parameter int REC_W     = 288,
    parameter     C_SEED_FILE = "",
    parameter int VW        = (NUM_SLOTS < 2) ? 1 : $clog2(NUM_SLOTS),
    parameter int MW        = (N_MODES < 2) ? 1 : $clog2(N_MODES),
    parameter int SW        = (NUM_SLOTS * N_MODES < 2) ? 1 : $clog2(NUM_SLOTS * N_MODES + 1)
) (
    input  logic                       clk,
    input  logic                       rst_n,

    // router 共享装载总线：0=A,1=B,2=C
    input  logic                       cfg_we,
    input  logic [1:0]                 cfg_engine,
    input  logic [VW-1:0]              cfg_voice,
    input  logic [MW-1:0]              cfg_mode,
    input  logic [REC_W-1:0]           cfg_data,

    input  logic                       clr_we,
    input  logic [1:0]                 clr_engine,
    input  logic [VW-1:0]              clr_voice,
    input  logic [MW-1:0]              clr_mode,

    input  logic                       seed_we,
    input  logic [1:0]                 seed_engine,
    input  logic [VW-1:0]              seed_voice,
    input  logic [MW-1:0]              seed_mode,
    input  logic [63:0]                seed_data,

    // A
    input  logic [NUM_SLOTS-1:0]       a_note_start,
    input  logic [NUM_SLOTS-1:0]       a_gate,
    input  logic [NUM_SLOTS-1:0]       a_active,
    input  logic [NUM_SLOTS*32-1:0]    a_x,
    input  logic [NUM_SLOTS*16-1:0]    a_x_vel,
    input  logic [NUM_SLOTS*MW-1:0]    a_nmodes,

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
    input  logic [NUM_SLOTS*MW-1:0]    b_nmodes,

    // C
    input  logic [NUM_SLOTS-1:0]       c_note_start,
    input  logic [NUM_SLOTS-1:0]       c_choke,
    input  logic [NUM_SLOTS*20-1:0]    c_len,
    input  logic [NUM_SLOTS*16-1:0]    c_seed_vel,
    input  logic [NUM_SLOTS*24-1:0]    c_attack,
    input  logic [NUM_SLOTS*24-1:0]    c_release,
    input  logic [NUM_SLOTS*MW-1:0]    c_nmodes,
    input  logic                       c_seed_load_start,
    input  logic [VW-1:0]              c_seed_load_voice,
    input  logic [MW-1:0]              c_seed_load_nmodes,
    input  logic [15:0]                c_seed_base,

    input  logic                       start,
    output logic                       sample_ready,
    output logic                       busy,
    output logic                       done,
    output logic                       out_valid,
    output logic signed [63:0]         mix_sum
);

    // cfg/clr/seed 路由
    logic a_cfg_we, b_cfg_we, c_cfg_we;
    logic a_clr_we, b_clr_we, c_clr_we;
    logic a_seed_we, b_seed_we, c_seed_we;

    always_comb begin
        a_cfg_we = cfg_we && (cfg_engine == 2'd0);
        b_cfg_we = cfg_we && (cfg_engine == 2'd1);
        c_cfg_we = cfg_we && (cfg_engine == 2'd2);

        a_clr_we = clr_we && (clr_engine == 2'd0);
        b_clr_we = clr_we && (clr_engine == 2'd1);
        c_clr_we = clr_we && (clr_engine == 2'd2);

        a_seed_we = seed_we && (seed_engine == 2'd0);
        b_seed_we = seed_we && (seed_engine == 2'd1);
        c_seed_we = seed_we && (seed_engine == 2'd2);
    end

    // A
    logic a_ready, a_done, a_busy, a_out_valid;
    logic signed [63:0] a_mix;
    logic a_voice_valid;
    logic [VW-1:0] a_voice_id;
    logic signed [63:0] a_voice_sum;

    eng1_engine_env_top #(
        .NUM_SLOTS(NUM_SLOTS), .N_MODES(N_MODES), .LANES(LANES), .REC_W(REC_W)
    ) u_a (
        .clk(clk), .rst_n(rst_n),
        .cfg_we(a_cfg_we), .cfg_voice(cfg_voice), .cfg_mode(cfg_mode), .cfg_data(cfg_data),
        .clr_we(a_clr_we), .clr_voice(clr_voice), .clr_mode(clr_mode),
        .seed_we(a_seed_we), .seed_voice(seed_voice), .seed_mode(seed_mode), .seed_data(seed_data),
        .aux_re(1'b0), .aux_voice('0), .aux_mode('0), .aux_data(), .aux_valid(),
        .co_we(1'b0), .co_voice('0), .co_mode('0), .co_field('0), .co_wdata('0),
        .note_start_mask(a_note_start), .gate_mask(a_gate),
        .choke_mask('0), .done_mask('0),
        .class_vec('0), .attack_vec('0), .release_vec('0),
        .start(start), .active_mask(a_active), .x_vec(a_x),
        .x_vel_vec(a_x_vel), .n_modes_vec(a_nmodes), .sample_ready(a_ready),
        .done(a_done), .busy(a_busy), .out_valid(a_out_valid), .mix_sum(a_mix),
        .sat_count(), .voice_valid(a_voice_valid), .voice_id(a_voice_id),
        .voice_sum(a_voice_sum)
    );

    // B
    logic b_ready, b_done, b_busy, b_out_valid;
    logic signed [63:0] b_mix;
    logic b_voice_valid;
    logic [VW-1:0] b_voice_id;
    logic signed [63:0] b_voice_sum;
    logic b_a1_active, b_a1_done;

    b_engine_top #(
        .NUM_SLOTS(NUM_SLOTS), .N_MODES(N_MODES), .LANES(LANES), .REC_W(REC_W)
    ) u_b (
        .clk(clk), .rst_n(rst_n),
        .cfg_we(b_cfg_we), .cfg_voice(cfg_voice), .cfg_mode(cfg_mode), .cfg_data(cfg_data),
        .clr_we(b_clr_we), .clr_voice(clr_voice), .clr_mode(clr_mode),
        .seed_we(b_seed_we), .seed_voice(seed_voice), .seed_mode(seed_mode), .seed_data(seed_data),
        .ctrl_vec(b_ctrl), .class_vec(b_class), .vel_vec(b_vel),
        .theta_base_vec(b_theta), .a1_enable(b_a1_enable),
        .a1_active(b_a1_active), .a1_done(b_a1_done),
        .note_start_mask(b_note_start), .gate_mask(b_gate), .ratio(b_ratio),
        .start(start), .active_mask(b_active), .n_modes_vec(b_nmodes),
        .sample_ready(b_ready), .done(b_done), .busy(b_busy),
        .out_valid(b_out_valid), .mix_sum(b_mix), .sat_count(),
        .voice_valid(b_voice_valid), .voice_id(b_voice_id), .voice_sum(b_voice_sum)
    );

    // C
    logic c_ready, c_done, c_busy, c_out_valid;
    logic signed [63:0] c_mix;
    logic c_voice_valid;
    logic [VW-1:0] c_voice_id;
    logic signed [63:0] c_voice_sum;
    logic [NUM_SLOTS-1:0] c_active_unused, c_done_unused;

    c_engine_top #(
        .NUM_SLOTS(NUM_SLOTS), .N_MODES(N_MODES), .LANES(LANES), .REC_W(REC_W),
        .SEED_FILE(C_SEED_FILE), .USE_SEED_ROM(1'b1)
    ) u_c (
        .clk(clk), .rst_n(rst_n),
        .cfg_we(c_cfg_we), .cfg_voice(cfg_voice), .cfg_mode(cfg_mode), .cfg_data(cfg_data),
        .clr_we(c_clr_we), .clr_voice(clr_voice), .clr_mode(clr_mode),
        .seed_we(c_seed_we), .seed_voice(seed_voice), .seed_mode(seed_mode), .seed_data(seed_data),
        .note_start_mask(c_note_start), .choke_mask(c_choke),
        .length_vec(c_len), .attack_vec(c_attack), .release_vec(c_release),
        .seed_vel_vec(c_seed_vel), .n_modes_vec(c_nmodes),
        .seed_load_start(c_seed_load_start), .seed_load_voice(c_seed_load_voice),
        .seed_load_nmodes(c_seed_load_nmodes), .seed_base(c_seed_base),
        .seed_busy(), .seed_done(),
        .start(start), .sample_ready(c_ready), .done(c_done), .busy(c_busy),
        .c_active(c_active_unused), .c_done(c_done_unused),
        .out_valid(c_out_valid), .mix_sum(c_mix), .sat_count(),
        .voice_valid(c_voice_valid), .voice_id(c_voice_id), .voice_sum(c_voice_sum)
    );

    // 求和
    logic sum_valid;
    logic signed [63:0] sum_mix;
    logic [2:0] sum_in_valid;
    logic [2:0][63:0] sum_in_mix;

    assign sum_in_valid = {c_out_valid, b_out_valid, a_out_valid};
    assign sum_in_mix[0] = a_mix;
    assign sum_in_mix[1] = b_mix;
    assign sum_in_mix[2] = c_mix;

    engine_mix_sum #(.NUM_ENGINES(3)) u_sum (
        .clk(clk), .rst_n(rst_n), .start(start),
        .in_valid(sum_in_valid), .in_mix(sum_in_mix),
        .out_valid(sum_valid), .mix_sum(sum_mix)
    );

    assign sample_ready = a_ready & b_ready & c_ready;
    assign busy         = a_busy | b_busy | c_busy;
    assign done         = sum_valid;
    assign out_valid    = sum_valid;
    assign mix_sum      = sum_mix;

endmodule
