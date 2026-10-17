// -----------------------------------------------------------------------------
// modal_poly_bank.sv -- module 2C：32 声部、四 lane 的 TDM 模态 bank。
//
// 四个 poly_modal_lane 实例，每个 lane 一个。每个 lane 拥有一个 signed
// 26x32 乘法器和一个同步单端口 72-bit 工作缓存，保存
// 所有 NUM_VOICES*LOCAL_MODES 个 mode。一个帧逐 voice 处理：
// 四个 lane 并行运行一个 voice，被排空，然后下一个活动 voice
// 开始。这是 rtl/module2BC_design.md 第 4 节允许的
// “run one voice and drain”调度；必须在
// 32x48 帧上实测，而不是从理论下界推断。
//
// 帧契约：
//   * 优先级 reset > clear > cfg > sample；busy 时三个 ready 都为 0
//   * 非法请求会被接受并以 error 拒绝，无副作用
//   * 在任何状态被更新之前对整个帧做范围检查，因此
//     后面一个非法 voice 不会让前面的 voice 已提交
//   * 非活动 voice 被冻结；n_modes=0 的活动 voice 合法
//     并产生零 voice 和
//   * 每个活动 voice 一个 voice_valid，然后在所有状态回写完成后
//     一个 out_valid；输出无 backpressure
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

    // 系数配置
    input  logic                   cfg_valid,
    output logic                   cfg_ready,
    input  logic [VW-1:0]          cfg_voice,
    input  logic [MW-1:0]          cfg_mode,
    input  logic [71:0]            cfg_word,

    // 逐 voice 逻辑状态清除
    input  logic                   clear_valid,
    output logic                   clear_ready,
    input  logic [VW-1:0]          clear_voice,
    output logic                   clear_done,

    // 单采样帧请求
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

    // 逐 lane 回写可观测性
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
    logic [N_MODES-1:0] coeff_loaded [0:NUM_VOICES-1];   // clear 时保留状态
    localparam logic [N_MODES-1:0] MODE_ONE = {{(N_MODES-1){1'b0}}, 1'b1};

    // 锁存的运行帧（驱动 run；仅在 PREP 写入）
    logic [NUM_VOICES-1:0]    act_r;
    logic [NUM_VOICES*MW-1:0] nm_r;
    logic [NUM_VOICES*32-1:0] x_r;
    logic [VW-1:0]            vcur;

    // intake 候选暂存：在 sample 握手时捕获，仅当 precheck 通过时才由
    // PREP 消费。被拒绝的候选绝不进入运行帧（死 token），因此没有可观测
    // 副作用。
    logic [NUM_VOICES-1:0]    act_c;
    logic [NUM_VOICES*MW-1:0] nm_c;
    logic [NUM_VOICES*32-1:0] x_c;

    // 寄存的逐 voice 选择（VSELECT），使宽 vcur-muxed 的
    // run_n/run_x/voice 不组合地位于 lane start 路径上
    logic [MW-1:0]            run_n_r;
    logic signed [31:0]       run_x_r;
    logic [VW-1:0]            vcur_r;

    logic signed [63:0] mix_acc, voice_sum_r;
    logic [SW-1:0]      sat_acc;
    logic [5:0]         voice_sat_r;

    // ------------------------------------------------------------------
    // 辅助函数
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

    // 一个 voice 未加载的最低 mode 索引（整行都存在时为 N_MODES）。一个 voice
    // 对 n 个 mode 完全加载当且仅当 n <= 该值，这在逻辑上等同于
    // ((~coeff_loaded & mask(n)) != 0)，但让整帧 precheck 使用短的
    // width-MW 比较，而不是可变宽度的 mask 移位。更新保持在寄存器中，
    // 使长的 n_modes 向量不会在同边沿拒绝路径上
    // 到达宽桶形移位器。
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

    wire clear_ok = clear_fire && (clear_voice < NUM_VOICES);
    wire cfg_ok   = cfg_fire && (cfg_mode < N_MODES) && (cfg_voice < NUM_VOICES);

    wire [1:0] cfg_lane = cfg_mode % 4;
    wire [IDXW-1:0] cfg_local_w = cfg_mode >> 2;

    // 整帧合法性：在触动任何状态之前检查（同周期拒绝是外部契约的一部分：
    // error_valid 在握手周期拉高，busy 保持低）。一个 voice 未加载当且仅当
    // 其 mode 数量超过 low_unloaded[v]（寄存的最低未配置 mode
    // 索引）；这在逻辑上等同于 (~coeff_loaded[v] & mask(nv)) != 0，
    // 但用浅的 MW-bit 比较替代了
    // 宽的可变移位。
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
    // 逐 voice 元数据寄存器：coeff_loaded / low_unloaded
    //
    // 每个 voice 使用常量索引下的 packed loaded_r/prefix_r 寄存器，消除
    // coeff_loaded[cfg_voice] 动态索引读-改-写的 RAM 推断模式。旧生产网表
    // 在 mode17 后从 RAM 读回到最低缺失索引的计算不等价；这里明确使用
    // 本 voice 寄存器自反馈，修复后仍须检查真实综合映射和网表功能。
    //
    // 语义与原实现保持一致：
    //   * 同步 reset 清 0（reset 优先）
    //   * clear 不触碰本块（clear 只清 lane 历史，不擦系数存在位）
    //   * 仅在合法 cfg 握手 cfg_ok（= cfg_fire && mode<N_MODES && voice<NUM_VOICES）
    //     且命中本 voice 时置位，任意顺序/重复写都合法
    //   * 同一 cfg 边沿就以“含本次 mode 的行”更新 prefix，因此紧接的下一拍
    //     sample 立即看到新前缀
    // 顶层 coeff_loaded/low_unloaded 仍按原数组形式保留，由本块的寄存器
    // assign 驱动，供测试/审查观测。
    // ------------------------------------------------------------------
    genvar gv;
    generate
        for (gv = 0; gv < NUM_VOICES; gv = gv + 1) begin : g_meta
            logic [N_MODES-1:0] loaded_r;
            logic [MW-1:0]      prefix_r;

            always_ff @(posedge clk) begin
                if (!rst_n) begin
                    loaded_r <= '0;
                    prefix_r <= {MW{1'b0}};
                end else if (cfg_ok && (cfg_voice == gv[VW-1:0])) begin
                    loaded_r <= loaded_r | (MODE_ONE << cfg_mode);
                    prefix_r <= lowest_missing(loaded_r | (MODE_ONE << cfg_mode));
                end
            end

            assign coeff_loaded[gv] = loaded_r;
            assign low_unloaded[gv] = prefix_r;
        end
    endgenerate

    // ------------------------------------------------------------------
    // 四个 lane
    // ------------------------------------------------------------------
    wire start_lane = (state == VSTART);
    // lane 输入来自 VSELECT 寄存的选择（不是从 vcur/nm_r/x_r 实时 mux），
    // 因此宽的逐 voice mux 不在 lane start/CE 路径上。
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
    // 帧控制器
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
                        end
                        // 合法 cfg 的元数据由独立的逐 voice g_meta 块更新；
                        // 此处不再写 coeff_loaded/low_unloaded，避免多驱动，
                        // 也避免动态索引读-改-写被推断成 RAM。
                    end else if (sample_fire) begin
                        // 捕获候选（暂存），并且仅当同边沿 precheck 通过时才
                        // 进入 PREP。拒绝路径在该握手边沿保持 error_valid 且
                        // busy 为低，且绝不写入 act_r/nm_r/x_r/mix_acc
                        // 或任何历史。
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
                    // 已接受的帧：将暂存候选复制到运行负载并
                    // 初始化累加器。宽的 act_r/nm_r/x_r 使能由这个
                    // 浅层状态译码驱动，
                    // 不在 precheck/scan 路径上。
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
                    // 寄存 vcur-muxed 的逐 voice 输入，然后从寄存的副本
                    // 启动各 lane。
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
