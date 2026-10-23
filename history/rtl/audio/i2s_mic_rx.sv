// -----------------------------------------------------------------------------
// i2s_mic_rx.sv -- 条件性的标准 I2S 数字麦克风接收器（主机）。
//
// 状态：条件性 / 未针对用户硬件验证。用户只
// 描述了一个“7 针麦克风和 2 针扬声器”；实际模块未被
// 识别。本模块实现一个 *标准* I2S 数字麦克风输入
//（例如 INMP441 类），并不声称物理器件与之匹配。
//
// FPGA 是串行主机：它驱动 MIC_BCK = audio_clk/4 = 3.072 MHz 和
// MIC_WS = 48 kHz（每帧 64 个 BCK，32 位时隙）。SD 在 BCK
// 上升沿采样。标准 I2S 一位延迟：声道 MSB 在 WS 边沿
// 之后一个 BCK 被采样。24 位有符号载荷以 MSB 在前的方式移入；
// 第 24 位之后的填充位被忽略。CH_SEL 选择 WS 低（0，左）或
// WS 高（1，右）。
//
// 这不是 PDM，不是 TDM，也不是模拟 ADC；它从不连接到
// 放大器输出。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module i2s_mic_rx #(
    parameter int CH_SEL = 0          // 0 = WS 低（左），1 = WS 高（右）
) (
    input  logic        clk,          // audio_clk（精确 12.288 MHz）
    input  logic        rst_n,        // 与 clk 同步的复位
    input  logic        sd,           // 来自麦克风的串行数据

    output logic        mic_bck,      // 3.072 MHz
    output logic        mic_ws,       // 48 kHz，低 = 左，高 = 右
    output logic [23:0] mic_data,     // 24 位有符号，MSB 在前
    output logic        mic_valid     // mic_data 更新时一个 clk
);

    // t 计数一个 BCK 周期内的 audio_clk 周期数（4 clk -> BCK = clk/4）
    logic [1:0] t;
    // bcnt 计数一个 64-BCK I2S 帧内的 BCK 周期数
    logic [5:0] bcnt;

    logic [23:0] sr;
    logic [23:0] data_r;
    logic        valid_r;

    // 载荷窗口：MSB 在 base+1，LSB 在 base+24
    localparam logic [5:0] BASE = (CH_SEL == 0) ? 6'd0 : 6'd32;
    localparam logic [5:0] LAST = BASE + 6'd24;

    wire rise = (t == 2'd1);     // 使 BCK 上升的 clk 边沿
    wire fall = (t == 2'd3);     // 使 BCK 下降的 clk 边沿

    assign mic_bck = t[1];
    assign mic_ws  = bcnt[5];
    assign mic_data  = data_r;
    assign mic_valid = valid_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            t       <= 2'd0;
            bcnt    <= 6'd0;
            sr      <= 24'd0;
            data_r  <= 24'd0;
            valid_r <= 1'b0;
        end else begin
            t       <= fall ? 2'd0 : (t + 2'd1);
            valid_r <= 1'b0;

            if (fall) begin
                bcnt <= (bcnt == 6'd63) ? 6'd0 : (bcnt + 6'd1);
            end

            if (rise) begin
                if ((bcnt > BASE) && (bcnt <= LAST)) begin
                    sr <= {sr[22:0], sd};
                    if (bcnt == LAST) begin
                        data_r  <= {sr[22:0], sd};
                        valid_r <= 1'b1;
                    end
                end
            end
        end
    end

endmodule
