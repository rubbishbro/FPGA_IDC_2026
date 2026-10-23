// =============================================================================
// 文件 : e2_engine.sv
// 模块 : e2_engine
// 功能 : E2 7×7 状态空间引擎核（外部 RAM）
// 说明 : 状态 q/v；字段 a11,a12,a21,a22,gq,gv,wo,q,qdot；7×mult / 5-stage。
// =============================================================================
`timescale 1ns/1ps

module e2_engine #(
    parameter int NUM_SLOTS = 16,
    parameter int N_MODES   = 80,
    parameter int LANES     = 4,
    parameter int LOCAL     = (N_MODES + LANES - 1) / LANES,
    parameter int REC_W     = 288,
    parameter int VW        = (NUM_SLOTS < 2) ? 1 : $clog2(NUM_SLOTS),
    parameter int MW        = (N_MODES < 1) ? 1 : $clog2(N_MODES + 1),
    parameter int AW        = (NUM_SLOTS * LOCAL < 2) ? 1 : $clog2(NUM_SLOTS * LOCAL)
) (
    input  logic                  clk,
    input  logic                  rst_n,

    input  logic                  cfg_we,
    input  logic [VW-1:0]         cfg_voice,
    input  logic [MW-1:0]         cfg_mode,
    input  logic [REC_W-1:0]      cfg_data,
    input  logic                  clr_we,
    input  logic [VW-1:0]         clr_voice,
    input  logic [MW-1:0]         clr_mode,
    input  logic                  seed_we,
    input  logic [VW-1:0]         seed_voice,
    input  logic [MW-1:0]         seed_mode,
    input  logic [63:0]           seed_data,

    input  logic                  start,
    input  logic [NUM_SLOTS-1:0]  active_mask,
    input  logic [NUM_SLOTS-1:0]  zero_mask,
    input  logic [NUM_SLOTS*32-1:0] x_vec,
    input  logic [NUM_SLOTS*MW-1:0] n_modes_vec,
    output logic                  sample_ready,
    output logic                  done,
    output logic                  busy,

    output logic                  out_valid,
    output logic signed [63:0]    mix_sum,
    output logic                  voice_valid,
    output logic [VW-1:0]         voice_id,
    output logic signed [63:0]    voice_sum,

    // 共享 RAM 端口
    output logic [LANES-1:0]      ram_rd_re,
    output logic [LANES*AW-1:0]   ram_rd_addr,
    input  logic [LANES*REC_W-1:0] ram_rd_data,
    output logic [LANES-1:0]      ram_st_we,
    output logic [LANES*AW-1:0]   ram_st_addr,
    output logic [LANES*64-1:0]   ram_st_data
);

    import modal_step_pkg::*;

    localparam int EW  = (N_MODES < 2) ? 1 : $clog2(N_MODES);
    localparam int RMW = (N_MODES < 2) ? 1 : $clog2(N_MODES);

    // RAM
    logic [LANES-1:0]        rd_re;
    logic [EW-1:0]           rd_lane_r;
    logic [LANES*AW-1:0]     rd_addr;
    logic [LANES*REC_W-1:0]  rd_data_vec;
    logic [REC_W-1:0]        rd_data;
    logic [LANES-1:0]        st_we;
    logic [LANES*AW-1:0]     st_addr;
    logic [LANES*64-1:0]     st_data;

    assign ram_rd_re   = rd_re;
    assign ram_rd_addr = rd_addr;
    assign ram_st_we   = st_we;
    assign ram_st_addr = st_addr;
    assign ram_st_data = st_data;
    assign rd_data_vec = ram_rd_data;

    // engine7
    logic          e_start, e_st_zero;
    logic [MW-1:0] e_n_modes;
    logic          e_co_re;
    logic [EW-1:0] e_co_addr;
    coeff_t        e_co_data;
    logic          e_st_re;
    logic [EW-1:0] e_st_addr;
    logic signed [31:0] e_st_q, e_st_qdot;
    logic          e_st_we;
    logic [EW-1:0] e_st_waddr;
    logic signed [31:0] e_st_q_wdata, e_st_qdot_wdata;
    logic signed [31:0] e_x_data;
    logic          e_y_valid;
    logic signed [63:0] e_y_data;

    // 9×32 -> coeff_t / state
    always_comb begin
        e_co_data.a11 = rd_data[0*32 +: 32];
        e_co_data.a12 = rd_data[1*32 +: 32];
        e_co_data.a21 = rd_data[2*32 +: 32];
        e_co_data.a22 = rd_data[3*32 +: 32];
        e_co_data.gq  = rd_data[4*32 +: 32];
        e_co_data.gv  = rd_data[5*32 +: 32];
        e_co_data.wo  = rd_data[6*32 +: 32];
    end

    logic [VW-1:0] vcur;
    logic [NUM_SLOTS-1:0] zero_r;
    logic [NUM_SLOTS*32-1:0] x_r;
    logic [NUM_SLOTS*MW-1:0] nm_r;

    wire [EW-1:0] rd_lane  = e_co_addr % LANES;
    wire [EW-1:0] rd_local = e_co_addr / LANES;
    wire [EW-1:0] wr_lane  = e_st_waddr % LANES;
    wire [EW-1:0] wr_local = e_st_waddr / LANES;

    always_comb begin
        rd_re   = '0;
        rd_addr = '0;
        rd_re[rd_lane] = e_co_re;
        for (int l = 0; l < LANES; l = l + 1)
            rd_addr[l*AW +: AW] = vcur * LOCAL + rd_local;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) rd_lane_r <= '0;
        else if (e_co_re) rd_lane_r <= rd_lane;
    end

    assign rd_data = rd_data_vec[rd_lane_r*REC_W +: REC_W];

    assign e_st_q    = $signed(rd_data[7*32 +: 32]);
    assign e_st_qdot = $signed(rd_data[8*32 +: 32]);

    always_comb begin
        st_we   = '0;
        st_addr = '0;
        st_data = '0;
        st_we[wr_lane] = e_st_we;
        for (int l = 0; l < LANES; l = l + 1) begin
            st_addr[l*AW +: AW] = vcur * LOCAL + wr_local;
            st_data[l*64 +: 64] = {e_st_qdot_wdata, e_st_q_wdata};
        end
    end

    assign e_x_data = x_r[vcur*32 +: 32];

    modal_engine7 #(
        .N_MODES(N_MODES), .X_DEPTH(1), .SATURATE(1'b1), .USE_X(1'b1)
    ) u_eng (
        .clk(clk), .rst_n(rst_n),
        .start(e_start), .st_zero(e_st_zero), .n_modes(e_n_modes),
        .co_re(e_co_re), .co_addr(e_co_addr), .co_data(e_co_data),
        .st_re(e_st_re), .st_addr(e_st_addr),
        .st_q(e_st_q), .st_qdot(e_st_qdot),
        .st_we(e_st_we), .st_waddr(e_st_waddr),
        .st_q_wdata(e_st_q_wdata), .st_qdot_wdata(e_st_qdot_wdata),
        .x_data(e_x_data),
        .y_valid(e_y_valid), .y_data(e_y_data)
    );

    // scheduler
    typedef enum logic [1:0] { S_IDLE, S_START, S_WAIT, S_DONE } state_t;
    state_t state;
    logic [NUM_SLOTS-1:0] active_r;
    logic signed [63:0] mix_acc;
    logic [VW-1:0] next_v;
    logic          next_found;

    function automatic [VW-1:0] first_active(input [NUM_SLOTS-1:0] m);
        logic found;
        begin
            first_active = {VW{1'b0}};
            found = 1'b0;
            for (int i = 0; i < NUM_SLOTS; i = i + 1)
                if (!found && m[i]) begin
                    first_active = i[VW-1:0];
                    found = 1'b1;
                end
        end
    endfunction

    always_comb begin
        next_found = 1'b0;
        next_v = {VW{1'b0}};
        for (int i = 0; i < NUM_SLOTS; i = i + 1)
            if (!next_found && active_r[i] && (i > vcur)) begin
                next_found = 1'b1;
                next_v = i[VW-1:0];
            end
    end

    assign e_start   = (state == S_START);
    assign e_st_zero = zero_r[vcur];
    assign e_n_modes = nm_r[vcur*MW +: MW];

    assign sample_ready = (state == S_IDLE);
    assign busy         = (state != S_IDLE);
    assign done         = (state == S_DONE);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            vcur        <= {VW{1'b0}};
            active_r    <= '0;
            zero_r      <= '0;
            x_r         <= '0;
            nm_r        <= '0;
            mix_acc     <= 64'sd0;
            out_valid   <= 1'b0;
            mix_sum     <= 64'sd0;
            voice_valid <= 1'b0;
            voice_id    <= {VW{1'b0}};
            voice_sum   <= 64'sd0;
        end else begin
            out_valid   <= 1'b0;
            voice_valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        active_r <= active_mask;
                        zero_r   <= zero_mask;
                        x_r      <= x_vec;
                        nm_r     <= n_modes_vec;
                        mix_acc  <= 64'sd0;
                        if (active_mask == '0) begin
                            mix_sum   <= 64'sd0;
                            out_valid <= 1'b1;
                            state     <= S_DONE;
                        end else begin
                            vcur  <= first_active(active_mask);
                            state <= S_START;
                        end
                    end
                end

                S_START: begin
                    state <= S_WAIT;
                end

                S_WAIT: begin
                    if (e_y_valid) begin
                        voice_sum   <= e_y_data;
                        voice_id    <= vcur;
                        voice_valid <= 1'b1;
                        mix_acc     <= mix_acc + e_y_data;
                        if (next_found) begin
                            vcur  <= next_v;
                            state <= S_START;
                        end else begin
                            mix_sum   <= mix_acc + e_y_data;
                            out_valid <= 1'b1;
                            state     <= S_DONE;
                        end
                    end
                end

                S_DONE: begin
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
