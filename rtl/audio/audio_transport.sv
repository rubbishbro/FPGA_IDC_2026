// -----------------------------------------------------------------------------
// audio_transport.sv -- core <-> audio serial transport.
//
// Two clock domains, one shared asynchronous-assert reset whose release is
// synchronised separately in each domain.  The only crossings are:
//   * the two audio_async_fifo pointers (Gray, 2 FF)
//   * the 48 kHz frame-toggle and the sticky diagnostic levels (2 FF levels)
// No data bus is ever directly synchronised.
//
//   core --(core_tx_* --> TX FIFO --> pt8211_tx)--> DAC_BCK/WS/DIN
//   MIC_BCK/WS/SD --> i2s_mic_rx --> RX FIFO -->(core_rx_*)--> core
//
// TX FIFO default 16 stereo pairs, RX FIFO default 16 samples.
// An empty TX FIFO produces a zero frame and a sticky underflow; a full RX FIFO
// drops the new microphone sample and raises a sticky overflow (old samples are
// never overwritten).
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module audio_transport #(
    parameter int TX_DEPTH = 16,
    parameter int RX_DEPTH = 16,
    parameter int CH_SEL   = 0,
    // static output format: 1 = standard I2S (MAX98357A, default),
    //                       0 = PT8211 Japanese/LSBJ (explicit opt-in only)
    parameter int OUT_FORMAT = 1
) (
    input  logic        clk_core,
    input  logic        clk_audio,
    input  logic        rst_n,          // shared async assert

    input  logic        mic_en,         // static; 0 in SONG mode
    input  logic        diag_clear,     // core-domain diagnostic clear

    // core-domain DAC producer
    input  logic        core_tx_valid,
    output logic        core_tx_ready,
    input  logic [31:0] core_tx_data,

    // core-domain microphone consumer
    output logic        core_rx_valid,
    input  logic        core_rx_ready,
    output logic [23:0] core_rx_data,

    // audio serial
    input  logic        mic_sd,
    output logic        dac_bck,
    output logic        dac_ws,
    output logic        dac_din,
    output logic        mic_bck,
    output logic        mic_ws,

    // core-domain timing and sticky diagnostics
    output logic        core_sample_tick,    // 48 kHz toggle, 2 FF synchronised
    output logic        core_sample_pulse,   // one core clk per frame
    output logic        underflow_sticky,
    output logic        overflow_sticky
);

    // ------------------------------------------------------------------
    // per-domain synchronised reset release
    // ------------------------------------------------------------------
    logic [1:0] arst_sync, crst_sync;
    always_ff @(posedge clk_audio or negedge rst_n)
        if (!rst_n) arst_sync <= 2'b00;
        else        arst_sync <= {arst_sync[0], 1'b1};

    always_ff @(posedge clk_core or negedge rst_n)
        if (!rst_n) crst_sync <= 2'b00;
        else        crst_sync <= {crst_sync[0], 1'b1};

    wire arst_n = arst_sync[1];
    wire crst_n = crst_sync[1];

    // ------------------------------------------------------------------
    // diag_clear is a core-domain *event* (one or a few core cycles, never a
    // held level).  A single core-cycle pulse would be missed by a level 2-FF
    // synchroniser in the (slower) audio domain, so it is converted to a
    // toggle, synchronised, and re-detected as a one-clk audio event.  One
    // event is always delivered regardless of source pulse width; two events
    // closer than the synchroniser latency (~2 audio clks) would merge.
    // ------------------------------------------------------------------
    logic dc_prev, dc_tgl;
    always_ff @(posedge clk_core or negedge crst_n)
        if (!crst_n) begin
            dc_prev <= 1'b0;
            dc_tgl  <= 1'b0;
        end else begin
            dc_prev <= diag_clear;
            if (diag_clear & ~dc_prev) dc_tgl <= ~dc_tgl;
        end

    logic dt_s1, dt_s2, dt_p;
    always_ff @(posedge clk_audio or negedge arst_n)
        if (!arst_n) begin
            dt_s1 <= 1'b0; dt_s2 <= 1'b0; dt_p <= 1'b0;
        end else begin
            dt_s2 <= dt_s1; dt_s1 <= dc_tgl; dt_p <= dt_s2;
        end
    wire a_diag_clear = dt_s2 ^ dt_p;

    // ------------------------------------------------------------------
    // TX path: core -> TX FIFO -> selected serial transmitter
    //   OUT_FORMAT=1 : standard I2S (MAX98357A), the default
    //   OUT_FORMAT=0 : PT8211 Japanese/LSBJ, explicit opt-in
    // ------------------------------------------------------------------
    logic        tx_rvalid, tx_rready;
    logic [31:0] tx_rdata;
    logic        tx_underflow, tx_frame_tick;

    audio_async_fifo #(.WIDTH(32), .DEPTH(TX_DEPTH)) u_tx_fifo (
        .wclk  (clk_core),
        .rclk  (clk_audio),
        .rst_n (rst_n),
        .wvalid(core_tx_valid),
        .wready(core_tx_ready),
        .wdata (core_tx_data),
        .rvalid(tx_rvalid),
        .rready(tx_rready),
        .rdata (tx_rdata),
        .wfull (),
        .rempty()
    );

    generate
        if (OUT_FORMAT == 0) begin : g_pt8211
            pt8211_tx u_tx (
                .clk             (clk_audio),
                .rst_n           (arst_n),
                .diag_clear      (a_diag_clear),
                .in_valid        (tx_rvalid),
                .in_ready        (tx_rready),
                .in_data         (tx_rdata),
                .dac_bck         (dac_bck),
                .dac_ws          (dac_ws),
                .dac_din         (dac_din),
                .underflow_pulse (),
                .underflow_sticky(tx_underflow),
                .frame_tick      (tx_frame_tick)
            );
        end else begin : g_i2s_amp
            i2s_amp_tx u_tx (
                .clk             (clk_audio),
                .rst_n           (arst_n),
                .diag_clear      (a_diag_clear),
                .in_valid        (tx_rvalid),
                .in_ready        (tx_rready),
                .in_data         (tx_rdata),
                .amp_bclk        (dac_bck),
                .amp_ws          (dac_ws),
                .amp_din         (dac_din),
                .underflow_pulse (),
                .underflow_sticky(tx_underflow),
                .frame_tick      (tx_frame_tick)
            );
        end
    endgenerate

    // ------------------------------------------------------------------
    // RX path: i2s_mic_rx -> RX FIFO -> core
    // ------------------------------------------------------------------
    logic        mic_valid;
    logic [23:0] mic_data;
    logic        rx_wready;

    i2s_mic_rx #(.CH_SEL(CH_SEL)) u_mic (
        .clk      (clk_audio),
        .rst_n    (arst_n & mic_en),
        .sd       (mic_sd),
        .mic_bck  (mic_bck),
        .mic_ws   (mic_ws),
        .mic_data (mic_data),
        .mic_valid(mic_valid)
    );

    wire rx_wvalid = mic_valid & mic_en;

    audio_async_fifo #(.WIDTH(24), .DEPTH(RX_DEPTH)) u_rx_fifo (
        .wclk  (clk_audio),
        .rclk  (clk_core),
        .rst_n (rst_n),
        .wvalid(rx_wvalid),
        .wready(rx_wready),
        .wdata (mic_data),
        .rvalid(core_rx_valid),
        .rready(core_rx_ready),
        .rdata (core_rx_data),
        .wfull (),
        .rempty()
    );

    // ------------------------------------------------------------------
    // sticky overflow (audio domain), cleared by the synchronised diag_clear
    // ------------------------------------------------------------------
    logic rx_overflow;
    always_ff @(posedge clk_audio or negedge arst_n)
        if (!arst_n)                     rx_overflow <= 1'b0;
        else if (rx_wvalid & ~rx_wready) rx_overflow <= 1'b1;
        else if (a_diag_clear)           rx_overflow <= 1'b0;

    // ------------------------------------------------------------------
    // 48 kHz frame toggle (audio domain) -> core
    // ------------------------------------------------------------------
    logic tick_tgl;
    always_ff @(posedge clk_audio or negedge arst_n)
        if (!arst_n)            tick_tgl <= 1'b0;
        else if (tx_frame_tick) tick_tgl <= ~tick_tgl;

    logic tgl_s1, tgl_s2, tgl_prev;
    always_ff @(posedge clk_core or negedge crst_n)
        if (!crst_n) begin
            tgl_s1   <= 1'b0;
            tgl_s2   <= 1'b0;
            tgl_prev <= 1'b0;
        end else begin
            tgl_s2   <= tgl_s1;
            tgl_s1   <= tick_tgl;
            tgl_prev <= tgl_s2;
        end

    assign core_sample_tick  = tgl_s2;
    assign core_sample_pulse = tgl_s2 ^ tgl_prev;

    // ------------------------------------------------------------------
    // sticky diagnostics synchronised to core (level, not bare pulse).
    // Exposing the synchronised audio-domain sticky level directly (rather than
    // latching it in core) means an event-delivered diag_clear really clears the
    // core-visible flag: when the audio sticky drops, so does this output.
    // ------------------------------------------------------------------
    logic uf_s1, uf_s2, of_s1, of_s2;
    always_ff @(posedge clk_core or negedge crst_n)
        if (!crst_n) begin
            uf_s1 <= 1'b0; uf_s2 <= 1'b0;
            of_s1 <= 1'b0; of_s2 <= 1'b0;
        end else begin
            uf_s2 <= uf_s1; uf_s1 <= tx_underflow;
            of_s2 <= of_s1; of_s1 <= rx_overflow;
        end

    assign underflow_sticky = uf_s2;
    assign overflow_sticky  = of_s2;

endmodule
