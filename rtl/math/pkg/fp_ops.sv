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

`endif
