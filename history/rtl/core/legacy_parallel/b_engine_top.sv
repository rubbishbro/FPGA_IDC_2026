// -----------------------------------------------------------------------------
// b_engine_top.sv -- B 引擎：b_front + engine/envelope
//
// B 的系数/状态仍在 eng1_engine_env_top 的 9×32 RAM；
// 本模块只产生 B 的 x 和 envelope attack/release。
// a1 刷新（B 的颤音/滑音）后续从 RAM 侧接入，不在本模块里。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module b_engine_top #(
    parameter int NUM_SLOTS = 16,
    parameter int N_MODES   = 48,
    parameter int LANES     = 4,
    parameter int REC_W     = 288,
    parameter int THETA_DEPTH = 5483,
    parameter THETA_FILE = ""
) (
    input  logic                       clk,
    input  logic                       rst_n,

    input  logic                       cfg_we,
    input  logic [((NUM_SLOTS<2)?1:$clog2(NUM_SLOTS))-1:0] cfg_voice,
    input  logic [((N_MODES<2)?1:$clog2(N_MODES))-1:0]     cfg_mode,
    input  logic [REC_W-1:0]           cfg_data,
    input  logic                       clr_we,
    input  logic [((NUM_SLOTS<2)?1:$clog2(NUM_SLOTS))-1:0] clr_voice,
    input  logic [((N_MODES<2)?1:$clog2(N_MODES))-1:0]     clr_mode,
    input  logic                       seed_we,
    input  logic [((NUM_SLOTS<2)?1:$clog2(NUM_SLOTS))-1:0] seed_voice,
    input  logic [((N_MODES<2)?1:$clog2(N_MODES))-1:0]     seed_mode,
    input  logic [63:0]                seed_data,

    input  logic [NUM_SLOTS*256-1:0]   ctrl_vec,
    input  logic [NUM_SLOTS*2-1:0]     class_vec,
    input  logic [NUM_SLOTS*16-1:0]    vel_vec,
    input  logic [NUM_SLOTS*16-1:0]    theta_base_vec,
    input  logic                       a1_enable,
    output logic                       a1_active,
    output logic                       a1_done,
    input  logic [NUM_SLOTS-1:0]       note_start_mask,
    input  logic [NUM_SLOTS-1:0]       gate_mask,
    input  logic [15:0]                ratio,

    input  logic                       start,
    input  logic [NUM_SLOTS-1:0]       active_mask,
    input  logic [NUM_SLOTS*((N_MODES<2)?1:$clog2(N_MODES))-1:0] n_modes_vec,

    output logic                       sample_ready,
    output logic                       done,
    output logic                       busy,
    output logic                       out_valid,
    output logic signed [63:0]         mix_sum,
    output logic [((NUM_SLOTS*N_MODES<2)?1:$clog2(NUM_SLOTS*N_MODES+1))-1:0] sat_count,
    output logic                       voice_valid,
    output logic [((NUM_SLOTS<2)?1:$clog2(NUM_SLOTS))-1:0] voice_id,
    output logic signed [63:0]         voice_sum
);

    logic [NUM_SLOTS*32-1:0] x_b;
    logic [NUM_SLOTS*24-1:0] atk_b, rel_b;
    logic                    aux_re;
    logic [((NUM_SLOTS<2)?1:$clog2(NUM_SLOTS))-1:0] aux_voice;
    logic [((N_MODES<2)?1:$clog2(N_MODES))-1:0]     aux_mode;
    logic [REC_W-1:0]        aux_data;
    logic                    aux_valid;
    logic                    co_we;
    logic [((NUM_SLOTS<2)?1:$clog2(NUM_SLOTS))-1:0] co_voice;
    logic [((N_MODES<2)?1:$clog2(N_MODES))-1:0]     co_mode;
    logic [3:0]              co_field;
    logic [31:0]             co_wdata;

    b_front #(.NUM_SLOTS(NUM_SLOTS)) u_front (
        .clk(clk), .rst_n(rst_n),
        .ctrl_vec(ctrl_vec), .class_vec(class_vec), .vel_vec(vel_vec),
        .start_mask(note_start_mask), .gate_mask(gate_mask), .ratio(ratio),
        .x_vec(x_b), .attack_vec(atk_b), .release_vec(rel_b)
    );

    eng1_engine_env_top #(
        .NUM_SLOTS(NUM_SLOTS), .N_MODES(N_MODES), .LANES(LANES), .REC_W(REC_W)
    ) u_engine (
        .clk(clk), .rst_n(rst_n),
        .cfg_we(cfg_we), .cfg_voice(cfg_voice), .cfg_mode(cfg_mode), .cfg_data(cfg_data),
        .clr_we(clr_we), .clr_voice(clr_voice), .clr_mode(clr_mode),
        .seed_we(seed_we), .seed_voice(seed_voice), .seed_mode(seed_mode), .seed_data(seed_data),
        .aux_re(aux_re), .aux_voice(aux_voice), .aux_mode(aux_mode),
        .aux_data(aux_data), .aux_valid(aux_valid),
        .co_we(co_we), .co_voice(co_voice), .co_mode(co_mode),
        .co_field(co_field), .co_wdata(co_wdata),
        .note_start_mask(note_start_mask), .gate_mask(gate_mask),
        .choke_mask('0), .done_mask('0),
        .class_vec(class_vec), .attack_vec(atk_b), .release_vec(rel_b),
        .start(start), .active_mask(active_mask), .x_vec(x_b),
        .x_vel_vec({NUM_SLOTS{16'h8000}}),
        .n_modes_vec(n_modes_vec), .sample_ready(sample_ready),
        .done(done), .busy(busy), .out_valid(out_valid), .mix_sum(mix_sum),
        .sat_count(sat_count), .voice_valid(voice_valid), .voice_id(voice_id),
        .voice_sum(voice_sum)
    );

    b_a1_ram_engine #(
        .NUM_SLOTS(NUM_SLOTS), .N_MODES(N_MODES),
        .COEFF_DEPTH(5483), .THETA_DEPTH(THETA_DEPTH),
        .THETA_FILE(THETA_FILE), .REC_W(REC_W)
    ) u_a1 (
        .clk(clk), .rst_n(rst_n),
        .class_vec(class_vec), .theta_base_vec(theta_base_vec),
        .ratio(ratio), .enable(a1_enable), .idle(~busy),
        .aux_re(aux_re), .aux_voice(aux_voice), .aux_mode(aux_mode),
        .aux_data(aux_data), .aux_valid(aux_valid),
        .co_we(co_we), .co_voice(co_voice), .co_mode(co_mode),
        .co_field(co_field), .co_wdata(co_wdata),
        .active(a1_active), .done(a1_done)
    );

endmodule
