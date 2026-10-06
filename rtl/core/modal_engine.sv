// -----------------------------------------------------------------------------
// modal_engine.sv -- module 2B/2C integration.
//
// Wires the coefficient loader (2B) to the 32-voice poly bank (2C):
//   * the external load port is the loader interface
//   * on a successful load_done the engine stores that voice's mode count and
//     loaded flag; only loaded voices may be activated in a frame (else error 4)
//   * loading and sampling are mutually exclusive; while idle a simultaneous
//     load/sample request resolves in favour of load and never handshakes both
//   * base allocation (voice n/count/loaded flags) lives here so the frame
//     sender cannot forge a mode count
//   * reset cancels compute and load and clears every loaded flag
//
//   error_code 1..3 = load error (voice OOB / missing entry / illegal ROM meta)
//              4    = an active voice has not been successfully loaded
//              5    = internal bank error
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module modal_engine #(
    parameter int NUM_VOICES = 32,
    parameter int N_MODES = 48,
    parameter int SKIP_ZERO_INPUT = 0,
    parameter int COEFF_DEPTH = 5483,
    parameter int INDEX_DEPTH = 1024,
    parameter COEFF_FILE = "rtl/rom/modal_coeff.mem",
    parameter INDEX_FILE = "rtl/rom/modal_index.mem",
    parameter int MW = (N_MODES < 1) ? 1 : $clog2(N_MODES + 1),
    parameter int VW = (NUM_VOICES < 2) ? 1 : $clog2(NUM_VOICES),
    parameter int SW = $clog2(NUM_VOICES * N_MODES + 1)
) (
    input  logic                   clk,
    input  logic                   rst_n,

    // load request (same as the loader port)
    input  logic                   load_valid,
    output logic                   load_ready,
    input  logic [VW-1:0]          load_voice,
    input  logic [1:0]             load_instrument,
    input  logic [6:0]             load_midi,
    input  logic                   load_dyn,
    output logic                   busy,
    output logic                   load_done,
    output logic [VW-1:0]          done_voice,
    output logic [MW-1:0]          loaded_n_modes,

    // one-sample frame request
    input  logic                   sample_valid,
    output logic                   sample_ready,
    input  logic [NUM_VOICES-1:0]  active_mask,
    input  logic [NUM_VOICES*32-1:0] x_vec,

    output logic                   out_valid,
    output logic signed [63:0]     mix_sum,
    output logic [SW-1:0]          sat_count,

    output logic                   voice_valid,
    output logic [VW-1:0]          voice_id,
    output logic signed [63:0]     voice_sum,

    output logic [3:0]             commit_valid,
    output logic [4*VW-1:0]        commit_voice,
    output logic [4*MW-1:0]        commit_mode,
    output logic [127:0]           commit_y1,
    output logic [127:0]           commit_y2,
    output logic [3:0]             commit_sat,

    output logic                   error_valid,
    output logic [2:0]             error_code
);

    localparam logic [1:0] E_IDLE = 2'd0, E_PREP = 2'd1, E_DRIVE = 2'd2, E_WAIT = 2'd3;

    logic [1:0]     estate;
    logic [NUM_VOICES-1:0] voice_loaded;
    logic [MW-1:0]  voice_nm [0:NUM_VOICES-1];
    logic           error4_r;

    logic [NUM_VOICES-1:0]    act_r;
    logic [NUM_VOICES*32-1:0] x_r;

    // intake candidate scratch: captured on the sample handshake, consumed by
    // E_PREP only for a frame whose precheck passed.  A rejected candidate is a
    // dead token and never reaches the operational payload (no observable side
    // effect), exactly like the bank's own candidate scratch.
    logic [NUM_VOICES-1:0]    act_c;
    logic [NUM_VOICES*32-1:0] x_c;

    // loader <-> bank
    logic                   ld_clear_valid, ld_cfg_valid;
    logic                   ld_clear_ready, ld_cfg_ready;
    logic [VW-1:0]          ld_clear_voice, ld_cfg_voice;
    logic [MW-1:0]          ld_cfg_mode;
    logic [71:0]            ld_cfg_word;
    logic                   ld_busy, ld_error_valid;
    logic [1:0]             ld_error_code;

    logic                   bk_busy, bk_error_valid, bk_sample_ready;
    logic                   bk_out_valid, bk_voice_valid;
    logic [VW-1:0]          bk_voice_id;
    logic signed [63:0]     bk_mix_sum, bk_voice_sum;
    logic [SW-1:0]          bk_sat_count;
    logic [3:0]             bk_commit_valid;
    logic [4*VW-1:0]        bk_commit_voice;
    logic [4*MW-1:0]        bk_commit_mode;
    logic [127:0]           bk_commit_y1, bk_commit_y2;
    logic [3:0]             bk_commit_sat;
    logic                   bk_error_flag;
    logic [1:0]             bk_error_code;

    // ------------------------------------------------------------------
    // load arbitration: loading wins over sampling when both are offered
    // ------------------------------------------------------------------
    wire engine_idle = (estate == E_IDLE) && !ld_busy && !bk_busy;
    assign load_ready = engine_idle;
    assign sample_ready = engine_idle && !load_valid;

    wire load_fire  = load_valid  && load_ready;
    wire sample_fire = sample_valid && sample_ready;

    logic any_active_unloaded;
    // A voice is usable if it was captured earlier, or if load_done is being
    // observed this very cycle (the registered capture lands one cycle later,
    // so a frame offered on the completion cycle must still see it loaded).
    wire [NUM_VOICES-1:0] loaded_eff = voice_loaded
        | (load_done ? ({{(NUM_VOICES-1){1'b0}}, 1'b1} << done_voice) : '0);
    always_comb begin
        any_active_unloaded = 1'b0;
        for (int v = 0; v < NUM_VOICES; v = v + 1)
            if (active_mask[v] && !loaded_eff[v]) any_active_unloaded = 1'b1;
    end

    // n_modes vector rebuilt from the engine's own stored metadata.  REGISTERED
    // (nm_vec_r) so the loader's n_r does not combinationally reach the bank's
    // legality scan / register enables.  nm_vec_r is captured on the SAME edge
    // as voice_nm (both update from load_done/done_voice), so it is not "one
    // cycle late" relative to the metadata; a frame that completes loading is
    // accepted on the completion edge and the E_DRIVE consumer uses the new n on
    // the next edge, preserving the load-completion-cycle golden behaviour.
    logic [NUM_VOICES*MW-1:0] nm_vec_r;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            nm_vec_r <= '0;
        end else begin
            for (int v = 0; v < NUM_VOICES; v = v + 1)
                if (load_done && (done_voice == v))
                    nm_vec_r[v*MW +: MW] <= loaded_n_modes;
        end
    end
    wire [NUM_VOICES*MW-1:0] nm_vec = nm_vec_r;

    // ------------------------------------------------------------------
    // coefficient loader
    // ------------------------------------------------------------------
    coeff_loader #(
        .NUM_VOICES(NUM_VOICES),
        .N_MODES(N_MODES),
        .COEFF_DEPTH(COEFF_DEPTH),
        .INDEX_DEPTH(INDEX_DEPTH),
        .COEFF_FILE(COEFF_FILE),
        .INDEX_FILE(INDEX_FILE)
    ) u_loader (
        .clk          (clk),
        .rst_n        (rst_n),
        .load_valid   (load_valid && (estate == E_IDLE) && !bk_busy),
        .load_ready   (),
        .load_voice   (load_voice),
        .load_instrument(load_instrument),
        .load_midi    (load_midi),
        .load_dyn     (load_dyn),
        .busy         (ld_busy),
        .load_done    (load_done),
        .done_voice   (done_voice),
        .loaded_n_modes(loaded_n_modes),
        .error_valid  (ld_error_valid),
        .error_code   (ld_error_code),
        .clear_valid  (ld_clear_valid),
        .clear_ready  (ld_clear_ready),
        .clear_voice  (ld_clear_voice),
        .cfg_valid    (ld_cfg_valid),
        .cfg_ready    (ld_cfg_ready),
        .cfg_voice    (ld_cfg_voice),
        .cfg_mode     (ld_cfg_mode),
        .cfg_word     (ld_cfg_word)
    );

    // ------------------------------------------------------------------
    // poly bank
    // ------------------------------------------------------------------
    modal_poly_bank #(
        .NUM_VOICES(NUM_VOICES),
        .N_MODES(N_MODES),
        .SKIP_ZERO_INPUT(SKIP_ZERO_INPUT)
    ) u_bank (
        .clk         (clk),
        .rst_n       (rst_n),
        .cfg_valid   (ld_cfg_valid),
        .cfg_ready   (ld_cfg_ready),
        .cfg_voice   (ld_cfg_voice),
        .cfg_mode    (ld_cfg_mode),
        .cfg_word    (ld_cfg_word),
        .clear_valid (ld_clear_valid),
        .clear_ready (ld_clear_ready),
        .clear_voice (ld_clear_voice),
        .clear_done  (),
        .sample_valid(estate == E_DRIVE),
        .sample_ready(bk_sample_ready),
        .active_mask (act_r),
        .n_modes_vec (nm_vec),
        .x_vec       (x_r),
        .busy        (bk_busy),
        .out_valid   (bk_out_valid),
        .mix_sum     (bk_mix_sum),
        .sat_count   (bk_sat_count),
        .voice_valid (bk_voice_valid),
        .voice_id    (bk_voice_id),
        .voice_sum   (bk_voice_sum),
        .error_valid (bk_error_flag),
        .error_code  (bk_error_code),
        .commit_valid(bk_commit_valid),
        .commit_voice(bk_commit_voice),
        .commit_mode (bk_commit_mode),
        .commit_y1   (bk_commit_y1),
        .commit_y2   (bk_commit_y2),
        .commit_sat (bk_commit_sat)
    );

    // ------------------------------------------------------------------
    // forwarded outputs
    // ------------------------------------------------------------------
    assign busy         = (estate != E_IDLE) || ld_busy || bk_busy;
    assign out_valid    = bk_out_valid;
    assign mix_sum      = bk_mix_sum;
    assign sat_count    = bk_sat_count;
    assign voice_valid  = bk_voice_valid;
    assign voice_id     = bk_voice_id;
    assign voice_sum    = bk_voice_sum;
    assign commit_valid = bk_commit_valid;
    assign commit_voice = bk_commit_voice;
    assign commit_mode  = bk_commit_mode;
    assign commit_y1    = bk_commit_y1;
    assign commit_y2    = bk_commit_y2;
    assign commit_sat   = bk_commit_sat;

    // The loader and bank errors are already registered one-cycle pulses, so
    // forward them in the very cycle they appear (this keeps the error visible
    // on the same cycle the engine returns to idle / raises sample_ready).
    // The active-unloaded error is registered because it is derived from a
    // sample request that is rejected on that same cycle.
    assign error_valid = ld_error_valid | bk_error_flag | error4_r;
    assign error_code  = ld_error_valid ? {1'b0, ld_error_code}
                       : bk_error_flag  ? 3'd5
                       : 3'd4;

    // ------------------------------------------------------------------
    // engine metadata + frame sequencer
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            estate      <= E_IDLE;
            voice_loaded<= '0;
            act_r       <= '0;
            x_r         <= '0;
            act_c       <= '0;
            x_c         <= '0;
            error4_r    <= 1'b0;
            for (int v = 0; v < NUM_VOICES; v = v + 1)
                voice_nm[v] <= {MW{1'b0}};
        end else begin
            error4_r <= 1'b0;

            // capture the load result of a successful transaction only
            if (load_done) begin
                voice_loaded[done_voice] <= 1'b1;
                voice_nm[done_voice]     <= loaded_n_modes;
            end

            // Capture the intake candidate on the shallow sample handshake so the
            // wide x payload CE does not sit behind any_active_unloaded.  The FSM
            // below only consumes it via E_PREP when the original legality decode
            // passed; an illegal frame still raises error4_r on this edge with
            // busy low and leaves every operational register/history untouched.
            if (sample_fire) begin
                act_c <= active_mask;
                x_c   <= x_vec;
            end

            if (sample_fire && any_active_unloaded)
                error4_r <= 1'b1;

            case (estate)
                E_IDLE: begin
                    if (sample_fire && !any_active_unloaded)
                        estate <= E_PREP;
                end

                E_PREP: begin
                    // Shallow state decode drives the wide operational payload;
                    // the bank request follows in E_DRIVE with the metadata that
                    // landed on the same edge as the sample handshake.
                    act_r  <= act_c;
                    x_r    <= x_c;
                    estate <= E_DRIVE;
                end

                E_DRIVE: estate <= E_WAIT;

                default: begin // E_WAIT
                    if (bk_out_valid) estate <= E_IDLE;
                end
            endcase
        end
    end

endmodule
