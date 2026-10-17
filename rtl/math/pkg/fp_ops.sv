// ===========================================================================
//  fp_ops.sv  --  fixed-point arithmetic, built on the sfp/ufp interfaces.
//
//  Every module is PARAMETERLESS: the (iw, qw) format of each signal comes from
//  the interface instance connected to the port, e.g. `a.qw`.  Those are
//  elaboration-time constants, so the shifts inside the fxp_pkg calls
//  constant-fold away and all of this costs no hardware.
//
//  Four constraints were MEASURED on GowinSynthesis GW5AST-138B / XSim 2017.4,
//  none of them assumed:
//
//   1. the operations are MODULES, not functions -- an interface cannot be a
//      function argument ("function f(sfp a)" is rejected by both tools);
//   2. an interface parameter may appear in an EXPRESSION (`a.qw`) but must not
//      be used in a localparam or passed as a submodule PARAMETER.  XSim says
//      "constant expression cannot contain a hierarchical identifier" and the
//      value silently becomes X;
//   3. the 64-bit-carrier functions in fxp_pkg raise WARN (EX3791) whenever
//      their result is assigned straight to a narrower target.  Assign to a
//      64-bit intermediate and slice explicitly instead -- that is why every
//      module below has a `logic signed [63:0] t` in it.  It also makes the
//      truncation visible in the source, which is the whole point;
//   4. a pure binary-point move IS sfp_resize; there is no separate sfp_shift.
//
//  Truncation is floor (arithmetic >>>), matching the hand-written RTL.
// ===========================================================================
`ifndef FP_OPS_SV
`define FP_OPS_SV

// ---- wrapping variants -----------------------------------------------------
module sfp_resize (sfp.in in, sfp.out out);
    logic signed [63:0] t;
    assign t       = fxp_pkg::fx_resize(in.val, `fp_qw(in), `fp_qw(out));
    assign out.val = t[`fp_wl(out)-1:0];
endmodule

module sfp_add (sfp.in a, sfp.in b, sfp.out y);
    logic signed [63:0] t;
    assign t     = fxp_pkg::fx_add(a.val, b.val, `fp_qw(a), `fp_qw(b), `fp_qw(y));
    assign y.val = t[`fp_wl(y)-1:0];
endmodule

module sfp_sub (sfp.in a, sfp.in b, sfp.out y);
    logic signed [63:0] t;
    assign t     = fxp_pkg::fx_sub(a.val, b.val, `fp_qw(a), `fp_qw(b), `fp_qw(y));
    assign y.val = t[`fp_wl(y)-1:0];
endmodule

module sfp_mul (sfp.in a, sfp.in b, sfp.out y);
    logic signed [63:0] t;
    assign t     = fxp_pkg::fx_mul(a.val, b.val, `fp_qw(a), `fp_qw(b), `fp_qw(y));
    assign y.val = t[`fp_wl(y)-1:0];
endmodule

module sfp_mac (sfp.in a, sfp.in b, sfp.in c, sfp.out y);
    logic signed [63:0] p, t;
    assign p     = fxp_pkg::fx_mul(a.val, b.val, `fp_qw(a), `fp_qw(b), `fp_qw(y));
    assign t     = fxp_pkg::fx_add(p, c.val, `fp_qw(y), `fp_qw(c), `fp_qw(y));
    assign y.val = t[`fp_wl(y)-1:0];
endmodule

// ---- saturating variants: clamp instead of wrapping, raise `clip` ----------
module sfp_resize_ind (sfp.in in, sfp.out out, output logic clip);
    logic signed [63:0] t;
    assign t       = fxp_pkg::fx_sat(in.val, `fp_qw(in), `fp_qw(out), `fp_wl(out));
    assign out.val = t[`fp_wl(out)-1:0];
    assign clip    = fxp_pkg::fx_clip(in.val, `fp_qw(in), `fp_qw(out), `fp_wl(out));
endmodule

module sfp_add_ind (sfp.in a, sfp.in b, sfp.out y, output logic clip);
    logic signed [63:0] s, t;
    assign s     = fxp_pkg::fx_add(a.val, b.val, `fp_qw(a), `fp_qw(b), `add_qw(a, b));
    assign t     = fxp_pkg::fx_sat(s, `add_qw(a, b), `fp_qw(y), `fp_wl(y));
    assign y.val = t[`fp_wl(y)-1:0];
    assign clip  = fxp_pkg::fx_clip(s, `add_qw(a, b), `fp_qw(y), `fp_wl(y));
endmodule

module sfp_sub_ind (sfp.in a, sfp.in b, sfp.out y, output logic clip);
    logic signed [63:0] d, t;
    assign d     = fxp_pkg::fx_sub(a.val, b.val, `fp_qw(a), `fp_qw(b), `add_qw(a, b));
    assign t     = fxp_pkg::fx_sat(d, `add_qw(a, b), `fp_qw(y), `fp_wl(y));
    assign y.val = t[`fp_wl(y)-1:0];
    assign clip  = fxp_pkg::fx_clip(d, `add_qw(a, b), `fp_qw(y), `fp_wl(y));
endmodule

module sfp_mul_ind (sfp.in a, sfp.in b, sfp.out y, output logic clip);
    logic signed [63:0] p, t;
    assign p     = fxp_pkg::fx_mul(a.val, b.val, `fp_qw(a), `fp_qw(b), `mult_qw(a, b));
    assign t     = fxp_pkg::fx_sat(p, `mult_qw(a, b), `fp_qw(y), `fp_wl(y));
    assign y.val = t[`fp_wl(y)-1:0];
    assign clip  = fxp_pkg::fx_clip(p, `mult_qw(a, b), `fp_qw(y), `fp_wl(y));
endmodule

module sfp_mac_ind (sfp.in a, sfp.in b, sfp.in c, sfp.out y, output logic clip);
    logic signed [63:0] p, s, t;
    assign p     = fxp_pkg::fx_mul(a.val, b.val, `fp_qw(a), `fp_qw(b), `mult_qw(a, b));
    assign s     = fxp_pkg::fx_add(p, c.val, `mult_qw(a, b), `fp_qw(c), `add_qw(y, c));
    assign t     = fxp_pkg::fx_sat(s, `add_qw(y, c), `fp_qw(y), `fp_wl(y));
    assign y.val = t[`fp_wl(y)-1:0];
    assign clip  = fxp_pkg::fx_clip(s, `add_qw(y, c), `fp_qw(y), `fp_wl(y));
endmodule

// ===========================================================================
//  ROUNDING variants (round-half-up, ties toward +inf)
//
//  The *floor* modules above are kept unchanged for the existing datapaths
//  (the CORDIC chain is verified against them).  These variants exist for the
//  modal recursion in rtl/simsynth, which must round: with floor, a 22-bit
//  coefficient's decay-rate error grows from 0.03% to 1.44%.
// ===========================================================================
module sfp_mul_rnd (sfp.in a, sfp.in b, sfp.out y);
    logic signed [63:0] t;
    assign t     = fxp_pkg::fx_mul_rnd(a.val, b.val, `fp_qw(a), `fp_qw(b), `fp_qw(y));
    assign y.val = t[`fp_wl(y)-1:0];
endmodule

module sfp_mac_rnd (sfp.in a, sfp.in b, sfp.in c, sfp.out y);
    logic signed [63:0] t;
    assign t     = fxp_pkg::fx_mac_rnd(a.val, b.val, c.val,
                                       `fp_qw(a), `fp_qw(b), `fp_qw(c), `fp_qw(y));
    assign y.val = t[`fp_wl(y)-1:0];
endmodule

// ===========================================================================
//  UNSIGNED (ufp) datapath.
//
//  The ufp interface existed but had no operators; these mirror the sfp set.
//  Implementation note: the fxp_pkg functions take a SIGNED 64-bit carrier, so
//  every operand is zero-extended ({0..0, val}) before the call.  A ufp value
//  never has the sign bit set, so arithmetic and logical shifts coincide and
//  the conversion is exact.
// ===========================================================================
module ufp_resize (ufp.in in, ufp.out out);
    logic [63:0] t;
    assign t       = fxp_pkg::fx_shift({{(64-`fp_wl(in)){1'b0}}, in.val},
                                       `fp_qw(in) - `fp_qw(out));
    assign out.val = t[`fp_wl(out)-1:0];
endmodule

module ufp_add (ufp.in a, ufp.in b, ufp.out y);
    logic [63:0] t;
    assign t = fxp_pkg::fx_add({{(64-`fp_wl(a)){1'b0}}, a.val},
                               {{(64-`fp_wl(b)){1'b0}}, b.val},
                               `fp_qw(a), `fp_qw(b), `add_qw(a, b));
    assign y.val = t[`fp_wl(y)-1:0];
endmodule

//  a - b, clamped at 0;  borrow = 1 when a < b (nothing valid to output)
module ufp_sub (ufp.in a, ufp.in b, ufp.out y, output logic borrow);
    logic signed [63:0] d;
    assign d       = fxp_pkg::fx_sub({{(64-`fp_wl(a)){1'b0}}, a.val},
                                     {{(64-`fp_wl(b)){1'b0}}, b.val},
                                     `fp_qw(a), `fp_qw(b), `add_qw(a, b));
    assign borrow  = (d < 0);
    assign y.val   = borrow ? '0 : d[`fp_wl(y)-1:0];
endmodule

module ufp_mul (ufp.in a, ufp.in b, ufp.out y);
    logic [63:0] t;
    assign t = fxp_pkg::fx_mul({{(64-`fp_wl(a)){1'b0}}, a.val},
                               {{(64-`fp_wl(b)){1'b0}}, b.val},
                               `fp_qw(a), `fp_qw(b), `mult_qw(a, b));
    assign y.val = t[`fp_wl(y)-1:0];
endmodule

module ufp_mac (ufp.in a, ufp.in b, ufp.in c, ufp.out y);
    logic [63:0] p, s;
    assign p = fxp_pkg::fx_mul({{(64-`fp_wl(a)){1'b0}}, a.val},
                               {{(64-`fp_wl(b)){1'b0}}, b.val},
                               `fp_qw(a), `fp_qw(b), `mult_qw(a, b));
    assign s = p + fxp_pkg::fx_shift({{(64-`fp_wl(c)){1'b0}}, c.val},
                                     `fp_qw(c) - `fp_qw(y));
    assign y.val = s[`fp_wl(y)-1:0];
endmodule

// ---- saturating (clamp to [0, 2^wl-1]) ------------------------------------
module ufp_add_ind (ufp.in a, ufp.in b, ufp.out y, output logic clip);
    logic [63:0] s, t;
    assign s = fxp_pkg::fx_add({{(64-`fp_wl(a)){1'b0}}, a.val},
                               {{(64-`fp_wl(b)){1'b0}}, b.val},
                               `fp_qw(a), `fp_qw(b), `add_qw(a, b));
    assign t    = fxp_pkg::fx_sat_u(s[63:0], `add_qw(a, b), `fp_qw(y), `fp_wl(y));
    assign y.val = t[`fp_wl(y)-1:0];
    assign clip  = fxp_pkg::fx_clip_u(s[63:0], `add_qw(a, b), `fp_qw(y), `fp_wl(y));
endmodule

module ufp_mul_ind (ufp.in a, ufp.in b, ufp.out y, output logic clip);
    logic [63:0] p, t;
    assign p = fxp_pkg::fx_mul({{(64-`fp_wl(a)){1'b0}}, a.val},
                               {{(64-`fp_wl(b)){1'b0}}, b.val},
                               `fp_qw(a), `fp_qw(b), `mult_qw(a, b));
    assign t    = fxp_pkg::fx_sat_u(p, `mult_qw(a, b), `fp_qw(y), `fp_wl(y));
    assign y.val = t[`fp_wl(y)-1:0];
    assign clip  = fxp_pkg::fx_clip_u(p, `mult_qw(a, b), `fp_qw(y), `fp_wl(y));
endmodule

module ufp_mac_ind (ufp.in a, ufp.in b, ufp.in c, ufp.out y, output logic clip);
    logic [63:0] p, s, t;
    assign p = fxp_pkg::fx_mul({{(64-`fp_wl(a)){1'b0}}, a.val},
                               {{(64-`fp_wl(b)){1'b0}}, b.val},
                               `fp_qw(a), `fp_qw(b), `mult_qw(a, b));
    assign s = p + fxp_pkg::fx_shift({{(64-`fp_wl(c)){1'b0}}, c.val},
                                     `fp_qw(c) - `fp_qw(y));
    assign t    = fxp_pkg::fx_sat_u(s, `mult_qw(a, b), `fp_qw(y), `fp_wl(y));
    assign y.val = t[`fp_wl(y)-1:0];
    assign clip  = fxp_pkg::fx_clip_u(s, `mult_qw(a, b), `fp_qw(y), `fp_wl(y));
endmodule

`endif
