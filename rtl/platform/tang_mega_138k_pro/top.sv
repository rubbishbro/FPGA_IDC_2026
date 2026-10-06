// -----------------------------------------------------------------------------
// top.sv -- Tang Mega 138K Pro board top for the automatic-song I2S output.
//
// Real board interface only:
//   clk   : 50 MHz crystal, pin P16 (from the official TangMega-138KPro example)
//   reset : board reset button, pin U4, ACTIVE HIGH
//   amp_* : PMOD2 / J26 -> external MAX98357A
//            amp_bclk = IO0 / C21, amp_lrc = IO1 / B20,
//            amp_din  = IO2 / B19, amp_sd  = IO3 / A17
//
// The 100 MHz core clock and the 12.5 MHz functional bring-up audio clock come
// ONLY from the Gowin PLL IP instantiated inside clock_reset.  12.5 MHz is NOT
// exact 12.288 MHz (see clock_reset.sv header): BCLK 3.125 MHz, LRC 48.828 kHz.  There is no path that wires
// the 50 MHz crystal, a test clock or a divided clock directly onto a pin as if
// it were the core/audio clock.
//
// Default power-on state is SONG mode (auto melody) at the frozen 32-voice
// scale.
//
// amp_sd (MAX98357A shutdown / channel select; high = left) is gated on
// board_audio_core.playback_ready, i.e. the first REAL sample handed to the TX
// FIFO -- not merely on a 48 kHz tick.  If voice loading fails or the song never
// produces a sample, playback_ready stays low and the amplifier stays shut down.
// amp_sd also drops combinationally on button reset or loss of lock.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module top #(
    parameter int NUM_VOICES = 32,
    parameter int N_MODES    = 48,
    parameter int NOTE_GAP   = 12000,
    parameter int ENABLE_BODY = 0,
    parameter int BODY_INSTRUMENT = 0,
    parameter COEFF_FILE = "rtl/rom/modal_coeff.mem",
    parameter INDEX_FILE = "rtl/rom/modal_index.mem",
    parameter BODY_FILE  = "rtl/rom/body_coeff.mem"
) (
    input  logic clk,          // 50 MHz crystal, P16
    input  logic reset,        // reset button, U4, active high
    output logic amp_bclk,     // PMOD2 IO0 / C21
    output logic amp_lrc,      // PMOD2 IO1 / B20
    output logic amp_din,      // PMOD2 IO2 / B19
    output logic amp_sd        // PMOD2 IO3 / A17
);

    logic clk_core, clk_audio, locked, rst_n;
    logic playback_ready;
    logic dac_bck, dac_ws, dac_din;

    clock_reset u_clock_reset (
        .clk_50m  (clk),
        .rst_btn  (reset),
        .clk_core (clk_core),
        .clk_audio(clk_audio),
        .locked   (locked),
        .rst_n    (rst_n)
    );

    board_audio_core #(
        .NUM_VOICES(NUM_VOICES),
        .N_MODES   (N_MODES),
        .NOTE_GAP  (NOTE_GAP),
        .ENABLE_BODY(ENABLE_BODY),
        .BODY_INSTRUMENT(BODY_INSTRUMENT),
        .COEFF_FILE(COEFF_FILE),
        .INDEX_FILE(INDEX_FILE),
        .BODY_FILE (BODY_FILE)
    ) u_audio (
        .clk_core      (clk_core),
        .clk_audio     (clk_audio),
        .rst_n         (rst_n),
        .playback_ready(playback_ready),
        .dac_bck       (dac_bck),
        .dac_ws        (dac_ws),
        .dac_din       (dac_din)
    );

    // Amplifier shutdown / channel select.  playback_ready is the core's sticky
    // "a real sample reached the TX FIFO" flag; combined with lock and the raw
    // button so a resume with no data (or a lost lock) keeps it low immediately.
    assign amp_sd   = locked & playback_ready & ~reset;
    assign amp_bclk = dac_bck;
    assign amp_lrc  = dac_ws;
    assign amp_din  = dac_din;

endmodule
