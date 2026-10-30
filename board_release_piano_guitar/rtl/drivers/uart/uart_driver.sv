`timescale 1ns/1ps
// 全双工 UART 字节驱动。拥有唯一的 RX 字节 FIFO，不解释任何帧或业务。
// capture_enable/flush_rx 是上层维护命令；普通 ready 反压不能暂停线上接收。
module uart_driver #(
    parameter int CLK_HZ = 100_000_000,
    parameter int BAUD = 115200,
    parameter int OVERSAMPLE = 16,
    parameter int RX_DEPTH = 1024
) (
    input logic clk, rst_n,
    input logic rx_i,
    output logic tx_o,
    input logic capture_enable, flush_rx,
    output logic rx_valid,
    input logic rx_ready,
    output logic [7:0] rx_data,
    output logic [$clog2(RX_DEPTH+1)-1:0] rx_level,
    input logic tx_valid,
    output logic tx_ready,
    input logic [7:0] tx_data,
    output logic tx_busy,
    output logic framing_err, break_detect, false_start, overflow
);
    logic byte_stb, fifo_space;
    logic [7:0] byte_data;

    comm_uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .OVERSAMPLE(OVERSAMPLE)) u_rx (
        .clk(clk), .rst_n(rst_n), .rx_i(rx_i), .rx_stb(byte_stb),
        .rx_data(byte_data), .framing_err(framing_err),
        .break_detect(break_detect), .false_start(false_start)
    );
    // 不依赖 ready/flush，避免 overflow -> 恢复控制 -> flush -> ready 的组合环。
    // 与原顶层一致，满队列同拍 pop 不提供额外写入名额。
    assign overflow = byte_stb && (rx_level == RX_DEPTH) && capture_enable;
    comm_fifo #(.WIDTH(8), .DEPTH(RX_DEPTH)) u_rx_fifo (
        .clk(clk), .rst_n(rst_n), .flush(flush_rx),
        .s_valid(byte_stb && capture_enable && !flush_rx), .s_ready(fifo_space),
        .s_data(byte_data), .m_valid(rx_valid), .m_ready(rx_ready),
        .m_data(rx_data), .level(rx_level)
    );
    // TX 不提供字节中途取消；维护时由上层取消尚未交付的字节。
    comm_uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_tx (
        .clk(clk), .rst_n(rst_n), .s_valid(tx_valid), .s_ready(tx_ready),
        .s_data(tx_data), .tx_o(tx_o), .busy(tx_busy)
    );
endmodule
