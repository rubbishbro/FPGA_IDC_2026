`timescale 1ns/1ps
// =============================================================================
// comm_hc05_status : HC-05 STATE 输入的同步与去抖。
//
// - HAS_STATE=1：state_async 先用两级触发器同步，再连续 DEBOUNCE_CYCLES 个
//   系统时钟周期去抖。link_up 跟随去抖后的值；connect_event/disconnect_event
//   是去抖后的 0→1 / 1→0 跳变产生的单拍脉冲。
// - HAS_STATE=0：link_up 固定为高，不产生连接/断开事件。空闲 UART 永远不会
//   被当作断线。
// - 本模块从不对单个 UART 字节做门控。
// =============================================================================
module comm_hc05_status #(
    parameter bit HAS_STATE       = 1'b1,
    parameter int DEBOUNCE_CYCLES = 2_000_000
) (
    input  logic clk,
    input  logic rst_n,
    input  logic state_async,

    output logic link_up,
    output logic disconnect_event,
    output logic connect_event
);

    generate
        if (HAS_STATE) begin : g_state
            localparam int EFF_DEBOUNCE =
                (DEBOUNCE_CYCLES < 1) ? 1 : DEBOUNCE_CYCLES;
            localparam int CNT_W =
                (EFF_DEBOUNCE <= 1) ? 1 : $clog2(EFF_DEBOUNCE);
            localparam logic [CNT_W-1:0] CNT_MAX = CNT_W'(EFF_DEBOUNCE - 1);

            (* ASYNC_REG = "TRUE" *) logic state_meta;
            (* ASYNC_REG = "TRUE" *) logic state_sync;

            logic [CNT_W-1:0] debounce_cnt;
            logic             debounced;

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    state_meta    <= 1'b0;
                    state_sync    <= 1'b0;
                    debounce_cnt  <= '0;
                    debounced     <= 1'b0;
                    link_up       <= 1'b0;
                    disconnect_event <= 1'b0;
                    connect_event    <= 1'b0;
                end else begin
                    disconnect_event <= 1'b0;
                    connect_event    <= 1'b0;

                    state_meta <= state_async;
                    state_sync <= state_meta;

                    if (state_sync == debounced) begin
                        debounce_cnt <= '0;
                    end else if (debounce_cnt == CNT_MAX) begin
                        debounce_cnt <= '0;
                        debounced    <= state_sync;
                        link_up      <= state_sync;
                        if (state_sync)
                            connect_event <= 1'b1;
                        else
                            disconnect_event <= 1'b1;
                    end else begin
                        debounce_cnt <= debounce_cnt + 1'b1;
                    end
                end
            end
        end else begin : g_no_state
            assign link_up          = 1'b1;
            assign disconnect_event = 1'b0;
            assign connect_event    = 1'b0;
        end
    endgenerate

endmodule
