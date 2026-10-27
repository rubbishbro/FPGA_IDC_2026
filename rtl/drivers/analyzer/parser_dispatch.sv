`timescale 1ns/1ps
// 共用一个解析上下文。在选中的解析器退休前，不得放行下一帧
// （仅收完最后一字节，并不等于其待处理事件/ACK 已完成）。
module parser_dispatch #(
    parameter int EQ_BANDS = 3
) (
    input logic clk, rst_n,
    input logic s_valid,
    output logic s_ready,
    input logic [7:0] s_data, s_type,
    input logic [15:0] s_seq,
    input logic [5:0] s_payload_len,
    input logic s_first, s_last, s_source_id,
    output logic admit_new_frame, busy, context_source_id,
    input logic [1:0] session_reset, cancel_source,
    input logic barrier_ready,
    output logic event_valid,
    input logic event_ready,
    output logic [31:0] event_data,
    output logic event_source_id, parse_error,
    output logic cfg_valid,
    input logic cfg_ready,
    output logic cfg_source_id,
    output logic [15:0] cfg_seq,
    output logic [7:0] cfg_command,
    output logic [4:0] cfg_payload_len,
    output logic [127:0] cfg_shadow,
    input logic cfg_done_valid,
    output logic cfg_done_ready,
    input logic [7:0] cfg_result,
    output logic reply_valid,
    input logic reply_ready,
    output logic reply_source_id,
    output logic [15:0] reply_seq,
    output logic [7:0] reply_command, reply_result
);
    typedef enum logic [1:0] {IDLE, FEED, RETIRE} state_t;
    state_t state;
    logic [7:0] type_r;
    logic source_r;
    logic midi_ready, config_ready, midi_done, config_done;
    logic midi_busy, config_busy;
    wire [7:0] route = (state == IDLE) ? s_type : type_r;
    wire feeding = state != RETIRE;
    wire to_midi = feeding && route == 8'h01;
    wire to_config = feeding && route == 8'h02;

    assign s_ready = to_midi ? midi_ready : to_config ? config_ready : feeding;
    assign admit_new_frame = state == IDLE;
    assign busy = state != IDLE;
    assign context_source_id = source_r;

    midi_analyzer u_midi (
        .clk(clk), .rst_n(rst_n), .flush(1'b0),
        .s_valid(s_valid && to_midi), .s_ready(midi_ready), .s_data(s_data),
        .s_first(s_first), .s_last(s_last), .s_source_id(s_source_id),
        .s_payload_len(s_payload_len),
        .event_valid(event_valid), .event_ready(event_ready), .event_data(event_data),
        .event_source_id(event_source_id), .frame_done(midi_done),
        .parse_error(parse_error), .busy(midi_busy)
    );
    config_analyzer #(.EQ_BANDS(EQ_BANDS)) u_config (
        .clk(clk), .rst_n(rst_n),
        .s_valid(s_valid && to_config), .s_ready(config_ready), .s_data(s_data),
        .s_first(s_first), .s_last(s_last), .s_source_id(s_source_id),
        .s_seq(s_seq), .s_payload_len(s_payload_len),
        .session_reset(session_reset), .cancel_source(cancel_source),
        .barrier_ready(barrier_ready),
        .cfg_valid(cfg_valid), .cfg_ready(cfg_ready), .cfg_source_id(cfg_source_id),
        .cfg_seq(cfg_seq), .cfg_command(cfg_command), .cfg_payload_len(cfg_payload_len),
        .cfg_shadow(cfg_shadow), .cfg_done_valid(cfg_done_valid),
        .cfg_done_ready(cfg_done_ready), .cfg_result(cfg_result),
        .reply_valid(reply_valid), .reply_ready(reply_ready),
        .reply_source_id(reply_source_id), .reply_seq(reply_seq),
        .reply_command(reply_command), .reply_result(reply_result),
        .frame_done(config_done), .busy(config_busy)
    );
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            type_r <= '0;
            source_r <= 1'b0;
        end else if (state != IDLE &&
                     ((type_r == 8'h01 && midi_done) ||
                      (type_r == 8'h02 && config_done))) begin
            state <= IDLE;
        end else if (s_valid && s_ready) begin
            if (state == IDLE) begin
                type_r <= s_type;
                source_r <= s_source_id;
            end
            if (s_last) begin
                if (route == 8'h01 || route == 8'h02) state <= RETIRE;
                else state <= IDLE;
            end else
                state <= FEED;
        end
    end
endmodule
