// audio_if.v - Audio sample receiver (48k节拍 in -> write to time_pingpong)
// 2026-09-29 架构重构
//
//  调试期简洁版：pix_clk 单域，48k 节拍由 pix_clk 分频产生（samp_en_i）。
//  wr_clk 与 rd_clk 同为 pix_clk（单域），无跨时钟，同步器在 time_pingpong 内退化。
//  未来接合成器 48k/MCLK 时，替换 wr_clk 为独立音频时钟，跨时钟同步器生效。
module audio_if #(
    parameter WIDTH = 16
) (
    input               clk_i,        // pix_clk（调试期）
    input               rst_ni,

    // 外部音频输入（调试期：ROM播放 / 测试信号；未来：合成器）
    input  [WIDTH-1:0]  audio_in_i,   // 采样数据
    input               samp_en_i,    // 48k 节拍脉冲（pix_clk 分频，同域）

    // 乒乓写接口
    output [WIDTH-1:0]  wr_data_o,
    output              wr_valid_o,   // 每采样 1 拍
    input               wr_ready_i    // 乒乓可写
);

    // 采样有效：节拍且乒乓可写
    // （48k 慢、乒乓几乎恒 ready；若 ready=0 该采样跳过，可接受）
    assign wr_data_o  = audio_in_i;
    assign wr_valid_o = samp_en_i & wr_ready_i;

endmodule