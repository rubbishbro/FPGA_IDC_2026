// -----------------------------------------------------------------------------
// eng1_engine_top.sv -- ENG1 单引擎（16 slot，4 lane，9×32 RAM 中心）
//
// 结构：
//   modal_ram（16 slot × N_MODES × 9×32，4 lane banks）
//       ↕ rd/st
//   4 × eng1_lane_core（纯计算）
//       ↓ partial_sum
//   voice_sum →（A 暂为 unity）→ mix_sum
//
// 每帧：逐 active voice，4 lane 同时算该 voice 的局部 mode，全部 done 后
// 汇总成一个 voice_sum，再进入下一个 voice。包络接口预留在 engine 内，
// A 当前 unity；B/C 后续接 env_gain。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module eng1_engine_top_ext #(
    parameter int NUM_SLOTS      = 16,
    parameter int N_MODES        = 48,
    parameter int LANES          = 4,
    parameter int LOCAL          = (N_MODES + LANES - 1) / LANES,
    parameter int VW             = (NUM_SLOTS < 2) ? 1 : $clog2(NUM_SLOTS),
    parameter int MW             = (N_MODES < 2) ? 1 : $clog2(N_MODES),
    parameter int AW             = (NUM_SLOTS * LOCAL < 2) ? 1 : $clog2(NUM_SLOTS * LOCAL),
    parameter int SW             = (NUM_SLOTS * N_MODES < 2) ? 1 : $clog2(NUM_SLOTS * N_MODES + 1),
    parameter int REC_W          = 288
) (
    input  logic                  clk,
    input  logic                  rst_n,

    // router：cfg / clear / seed
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

    // aux 读 / 单字段写（B a1 刷新用）
    input  logic                  aux_re,
    input  logic [VW-1:0]         aux_voice,
    input  logic [MW-1:0]         aux_mode,
    output logic [REC_W-1:0]      aux_data,
    output logic                  aux_valid,
    input  logic                  co_we,
    input  logic [VW-1:0]         co_voice,
    input  logic [MW-1:0]         co_mode,
    input  logic [3:0]            co_field,
    input  logic [31:0]           co_wdata,

    // 作业口
    input  logic                  start,
    input  logic [NUM_SLOTS-1:0]  active_mask,
    input  logic [NUM_SLOTS*32-1:0] x_vec,
    input  logic [NUM_SLOTS*16-1:0] x_vel_vec,   // UQ1.15，A 的力度进 x
    input  logic [NUM_SLOTS*MW-1:0] n_modes_vec,
    input  logic [NUM_SLOTS*16-1:0] env_gain_vec,   // UQ1.15，每 voice
    output logic                  sample_ready,
    output logic                  done,
    output logic                  busy,

    // 共享 RAM 端口（EXTERNAL RAM）
    output logic [LANES-1:0]      ram_rd_re,
    output logic [LANES*AW-1:0]   ram_rd_addr,
    input  logic [LANES*REC_W-1:0] ram_rd_data,
    output logic [LANES-1:0]      ram_st_we,
    output logic [LANES*AW-1:0]   ram_st_addr,
    output logic [LANES*64-1:0]   ram_st_data,

    // 结果（本引擎）
    output logic                  out_valid,
    output logic signed [63:0]    mix_sum,
    output logic [SW-1:0]         sat_count,
    output logic                  voice_valid,
    output logic [VW-1:0]         voice_id,
    output logic signed [63:0]    voice_sum
);

    // ---- RAM 端口 ----
    logic [LANES-1:0]       rd_re;
    logic [LANES*AW-1:0]    rd_addr;
    logic [LANES*REC_W-1:0] rd_data;
    logic [LANES-1:0]       lane_st_we;
    logic [LANES*AW-1:0]    lane_st_addr;
    logic [LANES*64-1:0]    lane_st_data;

    // 共享 RAM 由上层例化；这里只引出 lane 读写口。
    assign ram_rd_re   = rd_re;
    assign ram_rd_addr = rd_addr;
    assign ram_st_we   = lane_st_we;
    assign ram_st_addr = lane_st_addr;
    assign ram_st_data = lane_st_data;
    assign rd_data     = ram_rd_data;

    logic [VW-1:0] vcur;
    logic [NUM_SLOTS*32-1:0] x_r;

    function automatic [VW-1:0] first_active(input [NUM_SLOTS-1:0] m);
        logic found;
        begin
            first_active = {VW{1'b0}};
            found = 1'b0;
            for (int i = 0; i < NUM_SLOTS; i = i + 1) begin
                if (!found && m[i]) begin
                    first_active = i[VW-1:0];
                    found = 1'b1;
                end
            end
        end
    endfunction
    logic [NUM_SLOTS*MW-1:0] nm_r;

    function automatic logic signed [31:0] apply_xvel(
        input logic signed [31:0] x,
        input logic [15:0]        g
    );
        logic signed [47:0] p, r;
        begin
            if (g == 16'h8000) begin
                apply_xvel = x;
            end else begin
                p = x * $signed({1'b0, g});
                r = (p + 48'sd16384) >>> 15;
                if (r > 48'sd2147483647)       apply_xvel = 32'sh7FFFFFFF;
                else if (r < -48'sd2147483648)  apply_xvel = 32'sh80000000;
                else                            apply_xvel = r[31:0];
            end
        end
    endfunction

    wire signed [31:0] x_sel = apply_xvel(x_r[vcur*32 +: 32], x_vel_vec[vcur*16 +: 16]);

    // ---- 4 lane ----
    logic [LANES-1:0]       lane_start;
    logic [LANES-1:0]       lane_done;
    logic [LANES*64-1:0]    lane_ps;
    logic [LANES*6-1:0]     lane_sat;
    logic [LANES*VW-1:0]    lane_commit_voice;
    logic [LANES*MW-1:0]    lane_commit_mode;
    logic [LANES*32-1:0]    lane_commit_y1, lane_commit_y2;
    logic [LANES-1:0]       lane_commit_valid, lane_commit_sat;

    genvar g;
    generate
        for (g = 0; g < LANES; g = g + 1) begin : g_lane
            eng1_lane_core #(
                .NUM_SLOTS(NUM_SLOTS), .N_MODES(N_MODES), .LANES(LANES),
                .LANE(g), .LOCAL(LOCAL), .VW(VW), .MW(MW), .AW(AW),
                .REC_W(REC_W)
            ) u_lane (
                .clk(clk), .rst_n(rst_n),
                .start(lane_start[g]),
                .n_modes(nm_r[vcur*MW +: MW]),
                .x_in(x_sel),
                .voice(vcur),
                .rd_re(rd_re[g]),
                .rd_addr(rd_addr[g*AW +: AW]),
                .rd_data(rd_data[g*REC_W +: REC_W]),
                .st_we(lane_st_we[g]),
                .st_addr(lane_st_addr[g*AW +: AW]),
                .st_data(lane_st_data[g*64 +: 64]),
                .done(lane_done[g]),
                .busy(),
                .commit_valid(lane_commit_valid[g]),
                .commit_voice(lane_commit_voice[g*VW +: VW]),
                .commit_mode(lane_commit_mode[g*MW +: MW]),
                .commit_y1(lane_commit_y1[g*32 +: 32]),
                .commit_y2(lane_commit_y2[g*32 +: 32]),
                .commit_sat(lane_commit_sat[g]),
                .partial_sum(lane_ps[g*64 +: 64]),
                .sat_count(lane_sat[g*6 +: 6])
            );
        end
    endgenerate

    // ---- 调度 ----
    typedef enum logic [3:0] { S_IDLE, S_START, S_WAIT, S_MIXADD, S_MIXENV, S_ENVPART, S_MIXMIX, S_SUM, S_DONE } state_t;
    state_t state;
    logic [NUM_SLOTS-1:0] active_r;
    logic armed;
    logic signed [63:0] mix_acc;
    logic [SW-1:0] sat_acc;
    logic [LANES*64-1:0] lane_ps_r;
    logic [LANES*6-1:0]  lane_sat_r;
    logic [1:0]          mix_idx;
    logic signed [63:0]  ps_acc, ps_r, vsum_r;
    logic [5:0]          sat_tmp, sat_r;
    logic signed [47:0]  env_hi;
    logic        [47:0]  env_lo;

    logic [VW-1:0] next_v;
    logic          next_found;

    always_comb begin
        next_found = 1'b0;
        next_v = {VW{1'b0}};
        for (int i = 0; i < NUM_SLOTS; i = i + 1) begin
            if (!next_found && active_r[i] && (i > vcur)) begin
                next_found = 1'b1;
                next_v = i[VW-1:0];
            end
        end
    end

    function automatic logic signed [63:0] apply_env(
        input logic signed [63:0] s,
        input logic [15:0]        g
    );
        logic signed [31:0] sh;
        logic        [31:0] sl;
        logic signed [47:0] ph, pl;
        logic signed [79:0] p, r;
        begin
            // 64x16 拆成两个 32x16，缩短单级乘法路径。
            sh = s[63:32];
            sl = s[31:0];
            ph = sh * $signed({1'b0, g});
            pl = sl * g;
            p  = ($signed({{32{ph[47]}}, ph}) <<< 32)
               + $signed({32'b0, pl});
            r = (p + 80'sd16384) >>> 15;
            if (r > 80'sd9223372036854775807)
                apply_env = 64'sh7FFFFFFFFFFFFFFF;
            else if (r < -80'sd9223372036854775808)
                apply_env = 64'sh8000000000000000;
            else
                apply_env = r[63:0];
        end
    endfunction

    function automatic logic signed [63:0] env_combine(
        input logic signed [47:0] hi,
        input logic        [47:0] lo
    );
        logic signed [79:0] p, r;
        begin
            p = ($signed({{32{hi[47]}}, hi}) <<< 32) +
                $signed({32'b0, lo});
            r = (p + 80'sd16384) >>> 15;
            if (r > 80'sd9223372036854775807)
                env_combine = 64'sh7FFFFFFFFFFFFFFF;
            else if (r < -80'sd9223372036854775808)
                env_combine = 64'sh8000000000000000;
            else
                env_combine = r[63:0];
        end
    endfunction

    wire signed [63:0] ps_sum = $signed(lane_ps[0*64 +: 64]) +
                                $signed(lane_ps[1*64 +: 64]) +
                                $signed(lane_ps[2*64 +: 64]) +
                                $signed(lane_ps[3*64 +: 64]);
    wire [SW-1:0] sat_sum = lane_sat[0*6 +: 6] + lane_sat[1*6 +: 6] +
                            lane_sat[2*6 +: 6] + lane_sat[3*6 +: 6];
    wire signed [63:0] vsum = apply_env(ps_sum, env_gain_vec[vcur*16 +: 16]);

    assign sample_ready = (state == S_IDLE);
    assign busy         = (state != S_IDLE);
    assign done         = (state == S_DONE);
    assign lane_start   = (state == S_START) ? {LANES{1'b1}} : {LANES{1'b0}};

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            vcur          <= {VW{1'b0}};
            active_r      <= '0;
            armed         <= 1'b0;
            x_r           <= '0;
            nm_r          <= '0;
            mix_acc       <= 64'sd0;
            lane_ps_r    <= '0;
            lane_sat_r   <= '0;
            mix_idx      <= 2'd0;
            ps_acc       <= 64'sd0;
            ps_r         <= 64'sd0;
            vsum_r       <= 64'sd0;
            sat_tmp      <= 6'd0;
            sat_r        <= 6'd0;
            env_hi       <= 48'sd0;
            env_lo       <= 48'd0;
            sat_acc       <= {SW{1'b0}};
            out_valid     <= 1'b0;
            mix_sum       <= 64'sd0;
            sat_count     <= {SW{1'b0}};
            voice_valid   <= 1'b0;
            voice_id      <= {VW{1'b0}};
            voice_sum     <= 64'sd0;
        end else begin
            out_valid   <= 1'b0;
            voice_valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        active_r <= active_mask;
                        x_r      <= x_vec;
                        nm_r     <= n_modes_vec;
                        mix_acc  <= 64'sd0;
                        sat_acc  <= {SW{1'b0}};
                        // 用输入 mask 先找首个 active（active_r 下一拍才更新）
                        if (active_mask == '0) begin
                            vcur      <= {VW{1'b0}};
                            mix_sum   <= 64'sd0;
                            sat_count <= {SW{1'b0}};
                            out_valid <= 1'b1;
                            state     <= S_DONE;
                        end else begin
                            vcur  <= first_active(active_mask);
                            state <= S_START;
                        end
                    end
                end

                S_START: begin
                    armed <= 1'b0;
                    state <= S_WAIT;
                end

                S_WAIT: begin
                    if (!armed) begin
                        armed <= 1'b1;
                    end else if (&lane_done) begin
                        lane_ps_r  <= lane_ps;
                        lane_sat_r <= lane_sat;
                        voice_id   <= vcur;
                        mix_idx    <= 2'd0;
                        ps_acc     <= 64'sd0;
                        sat_tmp    <= 6'd0;
                        state      <= S_MIXADD;
                    end
                end

                S_MIXADD: begin
                    ps_acc  <= ps_acc + $signed(lane_ps_r[mix_idx*64 +: 64]);
                    sat_tmp <= sat_tmp + lane_sat_r[mix_idx*6 +: 6];
                    if (mix_idx == LANES-1) begin
                        ps_r   <= ps_acc + $signed(lane_ps_r[(LANES-1)*64 +: 64]);
                        sat_r  <= sat_tmp + lane_sat_r[(LANES-1)*6 +: 6];
                        state  <= S_MIXENV;
                    end else begin
                        mix_idx <= mix_idx + 1'b1;
                    end
                end

                S_MIXENV: begin
                    env_hi <= ps_r[63:32] * $signed({1'b0, env_gain_vec[voice_id*16 +: 16]});
                    env_lo <= ps_r[31:0]  * env_gain_vec[voice_id*16 +: 16];
                    state  <= S_ENVPART;
                end

                S_ENVPART: begin
                    vsum_r <= env_combine(env_hi, env_lo);
                    state  <= S_MIXMIX;
                end

                S_MIXMIX: begin
                    mix_acc     <= mix_acc + vsum_r;
                    sat_acc     <= sat_acc + sat_r;
                    voice_sum   <= vsum_r;
                    voice_valid <= 1'b1;
                    state       <= S_SUM;
                end

                S_SUM: begin
                    if (next_found) begin
                        vcur  <= next_v;
                        state <= S_START;
                    end else begin
                        mix_sum   <= mix_acc;
                        sat_count <= sat_acc;
                        out_valid <= 1'b1;
                        state     <= S_DONE;
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
