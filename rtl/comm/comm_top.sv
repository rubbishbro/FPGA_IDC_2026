`timescale 1ns/1ps
// 通信集成顶层：设备字节驱动、协议适配、帧路由、共享解析和会话协调。
// 对外端口/参数保持兼容；业务后级通过显式请求/完成接口连接。
module comm_top #(
    parameter int CLK_HZ = 100_000_000,
    parameter int WIRED_BAUD = 115200,
    parameter int BT_BAUD = 115200,
    parameter int OVERSAMPLE = 16,
    parameter int WIRED_OVERSAMPLE = OVERSAMPLE,
    parameter int BT_OVERSAMPLE = OVERSAMPLE,
    parameter int RX_DEPTH = 1024,
    parameter int FRAME_DEPTH = 8,
    parameter int EVENT_DEPTH = 64,
    parameter bit ISOLATE_PROTOCOL_ERRORS = 1'b1,
    parameter int EQ_BANDS = 3,
    parameter int TIMEOUT_CYCLES = CLK_HZ,
    parameter bit BT_HAS_STATE = 1'b0,
    parameter int STATE_DEBOUNCE_CYCLES = CLK_HZ / 50,
    parameter bit BT_PROTOCOL_V2 = 1'b0,
    parameter int BT_HEARTBEAT_CYCLES = 2 * CLK_HZ,
    parameter int BT_PROGRESS_CYCLES = CLK_HZ / 4,
    parameter int BT_ERROR_LIMIT = 8,
    parameter int BT_ERROR_WINDOW_CYCLES = CLK_HZ
) (
    input logic clk, rst_n,
    input logic [1:0] rx_i,
    output logic [1:0] tx_o,
    input logic hc05_state_async,
    input logic [1:0] session_restart,
    input logic [1:0] source_cleanup_done, source_ops_idle,
    input logic midi_ops_idle,
    output logic [1:0] source_quarantine, link_fault_pending,
    output logic [15:0] error_sticky,
    output logic [63:0] rx_error_count,
    output logic event_valid,
    input logic event_ready,
    output logic [31:0] event_data,
    output logic event_source_id,
    output logic midi_parse_error,
    output logic cfg_valid,
    input logic cfg_ready,
    output logic cfg_source_id,
    output logic [15:0] cfg_seq,
    output logic [7:0] cfg_command,
    output logic [4:0] cfg_payload_len,
    output logic [127:0] cfg_shadow,
    input logic cfg_done_valid,
    output logic cfg_done_ready,
    input logic [7:0] cfg_result
);
    localparam int ECW = $clog2(EVENT_DEPTH + 1);
    logic [1:0] byte_rx_valid, byte_rx_ready, byte_tx_valid, byte_tx_ready;
    logic [15:0] byte_rx_data, byte_tx_data;
    logic [1:0] rx_frame_err, rx_break, rx_false_start, rx_overflow;
    logic [1:0] frame_valid, frame_ready, frame_first, frame_last, frame_available;
    logic [15:0] frame_data, frame_type, frame_errors;
    logic [31:0] frame_seq;
    logic [11:0] frame_len;
    logic [1:0] pin, fault_now, restart_req, cancel_source, flush_link, cache_reset;
    logic bt_link_up, bt_state_known, bt_init_done, bt_disconnect, bt_connect;
    logic arb_valid, arb_ready, arb_first, arb_last, arb_source, arb_busy;
    logic [7:0] arb_data, arb_type;
    logic [15:0] arb_seq;
    logic [5:0] arb_len;
    logic dispatch_admit, dispatch_busy, dispatch_source;
    logic parsed_valid, parsed_ready, parsed_source;
    logic [31:0] parsed_data;
    logic ev_valid, ev_ready;
    logic [32:0] ev_data;
    logic [ECW-1:0] ev_level;
    logic reply_valid, reply_ready, reply_source;
    logic [15:0] reply_seq;
    logic [7:0] reply_command, reply_result;
    logic [1:0] reply_space, eligible;
    logic v2_cleanup_request;
    logic [1:0] midi_error_sources;

    uart_driver #(.CLK_HZ(CLK_HZ), .BAUD(WIRED_BAUD),
        .OVERSAMPLE(WIRED_OVERSAMPLE), .RX_DEPTH(RX_DEPTH)) u_wired (
        .clk(clk), .rst_n(rst_n), .rx_i(rx_i[0]), .tx_o(tx_o[0]),
        .capture_enable(!source_quarantine[0]), .flush_rx(flush_link[0]),
        .rx_valid(byte_rx_valid[0]), .rx_ready(byte_rx_ready[0]),
        .rx_data(byte_rx_data[7:0]), .rx_level(),
        .tx_valid(byte_tx_valid[0]), .tx_ready(byte_tx_ready[0]),
        .tx_data(byte_tx_data[7:0]), .tx_busy(),
        .framing_err(rx_frame_err[0]), .break_detect(rx_break[0]),
        .false_start(rx_false_start[0]), .overflow(rx_overflow[0])
    );
    hc05_driver #(.CLK_HZ(CLK_HZ), .BAUD(BT_BAUD),
        .OVERSAMPLE(BT_OVERSAMPLE), .RX_DEPTH(RX_DEPTH), .HAS_STATE(BT_HAS_STATE),
        .DEBOUNCE_CYCLES(STATE_DEBOUNCE_CYCLES)) u_bluetooth (
        .clk(clk), .rst_n(rst_n), .rx_i(rx_i[1]), .tx_o(tx_o[1]),
        .state_async(hc05_state_async),
        // v2 control RX must remain available while business is quarantined.
        .capture_enable(BT_PROTOCOL_V2 || !source_quarantine[1]),
        .flush_rx(!BT_PROTOCOL_V2 && flush_link[1]),
        .rx_valid(byte_rx_valid[1]), .rx_ready(byte_rx_ready[1]),
        .rx_data(byte_rx_data[15:8]), .rx_level(),
        .tx_valid(byte_tx_valid[1]), .tx_ready(byte_tx_ready[1]),
        .tx_data(byte_tx_data[15:8]), .tx_busy(),
        .framing_err(rx_frame_err[1]), .break_detect(rx_break[1]),
        .false_start(rx_false_start[1]), .overflow(rx_overflow[1]),
        .link_state_known(bt_state_known), .link_up(bt_link_up),
        .connect_event(bt_connect), .disconnect_event(bt_disconnect), .init_done(bt_init_done)
    );
    for (genvar g = 0; g < 2; g = g + 1) begin : g_link
        localparam bit SOURCE = (g == 1);
        if (g == 1 && BT_PROTOCOL_V2) begin : g_v2
        transport_v2_link #(.CLK_HZ(CLK_HZ), .FRAME_DEPTH(FRAME_DEPTH),
            .TIMEOUT_CYCLES(TIMEOUT_CYCLES), .HEARTBEAT_CYCLES(BT_HEARTBEAT_CYCLES),
            .PROGRESS_CYCLES(BT_PROGRESS_CYCLES), .ERROR_LIMIT(BT_ERROR_LIMIT),
            .ERROR_WINDOW_CYCLES(BT_ERROR_WINDOW_CYCLES)) u_transport (
            .clk(clk), .rst_n(rst_n), .flush(flush_link[g]), .pin(pin[g]),
            .maintenance_done(cache_reset[g]),
            .physical_fault(rx_frame_err[g] || rx_break[g] || rx_overflow[g] || session_restart[g]),
            .disconnect_event(bt_disconnect), .midi_error(midi_error_sources[g]),
            .cleanup_request(v2_cleanup_request),
            .rx_valid(byte_rx_valid[g]), .rx_ready(byte_rx_ready[g]), .rx_data(byte_rx_data[g*8 +: 8]),
            .tx_valid(byte_tx_valid[g]), .tx_ready(byte_tx_ready[g]), .tx_data(byte_tx_data[g*8 +: 8]),
            .frame_valid(frame_valid[g]), .frame_ready(frame_ready[g]),
            .frame_data(frame_data[g*8 +: 8]), .frame_type(frame_type[g*8 +: 8]),
            .frame_seq(frame_seq[g*16 +: 16]), .frame_payload_len(frame_len[g*6 +: 6]),
            .frame_first(frame_first[g]), .frame_last(frame_last[g]),
            .frame_available(frame_available[g]), .protocol_errors(frame_errors[g*8 +: 8]),
            .reply_valid(reply_valid && reply_source == SOURCE && !cancel_source[g]),
            .reply_ready(reply_space[g]), .reply_seq(reply_seq),
            .reply_command(reply_command), .reply_result(reply_result), .tx_busy()
        );
        end else begin : g_v1
        transport_link #(.FRAME_DEPTH(FRAME_DEPTH), .TIMEOUT_CYCLES(TIMEOUT_CYCLES)) u_transport (
            .clk(clk), .rst_n(rst_n), .flush(flush_link[g]), .pin(pin[g]),
            .rx_valid(byte_rx_valid[g]), .rx_ready(byte_rx_ready[g]),
            .rx_data(byte_rx_data[g*8 +: 8]),
            .tx_valid(byte_tx_valid[g]), .tx_ready(byte_tx_ready[g]),
            .tx_data(byte_tx_data[g*8 +: 8]),
            .frame_valid(frame_valid[g]), .frame_ready(frame_ready[g]),
            .frame_data(frame_data[g*8 +: 8]), .frame_type(frame_type[g*8 +: 8]),
            .frame_seq(frame_seq[g*16 +: 16]), .frame_payload_len(frame_len[g*6 +: 6]),
            .frame_first(frame_first[g]), .frame_last(frame_last[g]),
            .frame_available(frame_available[g]), .protocol_errors(frame_errors[g*8 +: 8]),
            .reply_valid(reply_valid && reply_source == SOURCE && !cancel_source[g]),
            .reply_ready(reply_space[g]), .reply_seq(reply_seq),
            .reply_command(reply_command), .reply_result(reply_result), .tx_busy()
        );
        end
        // 单个配置在途，且只有 analyzer 生产回复；准入检查隐含预留一个回复名额。
        assign eligible[g] = !cancel_source[g] &&
                             ((frame_type[g*8 +: 8] != 8'h02) || reply_space[g]);
    end
    generate if (!BT_PROTOCOL_V2) begin : g_no_v2
        assign v2_cleanup_request = 1'b0;
    end endgenerate

    // 延迟一拍锁存语法错误来源，避免parse_error/flush形成组合环。
    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n) midi_error_sources<=0;
        else midi_error_sources<=midi_parse_error ? (2'b01 << dispatch_source) : 2'b00;
    end
    session_ctrl #(.EVENT_DEPTH(EVENT_DEPTH),.ISOLATE_PROTOCOL_ERRORS(ISOLATE_PROTOCOL_ERRORS),
        .EXTERNAL_MANAGED_BT(BT_PROTOCOL_V2)) u_session (
        .clk(clk), .rst_n(rst_n), .session_restart(session_restart | {v2_cleanup_request, 1'b0}),
        .connect_event({bt_connect && !BT_PROTOCOL_V2, 1'b0}),
        .disconnect_event({bt_disconnect && !BT_PROTOCOL_V2, 1'b0}),
        .framing_err(rx_frame_err), .break_detect(rx_break),
        .overflow(rx_overflow | {BT_PROTOCOL_V2 && frame_errors[13], 1'b0}),
        .protocol_errors(frame_errors), .midi_error(midi_error_sources),
        .source_cleanup_done(source_cleanup_done), .source_ops_idle(source_ops_idle),
        .arb_busy(arb_busy), .arb_source(arb_source),
        .parser_busy(dispatch_busy), .parser_source(dispatch_source),
        .event_push(parsed_valid && parsed_ready), .event_push_source(parsed_source),
        .event_pop(ev_valid && ev_ready), .event_pop_source(ev_data[32]),
        .source_quarantine(source_quarantine), .link_fault_pending(link_fault_pending),
        .fault_now(fault_now), .restart_req(restart_req), .cancel_source(cancel_source),
        .flush_link(flush_link), .cache_reset(cache_reset),
        .error_sticky(error_sticky), .rx_error_count(rx_error_count)
    );

    frame_arbiter u_arbiter (
        .clk(clk), .rst_n(rst_n), .admit_new_frame(dispatch_admit), .eligible(eligible),
        .s_valid(frame_valid), .s_ready(frame_ready), .s_data(frame_data), .s_type(frame_type),
        .s_seq(frame_seq), .s_payload_len(frame_len), .s_first(frame_first), .s_last(frame_last),
        .m_valid(arb_valid), .m_ready(arb_ready), .m_data(arb_data), .m_type(arb_type),
        .m_seq(arb_seq), .m_payload_len(arb_len), .m_first(arb_first), .m_last(arb_last),
        .m_source_id(arb_source), .pin(pin), .busy(arb_busy)
    );
    parser_dispatch #(.EQ_BANDS(EQ_BANDS)) u_dispatch (
        .clk(clk), .rst_n(rst_n), .s_valid(arb_valid), .s_ready(arb_ready),
        .s_data(arb_data), .s_type(arb_type), .s_seq(arb_seq), .s_payload_len(arb_len),
        .s_first(arb_first), .s_last(arb_last), .s_source_id(arb_source),
        .admit_new_frame(dispatch_admit), .busy(dispatch_busy), .context_source_id(dispatch_source),
        .session_reset(cache_reset), .cancel_source(cancel_source),
        .barrier_ready(ev_level == 0 && midi_ops_idle),
        .event_valid(parsed_valid), .event_ready(parsed_ready), .event_data(parsed_data),
        .event_source_id(parsed_source), .parse_error(midi_parse_error),
        .cfg_valid(cfg_valid), .cfg_ready(cfg_ready), .cfg_source_id(cfg_source_id),
        .cfg_seq(cfg_seq), .cfg_command(cfg_command), .cfg_payload_len(cfg_payload_len),
        .cfg_shadow(cfg_shadow), .cfg_done_valid(cfg_done_valid), .cfg_done_ready(cfg_done_ready),
        .cfg_result(cfg_result), .reply_valid(reply_valid), .reply_ready(reply_ready),
        .reply_source_id(reply_source), .reply_seq(reply_seq), .reply_command(reply_command),
        .reply_result(reply_result)
    );
    assign reply_ready = cancel_source[reply_source] || reply_space[reply_source];
    comm_fifo #(.WIDTH(33), .DEPTH(EVENT_DEPTH)) u_event_fifo (
        .clk(clk), .rst_n(rst_n), .flush(1'b0),
        .s_valid(parsed_valid), .s_ready(parsed_ready), .s_data({parsed_source, parsed_data}),
        .m_valid(ev_valid), .m_ready(ev_ready), .m_data(ev_data), .level(ev_level)
    );

    // 输出数据
    assign event_source_id = ev_data[32];
    assign event_data = ev_data[31:0];
    // quarantine 是显式的维护取消，不是普通流反压。
    // 丢弃该来源的旧事件，保留另一来源的事件。
    wire ev_cancel = cancel_source[ev_data[32]];
    assign event_valid = ev_valid && !ev_cancel;
    assign ev_ready = ev_cancel || event_ready;

endmodule
