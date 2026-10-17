import clk_rst_pkg::*;
import fxp_pkg::*;

package math_state_pkg;

typedef enum logic [1:0] {
    S_IDLE, 
    S_WORKING, 
    S_DONE
} math_state_t;

endpackage

/*
from cartesian to polar
using CORDIC algorithm

IN_L and OUT_L should smaller than 61

start: start converting
x,y: cartesian coordinate;
r,w: polar coordinate;

Binary point, stated once here and expressed only through fxp_pkg from then on:

    input      fw_in  = IN_L - 1     (s.xxx,   1.0 = 2^(IN_L-1))
    datapath   fw_dp  = L - 3        (syy.xxx, 1.0 = 2^(L-3), two integer bits
                                      so +-sqrt(2) and +-pi both fit)
    output     fw_out = OUT_L - 3    (syy.yyy, 1.0 = 2^(OUT_L-3))

Every conversion below is an fxp_pkg call with these fw values, so the shifts
are compile-time constants and no format is hand-rolled inline.  Verified
bit-identical to the previous hand-written version (see sim/ c2p tests).
*/
module cart2polar#(
    parameter int IN_L  = 8,
    parameter int OUT_L = 8
)(
    input  clk_rst                    cr,
    input  logic                      start,
    input  logic signed  [IN_L-1:0]   x,y,
    output logic signed  [OUT_L-1:0]  r,w
);

import math_state_pkg::*;

initial begin
    assert( (IN_L < 61) & (OUT_L < 61) );
end

localparam int L     = (IN_L > OUT_L) ? IN_L+2 : OUT_L+2;
localparam int FW_IN  = IN_L - 1;
localparam int FW_DP  = L - 3;
localparam int FW_OUT = OUT_L - 3;

// constants live in the datapath's binary point (1.0 = 2^FW_DP)
// 0.607252935... * 2^(63)
localparam logic signed [L-1:0] k  = 64'b0_100_1101_1011_1010_0111_0110_1101_0100_0010_0001_1010_1111_0010_1101_0011_0100 >> (66-L);
localparam logic signed [L-1:0] pi = 64'b011_0_0100_1000_0111_1110_1101_0101_0001_0001_0000_1011_0100_0110_0001_0001_1010 >> (64-L);
//arctan(2^(-cnt)) ~ c1*2^(-cnt) - c2*2^(-3*cnt) {cnt>=1}, c0(pi/4){cnt==0}
localparam logic signed [L-1:0] c0 = pi >>> 2;
localparam logic signed [L-1:0] c1 = 64'b01_00_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000 >> (65-L);
localparam logic signed [L-1:0] c2 = 64'b0100_1010_0111_0011_0001_1111_0101_0011_1100_1000_1001_0110_0001_0010_1110_1010 >> (67-L);


logic signed [L-1:0]          v_x, v_y, theta;
logic        [$clog2(L)-1:0]  cnt;

math_state_t                 state;

always_ff @(posedge cr.clk or negedge cr.rst_n) begin
    if(!cr.rst_n) begin
        {r, w} <= '0;
        {v_x, v_y, theta} <= '0;
        cnt <= '0;
        state <= S_IDLE;
    end
    else if(cr.clk_en) begin
        case(state)
        S_IDLE: begin
            if(start) begin
                logic signed [L-1:0] a, b;
                // bring x,y onto the datapath binary point (sign extended, and
                // left-shifted by L-IN_L-2 when L > IN_L+2).  fx_resize also
                // removes the old { {2{sign}}, x, {(L-IN_L-2){1'b0}} }, whose
                // zero-width replication XSim mis-evaluates as 1 bit.
                a = fx_resize(x, FW_IN, FW_DP);
                b = fx_resize(y, FW_IN, FW_DP);

                v_x <= (a < 0) ? -a : a;
                v_y <= (a < 0) ? -b : b;
                theta <= (a < 0) ? ((b < 0) ? -pi : pi) : '0;
                state <= S_WORKING;
            end
        end
        S_WORKING: begin
            // the per-iteration shift by cnt is the algorithm itself and is
            // genuinely data dependent, so it stays a plain >>> here
            if (v_y < 0) begin
                v_x <= v_x - (v_y >>> cnt);
                v_y <= v_y + (v_x >>> cnt);
                theta <= theta - ((cnt == '0) ? c0 : ( (c1 >>> cnt) - (c2 >>> (cnt*3)) ));
            end
            else begin
                v_x <= v_x + (v_y >>> cnt);
                v_y <= v_y - (v_x >>> cnt);
                theta <= theta + ((cnt == '0) ? c0 : ( (c1 >>> cnt) - (c2 >>> (cnt*3)) ));
            end
            cnt <= cnt + 1'b1;
            if(cnt == '1) begin
                state <= S_DONE;
            end
        end
        S_DONE: begin
            // The fxp_pkg functions carry a 64-bit result, so the truncation to
            // OUT_L bits is made explicit through a same-width intermediate:
            // assigning straight into r/w would raise WARN (EX3791) every time
            // and bury real warnings.  Values are unchanged.
            logic signed [63:0] rt, wt;
            rt = fx_mul(v_x, k, FW_DP, FW_DP, FW_OUT);   // = (v_x*k) >>> (2*FW_DP-FW_OUT)
            wt = fx_resize(theta, FW_DP, FW_OUT);        // = theta >>> (FW_DP-FW_OUT)
            r <= rt[OUT_L-1:0];
            w <= wt[OUT_L-1:0];
            if(~start) state <= S_IDLE;
        end
        endcase
    end
end

endmodule



/*
from polar to cartesian
using CORDIC algorithm

IN_L and OUT_L should smaller than 61

start: start converting
r,w: polar coordinate;    Q(IN_L-3)   -- same scale as cart2polar's r,w output
x,y: cartesian coordinate Q(OUT_L-3)  -- NOT cart2polar's input scale: x = r*cos(w)
                                         reaches +-sqrt(2) when r = sqrt(2), and
                                         s.xxx cannot hold that
*/
module polar2cart#(
    parameter int IN_L  = 8,
    parameter int OUT_L = 8
)(
    input  clk_rst                    cr,
    input  logic                      start,
    input  logic signed  [IN_L-1:0]   r,w,
    output logic signed  [OUT_L-1:0]  x,y
);

import math_state_pkg::*;

initial begin
    assert( (IN_L < 61) & (OUT_L < 61) );
end

localparam int L     = (IN_L > OUT_L) ? IN_L+2 : OUT_L+2;
localparam int FW_IN  = IN_L - 3;
localparam int FW_DP  = L - 3;
localparam int FW_OUT = OUT_L - 3;

// constants live in the datapath's binary point (1.0 = 2^FW_DP)
// 0.607252935... * 2^(63)
localparam logic signed [L-1:0] k  = 64'b0_100_1101_1011_1010_0111_0110_1101_0100_0010_0001_1010_1111_0010_1101_0011_0100 >> (66-L);
localparam logic signed [L-1:0] pi = 64'b011_0_0100_1000_0111_1110_1101_0101_0001_0001_0000_1011_0100_0110_0001_0001_1010 >> (64-L);
//arctan(2^(-cnt)) ~ c1*2^(-cnt) - c2*2^(-3*cnt) {cnt>=1}, c0(pi/4){cnt==0}
localparam logic signed [L-1:0] c0 = pi >>> 2;
localparam logic signed [L-1:0] c1 = 64'b01_00_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000 >> (65-L);
localparam logic signed [L-1:0] c2 = 64'b0100_1010_0111_0011_0001_1111_0101_0011_1100_1000_1001_0110_0001_0010_1110_1010 >> (67-L);


logic signed [L-1:0]          v_x, v_y, theta;
logic        [$clog2(L)-1:0]  cnt;

math_state_t                 state;

always_ff @(posedge cr.clk or negedge cr.rst_n) begin
    if(!cr.rst_n) begin
        {x, y} <= '0;
        {v_x, v_y, theta} <= '0;
        cnt <= '0;
        state <= S_IDLE;
    end
    else if(cr.clk_en) begin
        case(state)
        S_IDLE: begin
            if(start) begin
                logic signed [L-1:0] a, b, c, d;
                a = fx_resize(r, FW_IN, FW_DP);
                b = fx_resize(w, FW_IN, FW_DP);

                c = fx_mul(a, k, FW_DP, FW_DP, FW_DP);

                v_x <= (b < -(pi>>1) | b > (pi>>1)) ? -c : c;
                v_y <= '0;
                
                theta <= (b < -(pi>>1) | b > (pi>>1)) ? ((b > (pi>>1)) ? b-pi : b+pi) : b;
                state <= S_WORKING;
            end
        end
        S_WORKING: begin
            // the per-iteration shift by cnt is the algorithm itself and is
            // genuinely data dependent, so it stays a plain >>> here
            if (theta > 0) begin
                v_x <= v_x - (v_y >>> cnt);
                v_y <= v_y + (v_x >>> cnt);
                theta <= theta - ((cnt == '0) ? c0 : ( (c1 >>> cnt) - (c2 >>> (cnt*3)) ));
            end
            else begin
                v_x <= v_x + (v_y >>> cnt);
                v_y <= v_y - (v_x >>> cnt);
                theta <= theta + ((cnt == '0) ? c0 : ( (c1 >>> cnt) - (c2 >>> (cnt*3)) ));
            end
            cnt <= cnt + 1'b1;
            if(cnt == '1) begin
                state <= S_DONE;
            end
        end
        S_DONE: begin
            logic signed [63:0] xt, yt;
            xt = fx_resize(v_x, FW_DP, FW_OUT); 
            yt = fx_resize(v_y, FW_DP, FW_OUT); 
            x <= xt[OUT_L-1:0];
            y <= yt[OUT_L-1:0];
            if(~start) state <= S_IDLE;
        end
        endcase
    end
end

endmodule



/*
square root, digit by digit (restoring method)

x   : Q(IN_L-1), treated as a NON-NEGATIVE value (x < 0 gives 0)
y   : Q(OUT_L-1)

Why this algorithm and not Newton: a Newton sqrt needs a seed and a stopping
rule, and both are easy to get wrong (see inv).  Digit-by-digit produces
exactly one result bit per step from the MSB down, never needs a seed, has no
convergence criterion, and is exact -- the only error is the final truncation.

Math.  With x_int = x*2^FI and y_int = y*2^FO:

    y = sqrt(x)  =>  y_int = sqrt(x_int) * 2^(FO - FI/2)

so the radicand is scaled by 2^(2*FO - FI) before taking the INTEGER square
root:

    y_int = isqrt(x_int << (2*FO - FI)) = isqrt( fx_resize(x, FI, 2*FO) )

That scaling is just a binary-point move, so it is one fxp_pkg call.  The
scaled radicand is at most 2^(2*OUT_L-1), i.e. 2*OUT_L-1 significant bits, so
padding to 2*OUT_L bits gives OUT_L clean 2-bit groups and exactly OUT_L steps.

Each step, with `rem` the running remainder and `root` what has been produced:

    rem  <- (rem << 2) | next 2 radicand bits
    root <- root << 1
    if rem >= (root << 1) | 1:  rem -= (root << 1) | 1 ;  root |= 1

Timing.  One digit per clock is deliberate.  An unrolled single-cycle version of
the same recurrence measured 522 LUT / 23.8 MHz Fmax against 68 LUT / 155.3 MHz
here, so unrolling eats 42 ns of the clock period instead of 6.4 ns and gives up
6.5x of clock headroom.  A 522-LUT cone is also layout sensitive.  If throughput
ever matters more than Fmax, unrolling is the trade to make.
*/
module sqrt#(
    parameter int IN_L  = 8,
    parameter int OUT_L = 8
)(
    input  clk_rst                    cr,
    input  logic                      start,
    input  logic signed  [IN_L-1:0]   x,
    output logic signed  [OUT_L-1:0]  y
);

import math_state_pkg::*;

localparam int FI = IN_L  - 1;    // input binary point
localparam int FO = OUT_L - 1;    // output binary point
localparam int WN = 2*OUT_L;      // radicand width: OUT_L 2-bit groups
localparam int RW = OUT_L;        // root width
localparam int MW = OUT_L + 4;    // room for rem<<2 and the trial value

logic [WN-1:0]  nn;               // radicand, consumed 2 bits per step
logic [MW-1:0]  rem;
logic [RW-1:0]  root;
logic [$clog2(OUT_L+1)-1:0] cnt;
math_state_t    state;

always_ff @(posedge cr.clk or negedge cr.rst_n) begin
    if(!cr.rst_n) begin
        nn    <= '0;
        rem   <= '0;
        root  <= '0;
        cnt   <= '0;
        state <= S_IDLE;
    end
    else if(cr.clk_en) begin
        case(state)
        S_IDLE: begin
            if(start) begin
                if(x < 0) begin
                    root  <= '0;          // negative input is not defined
                    state <= S_DONE;
                end
                else begin
                    nn    <= fx_resize(x, FI, 2*FO);   // radicand on Q(2*FO)
                    rem   <= '0;
                    root  <= '0;
                    cnt   <= '0;
                    state <= S_WORKING;
                end
            end
        end
        S_WORKING: begin
            logic [RW:0]   rn;                 // root << 1
            logic [RW+1:0] tr;                 // (root << 1) | 1
            logic [MW-1:0] nrem;               // (rem << 2) | next pair

            rn   = {root, 1'b0};
            tr   = {rn,   1'b1};
            nrem = {rem[MW-3:0], nn[WN-1:WN-2]};

            if(nrem >= tr) begin
                rem  <= nrem - tr;
                root <= rn[RW-1:0] + 1'b1;     // rn lsb is 0, so +1 == |1
            end
            else begin
                rem  <= nrem;
                root <= rn[RW-1:0];
            end
            nn  <= nn << 2;
            cnt <= cnt + 1'b1;
            if(cnt == OUT_L-1) state <= S_DONE;
        end
        S_DONE: begin
            y <= root[OUT_L-1:0];
            if(~start) state <= S_IDLE;
        end
        endcase
    end
end

endmodule



/*
bounded reciprocal of x
using Newton iteration algorithm

y = 1/x,  x in Q(IN_L-1), y in Q(OUT_L-1), BOTH UNSIGNED, both in [0, 2)

Three things this module has to get right, each was a real bug before:

1. INITIAL GUESS.  Newton only doubles while it is far from the answer, so
   seeding at 1 LSB needed about L+3 iterations and the 2^clog2(L) loop was
   short of that (x=1.0 came out 0.866).  A linear seed
       y0 = 1.5 - 0.5*x
   is exact at x = 1 and x = 2, has relative error <= 0.375 on [0.5, 2), and
   converges in about 5 iterations.

2. INTERMEDIATE RANGE.  The iteration forms 2*y, which reaches 4.0 when
   x -> 0.5, but a Q(L-1) word only holds [0, 2).  It used to wrap and, once
   the iteration count was raised, diverge completely.  The datapath is
   therefore DW = L+2 bits wide (still Q(L-1), so [0, 8)).

3. BINARY POINTS.  x arrives in Q(IN_L-1) and the datapath is Q(L-1); those
   differ whenever OUT_L > IN_L, so the x <= 0.5 test compares against a
   threshold in the INPUT scale, not the datapath scale.

The datapath stays UNSIGNED throughout.  fxp_pkg functions work on unsigned
values because the operands are declared unsigned, which zero-extends them into
the 64-bit carrier; a signed declaration holding the same bits would sign
extend and give wrong products (measured: 1.5*1.5 came out 32 instead of 288).
*/
module inv#(
    parameter int IN_L  = 8,
    parameter int OUT_L = 8
)(
    input  clk_rst             cr,
    input  logic               start,
    input  logic  [IN_L-1:0]   x,
    output logic  [OUT_L-1:0]  y
);

import math_state_pkg::*;

localparam int L      = (IN_L > OUT_L) ? IN_L : OUT_L;
localparam int FW_IN  = IN_L - 1;        // input binary point
localparam int FW_DP  = L - 1;           // datapath binary point
localparam int FW_OUT = OUT_L - 1;       // output binary point
localparam int DW     = L + 2;           // extra headroom for 2*y up to 4.0

// 0.5 in the INPUT scale -- the smallest x we try to invert, because 1/x for
// x < 0.5 is >= 2.0 and does not fit the output format
localparam logic [IN_L-1:0] min_in  = 1 << (IN_L - 2);
// linear seed 1.5 - 0.5*x, in the datapath scale
localparam logic [DW-1:0] seed_half = 3 << (FW_DP - 1);   // 1.5

logic [DW-1:0]        xt, yt;
logic [$clog2(L)-1:0] cnt;
math_state_t state;

always_ff @(posedge cr.clk or negedge cr.rst_n) begin
    if(!cr.rst_n) begin
        yt <= '0;
        xt <= '0;
        cnt <= '0;
        state <= S_IDLE;
    end
    else if(cr.clk_en) begin
        case(state)
        S_IDLE: begin
            if(start) begin
                logic [DW-1:0] xs;
                xs = fx_resize(x, FW_IN, FW_DP);      // Q(IN_L-1) -> Q(L-1)
                if(x <= min_in) begin
                    // bounded reciprocal: 1/x >= 2.0 does not fit the output, so
                    // saturate.  All ones is enough: the S_DONE resize shifts
                    // and truncates, and truncating an all-ones value to any
                    // width still leaves all ones, i.e. the largest output code.
                    // This is a specified branch, not an overflow -- nothing is
                    // out of range here.
                    yt <= '1;
                    state <= S_DONE;
                end
                else begin
                    xt <= xs;
                    yt <= seed_half - (xs >> 1);      // 1.5 - 0.5*x
                    cnt <= '0;
                    state <= S_WORKING;
                end
            end
        end
        S_WORKING: begin
            logic signed [63:0] t;
            logic        [DW-1:0] c, d;
            // y_{k+1} = 2*y_k - x*y_k*y_k , all in Q(L-1) but DW bits wide.
            // The fxp_pkg call returns 64 bits; go through a 64-bit temporary
            // and slice explicitly -- a part-select directly on a function call
            // is illegal, and assigning straight into DW bits raises EX3791.
            t = fx_mul(xt, yt, FW_DP, FW_DP, FW_DP);   // c = x*y
            c = t[DW-1:0];
            t = fx_mul(c, yt, FW_DP, FW_DP, FW_DP);    // d = x*y*y
            d = t[DW-1:0];

            yt <= (yt << 1) - d;
            cnt <= cnt + 1'b1;
            if(cnt == '1) begin
                state <= S_DONE;
            end
        end
        S_DONE: begin
            // No clamp.  For x > 0.5 Newton stays below 1/x, so y < 2.0 and the
            // truncation to OUT_L bits cannot exceed the largest output code
            // (swept the whole x range: max y = 1.99991).  The saturating case
            // is the `yt <= '1` branch above, which lands there through this
            // same resize.
            logic [63:0] c;
            c = fx_resize(yt, FW_DP, FW_OUT);
            y <= c[OUT_L-1:0];
            if(~start) state <= S_IDLE;
        end
        endcase
    end
end

endmodule
