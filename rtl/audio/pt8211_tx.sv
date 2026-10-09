// -----------------------------------------------------------------------------
// pt8211_tx.sv -- PT8211（Japanese / MSB 在前，无 I2S 一位延迟）发送器。
//
// audio_clk 是精确的 12.288 MHz 音频参考。BCK = audio_clk/8 =
// 1.536 MHz，每帧 32 个 BCK，两个 16 位时隙，因此帧率为 48 kHz。
// 输入对上的字为 {left[15:0], right[15:0]}；单声道演示把
// 同一个 16 位样本送入两半。
//
// 实现的协议（rtl/audio_bringup_design.md 第 3 节，由父会话
// 对照 PT8211 数据手册核对）：
//   * WS 低 = 右，WS 高 = 左
//   * MSB 在前；DIN 和 WS 在 BCK 下降沿变化，并由
//     DAC 在上升沿采样
//   * 没有 I2S 一位延迟：时隙的 MSB 随 WS 边沿
//     本身变化（WS 在与呈现 MSB 相同的下降沿变化）
//   * 时隙 LSB 在该时隙最后一个上升沿之前呈现
//
// 每帧从读侧弹出一个立体声对。在 FIFO 为空时
// 整个帧为零并置位粘滞下溢标志。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module pt8211_tx #(
    parameter int CLK_DIV = 8              // 每个 BCK 周期的 audio_clk 周期数
) (
    input  logic        clk,               // audio_clk（精确 12.288 MHz）
    input  logic        rst_n,             // 与 clk 同步的复位
    input  logic        diag_clear,        // 清除粘滞下溢标志

    // FIFO 读侧（audio_clk 域）
    input  logic        in_valid,
    output logic        in_ready,
    input  logic [31:0] in_data,           // {left[15:0], right[15:0]}

    // 串行输出
    output logic        dac_bck,
    output logic        dac_ws,
    output logic        dac_din,

    // 诊断
    output logic        underflow_pulse,
    output logic        underflow_sticky,
    output logic        frame_tick         // 每个帧起始处一个 clk 脉冲
);

    localparam int T_BITS = (CLK_DIV < 2) ? 1 : $clog2(CLK_DIV);
    localparam int DIV = CLK_DIV;

    // t 计数一个 BCK 周期内的 audio_clk 周期数
    logic [T_BITS-1:0] t;

    // b 是将在接下来的 BCK 周期呈现的位的索引（0..31）
    logic [4:0]        b;

    logic [31:0]       pair;
    logic              ws_r, din_r;
    logic              under_p, under_s;
    logic              frame_p;

    wire update_edge = (t == (DIV - 1'b1));   // BCK 下降沿
    wire first_bit   = (b == 5'd0);

    wire [15:0] cur_slot  = b[4] ? pair[31:16] : pair[15:0];
    wire [15:0] new_slot  = in_valid ? (b[4] ? in_data[31:16] : in_data[15:0])
                                     : 16'd0;
    wire        din_hold  = cur_slot[4'd15 - b[3:0]];   // 所保持对的第 b 位
    wire        din_fresh = new_slot[4'd15 - b[3:0]];   // 新对的第 0 位

    assign dac_bck = (t >= (DIV / 2));
    assign dac_ws  = ws_r;
    assign dac_din = din_r;

    assign in_ready        = update_edge & first_bit;
    assign underflow_pulse = under_p;
    assign underflow_sticky= under_s;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            t        <= {T_BITS{1'b0}};
            b        <= 5'd0;
            pair     <= 32'd0;
            ws_r     <= 1'b0;
            din_r    <= 1'b0;
            under_p  <= 1'b0;
            under_s  <= 1'b0;
            frame_p  <= 1'b0;
        end else begin
            t      <= update_edge ? {T_BITS{1'b0}} : (t + 1'b1);
            under_p<= 1'b0;
            frame_p<= 1'b0;

            if (diag_clear) under_s <= 1'b0;

            if (update_edge) begin
                if (first_bit) begin
                    // 帧边界：弹出下一对并在同一
                    // 下降沿呈现其 MSB（右，WS 低）-- 无 I2S 延迟
                    pair      <= in_valid ? in_data : 32'd0;
                    ws_r      <= 1'b0;
                    din_r     <= din_fresh;
                    b         <= 5'd1;
                    frame_p   <= 1'b1;
                    under_p   <= ~in_valid;
                    // 本帧的下溢优先于同时发生的清零
                    if (!in_valid) under_s <= 1'b1;
                end else begin
                    ws_r      <= b[4];
                    din_r     <= din_hold;
                    b         <= (b == 5'd31) ? 5'd0 : (b + 5'd1);
                end
            end
        end
    end

    // under_p / frame_p 在下降沿之后一个 clk 被寄存；在帧边界
    // 将它们作为干净的单 clk 脉冲暴露。
    assign frame_tick = frame_p;

    // underflow_pulse 是音频域中的一个单 clk 脉冲；粘滞标志
    // 才是传输导出的内容（粘滞电平，绝不跨 CDC 传裸脉冲）。

endmodule
