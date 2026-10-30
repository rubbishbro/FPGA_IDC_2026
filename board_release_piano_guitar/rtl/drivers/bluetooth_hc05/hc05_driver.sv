`timescale 1ns/1ps
// HC-05 透明传输设备包装。独立实例化通用 UART，STATE 只报告事实。
// 模块由外部预先配置；没有 AT FSM，也不把连接事件直接当作业务会话恢复。
module hc05_driver #(
    parameter int CLK_HZ = 100_000_000,
    parameter int BAUD = 115200,
    parameter int OVERSAMPLE = 16,
    parameter int RX_DEPTH = 1024,
    parameter bit HAS_STATE = 1'b0,
    parameter int DEBOUNCE_CYCLES = CLK_HZ / 50
) (
    input logic clk, rst_n,
    input logic rx_i, state_async,
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
    output logic framing_err, break_detect, false_start, overflow,
    output logic link_state_known, link_up, connect_event, disconnect_event,
    output logic init_done
);
    logic status_up;
    uart_driver #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .OVERSAMPLE(OVERSAMPLE),
                  .RX_DEPTH(RX_DEPTH)) u_uart (
        .clk(clk), .rst_n(rst_n), .rx_i(rx_i), .tx_o(tx_o),
        .capture_enable(capture_enable), .flush_rx(flush_rx),
        .rx_valid(rx_valid), .rx_ready(rx_ready), .rx_data(rx_data), .rx_level(rx_level),
        .tx_valid(tx_valid), .tx_ready(tx_ready), .tx_data(tx_data), .tx_busy(tx_busy),
        .framing_err(framing_err), .break_detect(break_detect),
        .false_start(false_start), .overflow(overflow)
    );
    comm_hc05_status #(.HAS_STATE(HAS_STATE), .DEBOUNCE_CYCLES(DEBOUNCE_CYCLES)) u_status (
        .clk(clk), .rst_n(rst_n), .state_async(state_async), .link_up(status_up),
        .connect_event(connect_event), .disconnect_event(disconnect_event)
    );
    // 无 STATE 时是“未知”，而非伪造物理连接；不以该状态门控字节流。
    assign link_state_known = HAS_STATE;
    assign link_up = HAS_STATE && status_up;
    // 仅表示透明数据通路已退出复位，不表示已配对或完成 AT 配置。
    assign init_done = rst_n;
endmodule
