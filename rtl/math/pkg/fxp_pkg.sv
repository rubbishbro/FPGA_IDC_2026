`timescale 1ns/1ps
// ===========================================================================
//  fxp_pkg -- a small fixed-point arithmetic package.
//
//  Model: a fixed-point number is a signed integer `v` plus a fraction width F,
//  meaning the real value is  v * 2^(-F).
//
//  SystemVerilog has no parameterised typedef and Gowin rejects parameterised
//  functions, so F cannot live in the TYPE.  Instead every operation takes F as
//  an ordinary argument and the call site passes constants; GowinSynthesis
//  inlines the function and constant-folds the shift, so it costs nothing.
//  (Measured:  y = a >>> 13   and   y = fx_shift(a, 13)   both give LUT=0.)
//
//  All arithmetic runs in a wide carrier so intermediate products cannot
//  overflow; the caller truncates on assignment.
// ===========================================================================
`ifndef FXP_PKG_SV
`define FXP_PKG_SV

package fxp_pkg;

    localparam int CW = 64;              // carrier width

    // ---- binary-point move -------------------------------------------------
    // d > 0 : coarser (drop LSBs, floor).  d < 0 : finer (pad zeros).
    function automatic logic signed [CW-1:0] fx_shift(input logic signed [CW-1:0] a,
                                                      input int d);
        fx_shift = (d >= 0) ? (a >>> d) : (a <<< (-d));
    endfunction

    // ---- add / sub, aligning both operands to the output's binary point ----
    //   r * 2^-fout = a * 2^-fa +/- b * 2^-fb
    function automatic logic signed [CW-1:0] fx_add(input logic signed [CW-1:0] a,
                                                    input logic signed [CW-1:0] b,
                                                    input int fa, input int fb,
                                                    input int fout);
        fx_add = fx_shift(a, fa - fout) + fx_shift(b, fb - fout);
    endfunction

    function automatic logic signed [CW-1:0] fx_sub(input logic signed [CW-1:0] a,
                                                    input logic signed [CW-1:0] b,
                                                    input int fa, input int fb,
                                                    input int fout);
        fx_sub = fx_shift(a, fa - fout) - fx_shift(b, fb - fout);
    endfunction

    // ---- multiply ----------------------------------------------------------
    //   r * 2^-fout = a * b * 2^-(fa+fb)   ->   r = (a*b) * 2^(fout-fa-fb)
    function automatic logic signed [CW-1:0] fx_mul(input logic signed [CW-1:0] a,
                                                    input logic signed [CW-1:0] b,
                                                    input int fa, input int fb,
                                                    input int fout);
        fx_mul = fx_shift(a * b, fa + fb - fout);
    endfunction

    // ---- resize (same number, different Q) --------------------------------
    function automatic logic signed [CW-1:0] fx_resize(input logic signed [CW-1:0] a,
                                                       input int fsrc, input int fdst);
        fx_resize = fx_shift(a, fsrc - fdst);
    endfunction

    // ---- saturating resize -------------------------------------------------
    //  Rescale from Q(qi) to Q(qo) and clamp into a signed `wo`-bit range.
    //  Two functions rather than one struct-returning function so each can be
    //  used directly on the right-hand side of a continuous assignment.
    function automatic logic signed [CW-1:0] fx_sat(input logic signed [CW-1:0] a,
                                                    input int qi, input int qo,
                                                    input int wo);
        logic signed [CW-1:0] w, hi, lo;
        w     = fx_resize(a, qi, qo);
        hi    = (64'sd1 <<< (wo - 1)) - 1;
        lo    = -(64'sd1 <<< (wo - 1));
        fx_sat = (w > hi) ? hi : ((w < lo) ? lo : w);
    endfunction

    function automatic logic fx_clip(input logic signed [CW-1:0] a,
                                     input int qi, input int qo, input int wo);
        logic signed [CW-1:0] w, hi, lo;
        w       = fx_resize(a, qi, qo);
        hi      = (64'sd1 <<< (wo - 1)) - 1;
        lo      = -(64'sd1 <<< (wo - 1));
        fx_clip = (w > hi) || (w < lo);
    endfunction

    // ---- whole-part extraction / integer to fixed -------------------------
    function automatic logic signed [CW-1:0] fx_from_int(input logic signed [CW-1:0] i,
                                                         input int fout);
        fx_from_int = fx_shift(i, -fout);
    endfunction

    function automatic logic signed [CW-1:0] fx_to_int(input logic signed [CW-1:0] a,
                                                       input int fsrc);
        fx_to_int = fx_shift(a, fsrc);
    endfunction

    // ---- number of bits needed for a given real constant ------------------
    // useful to size a signal: fx_bits(3.14159, 13) -> integer width needed
    function automatic int fx_iw_needed(input real v, input int frac);
        real mag;
        int  n;
        mag = (v < 0.0) ? -v : v;
        n   = 1;                                   // sign bit
        while ((2.0 ** (n - 1 - frac)) <= mag)     // only used at elaboration
            n = n + 1;                             // on a constant -> unrolled
        fx_iw_needed = n;
    endfunction

    // =====================================================================
    //  Rounding variants (round-half-up, ties toward +inf).
    //
    //  fx_* (above) FLOOR to match hand-written RTL that predates them.
    //  The modal recursion in rtl/simsynth must ROUND: with floor, the
    //  decay-rate error of a 22-bit coefficient rises from 0.03% to 1.44%,
    //  i.e. the resonators lose their poles' precision.  These variants exist
    //  so both sides can share one arithmetic source without changing the
    //  numerics of either.
    //
    //  fx_shift_rnd(a, d)  == (a + 2^(d-1)) >>> d   (d > 0)
    //                     == fx_shift(a, d)         (d <= 0, exact)
    // =====================================================================
    function automatic logic signed [CW-1:0] fx_shift_rnd(input logic signed [CW-1:0] a,
                                                          input int d);
        if (d <= 0) fx_shift_rnd = fx_shift(a, d);
        else        fx_shift_rnd = (a + (64'sd1 <<< (d - 1))) >>> d;
    endfunction

    // product rounded onto the fout grid:  r = round(a*b * 2^(fout-fa-fb))
    function automatic logic signed [CW-1:0] fx_mul_rnd(input logic signed [CW-1:0] a,
                                                        input logic signed [CW-1:0] b,
                                                        input int fa, input int fb,
                                                        input int fout);
        fx_mul_rnd = fx_shift_rnd(a * b, fa + fb - fout);
    endfunction

    // multiply-accumulate with a SINGLE rounding on the product: this is
    // exactly "qn += round(term)" of the modal recursion.
    function automatic logic signed [CW-1:0] fx_mac_rnd(input logic signed [CW-1:0] a,
                                                        input logic signed [CW-1:0] b,
                                                        input logic signed [CW-1:0] c,
                                                        input int fa, input int fb,
                                                        input int fc, input int fout);
        fx_mac_rnd = fx_mul_rnd(a, b, fa, fb, fout) + fx_shift(c, fc - fout);
    endfunction

    // ---- unsigned saturation (ufp datapath) --------------------------------
    //  Clamp into [0, 2^wo - 1];  pair with fx_clip_u() for the flag.
    function automatic logic [CW-1:0] fx_sat_u(input logic [CW-1:0] a,
                                               input int qi, input int qo,
                                               input int wo);
        logic [CW-1:0] w, hi;
        w       = fx_shift(a, qi - qo);            // floor is fine for unsigned
        hi      = (64'd1 <<< wo) - 1'd1;
        fx_sat_u = (w > hi) ? hi : w;
    endfunction

    function automatic logic fx_clip_u(input logic [CW-1:0] a,
                                       input int qi, input int qo, input int wo);
        logic [CW-1:0] w, hi;
        w        = fx_shift(a, qi - qo);
        hi       = (64'd1 <<< wo) - 1'd1;
        fx_clip_u = (w > hi);
    endfunction

endpackage
`endif
