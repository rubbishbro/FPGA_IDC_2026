// -----------------------------------------------------------------------------
// board_audio_core.sv -- platform wrapper around the audio session's
// audio_demo_core, exposing the playback handshake signal the board needs.
//
// audio_demo_core is owned by the audio implementer and is consumed read-only.
// It must provide the public output
//
//   playback_ready : sticky 1 after the first real (core_tx_valid &&
//                    core_tx_ready) sample is pushed into the TX FIFO, and 0
//                    while rst_n is low
//
// The board top uses this (not the 48 kHz frame tick) to enable the amplifier,
// so a voice-load failure or a stuck song cannot leave SD high.  Until the audio
// session lands the port this wrapper keeps synthesis from silently passing:
// the missing connection is a compile error, not a fallback.
//
// The test-only sim/audio_helpers/board_audio_core_model.sv provides the same
// module interface by tapping the real core's internal TX handshake; it is used
// only by sim/test_audio_board.py and is never in sources.f.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module board_audio_core #(
    parameter int NUM_VOICES = 32,
    parameter int N_MODES    = 48,
    parameter int NOTE_GAP   = 12000,
    parameter int ENABLE_BODY = 0,
    parameter int BODY_INSTRUMENT = 0,
    parameter COEFF_FILE = "rtl/rom/modal_coeff.mem",
    parameter INDEX_FILE = "rtl/rom/modal_index.mem",
    parameter BODY_FILE  = "rtl/rom/body_coeff.mem"
) (
    input  logic clk_core,
    input  logic clk_audio,
    input  logic rst_n,

    output logic playback_ready,   // sticky first TX FIFO handshake, reset 0
    output logic dac_bck,
    output logic dac_ws,
    output logic dac_din
);

    audio_demo_core #(
        .NUM_VOICES(NUM_VOICES),
        .N_MODES   (N_MODES),
        .NOTE_GAP  (NOTE_GAP),
        .MODE_SONG (1),
        .OUT_FORMAT(1),
        .ENABLE_BODY(ENABLE_BODY),
        .BODY_INSTRUMENT(BODY_INSTRUMENT),
        .COEFF_FILE(COEFF_FILE),
        .INDEX_FILE(INDEX_FILE),
        .BODY_FILE (BODY_FILE)
    ) u_core (
        .clk_core        (clk_core),
        .clk_audio       (clk_audio),
        .rst_n           (rst_n),
        .diag_clear      (1'b0),
        .mic_sd          (1'b0),
        .dac_bck         (dac_bck),
        .dac_ws          (dac_ws),
        .dac_din         (dac_din),
        .mic_bck         (),
        .mic_ws          (),
        .core_sample_tick(),
        .core_sample_pulse(),
        .underflow_sticky(),
        .overflow_sticky (),
        .tx_overflow_sticky(),
        .deadline_error  (),
        .engine_error_valid(),
        .engine_error_code(),
        .engine_busy     (),
        .playback_ready  (playback_ready)
    );

endmodule
