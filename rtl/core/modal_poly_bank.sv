// -----------------------------------------------------------------------------
// modal_poly_bank.sv -- module 2C: 32-voice, four-lane TDM modal bank.
//
// Four poly_modal_lane instances, one per lane.  Every lane owns one signed
// 26x32 multiplier and one synchronous single-port 72-bit working cache holding
// all NUM_VOICES*LOCAL_MODES modes.  A frame is processed voice by voice: the
// four lanes run one voice in parallel, are drained, then the next active voice
// starts.  This is the "run one voice and drain" schedule permitted by
// rtl/module2BC_design.md section 4; it must be measured on 32x48 frames, not
// argued from the theoretical lower bound.
//
// Frame contract:
//   * priority reset > clear > cfg > sample; all three ready are 0 while busy
//   * an illegal request is accepted and rejected with error, no side effect
//   * the whole frame is range-checked before any state is updated, so an
//     illegal later voice cannot leave the earlier voices committed
//   * inactive voices are frozen; an active voice with n_modes=0 is legal and
//     produces a zero voice sum
//   * one voice_valid per active voice, then a single out_valid once every
//     state write-back has completed; outputs have no backpressure
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module modal_poly_bank #(
    parameter int NUM_VOICES = 32,
    parameter int N_MODES = 48,
    parameter int SKIP_ZERO_INPUT = 0,
    parameter int MW = (N_MODES < 1) ? 1 : $clog2(N_MODES + 1),
    parameter int VW = (NUM_VOICES < 2) ? 1 : $clog2(NUM_VOICES),
    parameter int LOCAL_MODES = (N_MODES + 3) / 4,
    parameter int IDXW = (LOCAL_MODES < 2) ? 1 : $clog2(LOCAL_MODES),
    parameter int SW = $clog2(NUM_VOICES * N_MODES + 1)
) (
    input  logic                   clk,
    input  logic                   rst_n,

    // coefficient configuration
    input  logic                   cfg_valid,
    output logic                   cfg_ready,
    input  logic [VW-1:0]          cfg_voice,
    input  logic [MW-1:0]          cfg_mode,
    input  logic [71:0]            cfg_word,

    // per-voice logical state clear
    input  logic                   clear_valid,
    output logic                   clear_ready,
    input  logic [VW-1:0]          clear_voice,
    output logic                   clear_done,

    // one-sample frame request
    input  logic                   sample_valid,
    output logic                   sample_ready,
    input  logic [NUM_VOICES-1:0]  active_mask,
    input  logic [NUM_VOICES*MW-1:0] n_modes_vec,
    input  logic [NUM_VOICES*32-1:0] x_vec,

    output logic                   busy,
    output logic                   out_valid,
    output logic signed [63:0]     mix_sum,
    output logic [SW-1:0]          sat_count,

    output logic                   voice_valid,
    output logic [VW-1:0]          voice_id,
    output logic signed [63:0]     voice_sum,

    output logic                   error_valid,
    output logic [1:0]             error_code,

    // per-lane write-back observability
    output logic [3:0]             commit_valid,
    output logic [4*VW-1:0]        commit_voice,
    output logic [4*MW-1:0]        commit_mode,
    output logic [127:0]           commit_y1,
    output logic [127:0]           commit_y2,
    output logic [3:0]             commit_sat
);

    localparam logic [2:0] IDLE = 3'd0, PREP = 3'd6, VSELECT = 3'd7, VSTART = 3'd1,
                           VRUN = 3'd2, VEMIT = 3'd3, VNEXT = 3'd4, FINISH = 3'd5;

    logic [2:0] state;
    logic [N_MODES-1:0] coeff_loaded [0:NUM_VOICES-1];   // keeps state on clear
    localparam logic [N_MODES-1:0] MODE_ONE = {{(N_MODES-1){1'b0}}, 1'b1};

    // latched operational frame (drives the run; only written on PREP)
    logic [NUM_VOICES-1:0]    act_r;
    logic [NUM_VOICES*MW-1:0] nm_r;
    logic [NUM_VOICES*32-1:0] x_r;
    logic [VW-1:0]            vcur;

    // intake candidate scratch: captured on the sample handshake, consumed by
    // PREP only if the precheck passed.  A rejected candidate never reaches the
    // operational frame (dead token), so it has no observable side effect.
    logic [NUM_VOICES-1:0]    act_c;
    logic [NUM_VOICES*MW-1:0] nm_c;
    logic [NUM_VOICES*32-1:0] x_c;

    // registered per-voice selection (VSELECT) so the wide vcur-muxed
    // run_n/run_x/voice do not sit combinationally on the lane start path
    logic [MW-1:0]            run_n_r;
    logic signed [31:0]       run_x_r;
    logic [VW-1:0]            vcur_r;

    logic signed [63:0] mix_acc, voice_sum_r;
    logic [SW-1:0]      sat_acc;
    logic [5:0]         voice_sat_r;

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------
    function automatic [VW-1:0] first_act(input [NUM_VOICES-1:0] m);
        integer i;
        begin
            first_act = {VW{1'b0}};
            for (i = NUM_VOICES - 1; i >= 0; i = i - 1)
                if (m[i]) first_act = i[VW-1:0];
        end
    endfunction

    function automatic [VW-1:0] next_act(input [NUM_VOICES-1:0] m,
                                         input [VW-1:0] from);
        integer i;
        begin
            next_act = {VW{1'b0}};
            for (i = NUM_VOICES - 1; i >= 0; i = i - 1)
                if (m[i] && (i > from)) next_act = i[VW-1:0];
        end
    endfunction

    function automatic logic has_next_act(input [NUM_VOICES-1:0] m,
                                          input [VW-1:0] from);
        integer i;
        begin
            has_next_act = 1'b0;
            for (i = 0; i < NUM_VOICES; i = i + 1)
                if (m[i] && (i > from)) has_next_act = 1'b1;
        end
    endfunction

    // Lowest mode index that is not loaded for a voice (N_MODES when the whole
    // row is present).  A voice is fully loaded for n modes iff n <= this value,
    // which is logically identical to ((~coeff_loaded & mask(n)) != 0) but lets
    // the whole-frame precheck use a short width-MW comparison instead of a
    // variable-width mask shift.  Updated register-resident so the long n_modes
    // vector does not reach a wide barrel shifter on the same-edge reject path.
    function automatic [MW-1:0] lowest_missing(input [N_MODES-1:0] loaded);
        integer k;
        begin
            lowest_missing = N_MODES;
            for (k = N_MODES - 1; k >= 0; k = k - 1)
                if (!loaded[k]) lowest_missing = k;
        end
    endfunction

    wire has_active = |act_r;
    wire has_next   = has_next_act(act_r, vcur);

    // ------------------------------------------------------------------
    // handshake arbitration
    // ------------------------------------------------------------------
    wire idle = (state == IDLE);
    assign busy         = ~idle;
    assign clear_ready  = idle;
    assign cfg_ready    = idle && !clear_valid;
    assign sample_ready = idle && !clear_valid && !cfg_valid;

    wire clear_fire  = clear_valid  && clear_ready;
    wire cfg_fire    = cfg_valid    && cfg_ready;
    wire sample_fire = sample_valid && sample_ready;

    wire clear_ok = clear_fire && (clear_voice < NUM_VOICES);
    wire cfg_ok   = cfg_fire && (cfg_mode < N_MODES) && (cfg_voice < NUM_VOICES);

    wire [1:0] cfg_lane = cfg_mode % 4;
    wire [IDXW-1:0] cfg_local_w = cfg_mode >> 2;

    // Whole-frame legality: checked before any state is touched (same-cycle
    // reject is part of the external contract: error_valid is asserted on the
    // handshake cycle and busy stays low).  A voice is not loaded iff its mode
    // count exceeds lowest_missing[v], the registered lowest unconfigured mode
    // index; this is logically identical to (~coeff_loaded[v] & mask(nv)) != 0
    // but replaces the wide variable shift with a shallow MW-bit compare.
    logic [MW-1:0] low_unloaded [0:NUM_VOICES-1];
    logic pre_n_oob, pre_not_loaded;
    logic [MW-1:0]       ck_nv;
    always_comb begin
        pre_n_oob      = 1'b0;
        pre_not_loaded = 1'b0;
        ck_nv          = {MW{1'b0}};
        for (int v = 0; v < NUM_VOICES; v = v + 1) begin
            if (active_mask[v]) begin
                ck_nv = n_modes_vec[v*MW +: MW];
                if (ck_nv > N_MODES) pre_n_oob = 1'b1;
                if (ck_nv > low_unloaded[v]) pre_not_loaded = 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------
    // four lanes
    // ------------------------------------------------------------------
    wire start_lane = (state == VSTART);
    // lane inputs come from the VSELECT-registered selection (not a live mux off
    // vcur/nm_r/x_r), so the wide per-voice mux is off the lane start/CE path.
    wire [MW-1:0] run_n   = run_n_r;
    wire signed [31:0] run_x = run_x_r;

    logic [3:0]           lane_done;
    logic [3:0]           lane_cvalid, lane_csat;
    logic [VW-1:0]        lane_cvoice [0:3];
    logic [MW-1:0]        lane_cmode  [0:3];
    logic signed [31:0]   lane_cy1    [0:3];
    logic signed [31:0]   lane_cy2    [0:3];
    logic signed [63:0]   lane_ps     [0:3];
    logic [5:0]           lane_sat    [0:3];
    logic [3:0]           lane_cfg_we;

    genvar gi;
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : g_lane
            assign lane_cfg_we[gi] = cfg_ok && (cfg_lane == gi[1:0]);
            poly_modal_lane #(
                .NUM_VOICES(NUM_VOICES),
                .N_MODES(N_MODES),
                .LANE(gi),
                .SKIP_ZERO_INPUT(SKIP_ZERO_INPUT),
                .MW(MW),
                .LOCAL_MODES(LOCAL_MODES),
                .VW(VW),
                .IDXW(IDXW)
            ) u_lane (
                .clk        (clk),
                .rst_n      (rst_n),
                .start      (start_lane),
                .n_modes    (run_n),
                .x_in       (run_x),
                .voice      (vcur_r),
                .clear      (clear_fire),
                .clear_voice(clear_voice),
                .cfg_we     (lane_cfg_we[gi]),
                .cfg_voice  (cfg_voice),
                .cfg_local  (cfg_local_w),
                .cfg_wdata  (cfg_word),
                .done       (lane_done[gi]),
                .commit_voice(lane_cvoice[gi]),
                .commit_mode(lane_cmode[gi]),
                .commit_y1  (lane_cy1[gi]),
                .commit_y2  (lane_cy2[gi]),
                .commit_sat (lane_csat[gi]),
                .commit_valid(lane_cvalid[gi]),
                .partial_sum(lane_ps[gi]),
                .sat_count  (lane_sat[gi])
            );
        end
    endgenerate

    always_comb begin
        commit_valid = lane_cvalid;
        commit_sat   = lane_csat;
        for (int i = 0; i < 4; i = i + 1) begin
            commit_voice[i*VW +: VW] = lane_cvoice[i];
            commit_mode[i*MW +: MW]  = lane_cmode[i];
            commit_y1[i*32 +: 32]    = lane_cy1[i];
            commit_y2[i*32 +: 32]    = lane_cy2[i];
        end
    end

    wire all_done = &lane_done;

    // ------------------------------------------------------------------
    // frame controller
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state        <= IDLE;
            act_r        <= '0;
            nm_r         <= '0;
            x_r          <= '0;
            act_c        <= '0;
            nm_c         <= '0;
            x_c          <= '0;
            vcur         <= {VW{1'b0}};
            run_n_r      <= {MW{1'b0}};
            run_x_r      <= 32'sd0;
            vcur_r       <= {VW{1'b0}};
            mix_acc      <= 64'sd0;
            sat_acc      <= '0;
            voice_sum_r  <= 64'sd0;
            voice_sat_r  <= 6'd0;
            clear_done   <= 1'b0;
            out_valid    <= 1'b0;
            mix_sum      <= 64'sd0;
            sat_count    <= '0;
            voice_valid  <= 1'b0;
            voice_id     <= {VW{1'b0}};
            voice_sum    <= 64'sd0;
            error_valid  <= 1'b0;
            error_code   <= 2'd0;
            for (int v = 0; v < NUM_VOICES; v = v + 1) begin
                coeff_loaded[v] <= '0;
                low_unloaded[v] <= {MW{1'b0}};
            end
        end else begin
            clear_done  <= 1'b0;
            out_valid   <= 1'b0;
            voice_valid <= 1'b0;
            error_valid <= 1'b0;

            case (state)
                IDLE: begin
                    if (clear_fire) begin
                        if (clear_voice >= NUM_VOICES) begin
                            error_valid <= 1'b1;
                            error_code  <= 2'd1;
                        end else begin
                            clear_done <= 1'b1;
                        end
                    end else if (cfg_fire) begin
                        if ((cfg_mode >= N_MODES) || (cfg_voice >= NUM_VOICES)) begin
                            error_valid <= 1'b1;
                            error_code  <= 2'd1;
                        end else begin
                            coeff_loaded[cfg_voice][cfg_mode] <= 1'b1;
                            // Same-edge prefix update from the row value the
                            // register will hold after this edge, so a sample on
                            // the very next edge sees the just-configured mode.
                            low_unloaded[cfg_voice] <=
                                lowest_missing(coeff_loaded[cfg_voice]
                                               | (MODE_ONE << cfg_mode));
                        end
                    end else if (sample_fire) begin
                        // Capture the candidate (scratch) and, only if the
                        // same-edge precheck passes, enter PREP.  The reject path
                        // keeps error_valid on this handshake edge with busy low
                        // and NEVER writes act_r/nm_r/x_r/mix_acc or any history.
                        act_c <= active_mask;
                        nm_c  <= n_modes_vec;
                        x_c   <= x_vec;
                        if (pre_n_oob) begin
                            error_valid <= 1'b1;
                            error_code  <= 2'd2;
                        end else if (pre_not_loaded) begin
                            error_valid <= 1'b1;
                            error_code  <= 2'd3;
                        end else begin
                            state <= PREP;
                        end
                    end
                end

                PREP: begin
                    // Accepted frame: copy the scratch candidate into the
                    // operational payload and initialise the accumulators.  The
                    // wide act_r/nm_r/x_r enables are driven by this shallow
                    // state decode, off the precheck/scan path.
                    act_r   <= act_c;
                    nm_r    <= nm_c;
                    x_r     <= x_c;
                    mix_acc <= 64'sd0;
                    sat_acc <= '0;
                    if (|act_c) begin
                        vcur  <= first_act(act_c);
                        state <= VSELECT;
                    end else begin
                        state <= FINISH;
                    end
                end

                VSELECT: begin
                    // Register the vcur-muxed per-voice inputs, then start the
                    // lanes from the registered copy.
                    run_n_r <= nm_r[vcur*MW +: MW];
                    run_x_r <= x_r[vcur*32 +: 32];
                    vcur_r  <= vcur;
                    state   <= VSTART;
                end

                VSTART: state <= VRUN;

                VRUN: begin
                    if (all_done) begin
                        voice_sum_r <= (lane_ps[0] + lane_ps[1])
                                     + (lane_ps[2] + lane_ps[3]);
                        voice_sat_r <= lane_sat[0] + lane_sat[1]
                                     + lane_sat[2] + lane_sat[3];
                        state <= VEMIT;
                    end
                end

                VEMIT: begin
                    voice_valid <= 1'b1;
                    voice_id    <= vcur;
                    voice_sum   <= voice_sum_r;
                    mix_acc     <= mix_acc + voice_sum_r;
                    sat_acc     <= sat_acc + voice_sat_r;
                    state       <= VNEXT;
                end

                VNEXT: begin
                    if (has_next) begin
                        vcur  <= next_act(act_r, vcur);
                        state <= VSELECT;
                    end else begin
                        state <= FINISH;
                    end
                end

                default: begin // FINISH
                    mix_sum   <= mix_acc;
                    sat_count <= sat_acc;
                    out_valid <= 1'b1;
                    state     <= IDLE;
                end
            endcase
        end
    end

endmodule
