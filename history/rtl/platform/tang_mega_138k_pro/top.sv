// -----------------------------------------------------------------------------
// top.sv -- Tang Mega 138K Pro 板级顶层，用于自动演奏歌曲的 I2S 输出。
//
// 仅使用真实的板级接口：
//   clk   : 50 MHz 晶振，引脚 P16（取自官方 TangMega-138KPro 示例）
//   reset : 板上复位按钮，引脚 U4，高有效
//   amp_* : PMOD2 / J26 -> 外接 MAX98357A
//            amp_bclk = IO0 / C21, amp_lrc = IO1 / B20,
//            amp_din  = IO2 / B19, amp_sd  = IO3 / A17
//
// 100 MHz 核心时钟与 12.5 MHz 功能调试音频时钟只来自 clock_reset 内部例化的
// Gowin PLL IP。12.5 MHz 并非精确的 12.288 MHz（见 clock_reset.sv 文件头）：
// BCLK 3.125 MHz，LRC 48.828 kHz。不存在把 50 MHz 晶振、测试时钟或分频时钟
// 直接接到引脚上当作核心/音频时钟的路径。
//
// 默认上电状态是 SONG 模式（自动旋律），采用冻结的 32 声部规模。
//
// amp_sd（MAX98357A 关断 / 声道选择；高电平 = 左声道）由
// board_audio_core.playback_ready 门控，即第一个真正送入 TX FIFO 的样本
// ——而不仅仅是一个 48 kHz 节拍。如果声部装载失败或歌曲从未产生样本，
// playback_ready 保持低电平，功放保持关断。
// amp_sd 也会在按钮复位或失锁时组合逻辑地立即拉低。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module top #(
    parameter int NUM_VOICES = 32,
    parameter int N_MODES    = 48,
    parameter int NOTE_GAP   = 12000,
    parameter int ENABLE_BODY = 0,
    parameter int BODY_INSTRUMENT = 0,
    parameter COEFF_FILE = "rtl/rom/modal_coeff.mem",
    parameter INDEX_FILE = "rtl/rom/modal_index.mem",
    parameter BODY_FILE  = "rtl/rom/body_coeff.mem"
) (
    input  logic clk,          // 50 MHz 晶振，P16
    input  logic reset,        // 复位按钮，U4，高有效
    output logic amp_bclk,     // PMOD2 IO0 / C21
    output logic amp_lrc,      // PMOD2 IO1 / B20
    output logic amp_din,      // PMOD2 IO2 / B19
    output logic amp_sd        // PMOD2 IO3 / A17
);

    logic clk_core, clk_audio, locked, rst_n;
    logic playback_ready;
    logic dac_bck, dac_ws, dac_din;

    clock_reset u_clock_reset (
        .clk_50m  (clk),
        .rst_btn  (reset),
        .clk_core (clk_core),
        .clk_audio(clk_audio),
        .locked   (locked),
        .rst_n    (rst_n)
    );

    board_audio_core #(
        .NUM_VOICES(NUM_VOICES),
        .N_MODES   (N_MODES),
        .NOTE_GAP  (NOTE_GAP),
        .ENABLE_BODY(ENABLE_BODY),
        .BODY_INSTRUMENT(BODY_INSTRUMENT),
        .COEFF_FILE(COEFF_FILE),
        .INDEX_FILE(INDEX_FILE),
        .BODY_FILE (BODY_FILE)
    ) u_audio (
        .clk_core      (clk_core),
        .clk_audio     (clk_audio),
        .rst_n         (rst_n),
        .playback_ready(playback_ready),
        .dac_bck       (dac_bck),
        .dac_ws        (dac_ws),
        .dac_din       (dac_din)
    );

    // 功放关断 / 声道选择。playback_ready 是核心的粘滞标志“确有真实样本到达
    // TX FIFO”；再与锁定状态和原始按钮组合，使得无数据恢复（或失锁）时立即保持低电平。
    assign amp_sd   = locked & playback_ready & ~reset;
    assign amp_bclk = dac_bck;
    assign amp_lrc  = dac_ws;
    assign amp_din  = dac_din;

endmodule
