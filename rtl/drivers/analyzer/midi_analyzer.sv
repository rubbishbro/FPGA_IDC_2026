`timescale 1ns/1ps
// MIDI_DATA payload 解析器，面向“包内自包含”的 MIDI 协议。
//
// 每拍接收一个输入字节。帧由已接收字节上的 s_first/s_last 界定；
// running status、pending 数据、SysEx 跳过以及全部解析上下文都在每个帧边界复位。
// 输出事件使用 MIDI_REFERENCE.md 中固定的 32-bit 布局；来源 id 走独立侧带，
// 永远不改变 32-bit 事件本身。
//
// 不依赖路由器、UART、CRC 或 SLIP。上游分帧器假定只送 CRC/长度已校验的帧，
// 但 first/last/len 违约仍会被检测并安全排空，而不是破坏内部状态。

module midi_analyzer (
    input  logic        clk,
    input  logic        rst_n,          // 异步置位、同步释放
    input  logic        flush,          // 同步维护中止

    // 已校验的 MIDI payload 字节流
    input  logic        s_valid,
    output logic        s_ready,
    input  logic [7:0]  s_data,
    input  logic        s_first,
    input  logic        s_last,
    input  logic        s_source_id,
    input  logic [6:0]  s_payload_len,  // 合法帧为 1..64

    // 32-bit 事件 + 来源侧带
    output logic        event_valid,
    input  logic        event_ready,
    output logic [31:0] event_data,
    output logic        event_source_id,

    // 帧 / 错误状态
    output logic        frame_done,     // 尾部事件退休后的单拍脉冲
    output logic        parse_error,    // 每检测到一个错误产生单拍脉冲
    output logic        busy
);

    // ------------------------------------------------------------------
    // 事件种类 / 解析器状态
    // ------------------------------------------------------------------
    localparam logic [3:0] KIND_NOTE_OFF      = 4'd0;
    localparam logic [3:0] KIND_NOTE_ON       = 4'd1;
    localparam logic [3:0] KIND_CONTROL_CHANGE= 4'd2;
    localparam logic [3:0] KIND_PROGRAM       = 4'd3;
    localparam logic [3:0] KIND_PITCH_BEND    = 4'd4;

    localparam logic [1:0] ST_IDLE   = 2'd0;
    localparam logic [1:0] ST_ACTIVE = 2'd1;
    localparam logic [1:0] ST_TAIL   = 2'd2;

    // ------------------------------------------------------------------
    // 解析上下文
    // ------------------------------------------------------------------
    logic [1:0]  state;
    logic        in_sysex;
    logic        pending;       // 等待下一个数据字节的通道消息
    logic [1:0]  data_idx;      // pending 消息已捕获的数据字节数
    logic [7:0]  status_cur;    // pending 通道消息的 status
    logic [7:0]  running;       // 当前通道 running status，0 表示无
    logic [1:0]  sys_skip;      // 剩余需要吞掉的 System Common 数据字节数
    logic [6:0]  byte_count;    // 本帧已接收的字节数
    logic [6:0]  frame_len;     // 锁存的 s_payload_len
    logic        frame_source;  // 锁存的 s_source_id
    logic        frame_bad;     // 长度/帧边界违约，已停止解析
    logic [7:0]  data1;         // pending 消息的第一个已接收数据字节

    // 寄存器输出的事件。event_valid 有效期间 s_ready 会被拉低，
    // 因此最多只有一个事件处于 pending。
    logic        event_valid_q;
    logic [31:0] event_data_q;
    logic        event_source_q;

    logic        frame_done_q;
    logic        parse_error_q;

    // ------------------------------------------------------------------
    // 组合逻辑的下一状态值
    // ------------------------------------------------------------------
    logic [1:0]  n_state;
    logic        n_in_sysex;
    logic        n_pending;
    logic [1:0]  n_data_idx;
    logic [7:0]  n_status_cur;
    logic [7:0]  n_running;
    logic [1:0]  n_sys_skip;
    logic [6:0]  n_byte_count;
    logic [7:0]  n_data1;
    logic [6:0]  n_frame_len;
    logic        n_frame_source;
    logic        n_frame_bad;
    logic        n_event_valid;
    logic [31:0] n_event_data;
    logic        n_event_source;
    logic        n_frame_done;
    logic        n_parse_error;

    logic        is_rt;
    logic        is_sys;
    logic        is_chan;
    logic        is_data;
    logic        ev_gen;
    logic [32:0] ev_word;
    logic        accept;

    // ------------------------------------------------------------------
    // 辅助函数
    // ------------------------------------------------------------------
    function automatic logic one_data_status(input logic [7:0] st);
        one_data_status = (st[7:4] == 4'hC) || (st[7:4] == 4'hD);
    endfunction

    // 返回 {valid, kind[3:0], channel[3:0], data1[6:0], data2[6:0], 10'b0}。
    // A/D（通道压力/复音压力）消息和未支持的 CC 会正常消费，但不产生事件。
    function automatic logic [32:0] build_event(
        input logic [7:0] st,
        input logic [6:0] d1,
        input logic [6:0] d2
    );
        logic        ok;
        logic [3:0]  kind;
        logic [6:0]  e1;
        logic [6:0]  e2;
        begin
            ok   = 1'b1;
            kind = KIND_NOTE_OFF;
            e1   = d1;
            e2   = d2;

            case (st[7:4])
                4'h8: begin
                    kind = KIND_NOTE_OFF;
                end
                4'h9: begin
                    if (d2 == 7'd0) begin
                        kind = KIND_NOTE_OFF;
                        e2   = 7'd0;
                    end else begin
                        kind = KIND_NOTE_ON;
                    end
                end
                4'hA: begin
                    ok = 1'b0;
                end
                4'hB: begin
                    if ((d1 == 7'd1)  || (d1 == 7'd7) ||
                        (d1 == 7'd11) || (d1 == 7'd64)) begin
                        kind = KIND_CONTROL_CHANGE;
                    end else if (((d1 == 7'd120) || (d1 == 7'd123)) &&
                                 (d2 == 7'd0)) begin
                        kind = KIND_CONTROL_CHANGE;
                    end else begin
                        ok = 1'b0;
                    end
                end
                4'hC: begin
                    kind = KIND_PROGRAM;
                    e2   = 7'd0;
                end
                4'hD: begin
                    ok = 1'b0;
                end
                4'hE: begin
                    kind = KIND_PITCH_BEND;
                end
                default: begin
                    ok = 1'b0;
                end
            endcase

            build_event = {ok, kind, st[3:0], e1, e2, 10'b0};
        end
    endfunction

    // ------------------------------------------------------------------
    // 握手与输出
    // ------------------------------------------------------------------
    assign accept = s_valid && s_ready;

    assign s_ready = rst_n && !flush &&
                     (state != ST_TAIL) &&
                     !frame_done_q && !event_valid_q;

    assign event_valid     = rst_n && !flush && event_valid_q;
    assign event_data      = event_data_q;
    assign event_source_id = event_source_q;

    assign frame_done      = rst_n && !flush && frame_done_q;
    assign parse_error     = rst_n && !flush && parse_error_q;

    // busy 会一直保持到 frame_done 脉冲结束，避免在尾部退休的同一拍
    // 又放行新的 first 字节。
    assign busy = rst_n && !flush &&
                  ((state != ST_IDLE) || frame_done_q);

    // ------------------------------------------------------------------
    // 下一状态 / 解析逻辑
    // ------------------------------------------------------------------
    always @* begin
        n_state        = state;
        n_in_sysex     = in_sysex;
        n_pending      = pending;
        n_data_idx     = data_idx;
        n_status_cur   = status_cur;
        n_running      = running;
        n_sys_skip     = sys_skip;
        n_byte_count   = byte_count;
        n_data1        = data1;
        n_frame_len    = frame_len;
        n_frame_source = frame_source;
        n_frame_bad    = frame_bad;
        n_event_valid  = event_valid_q && !event_ready;
        n_event_data   = event_data_q;
        n_event_source = event_source_q;
        n_frame_done   = 1'b0;
        n_parse_error  = 1'b0;
        ev_gen         = 1'b0;
        ev_word        = 33'd0;

        is_rt   = (s_data >= 8'hF8);
        is_sys  = (s_data >= 8'hF0) && (s_data <= 8'hF7);
        is_chan = (s_data >= 8'h80) && (s_data <= 8'hEF);
        is_data = (s_data <  8'h80);

        if (state == ST_IDLE) begin
            if (accept) begin
                if (!s_first) begin
                    // 没有放行任何帧；丢弃该字节并保持空闲。
                    n_parse_error = 1'b1;
                end else begin
                    n_state        = ST_ACTIVE;
                    n_frame_source = s_source_id;
                    n_frame_len    = s_payload_len;
                    n_byte_count   = 7'd1;
                    n_frame_bad    = 1'b0;
                    n_in_sysex     = 1'b0;
                    n_pending      = 1'b0;
                    n_data_idx     = 2'd0;
                    n_status_cur   = 8'd0;
                    n_running      = 8'd0;
                    n_sys_skip     = 2'd0;
                    n_data1        = 8'd0;

                    if ((s_payload_len == 7'd0) || (s_payload_len > 7'd64)) begin
                        // 声明的长度非法：只消费字节、不尝试解析，保证不越界。
                        n_frame_bad   = 1'b1;
                        n_parse_error = 1'b1;
                    end else begin
                        // 在刚复位的上下文里处理第一个字节。
                        if (is_rt) begin
                            // 实时消息：忽略，不改变解析器状态。
                        end else if (is_sys) begin
                            n_running  = 8'd0;
                            n_in_sysex = (s_data == 8'hF0);
                            case (s_data)
                                8'hF1, 8'hF3: n_sys_skip = 2'd1;
                                8'hF2:        n_sys_skip = 2'd2;
                                default:      n_sys_skip = 2'd0;
                            endcase
                        end else if (is_chan) begin
                            n_pending    = 1'b1;
                            n_data_idx   = 2'd0;
                            n_status_cur = s_data;
                            n_running    = s_data;
                        end else begin
                            // 没有 running status 的数据字节：孤立字节。
                            n_parse_error = 1'b1;
                        end
                    end

                    if (s_last) begin
                        n_state = ST_TAIL;
                        if ((s_payload_len >= 7'd1) &&
                            (s_payload_len <= 7'd64) &&
                            (n_byte_count != n_frame_len)) begin
                            n_parse_error = 1'b1;
                        end
                        if (n_in_sysex)       n_parse_error = 1'b1;
                        if (n_pending)        n_parse_error = 1'b1;
                        if (n_sys_skip != 0)  n_parse_error = 1'b1;

                        // 局部解析状态绝不跨越帧边界。
                        n_in_sysex   = 1'b0;
                        n_pending    = 1'b0;
                        n_data_idx   = 2'd0;
                        n_status_cur = 8'd0;
                        n_running    = 8'd0;
                        n_sys_skip   = 2'd0;
                        n_data1      = 8'd0;
                    end
                end
            end
        end else if (state == ST_ACTIVE) begin
            if (accept) begin
                if (s_first) begin
                    // 尾部退休前不能放行新帧；标记错误，并继续解析已放行的帧。
                    n_parse_error = 1'b1;
                end

                if (byte_count != 7'd127) begin
                    n_byte_count = byte_count + 7'd1;
                end else begin
                    // 畸形帧导致计数失控时饱和而不是回绕；frame_bad=1 后解析已经停止。
                    n_byte_count = byte_count;
                end

                if (!frame_bad && (byte_count < frame_len)) begin
                    if (is_rt) begin
                        // F8..FF 优先级最高，保持 pending、running status 和 SysEx 跳过状态。
                    end else if (is_sys) begin
                        if (n_pending || (n_sys_skip != 2'd0)) begin
                            n_parse_error = 1'b1;
                        end
                        n_pending    = 1'b0;
                        n_data_idx   = 2'd0;
                        n_status_cur = 8'd0;
                        n_running    = 8'd0;
                        n_sys_skip   = 2'd0;
                        n_in_sysex   = (s_data == 8'hF0);
                        case (s_data)
                            8'hF1, 8'hF3: n_sys_skip = 2'd1;
                            8'hF2:        n_sys_skip = 2'd2;
                            default:      n_sys_skip = 2'd0;
                        endcase
                    end else if (is_chan) begin
                        if (n_pending || (n_sys_skip != 2'd0)) begin
                            n_parse_error = 1'b1;
                        end
                        n_in_sysex   = 1'b0;
                        n_pending    = 1'b1;
                        n_data_idx   = 2'd0;
                        n_status_cur = s_data;
                        n_running    = s_data;
                        n_sys_skip   = 2'd0;
                    end else begin
                        // 数据字节
                        if (n_in_sysex) begin
                            // SysEx 负载：直接跳过，不产生任何事件。
                        end else if (n_sys_skip != 2'd0) begin
                            n_sys_skip = n_sys_skip - 2'd1;
                        end else if (n_pending) begin
                            if ((n_data_idx == 2'd0) &&
                                !one_data_status(n_status_cur)) begin
                                n_data1   = s_data;
                                n_data_idx = 2'd1;
                            end else begin
                                if (n_data_idx == 2'd1) begin
                                    ev_word = build_event(n_status_cur,
                                                          n_data1[6:0],
                                                          s_data[6:0]);
                                end else begin
                                    ev_word = build_event(n_status_cur,
                                                          s_data[6:0],
                                                          7'd0);
                                end
                                if (ev_word[32]) ev_gen = 1'b1;
                                n_pending  = 1'b0;
                                n_data_idx = 2'd0;
                            end
                        end else if (n_running != 8'd0) begin
                            if (one_data_status(n_running)) begin
                                ev_word = build_event(n_running,
                                                      s_data[6:0], 7'd0);
                                if (ev_word[32]) ev_gen = 1'b1;
                            end else begin
                                n_pending    = 1'b1;
                                n_status_cur = n_running;
                                n_data_idx   = 2'd1;
                                n_data1      = s_data;
                            end
                        end else begin
                            // 既没有 pending 也没有 running status 的数据字节。
                            n_parse_error = 1'b1;
                        end
                    end
                end else if (!frame_bad) begin
                    // 字节数超过声明长度：停止解析，但仍安全消费到真正的 last 字节。
                    n_frame_bad   = 1'b1;
                    n_parse_error = 1'b1;
                end

                if (ev_gen) begin
                    n_event_valid  = 1'b1;
                    n_event_data   = ev_word[31:0];
                    n_event_source = n_frame_source;
                end

                if (s_last) begin
                    n_state = ST_TAIL;
                    if ((n_frame_len >= 7'd1) &&
                        (n_frame_len <= 7'd64) &&
                        (n_byte_count != n_frame_len)) begin
                        n_parse_error = 1'b1;
                    end
                    if (n_in_sysex)       n_parse_error = 1'b1;
                    if (n_pending)        n_parse_error = 1'b1;
                    if (n_sys_skip != 0)  n_parse_error = 1'b1;

                    n_in_sysex   = 1'b0;
                    n_pending    = 1'b0;
                    n_data_idx   = 2'd0;
                    n_status_cur = 8'd0;
                    n_running    = 8'd0;
                    n_sys_skip   = 2'd0;
                    n_data1      = 8'd0;
                end
            end
        end else begin
            // ST_TAIL：等待最后一个已接收事件（如有）退休，
            // 然后只产生一拍 frame_done。
            if (!event_valid_q || event_ready) begin
                n_state      = ST_IDLE;
                n_frame_done = 1'b1;
                n_in_sysex   = 1'b0;
                n_pending    = 1'b0;
                n_data_idx   = 2'd0;
                n_status_cur = 8'd0;
                n_running    = 8'd0;
                n_sys_skip   = 2'd0;
                n_data1      = 8'd0;
            end
        end
    end

    // ------------------------------------------------------------------
    // 寄存器
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= ST_IDLE;
            in_sysex       <= 1'b0;
            pending        <= 1'b0;
            data_idx       <= 2'd0;
            status_cur     <= 8'd0;
            running        <= 8'd0;
            sys_skip       <= 2'd0;
            byte_count     <= 7'd0;
            frame_len      <= 7'd0;
            frame_source   <= 1'b0;
            frame_bad      <= 1'b0;
            data1          <= 8'd0;
            event_valid_q  <= 1'b0;
            event_data_q   <= 32'd0;
            event_source_q <= 1'b0;
            frame_done_q   <= 1'b0;
            parse_error_q  <= 1'b0;
        end else if (flush) begin
            // 维护中止：丢弃当前帧、任何未拼装完的消息和任何尚未交付的输出事件。
            // 已经交付出去的事件不回滚。
            state          <= ST_IDLE;
            in_sysex       <= 1'b0;
            pending        <= 1'b0;
            data_idx       <= 2'd0;
            status_cur     <= 8'd0;
            running        <= 8'd0;
            sys_skip       <= 2'd0;
            byte_count     <= 7'd0;
            frame_len      <= 7'd0;
            frame_source   <= 1'b0;
            frame_bad      <= 1'b0;
            data1          <= 8'd0;
            event_valid_q  <= 1'b0;
            event_data_q   <= 32'd0;
            event_source_q <= 1'b0;
            frame_done_q   <= 1'b0;
            parse_error_q  <= 1'b0;
        end else begin
            state          <= n_state;
            in_sysex       <= n_in_sysex;
            pending        <= n_pending;
            data_idx       <= n_data_idx;
            status_cur     <= n_status_cur;
            running        <= n_running;
            sys_skip       <= n_sys_skip;
            byte_count     <= n_byte_count;
            frame_len      <= n_frame_len;
            frame_source   <= n_frame_source;
            frame_bad      <= n_frame_bad;
            data1          <= n_data1;
            event_valid_q  <= n_event_valid;
            event_data_q   <= n_event_data;
            event_source_q <= n_event_source;
            frame_done_q   <= n_frame_done;
            parse_error_q  <= n_parse_error;
        end
    end

endmodule
