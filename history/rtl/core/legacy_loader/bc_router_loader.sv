// -----------------------------------------------------------------------------
// bc_router_loader.sv -- B/C 的 64-bit index/control/coeff/seed loader + 9×32 打包
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module bc_router_loader #(
    parameter int NUM_SLOTS = 16,
    parameter int N_MODES = 48,
    parameter int COEFF_DEPTH = 5483,
    parameter int INDEX_DEPTH = 8192,
    parameter int CTRL_DEPTH = 1024,
    parameter int SEED_DEPTH = 1152,
    parameter COEFF_FILE = "rtl/rom/b_coeff.mem",
    parameter INDEX_FILE = "rtl/rom/b_index.mem",
    parameter CTRL_FILE = "rtl/rom/b_ctrl.mem",
    parameter SEED_FILE = "rtl/rom/c_seed.mem",
    parameter int REC_W = 288,
    parameter int VW = (NUM_SLOTS < 2) ? 1 : $clog2(NUM_SLOTS),
    parameter int MW = (N_MODES < 2) ? 1 : $clog2(N_MODES)
) (
    input  logic clk, rst_n,
    input  logic load_valid,
    output logic load_ready,
    input  logic [1:0] ev_class,
    input  logic [1:0] ev_layer,
    input  logic [3:0] ev_instrument,
    input  logic [6:0] ev_note,
    input  logic [7:0] ev_velocity,
    input  logic [11:0] ev_note_id,
    input  logic ev_gate,
    input  logic [1:0] ev_event_type,
    input  logic [VW-1:0] load_voice,

    output logic cfg_we,
    output logic [VW-1:0] cfg_voice,
    output logic [MW-1:0] cfg_mode,
    output logic [REC_W-1:0] cfg_data,
    output logic clr_we,
    output logic [VW-1:0] clr_voice,

    output logic seed_valid,
    output logic [VW-1:0] seed_voice,
    output logic [MW-1:0] seed_mode,
    output logic [63:0] seed_word,

    output logic commit_valid,
    output logic [1:0] commit_class,
    output logic [3:0] commit_instrument,
    output logic [6:0] commit_note,
    output logic [7:0] commit_velocity,
    output logic [MW-1:0] commit_n_modes,
    output logic [255:0] commit_ctrl,
    output logic [15:0] theta_base,

    output logic load_done,
    output logic [VW-1:0] done_voice,
    output logic [MW-1:0] loaded_n_modes,
    output logic error_valid,
    output logic [2:0] error_code
);

    logic cfg_valid, clear_valid;
    logic [VW-1:0] cfg_voice_i, clear_voice_i, done_voice_i;
    logic [MW-1:0] cfg_mode_i, n_i;
    logic [71:0] cfg_word;

    class_loader64 #(
        .NUM_VOICES(NUM_SLOTS), .N_MODES(N_MODES),
        .COEFF_DEPTH(COEFF_DEPTH), .INDEX_DEPTH(INDEX_DEPTH),
        .CTRL_DEPTH(CTRL_DEPTH), .SEED_DEPTH(SEED_DEPTH),
        .COEFF_FILE(COEFF_FILE), .INDEX_FILE(INDEX_FILE),
        .CTRL_FILE(CTRL_FILE), .SEED_FILE(SEED_FILE),
        .USE_BUF(1'b0), .MW(MW)
    ) u_ld (
        .clk(clk), .rst_n(rst_n),
        .load_valid(load_valid), .load_ready(load_ready),
        .ev_class(ev_class), .ev_layer(ev_layer), .ev_instrument(ev_instrument),
        .ev_note(ev_note), .ev_velocity(ev_velocity), .ev_note_id(ev_note_id),
        .ev_gate(ev_gate), .ev_event_type(ev_event_type),
        .load_voice(load_voice),
        .busy(), .load_done(load_done), .done_voice(done_voice_i),
        .loaded_n_modes(n_i), .theta_base(theta_base),
        .error_valid(error_valid), .error_code(error_code),
        .clear_valid(clear_valid), .clear_ready(1'b1), .clear_voice(clear_voice_i),
        .cfg_valid(cfg_valid), .cfg_ready(1'b1),
        .cfg_voice(cfg_voice_i), .cfg_mode(cfg_mode_i), .cfg_word(cfg_word),
        .buf_rd_en(), .buf_rd_addr(), .buf_rd_data(72'd0),
        .seed_valid(seed_valid), .seed_ready(1'b1),
        .seed_voice(seed_voice), .seed_mode(seed_mode), .seed_word(seed_word),
        .commit_valid(commit_valid), .commit_class(commit_class),
        .commit_layer(), .commit_instrument(commit_instrument),
        .commit_note(commit_note), .commit_velocity(commit_velocity),
        .commit_note_id(), .commit_n_modes(commit_n_modes),
        .commit_ctrl(commit_ctrl)
    );

    always_comb begin
        cfg_data = '0;
        cfg_data[0*32 +: 32] = {{6{cfg_word[71]}}, cfg_word[71:46]};
        cfg_data[1*32 +: 32] = {{10{cfg_word[21]}}, cfg_word[21:0]};
        cfg_data[2*32 +: 32] = {8'b0, cfg_word[45:22]};
    end

    assign cfg_we = cfg_valid;
    assign cfg_voice = cfg_voice_i;
    assign cfg_mode = cfg_mode_i;
    assign clr_we = clear_valid;
    assign clr_voice = clear_voice_i;
    assign done_voice = done_voice_i;
    assign loaded_n_modes = n_i;

endmodule
