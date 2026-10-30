`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// slip_frame_rx -- SLIP 分帧 + CRC-16/CCITT-FALSE 校验后的帧存储。
//
// 候选帧逐字节解码（转义处理与 CRC 更新），payload 字节直接写入小型
// payload RAM 中预留的槽位；只有结束 C0、长度、版本/类型、CRC 全部通过后，
// 该槽位才作为已提交帧描述符发布。没有整帧暂存缓冲，也没有 memcpy。
//
// 存储是一个 FRAME_DEPTH+1 个 payload 槽位的环（FRAME_DEPTH 个已提交槽位
// 加一个推测写槽位）。已提交槽位通过同步 RAM 加保持输出寄存器读出，
// 因此 m_* 在 m_ready 为低时保持稳定。允许读气泡。
//
// flush 是同步维护中止：
//   pin=0 -> 中止候选帧，丢弃保持输出和所有已提交帧；
//   pin=1 -> 中止候选帧，只保留当前队头（包括已保持的输出字节/元数据）
//            到它最后一次传输完成，其余全部丢弃。
// -----------------------------------------------------------------------------
module slip_frame_rx #(
    parameter int FRAME_DEPTH    = 8,
    parameter int TIMEOUT_CYCLES = 100000000
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        flush,
    input  logic        pin,

    input  logic        s_valid,
    output logic        s_ready,
    input  logic [7:0]  s_data,

    output logic        m_valid,
    input  logic        m_ready,
    output logic [7:0]  m_data,
    output logic        m_first,
    output logic        m_last,
    output logic [7:0]  m_type,
    output logic [15:0] m_seq,
    output logic [5:0]  m_payload_len,
    output logic        frame_available,

    output logic [7:0]  err_flags
);

    import comm_pkg::*;

    localparam int RING_SIZE  = FRAME_DEPTH + 1;
    localparam int PTR_W      = (RING_SIZE <= 2) ? 1 : $clog2(RING_SIZE);
    localparam int CNT_W      = (RING_SIZE <= 2) ? 1 : $clog2(RING_SIZE);
    localparam int SLOT_BYTES = 32;
    localparam int RAM_WORDS  = RING_SIZE * SLOT_BYTES;
    localparam int ADDR_W     = (RAM_WORDS <= 2) ? 1 : $clog2(RAM_WORDS);
    localparam int TMR_W      = (TIMEOUT_CYCLES <= 2) ? 1 : $clog2(TIMEOUT_CYCLES);

    localparam logic [7:0] SLIP_END  = 8'hC0;
    localparam logic [7:0] SLIP_ESC  = 8'hDB;
    localparam logic [7:0] SLIP_ESC_END = 8'hDC;
    localparam logic [7:0] SLIP_ESC_ESC = 8'hDD;

    localparam logic [7:0] ERR_SLIP   = 8'h01;
    localparam logic [7:0] ERR_LEN    = 8'h02;
    localparam logic [7:0] ERR_CRC    = 8'h04;
    localparam logic [7:0] ERR_VER    = 8'h08;
    localparam logic [7:0] ERR_TIMEOUT= 8'h10;

    typedef enum logic [1:0] {
        S_HUNT,     // 还没见到 C0，忽略垃圾字节
        S_START,    // 已见到 C0，等待一个空闲 payload 槽位
        S_DECODE,   // 候选帧进行中；payload 槽位就是当前 tail
        S_DISCARD   // 丢弃到下一个未转义的 C0
    } rx_state_t;

    rx_state_t state;

    // 已提交帧环。head 指向最旧的已提交帧，tail 指向空闲的推测写槽位。
    // count 范围为 0..FRAME_DEPTH。
    logic [PTR_W-1:0] head;
    logic [PTR_W-1:0] tail;
    logic [CNT_W-1:0] count;

    // payload RAM（一个写口、一个同步读口）与每槽元数据。
    // 元数据很小，可以放在寄存器里。
    logic [7:0]  payload_ram [0:RAM_WORDS-1];
    logic [7:0]  meta_type [0:FRAME_DEPTH];
    logic [15:0] meta_seq  [0:FRAME_DEPTH];
    logic [5:0]  meta_len  [0:FRAME_DEPTH];

    // 候选帧解码状态。
    // header + 最大 payload + CRC 最多 40 个解码字节。要在计数器回绕前拒绝；
    // 不要为此综合一个 32-bit 的畸形帧计时器。
    logic [5:0] body_count;
    logic [15:0] crc_r;
    logic [7:0]  cand_type;
    logic [15:0] cand_seq;
    logic [15:0] cand_len;
    logic        esc_pending;
    logic        invalid_len;
    logic [7:0]  err_accum;       // 每帧累计的版本/类型诊断
    logic [7:0]  rx_crc_lo;
    logic [7:0]  rx_crc_hi;
    logic [TMR_W-1:0] timeout_cnt;

    // 输出保持寄存器。这是帧流对外可见的全部状态。
    logic        held_valid;
    logic [7:0]  held_data;
    logic [4:0]  held_off;
    logic [7:0]  held_type;
    logic [15:0] held_seq;
    logic [5:0]  held_len;
    logic        held_first;
    logic        held_last;

    // 同步 payload RAM 读流水 / 预取。
    logic [4:0]       next_off;
    logic             rd_capture;
    logic             ram_re;
    logic [ADDR_W-1:0] rd_addr;
    logic [7:0]       ram_q;

    wire         in_fire   = s_valid && s_ready;
    wire         pop_any   = held_valid && m_ready;
    wire         pop_last  = pop_any && held_last;
    wire         frame_end = (state == S_DECODE) && in_fire &&
                             !esc_pending && (s_data == SLIP_END);
    wire         esc_db_c0 = (state == S_DECODE) && in_fire && esc_pending &&
                             (s_data == SLIP_END);

    assign m_valid         = held_valid;
    assign m_data          = held_data;
    assign m_first         = held_first;
    assign m_last          = held_last;
    assign m_type          = held_type;
    assign m_seq           = held_seq;
    assign m_payload_len   = held_len;
    assign frame_available = (count != 0);

    // 维护 flush 有效期间、或等待已提交槽位释放（S_START）期间，
    // 不接收新字节。
    assign s_ready = rst_n && !flush && (state != S_START);

    function automatic logic [PTR_W-1:0] ptr_next(input logic [PTR_W-1:0] p);
        ptr_next = (p == FRAME_DEPTH) ? {PTR_W{1'b0}} : (p + 1'b1);
    endfunction

    // 当输出寄存器为空且存在已提交帧时，发起一次预取读。
    // next_off 标识下一个 payload 字节。
    always_comb begin
        ram_re = !flush && !held_valid && !rd_capture && (count != 0);
        rd_addr = {head, next_off};
    end

    always_ff @(posedge clk) begin
        if (ram_re)
            ram_q <= payload_ram[rd_addr];
    end

    // 独立的简单写口（RAM 数组不复位）。payload 字节在解码当拍写入，
    // 早于任何可能让该帧可见的提交。
    wire         take_decoded = (state == S_DECODE) && in_fire && !flush &&
                                (esc_pending ? ((s_data == SLIP_ESC_END) ||
                                                (s_data == SLIP_ESC_ESC))
                                             : ((s_data != SLIP_ESC) &&
                                                (s_data != SLIP_END)));
    wire         payload_wr = take_decoded && !invalid_len &&
                               (body_count >= 6'd6) &&
                               (body_count < (6'd6 + cand_len[5:0])) &&
                               ((body_count - 6'd6) < 32);
    wire [4:0] payload_wr_offset = body_count[4:0] - 5'd6;
    wire [ADDR_W-1:0] payload_wr_addr = {tail, payload_wr_offset};
    wire [7:0]   payload_wr_data = decoded_byte(s_data, esc_pending);

    always_ff @(posedge clk) begin
        if (payload_wr)
            payload_ram[payload_wr_addr] <= payload_wr_data;
    end

    always_ff @(posedge clk or negedge rst_n) begin : rx_seq
        logic        commit_now;
        logic [7:0]  ev;

        if (!rst_n) begin
            state        <= S_HUNT;
            head         <= '0;
            tail         <= '0;
            count        <= '0;
            body_count   <= 6'd0;
            crc_r        <= 16'hFFFF;
            cand_type    <= 8'h00;
            cand_seq     <= 16'h0000;
            cand_len     <= 16'h0000;
            esc_pending  <= 1'b0;
            invalid_len  <= 1'b0;
            err_accum    <= 8'h00;
            rx_crc_lo    <= 8'h00;
            rx_crc_hi    <= 8'h00;
            timeout_cnt  <= '0;
            held_valid   <= 1'b0;
            held_data    <= 8'h00;
            held_off     <= 5'd0;
            held_type    <= 8'h00;
            held_seq     <= 16'h0000;
            held_len     <= 6'd0;
            held_first   <= 1'b0;
            held_last    <= 1'b0;
            next_off     <= 5'd0;
            rd_capture   <= 1'b0;
            err_flags    <= 8'h00;
        end else begin
            err_flags  <= 8'h00;
            commit_now  = 1'b0;
            ev          = 8'h00;

            if (flush) begin
                // 候选帧总是被放弃。推测写槽位就是当前 tail，
                // 因此不需要任何拷贝就能释放。
                state       <= S_HUNT;
                body_count  <= 6'd0;
                esc_pending <= 1'b0;
                invalid_len <= 1'b0;
                err_accum   <= 8'h00;
                timeout_cnt <= '0;
                rd_capture  <= 1'b0;

                if (pin) begin
                    if (pop_any) begin
                        held_valid <= 1'b0;
                        if (held_last) begin
                            // 被 pin 的队头已经完整传输完：其余帧也全部丢弃。
                            count   <= '0;
                            head    <= tail;
                            next_off<= 5'd0;
                        end else begin
                            // 同一队头继续传输；它后面的帧全部消失。
                            count   <= 1'b1;
                            tail    <= ptr_next(head);
                            next_off<= held_off + 5'd1;
                        end
                    end else if (count != 0) begin
                        count   <= 1'b1;
                        tail    <= ptr_next(head);
                    end else begin
                        count    <= '0;
                        held_valid <= 1'b0;
                        next_off <= 5'd0;
                    end
                end else begin
                    count      <= '0;
                    head       <= tail;
                    held_valid <= 1'b0;
                    next_off   <= 5'd0;
                end
            end else begin
                rd_capture <= ram_re;

                // -----------------------------------------------------------------
                // 输入分帧状态机
                // -----------------------------------------------------------------
                if (in_fire) begin
                    case (state)
                        S_HUNT: begin
                            if (s_data == SLIP_END)
                                state <= S_START;
                        end

                        S_DECODE: begin
                            timeout_cnt <= '0;
                            if (!esc_pending && (s_data == SLIP_ESC)) begin
                                esc_pending <= 1'b1;
                            end else if (frame_end) begin
                                // 没有待处理转义的结束 C0。
                                if (body_count == 0) begin
                                    // 空帧/连续 C0 是合法的，静默忽略。
                                    state      <= S_START;
                                    body_count <= 6'd0;
                                    timeout_cnt<= '0;
                                end else begin
                                    ev = err_accum;
                                    if (invalid_len)
                                        ev[1] = 1'b1;
                                    else if (body_count != (6'd8 + cand_len[5:0]))
                                        ev[1] = 1'b1;

                                    if (!ev[1]) begin
                                        if ({rx_crc_hi, rx_crc_lo} != crc_r)
                                            ev[2] = 1'b1;
                                    end

                                    if (ev == 8'h00) begin
                                        meta_type[tail] <= cand_type;
                                        meta_seq[tail]  <= cand_seq;
                                        meta_len[tail]  <= cand_len[5:0];
                                        commit_now = 1'b1;
                                    end else begin
                                        err_flags <= ev;
                                    end

                                    state      <= S_START;
                                    body_count <= 6'd0;
                                    esc_pending<= 1'b0;
                                    invalid_len<= 1'b0;
                                    err_accum  <= 8'h00;
                                    timeout_cnt<= '0;
                                end
                            end else if (esc_db_c0) begin
                                // DB C0 不是合法的数据转义。这个 C0 仍然是帧边界；
                                // 报错并在这里重新同步（它同时充当下一帧的起始定界符）。
                                err_flags  <= (err_accum | ERR_SLIP);
                                state      <= S_START;
                                body_count <= 6'd0;
                                esc_pending<= 1'b0;
                                invalid_len<= 1'b0;
                                err_accum  <= 8'h00;
                                timeout_cnt<= '0;
                            end else if (esc_pending &&
                                         (s_data != SLIP_ESC_END) &&
                                         (s_data != SLIP_ESC_ESC)) begin
                                // 其他非法 DB xx：终止候选帧，
                                // 吞掉字节直到下一个未转义的 C0。
                                err_flags  <= (err_accum | ERR_SLIP);
                                state      <= S_DISCARD;
                                body_count <= 6'd0;
                                esc_pending<= 1'b0;
                                invalid_len<= 1'b0;
                                err_accum  <= 8'h00;
                                timeout_cnt<= '0;
                            end else begin
                                // 一个解码后的 body 字节（原始字节，或 DB DC / DB DD）。
                                // 每个未转义字节只更新一次 CRC，并把 payload 字节直接写入槽位。
                                if (body_count < 6'd6) begin
                                    case (body_count)
                                        6'd0: begin
                                            if (decoded_byte(s_data, esc_pending) != 8'h01) begin
                                                err_flags <= ERR_VER;
                                                state <= S_DISCARD;
                                            end
                                        end
                                        6'd1: begin
                                            cand_type <= decoded_byte(s_data, esc_pending);
                                            if ((decoded_byte(s_data, esc_pending) != TYPE_MIDI) &&
                                                (decoded_byte(s_data, esc_pending) != TYPE_CONFIG)) begin
                                                err_flags <= ERR_VER;
                                                state <= S_DISCARD;
                                            end
                                        end
                                        6'd2: cand_seq[7:0]  <= decoded_byte(s_data, esc_pending);
                                        6'd3: cand_seq[15:8] <= decoded_byte(s_data, esc_pending);
                                        6'd4: cand_len[7:0]  <= decoded_byte(s_data, esc_pending);
                                        6'd5: begin
                                            cand_len[15:8] <= decoded_byte(s_data, esc_pending);
                                            if (cand_type == TYPE_MIDI) begin
                                                if (({decoded_byte(s_data, esc_pending), cand_len[7:0]} == 16'd0) ||
                                                    ({decoded_byte(s_data, esc_pending), cand_len[7:0]} > 16'd32)) begin
                                                    invalid_len <= 1'b1;
                                                    err_flags <= ERR_LEN;
                                                    state <= S_DISCARD;
                                                end
                                            end else if (cand_type == TYPE_CONFIG) begin
                                                if (({decoded_byte(s_data, esc_pending), cand_len[7:0]} == 16'd0) ||
                                                    ({decoded_byte(s_data, esc_pending), cand_len[7:0]} > 16'd16)) begin
                                                    invalid_len <= 1'b1;
                                                    err_flags <= ERR_LEN;
                                                    state <= S_DISCARD;
                                                end
                                            end
                                        end
                                        default: ;
                                    endcase
                                    crc_r <= crc16_byte(crc_r, decoded_byte(s_data, esc_pending));
                                end else if (body_count < (6'd6 + cand_len[5:0])) begin
                                    crc_r <= crc16_byte(crc_r, decoded_byte(s_data, esc_pending));
                                end else if (body_count == (6'd6 + cand_len[5:0])) begin
                                    rx_crc_lo <= decoded_byte(s_data, esc_pending);
                                end else if (body_count == (6'd7 + cand_len[5:0])) begin
                                    rx_crc_hi <= decoded_byte(s_data, esc_pending);
                                end else begin
                                    // 任何多余的解码字节都会立即使整个候选帧失效（不让计数器回绕）。
                                    err_flags <= ERR_LEN;
                                    state <= S_DISCARD;
                                end

                                if (esc_pending)
                                    esc_pending <= 1'b0;
                                body_count <= body_count + 6'd1;
                            end
                        end

                        S_DISCARD: begin
                            if (s_data == SLIP_END)
                                state <= S_START;
                        end

                        S_START: ; // 这里不会发生 in_fire（s_ready=0）
                    endcase
                end else begin
                    if (state == S_START) begin
                        if (count < FRAME_DEPTH) begin
                            // 在 tail 处隐含预留空闲槽位，并开始新的候选帧。
                            // 本拍不消费任何字节。
                            state       <= S_DECODE;
                            body_count  <= 6'd0;
                            crc_r       <= 16'hFFFF;
                            cand_type   <= 8'h00;
                            cand_seq    <= 16'h0000;
                            cand_len    <= 16'h0000;
                            esc_pending <= 1'b0;
                            invalid_len <= 1'b0;
                            err_accum   <= 8'h00;
                            rx_crc_lo   <= 8'h00;
                            rx_crc_hi   <= 8'h00;
                            timeout_cnt <= '0;
                        end
                    end else if ((state == S_DECODE) &&
                                 ((body_count != 0) || esc_pending)) begin
                        // 字节间超时：只针对确实在等线上字节的非空候选帧。
                        // 孤立的 DB（转义待处理）已经算半个线上帧。
                        // 队列让我们停顿（S_START）时不计时；空闲/空链路也不计时。
                        if (timeout_cnt >= (TIMEOUT_CYCLES - 1)) begin
                            err_flags   <= (err_accum | ERR_TIMEOUT);
                            state       <= S_DISCARD;
                            body_count  <= 6'd0;
                            esc_pending <= 1'b0;
                            invalid_len <= 1'b0;
                            err_accum   <= 8'h00;
                            timeout_cnt <= '0;
                        end else begin
                            timeout_cnt <= timeout_cnt + 1'b1;
                        end
                    end
                end

                // -----------------------------------------------------------------
                // 输出保持寄存器捕获 / 弹出
                // -----------------------------------------------------------------
                if (rd_capture) begin
                    held_valid <= 1'b1;
                    held_data  <= ram_q;
                    held_off   <= next_off;
                    held_type  <= meta_type[head];
                    held_seq   <= meta_seq[head];
                    held_len   <= meta_len[head];
                    held_first <= (next_off == 5'd0);
                    held_last  <= (next_off == (meta_len[head] - 6'd1));
                end

                if (pop_any) begin
                    held_valid <= 1'b0;
                    if (held_last) begin
                        head     <= ptr_next(head);
                        next_off <= 5'd0;
                    end else begin
                        next_off <= held_off + 5'd1;
                    end
                end

                // -----------------------------------------------------------------
                // 提交 / 计数维护（提交与弹出可能同拍发生）
                // -----------------------------------------------------------------
                if (commit_now) begin
                    tail <= ptr_next(tail);
                    if (count == 0)
                        next_off <= 5'd0;
                end

                case ({pop_last, commit_now})
                    2'b10: count <= count - 1'b1;
                    2'b01: count <= count + 1'b1;
                    default: count <= count;
                endcase
            end
        end
    end

    // SLIP 反转义后解码一个 body 字节。esc_pending 表示上一个线上字节是 DB，
    // 因此只有 DC/DD 会进入解码字节路径。
    function automatic logic [7:0] decoded_byte(
        input logic [7:0] raw,
        input logic       esc
    );
        if (!esc)
            decoded_byte = raw;
        else if (raw == SLIP_ESC_END)
            decoded_byte = SLIP_END;
        else
            decoded_byte = SLIP_ESC;
    endfunction

endmodule
