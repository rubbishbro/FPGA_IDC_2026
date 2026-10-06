// -----------------------------------------------------------------------------
// i2s_amp_tx.sv -- standard-I2S transmitter for the MAX98357A Class-D amplifier.
//
// This is the DEFAULT external playback path.  The MAX98357A is a standard-I2S
// mono Class-D amplifier (not a microphone, and not a Japanese/LSBJ DAC): it
// needs only BCLK, LRC/WS and DIN; it does NOT need MCLK.  GAIN and SD are
// configuration pins, never audio data.
//
// Exact 12.288 MHz audio reference:
//   BCLK = clk/4   = 3.072 MHz
//   WS   = BCLK/64 = 48 kHz, 32-bit slots, 64 BCLK per frame
//   standard I2S one-bit delay: WS changes on the falling BCLK edge and the
//   channel MSB is presented one BCLK later (sampled on the next rising edge)
//   WS low = left, WS high = right (standard I2S)
//   16-bit signed example in the leading bits of each 32-bit slot, remaining
//   bits zero; the same mono sample is copied to both channels.
//
// One pair is popped from the read side every frame; an empty FIFO sends a
// whole zero frame and raises the sticky underflow flag.
//
// This module is deliberately NOT configurable to LSBJ/PT8211; that is the
// separate pt8211_tx.sv path and must be selected explicitly.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module i2s_amp_tx #(
    parameter int CLK_DIV = 4               // audio_clk cycles per BCLK period
) (
    input  logic        clk,                // audio_clk (exact 12.288 MHz)
    input  logic        rst_n,
    input  logic        diag_clear,

    // FIFO read side (audio_clk domain); mono sample duplicated to L and R
    input  logic        in_valid,
    output logic        in_ready,
    input  logic [31:0] in_data,            // {left[15:0], right[15:0]}; mono = either half

    // serial output
    output logic        amp_bclk,
    output logic        amp_ws,
    output logic        amp_din,

    // diagnostics
    output logic        underflow_pulse,
    output logic        underflow_sticky,
    output logic        frame_tick
);

    localparam int T_BITS = (CLK_DIV < 2) ? 1 : $clog2(CLK_DIV);
    localparam int DIV = CLK_DIV;

    logic [T_BITS-1:0] t;                   // clk cycles within one BCLK period
    logic [5:0]        bcnt;                // 0..63 BCLK within an I2S frame
    logic [15:0]       mono;                // current frame's mono sample
    logic              ws_r, din_r;
    logic              under_p, under_s;
    logic              frame_p;

    wire fall = (t == (DIV - 1'b1));        // falling BCLK edge
    wire [5:0] nxt = (bcnt == 6'd63) ? 6'd0 : (bcnt + 6'd1);

    // payload window inside each 32-bit slot: bits 1..16, MSB first.  nxt[3:0]
    // is (nxt mod 16) for both halves, so 16-nxt[3:0] (mod 16) indexes the
    // payload MSB..LSB for nxt in 1..16 and 33..48.
    wire [4:0] pay_idx5  = 5'd16 - {1'b0, nxt[3:0]};
    wire [3:0] pay_idx   = pay_idx5[3:0];
    wire       in_payload = ((nxt >= 6'd1) && (nxt <= 6'd16)) ||
                            ((nxt >= 6'd33) && (nxt <= 6'd48));
    wire       bit_val    = in_payload ? mono[pay_idx] : 1'b0;

    assign amp_bclk = (t >= (DIV / 2));
    assign amp_ws   = ws_r;
    assign amp_din  = din_r;

    assign in_ready        = fall & (nxt == 6'd0);
    assign underflow_pulse = under_p;
    assign underflow_sticky= under_s;
    assign frame_tick      = frame_p;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            t       <= {T_BITS{1'b0}};
            bcnt    <= 6'd0;
            mono    <= 16'd0;
            ws_r    <= 1'b0;
            din_r   <= 1'b0;
            under_p <= 1'b0;
            under_s <= 1'b0;
            frame_p <= 1'b0;
        end else begin
            t       <= fall ? {T_BITS{1'b0}} : (t + 1'b1);
            under_p <= 1'b0;
            frame_p <= 1'b0;
            if (diag_clear) under_s <= 1'b0;

            if (fall) begin
                bcnt <= nxt;
                if (nxt == 6'd0) begin
                    // frame boundary: pop the next mono sample; WS low here
                    mono    <= in_valid ? in_data[15:0] : 16'd0;
                    ws_r    <= 1'b0;
                    din_r   <= 1'b0;                    // 1-bit delay / don't care
                    frame_p <= 1'b1;
                    under_p <= ~in_valid;
                    // an underflow on this frame wins over a simultaneous clear
                    if (!in_valid) under_s <= 1'b1;
                end else begin
                    ws_r  <= (nxt >= 6'd32);
                    din_r <= bit_val;
                end
            end
        end
    end

endmodule
