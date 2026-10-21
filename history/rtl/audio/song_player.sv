// -----------------------------------------------------------------------------
// song_player.sv -- 用于 modal_engine 的自动公有领域旋律前端。
//
// 驱动引擎的 load 和 sample 端口并对其进行定序，使得每个
// 48 kHz tick 产生一个样本帧。离线事件->声部分配：
// 事件 k 被加载到声部 k % NUM_VOICES（一个固定的循环分配器，*不是*
// 第 4 阶段的自动分配器）。槽位的尾部被保留，因为已加载的声部
// 仍留在 active_mask 中；只有当分配器再次轮到它们时
// 槽位才会被重新分配。
//
// 时间线：
//   * 每个 sample_tick 发出一个样本（一个由音频帧翻转
//     导出的 core 域脉冲）。在前一个样本仍在处理时到来的 tick
//     不会丢失：它会被计数并置位 deadline_error，
//     从不静默跳过。
//   * 音符间隔默认 NOTE_GAP=12000 个样本（48 kHz 下 250 ms）；旋律
//     在尾部间隔之后循环。
//   * 每个事件首先通过引擎 load 握手加载其目标槽位；
//     7 样本升余弦激励在下一个被接受的样本处开始。
//     脉冲位置只有在样本请求真正被接受
//     （sample_ready）时才推进，绝不在未被接收的 valid 上推进。
//
// 这 7 个脉冲值是整数模型的升余弦脉冲，幅度 0.2，
// 使用与 python/modal_sim/fixed_point.py 相同的四舍五入规则量化。
//
// 力度：输出 load_vel[7:0]（0..255）。固定曲谱固定用 255（满力度），
// 压力传感器前端以后把每个事件的 8-bit 值接到 load_vel；真正的幅度缩放
// 在 coeff_loader 装载时完成（按 vel_q 缩放 G），本模块不增加乘法器。
// load_dyn[0] 仍是采样层/选表位，不承载连续力度。
// 注意：piano 档（load_dyn=0）仍要求 12 样本脉冲；当前固定曲谱只用 forte。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module song_player #(
    parameter int NUM_VOICES = 8,
    parameter int N_MODES    = 48,
    parameter int NOTE_GAP   = 12000,
    parameter int PULSE_LEN  = 7,
    parameter logic [7:0] SCORE_VEL = 8'd255,
    parameter int VW = (NUM_VOICES < 2) ? 1 : $clog2(NUM_VOICES),
    parameter int MW = (N_MODES < 1) ? 1 : $clog2(N_MODES + 1)
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  diag_clear,

    // engine load 端口
    output logic                  load_valid,
    input  logic                  load_ready,
    output logic [VW-1:0]         load_voice,
    output logic [1:0]            load_instrument,
    output logic [6:0]            load_midi,
    output logic                  load_dyn,        // 采样层：0=piano，1=forte
    output logic [7:0]            load_vel,        // 8-bit 力度，0..255
    input  logic                  load_done,
    input  logic [VW-1:0]         done_voice,
    input  logic [MW-1:0]         loaded_n_modes,

    // engine sample 端口
    output logic                  sample_valid,
    input  logic                  sample_ready,
    output logic [NUM_VOICES-1:0] active_mask,
    output logic [NUM_VOICES*32-1:0] x_vec,
    input  logic                  engine_out_valid,
    input  logic signed [63:0]    engine_mix_sum,

    // 节拍（每个 48 kHz 音频帧一个 core 域脉冲）
    input  logic                  sample_tick,

    // 为输出适配器产生的样本
    output logic                  out_valid,
    output logic signed [63:0]    out_sum,

    // 诊断 / 可观测性
    output logic                  deadline_error,
    output logic                  busy,
    output logic [5:0]            event_index
);

    localparam int CW = (NOTE_GAP < 2) ? 1 : $clog2(NOTE_GAP);
    localparam int EW = 17;                         // {vel[7:0], midi[6:0], inst[1:0]}
    localparam int NUM_EVENTS = 42;
    // 固定曲谱先用满力度；压力传感器前端以后把这里换成每个事件的 8-bit 值。

    // ------------------------------------------------------------------
    // 公有领域 Twinkle-Twinkle 旋律，guitar（inst=0）forte（dyn=1）
    // ------------------------------------------------------------------
    function automatic [EW-1:0] event_at(input [5:0] idx);
        case (idx)
            6'd0 : event_at = {SCORE_VEL, 7'd60, 2'd0};
            6'd1 : event_at = {SCORE_VEL, 7'd60, 2'd0};
            6'd2 : event_at = {SCORE_VEL, 7'd67, 2'd0};
            6'd3 : event_at = {SCORE_VEL, 7'd67, 2'd0};
            6'd4 : event_at = {SCORE_VEL, 7'd69, 2'd0};
            6'd5 : event_at = {SCORE_VEL, 7'd69, 2'd0};
            6'd6 : event_at = {SCORE_VEL, 7'd67, 2'd0};
            6'd7 : event_at = {SCORE_VEL, 7'd65, 2'd0};
            6'd8 : event_at = {SCORE_VEL, 7'd65, 2'd0};
            6'd9 : event_at = {SCORE_VEL, 7'd64, 2'd0};
            6'd10: event_at = {SCORE_VEL, 7'd64, 2'd0};
            6'd11: event_at = {SCORE_VEL, 7'd62, 2'd0};
            6'd12: event_at = {SCORE_VEL, 7'd62, 2'd0};
            6'd13: event_at = {SCORE_VEL, 7'd60, 2'd0};
            6'd14: event_at = {SCORE_VEL, 7'd67, 2'd0};
            6'd15: event_at = {SCORE_VEL, 7'd67, 2'd0};
            6'd16: event_at = {SCORE_VEL, 7'd65, 2'd0};
            6'd17: event_at = {SCORE_VEL, 7'd65, 2'd0};
            6'd18: event_at = {SCORE_VEL, 7'd64, 2'd0};
            6'd19: event_at = {SCORE_VEL, 7'd64, 2'd0};
            6'd20: event_at = {SCORE_VEL, 7'd62, 2'd0};
            6'd21: event_at = {SCORE_VEL, 7'd67, 2'd0};
            6'd22: event_at = {SCORE_VEL, 7'd67, 2'd0};
            6'd23: event_at = {SCORE_VEL, 7'd65, 2'd0};
            6'd24: event_at = {SCORE_VEL, 7'd65, 2'd0};
            6'd25: event_at = {SCORE_VEL, 7'd64, 2'd0};
            6'd26: event_at = {SCORE_VEL, 7'd64, 2'd0};
            6'd27: event_at = {SCORE_VEL, 7'd62, 2'd0};
            6'd28: event_at = {SCORE_VEL, 7'd60, 2'd0};
            6'd29: event_at = {SCORE_VEL, 7'd60, 2'd0};
            6'd30: event_at = {SCORE_VEL, 7'd67, 2'd0};
            6'd31: event_at = {SCORE_VEL, 7'd67, 2'd0};
            6'd32: event_at = {SCORE_VEL, 7'd69, 2'd0};
            6'd33: event_at = {SCORE_VEL, 7'd69, 2'd0};
            6'd34: event_at = {SCORE_VEL, 7'd67, 2'd0};
            6'd35: event_at = {SCORE_VEL, 7'd65, 2'd0};
            6'd36: event_at = {SCORE_VEL, 7'd65, 2'd0};
            6'd37: event_at = {SCORE_VEL, 7'd64, 2'd0};
            6'd38: event_at = {SCORE_VEL, 7'd64, 2'd0};
            6'd39: event_at = {SCORE_VEL, 7'd62, 2'd0};
            6'd40: event_at = {SCORE_VEL, 7'd62, 2'd0};
            6'd41: event_at = {SCORE_VEL, 7'd60, 2'd0};
            default: event_at = {SCORE_VEL, 7'd60, 2'd0};
        endcase
    endfunction

    // 7 样本升余弦脉冲，幅度 0.2，Q2.30 四舍五入
    function automatic logic signed [31:0] pulse_val(input [2:0] i);
        case (i)
            3'd0: pulse_val = 32'sd0;
            3'd1: pulse_val = 32'sd40427475;
            3'd2: pulse_val = 32'sd131267186;
            3'd3: pulse_val = 32'sd204114978;
            3'd4: pulse_val = 32'sd204114978;
            3'd5: pulse_val = 32'sd131267186;
            3'd6: pulse_val = 32'sd40427475;
            default: pulse_val = 32'sd0;
        endcase
    endfunction

    // ------------------------------------------------------------------
    // 状态
    // ------------------------------------------------------------------
    localparam logic [2:0] S_IDLE = 3'd0, S_LOAD = 3'd1, S_LOADW = 3'd2,
                           S_SAMPLE = 3'd3, S_SAMPLEW = 3'd4, S_DONE = 3'd5;

    logic [2:0]            state;
    logic [7:0]            pending;
    logic [5:0]            ev_idx;
    logic [CW-1:0]         samp_cnt;

    logic [VW-1:0]         ld_voice;
    logic [1:0]            ld_inst;
    logic [6:0]            ld_midi;
    logic                  ld_dyn;
    logic [7:0]            ld_vel;

    logic [NUM_VOICES-1:0] loaded_mask;
    logic [2:0]            pulse_pos [0:NUM_VOICES-1];

    logic signed [63:0]    sum_r;
    logic                  valid_r;
    logic                  deadline_r;

    wire [EW-1:0] cur_ev = event_at(ev_idx);
    wire [VW-1:0] next_voice = ev_idx % NUM_VOICES;

    assign active_mask     = loaded_mask;
    assign load_valid      = (state == S_LOAD);
    assign sample_valid    = (state == S_SAMPLE);
    assign load_voice      = ld_voice;
    assign load_instrument = ld_inst;
    assign load_midi       = ld_midi;
    assign load_dyn        = ld_dyn;
    assign load_vel        = ld_vel;

    assign out_valid       = valid_r;
    assign out_sum         = sum_r;
    assign deadline_error  = deadline_r;
    assign busy            = (state != S_IDLE);
    assign event_index     = ev_idx;

    always_comb begin
        for (int v = 0; v < NUM_VOICES; v = v + 1) begin
            if (pulse_pos[v] < PULSE_LEN)
                x_vec[v*32 +: 32] = pulse_val(pulse_pos[v]);
            else
                x_vec[v*32 +: 32] = 32'sd0;
        end
    end

    // ------------------------------------------------------------------
    // 主 FSM
    // ------------------------------------------------------------------
    // tick 从不丢失：即使它与一个待处理样本启动落在同一周期，
    // 也会被合并进 pending 计数器。在一个样本仍在处理（或
    // 已经待处理）时到来的 tick 会置位
    // 粘滞 deadline 标志。
    wire        busy_now  = (state != S_IDLE);
    wire        miss_now  = sample_tick & (busy_now | (pending != 8'd0));
    wire [7:0]  pend_inc  = (pending == 8'hFF) ? pending : (pending + 8'd1);
    wire [7:0]  pend_base = sample_tick ? pend_inc : pending;
    wire        start_now = (state == S_IDLE) && (pending != 8'd0);
    wire [7:0]  pend_nxt  = start_now ? (pend_base - 8'd1) : pend_base;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            pending    <= 8'd0;
            ev_idx     <= 6'd0;
            samp_cnt   <= {CW{1'b0}};
            ld_voice   <= {VW{1'b0}};
            ld_inst    <= 2'd0;
            ld_midi    <= 7'd0;
            ld_dyn     <= 1'b0;
            ld_vel     <= SCORE_VEL;
            loaded_mask<= {NUM_VOICES{1'b0}};
            sum_r      <= 64'sd0;
            valid_r    <= 1'b0;
            deadline_r <= 1'b0;
            for (int v = 0; v < NUM_VOICES; v = v + 1)
                pulse_pos[v] <= 3'd7;               // 无活动脉冲
        end else begin
            valid_r <= 1'b0;
            if (diag_clear) deadline_r <= 1'b0;

            if (miss_now) deadline_r <= 1'b1;
            pending <= pend_nxt;

            case (state)
                S_IDLE: begin
                    if (start_now) begin
                        if (samp_cnt == {CW{1'b0}}) begin
                            ld_voice <= next_voice;
                            ld_inst  <= cur_ev[1:0];
                            ld_midi  <= cur_ev[8:2];
                            ld_dyn   <= 1'b1;          // 固定曲谱用 forte 表
                            ld_vel   <= cur_ev[16:9];  // 8-bit 力度（曲谱全 255）
                            state    <= S_LOAD;
                        end else begin
                            state <= S_SAMPLE;
                        end
                    end
                end

                S_LOAD: begin
                    if (load_ready) state <= S_LOADW;
                end

                S_LOADW: begin
                    if (load_done) begin
                        loaded_mask[done_voice] <= 1'b1;
                        pulse_pos[done_voice]   <= 3'd0;   // 武装脉冲
                        ev_idx <= (ev_idx == (NUM_EVENTS-1)) ? 6'd0
                                                             : (ev_idx + 6'd1);
                        state  <= S_SAMPLE;
                    end
                end

                S_SAMPLE: begin
                    if (sample_ready) begin
                        // 已接受：推进脉冲位置和时间线
                        for (int v = 0; v < NUM_VOICES; v = v + 1)
                            if (pulse_pos[v] < PULSE_LEN)
                                pulse_pos[v] <= pulse_pos[v] + 3'd1;
                        if (samp_cnt == (NOTE_GAP-1))
                            samp_cnt <= {CW{1'b0}};
                        else
                            samp_cnt <= samp_cnt + 1'b1;
                        state <= S_SAMPLEW;
                    end
                end

                S_SAMPLEW: begin
                    if (engine_out_valid) begin
                        sum_r   <= engine_mix_sum;
                        valid_r <= 1'b1;
                        state   <= S_DONE;
                    end
                end

                default: state <= S_IDLE;   // S_DONE
            endcase
        end
    end

endmodule
