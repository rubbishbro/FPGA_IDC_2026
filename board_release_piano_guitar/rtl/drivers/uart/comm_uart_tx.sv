`timescale 1ns/1ps
// =============================================================================
// comm_uart_tx : 8N1 UART 发送器，位定时由小数 NCO 产生。
//
// - 只有空闲时 s_ready 才为高，因此字节一旦被接收，就一定会完整发出。
//   本模块有意不提供 flush 端口。
// - 空闲时线路为高。帧格式：起始位(0)、data[0..7] 低位先发、停止位(1)。
// - 位周期由 NCO 时钟使能产生；不生成派生时钟，也不使用纯整数分频。
// =============================================================================
module comm_uart_tx #(
    parameter int CLK_HZ = 100_000_000,
    parameter int BAUD   = 115_200
) (
    input  logic       clk,
    input  logic       rst_n,

    input  logic       s_valid,
    output logic       s_ready,
    input  logic [7:0] s_data,

    output logic       tx_o,
    output logic       busy
);

    // ---------------------------------------------------------------------
    // 小数位 tick（NCO）。宽位宽运算只在展开阶段完成。
    // ---------------------------------------------------------------------
    localparam int NCO_W = 24;

    localparam longint unsigned BIT_NUM = 64'd1 * BAUD;
    localparam longint unsigned BIT_DEN = 64'd1 * CLK_HZ;
    localparam longint unsigned NCO_INC_CALC =
        ((BIT_NUM << NCO_W) + (BIT_DEN / 2)) / BIT_DEN;
    localparam logic [NCO_W:0] NCO_INC = NCO_INC_CALC;

    logic [NCO_W-1:0] phase_acc;
    logic [NCO_W:0]   phase_sum;
    logic             tick;

    typedef enum logic [2:0] {
        T_IDLE,
        T_START,
        T_DATA,
        T_STOP,
        T_END
    } state_t;

    state_t state;
    logic [7:0] data_q;
    logic [2:0] bit_idx;

    assign s_ready = !busy;

    wire accept = s_valid && s_ready;
    wire nco_rst = (state == T_IDLE) && accept;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= T_IDLE;
            data_q  <= '0;
            bit_idx <= '0;
            tx_o    <= 1'b1;
            busy    <= 1'b0;
        end else begin
            case (state)
                T_IDLE: begin
                    tx_o <= 1'b1;
                    if (s_valid) begin
                        data_q  <= s_data;
                        bit_idx <= '0;
                        busy    <= 1'b1;
                        tx_o    <= 1'b0;       // start bit
                        state   <= T_START;
                    end
                end

                T_START: begin
                    if (tick) begin
                        tx_o    <= data_q[0];
                        bit_idx <= 3'd1;
                        state   <= T_DATA;
                    end
                end

                T_DATA: begin
                    if (tick) begin
                        tx_o <= data_q[bit_idx];
                        if (bit_idx == 3'd7) begin
                            state <= T_STOP;
                        end else begin
                            bit_idx <= bit_idx + 1'b1;
                        end
                    end
                end

                T_STOP: begin
                    if (tick) begin
                        tx_o  <= 1'b1;         // stop bit begins
                        state <= T_END;
                    end
                end

                T_END: begin
                    if (tick) begin
                        tx_o  <= 1'b1;         // one full stop bit completed
                        busy  <= 1'b0;
                        state <= T_IDLE;
                    end
                end

                default: begin
                    state <= T_IDLE;
                    tx_o  <= 1'b1;
                    busy  <= 1'b0;
                end
            endcase
        end
    end

    // ---------------------------------------------------------------------
    // NCO 相位累加器。接收新字节时复位。
    // ---------------------------------------------------------------------
    assign phase_sum = {1'b0, phase_acc} + NCO_INC;
    assign tick      = phase_sum[NCO_W];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            phase_acc <= '0;
        else if (nco_rst)
            phase_acc <= '0;
        else
            phase_acc <= phase_sum[NCO_W-1:0];
    end

endmodule
