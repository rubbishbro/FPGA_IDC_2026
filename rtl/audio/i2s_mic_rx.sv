// -----------------------------------------------------------------------------
// i2s_mic_rx.sv -- conditional standard-I2S digital-mic receiver (master).
//
// STATUS: conditional / unverified against the user's hardware.  The user only
// described a "7-pin microphone and 2-pin speaker"; the actual module is not
// identified.  This block implements a *standard* I2S digital microphone input
// (e.g. INMP441-class) and makes no claim that the physical device matches it.
//
// The FPGA is the serial master: it drives MIC_BCK = audio_clk/4 = 3.072 MHz and
// MIC_WS = 48 kHz (64 BCK per frame, 32-bit slots).  SD is sampled on the BCK
// rising edge.  Standard I2S one-bit delay: the channel MSB is sampled one BCK
// after the WS edge.  A 24-bit signed payload is shifted in MSB first; the
// padding bits after bit 24 are ignored.  CH_SEL picks WS-low (0, left) or
// WS-high (1, right).
//
// This is not PDM, not TDM, and not an analogue ADC; it never connects to an
// amplifier output.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module i2s_mic_rx #(
    parameter int CH_SEL = 0          // 0 = WS-low (left), 1 = WS-high (right)
) (
    input  logic        clk,          // audio_clk (exact 12.288 MHz)
    input  logic        rst_n,        // reset synchronised to clk
    input  logic        sd,           // serial data from the microphone

    output logic        mic_bck,      // 3.072 MHz
    output logic        mic_ws,       // 48 kHz, low = left, high = right
    output logic [23:0] mic_data,     // 24-bit signed, MSB first
    output logic        mic_valid     // one clk when mic_data is fresh
);

    // t counts audio_clk cycles in one BCK period (4 clk -> BCK = clk/4)
    logic [1:0] t;
    // bcnt counts BCK periods in one 64-BCK I2S frame
    logic [5:0] bcnt;

    logic [23:0] sr;
    logic [23:0] data_r;
    logic        valid_r;

    // payload window: MSB at base+1, LSB at base+24
    localparam logic [5:0] BASE = (CH_SEL == 0) ? 6'd0 : 6'd32;
    localparam logic [5:0] LAST = BASE + 6'd24;

    wire rise = (t == 2'd1);     // clk edge that makes BCK rise
    wire fall = (t == 2'd3);     // clk edge that makes BCK fall

    assign mic_bck = t[1];
    assign mic_ws  = bcnt[5];
    assign mic_data  = data_r;
    assign mic_valid = valid_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            t       <= 2'd0;
            bcnt    <= 6'd0;
            sr      <= 24'd0;
            data_r  <= 24'd0;
            valid_r <= 1'b0;
        end else begin
            t       <= fall ? 2'd0 : (t + 2'd1);
            valid_r <= 1'b0;

            if (fall) begin
                bcnt <= (bcnt == 6'd63) ? 6'd0 : (bcnt + 6'd1);
            end

            if (rise) begin
                if ((bcnt > BASE) && (bcnt <= LAST)) begin
                    sr <= {sr[22:0], sd};
                    if (bcnt == LAST) begin
                        data_r  <= {sr[22:0], sd};
                        valid_r <= 1'b1;
                    end
                end
            end
        end
    end

endmodule
