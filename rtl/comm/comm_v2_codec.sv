`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// comm_v2_codec -- 蓝牙会话协议 v2 的通用帧编解码器。
//
// 线上 body: VERSION=02 | TYPE | SEQ:u16LE | LEN:u16LE | SESSION:u32LE |
//             PAYLOAD[LEN] | CRC:u16LE
//
// RX 独立维护 CONTROL 与业务（MIDI/CONFIG）两个已验证帧队列。字节分帧与
// 候选帧解码不等待任一队列，因此业务队列满时控制帧仍可继续入队。队列满时
// 丢弃整帧并脉冲 errors[5]（已验证帧队列 overflow），不静默丢帧。
//
// TX 接受完整帧描述符，按 SLIP 规则逐字节输出；payload byte0 位于 [7:0]。
// valid/ready 为普通同步握手，tx_valid 在 tx_ready 为低时保持字节稳定。
//
// errors 为单拍脉冲，布局沿用 v1：
//   [0] SLIP 转义错误  [1] 长度错误  [2] CRC 错误  [3] 版本/类型错误
//   [4] 半帧字节间超时 [5] 已验证帧队列 overflow
// -----------------------------------------------------------------------------
module comm_v2_codec #(
    parameter int FRAME_DEPTH    = 8,
    parameter int CONTROL_DEPTH  = 4,
    parameter int TIMEOUT_CYCLES = 100000000
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        flush,

    // -------------------------------------------------------------------------
    // Raw UART byte stream (RX)
    // -------------------------------------------------------------------------
    input  logic        rx_valid,
    output logic        rx_ready,
    input  logic [7:0]  rx_data,

    // Verified CONTROL frames
    output logic        ctrl_valid,
    input  logic        ctrl_ready,
    output logic [15:0] ctrl_seq,
    output logic [31:0] ctrl_session,
    output logic [5:0]  ctrl_len,
    output logic [255:0] ctrl_payload,

    // Verified business frames (MIDI / CONFIG)
    output logic        biz_valid,
    input  logic        biz_ready,
    output logic [7:0]  biz_type,
    output logic [15:0] biz_seq,
    output logic [31:0] biz_session,
    output logic [5:0]  biz_len,
    output logic [255:0] biz_payload,

    output logic [7:0]  errors,

    // -------------------------------------------------------------------------
    // Full frame descriptor (TX)
    // -------------------------------------------------------------------------
    input  logic        send_valid,
    output logic        send_ready,
    input  logic [7:0]  send_type,
    input  logic [15:0] send_seq,
    input  logic [31:0] send_session,
    input  logic [5:0]  send_len,
    input  logic [255:0] send_payload,

    output logic        tx_valid,
    input  logic        tx_ready,
    output logic [7:0]  tx_data
);

    import comm_pkg::*;

    localparam logic [7:0] SLIP_END     = 8'hC0;
    localparam logic [7:0] SLIP_ESC     = 8'hDB;
    localparam logic [7:0] SLIP_ESC_END = 8'hDC;
    localparam logic [7:0] SLIP_ESC_ESC = 8'hDD;

    localparam logic [7:0] WIRE_VERSION = 8'h02;
    localparam logic [7:0] TYPE_CONTROL = 8'h03;

    localparam logic [7:0] ERR_SLIP    = 8'h01;
    localparam logic [7:0] ERR_LEN     = 8'h02;
    localparam logic [7:0] ERR_CRC     = 8'h04;
    localparam logic [7:0] ERR_VER     = 8'h08;
    localparam logic [7:0] ERR_TIMEOUT = 8'h10;
    localparam logic [7:0] ERR_OVF     = 8'h20;

    localparam int CTRL_PTR_W = (CONTROL_DEPTH <= 2) ? 1 : $clog2(CONTROL_DEPTH);
    localparam int CTRL_CNT_W = (CONTROL_DEPTH <= 1) ? 1 : $clog2(CONTROL_DEPTH + 1);
    localparam int BIZ_PTR_W  = (FRAME_DEPTH <= 2) ? 1 : $clog2(FRAME_DEPTH);
    localparam int BIZ_CNT_W  = (FRAME_DEPTH <= 1) ? 1 : $clog2(FRAME_DEPTH + 1);
    localparam int TMR_W      = (TIMEOUT_CYCLES <= 2) ? 1 : $clog2(TIMEOUT_CYCLES);

    typedef enum logic [1:0] {
        S_HUNT,     // 首次等待前导 C0
        S_DECODE,   // 解码 body；body_count==0 时可直接开始（共享 C0）
        S_DISCARD   // 丢弃到下一个未转义 C0
    } rx_state_t;

    rx_state_t state;

    // -------------------------------------------------------------------------
    // RX 候选帧
    // -------------------------------------------------------------------------
    logic [5:0]   body_count;
    logic [15:0]  crc_calc;
    logic [7:0]   crc_lo;
    logic [7:0]   crc_hi;
    logic [7:0]   cand_type;
    logic [15:0]  cand_seq;
    logic [15:0]  cand_len;
    logic [31:0]  cand_session;
    logic [255:0] cand_payload;
    logic         esc_pending;
    logic [TMR_W-1:0] timeout_cnt;

    // -------------------------------------------------------------------------
    // 独立队列
    // -------------------------------------------------------------------------
    logic [255:0] ctrl_mem       [0:CONTROL_DEPTH-1];
    logic [15:0]  ctrl_seq_mem   [0:CONTROL_DEPTH-1];
    logic [31:0]  ctrl_sess_mem  [0:CONTROL_DEPTH-1];
    logic [5:0]   ctrl_len_mem   [0:CONTROL_DEPTH-1];
    logic [CTRL_PTR_W-1:0] ctrl_wr, ctrl_rd;
    logic [CTRL_CNT_W-1:0] ctrl_count;

    logic [255:0] biz_mem        [0:FRAME_DEPTH-1];
    logic [7:0]   biz_type_mem   [0:FRAME_DEPTH-1];
    logic [15:0]  biz_seq_mem    [0:FRAME_DEPTH-1];
    logic [31:0]  biz_sess_mem   [0:FRAME_DEPTH-1];
    logic [5:0]   biz_len_mem    [0:FRAME_DEPTH-1];
    logic [BIZ_PTR_W-1:0] biz_wr, biz_rd;
    logic [BIZ_CNT_W-1:0] biz_count;

    // -------------------------------------------------------------------------
    // TX 编码状态
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        T_IDLE,
        T_LEAD,
        T_BODY,
        T_ESC,
        T_TRAIL
    } tx_state_t;

    tx_state_t tx_state;
    logic [7:0]  tx_type;
    logic [15:0] tx_seq;
    logic [31:0] tx_session;
    logic [5:0]  tx_len;
    logic [255:0] tx_payload;
    logic [15:0] tx_crc;
    logic [5:0]  tx_body_idx;

    // -------------------------------------------------------------------------
    // SLIP / header 组合逻辑
    // -------------------------------------------------------------------------
    assign rx_ready = rst_n && !flush;

    wire rx_fire = rx_valid && rx_ready;

    wire [7:0] unescaped_byte =
        (rx_data == SLIP_ESC_END) ? SLIP_END :
        (rx_data == SLIP_ESC_ESC) ? SLIP_ESC : rx_data;
    wire [7:0] dec_byte = esc_pending ? unescaped_byte : rx_data;
    wire [15:0] len_full = {dec_byte, cand_len[7:0]};

    wire at_frame_end = rx_fire && (state == S_DECODE) && !esc_pending &&
                        (rx_data == SLIP_END) && (body_count != 6'd0);

    wire frame_len_ok = (body_count == (6'd12 + cand_len[5:0]));
    wire frame_crc_ok = ({crc_hi, crc_lo} == crc_calc);
    wire frame_ok     = at_frame_end && frame_len_ok && frame_crc_ok;

    wire frame_is_ctrl = frame_ok && (cand_type == TYPE_CONTROL);
    wire frame_is_biz  = frame_ok && (cand_type != TYPE_CONTROL);

    // -------------------------------------------------------------------------
    // 队列输出 / 握手
    // -------------------------------------------------------------------------
    assign ctrl_valid   = (ctrl_count != '0) && !flush;
    assign ctrl_seq     = ctrl_seq_mem[ctrl_rd];
    assign ctrl_session = ctrl_sess_mem[ctrl_rd];
    assign ctrl_len     = ctrl_len_mem[ctrl_rd];
    assign ctrl_payload = ctrl_mem[ctrl_rd];

    assign biz_valid    = (biz_count != '0) && !flush;
    assign biz_type     = biz_type_mem[biz_rd];
    assign biz_seq      = biz_seq_mem[biz_rd];
    assign biz_session  = biz_sess_mem[biz_rd];
    assign biz_len      = biz_len_mem[biz_rd];
    assign biz_payload  = biz_mem[biz_rd];

    wire ctrl_pop = ctrl_valid && ctrl_ready && !flush;
    wire biz_pop  = biz_valid  && biz_ready  && !flush;

    // 队列满但同拍有消费者取走时仍可接收当前帧；读写同一槽位是安全的，
    // 因为输出组合读的是写入前的旧值。
    wire ctrl_has_room = (ctrl_count < CONTROL_DEPTH) || ctrl_pop;
    wire biz_has_room  = (biz_count  < FRAME_DEPTH)  || biz_pop;

    wire ctrl_push = frame_is_ctrl && ctrl_has_room;
    wire biz_push  = frame_is_biz  && biz_has_room;
    wire frame_ovf = (frame_is_ctrl && !ctrl_has_room) ||
                     (frame_is_biz  && !biz_has_room);

    // -------------------------------------------------------------------------
    // RX 候选帧 / 错误状态机
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_HUNT;
            body_count   <= 6'd0;
            crc_calc     <= 16'hFFFF;
            crc_lo       <= 8'h00;
            crc_hi       <= 8'h00;
            cand_type    <= 8'h00;
            cand_seq     <= 16'h0000;
            cand_len     <= 16'h0000;
            cand_session <= 32'h00000000;
            cand_payload <= 256'd0;
            esc_pending  <= 1'b0;
            timeout_cnt  <= '0;
            errors       <= 8'h00;
        end else if (flush) begin
            state        <= S_HUNT;
            body_count   <= 6'd0;
            crc_calc     <= 16'hFFFF;
            crc_lo       <= 8'h00;
            crc_hi       <= 8'h00;
            cand_type    <= 8'h00;
            cand_seq     <= 16'h0000;
            cand_len     <= 16'h0000;
            cand_session <= 32'h00000000;
            cand_payload <= 256'd0;
            esc_pending  <= 1'b0;
            timeout_cnt  <= '0;
            errors       <= 8'h00;
        end else begin
            errors <= 8'h00;

            if (rx_fire) begin
                timeout_cnt <= '0;

                case (state)
                    // -----------------------------------------------------------------
                    S_HUNT: begin
                        if (rx_data == SLIP_END) begin
                            body_count   <= 6'd0;
                            crc_calc     <= 16'hFFFF;
                            crc_lo       <= 8'h00;
                            crc_hi       <= 8'h00;
                            cand_type    <= 8'h00;
                            cand_seq     <= 16'h0000;
                            cand_len     <= 16'h0000;
                            cand_session <= 32'h00000000;
                            cand_payload <= 256'd0;
                            esc_pending  <= 1'b0;
                            state        <= S_DECODE;
                        end
                    end

                    // -----------------------------------------------------------------
                    S_DECODE: begin
                        if (!esc_pending && (rx_data == SLIP_ESC)) begin
                            esc_pending <= 1'b1;
                        end else if (!esc_pending && (rx_data == SLIP_END)) begin
                            // 帧边界。空 body 直接忽略，C0 同时可作为下一帧前导。
                            if (body_count == 6'd0) begin
                                body_count   <= 6'd0;
                                crc_calc     <= 16'hFFFF;
                                crc_lo       <= 8'h00;
                                crc_hi       <= 8'h00;
                                cand_type    <= 8'h00;
                                cand_seq     <= 16'h0000;
                                cand_len     <= 16'h0000;
                                cand_session <= 32'h00000000;
                                cand_payload <= 256'd0;
                                esc_pending  <= 1'b0;
                                state        <= S_DECODE;
                            end else if (!frame_len_ok) begin
                                errors       <= ERR_LEN;
                                body_count   <= 6'd0;
                                crc_calc     <= 16'hFFFF;
                                crc_lo       <= 8'h00;
                                crc_hi       <= 8'h00;
                                cand_type    <= 8'h00;
                                cand_seq     <= 16'h0000;
                                cand_len     <= 16'h0000;
                                cand_session <= 32'h00000000;
                                cand_payload <= 256'd0;
                                esc_pending  <= 1'b0;
                                state        <= S_DECODE;
                            end else if (!frame_crc_ok) begin
                                errors       <= ERR_CRC;
                                body_count   <= 6'd0;
                                crc_calc     <= 16'hFFFF;
                                crc_lo       <= 8'h00;
                                crc_hi       <= 8'h00;
                                cand_type    <= 8'h00;
                                cand_seq     <= 16'h0000;
                                cand_len     <= 16'h0000;
                                cand_session <= 32'h00000000;
                                cand_payload <= 256'd0;
                                esc_pending  <= 1'b0;
                                state        <= S_DECODE;
                            end else begin
                                if (frame_ovf)
                                    errors <= ERR_OVF;
                                body_count   <= 6'd0;
                                crc_calc     <= 16'hFFFF;
                                crc_lo       <= 8'h00;
                                crc_hi       <= 8'h00;
                                cand_type    <= 8'h00;
                                cand_seq     <= 16'h0000;
                                cand_len     <= 16'h0000;
                                cand_session <= 32'h00000000;
                                cand_payload <= 256'd0;
                                esc_pending  <= 1'b0;
                                state        <= S_DECODE;
                            end
                        end else if (esc_pending && (rx_data == SLIP_END)) begin
                            // DB C0 非法，但这个 C0 是帧边界，立即重新同步。
                            errors      <= ERR_SLIP;
                            body_count  <= 6'd0;
                            crc_calc    <= 16'hFFFF;
                            crc_lo      <= 8'h00;
                            crc_hi      <= 8'h00;
                            cand_type   <= 8'h00;
                            cand_seq    <= 16'h0000;
                            cand_len    <= 16'h0000;
                            cand_session<= 32'h00000000;
                            cand_payload<= 256'd0;
                            esc_pending <= 1'b0;
                            state       <= S_DECODE;
                        end else if (esc_pending &&
                                     (rx_data != SLIP_ESC_END) &&
                                     (rx_data != SLIP_ESC_ESC)) begin
                            // 非法 DB xx：丢弃到下一个未转义 C0。
                            errors       <= ERR_SLIP;
                            body_count   <= 6'd0;
                            esc_pending  <= 1'b0;
                            state        <= S_DISCARD;
                        end else begin
                            // 一个合法 body 字节（可能来自 DB DC / DB DD）。
                            esc_pending <= 1'b0;

                            if (body_count == 6'd0) begin
                                if (dec_byte != WIRE_VERSION) begin
                                    errors <= ERR_VER;
                                    state  <= S_DISCARD;
                                end
                                crc_calc   <= crc16_byte(16'hFFFF, dec_byte);
                                body_count <= 6'd1;
                            end else if (body_count == 6'd1) begin
                                cand_type <= dec_byte;
                                if ((dec_byte != TYPE_MIDI) &&
                                    (dec_byte != TYPE_CONFIG) &&
                                    (dec_byte != TYPE_CONTROL)) begin
                                    errors <= ERR_VER;
                                    state  <= S_DISCARD;
                                end
                                crc_calc   <= crc16_byte(crc_calc, dec_byte);
                                body_count <= 6'd2;
                            end else if (body_count == 6'd2) begin
                                cand_seq[7:0] <= dec_byte;
                                crc_calc      <= crc16_byte(crc_calc, dec_byte);
                                body_count    <= 6'd3;
                            end else if (body_count == 6'd3) begin
                                cand_seq[15:8] <= dec_byte;
                                crc_calc       <= crc16_byte(crc_calc, dec_byte);
                                body_count     <= 6'd4;
                            end else if (body_count == 6'd4) begin
                                cand_len[7:0] <= dec_byte;
                                crc_calc      <= crc16_byte(crc_calc, dec_byte);
                                body_count    <= 6'd5;
                            end else if (body_count == 6'd5) begin
                                cand_len[15:8] <= dec_byte;
                                crc_calc       <= crc16_byte(crc_calc, dec_byte);
                                body_count     <= 6'd6;

                                if ((len_full == 16'd0) || (len_full > 16'd32) ||
                                    ((cand_type == TYPE_CONFIG) && (len_full > 16'd16)) ||
                                    ((cand_type == TYPE_MIDI) && (len_full < 16'd3))) begin
                                    errors <= ERR_LEN;
                                    state  <= S_DISCARD;
                                end
                            end else if (body_count < 6'd10) begin
                                // SESSION[31:0]，小端。
                                case (body_count)
                                    6'd6: cand_session[7:0]   <= dec_byte;
                                    6'd7: cand_session[15:8]  <= dec_byte;
                                    6'd8: cand_session[23:16] <= dec_byte;
                                    default: cand_session[31:24] <= dec_byte;
                                endcase
                                crc_calc   <= crc16_byte(crc_calc, dec_byte);
                                body_count <= body_count + 6'd1;
                            end else if (body_count < (6'd10 + cand_len[5:0])) begin
                                cand_payload[{body_count - 6'd10, 3'b000} +: 8] <= dec_byte;
                                crc_calc   <= crc16_byte(crc_calc, dec_byte);
                                body_count <= body_count + 6'd1;
                            end else if (body_count == (6'd10 + cand_len[5:0])) begin
                                crc_lo     <= dec_byte;
                                body_count <= body_count + 6'd1;
                            end else if (body_count == (6'd11 + cand_len[5:0])) begin
                                crc_hi     <= dec_byte;
                                body_count <= body_count + 6'd1;
                            end else begin
                                // 超出 body=LEN+12 的多余字节。
                                errors      <= ERR_LEN;
                                body_count  <= 6'd0;
                                esc_pending <= 1'b0;
                                state       <= S_DISCARD;
                            end
                        end
                    end

                    // -----------------------------------------------------------------
                    S_DISCARD: begin
                        if (!esc_pending && (rx_data == SLIP_END)) begin
                            body_count   <= 6'd0;
                            crc_calc     <= 16'hFFFF;
                            crc_lo       <= 8'h00;
                            crc_hi       <= 8'h00;
                            cand_type    <= 8'h00;
                            cand_seq     <= 16'h0000;
                            cand_len     <= 16'h0000;
                            cand_session <= 32'h00000000;
                            cand_payload <= 256'd0;
                            esc_pending  <= 1'b0;
                            state        <= S_DECODE;
                        end else if (!esc_pending && (rx_data == SLIP_ESC)) begin
                            esc_pending <= 1'b1;
                        end else if (esc_pending) begin
                            esc_pending <= 1'b0;
                        end
                    end

                    default: state <= S_HUNT;
                endcase
            end else if ((state == S_DECODE) &&
                         ((body_count != 6'd0) || esc_pending)) begin
                // 字节间超时只针对已经开始的半帧；空闲/空 body 不计时。
                if (timeout_cnt >= (TIMEOUT_CYCLES - 1)) begin
                    errors       <= ERR_TIMEOUT;
                    body_count   <= 6'd0;
                    cand_type    <= 8'h00;
                    cand_seq     <= 16'h0000;
                    cand_len     <= 16'h0000;
                    cand_session <= 32'h00000000;
                    cand_payload <= 256'd0;
                    esc_pending  <= 1'b0;
                    timeout_cnt  <= '0;
                    state        <= S_DISCARD;
                end else begin
                    timeout_cnt <= timeout_cnt + 1'b1;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // CONTROL 队列
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctrl_wr    <= '0;
            ctrl_rd    <= '0;
            ctrl_count <= '0;
        end else if (flush) begin
            ctrl_wr    <= '0;
            ctrl_rd    <= '0;
            ctrl_count <= '0;
        end else begin
            if (ctrl_push) begin
                ctrl_mem[ctrl_wr]      <= cand_payload;
                ctrl_seq_mem[ctrl_wr]  <= cand_seq;
                ctrl_sess_mem[ctrl_wr] <= cand_session;
                ctrl_len_mem[ctrl_wr]  <= cand_len[5:0];
                if (ctrl_wr == CONTROL_DEPTH - 1)
                    ctrl_wr <= '0;
                else
                    ctrl_wr <= ctrl_wr + 1'b1;
            end
            if (ctrl_pop) begin
                if (ctrl_rd == CONTROL_DEPTH - 1)
                    ctrl_rd <= '0;
                else
                    ctrl_rd <= ctrl_rd + 1'b1;
            end
            case ({ctrl_push, ctrl_pop})
                2'b10:   ctrl_count <= ctrl_count + 1'b1;
                2'b01:   ctrl_count <= ctrl_count - 1'b1;
                default: ctrl_count <= ctrl_count;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // 业务队列
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            biz_wr    <= '0;
            biz_rd    <= '0;
            biz_count <= '0;
        end else if (flush) begin
            biz_wr    <= '0;
            biz_rd    <= '0;
            biz_count <= '0;
        end else begin
            if (biz_push) begin
                biz_mem[biz_wr]      <= cand_payload;
                biz_type_mem[biz_wr] <= cand_type;
                biz_seq_mem[biz_wr]  <= cand_seq;
                biz_sess_mem[biz_wr] <= cand_session;
                biz_len_mem[biz_wr]  <= cand_len[5:0];
                if (biz_wr == FRAME_DEPTH - 1)
                    biz_wr <= '0;
                else
                    biz_wr <= biz_wr + 1'b1;
            end
            if (biz_pop) begin
                if (biz_rd == FRAME_DEPTH - 1)
                    biz_rd <= '0;
                else
                    biz_rd <= biz_rd + 1'b1;
            end
            case ({biz_push, biz_pop})
                2'b10:   biz_count <= biz_count + 1'b1;
                2'b01:   biz_count <= biz_count - 1'b1;
                default: biz_count <= biz_count;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // TX：完整 body 字节生成
    // -------------------------------------------------------------------------
    function automatic logic [7:0] tx_body_byte(
        input logic [5:0]   idx,
        input logic [7:0]   typ,
        input logic [15:0]  seq,
        input logic [31:0]  sess,
        input logic [5:0]   len,
        input logic [255:0] pay,
        input logic [15:0]  crc
    );
        integer pi;
        begin
            if (idx == 6'd0)
                tx_body_byte = WIRE_VERSION;
            else if (idx == 6'd1)
                tx_body_byte = typ;
            else if (idx == 6'd2)
                tx_body_byte = seq[7:0];
            else if (idx == 6'd3)
                tx_body_byte = seq[15:8];
            else if (idx == 6'd4)
                tx_body_byte = {2'b00, len};
            else if (idx == 6'd5)
                tx_body_byte = 8'h00;
            else if (idx == 6'd6)
                tx_body_byte = sess[7:0];
            else if (idx == 6'd7)
                tx_body_byte = sess[15:8];
            else if (idx == 6'd8)
                tx_body_byte = sess[23:16];
            else if (idx == 6'd9)
                tx_body_byte = sess[31:24];
            else if ((idx >= 6'd10) && (idx < (6'd10 + len))) begin
                pi = idx - 6'd10;
                tx_body_byte = pay[pi*8 +: 8];
            end else if (idx == (6'd10 + len))
                tx_body_byte = crc[7:0];
            else if (idx == (6'd11 + len))
                tx_body_byte = crc[15:8];
            else
                tx_body_byte = 8'h00;
        end
    endfunction

    wire [7:0] tx_cur_body = tx_body_byte(
        tx_body_idx, tx_type, tx_seq, tx_session, tx_len, tx_payload, tx_crc);
    wire       tx_body_esc = (tx_cur_body == SLIP_END) || (tx_cur_body == SLIP_ESC);
    wire [7:0] tx_esc_byte = (tx_cur_body == SLIP_END) ? SLIP_ESC_END : SLIP_ESC_ESC;

    assign send_ready = rst_n && !flush && (tx_state == T_IDLE) &&
                        (send_len <= 6'd32);

    assign tx_valid = rst_n && !flush && (tx_state != T_IDLE);

    always_comb begin
        case (tx_state)
            T_LEAD, T_TRAIL: tx_data = SLIP_END;
            T_BODY:          tx_data = tx_body_esc ? SLIP_ESC : tx_cur_body;
            T_ESC:           tx_data = tx_esc_byte;
            default:         tx_data = 8'h00;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_state    <= T_IDLE;
            tx_type     <= 8'h00;
            tx_seq      <= 16'h0000;
            tx_session  <= 32'h00000000;
            tx_len      <= 6'd0;
            tx_payload  <= 256'd0;
            tx_crc      <= 16'hFFFF;
            tx_body_idx <= 6'd0;
        end else if (flush) begin
            tx_state    <= T_IDLE;
            tx_body_idx <= 6'd0;
        end else begin
            case (tx_state)
                T_IDLE: begin
                    if (send_valid && send_ready) begin
                        tx_type     <= send_type;
                        tx_seq      <= send_seq;
                        tx_session  <= send_session;
                        tx_len      <= send_len;
                        tx_payload  <= send_payload;
                        tx_crc      <= 16'hFFFF;
                        tx_body_idx <= 6'd0;
                        tx_state    <= T_LEAD;
                    end
                end

                T_LEAD: begin
                    if (tx_ready)
                        tx_state <= T_BODY;
                end

                T_BODY: begin
                    if (tx_ready) begin
                        if (tx_body_idx < (6'd10 + tx_len))
                            tx_crc <= crc16_byte(tx_crc, tx_cur_body);

                        if (tx_body_esc) begin
                            tx_state <= T_ESC;
                        end else if (tx_body_idx == (6'd11 + tx_len)) begin
                            tx_state <= T_TRAIL;
                        end else begin
                            tx_body_idx <= tx_body_idx + 6'd1;
                        end
                    end
                end

                T_ESC: begin
                    if (tx_ready) begin
                        if (tx_body_idx == (6'd11 + tx_len)) begin
                            tx_state <= T_TRAIL;
                        end else begin
                            tx_body_idx <= tx_body_idx + 6'd1;
                            tx_state    <= T_BODY;
                        end
                    end
                end

                T_TRAIL: begin
                    if (tx_ready)
                        tx_state <= T_IDLE;
                end

                default: tx_state <= T_IDLE;
            endcase
        end
    end

endmodule
