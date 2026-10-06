// -----------------------------------------------------------------------------
// tone_source.sv -- continuous square-wave sample source for the standalone
// diagnostic tone (diagnostic_tone_top).
//
// SCOPE: this module is a pure audio-clock-domain generator.  It is NOT part of
// the automatic-song path: it does not read any ROM, FIFO, modal engine, body
// filter or microphone, and it never replaces the main project.  It only exists
// so that a board bring-up can hear a stable, known tone without the core.
//
// Interface / handshake
//   * `ready` is a one-cycle consume strobe from i2s_amp_tx.in_ready (asserted
//     once per 64-BCLK I2S frame, on the falling BCLK boundary).
//   * `pcm` is COMBINATIONAL from the CURRENT `phase`, so the consumer latches it
//     on the same cycle `ready` is high; the handshake advances the phase.
//   * Each accepted handshake advances `phase` 0..47 and wraps to 0 after 47.
//   * `phase < 24` -> +1024 (16'h0400), otherwise -1024 (16'hfc00), i.e. a 50%
//     duty square wave of amplitude 1024 LSB = -30.10 dBFS (20*log10(1/32)).
//   * {sample,sample} is placed on both left and right halves so the mono tone is
//     channel-agnostic (matches i2s_amp_tx's mono duplicate-to-both behaviour).
//   * `started` is sticky after the first accepted handshake and clears only on
//     reset.  The board top uses it to gate the amplifier SD pin: after a lock
//     loss the reset synchroniser clears it, and it is re-asserted only after the
//     first frame accepted following re-lock.
//
// Frequency (audio clock 12.5 MHz, CLK_DIV=4 in i2s_amp_tx):
//   LRC/frame = 12.5 MHz / 4 / 64 = 48828.125 Hz
//   tone      = 48828.125 / 48      = 1017.252604166... Hz
// NOTE: 12.5 MHz is the real Gowin PLL output, NOT the 12.288 MHz audio
// reference.  The tone is therefore also ~1.725% high; this is a diagnostic
// bring-up aid, not a calibrated 48 kHz source.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tone_source (
    input  logic        clk,        // audio clock (clk_audio)
    input  logic        rst_n,      // audio-domain active-low reset (from top)
    input  logic        ready,      // 1-cycle consume strobe (i2s_amp_tx.in_ready)

    output logic [31:0] pcm,        // {left[15:0], right[15:0]}; both halves equal
    output logic        started     // sticky after first accepted handshake
);

    // 48 handshakes per LRC period = 24 samples high + 24 samples low.
    localparam logic [5:0] PHASE_LAST = 6'd47;
    localparam logic [5:0] PHASE_HALF = 6'd24;
    localparam logic [15:0] AMP_POS  = 16'h0400;   // +1024 = -30.10 dBFS
    localparam logic [15:0] AMP_NEG  = 16'hfc00;   // -1024 (two's complement)

    logic [5:0]  phase;
    logic        started_r;
    logic [15:0] sample;

    // Sample for the current phase.  The consumer reads this on the same cycle
    // `ready` is high, so the transfer and the phase step are one handshake.
    always_comb sample = (phase < PHASE_HALF) ? AMP_POS : AMP_NEG;

    // Identical mono sample in both 16-bit halves.
    assign pcm = {sample, sample};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase     <= 6'd0;
            started_r <= 1'b0;
        end else if (ready) begin
            phase     <= (phase == PHASE_LAST) ? 6'd0 : (phase + 6'd1);
            started_r <= 1'b1;
        end
    end

    assign started = started_r;

endmodule
