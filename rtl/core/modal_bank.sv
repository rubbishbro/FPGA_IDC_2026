// -----------------------------------------------------------------------------
// modal_bank.sv -- 单声部、N 模态、四 lane 的 TDM 模态阵列（module 2A）。
//
// 四个完全相同的 lane（lane = global mode % 4，local = global mode / 4）。每个
// lane 拥有一个 72-bit 同步读单端口工作缓存和一个共享的 26x32 signed 乘法器；
// 每 3 个时钟处理一个 mode（II = 3）。
//
// 本模块只包含 modal bank 及其内部求和。Excitation
// 生成、voice 分配、共享 body filter 和最终 I2S 输出
// 属于后续阶段（见 rtl/module2A_design.md 第 1 和 7 节）。
//
// 空闲时的优先级：clear > config > sample。非法请求会被接受（握手）并以
// error_code 拒绝，绝不启动一个帧。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module modal_bank #(
    parameter int N_MODES = 48,
    parameter int SKIP_ZERO_INPUT = 0,
    parameter int MW = $clog2(N_MODES + 1),                       // 全局 mode id 宽度
    parameter int LOCAL_MODES = (N_MODES + 3) / 4,               // 每个 lane 的 slot 数
    parameter int ADDRW = ($clog2(2 * LOCAL_MODES) < 1) ? 1 : $clog2(2 * LOCAL_MODES)
) (
    input  logic               clk,
    input  logic               rst_n,

    // 系数配置
    input  logic               cfg_valid,
    output logic               cfg_ready,
    input  logic [MW-1:0]      cfg_mode,
    input  logic [71:0]        cfg_word,

    // 逻辑状态清除
    input  logic               clear_valid,
    output logic               clear_ready,
    output logic               clear_done,

    // 单采样帧请求
    input  logic               sample_valid,
    output logic               sample_ready,
    input  logic [MW-1:0]      n_modes,
    input  logic signed [31:0] x_in,

    // 帧结果
    output logic               busy,
    output logic               out_valid,
    output logic signed [63:0] y_sum,
    output logic [5:0]         sat_count,

    // 非法请求报告
    output logic               error_valid,
    output logic [1:0]         error_code,

    // 逐 lane 回写可观测性
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
    // 握手仲裁
    // ------------------------------------------------------------------
    wire idle = (state == IDLE);
    assign busy         = ~idle;
    assign clear_ready  = idle;
    assign cfg_ready    = idle && !clear_valid;
    assign sample_ready = idle && !clear_valid && !cfg_valid;

    wire clear_fire  = clear_valid  && clear_ready;
    wire cfg_fire    = cfg_valid    && cfg_ready;
    wire sample_fire = sample_valid && sample_ready;

    // 帧所需的每个系数都加载了吗？
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

    // 全局 mode -> lane = k % 4（MW=1 时也可用）
    logic [1:0] cfg_lane;
    always_comb cfg_lane = cfg_mode % 4;

    // ------------------------------------------------------------------
    // 四个 lane
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
    // 顶层帧控制器
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
