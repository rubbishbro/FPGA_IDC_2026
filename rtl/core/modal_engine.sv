// -----------------------------------------------------------------------------
// modal_engine.sv -- module 2B/2C 集成。
//
// 将 coefficient loader（2B）连接到 32-voice poly bank（2C）：
//   * 外部 load 端口就是 loader 接口
//   * 成功 load_done 时 engine 存储该 voice 的 mode 数量和 loaded 标志；
//     帧中只能激活已加载的 voice（否则 error 4）
//   * loading 和 sampling 互斥；空闲时同时到达的 load/sample 请求以 load 为准，
//     绝不两者都握手
//   * 基础分配（voice n/count/loaded 标志）放在这里，使帧发送方无法伪造
//     mode 数量
//   * reset 取消 compute 和 load 并清除每个 loaded 标志
//
//   error_code 1..3 = load 错误（voice OOB / 缺失 entry / 非法 ROM meta）
//              4    = 活动 voice 尚未成功加载
//              5    = 内部 bank 错误
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

    // load 请求（与 loader 端口相同）
    input  logic                   load_valid,
    output logic                   load_ready,
    input  logic [VW-1:0]          load_voice,
    input  logic [1:0]             load_instrument,
    input  logic [6:0]             load_midi,
    input  logic                   load_dyn,       // 采样层
    input  logic [7:0]             load_vel,       // 8-bit 压力力度
    output logic                   busy,
    output logic                   load_done,
    output logic [VW-1:0]          done_voice,
    output logic [MW-1:0]          loaded_n_modes,

    // 单采样帧请求
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

    // intake 候选暂存：在 sample 握手时捕获，仅对 precheck 通过的帧由
    // E_PREP 消费。被拒绝的候选是死 token，绝不进入运行负载
    // （无可观测副作用），与 bank 自身的候选暂存
    // 完全一样。
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
    // load 仲裁：当两者同时到达时 load 优先于 sampling
    // ------------------------------------------------------------------
    wire engine_idle = (estate == E_IDLE) && !ld_busy && !bk_busy;
    assign load_ready = engine_idle;
    assign sample_ready = engine_idle && !load_valid;

    wire load_fire  = load_valid  && load_ready;
    wire sample_fire = sample_valid && sample_ready;

    logic any_active_unloaded;
    // 一个 voice 若之前已被捕获，或本周期正在观察到 load_done，则可用
    // （寄存的捕获在一个周期后到达，因此在完成周期提供的帧
    // 仍必须看到它已加载）。
    wire [NUM_VOICES-1:0] loaded_eff = voice_loaded
        | (load_done ? ({{(NUM_VOICES-1){1'b0}}, 1'b1} << done_voice) : '0);
    always_comb begin
        any_active_unloaded = 1'b0;
        for (int v = 0; v < NUM_VOICES; v = v + 1)
            if (active_mask[v] && !loaded_eff[v]) any_active_unloaded = 1'b1;
    end

    // n_modes 向量由 engine 自己存储的 metadata 重建。它是 REGISTERED
    // （nm_vec_r），因此 loader 的 n_r 不会组合地到达 bank 的合法性扫描 /
    // 寄存器使能。nm_vec_r 与 voice_nm 在同一拍捕获（两者都由
    // load_done/done_voice 更新），所以相对于 metadata
    // 并非“晚一个周期”；完成加载的帧在完成边沿被接受，
    // E_DRIVE 消费者在下一拍使用新的 n，
    // 从而保持 load-completion-cycle 的 golden 行为。
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
    // 系数 loader
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
        .load_vel     (load_vel),
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
    // 转发输出
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

    // loader 和 bank 错误已经是寄存的单周期脉冲，因此在它们出现的
    // 当拍就转发（这使错误在 engine 返回 idle / 拉高 sample_ready 的
    // 同一周期保持可见）。active-unloaded 错误是寄存的，因为它
    // 派生自一个在同一周期被拒绝的
    // sample 请求。
    assign error_valid = ld_error_valid | bk_error_flag | error4_r;
    assign error_code  = ld_error_valid ? {1'b0, ld_error_code}
                       : bk_error_flag  ? 3'd5
                       : 3'd4;

    // ------------------------------------------------------------------
    // engine metadata + 帧序列器
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

            // 仅捕获成功事务的 load 结果
            if (load_done) begin
                voice_loaded[done_voice] <= 1'b1;
                voice_nm[done_voice]     <= loaded_n_modes;
            end

            // 在浅层 sample 握手时捕获 intake 候选，使宽 x 负载的 CE 不位于
            // any_active_unloaded 之后。下面的 FSM 仅在原始合法性译码
            // 通过时才通过 E_PREP 消费它；非法帧仍会在该边沿拉高
            // error4_r，busy 保持低，
            // 且不触动任何运行寄存器/历史。
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
                    // 浅层状态译码驱动宽运行负载；
                    // bank 请求随后在 E_DRIVE 中带着与 sample 握手同一拍到达的
                    // metadata 发出。
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
