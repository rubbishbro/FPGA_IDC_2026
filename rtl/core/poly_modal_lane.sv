// -----------------------------------------------------------------------------
// poly_modal_lane.sv -- one TDM lane of the 32-voice modal bank (module 2C).
//
// Extends the verified module 2A lane (`modal_lane.sv`) with the voice
// dimension: one signed 26x32 multiplier, one synchronous single-port 72-bit
// working cache holding NUM_VOICES*LOCAL_MODES modes, and a per-voice state
// validity bitmap.  A state word is at
//
//     mem[2*(voice*LOCAL_MODES + local) + 0] = 72-bit coefficient word
//     mem[2*(voice*LOCAL_MODES + local) + 1] = {8'b0, y2, y1}
//
// All lanes use the same voice slot; global mode k maps to lane k%4, local k/4.
// The RAM is never reset; clear only drops the target voice's state_valid slice,
// leaving the coefficients (and every other voice) untouched.
//
// Arithmetic contract is identical to module 2A (rtl/module2A_design.md s.3):
//   G Q2.24 signed 26, a1 Q2.20 signed 22 (<<4), a2 UQ0.24 unsigned 24,
//   x/y Q2.30 signed 32, product signed 58, accumulator 64,
//   ynew = clamp((acc + 2^23) >>> 24, -2^31, 2^31-1).
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module poly_modal_lane #(
    parameter int NUM_VOICES = 32,
    parameter int N_MODES = 48,
    parameter int LANE = 0,
    parameter int SKIP_ZERO_INPUT = 0,
    parameter int MW = (N_MODES < 1) ? 1 : $clog2(N_MODES + 1),
    parameter int LOCAL_MODES = (N_MODES + 3) / 4,
    parameter int VW = (NUM_VOICES < 2) ? 1 : $clog2(NUM_VOICES),
    parameter int SLOTS = NUM_VOICES * LOCAL_MODES,
    parameter int ADDRW = (2 * SLOTS < 2) ? 1 : $clog2(2 * SLOTS),
    parameter int SVW = (SLOTS < 2) ? 1 : $clog2(SLOTS),
    parameter int IDXW = (LOCAL_MODES < 2) ? 1 : $clog2(LOCAL_MODES)
) (
    input  logic               clk,
    input  logic               rst_n,

    // one-voice frame
    input  logic               start,
    input  logic [MW-1:0]      n_modes,
    input  logic signed [31:0] x_in,
    input  logic [VW-1:0]      voice,

    // per-voice state clear (idle only)
    input  logic               clear,
    input  logic [VW-1:0]      clear_voice,

    // coefficient write
    input  logic               cfg_we,
    input  logic [VW-1:0]      cfg_voice,
    input  logic [IDXW-1:0]    cfg_local,
    input  logic [71:0]        cfg_wdata,

    output logic               done,
    output logic [VW-1:0]      commit_voice,
    output logic [MW-1:0]      commit_mode,
    output logic signed [31:0] commit_y1,
    output logic signed [31:0] commit_y2,
    output logic               commit_sat,
    output logic               commit_valid,
    output logic signed [63:0] partial_sum,
    output logic [5:0]         sat_count
);

    localparam logic signed [63:0] YMIN = -64'sd2147483648;
    localparam logic signed [63:0] YMAX =  64'sd2147483647;
    localparam logic signed [63:0] ROUND = 64'sd8388608;   // 2^23

    // ------------------------------------------------------------------
    // per-lane mode count: global mode k maps to lane k%4, local k/4
    // ------------------------------------------------------------------
    function automatic [MW-1:0] count_for(input [MW-1:0] nm);
        integer v;
        begin
            if (nm > LANE) v = (nm - LANE + 3) >> 2;
            else           v = 0;
            count_for = v[MW-1:0];
        end
    endfunction

    // ------------------------------------------------------------------
    // working cache (no-change synchronous single-port, never reset)
    //
    // On a write cycle the read is suppressed and `rdata` holds its previous
    // value; on a read cycle `rdata` captures mem[addr] at the clock edge.  This
    // avoids the read-first (WRITE_MODE=2'b10) inference that the Gowin SPX9
    // BSRAM cannot implement.  The datapath never relies on the RAM output
    // PRODUCED BY a write cycle: a write edge still consumes the state read in
    // the previous ph1 (its ctx_y2/y1 come from that earlier read), the newly
    // written value is not needed in the following ph0, and ph0 then reads the
    // next coefficient for ph1 to consume.  The ph2 write address (odd state
    // word) never equals the ph0 coeff / ph1 state read address consumed right
    // after it.  See sim/test_poly_lane_ram_write_mode.py and the parent's
    // sim/test_poly_lane_ram_equivalence_review.py for the cycle-by-cycle proof.
    // ------------------------------------------------------------------
    logic [71:0]           mem [0:2*SLOTS-1];
    logic [71:0]           rdata;
    logic [ADDRW-1:0]      addr;
    logic                  we;
    logic [71:0]           wdata;

    always_ff @(posedge clk) begin
        if (we) mem[addr] <= wdata;
        else    rdata    <= mem[addr];
    end

    // ------------------------------------------------------------------
    // state
    // ------------------------------------------------------------------
    localparam logic [1:0] S_IDLE = 2'd0, S_RUN = 2'd1, S_DONE = 2'd2;

    logic [1:0]          st;
    logic [1:0]          ph;
    logic [7:0]          mi;
    logic [MW-1:0]       lc;             // latched per-lane count
    logic signed [31:0]  x_r;
    logic [VW-1:0]       voice_r;

    logic [SLOTS-1:0]    state_valid;    // per (voice,local) bitmap
    logic signed [63:0]  acc, ps;
    logic signed [57:0]  prod_r;
    logic [5:0]          sat;

    logic signed [25:0]  ctx_a1, ctx_a2;
    logic signed [31:0]  ctx_y2, ctx_oldy1;

    logic                pend_valid;
    logic [MW-1:0]       pend_local;
    logic signed [31:0]  pend_ynew, pend_oldy1;
    logic                pend_sat;

    // Registered voice base = voice_r * LOCAL_MODES.  voice_r is latched once at
    // `start` and constant for the whole frame, so the base is registered at
    // start instead of being re-multiplied combinationally every phase (the
    // constant multiply otherwise mapped to a DSP with OREG=BYPASS feeding the
    // dynamic operand/state_valid select, a long address chain).  Purely an
    // addressing optimisation: identical indices, no arithmetic change.
    logic [SVW-1:0]      vb_r;
    wire [SVW-1:0]       vb_next = voice * LOCAL_MODES;

    // clamped local indices (never an out-of-range select)
    wire [IDXW-1:0] mi_cl = (mi < LOCAL_MODES) ? mi[IDXW-1:0] : {IDXW{1'b0}};
    wire [IDXW-1:0] pd_cl = (pend_local < LOCAL_MODES) ? pend_local[IDXW-1:0]
                                                       : {IDXW{1'b0}};
    wire [SVW-1:0]  sv_run  = vb_r + mi_cl;
    wire [SVW-1:0]  sv_pend = vb_r + pd_cl;

    // ------------------------------------------------------------------
    // Split the "mode-index -> valid lookup -> DSP operand" chain across the
    // phase pipeline (the lane already reads the state word in ph1 and consumes
    // it in ph2):
    //   ph0 : prefetch-register the run index sv_run_r = vb_r + mi_cl;
    //   ph1 : capture ctx_valid <= (S_RUN & mi<lc & state_valid[sv_run_r]) -- the
    //         lookup now uses the REGISTERED index, off the mi->lookup critical
    //         path, and the ph1 state read is the data ph2 consumes;
    //   ph2 : gate rdata's y1/y2 with the REGISTERED ctx_valid.
    // `mi` is constant across ph0..ph2 of a mode, and `clear` is accepted only
    // while idle (never during a run), so the registered valid bit stays aligned
    // with the mode; the pending write/commit path is unchanged.
    // ------------------------------------------------------------------
    logic [SVW-1:0] sv_run_r;
    logic           ctx_valid;
    wire            valid_now = (st == S_RUN) && (mi < lc) && state_valid[sv_run_r];

    // ------------------------------------------------------------------
    // multiplier operand select (one logical multiplier)
    // ------------------------------------------------------------------
    wire signed [31:0] y1_use = (ctx_valid) ? $signed(rdata[31:0]) : 32'sd0;
    wire signed [31:0] y2_use = (ctx_valid) ? $signed(rdata[63:32]) : 32'sd0;

    logic signed [25:0] csel;
    logic signed [31:0] osel;
    always_comb begin
        csel = 26'sd0;
        osel = 32'sd0;
        if (st == S_RUN) begin
            case (ph)
                2'd1: if (mi < lc) begin        // G * x  (rdata = coefficient)
                    csel = $signed(rdata[71:46]);
                    osel = x_r;
                end
                2'd2: if (mi < lc) begin        // a1 * y1 (rdata = state)
                    csel = ctx_a1;
                    osel = $signed(y1_use);
                end
                default: if ((mi >= 8'd1) && (mi <= lc)) begin
                    csel = ctx_a2;              // a2 * y2 (context of mi-1)
                    osel = ctx_y2;
                end
            endcase
        end
    end

    // SKIP_ZERO_INPUT: explicitly bypass the G*x product register when the frame
    // input is zero.  The single multiply point stays in place; only this slot's
    // result is forced to zero.
    wire skip_g_slot = (SKIP_ZERO_INPUT != 0) && (st == S_RUN) &&
                       (ph == 2'd1) && (mi < lc) && (x_r == 32'sd0);

    always_ff @(posedge clk) begin
        if (!rst_n)               prod_r <= 58'sd0;
        else if (skip_g_slot)     prod_r <= 58'sd0;
        else                      prod_r <= csel * osel;  // signed 58-bit product
    end

    wire signed [63:0] prod64 = {{6{prod_r[57]}}, prod_r};

    // finalise arithmetic for the mode whose products just completed
    wire signed [63:0] shifted = (acc + ROUND) >>> 24;
    wire               sat_now = (shifted > YMAX) || (shifted < YMIN);
    logic signed [31:0] ynew;
    always_comb begin
        if (shifted > YMAX)      ynew = 32'sh7FFFFFFF;
        else if (shifted < YMIN) ynew = 32'sh80000000;
        else                     ynew = shifted[31:0];
    end

    // ------------------------------------------------------------------
    // phase/mode control
    // ------------------------------------------------------------------
    wire finalize_en = (st == S_RUN) && (ph == 2'd2) && (mi >= 8'd1) && (mi <= lc);
    wire write_en    = (st == S_RUN) && (ph == 2'd2) && pend_valid;
    wire last_cycle  = (st == S_RUN) && (ph == 2'd2) && (mi == (lc + 8'd1));

    // run-port access
    logic              run_we;
    logic [ADDRW-1:0]  run_addr;
    logic [71:0]       run_wdata;
    logic [31:0]       run_addr_w;
    always_comb begin
        run_we     = 1'b0;
        run_addr_w = 32'd0;
        run_wdata  = 72'd0;
        if (st == S_RUN) begin
            case (ph)
                2'd0: run_addr_w = 2 * (vb_r + mi_cl) + 0;
                2'd1: run_addr_w = 2 * (vb_r + mi_cl) + 1;
                default: if (write_en) begin
                    run_we     = 1'b1;
                    run_addr_w = 2 * (vb_r + pd_cl) + 1;
                    run_wdata  = {8'b0, pend_oldy1, pend_ynew};
                end
            endcase
        end
    end
    assign run_addr = run_addr_w[ADDRW-1:0];

    wire [31:0] cfg_addr_w = 2 * ((cfg_voice * LOCAL_MODES) + cfg_local);

    always_comb begin
        addr  = cfg_we ? cfg_addr_w[ADDRW-1:0] : run_addr;
        we    = cfg_we | run_we;
        wdata = cfg_we ? cfg_wdata : run_wdata;
    end

    assign done        = (st == S_DONE);
    assign partial_sum = ps;
    assign sat_count   = sat;
    assign commit_voice= voice_r;

    // ------------------------------------------------------------------
    // main sequential process
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            st           <= S_IDLE;
            ph           <= 2'd0;
            mi           <= 8'd0;
            lc           <= {MW{1'b0}};
            x_r          <= 32'sd0;
            voice_r      <= {VW{1'b0}};
            vb_r         <= {SVW{1'b0}};
            state_valid  <= '0;
            acc          <= 64'sd0;
            ps           <= 64'sd0;
            sat          <= 6'd0;
            ctx_a1       <= 26'sd0;
            ctx_a2       <= 26'sd0;
            ctx_y2       <= 32'sd0;
            ctx_oldy1    <= 32'sd0;
            sv_run_r     <= {SVW{1'b0}};
            ctx_valid    <= 1'b0;
            pend_valid   <= 1'b0;
            pend_local   <= {MW{1'b0}};
            pend_ynew    <= 32'sd0;
            pend_oldy1   <= 32'sd0;
            pend_sat     <= 1'b0;
            commit_valid <= 1'b0;
            commit_mode  <= {MW{1'b0}};
            commit_y1    <= 32'sd0;
            commit_y2    <= 32'sd0;
            commit_sat   <= 1'b0;
        end else begin
            commit_valid <= 1'b0;

            // Static per-voice clear decoder: the compiler elaborates one
            // constant slice `v*LOCAL_MODES` per voice, so no voice*LOCAL_MODES
            // multiply/DSP is generated and an out-of-range clear_voice naturally
            // matches no slice.  Priority vs the pending write is unchanged
            // (clear is accepted only while idle, never during a run).
            for (int v = 0; v < NUM_VOICES; v = v + 1)
                if (clear && (clear_voice == v[VW-1:0]))
                    state_valid[v*LOCAL_MODES +: LOCAL_MODES] <= '0;

            case (st)
                S_IDLE, S_DONE: begin
                    if (start) begin
                        lc         <= count_for(n_modes);
                        x_r        <= x_in;
                        voice_r    <= voice;
                        vb_r       <= vb_next;
                        ph         <= 2'd0;
                        mi         <= 8'd0;
                        ps         <= 64'sd0;
                        sat        <= 6'd0;
                        acc        <= 64'sd0;
                        pend_valid <= 1'b0;
                        st         <= (count_for(n_modes) == {MW{1'b0}}) ? S_DONE
                                                                         : S_RUN;
                    end
                end

                S_RUN: begin
                    // ph0: prefetch the run index for the ph1 valid lookup
                    if (ph == 2'd0) sv_run_r <= sv_run;
                    // ph1: capture the (registered-index) state-valid for ph2
                    if (ph == 2'd1) ctx_valid <= valid_now;

                    if ((ph == 2'd1) && (mi < lc)) begin
                        ctx_a1 <= {rdata[21:0], 4'b0};        // a1 Q2.20 -> 26-bit
                        ctx_a2 <= {2'b0, rdata[45:22]};       // a2 UQ0.24 -> 26-bit
                    end
                    if ((ph == 2'd2) && (mi < lc)) begin
                        ctx_y2    <= y2_use;
                        ctx_oldy1 <= y1_use;
                    end

                    if (ph == 2'd2)      acc <= prod64;             // G*x
                    else if (ph == 2'd0) acc <= acc - prod64;       // a1*y1
                    else                 acc <= acc - prod64;       // a2*y2

                    if (finalize_en) begin
                        // finalize only fills the pending token (rounded/clamped
                        // ynew is a registered boundary here)
                        pend_valid  <= 1'b1;
                        pend_local  <= mi - 8'd1;
                        pend_ynew   <= ynew;
                        pend_oldy1  <= ctx_oldy1;
                        pend_sat    <= sat_now;
                    end

                    if (write_en) begin
                        // accumulate the partial sum / saturation from the
                        // REGISTERED pending token (not from the live acc->ynew
                        // clamp), so the 64-bit ps adder is off that chain; the
                        // set of accumulated values and the done-time partial_sum
                        // are bit-identical.
                        ps                   <= ps + {{32{pend_ynew[31]}}, pend_ynew};
                        if (pend_sat) sat    <= sat + 6'd1;
                        state_valid[sv_pend] <= 1'b1;
                        commit_valid <= 1'b1;
                        commit_mode  <= (pend_local << 2) | LANE;
                        commit_y1    <= pend_ynew;
                        commit_y2    <= pend_oldy1;
                        commit_sat   <= pend_sat;
                    end

                    if (last_cycle) begin
                        st <= S_DONE;
                    end else if (ph == 2'd2) begin
                        ph <= 2'd0;
                        mi <= mi + 8'd1;
                    end else begin
                        ph <= ph + 2'd1;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
