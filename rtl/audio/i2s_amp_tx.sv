// -----------------------------------------------------------------------------
// i2s_amp_tx.sv -- 用于 MAX98357A D 类放大器的标准 I2S 发送器。
//
// 这是默认的外部播放通路。MAX98357A 是一个标准 I2S
// 单声道 D 类放大器（不是麦克风，也不是 Japanese/LSBJ DAC）：它
// 只需要 BCLK、LRC/WS 和 DIN；它不需要 MCLK。GAIN 和 SD 是
// 配置引脚，绝不是音频数据。
//
// 精确的 12.288 MHz 音频参考：
//   BCLK = clk/4   = 3.072 MHz
//   WS   = BCLK/64 = 48 kHz，32 位时隙，每帧 64 个 BCLK
//   标准 I2S 一位延迟：WS 在 BCLK 下降沿变化，声道
//   MSB 在一个 BCLK 之后呈现（在下一个上升沿采样）
//   WS 低 = 左，WS 高 = 右（标准 I2S）
//   16 位有符号样本示例放在每个 32 位时隙的前导位，其余
//   位为零；相同的单声道样本被复制到两个声道。
//
// 每帧从读侧弹出一个对；空的 FIFO 发送
// 整个零帧并置位粘滞下溢标志。
//
// 本模块故意不配置为 LSBJ/PT8211；那属于
// 单独的 pt8211_tx.sv 通路，必须显式选择。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module i2s_amp_tx #(
    parameter int CLK_DIV = 4               // 每个 BCLK 周期的 audio_clk 周期数
) (
    input  logic        clk,                // audio_clk（精确 12.288 MHz）
    input  logic        rst_n,
    input  logic        diag_clear,

    // FIFO 读侧（audio_clk 域）；单声道样本复制到 L 和 R
    input  logic        in_valid,
    output logic        in_ready,
    input  logic [31:0] in_data,            // {left[15:0], right[15:0]}；单声道 = 任一半

    // 串行输出
    output logic        amp_bclk,
    output logic        amp_ws,
    output logic        amp_din,

    // 诊断
    output logic        underflow_pulse,
    output logic        underflow_sticky,
    output logic        frame_tick
);

    localparam int T_BITS = (CLK_DIV < 2) ? 1 : $clog2(CLK_DIV);
    localparam int DIV = CLK_DIV;

    logic [T_BITS-1:0] t;                   // 一个 BCLK 周期内的 clk 周期数
    logic [5:0]        bcnt;                // I2S 帧内的 0..63 个 BCLK
    logic [15:0]       mono;                // 当前帧的单声道样本
    logic              ws_r, din_r;
    logic              under_p, under_s;
    logic              frame_p;

    wire fall = (t == (DIV - 1'b1));        // BCLK 下降沿
    wire [5:0] nxt = (bcnt == 6'd63) ? 6'd0 : (bcnt + 6'd1);

    // 每个 32 位时隙内的载荷窗口：位 1..16，MSB 在前。对于两半
    // nxt[3:0] 都是 (nxt mod 16)，因此 16-nxt[3:0] (mod 16) 在
    // nxt 为 1..16 和 33..48 时索引载荷的 MSB..LSB。
    wire [4:0] pay_idx5  = 5'd16 - {1'b0, nxt[3:0]};
    wire [3:0] pay_idx   = pay_idx5[3:0];
    wire       in_payload = ((nxt >= 6'd1) && (nxt <= 6'd16)) ||
                            ((nxt >= 6'd33) && (nxt <= 6'd48));
    wire       bit_val    = in_payload ? mono[pay_idx] : 1'b0;

    assign amp_bclk = (t >= (DIV / 2));
    assign amp_ws   = ws_r;
    assign amp_din  = din_r;

    assign in_ready        = fall & (nxt == 6'd0);
    assign underflow_pulse = under_p;
    assign underflow_sticky= under_s;
    assign frame_tick      = frame_p;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            t       <= {T_BITS{1'b0}};
            bcnt    <= 6'd0;
            mono    <= 16'd0;
            ws_r    <= 1'b0;
            din_r   <= 1'b0;
            under_p <= 1'b0;
            under_s <= 1'b0;
            frame_p <= 1'b0;
        end else begin
            t       <= fall ? {T_BITS{1'b0}} : (t + 1'b1);
            under_p <= 1'b0;
            frame_p <= 1'b0;
            if (diag_clear) under_s <= 1'b0;

            if (fall) begin
                bcnt <= nxt;
                if (nxt == 6'd0) begin
                    // 帧边界：弹出下一个单声道样本；此处 WS 为低
                    mono    <= in_valid ? in_data[15:0] : 16'd0;
                    ws_r    <= 1'b0;
                    din_r   <= 1'b0;                    // 1 位延迟 / 无关
                    frame_p <= 1'b1;
                    under_p <= ~in_valid;
                    // 本帧的下溢优先于同时发生的清零
                    if (!in_valid) under_s <= 1'b1;
                end else begin
                    ws_r  <= (nxt >= 6'd32);
                    din_r <= bit_val;
                end
            end
        end
    end

endmodule
