// -----------------------------------------------------------------------------
// song_player_harness.sv -- TEST-ONLY wrapper: song_player + mock_modal_engine.
//
// Exposes the internal load/sample handshakes so sim/test_song_player.py can
// check event ordering, voice assignment, excitation pulses and deadline
// handling without reaching into private state.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module song_player_harness #(
    parameter int NUM_VOICES = 8,
    parameter int N_MODES    = 48,
    parameter int NOTE_GAP   = 12000,
    parameter int PULSE_LEN  = 7,
    parameter int MOCK_LOAD_LAT   = 6,
    parameter int MOCK_SAMPLE_LAT = 5,
    parameter int MOCK_STALL      = 0,
    parameter int VW = (NUM_VOICES < 2) ? 1 : $clog2(NUM_VOICES),
    parameter int MW = (N_MODES < 1) ? 1 : $clog2(N_MODES + 1)
) (
    input  logic clk,
    input  logic rst_n,
    input  logic diag_clear,
    input  logic sample_tick,

    output logic                  load_valid,
    output logic                  load_ready,
    output logic [VW-1:0]         load_voice,
    output logic [1:0]            load_instrument,
    output logic [6:0]            load_midi,
    output logic                  load_dyn,
    output logic [7:0]            load_vel,
    output logic                  load_done,
    output logic [VW-1:0]         done_voice,
    output logic [MW-1:0]         loaded_n_modes,

    output logic                  sample_valid,
    output logic                  sample_ready,
    output logic [NUM_VOICES-1:0] active_mask,
    output logic [NUM_VOICES*32-1:0] x_vec,

    output logic                  out_valid,
    output logic signed [63:0]    out_sum,
    output logic                  deadline_error,
    output logic                  busy,
    output logic [5:0]            event_index,

    output logic [63:0]           eng_mix_sum
);

    logic                  eng_out_valid;
    logic signed [63:0]    eng_mix;

    song_player #(
        .NUM_VOICES(NUM_VOICES), .N_MODES(N_MODES),
        .NOTE_GAP(NOTE_GAP), .PULSE_LEN(PULSE_LEN)
    ) u_song (
        .clk             (clk),
        .rst_n           (rst_n),
        .diag_clear      (diag_clear),
        .load_valid      (load_valid),
        .load_ready      (load_ready),
        .load_voice      (load_voice),
        .load_instrument (load_instrument),
        .load_midi       (load_midi),
        .load_dyn        (load_dyn),
        .load_vel        (load_vel),
        .load_done       (load_done),
        .done_voice      (done_voice),
        .loaded_n_modes  (loaded_n_modes),
        .sample_valid    (sample_valid),
        .sample_ready    (sample_ready),
        .active_mask     (active_mask),
        .x_vec           (x_vec),
        .engine_out_valid(eng_out_valid),
        .engine_mix_sum  (eng_mix),
        .sample_tick     (sample_tick),
        .out_valid       (out_valid),
        .out_sum         (out_sum),
        .deadline_error  (deadline_error),
        .busy            (busy),
        .event_index     (event_index)
    );

    modal_engine #(
        .NUM_VOICES(NUM_VOICES), .N_MODES(N_MODES), .SKIP_ZERO_INPUT(1),
        .MOCK_LOAD_LAT(MOCK_LOAD_LAT), .MOCK_SAMPLE_LAT(MOCK_SAMPLE_LAT),
        .MOCK_STALL(MOCK_STALL)
    ) u_engine (
        .clk            (clk),
        .rst_n          (rst_n),
        .load_valid     (load_valid),
        .load_ready     (load_ready),
        .load_voice     (load_voice),
        .load_instrument(load_instrument),
        .load_midi      (load_midi),
        .load_dyn       (load_dyn),
        .load_vel       (load_vel),
        .sample_valid   (sample_valid),
        .sample_ready   (sample_ready),
        .active_mask    (active_mask),
        .x_vec          (x_vec),
        .busy           (),
        .load_done      (load_done),
        .done_voice     (done_voice),
        .loaded_n_modes (loaded_n_modes),
        .out_valid      (eng_out_valid),
        .mix_sum        (eng_mix),
        .sat_count      (),
        .voice_valid    (),
        .voice_id       (),
        .voice_sum      (),
        .commit_valid   (),
        .commit_voice   (),
        .commit_mode    (),
        .commit_y1      (),
        .commit_y2      (),
        .commit_sat     (),
        .error_valid    (),
        .error_code     ()
    );

    assign eng_mix_sum = eng_mix;

endmodule
