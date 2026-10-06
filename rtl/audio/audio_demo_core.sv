// -----------------------------------------------------------------------------
// audio_demo_core.sv -- integration of modal_engine + song_player + audio_transport.
//
// Two exact clock inputs: clk_core (100 MHz) and clk_audio (12.288 MHz).  Mode is
// fixed before reset (MODE_SONG=1 default); the datapath is only ever started out
// of reset, so a MIC start can never see a stale song frame.
//
//   SONG: modal_engine + song_player -> output adapter -> audio_transport TX
//   MIC : i2s_mic_rx -> audio_transport RX -> output adapter -> TX (no synthesis)
//
// Output adaptation (rtl/audio_bringup_design.md section 3):
//   sum : Q2.30 signed 64 -> >>3, (+2^14)>>15, saturate int16   (3-bit demo pad)
//   mic : Q2.23 signed 24 -> >>2, (+2^7)>>8,   saturate int16   (2-bit field pad)
// Mono is duplicated to both PT8211 channels.
//
// The engine instance uses the module2BC_design.md section 5 external interface.
// It is provided by the 2B/2C implementer; this module does not define it.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module audio_demo_core #(
    parameter int NUM_VOICES  = 8,
    parameter int N_MODES     = 48,
    parameter int NOTE_GAP    = 12000,
    parameter int PULSE_LEN   = 7,
    parameter int MODE_SONG   = 1,      // 1 = SONG (default), 0 = MIC
    parameter int TX_DEPTH    = 16,
    parameter int RX_DEPTH    = 16,
    parameter int CH_SEL      = 0,
    parameter int OUT_FORMAT  = 1,      // 1 = standard I2S MAX98357A (default)
    parameter int SUM_ATT     = 3,      // demo pad before the 15-bit round shift
    parameter int MIC_ATT     = 2,      // demo pad before the 8-bit round shift
    parameter int ENABLE_BODY   = 0,    // 0 = bypass (baseline), 1 = insert body
    parameter int BODY_INSTRUMENT = 0,  // 0..3 guitar/piano/banjo/mandolin
    parameter COEFF_FILE = "rtl/rom/modal_coeff.mem",
    parameter INDEX_FILE = "rtl/rom/modal_index.mem",
    parameter BODY_FILE  = "rtl/rom/body_coeff.mem"
) (
    input  logic        clk_core,
    input  logic        clk_audio,
    input  logic        rst_n,
    input  logic        diag_clear,

    // serial
    input  logic        mic_sd,
    output logic        dac_bck,
    output logic        dac_ws,
    output logic        dac_din,
    output logic        mic_bck,
    output logic        mic_ws,

    // timing / diagnostics
    output logic        core_sample_tick,
    output logic        core_sample_pulse,
    output logic        underflow_sticky,
    output logic        overflow_sticky,     // RX FIFO full, mic sample dropped
    output logic        tx_overflow_sticky,  // adapter could not hand a song frame on
    output logic        body_overflow_sticky,// body input hold could not keep a frame
    output logic        playback_ready,      // see below
    output logic        deadline_error,
    output logic        engine_error_valid,
    output logic [2:0]  engine_error_code,
    output logic        engine_busy
);

    localparam int VW = (NUM_VOICES < 2) ? 1 : $clog2(NUM_VOICES);
    localparam int MW = (N_MODES < 1) ? 1 : $clog2(N_MODES + 1);

    wire mode_song = (MODE_SONG != 0);

    // ------------------------------------------------------------------
    // core-domain reset release
    // ------------------------------------------------------------------
    logic [1:0] crst_sync;
    always_ff @(posedge clk_core or negedge rst_n)
        if (!rst_n) crst_sync <= 2'b00;
        else        crst_sync <= {crst_sync[0], 1'b1};
    wire core_rst_n = crst_sync[1];

    wire sp_rst_n = core_rst_n & mode_song;

    // ------------------------------------------------------------------
    // transport
    // ------------------------------------------------------------------
    logic        core_tx_valid, core_tx_ready;
    logic [31:0] core_tx_data;
    logic        core_rx_valid, core_rx_ready;
    logic [23:0] core_rx_data;

    audio_transport #(
        .TX_DEPTH(TX_DEPTH), .RX_DEPTH(RX_DEPTH), .CH_SEL(CH_SEL),
        .OUT_FORMAT(OUT_FORMAT)
    ) u_transport (
        .clk_core        (clk_core),
        .clk_audio       (clk_audio),
        .rst_n           (rst_n),
        .mic_en          (~mode_song),
        .diag_clear      (diag_clear),
        .core_tx_valid   (core_tx_valid),
        .core_tx_ready   (core_tx_ready),
        .core_tx_data    (core_tx_data),
        .core_rx_valid   (core_rx_valid),
        .core_rx_ready   (core_rx_ready),
        .core_rx_data    (core_rx_data),
        .mic_sd          (mic_sd),
        .dac_bck         (dac_bck),
        .dac_ws          (dac_ws),
        .dac_din         (dac_din),
        .mic_bck         (mic_bck),
        .mic_ws          (mic_ws),
        .core_sample_tick(core_sample_tick),
        .core_sample_pulse(core_sample_pulse),
        .underflow_sticky(underflow_sticky),
        .overflow_sticky (overflow_sticky)
    );

    // ------------------------------------------------------------------
    // modal engine (2B/2C interface) + song player
    // ------------------------------------------------------------------
    logic                  sp_load_valid, sp_load_ready;
    logic [VW-1:0]         sp_load_voice;
    logic [1:0]            sp_load_instrument;
    logic [6:0]            sp_load_midi;
    logic                  sp_load_dyn;
    logic                  sp_load_done;
    logic [VW-1:0]         sp_done_voice;
    logic [MW-1:0]         sp_loaded_n_modes;

    logic                  sp_sample_valid, sp_sample_ready;
    logic [NUM_VOICES-1:0] sp_active_mask;
    logic [NUM_VOICES*32-1:0] sp_x_vec;

    logic                  sp_engine_out_valid;
    logic signed [63:0]    sp_engine_mix_sum;

    logic                  sp_out_valid;
    logic signed [63:0]    sp_out_sum;

    song_player #(
        .NUM_VOICES(NUM_VOICES), .N_MODES(N_MODES),
        .NOTE_GAP(NOTE_GAP), .PULSE_LEN(PULSE_LEN)
    ) u_song (
        .clk             (clk_core),
        .rst_n           (sp_rst_n),
        .diag_clear      (diag_clear),
        .load_valid      (sp_load_valid),
        .load_ready      (sp_load_ready),
        .load_voice      (sp_load_voice),
        .load_instrument (sp_load_instrument),
        .load_midi       (sp_load_midi),
        .load_dyn        (sp_load_dyn),
        .load_done       (sp_load_done),
        .done_voice      (sp_done_voice),
        .loaded_n_modes  (sp_loaded_n_modes),
        .sample_valid    (sp_sample_valid),
        .sample_ready    (sp_sample_ready),
        .active_mask     (sp_active_mask),
        .x_vec           (sp_x_vec),
        .engine_out_valid(sp_engine_out_valid),
        .engine_mix_sum  (sp_engine_mix_sum),
        .sample_tick     (core_sample_pulse),
        .out_valid       (sp_out_valid),
        .out_sum         (sp_out_sum),
        .deadline_error  (deadline_error),
        .busy            (),
        .event_index     ()
    );

    modal_engine #(
        .NUM_VOICES(NUM_VOICES), .N_MODES(N_MODES), .SKIP_ZERO_INPUT(1),
        .COEFF_FILE(COEFF_FILE), .INDEX_FILE(INDEX_FILE)
    ) u_engine (
        .clk            (clk_core),
        .rst_n          (sp_rst_n),
        .load_valid     (sp_load_valid),
        .load_ready     (sp_load_ready),
        .load_voice     (sp_load_voice),
        .load_instrument(sp_load_instrument),
        .load_midi      (sp_load_midi),
        .load_dyn       (sp_load_dyn),
        .sample_valid   (sp_sample_valid),
        .sample_ready   (sp_sample_ready),
        .active_mask    (sp_active_mask),
        .x_vec          (sp_x_vec),
        .busy           (engine_busy),
        .load_done      (sp_load_done),
        .done_voice     (sp_done_voice),
        .loaded_n_modes (sp_loaded_n_modes),
        .out_valid      (sp_engine_out_valid),
        .mix_sum        (sp_engine_mix_sum),
        .sat_count      (),
        .voice_valid    (),
        .voice_id       (),
        .voice_sum      (),
        .commit_valid   (),
        .commit_voice   (),
        .commit_mode    (),
        .commit_y1      (),
        .commit_y2      (),
        .commit_sat     (),
        .error_valid    (engine_error_valid),
        .error_code     (engine_error_code)
    );

    // ------------------------------------------------------------------
    // optional shared body filter (guitar by default), inserted between the
    // real song mix and the output adapter.  A one-deep input hold absorbs the
    // engine's single-cycle out_valid while the body is busy; a frame that
    // cannot be held at all sets a sticky diagnostic (never silently dropped).
    // The body history is cleared by rst_n; the module's own clear port is a
    // unit-tested feature not driven by this demo.
    // ------------------------------------------------------------------
    logic               body_src_valid;
    logic signed [63:0] body_src_sum;

    generate
        if (ENABLE_BODY != 0) begin : g_body
            logic               body_in_valid, body_in_ready;
            logic signed [63:0] body_in_sum;
            logic               body_out_valid;
            logic signed [63:0] body_out_sum;
            logic [3:0]         body_out_sat;
            logic [2:0]         body_sat_count;
            logic               body_coeff_ready, body_coeff_error;
            logic               body_buf_valid;
            logic signed [63:0] body_buf_data;
            logic               body_ovf_r;

            body_filter #(
                .BODY_INSTRUMENT (BODY_INSTRUMENT),
                .BODY_FILE       (BODY_FILE)
            ) u_body (
                .clk         (clk_core),
                .rst_n       (core_rst_n),
                .clear_valid (1'b0),
                .clear_ready (),
                .in_valid    (body_in_valid),
                .in_ready    (body_in_ready),
                .in_sum      (body_in_sum),
                .out_valid   (body_out_valid),
                .out_sum     (body_out_sum),
                .out_sat     (body_out_sat),
                .sat_count   (body_sat_count),
                .coeff_ready (body_coeff_ready),
                .coeff_error (body_coeff_error)
            );

            assign body_in_valid = body_buf_valid | sp_out_valid;
            assign body_in_sum   = body_buf_valid ? body_buf_data : sp_out_sum;
            wire body_take       = body_in_valid & body_in_ready;
            wire body_live_drop  = sp_out_valid & body_buf_valid;
            wire body_live_hold  = sp_out_valid & ~body_buf_valid & ~body_in_ready;

            always_ff @(posedge clk_core or negedge core_rst_n) begin
                if (!core_rst_n) begin
                    body_buf_valid <= 1'b0;
                    body_buf_data  <= 64'sd0;
                    body_ovf_r     <= 1'b0;
                end else begin
                    if (diag_clear) body_ovf_r <= 1'b0;
                    if (body_take && body_buf_valid) body_buf_valid <= 1'b0;
                    if (body_live_hold) begin
                        body_buf_valid <= 1'b1;
                        body_buf_data  <= sp_out_sum;
                    end
                    if (body_live_drop) body_ovf_r <= 1'b1;
                end
            end

            assign body_src_valid = body_out_valid;
            assign body_src_sum   = body_out_sum;
            assign body_overflow_sticky = body_ovf_r;
        end else begin : g_nobody
            assign body_src_valid = 1'b0;
            assign body_src_sum   = 64'sd0;
            assign body_overflow_sticky = 1'b0;
        end
    endgenerate

    // ------------------------------------------------------------------
    // output adaptation
    // ------------------------------------------------------------------
    function automatic logic signed [15:0] sum_to_i16(input logic signed [63:0] s);
        logic signed [63:0] t;
        begin
            t = s >>> SUM_ATT;
            t = (t + 64'sd16384) >>> 15;      // +2^14
            if (t > 64'sd32767)       sum_to_i16 = 16'sh7FFF;
            else if (t < -64'sd32768) sum_to_i16 = 16'sh8000;
            else                      sum_to_i16 = t[15:0];
        end
    endfunction

    function automatic logic signed [15:0] mic_to_i16(input logic signed [23:0] m);
        logic signed [23:0] t;
        begin
            t = m >>> MIC_ATT;
            t = (t + 24'sd128) >>> 8;         // +2^7
            if (t > 24'sd32767)       mic_to_i16 = 16'sh7FFF;
            else if (t < -24'sd32768) mic_to_i16 = 16'sh8000;
            else                      mic_to_i16 = t[15:0];
        end
    endfunction

    logic        src_valid;
    logic [15:0] src_i16;

    always_comb begin
        if (mode_song) begin
            if (ENABLE_BODY != 0) begin
                src_valid = body_src_valid;
                src_i16   = sum_to_i16(body_src_sum);
            end else begin
                src_valid = sp_out_valid;
                src_i16   = sum_to_i16(sp_out_sum);
            end
        end else begin
            src_valid = core_rx_valid;
            src_i16   = mic_to_i16($signed(core_rx_data));
        end
    end

    wire [31:0] src_pair = {src_i16, src_i16};   // same mono sample on L and R

    // one-deep hold; a new song frame arriving with no room is flagged, never
    // overwriting the frame already waiting to be sent.
    logic        tx_hold_valid;
    logic [31:0] tx_hold;
    logic        tx_overflow_r;

    wire hold_free = (~tx_hold_valid) | core_tx_ready;

    assign core_rx_ready = mode_song ? 1'b0 : hold_free;

    wire src_fire = src_valid & hold_free;

    always_ff @(posedge clk_core or negedge core_rst_n) begin
        if (!core_rst_n) begin
            tx_hold_valid <= 1'b0;
            tx_hold       <= 32'd0;
            tx_overflow_r <= 1'b0;
        end else begin
            if (diag_clear) tx_overflow_r <= 1'b0;

            if (tx_hold_valid && core_tx_ready) tx_hold_valid <= 1'b0;

            if (src_fire) begin
                tx_hold_valid <= 1'b1;
                tx_hold       <= src_pair;
            end else if (mode_song && src_valid && !hold_free) begin
                tx_overflow_r <= 1'b1;          // unsent song frame dropped
            end
        end
    end

    assign core_tx_valid     = tx_hold_valid;
    assign core_tx_data      = tx_hold;
    assign tx_overflow_sticky= tx_overflow_r;

    // ------------------------------------------------------------------
    // playback_ready: sticky once the first real sample has been handed to the
    // TX FIFO (core_tx_valid & core_tx_ready).  This says "the audio producer
    // has actually started", NOT that sound has been verified.  It stays 0 if
    // no sample is ever produced (e.g. a load that never completes), so a board
    // layer can use it (together with clock lock / frame priming) to avoid
    // enabling the amplifier on a silent, stuck datapath.  Cleared by reset.
    // ------------------------------------------------------------------
    logic playback_ready_r;
    always_ff @(posedge clk_core or negedge core_rst_n)
        if (!core_rst_n)                       playback_ready_r <= 1'b0;
        else if (core_tx_valid & core_tx_ready) playback_ready_r <= 1'b1;

    assign playback_ready = playback_ready_r;

endmodule
