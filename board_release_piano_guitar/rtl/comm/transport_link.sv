`timescale 1ns/1ps
// 单路协议适配：字节 <-> 已验证帧/回复描述符。无引脚、来源号或业务决策。
module transport_link #(
    parameter int FRAME_DEPTH = 8,
    parameter int TIMEOUT_CYCLES = 100000000
) (
    input logic clk, rst_n,
    input logic flush, pin,
    input logic rx_valid,
    output logic rx_ready,
    input logic [7:0] rx_data,
    output logic tx_valid,
    input logic tx_ready,
    output logic [7:0] tx_data,
    output logic frame_valid,
    input logic frame_ready,
    output logic [7:0] frame_data, frame_type,
    output logic [15:0] frame_seq,
    output logic [5:0] frame_payload_len,
    output logic frame_first, frame_last, frame_available,
    output logic [7:0] protocol_errors,
    input logic reply_valid,
    output logic reply_ready,
    input logic [15:0] reply_seq,
    input logic [7:0] reply_command, reply_result,
    output logic tx_busy
);
    logic queued_valid, queued_ready;
    logic [31:0] queued_data;
    logic [1:0] reply_level;
    slip_frame_rx #(.FRAME_DEPTH(FRAME_DEPTH), .TIMEOUT_CYCLES(TIMEOUT_CYCLES)) u_framer (
        .clk(clk), .rst_n(rst_n), .flush(flush), .pin(pin),
        .s_valid(rx_valid), .s_ready(rx_ready), .s_data(rx_data),
        .m_valid(frame_valid), .m_ready(frame_ready), .m_data(frame_data),
        .m_first(frame_first), .m_last(frame_last), .m_type(frame_type),
        .m_seq(frame_seq), .m_payload_len(frame_payload_len),
        .frame_available(frame_available), .err_flags(protocol_errors)
    );
    // 每链路只有这一份回复队列；固定深度 2，保持原有容量。
    comm_fifo #(.WIDTH(32), .DEPTH(2)) u_reply_fifo (
        .clk(clk), .rst_n(rst_n), .flush(flush),
        .s_valid(reply_valid && !flush), .s_ready(reply_ready),
        .s_data({reply_seq, reply_command, reply_result}),
        .m_valid(queued_valid), .m_ready(queued_ready), .m_data(queued_data),
        .level(reply_level)
    );
    slip_frame_tx u_encoder (
        .clk(clk), .rst_n(rst_n), .flush(flush),
        .s_valid(queued_valid), .s_ready(queued_ready), .s_seq(queued_data[31:16]),
        .s_command(queued_data[15:8]), .s_result(queued_data[7:0]),
        .m_valid(tx_valid), .m_ready(tx_ready), .m_data(tx_data), .busy(tx_busy)
    );
endmodule
