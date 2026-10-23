// -----------------------------------------------------------------------------
// board_audio_core_model.sv -- TEST-ONLY stand-in for
// rtl/platform/tang_mega_138k_pro/board_audio_core.sv.
//
// The real wrapper will connect the audio session's new public
// `playback_ready` output.  That port does not exist yet, so this model gives
// the same module interface by tapping the real audio_demo_core's internal TX
// handshake (u_core.core_tx_valid && u_core.core_tx_ready) and holding a sticky
// `playback_ready` that clears on reset -- exactly the agreed semantics.
//
// It is used ONLY by sim/test_audio_board.py and is NEVER listed in sources.f.
// Defining BOARD_AUDIO_STUCK at compile time models a stuck song: playback_ready
// never rises, so the board must keep the amplifier shut down.
//
// If the audio implementer renames core_tx_valid/core_tx_ready this file stops
// elaborating and the board test fails loudly rather than passing vacuously.
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

    output logic playback_ready,
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
        .engine_busy     ()
    );

`ifdef BOARD_AUDIO_STUCK
    assign playback_ready = 1'b0;
`else
    logic ready_r;
    always_ff @(posedge clk_core or negedge rst_n)
        if (!rst_n) ready_r <= 1'b0;
        else if (u_core.core_tx_valid && u_core.core_tx_ready) ready_r <= 1'b1;
    assign playback_ready = ready_r;
`endif

endmodule
