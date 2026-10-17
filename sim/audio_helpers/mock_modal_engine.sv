// -----------------------------------------------------------------------------
// mock_modal_engine.sv -- behavioural stand-in for rtl/core/modal_engine.sv.
//
// TEST-ONLY helper for the audio bring-up task.  It exposes exactly the external
// interface documented in rtl/module2BC_design.md section 5 so that
// audio_demo_core.sv / song_player.sv can be built and exercised before the real
// 2B/2C engine exists.  It performs NO modal synthesis: it returns the plain
// signed sum of the active x_vec slots.  Passing against this mock proves the
// audio sequencing/transport, never the 2C arithmetic.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module modal_engine #(
    parameter int NUM_VOICES = 32,
    parameter int N_MODES    = 48,
    parameter int SKIP_ZERO_INPUT = 0,
    parameter int VW = (NUM_VOICES < 2) ? 1 : $clog2(NUM_VOICES),
    parameter int MW = (N_MODES < 1) ? 1 : $clog2(N_MODES + 1),
    parameter int SW = $clog2(NUM_VOICES * N_MODES + 1),
    // mock latency: cycles from handshake to done/out_valid
    parameter int MOCK_LOAD_LAT   = 6,
    parameter int MOCK_SAMPLE_LAT = 5,
    parameter int MOCK_STALL      = 0,   // idle cycles with ready low after a job
    parameter COEFF_FILE = "rtl/rom/modal_coeff.mem",
    parameter INDEX_FILE = "rtl/rom/modal_index.mem"
) (
    input  logic                   clk,
    input  logic                   rst_n,

    input  logic                   load_valid,
    output logic                   load_ready,
    input  logic [VW-1:0]          load_voice,
    input  logic [1:0]             load_instrument,
    input  logic [6:0]             load_midi,
    input  logic                   load_dyn,

    input  logic                   sample_valid,
    output logic                   sample_ready,
    input  logic [NUM_VOICES-1:0]  active_mask,
    input  logic [NUM_VOICES*32-1:0] x_vec,

    output logic                   busy,
    output logic                   load_done,
    output logic [VW-1:0]          done_voice,
    output logic [MW-1:0]          loaded_n_modes,

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

    localparam logic [1:0] IDLE = 2'd0, LD = 2'd1, SMP = 2'd2;
    localparam logic [MW-1:0] ONE = 1;

    logic [1:0]    st;
    logic [7:0]    cnt;
    logic          block;
    logic [7:0]    stall;

    logic [VW-1:0] ld_voice_r;
    logic          load_done_r, out_valid_r;
    logic [VW-1:0] done_voice_r;
    logic signed [63:0] mix_r;

    logic [NUM_VOICES-1:0]    act_r;
    logic [NUM_VOICES*32-1:0] x_r;

    logic signed [63:0] mixed;
    always_comb begin
        mixed = 64'sd0;
        for (int v = 0; v < NUM_VOICES; v = v + 1)
            if (act_r[v]) mixed = mixed + $signed(x_r[v*32 +: 32]);
    end

    assign load_ready      = (st == IDLE) && !block;
    assign sample_ready    = (st == IDLE) && !block && !load_valid;  // load preferred
    assign busy            = (st != IDLE) || block;
    assign load_done       = load_done_r;
    assign done_voice      = done_voice_r;
    assign loaded_n_modes  = ONE;
    assign out_valid       = out_valid_r;
    assign mix_sum         = mix_r;
    assign sat_count       = '0;
    assign voice_valid     = 1'b0;
    assign voice_id        = '0;
    assign voice_sum       = 64'sd0;
    assign commit_valid    = 4'd0;
    assign commit_voice    = '0;
    assign commit_mode     = '0;
    assign commit_y1       = '0;
    assign commit_y2       = '0;
    assign commit_sat      = '0;
    assign error_valid     = 1'b0;
    assign error_code      = 3'd0;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st           <= IDLE;
            cnt          <= 8'd0;
            block        <= 1'b0;
            stall        <= 8'd0;
            ld_voice_r   <= '0;
            load_done_r  <= 1'b0;
            out_valid_r  <= 1'b0;
            done_voice_r <= '0;
            mix_r        <= 64'sd0;
            act_r        <= '0;
            x_r          <= '0;
        end else begin
            load_done_r <= 1'b0;
            out_valid_r <= 1'b0;

            case (st)
                IDLE: begin
                    if (block) begin
                        if (stall == 8'd0) block <= 1'b0;
                        else               stall <= stall - 8'd1;
                    end else if (load_valid) begin
                        ld_voice_r <= load_voice;
                        st         <= LD;
                        cnt        <= MOCK_LOAD_LAT[7:0];
                    end else if (sample_valid) begin
                        act_r <= active_mask;
                        x_r   <= x_vec;
                        st    <= SMP;
                        cnt   <= MOCK_SAMPLE_LAT[7:0];
                    end
                end

                LD: begin
                    if (cnt == 8'd0) begin
                        load_done_r  <= 1'b1;
                        done_voice_r <= ld_voice_r;
                        st           <= IDLE;
                        if (MOCK_STALL > 0) begin
                            block <= 1'b1;
                            stall <= MOCK_STALL[7:0];
                        end
                    end else begin
                        cnt <= cnt - 8'd1;
                    end
                end

                default: begin // SMP
                    if (cnt == 8'd0) begin
                        out_valid_r <= 1'b1;
                        mix_r       <= mixed;
                        st          <= IDLE;
                        if (MOCK_STALL > 0) begin
                            block <= 1'b1;
                            stall <= MOCK_STALL[7:0];
                        end
                    end else begin
                        cnt <= cnt - 8'd1;
                    end
                end
            endcase
        end
    end

endmodule
