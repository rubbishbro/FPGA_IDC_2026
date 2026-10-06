// -----------------------------------------------------------------------------
// modal_lane.sv -- one TDM lane of the modal bank (module 2A).
//
// One shared 26x32 signed logic multiplier, one synchronous-read single-port
// 72-bit working cache, II = 3 modes.
//
// Arithmetic contract (rtl/DECISIONS.md C, rtl/module2A_design.md section 3):
//   G   Q2.24 signed   26 bit
//   a1  Q2.20 signed   22 bit  -> sign-extend, <<4 -> 26-bit Q2.24
//   a2  UQ0.24 unsigned 24 bit -> zero-extend -> 26-bit
//   x / y1 / y2  Q2.30 signed 32 bit
//   product signed 58 bit; accumulator 64 bit
//   acc = G*x - (a1<<4)*y1 - a2*y2
//   ynew = clamp((acc + 2^23) >>> 24, -2^31, 2^31-1)
//
// Storage per lane: mem[2*j] = 72-bit coefficient word, mem[2*j+1] = state
// {8'b0, y2, y1}.  One access per clock: config write, coefficient read, state
// read, state write are mutually exclusive.  The RAM array is never reset; a
// per-lane state_valid bitmap masks uninitialised contents with (0,0).
//
// Pipeline (see delivery report for the cycle table):
//   phase 0 : read coefficient of mode mi
//   phase 1 : read state of mode mi, present G*x for mode mi
//   phase 2 : present a1*y1 for mode mi, finalise mode mi-1, write mode mi-2
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module modal_lane #(
    parameter int N_MODES = 48,
    parameter int LANE = 0,
    parameter int SKIP_ZERO_INPUT = 0,
    parameter int MW = $clog2(N_MODES + 1),                       // global mode id width
    parameter int LOCAL_MODES = (N_MODES + 3) / 4,               // slots per lane
    parameter int ADDRW = ($clog2(2 * LOCAL_MODES) < 1) ? 1 : $clog2(2 * LOCAL_MODES),
    parameter int IDXW = (LOCAL_MODES > 1) ? $clog2(LOCAL_MODES) : 1
) (
    input  logic               clk,
    input  logic               rst_n,

    input  logic               start,        // one-cycle frame start pulse
    input  logic [MW-1:0]      n_modes,      // frame global mode count
    input  logic signed [31:0] x_in,         // frame shared excitation

    input  logic               clear,        // clear logical state (idle only)

    input  logic               cfg_we,       // configuration write to this lane
    input  logic [ADDRW-1:0]   cfg_addr,
    input  logic [71:0]        cfg_wdata,

    output logic               done,
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
    // single-port 72-bit working cache (read-first), never reset.
    // Only the LOCAL_MODES slots this lane can own are allocated.
    // ------------------------------------------------------------------
    logic [71:0]           mem [0:2*LOCAL_MODES-1];
    logic [71:0]           rdata;
    logic [ADDRW-1:0]      addr;
    logic                  we;
    logic [71:0]           wdata;

    always_ff @(posedge clk) begin
        if (we) mem[addr] <= wdata;
        rdata <= mem[addr];
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

    logic [LOCAL_MODES-1:0] state_valid;   // per-lane local-mode bitmap
    logic signed [63:0]  acc, ps;
    logic signed [57:0]  prod_r;
    logic [5:0]          sat;

    logic signed [25:0]  ctx_a1, ctx_a2;
    logic signed [31:0]  ctx_y2, ctx_oldy1;

    logic                pend_valid;
    logic [MW-1:0]       pend_local;
    logic signed [31:0]  pend_ynew, pend_oldy1;
    logic                pend_sat;

    // ------------------------------------------------------------------
    // multiplier operand select (one logical multiplier)
    // ------------------------------------------------------------------
    // clamped local-mode index for the bitmap (never an out-of-range select)
    wire [IDXW-1:0] mi_idx   = (mi < LOCAL_MODES) ? mi[IDXW-1:0] : {IDXW{1'b0}};
    wire [IDXW-1:0] pend_idx = (pend_local < LOCAL_MODES) ? pend_local[IDXW-1:0]
                                                          : {IDXW{1'b0}};

    wire signed [31:0] y1_use = ((st == S_RUN) && (mi < lc) &&
                                 state_valid[mi_idx]) ? $signed(rdata[31:0])
                                                      : 32'sd0;
    wire signed [31:0] y2_use = ((st == S_RUN) && (mi < lc) &&
                                 state_valid[mi_idx]) ? $signed(rdata[63:32])
                                                      : 32'sd0;

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
    // result is forced to zero (no operand hack, no timing change).
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

    // run-port access.  Full-width 2*local(+1) is formed first, then the low
    // ADDRW bits are taken; no part-select of a narrower signal.
    logic              run_we;
    logic [ADDRW-1:0]  run_addr;
    logic [71:0]       run_wdata;
    logic [MW:0]       run_addr_full;
    always_comb begin
        run_we        = 1'b0;
        run_addr      = {ADDRW{1'b0}};
        run_wdata     = 72'd0;
        run_addr_full = {(MW + 1){1'b0}};
        if (st == S_RUN) begin
            case (ph)
                2'd0: begin
                    run_addr_full = {mi[MW-1:0], 1'b0};        // coefficient
                    if (mi < lc) run_addr = run_addr_full[ADDRW-1:0];
                end
                2'd1: begin
                    run_addr_full = {mi[MW-1:0], 1'b1};        // state
                    if (mi < lc) run_addr = run_addr_full[ADDRW-1:0];
                end
                default: begin
                    if (write_en) begin
                        run_we        = 1'b1;
                        run_addr_full = {pend_local, 1'b1};    // state to write back
                        run_addr      = run_addr_full[ADDRW-1:0];
                        run_wdata     = {8'b0, pend_oldy1, pend_ynew};
                    end
                end
            endcase
        end
    end

    always_comb begin
        addr  = cfg_we ? cfg_addr : run_addr;
        we    = cfg_we | run_we;
        wdata = cfg_we ? cfg_wdata : run_wdata;
    end

    assign done        = (st == S_DONE);
    assign partial_sum = ps;
    assign sat_count   = sat;

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
            state_valid  <= '0;
            acc          <= 64'sd0;
            ps           <= 64'sd0;
            sat          <= 6'd0;
            ctx_a1       <= 26'sd0;
            ctx_a2       <= 26'sd0;
            ctx_y2       <= 32'sd0;
            ctx_oldy1    <= 32'sd0;
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

            if (clear) begin
                state_valid <= '0;
                ps          <= 64'sd0;
                sat         <= 6'd0;
                pend_valid  <= 1'b0;
            end

            case (st)
                S_IDLE: begin
                    if (start) begin
                        lc  <= count_for(n_modes);
                        x_r <= x_in;
                        ph  <= 2'd0;
                        mi  <= 8'd0;
                        ps  <= 64'sd0;
                        sat <= 6'd0;
                        acc <= 64'sd0;
                        pend_valid <= 1'b0;
                        st  <= (count_for(n_modes) == {MW{1'b0}}) ? S_DONE : S_RUN;
                    end
                end

                S_RUN: begin
                    // capture coefficient of the current mode
                    if ((ph == 2'd1) && (mi < lc)) begin
                        ctx_a1 <= {rdata[21:0], 4'b0};        // a1 Q2.20 -> 26-bit
                        ctx_a2 <= {2'b0, rdata[45:22]};       // a2 UQ0.24 -> 26-bit
                    end
                    // capture state of the current mode
                    if ((ph == 2'd2) && (mi < lc)) begin
                        ctx_y2    <= y2_use;
                        ctx_oldy1 <= y1_use;
                    end

                    // accumulator: product available this phase
                    if (ph == 2'd2)      acc <= prod64;             // G*x
                    else if (ph == 2'd0) acc <= acc - prod64;       // a1*y1
                    else                 acc <= acc - prod64;       // a2*y2

                    // finalise the previous mode
                    if (finalize_en) begin
                        pend_valid  <= 1'b1;
                        pend_local  <= mi - 8'd1;
                        pend_ynew   <= ynew;
                        pend_oldy1  <= ctx_oldy1;
                        pend_sat    <= sat_now;
                        ps          <= ps + {{32{ynew[31]}}, ynew};
                        if (sat_now) sat <= sat + 6'd1;
                    end

                    // write back the mode that finished three cycles ago
                    if (write_en) begin
                        state_valid[pend_idx] <= 1'b1;
                        commit_valid <= 1'b1;
                        commit_mode  <= (pend_local << 2) | LANE;
                        commit_y1    <= pend_ynew;
                        commit_y2    <= pend_oldy1;
                        commit_sat   <= pend_sat;
                    end

                    // advance
                    if (last_cycle) begin
                        st <= S_DONE;
                    end else if (ph == 2'd2) begin
                        ph <= 2'd0;
                        mi <= mi + 8'd1;
                    end else begin
                        ph <= ph + 2'd1;
                    end
                end

                default: begin // S_DONE
                    if (start) begin
                        lc  <= count_for(n_modes);
                        x_r <= x_in;
                        ph  <= 2'd0;
                        mi  <= 8'd0;
                        ps  <= 64'sd0;
                        sat <= 6'd0;
                        acc <= 64'sd0;
                        pend_valid <= 1'b0;
                        st  <= (count_for(n_modes) == {MW{1'b0}}) ? S_DONE : S_RUN;
                    end
                end
            endcase
        end
    end

endmodule
