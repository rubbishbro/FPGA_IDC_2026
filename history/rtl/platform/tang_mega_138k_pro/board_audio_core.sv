// -----------------------------------------------------------------------------
// board_audio_core.sv -- 围绕音频会话的 audio_demo_core 的平台包装，
// 对外暴露板级所需的播放握手信号。
//
// audio_demo_core 由音频实现者拥有，这里只读使用。
// 它必须提供以下公共输出
//
//   playback_ready : 首个真实样本（core_tx_valid &&
//                    core_tx_ready）被推入 TX FIFO 后粘滞为 1，而
//                    rst_n 为低时保持为 0
//
// 板级顶层用它（而不是 48 kHz 帧节拍）来使能功放，
// 这样声部装载失败或歌曲卡死都不会让 SD 保持高电平。在音频会话
// 落地该端口之前，本包装让综合无法静默通过：
// 缺失的连接是编译错误，而不是回退。
//
// 仅供测试的 sim/audio_helpers/board_audio_core_model.sv 通过接入真实核心的
// 内部 TX 握手来提供相同的模块接口；它只被
// sim/test_audio_board.py 使用，且从不出现在 sources.f 中。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module board_audio_core #(
    parameter int NUM_VOICES = 32,
    parameter int N_MODES    = 48,
    parameter int NOTE_GAP   = 12000,
    parameter int ENABLE_BODY = 0,
    parameter int BODY_INSTRUMENT = 0,
    parameter COEFF_FILE = "rtl/rom/modal_coeff.mem",
    parameter INDEX_FILE = "rtl/rom/modal_index.mem",
    parameter BODY_FILE  = "rtl/rom/body_coeff.mem"
) (
    input  logic clk_core,
    input  logic clk_audio,
    input  logic rst_n,

    output logic playback_ready,   // 首次 TX FIFO 握手后粘滞置位，复位为 0
    output logic dac_bck,
    output logic dac_ws,
    output logic dac_din
);

    audio_demo_core #(
        .NUM_VOICES(NUM_VOICES),
        .N_MODES   (N_MODES),
        .NOTE_GAP  (NOTE_GAP),
        .MODE_SONG (1),
        .OUT_FORMAT(1),
        .ENABLE_BODY(ENABLE_BODY),
        .BODY_INSTRUMENT(BODY_INSTRUMENT),
        .COEFF_FILE(COEFF_FILE),
        .INDEX_FILE(INDEX_FILE),
        .BODY_FILE (BODY_FILE)
    ) u_core (
        .clk_core        (clk_core),
        .clk_audio       (clk_audio),
        .rst_n           (rst_n),
        .diag_clear      (1'b0),
        .mic_sd          (1'b0),
        .dac_bck         (dac_bck),
        .dac_ws          (dac_ws),
        .dac_din         (dac_din),
        .mic_bck         (),
        .mic_ws          (),
        .core_sample_tick(),
        .core_sample_pulse(),
        .underflow_sticky(),
        .overflow_sticky (),
        .tx_overflow_sticky(),
        .deadline_error  (),
        .engine_error_valid(),
        .engine_error_code(),
        .engine_busy     (),
        .playback_ready  (playback_ready)
    );

endmodule
