// -----------------------------------------------------------------------------
// pt8211_tx.sv -- PT8211 (Japanese / MSB-first, no I2S one-bit delay) transmitter.
//
// audio_clk is the exact 12.288 MHz audio reference.  BCK = audio_clk/8 =
// 1.536 MHz, 32 BCK per frame, two 16-bit slots, so the frame rate is 48 kHz.
// The word on the input pair is {left[15:0], right[15:0]}; the mono demo feeds
// the same 16-bit sample to both halves.
//
// Protocol implemented (rtl/audio_bringup_design.md section 3, checked against
// the PT8211 data sheet by the parent session):
//   * WS low = right, WS high = left
//   * MSB first; DIN and WS change on the falling BCK edge and are sampled by
//     the DAC on the rising edge
//   * there is NO I2S one-bit delay: the MSB of a slot changes with the WS edge
//     itself (WS changes on the same falling edge that presents the MSB)
//   * the slot LSB is presented before the last rising edge of the slot
//
// One stereo pair is popped from the read side every frame.  On an empty FIFO
// the whole frame is zero and a sticky underflow flag is raised.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module pt8211_tx #(
    parameter int CLK_DIV = 8              // audio_clk cycles per BCK period
) (
    input  logic        clk,               // audio_clk (exact 12.288 MHz)
    input  logic        rst_n,             // reset synchronised to clk
    input  logic        diag_clear,        // clears the sticky underflow flag

    // FIFO read side (audio_clk domain)
    input  logic        in_valid,
    output logic        in_ready,
    input  logic [31:0] in_data,           // {left[15:0], right[15:0]}

    // serial output
    output logic        dac_bck,
    output logic        dac_ws,
    output logic        dac_din,

    // diagnostics
    output logic        underflow_pulse,
    output logic        underflow_sticky,
    output logic        frame_tick         // one clk pulse at each frame start
);

    localparam int T_BITS = (CLK_DIV < 2) ? 1 : $clog2(CLK_DIV);
    localparam int DIV = CLK_DIV;

    // t counts audio_clk cycles within one BCK period
    logic [T_BITS-1:0] t;

    // b is the index (0..31) of the bit presented during the coming BCK period
    logic [4:0]        b;

    logic [31:0]       pair;
    logic              ws_r, din_r;
    logic              under_p, under_s;
    logic              frame_p;

    wire update_edge = (t == (DIV - 1'b1));   // falling BCK edge
    wire first_bit   = (b == 5'd0);

    wire [15:0] cur_slot  = b[4] ? pair[31:16] : pair[15:0];
    wire [15:0] new_slot  = in_valid ? (b[4] ? in_data[31:16] : in_data[15:0])
                                     : 16'd0;
    wire        din_hold  = cur_slot[4'd15 - b[3:0]];   // bit b of the held pair
    wire        din_fresh = new_slot[4'd15 - b[3:0]];   // bit 0 of a fresh pair

    assign dac_bck = (t >= (DIV / 2));
    assign dac_ws  = ws_r;
    assign dac_din = din_r;

    assign in_ready        = update_edge & first_bit;
    assign underflow_pulse = under_p;
    assign underflow_sticky= under_s;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            t        <= {T_BITS{1'b0}};
            b        <= 5'd0;
            pair     <= 32'd0;
            ws_r     <= 1'b0;
            din_r    <= 1'b0;
            under_p  <= 1'b0;
            under_s  <= 1'b0;
            frame_p  <= 1'b0;
        end else begin
            t      <= update_edge ? {T_BITS{1'b0}} : (t + 1'b1);
            under_p<= 1'b0;
            frame_p<= 1'b0;

            if (diag_clear) under_s <= 1'b0;

            if (update_edge) begin
                if (first_bit) begin
                    // frame boundary: pop the next pair and present its MSB
                    // (right, WS low) on this same falling edge -- no I2S delay
                    pair      <= in_valid ? in_data : 32'd0;
                    ws_r      <= 1'b0;
                    din_r     <= din_fresh;
                    b         <= 5'd1;
                    frame_p   <= 1'b1;
                    under_p   <= ~in_valid;
                    // an underflow on this frame wins over a simultaneous clear
                    if (!in_valid) under_s <= 1'b1;
                end else begin
                    ws_r      <= b[4];
                    din_r     <= din_hold;
                    b         <= (b == 5'd31) ? 5'd0 : (b + 5'd1);
                end
            end
        end
    end

    // under_p / frame_p are registered one clk after the falling edge; expose
    // them as clean one-clk pulses at the frame boundary.
    assign frame_tick = frame_p;

    // underflow_pulse is a one-clk pulse in the audio domain; the sticky flag is
    // what the transport exports (sticky level, never a bare pulse across CDC).

endmodule
