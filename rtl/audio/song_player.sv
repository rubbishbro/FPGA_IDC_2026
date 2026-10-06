// -----------------------------------------------------------------------------
// song_player.sv -- automatic public-domain melody front-end for modal_engine.
//
// Drives the engine's load and sample ports and sequences them so that one
// sample frame is produced per 48 kHz tick.  Offline event->voice assignment:
// event k is loaded into voice k % NUM_VOICES (a fixed cyclic allocator, *not*
// the stage-4 automatic allocator).  A slot's tail is kept because loaded voices
// stay in active_mask; slots are only reassigned when the allocator reaches them
// again.
//
// Timeline:
//   * one sample is emitted per sample_tick (a core-domain pulse derived from the
//     audio frame toggle).  A tick that arrives while the previous sample is
//     still being processed is not lost: it is counted and deadline_error is
//     set, never silently skipped.
//   * note gap default NOTE_GAP=12000 samples (250 ms at 48 kHz); the melody
//     loops after a trailing gap.
//   * each event first loads its target slot through the engine load handshake;
//     the 7-sample raised-cosine excitation starts at the next accepted sample.
//     The pulse position only advances when the sample request is truly accepted
//     (sample_ready), never on a valid that was not taken.
//
// The 7 pulse values are the integer model's raised-cosine pulse, amplitude 0.2,
// quantised with the same round-half-up rule as python/modal_sim/fixed_point.py.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module song_player #(
    parameter int NUM_VOICES = 8,
    parameter int N_MODES    = 48,
    parameter int NOTE_GAP   = 12000,
    parameter int PULSE_LEN  = 7,
    parameter int VW = (NUM_VOICES < 2) ? 1 : $clog2(NUM_VOICES),
    parameter int MW = (N_MODES < 1) ? 1 : $clog2(N_MODES + 1)
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  diag_clear,

    // engine load port
    output logic                  load_valid,
    input  logic                  load_ready,
    output logic [VW-1:0]         load_voice,
    output logic [1:0]            load_instrument,
    output logic [6:0]            load_midi,
    output logic                  load_dyn,
    input  logic                  load_done,
    input  logic [VW-1:0]         done_voice,
    input  logic [MW-1:0]         loaded_n_modes,

    // engine sample port
    output logic                  sample_valid,
    input  logic                  sample_ready,
    output logic [NUM_VOICES-1:0] active_mask,
    output logic [NUM_VOICES*32-1:0] x_vec,
    input  logic                  engine_out_valid,
    input  logic signed [63:0]    engine_mix_sum,

    // pacing (one core-domain pulse per 48 kHz audio frame)
    input  logic                  sample_tick,

    // produced sample for the output adapter
    output logic                  out_valid,
    output logic signed [63:0]    out_sum,

    // diagnostics / observability
    output logic                  deadline_error,
    output logic                  busy,
    output logic [5:0]            event_index
);

    localparam int CW = (NOTE_GAP < 2) ? 1 : $clog2(NOTE_GAP);
    localparam int EW = 10;                         // {dyn, midi[6:0], inst[1:0]}
    localparam int NUM_EVENTS = 42;

    // ------------------------------------------------------------------
    // public-domain Twinkle-Twinkle melody, guitar (inst=0) forte (dyn=1)
    // ------------------------------------------------------------------
    function automatic [EW-1:0] event_at(input [5:0] idx);
        case (idx)
            6'd0 : event_at = {1'b1, 7'd60, 2'd0};
            6'd1 : event_at = {1'b1, 7'd60, 2'd0};
            6'd2 : event_at = {1'b1, 7'd67, 2'd0};
            6'd3 : event_at = {1'b1, 7'd67, 2'd0};
            6'd4 : event_at = {1'b1, 7'd69, 2'd0};
            6'd5 : event_at = {1'b1, 7'd69, 2'd0};
            6'd6 : event_at = {1'b1, 7'd67, 2'd0};
            6'd7 : event_at = {1'b1, 7'd65, 2'd0};
            6'd8 : event_at = {1'b1, 7'd65, 2'd0};
            6'd9 : event_at = {1'b1, 7'd64, 2'd0};
            6'd10: event_at = {1'b1, 7'd64, 2'd0};
            6'd11: event_at = {1'b1, 7'd62, 2'd0};
            6'd12: event_at = {1'b1, 7'd62, 2'd0};
            6'd13: event_at = {1'b1, 7'd60, 2'd0};
            6'd14: event_at = {1'b1, 7'd67, 2'd0};
            6'd15: event_at = {1'b1, 7'd67, 2'd0};
            6'd16: event_at = {1'b1, 7'd65, 2'd0};
            6'd17: event_at = {1'b1, 7'd65, 2'd0};
            6'd18: event_at = {1'b1, 7'd64, 2'd0};
            6'd19: event_at = {1'b1, 7'd64, 2'd0};
            6'd20: event_at = {1'b1, 7'd62, 2'd0};
            6'd21: event_at = {1'b1, 7'd67, 2'd0};
            6'd22: event_at = {1'b1, 7'd67, 2'd0};
            6'd23: event_at = {1'b1, 7'd65, 2'd0};
            6'd24: event_at = {1'b1, 7'd65, 2'd0};
            6'd25: event_at = {1'b1, 7'd64, 2'd0};
            6'd26: event_at = {1'b1, 7'd64, 2'd0};
            6'd27: event_at = {1'b1, 7'd62, 2'd0};
            6'd28: event_at = {1'b1, 7'd60, 2'd0};
            6'd29: event_at = {1'b1, 7'd60, 2'd0};
            6'd30: event_at = {1'b1, 7'd67, 2'd0};
            6'd31: event_at = {1'b1, 7'd67, 2'd0};
            6'd32: event_at = {1'b1, 7'd69, 2'd0};
            6'd33: event_at = {1'b1, 7'd69, 2'd0};
            6'd34: event_at = {1'b1, 7'd67, 2'd0};
            6'd35: event_at = {1'b1, 7'd65, 2'd0};
            6'd36: event_at = {1'b1, 7'd65, 2'd0};
            6'd37: event_at = {1'b1, 7'd64, 2'd0};
            6'd38: event_at = {1'b1, 7'd64, 2'd0};
            6'd39: event_at = {1'b1, 7'd62, 2'd0};
            6'd40: event_at = {1'b1, 7'd62, 2'd0};
            6'd41: event_at = {1'b1, 7'd60, 2'd0};
            default: event_at = {1'b1, 7'd60, 2'd0};
        endcase
    endfunction

    // 7-sample raised-cosine pulse, amp 0.2, Q2.30 round-half-up
    function automatic logic signed [31:0] pulse_val(input [2:0] i);
        case (i)
            3'd0: pulse_val = 32'sd0;
            3'd1: pulse_val = 32'sd40427475;
            3'd2: pulse_val = 32'sd131267186;
            3'd3: pulse_val = 32'sd204114978;
            3'd4: pulse_val = 32'sd204114978;
            3'd5: pulse_val = 32'sd131267186;
            3'd6: pulse_val = 32'sd40427475;
            default: pulse_val = 32'sd0;
        endcase
    endfunction

    // ------------------------------------------------------------------
    // state
    // ------------------------------------------------------------------
    localparam logic [2:0] S_IDLE = 3'd0, S_LOAD = 3'd1, S_LOADW = 3'd2,
                           S_SAMPLE = 3'd3, S_SAMPLEW = 3'd4, S_DONE = 3'd5;

    logic [2:0]            state;
    logic [7:0]            pending;
    logic [5:0]            ev_idx;
    logic [CW-1:0]         samp_cnt;

    logic [VW-1:0]         ld_voice;
    logic [1:0]            ld_inst;
    logic [6:0]            ld_midi;
    logic                  ld_dyn;

    logic [NUM_VOICES-1:0] loaded_mask;
    logic [2:0]            pulse_pos [0:NUM_VOICES-1];

    logic signed [63:0]    sum_r;
    logic                  valid_r;
    logic                  deadline_r;

    wire [EW-1:0] cur_ev = event_at(ev_idx);
    wire [VW-1:0] next_voice = ev_idx % NUM_VOICES;

    assign active_mask     = loaded_mask;
    assign load_valid      = (state == S_LOAD);
    assign sample_valid    = (state == S_SAMPLE);
    assign load_voice      = ld_voice;
    assign load_instrument = ld_inst;
    assign load_midi       = ld_midi;
    assign load_dyn        = ld_dyn;

    assign out_valid       = valid_r;
    assign out_sum         = sum_r;
    assign deadline_error  = deadline_r;
    assign busy            = (state != S_IDLE);
    assign event_index     = ev_idx;

    always_comb begin
        for (int v = 0; v < NUM_VOICES; v = v + 1) begin
            if (pulse_pos[v] < PULSE_LEN)
                x_vec[v*32 +: 32] = pulse_val(pulse_pos[v]);
            else
                x_vec[v*32 +: 32] = 32'sd0;
        end
    end

    // ------------------------------------------------------------------
    // main FSM
    // ------------------------------------------------------------------
    // A tick is never lost: it is merged into the pending counter even when it
    // lands in the same cycle a pending sample starts.  A tick that arrives
    // while a sample is still being processed (or already pending) raises the
    // sticky deadline flag.
    wire        busy_now  = (state != S_IDLE);
    wire        miss_now  = sample_tick & (busy_now | (pending != 8'd0));
    wire [7:0]  pend_inc  = (pending == 8'hFF) ? pending : (pending + 8'd1);
    wire [7:0]  pend_base = sample_tick ? pend_inc : pending;
    wire        start_now = (state == S_IDLE) && (pending != 8'd0);
    wire [7:0]  pend_nxt  = start_now ? (pend_base - 8'd1) : pend_base;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            pending    <= 8'd0;
            ev_idx     <= 6'd0;
            samp_cnt   <= {CW{1'b0}};
            ld_voice   <= {VW{1'b0}};
            ld_inst    <= 2'd0;
            ld_midi    <= 7'd0;
            ld_dyn     <= 1'b0;
            loaded_mask<= {NUM_VOICES{1'b0}};
            sum_r      <= 64'sd0;
            valid_r    <= 1'b0;
            deadline_r <= 1'b0;
            for (int v = 0; v < NUM_VOICES; v = v + 1)
                pulse_pos[v] <= 3'd7;               // no active pulse
        end else begin
            valid_r <= 1'b0;
            if (diag_clear) deadline_r <= 1'b0;

            if (miss_now) deadline_r <= 1'b1;
            pending <= pend_nxt;

            case (state)
                S_IDLE: begin
                    if (start_now) begin
                        if (samp_cnt == {CW{1'b0}}) begin
                            ld_voice <= next_voice;
                            ld_inst  <= cur_ev[1:0];
                            ld_midi  <= cur_ev[8:2];
                            ld_dyn   <= cur_ev[9];
                            state    <= S_LOAD;
                        end else begin
                            state <= S_SAMPLE;
                        end
                    end
                end

                S_LOAD: begin
                    if (load_ready) state <= S_LOADW;
                end

                S_LOADW: begin
                    if (load_done) begin
                        loaded_mask[done_voice] <= 1'b1;
                        pulse_pos[done_voice]   <= 3'd0;   // arm pulse
                        ev_idx <= (ev_idx == (NUM_EVENTS-1)) ? 6'd0
                                                             : (ev_idx + 6'd1);
                        state  <= S_SAMPLE;
                    end
                end

                S_SAMPLE: begin
                    if (sample_ready) begin
                        // accepted: advance the pulse positions and the timeline
                        for (int v = 0; v < NUM_VOICES; v = v + 1)
                            if (pulse_pos[v] < PULSE_LEN)
                                pulse_pos[v] <= pulse_pos[v] + 3'd1;
                        if (samp_cnt == (NOTE_GAP-1))
                            samp_cnt <= {CW{1'b0}};
                        else
                            samp_cnt <= samp_cnt + 1'b1;
                        state <= S_SAMPLEW;
                    end
                end

                S_SAMPLEW: begin
                    if (engine_out_valid) begin
                        sum_r   <= engine_mix_sum;
                        valid_r <= 1'b1;
                        state   <= S_DONE;
                    end
                end

                default: state <= S_IDLE;   // S_DONE
            endcase
        end
    end

endmodule
