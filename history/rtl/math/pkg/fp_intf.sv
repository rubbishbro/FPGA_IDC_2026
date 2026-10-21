// ===========================================================================
//  fp_intf.sv  --  fixed-point interfaces.
//
//  SystemVerilog has no parameterised typedef, so an (iw, qw) format cannot
//  live inside a plain type.  A parameterised INTERFACE can carry it, and
//  because interface parameters are elaboration-time constants every shift
//  derived from them constant-folds to zero hardware.
//
//  Measured on GowinSynthesis (GW5AST-138B, sysv2017):
//      a.val >>> a.qw        (qw is an interface parameter)   LUT = 0
//      a.val >>> s           (s is a runtime signal)          LUT = 77..665
//  so the whole point of this file is to keep every shift amount a parameter.
//
//  Format convention (same as fplib):
//      iw  = integer bits, INCLUDING the sign bit
//      qw  = fractional bits
//      wl  = iw + qw = total width
//      value of val = real * 2^qw
//  Examples:
//      sfp #(.iw(1), .qw(23))   s1.23, 24 bit, range (-1, 1),   2^-23 step
//      sfp #(.iw(3), .qw(5))    s3.5,   8 bit, range (-4, 4),   2^-5  step
//      ufp #(.iw(4), .qw(12))   u4.12, 16 bit, range [0, 16),   2^-12 step
// ===========================================================================
`ifndef FP_INTF_SV
`define FP_INTF_SV

interface sfp #(parameter int iw = 1, parameter int qw = 22);
    localparam int wl = iw + qw;
    logic signed [wl-1:0] val;
    modport in  (input  val);
    modport out (output val);
endinterface

interface ufp #(parameter int iw = 1, parameter int qw = 15);
    localparam int wl = iw + qw;
    logic [wl-1:0] val;
    modport in  (input  val);
    modport out (output val);
endinterface

// ---- format access, use as `fp_qw(my_signal) --------------------------------
`define fp_iw(x)  (x.iw)
`define fp_qw(x)  (x.qw)
`define fp_wl(x)  (x.iw + x.qw)

// ---- format arithmetic for sizing intermediate signals --------------------
// product of two fixed point numbers: widths add
`define mult_iw(a, b) (`fp_iw(a) + `fp_iw(b))
`define mult_qw(a, b) (`fp_qw(a) + `fp_qw(b))
// sum of two: fractional widths take the max, integer widths need one more bit
// for the carry, so an exact add needs max(iw)+1 integer bits
`define add_qw(a, b)  ((`fp_qw(a) > `fp_qw(b)) ? `fp_qw(a) : `fp_qw(b))
`define add_iw(a, b)  (((`fp_iw(a) > `fp_iw(b)) ? `fp_iw(a) : `fp_iw(b)) + 1)

`endif
