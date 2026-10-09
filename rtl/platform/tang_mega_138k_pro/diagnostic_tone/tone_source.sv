// -----------------------------------------------------------------------------
// tone_source.sv —— 独立诊断音（diagnostic_tone_top）的连续方波采样源。
//
// 范围：本模块是纯音频时钟域发生器。它不属于自动演奏歌曲路径：不读取任何 ROM、FIFO、
// 模态引擎（modal engine）、体滤波器（body filter）或麦克风，也绝不替代主工程。它存在
// 的唯一目的是让板级 bring-up 在没有核心逻辑的情况下听到一个稳定、已知的音调。
//
// 接口 / 握手
//   * `ready` 是来自 i2s_amp_tx.in_ready 的单周期消费选通（每 64-BCLK 的 I2S 帧在 BCLK
//     下降沿边界拉高一次）。
//   * `pcm` 由当前 `phase` 组合产生，因此消费者在 `ready` 为高的同一周期锁存它；握手
//     推动相位前进。
//   * 每次被接受的握手使 `phase` 从 0 前进到 47，到 47 后回绕到 0。
//   * `phase < 24` -> +1024 (16'h0400)，否则 -1024 (16'hfc00)，即 50% 占空比方波，幅度
//     1024 LSB = -30.10 dBFS (20*log10(1/32))。
//   * {sample,sample} 被放到左、右两半，使单声道音调与声道无关（与 i2s_amp_tx 的单声道
//     复制到两个声道的行为一致）。
//   * `started` 在第一次被接受的握手后粘滞，仅在复位时清除。板级 top 用它来门控放大器
//     SD 引脚：失锁后复位同步器会清除它，只有在重新锁定后接受第一帧时才重新置位。
//
// 频率（音频时钟 12.5 MHz，i2s_amp_tx 中 CLK_DIV=4）：
//   LRC/帧    = 12.5 MHz / 4 / 64 = 48828.125 Hz
//   音调      = 48828.125 / 48      = 1017.252604166... Hz
// 注意：12.5 MHz 是真实的 Gowin PLL 输出，并非 12.288 MHz 音频参考。因此音调也偏高
// 约 1.725%；这是诊断 bring-up 辅助手段，不是校准过的 48 kHz 源。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

// 相位计数器和组合选择器
module tone_source (
    input  logic        clk,        // 音频时钟 (clk_audio)
    input  logic        rst_n,      // 音频域低有效复位（来自 top）
    input  logic        ready,      // 单周期消费选通 (i2s_amp_tx.in_ready)

    output logic [31:0] pcm,        // {left[15:0], right[15:0]}；两半相等
    output logic        started     // 在第一次被接受的握手后粘滞
);

    // 每个 LRC 周期 48 次握手 = 24 个高电平采样 + 24 个低电平采样。
    localparam logic [5:0] PHASE_LAST = 6'd47;
    localparam logic [5:0] PHASE_HALF = 6'd24;
    localparam logic [15:0] AMP_POS  = 16'h0400;   // +1024 = -30.10 dBFS
    localparam logic [15:0] AMP_NEG  = 16'hfc00;   // -1024（二进制补码）

    logic [5:0]  phase;
    logic        started_r;
    logic [15:0] sample;

    // 当前相位的采样。消费者在 `ready` 为高的同一周期读取它，因此传输和相位步进
    // 是同一次握手。
    always_comb sample = (phase < PHASE_HALF) ? AMP_POS : AMP_NEG;

    // 两个 16 位半部分中相同的单声道采样。
    assign pcm = {sample, sample};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase     <= 6'd0;
            started_r <= 1'b0;
        end else if (ready) begin
            phase     <= (phase == PHASE_LAST) ? 6'd0 : (phase + 6'd1);
            started_r <= 1'b1;
        end
    end

    assign started = started_r;

endmodule
