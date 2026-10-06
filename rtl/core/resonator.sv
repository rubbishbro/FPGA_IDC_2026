// -----------------------------------------------------------------------------
// resonator.sv -- one second-order IIR mode, fixed point.
//
//   y[n] = G*x[n] - a1*y[n-1] - a2*y[n-2]
//
// Formats (rtl/DECISIONS.md C, updated to FS=30):
//   a1  Q2.20  signed   22 bit     -> rescaled by <<4 to the 2^24 coefficient scale
//   a2  UQ0.24 unsigned 24 bit     (coefficient scale 24)
//   G   Q2.24  signed   26 bit     (coefficient scale 24)
//   y   Q2.30  signed   32 bit     (state; widened from 24 frac to kill the DC trap)
//   x   Q2.30  signed   32 bit     (excitation shares the state scale)
//
// Arithmetic (must match python/modal_sim/fixed_point.py bit for bit):
//   acc = G*x - (a1<<4)*y1 - a2*y2          // every product carries 2^(24+30)
//   y   = round_half_up(acc / 2^24)         // (acc + 2^23) >>> 24 -> scale 2^30
//         then saturate to Q2.30 [-2^31, 2^31-1]
//
// One sample per valid_in pulse.  load latches coefficients and clears state.
// y_out is the newly computed y (registered); valid_out marks it.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module resonator #(
    parameter int YW   = 32,   // y / x width
    parameter int YF   = 30,   // y / x fractional bits
    parameter int GW   = 26,   // G width (Q2.24)
    parameter int A1W  = 22,   // a1 width (Q2.20)
    parameter int A1F  = 20,   // a1 fractional bits
    parameter int A2W  = 24,   // a2 width (UQ0.24 unsigned)
    parameter int CF   = 24,   // coefficient fractional bits (a2 / G scale)
    parameter int ACCW = 64    // accumulator width (see DECISIONS G1)
) (
    input  logic                 clk,
    input  logic                 rst_n,

    input  logic                 load,
    input  logic signed [A1W-1:0] a1_in,
    input  logic        [A2W-1:0] a2_in,
    input  logic signed [GW-1:0]  g_in,

    input  logic                 valid_in,
    input  logic signed [YW-1:0]  x_in,

    output logic signed [YW-1:0]  y_out,
    output logic                 valid_out,
    output logic                 sat_out
);

    localparam int SH = CF - A1F;                      // 4
    localparam logic signed [ACCW-1:0] YMIN = -(1 <<< (YW-1));
    localparam logic signed [ACCW-1:0] YMAX =  (1 <<< (YW-1)) - 1;
    localparam logic signed [ACCW-1:0] ROUND = 1 <<< (CF-1);   // signed: keeps >>> arithmetic

    logic signed [A1W-1:0] a1_r;
    logic        [A2W-1:0] a2_r;
    logic signed [GW-1:0]  g_r;
    logic signed [YW-1:0]  y1, y2;

    // a1 rescaled to the 2^24 coefficient scale; a2 zero-extended so the product is signed
    logic signed [YW-1:0] a1q24;
    logic signed [A2W:0]  a2s;
    assign a1q24 = a1_r <<< SH;
    assign a2s   = {1'b0, a2_r};

    // products, widened to the accumulator so the subtract cannot overflow
    logic signed [ACCW-1:0] p1, p2, p3, acc, shifted;
    assign p1 = g_r * x_in;
    assign p2 = a1q24 * y1;
    assign p3 = a2s * y2;
    assign acc = p1 - p2 - p3;
    assign shifted = (acc + ROUND) >>> CF;

    logic sat_now;
    logic signed [YW-1:0] ynew;
    assign sat_now = (shifted > YMAX) || (shifted < YMIN);
    assign ynew = sat_now ? (shifted[ACCW-1] ? YMIN[YW-1:0] : YMAX[YW-1:0])
                          : shifted[YW-1:0];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            a1_r <= '0; a2_r <= '0; g_r <= '0;
            y1 <= '0; y2 <= '0;
            y_out <= '0; valid_out <= 1'b0; sat_out <= 1'b0;
        end else if (load) begin
            a1_r <= a1_in; a2_r <= a2_in; g_r <= g_in;
            y1 <= '0; y2 <= '0;
            valid_out <= 1'b0; sat_out <= 1'b0;
        end else begin
            valid_out <= valid_in;
            if (valid_in) begin
                y1 <= ynew;
                y2 <= y1;
                y_out <= ynew;
                sat_out <= sat_now;
            end else begin
                sat_out <= 1'b0;          // status is only meaningful with valid_out
            end
        end
    end

endmodule
