`timescale 1ns/1ps
// =============================================================================
// comm_uart_rx : 8N1 UART 接收器，使用 NCO 时钟使能过采样。
//
// - rx_i 在系统时钟域先用两级触发器同步。
// - 小数 NCO 产生 OVERSAMPLE × BAUD 的 tick，不生成派生时钟。
//   NCO 相位在每个检测到的起始沿复位。
// - 起始位确认：在起始位中心附近采样；若采到高电平，产生单拍 false_start
//   脉冲，并等待线路回到高电平后再寻找下一个起始位。
// - 数据位/停止位在位中心用三样本多数表决采样。
// - rx_stb 是单拍脉冲，只在停止位有效时产生。
// - 停止位无效时产生单拍 framing_err 脉冲，不产生 rx_stb。
// - 若线路持续低电平超过 10.5 个位时间，break_detect 只脉冲一次；随后接收器
//   保持在 S_HOLD 状态，直到线路变高，因此持续 break 期间不会重复产生
//   framing_err/rx_stb/break_detect 脉冲。
// =============================================================================
module comm_uart_rx #(
    parameter int CLK_HZ      = 100_000_000,
    parameter int BAUD        = 115_200,
    parameter int OVERSAMPLE  = 16
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       rx_i,

    output logic       rx_stb,
    output logic [7:0] rx_data,
    output logic       framing_err,
    output logic       break_detect,
    output logic       false_start
);

    // ---------------------------------------------------------------------
    // 小数波特率 tick（NCO）。宽位宽除法只在展开阶段完成。
    // ---------------------------------------------------------------------
    localparam int NCO_W = 24;

    localparam longint unsigned TICK_NUM = 64'd1 * OVERSAMPLE * BAUD;
    localparam longint unsigned TICK_DEN = 64'd1 * CLK_HZ;
    localparam longint unsigned NCO_INC_CALC =
        ((TICK_NUM << NCO_W) + (TICK_DEN / 2)) / TICK_DEN;
    // 保留进位位：当 OVERSAMPLE*BAUD==CLK_HZ 时，应当每个系统时钟产生一个
    // tick，而不是在截断 2**NCO_W 后把增量变成 0。
    localparam logic [NCO_W:0] NCO_INC = NCO_INC_CALC;

    logic [NCO_W-1:0] phase_acc;
    logic [NCO_W:0]   phase_sum;
    logic             tick;

    // ---------------------------------------------------------------------
    // 异步引脚同步。
    // ---------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) logic rx_meta;
    (* ASYNC_REG = "TRUE" *) logic rx_sync;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
        end else begin
            rx_meta <= rx_i;
            rx_sync <= rx_meta;
        end
    end

    // ---------------------------------------------------------------------
    // 接收状态机与 tick 计数器。
    // ---------------------------------------------------------------------
    typedef enum logic [2:0] {
        S_IDLE,
        S_START,
        S_DATA,
        S_STOP,
        S_HOLD,
        S_WAIT_HIGH
    } state_t;

    state_t state;

    localparam int HALF_TICK   = OVERSAMPLE / 2;          // start-bit centre
    localparam int BIT_W       = $clog2(OVERSAMPLE + 2);  // per-bit tick count
    localparam int LOW_W       = $clog2((10 * OVERSAMPLE) + OVERSAMPLE + 2);
    localparam int BREAK_TICKS = (10 * OVERSAMPLE) + (OVERSAMPLE / 2);
    localparam int LOW_LIMIT   = BREAK_TICKS;

    localparam logic [BIT_W-1:0] START_LO   = (HALF_TICK - 1);
    localparam logic [BIT_W-1:0] START_HI   = (HALF_TICK + 1);
    localparam logic [BIT_W-1:0] DATA_LO    = (OVERSAMPLE - 2);
    localparam logic [BIT_W-1:0] DATA_HI    = OVERSAMPLE;
    localparam logic [LOW_W-1:0] LOW_LIMIT_V = LOW_LIMIT;

    logic [BIT_W-1:0] bit_tick;    // ticks since start edge / last bit sample
    logic [LOW_W-1:0] low_ticks;   // ticks since start edge, for break detect
    logic [2:0]       bit_idx;     // 0..7
    logic [1:0]       ones;        // ones from first two samples of a window
    logic [1:0]       samp_idx;    // 0..2
    logic [7:0]       data_q;
    logic             break_issued;

    logic [BIT_W-1:0] tick_idx;

    assign tick_idx = bit_tick + 1'b1;

    wire maj_high = ((ones + rx_sync) >= 2'd2);

    wire start_edge = (state == S_IDLE) && !rx_sync;
    wire nco_rst    = start_edge;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            bit_tick     <= '0;
            low_ticks    <= '0;
            bit_idx      <= '0;
            ones         <= '0;
            samp_idx     <= '0;
            data_q       <= '0;
            break_issued <= 1'b0;
            rx_stb       <= 1'b0;
            rx_data      <= '0;
            framing_err  <= 1'b0;
            break_detect <= 1'b0;
            false_start  <= 1'b0;
        end else begin
            // 默认：每个事件输出都是单拍脉冲。
            rx_stb       <= 1'b0;
            framing_err  <= 1'b0;
            break_detect <= 1'b0;
            false_start  <= 1'b0;

            // 统计经过的 tick。low_ticks 饱和计数；bit_tick 在每次位判决时复位。
            if (tick && (state != S_IDLE) && (state != S_WAIT_HIGH)) begin
                bit_tick <= bit_tick + 1'b1;
                if (!rx_sync && low_ticks != LOW_LIMIT_V)
                    low_ticks <= low_ticks + 1'b1;
            end
            // BREAK 统计的是持续低电平，而不是经过的帧时间。
            // 数据位为高后停止位无效属于 framing error，但还不构成 10.5 位 BREAK。
            if (rx_sync) low_ticks <= '0;

            case (state)
                S_IDLE: begin
                    if (!rx_sync) begin
                        bit_tick     <= '0;
                        low_ticks    <= '0;
                        bit_idx      <= '0;
                        ones         <= '0;
                        samp_idx     <= '0;
                        data_q       <= '0;
                        break_issued <= 1'b0;
                        state        <= S_START;
                    end
                end

                S_START: begin
                    if (tick && (tick_idx >= START_LO) &&
                        (tick_idx <= START_HI)) begin
                        if (samp_idx == 2'd2) begin
                            if (maj_high) begin
                                false_start <= 1'b1;
                                state       <= S_WAIT_HIGH;
                            end else begin
                                state     <= S_DATA;
                                bit_idx   <= '0;
                                bit_tick  <= '0;
                            end
                            samp_idx <= '0;
                            ones     <= '0;
                        end else begin
                            ones     <= ones + rx_sync;
                            samp_idx <= samp_idx + 1'b1;
                        end
                    end
                end

                S_DATA: begin
                    if (tick && (tick_idx >= DATA_LO) &&
                        (tick_idx <= DATA_HI)) begin
                        if (samp_idx == 2'd2) begin
                            data_q[bit_idx] <= maj_high;
                            bit_tick        <= '0;
                            samp_idx        <= '0;
                            ones            <= '0;
                            if (bit_idx == 3'd7)
                                state <= S_STOP;
                            else
                                bit_idx <= bit_idx + 1'b1;
                        end else begin
                            ones     <= ones + rx_sync;
                            samp_idx <= samp_idx + 1'b1;
                        end
                    end
                end

                S_STOP: begin
                    if (tick && (tick_idx >= DATA_LO) &&
                        (tick_idx <= DATA_HI)) begin
                        if (samp_idx == 2'd2) begin
                            bit_tick <= '0;
                            samp_idx <= '0;
                            ones     <= '0;
                            if (maj_high) begin
                                rx_data <= data_q;
                                rx_stb  <= 1'b1;
                                state   <= S_IDLE;
                            end else begin
                                framing_err  <= 1'b1;
                                break_issued <= 1'b0;
                                state        <= S_HOLD;
                            end
                        end else begin
                            ones     <= ones + rx_sync;
                            samp_idx <= samp_idx + 1'b1;
                        end
                    end
                end

                S_HOLD: begin
                    // 在整个持续低电平期间停在这里。每个下降沿只产生一次 break 事件。
                    if (rx_sync) begin
                        state <= S_IDLE;
                    end else if (tick && !break_issued &&
                                 (low_ticks == (LOW_LIMIT_V - 1'b1))) begin
                        break_detect <= 1'b1;
                        break_issued <= 1'b1;
                    end
                end

                S_WAIT_HIGH: begin
                    if (rx_sync)
                        state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // ---------------------------------------------------------------------
    // NCO 相位累加器。每个起始沿复位（前馈相位重置，不是 PLL）。
    // tick 是单拍时钟使能脉冲。
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
