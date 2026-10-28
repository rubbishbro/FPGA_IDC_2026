`timescale 1ns/1ps
// 来源会话协调。只依据显式状态/握手计数决定维护命令，不拥有帧/事件数据。
module session_ctrl #(
    parameter int EVENT_DEPTH = 64,
    parameter bit ISOLATE_PROTOCOL_ERRORS = 1'b1
) (
    input logic clk, rst_n,
    input logic [1:0] session_restart, connect_event, disconnect_event,
    input logic [1:0] framing_err, break_detect, overflow,
    input logic [15:0] protocol_errors,
    input logic [1:0] midi_error,
    input logic [1:0] source_cleanup_done, source_ops_idle,
    input logic arb_busy, arb_source, parser_busy, parser_source,
    input logic event_push, event_push_source, event_pop, event_pop_source,
    output logic [1:0] source_quarantine, link_fault_pending,
    output logic [1:0] fault_now, restart_req, cancel_source, flush_link, cache_reset,
    output logic [15:0] error_sticky,
    output logic [63:0] rx_error_count
);
    localparam int ECW = $clog2(EVENT_DEPTH + 1);
    logic [ECW-1:0] pending_events [0:1];
    logic [1:0] restart_pending;
    logic [15:0] error_now;
    assign restart_req = session_restart | connect_event;
    assign source_quarantine = link_fault_pending;
    assign cancel_source = source_quarantine | fault_now | restart_req;
    assign flush_link = fault_now | restart_req | cache_reset;
    for (genvar g = 0; g < 2; g = g + 1) begin : g_source
        assign error_now[g*8 +: 8] = {overflow[g], break_detect[g], framing_err[g],
                                     (protocol_errors[g*8 +: 5] | (midi_error[g]?5'b10000:5'b0))};
        assign fault_now[g] = !source_quarantine[g] &&
            (framing_err[g] || break_detect[g] || overflow[g] ||
             protocol_errors[g*8+4] || disconnect_event[g] ||
             (ISOLATE_PROTOCOL_ERRORS && ((|protocol_errors[g*8 +: 5]) || midi_error[g])));
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            link_fault_pending <= 2'b00;
            restart_pending <= 2'b00;
            cache_reset <= 2'b00;
            error_sticky <= '0;
            rx_error_count <= '0;
            pending_events[0] <= '0;
            pending_events[1] <= '0;
        end else begin
            cache_reset <= 2'b00;
            error_sticky <= error_sticky | error_now;
            for (int i = 0; i < 2; i = i + 1) begin
                if (|error_now[i*8 +: 8])
                    if (rx_error_count[i*32 +: 32] != 32'hffff_ffff)
                        rx_error_count[i*32 +: 32] <= rx_error_count[i*32 +: 32] + 1'b1;
                case ({(event_push && event_push_source == (i == 1)),
                       (event_pop && event_pop_source == (i == 1))})
                    2'b10: pending_events[i] <= pending_events[i] + 1'b1;
                    2'b01: pending_events[i] <= pending_events[i] - 1'b1;
                    default: ;
                endcase
                if (fault_now[i] || restart_req[i]) begin
                    link_fault_pending[i] <= 1'b1;
                    restart_pending[i] <= restart_req[i];
                end else if (source_quarantine[i] && restart_pending[i] &&
                    pending_events[i] == 0 && source_ops_idle[i] && source_cleanup_done[i] &&
                    !(arb_busy && arb_source == (i == 1)) &&
                    !(parser_busy && parser_source == (i == 1))) begin
                    link_fault_pending[i] <= 1'b0;
                    restart_pending[i] <= 1'b0;
                    cache_reset[i] <= 1'b1;
                end
            end
        end
    end
endmodule
