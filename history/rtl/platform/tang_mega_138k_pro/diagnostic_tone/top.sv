// -----------------------------------------------------------------------------
// top.sv —— 独立连续诊断音板级 top（Tang Mega 138K Pro）。
//
// 这是一个刻意最小化、自包含的 bring-up 设计。它不是自动演奏歌曲工程，也不例化或替代
// 任何歌曲、FIFO、模态引擎、体滤波器或麦克风逻辑。它的存在是为了用尽可能最小的 RTL
// 检查板子能否产生稳定、已知的 I2S 音调。
//
// 仅使用真实板级接口：
//   clk      : 50 MHz 晶振，引脚 P16
//   amp_*    : PMOD2 / J26 -> 外部 MAX98357A（与主工程相同的 3.3 V 接线）：
//              amp_bclk = C21 (BCLK), amp_lrc = B20 (LRC/WS),
//              amp_din  = B19 (DIN), amp_sd = A17 (shutdown / 声道选择)。
//
// 刻意没有板级复位 / 按键端口（主设计使用 U4）：唯一的状态控制是音频 PLL 锁定。因此
// 本设计不依赖任何按键，也不会因为未确认的按键而被静音。
//
// 时钟：只使用现有的真实 Gowin PLL IP Gowin_PLL_audio_12M5；100 MHz 核心 PLL 不需要
// 也不例化。clk -> 12.5 MHz 音频。12.5 MHz 是真实的厂商 PLL 输出，并非精确的
// 12.288 MHz（见 clock_reset.sv / BOARD_README）：BCLK = 3.125 MHz，LRC = 48.828125 kHz。
// 音调频率为 48828.125/48 = 1017.252604166... Hz，幅度 -30.10 dBFS。
//
// 复位：音频域中的 3FF 同步器在 PLL 报告失锁的瞬间异步置位，并在锁定恢复后同步释放
// （晚 3 个音频时钟）。音调源和 I2S 发送器都使用
//   rst_n = rst_sync[2]
// 即复位释放仅由同步后的最后一级驱动；原始 50 MHz 锁定信号不 AND 进正常状态的 CLEAR
// 树。（把原始锁定信号 AND 进去会让异步锁定绕过同步器，并在每个正常状态寄存器上破坏
// removal。）失去锁定仍会异步清除数据通路：原始 audio_locked 异步清除 rst_sync，其最后
// 一级再异步清除正常状态。重新锁定总是从第一帧重新开始。
//
// amp_sd 由锁定、复位和粘滞的音调 `started` 标志组合门控。它在失锁的同一周期变低，并且
// 只有在重新锁定后接受第一个完整帧后才重新使能。任何按键、ROM 或核心信号都无法将它
// 保持为高。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module diagnostic_tone_top (
    input  logic clk,        // 50 MHz 晶振，板级引脚 P16
    output logic amp_bclk,   // PMOD2 IO0 / C21 -> MAX98357A BCLK
    output logic amp_lrc,    // PMOD2 IO1 / B20 -> MAX98357A LRC/WS
    output logic amp_din,    // PMOD2 IO2 / B19 -> MAX98357A DIN
    output logic amp_sd      // PMOD2 IO3 / A17 -> MAX98357A SD（高 = 左声道）
);

    // ------------------------------------------------------------------
    // 真实厂商 PLL IP（用户生成，位于 ../ip/）。
    // 端口列表与 Gowin V1.9.12.04 生成的完全一致：
    //   Gowin_PLL_audio_12M5 (clkin, init_clk, clkout0, lock)
    // 没有用户复位/enclk 端口；该 IP 自行启动。
    // ------------------------------------------------------------------
    logic clk_audio;        // 12.5 MHz 音频参考
    logic audio_locked;     // PLL 锁定

    Gowin_PLL_audio_12M5 u_pll_audio (
        .clkin   (clk),
        .init_clk(clk),
        .clkout0 (clk_audio),
        .lock    (audio_locked)
    );

    // ------------------------------------------------------------------
    // 音频域复位：3FF，失锁时异步置位，同步释放。rst_sync[2]（同步后的最后一级）是
    // 音调源和 I2S 发送器共享的复位；原始锁定信号仅用作这条专用链的异步清除（以及
    // 下方用于立即静音的 amp_sd），因此它绝不会绕过同步器进入正常状态的 CLEAR。
    // ------------------------------------------------------------------
    logic [2:0] rst_sync;
    logic       rst_n;

    always_ff @(posedge clk_audio or negedge audio_locked)
        if (!audio_locked) rst_sync <= 3'b000;
        else               rst_sync <= {rst_sync[1:0], 1'b1};

    assign rst_n = rst_sync[2];

    // ------------------------------------------------------------------
    // 连续方波音调源（纯音频域）。
    // ------------------------------------------------------------------
    logic [31:0] tone_pcm;
    logic        tone_ready;    // i2s_amp_tx.in_ready 消费选通
    logic        tone_started;  // 粘滞的首次握手标志

    tone_source u_tone (
        .clk    (clk_audio),
        .rst_n  (rst_n),
        .ready  (tone_ready),
        .pcm    (tone_pcm),
        .started(tone_started)
    );

    // ------------------------------------------------------------------
    // 只读复用现有 I2S 发送器。CLK_DIV=4 得到 BCLK = clk_audio/4；in_valid 拉高、
    // diag_clear 拉低，因为本诊断永不欠载且没有单独的清除控制。
    // ------------------------------------------------------------------
    i2s_amp_tx #(
        .CLK_DIV(4)
    ) u_i2s (
        .clk             (clk_audio),
        .rst_n           (rst_n),
        .diag_clear      (1'b0),
        .in_valid        (1'b1),
        .in_ready        (tone_ready),
        .in_data         (tone_pcm),
        .amp_bclk        (amp_bclk),
        .amp_ws          (amp_lrc),
        .amp_din         (amp_din),
        .underflow_pulse (),
        .underflow_sticky(),
        .frame_tick      ()
    );

    // 放大器 shutdown / 声道选择：仅在已锁定、复位已释放且至少接受了一个音调帧时为高。
    // 失锁会在同一周期组合地将其拉低（这里刻意保留原始 audio_locked 以实现立即静音，
    // 而 rst_n 的释放是同步的）。
    assign amp_sd = audio_locked & rst_n & tone_started;

endmodule
