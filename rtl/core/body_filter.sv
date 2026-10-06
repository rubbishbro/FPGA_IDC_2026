// -----------------------------------------------------------------------------
// body_filter.sv -- shared 4-section (8th-order) body-filter accelerator.
//
// Pipelined version.  The arithmetic and all state values are bit-identical to
// the earlier single-cycle implementation; only the schedule changed.  The
// 100 MHz failure was the path
//     operand mux -> (sec*5 address MULT) -> coefficient mux -> 68x32 multiply
//     -> 100-bit product -> 104-bit accumulate -> round/clamp -> state
// all in one cycle.  It is now split:
//
//   * the section*5 dynamic address multiplier is removed: a registered
//     `tap_idx` counter (0..19) selects the coefficient, and a separate
//     registered `tap` (0..4) selects the operand.  No arithmetic address.
//   * three registered stages per tap: S_OP (latch op_s/op_c), S_MUL (register
//     the exact (64+G)+32-bit product), S_ACC (add/subtract the sign-extended
//     product into the 104-bit accumulator).  The multiply and the 104-bit add
//     are never in the same cycle.
//   * the per-section round is also pipelined so the clamp/compare chain is not
//     in the accumulator cycle: S_RNDA registers (acc+2**29)>>30, S_RNDB
//     registers the signed(64+G) clamp, S_UPD updates the section history, and
//     (last section only) S_FIN does the Q(30+G)->Q30 fold and signed64 clamp.
//     Then S_OUT.
//
// 20 taps * 3 cycles + 4 * (3 round/update stages) + final + output = ~74
// cycles (< 128).  No intermediate rounding, clamping or wrapping is
// introduced between stages: the product and accumulator are exact wide
// integers, so the frame result equals the DFI golden bit for bit.
//
// Numerical contract (rtl/body_design.md section 2, guard-bit variant):
//   * coefficients    : signed Q2.30, 32 bit
//   * external x / y  : signed 64 bit, Q30 (same scale as modal mix_sum)
//   * internal state  : signed (64+G) bit, Q(30+G); G = GUARD_BITS (default 4)
//   * product         : (64+G)+32 bit, sign extended into a >= 104-bit acc
//   * Direct Form I, sections in SOS order, one order-2 section at a time:
//         xin = in_sum << G
//         acc = b0*x + b1*x1 + b2*x2 - a1*y1 - a2*y2
//         y   = clamp_s(64+G)( (acc + 2**29) >>> 30 )          # Q(30+G)
//     only the last section folds back to the pins:
//         raw = (y + 2**(G-1)) >>> G
//         out = clamp_s64(raw);  its saturation is OR-ed into out_sat[3]
//
// Handshake / priority (unchanged):
//   * reset (rst_n, asynchronous) cancels any in-flight frame at any pipeline
//     stage, clears every history register and re-runs the ROM preload; no
//     ghost out_valid can survive it.
//   * clear_valid/clear_ready clears only the history (and the saturation
//     record) and keeps the coefficients; accepted only while idle and wins
//     over a coincident in_valid.
//   * in_valid/in_ready accepts a sample only in the idle state; while a frame
//     is in flight in_ready is low, so a held in_valid is not a second input.
//   * out_valid is a single cycle with no backpressure.
//
// The synchronous ROM preload only raises coeff_ready after all 20 words of
// the selected instrument have been captured.  If the init file is missing or
// short, iverilog leaves X in the ROM; the preload detects that and stays in
// S_ERR (coeff_error=1, coeff_ready=0) instead of faking a valid zero filter.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module body_filter #(
    parameter int BODY_INSTRUMENT = 0,             // 0..3 guitar/piano/banjo/mandolin
    parameter BODY_FILE = "rtl/rom/body_coeff.mem",
    parameter int GUARD_BITS = 4                   // internal extra fractional bits (>=1)
) (
    input  logic               clk,
    input  logic               rst_n,

    // synchronous history clear (accepted only while idle, keeps coefficients)
    input  logic               clear_valid,
    output logic               clear_ready,

    // sample input
    input  logic               in_valid,
    output logic               in_ready,
    input  logic signed [63:0] in_sum,

    // sample output (single cycle, no backpressure)
    output logic               out_valid,
    output logic signed [63:0] out_sum,
    output logic [3:0]         out_sat,
    output logic [2:0]         sat_count,

    // ROM / coefficient diagnostics
    output logic               coeff_ready,
    output logic               coeff_error
);

    localparam int NSEC   = 4;
    localparam int NTAP   = 5;
    localparam int ROM_WORDS = 80;
    localparam int COEFF_FRAC = 30;

    localparam int SW     = 64 + GUARD_BITS;       // internal state / interstage width
    localparam int ACC_W  = SW + 36;               // 104 for SW=68 (>= 100 required)
    localparam int FSW    = SW + 1;                // room for the final +2**(G-1)

    // mask the (static) instrument so an illegal parameter cannot index past
    // the ROM; the error is still reported below.
    localparam int BASE = (BODY_INSTRUMENT & 3) * (NSEC * NTAP);

    localparam logic [3:0] S_PRE  = 4'd0,
                           S_IDLE = 4'd1,
                           S_OP   = 4'd2,
                           S_MUL  = 4'd3,
                           S_ACC  = 4'd4,
                           S_RNDA = 4'd5,
                           S_RNDB = 4'd6,
                           S_UPD  = 4'd7,
                           S_FIN  = 4'd8,
                           S_OUT  = 4'd9,
                           S_ERR  = 4'd10;

    // ------------------------------------------------------------------
    // coefficient ROM + captured coefficients
    // ------------------------------------------------------------------
    logic [31:0]        rom [0:ROM_WORDS-1];
    logic signed [31:0] coef [0:NSEC*NTAP-1];

    initial begin
        $readmemh(BODY_FILE, rom);
    end

    logic [4:0] pre_idx;
    logic [3:0] state;

    // X detection is a simulation guard: a missing/short init file must not
    // masquerade as a valid all-zero filter.  Real synthesis has no X, so the
    // guard compiles out.
`ifdef SYNTHESIS
    wire pre_bad = 1'b0;
`else
    wire pre_bad = $isunknown(rom[BASE + pre_idx]);
`endif

    // ------------------------------------------------------------------
    // history state (per section), internal Q(30+GUARD_BITS)
    // ------------------------------------------------------------------
    logic signed [SW-1:0] x1 [0:NSEC-1];
    logic signed [SW-1:0] x2 [0:NSEC-1];
    logic signed [SW-1:0] y1 [0:NSEC-1];
    logic signed [SW-1:0] y2 [0:NSEC-1];

    // per-section saturation record, shifted one section at a time (removes the
    // sec==N clock-enable comparator from the critical control path; bit s ends
    // up holding section s's flag after the four S_UPD stages)
    logic [NSEC-1:0] sat_sr;

    // ------------------------------------------------------------------
    // pipeline control
    // ------------------------------------------------------------------
    logic [1:0]           sec;
    logic [2:0]           tap;
    logic [4:0]           tap_idx;
    logic signed [SW-1:0] sec_x;

    logic signed [SW-1:0] op_s;
    logic signed [31:0]   op_c;
    logic                 op_sub;

    logic signed [SW-1:0]  op_s_r;
    logic signed [31:0]    op_c_r;
    logic                  op_sub_r;
    logic signed [SW+31:0] prod_r;                 // 100 bit for SW=68
    logic signed [ACC_W-1:0] acc;

    // operand select: registered tap/sec only, no address arithmetic
    always_comb begin
        op_c   = coef[tap_idx];
        op_s   = sec_x;
        op_sub = 1'b0;
        case (tap)
            3'd1:    op_s = x1[sec];
            3'd2:    op_s = x2[sec];
            3'd3: begin op_s = y1[sec]; op_sub = 1'b1; end
            3'd4: begin op_s = y2[sec]; op_sub = 1'b1; end
            default: op_s = sec_x;
        endcase
    end

    logic signed [ACC_W-1:0] prodx_r;
    logic signed [ACC_W-1:0] acc_nxt;
    assign prodx_r = {{(ACC_W-(SW+32)){prod_r[SW+31]}}, prod_r};
    assign acc_nxt = op_sub_r ? (acc - prodx_r) : (acc + prodx_r);

    // ------------------------------------------------------------------
    // round / clamp pipeline (exact, unchanged arithmetic)
    // ------------------------------------------------------------------
    localparam logic signed [ACC_W-1:0] ROUND_C =
        {{(ACC_W-30){1'b0}}, 30'd536870912};                 // 2**29
    localparam logic signed [ACC_W-1:0] TWO_SW1 =
        {{(ACC_W-1){1'b0}}, 1'b1} <<< (SW-1);
    localparam logic signed [ACC_W-1:0] Y_MAX = TWO_SW1 - 1'b1;
    localparam logic signed [ACC_W-1:0] Y_MIN = -TWO_SW1;
    localparam logic signed [SW-1:0] STATE_MAX = {1'b0, {(SW-1){1'b1}}};
    localparam logic signed [SW-1:0] STATE_MIN = {1'b1, {(SW-1){1'b0}}};

    // stage A: rounding add (combinational from acc, registered in S_RNDA)
    logic signed [ACC_W-1:0] rounded_c;
    assign rounded_c = (acc + ROUND_C) >>> COEFF_FRAC;
    logic signed [ACC_W-1:0] rounded_r;

    // stage B: signed(64+G) clamp (combinational from rounded_r)
    logic                 sat68_c;
    logic signed [SW-1:0] y_state_c;
    always_comb begin
        if (rounded_r > Y_MAX) begin
            y_state_c = STATE_MAX;
            sat68_c   = 1'b1;
        end else if (rounded_r < Y_MIN) begin
            y_state_c = STATE_MIN;
            sat68_c   = 1'b1;
        end else begin
            y_state_c = rounded_r[SW-1:0];
            sat68_c   = 1'b0;
        end
    end
    logic                 sat68_r;
    logic signed [SW-1:0] y_state_r;

    // stage C: last-section Q(30+G) -> Q30 fold (combinational from y_state_r)
    localparam logic signed [FSW-1:0] FINAL_RND =
        {{(FSW-GUARD_BITS){1'b0}}, {1'b1, {(GUARD_BITS-1){1'b0}}}};
    localparam logic signed [FSW-1:0] TWO63_F =
        {{(FSW-1){1'b0}}, 1'b1} <<< 63;
    localparam logic signed [FSW-1:0] OUT_MAX = TWO63_F - 1'b1;
    localparam logic signed [FSW-1:0] OUT_MIN = -TWO63_F;

    logic signed [FSW-1:0] y_plus_c;
    logic signed [FSW-1:0] rawf_c;
    logic                 sat_final_c;
    logic signed [63:0]   y_final_c;
    assign y_plus_c = y_state_r + FINAL_RND;
    assign rawf_c   = y_plus_c >>> GUARD_BITS;
    always_comb begin
        if (rawf_c > OUT_MAX) begin
            y_final_c   = 64'sh7FFFFFFFFFFFFFFF;
            sat_final_c = 1'b1;
        end else if (rawf_c < OUT_MIN) begin
            y_final_c   = 64'sh8000000000000000;
            sat_final_c = 1'b1;
        end else begin
            y_final_c   = rawf_c[63:0];
            sat_final_c = 1'b0;
        end
    end

    // output staging
    logic signed [63:0] yout;

    // ------------------------------------------------------------------
    // handshake
    // ------------------------------------------------------------------
    assign clear_ready = (state == S_IDLE) && coeff_ready;
    assign in_ready    = (state == S_IDLE) && coeff_ready && !clear_valid;

    // ------------------------------------------------------------------
    // sequencer
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_PRE;
            pre_idx     <= 5'd0;
            coeff_ready <= 1'b0;
            coeff_error <= 1'b0;
            out_valid   <= 1'b0;
            out_sum     <= 64'sd0;
            out_sat     <= 4'd0;
            sat_count   <= 3'd0;
            sat_sr      <= {NSEC{1'b0}};
            sec         <= 2'd0;
            tap         <= 3'd0;
            tap_idx     <= 5'd0;
            sec_x       <= {SW{1'b0}};
            op_s_r      <= {SW{1'b0}};
            op_c_r      <= 32'sd0;
            op_sub_r    <= 1'b0;
            prod_r      <= {(SW+32){1'b0}};
            acc         <= {ACC_W{1'b0}};
            rounded_r   <= {ACC_W{1'b0}};
            y_state_r   <= {SW{1'b0}};
            sat68_r     <= 1'b0;
            yout        <= 64'sd0;
            for (int i = 0; i < NSEC; i = i + 1) begin
                x1[i] <= {SW{1'b0}};
                x2[i] <= {SW{1'b0}};
                y1[i] <= {SW{1'b0}};
                y2[i] <= {SW{1'b0}};
            end
        end else begin
            out_valid <= 1'b0;

            case (state)
                // ------------------------------------------------
                S_PRE: begin
                    if ((BODY_INSTRUMENT < 0) || (BODY_INSTRUMENT > 3)) begin
                        coeff_error <= 1'b1;
                        state       <= S_ERR;
                    end else if (pre_bad) begin
                        coeff_error <= 1'b1;
                        state       <= S_ERR;
                    end else begin
                        coef[pre_idx] <= rom[BASE + pre_idx];
                        if (pre_idx == (NSEC * NTAP - 1)) begin
                            coeff_ready <= 1'b1;
                            state       <= S_IDLE;
                        end else begin
                            pre_idx <= pre_idx + 5'd1;
                        end
                    end
                end

                // ------------------------------------------------
                S_ERR: state <= S_ERR;

                // ------------------------------------------------
                S_IDLE: begin
                    if (clear_valid) begin
                        for (int i = 0; i < NSEC; i = i + 1) begin
                            x1[i] <= {SW{1'b0}};
                            x2[i] <= {SW{1'b0}};
                            y1[i] <= {SW{1'b0}};
                            y2[i] <= {SW{1'b0}};
                        end
                        sat_sr <= {NSEC{1'b0}};
                    end else if (in_valid) begin
                        // explicit (64+G)-bit sign extension before the guard
                        // shift, so full signed64 inputs are not truncated
                        sec_x    <= {{GUARD_BITS{in_sum[63]}}, in_sum}
                                    <<< GUARD_BITS;
                        sec      <= 2'd0;
                        tap      <= 3'd0;
                        tap_idx  <= 5'd0;
                        acc      <= {ACC_W{1'b0}};
                        op_sub_r <= 1'b0;
                        sat_sr   <= {NSEC{1'b0}};
                        state    <= S_OP;
                    end
                end

                // ------------------------------------------------
                S_OP: begin
                    op_c_r   <= coef[tap_idx];
                    op_s_r   <= op_s;
                    op_sub_r <= op_sub;
                    state    <= S_MUL;
                end

                // ------------------------------------------------
                S_MUL: begin
                    prod_r <= op_c_r * op_s_r;
                    state  <= S_ACC;
                end

                // ------------------------------------------------
                S_ACC: begin
                    acc     <= acc_nxt;
                    // keep the coefficient index in 0..19: never form sec*5 and
                    // never read past the coefficient array
                    tap_idx <= (tap_idx == (NSEC * NTAP - 1)) ? 5'd0
                                                              : tap_idx + 5'd1;
                    if (tap == (NTAP - 1)) begin
                        tap   <= 3'd0;
                        state <= S_RNDA;
                    end else begin
                        tap   <= tap + 3'd1;
                        state <= S_OP;
                    end
                end

                // ------------------------------------------------
                S_RNDA: begin
                    rounded_r <= rounded_c;
                    state     <= S_RNDB;
                end

                S_RNDB: begin
                    y_state_r <= y_state_c;
                    sat68_r   <= sat68_c;
                    state     <= S_UPD;
                end

                // ------------------------------------------------
                S_UPD: begin
                    x2[sec]    <= x1[sec];
                    x1[sec]    <= sec_x;
                    y2[sec]    <= y1[sec];
                    y1[sec]    <= y_state_r;
                    // shift the section's saturation flag into place; the CE no
                    // longer depends on the section counter
                    sat_sr     <= {sat68_r, sat_sr[NSEC-1:1]};
                    if (sec == (NSEC - 1)) begin
                        state    <= S_FIN;
                    end else begin
                        sec_x      <= y_state_r;
                        sec        <= sec + 2'd1;
                        acc        <= {ACC_W{1'b0}};
                        state      <= S_OP;
                    end
                end

                // ------------------------------------------------
                S_FIN: begin
                    yout     <= y_final_c;
                    sat_sr[3] <= sat_sr[3] | sat_final_c;
                    state    <= S_OUT;
                end

                // ------------------------------------------------
                S_OUT: begin
                    out_valid <= 1'b1;
                    out_sum   <= yout;
                    out_sat   <= sat_sr;
                    sat_count <= sat_sr[0] + sat_sr[1] + sat_sr[2] + sat_sr[3];
                    state     <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
