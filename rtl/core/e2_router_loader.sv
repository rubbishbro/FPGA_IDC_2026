// -----------------------------------------------------------------------------
// e2_router_loader.sv -- ENG2 的 index/control/seed + 224-bit coeff loader
//
// 复用 class_loader64 的 index/control/seed FSM；coefficient 单独读 224-bit
// (7 x 32) 表，打包成 9x32 记录（field0..6 = a11..wo）。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module e2_router_loader #(
    parameter int NUM_SLOTS = 16,
    parameter int N_MODES   = 80,
    parameter int REC_W     = 288,
    parameter int COEFF_DEPTH = 8192,
    parameter int INDEX_DEPTH = 8192,
    parameter int CTRL_DEPTH  = 1024,
    parameter int SEED_DEPTH  = 1152,
    parameter     COEFF_FILE  = "rtl/rom/e2_coeff.mem",
    parameter     INDEX_FILE  = "rtl/rom/e2_index.mem",
    parameter     CTRL_FILE   = "rtl/rom/e2_ctrl.mem",
    parameter     SEED_FILE   = "rtl/rom/e2_seed.mem",
    parameter     L72_FILE    = "rtl/rom/modal_coeff.mem",
    parameter int VW = (NUM_SLOTS < 2) ? 1 : $clog2(NUM_SLOTS),
    parameter int MW = (N_MODES < 2) ? 1 : $clog2(N_MODES + 1)
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
    input  logic [VW-1:0] load_voice,

    output logic cfg_we,
    output logic [VW-1:0] cfg_voice,
    output logic [MW-1:0] cfg_mode,
    output logic [REC_W-1:0] cfg_data,
    output logic clr_we,
    output logic [VW-1:0] clr_voice,
    output logic [MW-1:0] clr_mode,

    output logic seed_valid,
    output logic [VW-1:0] seed_voice,
    output logic [MW-1:0] seed_mode,
    output logic [63:0] seed_word,

    output logic load_done,
    output logic [VW-1:0] done_voice,
    output logic [MW-1:0] loaded_n_modes,
    output logic [15:0] theta_base,
    output logic error_valid,
    output logic [2:0] error_code
);

    logic cfg_valid, clear_valid;
    logic [VW-1:0] cfg_voice_i, clear_voice_i, done_voice_i;
    logic [MW-1:0] cfg_mode_i, n_i;
    logic [71:0] cfg_word;       // ignored; class_loader64 的 72-bit 系数
    logic [255:0] commit_ctrl;
    logic [223:0] e2_coeff_rom [0:COEFF_DEPTH-1];
    logic [15:0]  e2_addr;

    initial begin
        if (COEFF_FILE != "") $readmemh(COEFF_FILE, e2_coeff_rom);
    end

    assign e2_addr = theta_base + cfg_mode_i;

    // 7 x 32 -> 9 x 32（低 7 字段；state 字段保持 0）
    always_comb begin
        cfg_data = '0;
        cfg_data[0*32 +: 32] = e2_coeff_rom[e2_addr][0*32 +: 32];
        cfg_data[1*32 +: 32] = e2_coeff_rom[e2_addr][1*32 +: 32];
        cfg_data[2*32 +: 32] = e2_coeff_rom[e2_addr][2*32 +: 32];
        cfg_data[3*32 +: 32] = e2_coeff_rom[e2_addr][3*32 +: 32];
        cfg_data[4*32 +: 32] = e2_coeff_rom[e2_addr][4*32 +: 32];
        cfg_data[5*32 +: 32] = e2_coeff_rom[e2_addr][5*32 +: 32];
        cfg_data[6*32 +: 32] = e2_coeff_rom[e2_addr][6*32 +: 32];
    end

    class_loader64 #(
        .NUM_VOICES(NUM_SLOTS), .N_MODES(N_MODES),
        .COEFF_DEPTH(COEFF_DEPTH), .INDEX_DEPTH(INDEX_DEPTH),
        .CTRL_DEPTH(CTRL_DEPTH), .SEED_DEPTH(SEED_DEPTH),
        .COEFF_FILE(L72_FILE), .INDEX_FILE(INDEX_FILE),
        .CTRL_FILE(CTRL_FILE), .SEED_FILE(SEED_FILE),
        .USE_BUF(1'b0), .MW(MW)
    ) u_ld (
        .clk(clk), .rst_n(rst_n),
        .load_valid(load_valid), .load_ready(load_ready),
        .ev_class(ev_class), .ev_layer(ev_layer), .ev_instrument(ev_instrument),
        .ev_note(ev_note), .ev_velocity(ev_velocity), .ev_note_id(ev_note_id),
        .ev_gate(1'b1), .ev_event_type(2'd0), .load_voice(load_voice),
        .busy(), .load_done(load_done), .done_voice(done_voice_i),
        .loaded_n_modes(n_i), .theta_base(theta_base),
        .error_valid(error_valid), .error_code(error_code),
        .clear_valid(clear_valid), .clear_ready(1'b1), .clear_voice(clear_voice_i),
        .cfg_valid(cfg_valid), .cfg_ready(1'b1),
        .cfg_voice(cfg_voice_i), .cfg_mode(cfg_mode_i), .cfg_word(cfg_word),
        .buf_rd_en(), .buf_rd_addr(), .buf_rd_data(72'd0),
        .seed_valid(seed_valid), .seed_ready(1'b1),
        .seed_voice(seed_voice), .seed_mode(seed_mode), .seed_word(seed_word),
        .commit_valid(), .commit_class(), .commit_layer(),
        .commit_instrument(), .commit_note(), .commit_velocity(),
        .commit_note_id(), .commit_n_modes(), .commit_ctrl(commit_ctrl)
    );

    assign cfg_we    = cfg_valid;
    assign cfg_voice = cfg_voice_i;
    assign cfg_mode  = cfg_mode_i;
    assign clr_we    = clear_valid;
    assign clr_voice = clear_voice_i;
    assign clr_mode  = cfg_mode_i;
    assign done_voice = done_voice_i;
    assign loaded_n_modes = n_i;

endmodule
