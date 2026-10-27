`timescale 1ns/1ps
// CONFIG 解析器：每个已校验的 CONFIG 帧只处理一条命令，协议 v1。
//
// 职责：
//   - 每条命令只消费一个完整帧（first..last）
//   - 校验外层长度一致性和命令字段；帧完整前不修改共享 shadow
//   - 在向后级发起提交前，执行 MIDI 事件/消费者屏障
//   - 等到后级返回真实完成结果后才回复
//   - 每个来源保留一条最近的重试缓存（seq、len、完整 payload、result），
//     命中时直接重放，不再向后级提交
//   - 对已取消（隔离）的来源，抑制回复和缓存发布
//
// 这里有意不实现 EQ/音频算法。仅校验错误和缓存重放会立即回复；
// 合法配置走 cfg_valid/cfg_ready，再走 cfg_done_valid/cfg_done_ready。
// 不猜测 ACK。
module config_analyzer #(
    parameter int EQ_BANDS = 3
) (
    input  logic        clk,
    input  logic        rst_n,

    // 已校验帧的 payload 流（来源/seq/len 侧带随行）。
    input  logic        s_valid,
    output logic        s_ready,
    input  logic [7:0]  s_data,
    input  logic        s_first,
    input  logic        s_last,
    input  logic        s_source_id,
    input  logic [15:0] s_seq,
    input  logic [5:0]  s_payload_len,

    // 每来源维护侧带。
    input  logic [1:0]  session_reset,
    input  logic [1:0]  cancel_source,

    // 此前 MIDI FIFO 已排空，且应用侧操作空闲。
    input  logic        barrier_ready,

    // 两段式后级提交请求。
    output logic        cfg_valid,
    output logic        cfg_source_id,
    output logic [15:0] cfg_seq,
    output logic [7:0]  cfg_command,
    output logic [4:0]  cfg_payload_len,
    output logic [127:0] cfg_shadow,
    input  logic        cfg_ready,

    // 后级完成（result 是权威的最终结果）。
    input  logic        cfg_done_valid,
    output logic        cfg_done_ready,
    input  logic [7:0]  cfg_result,

    // 最终回复描述符。request_type=02 由 TX 编码器补上。
    output logic        reply_valid,
    input  logic        reply_ready,
    output logic        reply_source_id,
    output logic [15:0] reply_seq,
    output logic [7:0]  reply_command,
    output logic [7:0]  reply_result,

    output logic        frame_done,
    output logic        busy
);

    // 线上协议结果码（PROTOCOL_V1 §7.2）。
    localparam logic [7:0] RESULT_OK          = 8'd0;
    localparam logic [7:0] RESULT_UNSUPPORTED = 8'd1;
    localparam logic [7:0] RESULT_BAD_LENGTH  = 8'd2;
    localparam logic [7:0] RESULT_OUT_OF_RANGE= 8'd3;
    localparam logic [7:0] RESULT_BUSY        = 8'd4;
    localparam logic [7:0] RESULT_SEQ_CONFLICT= 8'd5;
    localparam logic [7:0] RESULT_NOT_READY   = 8'd6;

    localparam logic [7:0] CMD_EQ_SET     = 8'h01;
    localparam logic [7:0] CMD_REVERB_SET = 8'h02;

    localparam logic [5:0] MAX_CONFIG_PAYLOAD = 6'd16;

    typedef enum logic [3:0] {
        S_IDLE,
        S_RECV,
        S_LOOKUP,
        S_EVAL,
        S_WAIT_BARRIER,
        S_CFG,
        S_WAIT_DONE,
        S_REPLY,
        S_DONE,
        S_RETIRE
    } state_t;

    state_t state;

    // 锁存的帧上下文。
    logic        ctx_source;
    logic [15:0] ctx_seq;
    logic [5:0]  ctx_declared_len;
    logic [5:0]  ctx_count;
    logic [127:0] ctx_payload;
    logic        ctx_saw_first;
    logic        ctx_bad_frame;
    logic        ctx_overflow;
    logic [7:0]  ctx_result;
    logic        ctx_do_cache;      // 回复被接收时发布该结果
    logic        ctx_canceled;      // 该上下文属于已取消的来源
    logic        ctx_session_stale; // 上下文开始后发生了会话复位

    // 每来源最近一次重试缓存（每个来源一项）。
    logic        cache_valid   [0:1];
    logic [15:0] cache_seq     [0:1];
    logic [5:0]  cache_len     [0:1];
    logic [127:0] cache_payload[0:1];
    logic [7:0]  cache_result  [0:1];

    // 组合逻辑校验结果。
    logic        frame_ok;
    logic        sem_ok;
    logic [7:0]  sem_result;
    logic        cache_hit;
    logic        cache_conflict;
    // 把 128-bit 比较拆到时钟边界两侧；否则 Gowin 会在 S_EVAL 结果路径上
    // 映射出一长串进位/归约链。
    (* syn_preserve = 1 *) logic [3:0] cache_equal_parts;
    logic cache_key_match, cache_length_match;

    logic [7:0]  v_cmd;
    logic [7:0]  v_band;
    logic [7:0]  v_enable;
    logic [7:0]  v_filter_type;
    logic [7:0]  v_preset;
    logic [15:0] v_frequency;
    logic signed [15:0] v_gain;
    logic [15:0] v_q;

    integer i;

    // ---------------------------------------------------------------------
    // 握手 / 状态输出
    // ---------------------------------------------------------------------
    assign s_ready        = (state == S_IDLE) || (state == S_RECV);
    assign busy           = (state != S_IDLE);
    assign frame_done     = (state == S_DONE) || (state == S_RETIRE);

    // 已取消的来源不得再发起新的提交或回复。这里同时参考上下文里的取消锁存，
    // 这样单拍 cancel 脉冲会在该上下文余下生命周期内持续生效。
    assign cfg_valid      = (state == S_CFG) &&
                            !ctx_canceled && !cancel_source[ctx_source];
    assign reply_valid    = (state == S_REPLY) &&
                            !ctx_canceled && !cancel_source[ctx_source];

    // 后级一旦接收了请求，即使来源随后被取消，也要继续等待真实完成。
    assign cfg_done_ready = (state == S_WAIT_DONE);

    assign cfg_source_id   = ctx_source;
    assign cfg_seq         = ctx_seq;
    assign cfg_command     = ctx_payload[7:0];
    assign cfg_payload_len = ctx_declared_len[4:0];
    assign cfg_shadow      = ctx_payload;

    assign reply_source_id = ctx_source;
    assign reply_seq       = ctx_seq;
    assign reply_command   = ctx_payload[7:0];
    assign reply_result    = ctx_result;

    // ---------------------------------------------------------------------
    // 帧完整性与语义校验
    // ---------------------------------------------------------------------
    // 解析器先收完整帧，再做任何决定。只有满足以下条件的帧才可用：
    // 第 0 字节带 s_first 起始、没有多余的 first 标记、不超过 16 字节 CONFIG 上限、
    // 已接收字节数等于声明的 payload 长度。
    always_comb begin
        frame_ok = ctx_saw_first &&
                   !ctx_bad_frame &&
                   !ctx_overflow &&
                   (ctx_declared_len >= 6'd1) &&
                   (ctx_declared_len <= MAX_CONFIG_PAYLOAD) &&
                   (ctx_count == ctx_declared_len);
    end

    // 从 shadow 中提取小端字段（byte 0 位于 [7:0]）。
    assign v_cmd         = ctx_payload[7:0];
    assign v_band        = ctx_payload[15:8];
    assign v_enable      = ctx_payload[23:16];
    assign v_filter_type = ctx_payload[31:24];
    assign v_preset      = ctx_payload[15:8];
    assign v_frequency   = {ctx_payload[47:40], ctx_payload[39:32]};
    assign v_gain        = $signed({ctx_payload[63:56], ctx_payload[55:48]});
    assign v_q           = {ctx_payload[79:72], ctx_payload[71:64]};

    always_comb begin
        sem_ok     = 1'b0;
        sem_result = RESULT_BAD_LENGTH;

        if ((ctx_declared_len == 6'd0) ||
            (ctx_declared_len > MAX_CONFIG_PAYLOAD)) begin
            sem_result = RESULT_BAD_LENGTH;
        end else begin
            case (v_cmd)
                CMD_EQ_SET: begin
                    if (ctx_declared_len != 6'd10) begin
                        sem_result = RESULT_BAD_LENGTH;
                    end else if (v_filter_type != 8'd0) begin
                        // v1 只支持 peaking/bell；不要静默映射成别的滤波器。
                        sem_result = RESULT_UNSUPPORTED;
                    end else if (v_band >= EQ_BANDS) begin
                        sem_result = RESULT_OUT_OF_RANGE;
                    end else if (v_enable > 8'd1) begin
                        sem_result = RESULT_OUT_OF_RANGE;
                    end else if ((v_frequency < 16'd20) ||
                                 (v_frequency > 16'd20000)) begin
                        sem_result = RESULT_OUT_OF_RANGE;
                    end else if ((v_gain < -16'sd3072) ||
                                 (v_gain > 16'sd3072)) begin
                        sem_result = RESULT_OUT_OF_RANGE;
                    end else if ((v_q < 16'd26) || (v_q > 16'd2560)) begin
                        sem_result = RESULT_OUT_OF_RANGE;
                    end else begin
                        sem_result = RESULT_OK;
                        sem_ok     = 1'b1;
                    end
                end

                CMD_REVERB_SET: begin
                    if (ctx_declared_len != 6'd2) begin
                        sem_result = RESULT_BAD_LENGTH;
                    end else if (v_preset > 8'd2) begin
                        sem_result = RESULT_OUT_OF_RANGE;
                    end else begin
                        sem_result = RESULT_OK;
                        sem_ok     = 1'b1;
                    end
                end

                default: begin
                    sem_result = RESULT_UNSUPPORTED;
                end
            endcase
        end
    end

    // 只对结构可用的帧做缓存查找。同一拍发生会话复位时，命中与冲突都置为假：
    // 失效优先。
    always_comb begin
        cache_hit      = 1'b0;
        cache_conflict = 1'b0;

        if (frame_ok && cache_key_match && cache_valid[ctx_source] &&
            !session_reset[ctx_source] && !ctx_session_stale) begin
                if (cache_length_match && (&cache_equal_parts)) begin
                    cache_hit = 1'b1;
                end else begin
                    // 同来源、同 SEQ 但内容不同：报告冲突，绝不替换不可变的原缓存。
                    cache_conflict = 1'b1;
                end
        end
    end

    // 只有在回复真正被接收后才发布缓存。已取消/隔离或会话失效的上下文不发布；
    // session_reset 优先于同一拍的写。
    logic cache_we;
    always_comb begin
        cache_we = (state == S_REPLY) &&
                   reply_valid && reply_ready &&
                   ctx_do_cache &&
                   !ctx_canceled && !cancel_source[ctx_source] &&
                   !ctx_session_stale &&
                   !session_reset[ctx_source];
    end

    // ---------------------------------------------------------------------
    // 帧 / 命令状态机
    // ---------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= S_IDLE;
            ctx_source        <= 1'b0;
            ctx_seq           <= 16'd0;
            ctx_declared_len  <= 6'd0;
            ctx_count         <= 6'd0;
            ctx_payload       <= 128'd0;
            ctx_saw_first     <= 1'b0;
            ctx_bad_frame     <= 1'b0;
            ctx_overflow      <= 1'b0;
            ctx_result        <= 8'd0;
            ctx_do_cache      <= 1'b0;
            ctx_canceled      <= 1'b0;
            ctx_session_stale <= 1'b0;
            cache_equal_parts <= '0;
            cache_key_match <= 1'b0;
            cache_length_match <= 1'b0;
        end else begin
            // 当前在途上下文的维护侧带。
            if (state != S_IDLE) begin
                if (cancel_source[ctx_source])
                    ctx_canceled <= 1'b1;
                if (session_reset[ctx_source])
                    ctx_session_stale <= 1'b1;
            end

            case (state)
                S_IDLE: begin
                    if (s_valid && s_ready) begin
                        // 帧开始。第一个被接收的字节必须在字节偏移 0 处带 s_first。
                        ctx_source        <= s_source_id;
                        ctx_seq           <= s_seq;
                        ctx_declared_len  <= s_payload_len;
                        ctx_count         <= 6'd1;
                        ctx_payload       <= {{120{1'b0}}, s_data};
                        ctx_saw_first     <= s_first;
                        ctx_bad_frame     <= ~s_first;
                        ctx_overflow      <= 1'b0;
                        ctx_result        <= 8'd0;
                        ctx_do_cache      <= 1'b0;
                        ctx_canceled      <= cancel_source[s_source_id];
                        ctx_session_stale <= 1'b0;
                        if (s_last)
                            state <= S_LOOKUP;
                        else
                            state <= S_RECV;
                    end
                end

                S_RECV: begin
                    if (s_valid && s_ready) begin
                        if (s_first)
                            ctx_bad_frame <= 1'b1;
                        if (ctx_count < MAX_CONFIG_PAYLOAD)
                            ctx_payload[{ctx_count[3:0], 3'b000} +: 8] <= s_data;
                        else
                            ctx_overflow <= 1'b1;
                        if (ctx_count < 6'd63)
                            ctx_count <= ctx_count + 6'd1;
                        if (s_last)
                            state <= S_LOOKUP;
                    end
                end

                S_LOOKUP: begin
                    for (int part = 0; part < 4; part = part + 1)
                        cache_equal_parts[part] <=
                            cache_payload[ctx_source][part*32 +: 32] == ctx_payload[part*32 +: 32];
                    cache_key_match <= cache_valid[ctx_source] &&
                                       cache_seq[ctx_source] == ctx_seq && !session_reset[ctx_source];
                    cache_length_match <= cache_len[ctx_source] == ctx_declared_len;
                    state <= S_EVAL;
                end

                S_EVAL: begin
                    if (ctx_canceled || cancel_source[ctx_source]) begin
                        // 接收过程中被取消：直接退休，不回复。
                        state <= S_RETIRE;
                    end else if (!frame_ok) begin
                        // 外层帧/长度畸形。不要写缓存，也不要到达后级；
                        // 此时 SEQ 本身不可信。
                        ctx_result   <= RESULT_BAD_LENGTH;
                        ctx_do_cache <= 1'b0;
                        state        <= S_REPLY;
                    end else if (cache_hit) begin
                        ctx_result   <= cache_result[ctx_source];
                        ctx_do_cache <= 1'b0;
                        state        <= S_REPLY;
                    end else if (cache_conflict) begin
                        ctx_result   <= RESULT_SEQ_CONFLICT;
                        ctx_do_cache <= 1'b0;
                        state        <= S_REPLY;
                    end else if (!sem_ok) begin
                        // 请求结构合法，但命令/字段有错。该错误可缓存，不触碰后级。
                        ctx_result   <= sem_result;
                        ctx_do_cache <= 1'b1;
                        state        <= S_REPLY;
                    end else begin
                        // 合法配置：等待事件屏障。
                        ctx_do_cache <= 1'b1;
                        state        <= S_WAIT_BARRIER;
                    end
                end

                S_WAIT_BARRIER: begin
                    if (ctx_canceled || cancel_source[ctx_source])
                        state <= S_RETIRE;
                    else if (barrier_ready)
                        state <= S_CFG;
                end

                S_CFG: begin
                    if (ctx_canceled || cancel_source[ctx_source]) begin
                        // 后级尚未接收：干净地中止请求。
                        state <= S_RETIRE;
                    end else if (cfg_ready) begin
                        // 握手完成：从这里开始，提交由后级负责。
                        state <= S_WAIT_DONE;
                    end
                end

                S_WAIT_DONE: begin
                    if (cfg_done_valid && cfg_done_ready) begin
                        ctx_result <= cfg_result;
                        if (ctx_canceled || cancel_source[ctx_source])
                            state <= S_RETIRE;
                        else
                            state <= S_REPLY;
                    end
                end

                S_REPLY: begin
                    if (ctx_canceled || cancel_source[ctx_source]) begin
                        // 旧/隔离上下文：抑制回复。
                        state <= S_RETIRE;
                    end else if (reply_ready) begin
                        state <= S_DONE;
                    end
                end

                S_DONE: begin
                    state <= S_IDLE;
                end

                S_RETIRE: begin
                    state <= S_IDLE;
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

    // ---------------------------------------------------------------------
    // 每来源最近结果缓存
    // ---------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 2; i = i + 1) begin
                cache_valid[i]   <= 1'b0;
                cache_seq[i]     <= 16'd0;
                cache_len[i]     <= 6'd0;
                cache_payload[i] <= 128'd0;
                cache_result[i]  <= 8'd0;
            end
        end else begin
            // 失效优先于同一拍的缓存发布。
            for (i = 0; i < 2; i = i + 1) begin
                if (session_reset[i])
                    cache_valid[i] <= 1'b0;
            end

            if (cache_we) begin
                cache_valid[ctx_source]   <= 1'b1;
                cache_seq[ctx_source]     <= ctx_seq;
                cache_len[ctx_source]     <= ctx_declared_len;
                cache_payload[ctx_source] <= ctx_payload;
                cache_result[ctx_source]  <= ctx_result;
            end
        end
    end

endmodule
