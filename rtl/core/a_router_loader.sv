// -----------------------------------------------------------------------------
// a_router_loader.sv -- A 的 index/coeff ROM loader + 9×32 记录打包
//
// 复用 class_loader（A 的 20-bit index），把 72-bit {G,a2,a1} 打包成
// 9×32 记录（field0=G, field1=a1, field2=a2, state=0）。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module a_router_loader #(
    parameter int NUM_SLOTS = 16,
    parameter int N_MODES   = 48,
    parameter int COEFF_DEPTH = 5483,
    parameter int INDEX_DEPTH = 1024,
    parameter COEFF_FILE = "rtl/rom/modal_coeff.mem",
    parameter INDEX_FILE = "rtl/rom/modal_index.mem",
    parameter int REC_W = 288,
    parameter int VW = (NUM_SLOTS < 2) ? 1 : $clog2(NUM_SLOTS),
    parameter int MW = (N_MODES < 1) ? 1 : $clog2(N_MODES + 1)
) (
    input  logic clk,
    input  logic rst_n,

    input  logic load_valid,
    output logic load_ready,
    input  logic [VW-1:0] load_voice,
    input  logic [1:0] load_instrument,
    input  logic [6:0] load_midi,
    input  logic load_dyn,
    input  logic [7:0] load_vel,

    output logic cfg_we,
    output logic [VW-1:0] cfg_voice,
    output logic [MW-1:0] cfg_mode,
    output logic [REC_W-1:0] cfg_data,
    output logic clr_we,
    output logic [VW-1:0] clr_voice,

    output logic load_done,
    output logic [VW-1:0] done_voice,
    output logic [MW-1:0] loaded_n_modes,
    output logic error_valid,
    output logic [2:0] error_code
);

    logic cfg_valid, clear_valid, busy;
    logic [VW-1:0] cfg_voice_i, clear_voice_i, done_voice_i;
    logic [MW-1:0] cfg_mode_i, n_i;
    logic [71:0] cfg_word;
    logic [1:0] ecode2;

    class_loader #(
        .NUM_VOICES(NUM_SLOTS), .N_MODES(N_MODES),
        .COEFF_DEPTH(COEFF_DEPTH), .INDEX_DEPTH(INDEX_DEPTH),
        .COEFF_FILE(COEFF_FILE), .INDEX_FILE(INDEX_FILE),
        .USE_BUF(1'b0)
    ) u_ld (
        .clk(clk), .rst_n(rst_n),
        .load_valid(load_valid), .load_ready(load_ready),
        .ev_class(2'd0), .ev_layer({1'b0, load_dyn}),
        .ev_instrument({2'b00, load_instrument}),
        .ev_note(load_midi), .ev_velocity(load_vel),
        .ev_note_id(12'd0), .ev_gate(1'b1), .ev_event_type(2'd0),
        .load_voice(load_voice),
        .busy(busy), .load_done(load_done), .done_voice(done_voice_i),
        .loaded_n_modes(n_i), .theta_base(),
        .error_valid(error_valid), .error_code(ecode2),
        .clear_valid(clear_valid), .clear_ready(1'b1), .clear_voice(clear_voice_i),
        .cfg_valid(cfg_valid), .cfg_ready(1'b1),
        .cfg_voice(cfg_voice_i), .cfg_mode(cfg_mode_i), .cfg_word(cfg_word),
        .buf_rd_en(), .buf_rd_addr(), .buf_rd_data(72'd0),
        .seed_valid(), .seed_ready(1'b1), .seed_voice(),
        .seed_mode(), .seed_word(),
        .commit_valid(), .commit_class(), .commit_layer(),
        .commit_instrument(), .commit_note(), .commit_velocity(),
        .commit_note_id(), .commit_n_modes()
    );

    // 72-bit -> 9×32（G 26, a1 22, a2 24）
    always_comb begin
        cfg_data = '0;
        cfg_data[0*32 +: 32] = {{6{cfg_word[71]}}, cfg_word[71:46]};
        cfg_data[1*32 +: 32] = {{10{cfg_word[21]}}, cfg_word[21:0]};
        cfg_data[2*32 +: 32] = {8'b0, cfg_word[45:22]};
    end

    assign cfg_we      = cfg_valid;
    assign cfg_voice   = cfg_voice_i;
    assign cfg_mode    = cfg_mode_i;
    assign clr_we      = clear_valid;
    assign clr_voice   = clear_voice_i;
    assign done_voice  = done_voice_i;
    assign loaded_n_modes = n_i;
    assign error_code  = {1'b0, ecode2};

endmodule
