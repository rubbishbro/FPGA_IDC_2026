// -----------------------------------------------------------------------------
// modal_bank.sv -- single-voice, N-mode, four-lane TDM modal array (module 2A).
//
// Four identical lanes (lane = global mode % 4, local = global mode / 4).  Each
// lane owns one 72-bit synchronous-read single-port working cache and one shared
// 26x32 signed multiplier; a mode is processed every 3 clocks (II = 3).
//
// This module contains only the modal bank and its internal sum.  Excitation
// generation, voice allocation, the shared body filter and the final I2S output
// belong to later stages (see rtl/module2A_design.md sections 1 and 7).
//
// Priority while idle: clear > config > sample.  Illegal requests are accepted
// (handshake) and rejected with error_code, never starting a frame.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module modal_bank #(
    parameter int N_MODES = 48,
    parameter int SKIP_ZERO_INPUT = 0,
    parameter int MW = $clog2(N_MODES + 1),                       // global mode id width
    parameter int LOCAL_MODES = (N_MODES + 3) / 4,               // slots per lane
    parameter int ADDRW = ($clog2(2 * LOCAL_MODES) < 1) ? 1 : $clog2(2 * LOCAL_MODES)
) (
    input  logic               clk,
    input  logic               rst_n,

    // coefficient configuration
    input  logic               cfg_valid,
    output logic               cfg_ready,
    input  logic [MW-1:0]      cfg_mode,
    input  logic [71:0]        cfg_word,

    // logical state clear
    input  logic               clear_valid,
    output logic               clear_ready,
    output logic               clear_done,

    // one-sample frame request
    input  logic               sample_valid,
    output logic               sample_ready,
    input  logic [MW-1:0]      n_modes,
    input  logic signed [31:0] x_in,

    // frame result
    output logic               busy,
    output logic               out_valid,
    output logic signed [63:0] y_sum,
    output logic [5:0]         sat_count,

    // illegal request report
    output logic               error_valid,
    output logic [1:0]         error_code,

    // per-lane write-back observability
    output logic [3:0]         commit_valid,
    output logic [4*MW-1:0]    commit_mode,
    output logic [127:0]       commit_y1,
    output logic [127:0]       commit_y2,
    output logic [3:0]         commit_sat
);

    localparam logic [1:0] IDLE = 2'd0, RUN = 2'd1, SUM = 2'd2, OUT = 2'd3;

    logic [1:0] state;
    logic [N_MODES-1:0] coeff_loaded;

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

    // every coefficient required by the frame is loaded?
    logic all_loaded;
    always_comb begin
        all_loaded = 1'b1;
        for (int k = 0; k < N_MODES; k++)
            if (k < n_modes) all_loaded = all_loaded && coeff_loaded[k];
    end

    wire cfg_ok   = cfg_fire && (cfg_mode < N_MODES);
    wire sample_ok = sample_fire && (n_modes <= N_MODES) && all_loaded;
    wire start    = sample_ok;

    wire [MW:0]       cfg_addr_full = {1'b0, (cfg_mode >> 2)} << 1;  // 2*local
    wire [ADDRW-1:0]  cfg_addr = cfg_addr_full[ADDRW-1:0];

    // global mode -> lane = k % 4 (works for MW=1 too)
    logic [1:0] cfg_lane;
    always_comb cfg_lane = cfg_mode % 4;

    // ------------------------------------------------------------------
    // four lanes
    // ------------------------------------------------------------------
    logic [3:0]                lane_done;
    logic [3:0]                lane_cvalid, lane_csat;
    logic [MW-1:0]             lane_cmode  [0:3];
    logic signed [31:0]        lane_cy1    [0:3];
    logic signed [31:0]        lane_cy2    [0:3];
    logic signed [63:0]        lane_ps     [0:3];
    logic [5:0]                lane_sat    [0:3];
    logic [3:0]                lane_cfg_we;

    genvar gi;
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : g_lane
            assign lane_cfg_we[gi] = cfg_ok && (cfg_lane == gi[1:0]);

            modal_lane #(
                .N_MODES(N_MODES),
                .LANE(gi),
                .SKIP_ZERO_INPUT(SKIP_ZERO_INPUT),
                .MW(MW),
                .ADDRW(ADDRW)
            ) u_lane (
                .clk        (clk),
                .rst_n      (rst_n),
                .start      (start),
                .n_modes    (n_modes),
                .x_in       (x_in),
                .clear      (clear_fire),
                .cfg_we     (lane_cfg_we[gi]),
                .cfg_addr   (cfg_addr),
                .cfg_wdata  (cfg_word),
                .done       (lane_done[gi]),
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
        for (int i = 0; i < 4; i++) begin
            commit_mode[i*MW +: MW] = lane_cmode[i];
            commit_y1[i*32 +: 32]   = lane_cy1[i];
            commit_y2[i*32 +: 32]   = lane_cy2[i];
        end
    end

    wire all_done = &lane_done;

    // ------------------------------------------------------------------
    // top frame controller
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state       <= IDLE;
            coeff_loaded<= '0;
            clear_done  <= 1'b0;
            out_valid   <= 1'b0;
            y_sum       <= 64'sd0;
            sat_count   <= 6'd0;
            error_valid <= 1'b0;
            error_code  <= 2'd0;
        end else begin
            clear_done  <= 1'b0;
            out_valid   <= 1'b0;
            error_valid <= 1'b0;

            case (state)
                IDLE: begin
                    if (clear_fire) begin
                        clear_done <= 1'b1;
                    end else if (cfg_fire) begin
                        if (cfg_mode >= N_MODES) begin
                            error_valid <= 1'b1;
                            error_code  <= 2'd1;
                        end else begin
                            coeff_loaded[cfg_mode] <= 1'b1;
                        end
                    end else if (sample_fire) begin
                        if (n_modes > N_MODES) begin
                            error_valid <= 1'b1;
                            error_code  <= 2'd2;
                        end else if (!all_loaded) begin
                            error_valid <= 1'b1;
                            error_code  <= 2'd3;
                        end else begin
                            state <= RUN;
                        end
                    end
                end

                RUN: if (all_done) state <= SUM;

                SUM: begin
                    y_sum     <= (lane_ps[0] + lane_ps[1]) + (lane_ps[2] + lane_ps[3]);
                    sat_count <= lane_sat[0] + lane_sat[1] + lane_sat[2] + lane_sat[3];
                    out_valid <= 1'b1;
                    state     <= OUT;
                end

                default: begin // OUT
                    state <= IDLE;
                end
            endcase
        end
    end

endmodule
