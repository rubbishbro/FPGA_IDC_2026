`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// slip_frame_tx -- REPLY（TYPE=80，LEN=3）的 SLIP/CRC 编码器。
//
// 描述符接口：{seq[15:0], command[7:0], result[7:0]}。
// 线上帧：C0 | SLIP(VER=01 TYPE=80 SEQ LEN=0003 PAYLOAD[02,cmd,res] CRC16) | C0。
//
// 编码器只保留每帧的小状态（seq/cmd/result/CRC/index），一次一个字节地送入
// UART 字节流。CRC 对每个解码后的 body 字节更新一次，与线上是否转义无关。
// 尾部 C0 必须交给 UART 后，才能接收下一个描述符。
// -----------------------------------------------------------------------------
module slip_frame_tx (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        flush,

    input  logic        s_valid,
    output logic        s_ready,
    input  logic [15:0] s_seq,
    input  logic [7:0]  s_command,
    input  logic [7:0]  s_result,

    output logic        m_valid,
    input  logic        m_ready,
    output logic [7:0]  m_data,

    output logic        busy
);

    import comm_pkg::*;

    localparam logic [7:0] SLIP_END     = 8'hC0;
    localparam logic [7:0] SLIP_ESC     = 8'hDB;
    localparam logic [7:0] SLIP_ESC_END = 8'hDC;
    localparam logic [7:0] SLIP_ESC_ESC = 8'hDD;

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_LEAD,    // leading C0
        ST_BODY,    // body byte, or DB prefix when it needs escaping
        ST_ESC,     // escaped second wire byte
        ST_TRAIL    // trailing C0
    } tx_state_t;

    tx_state_t state;
    logic [15:0] seq_r;
    logic [7:0]  cmd_r;
    logic [7:0]  res_r;
    logic [15:0] crc_r;
    logic [3:0]  body_idx;

    logic [7:0]  cur_body;
    logic [7:0]  esc_byte;
    logic        body_esc;

    assign s_ready = rst_n && (state == ST_IDLE) && !flush;
    assign m_valid = (state != ST_IDLE);
    assign busy    = (state != ST_IDLE);

    // body 字节，小端：VERSION、TYPE、SEQ、LEN、PAYLOAD、CRC。
    function automatic logic [7:0] body_byte(
        input logic [3:0]  idx,
        input logic [15:0] seq,
        input logic [7:0]  cmd,
        input logic [7:0]  res,
        input logic [15:0] crc
    );
        case (idx)
            4'd0:    body_byte = 8'h01;             // VERSION
            4'd1:    body_byte = TYPE_REPLY;        // 0x80
            4'd2:    body_byte = seq[7:0];
            4'd3:    body_byte = seq[15:8];
            4'd4:    body_byte = 8'h03;             // LEN 低字节
            4'd5:    body_byte = 8'h00;             // LEN 高字节
            4'd6:    body_byte = 8'h02;             // request_type = CONFIG
            4'd7:    body_byte = cmd;
            4'd8:    body_byte = res;
            4'd9:    body_byte = crc[7:0];
            4'd10:   body_byte = crc[15:8];
            default: body_byte = 8'h00;
        endcase
    endfunction

    always @* begin
        cur_body = body_byte(body_idx, seq_r, cmd_r, res_r, crc_r);
        body_esc = (cur_body == SLIP_END) || (cur_body == SLIP_ESC);
        if (cur_body == SLIP_END)
            esc_byte = SLIP_ESC_END;
        else
            esc_byte = SLIP_ESC_ESC; // 仅在 C0 / DB 时使用
    end

    always @* begin
        case (state)
            ST_LEAD, ST_TRAIL: m_data = SLIP_END;
            ST_BODY:           m_data = body_esc ? SLIP_ESC : cur_body;
            ST_ESC:            m_data = esc_byte;
            default:           m_data = 8'h00;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= ST_IDLE;
            seq_r    <= 16'h0000;
            cmd_r    <= 8'h00;
            res_r    <= 8'h00;
            crc_r    <= 16'hFFFF;
            body_idx <= 4'd0;
        end else if (flush) begin
            // 维护取消：放弃当前回复的剩余部分。
            // 若某个字节已在本拍被 UART 接收（m_valid && m_ready），
            // 它已归 UART 所有，不再撤回。
            state <= ST_IDLE;
        end else begin
            case (state)
                ST_IDLE: begin
                    if (s_valid) begin
                        seq_r    <= s_seq;
                        cmd_r    <= s_command;
                        res_r    <= s_result;
                        crc_r    <= 16'hFFFF;
                        body_idx <= 4'd0;
                        state    <= ST_LEAD;
                    end
                end

                ST_LEAD: begin
                    if (m_ready)
                        state <= ST_BODY;
                end

                ST_BODY: begin
                    if (m_ready) begin
                        if (body_idx < 4'd9)
                            crc_r <= crc16_byte(crc_r, cur_body);

                        if (body_esc) begin
                            state <= ST_ESC;       // DB prefix already sent this beat
                        end else if (body_idx == 4'd10) begin
                            state <= ST_TRAIL;
                        end else begin
                            body_idx <= body_idx + 4'd1;
                        end
                    end
                end

                ST_ESC: begin
                    if (m_ready) begin
                        if (body_idx == 4'd10)
                            state <= ST_TRAIL;
                        else begin
                            body_idx <= body_idx + 4'd1;
                            state    <= ST_BODY;
                        end
                    end
                end

                ST_TRAIL: begin
                    if (m_ready)
                        state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
