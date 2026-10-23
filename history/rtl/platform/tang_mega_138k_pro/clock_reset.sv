// -----------------------------------------------------------------------------
// clock_reset.sv -- Tang Mega 138K Pro 时钟 / 复位包装。
//
// 板上 50 MHz 晶振（clk，P16）为两个 Gowin PLL IP 模块提供输入，这两个 IP 由
// Gowin IP Core Generator 生成（PLL_ADV，目标 GW5AST-138B / FPG676AES）：
//
//   * Gowin_PLL_core_100M -> clkout0 = 100.000 MHz（核心时钟）
//   * Gowin_PLL_audio_12M5 -> clkout0 = 12.500 MHz（音频参考）
//
// 音频速率注意事项：在此器件上无法从 50 MHz 晶振产生精确的 12.288 MHz
// （PFD 必须为 19-81.25 MHz；不存在精确解）。真实工具生成的 12.5 MHz
// PLL 给出 BCLK 3.125 MHz 和 LRC 48.828125 kHz
// （相对 48 kHz 速率偏差 +1.725% / 音高偏差 +29.6 音分）。它是功能性的
// 上电调试时钟，而非忠实于 48 kHz 的参考；ROM 系数仍是 48
// kHz 那一组，因此诊断比较预计会存在该比例上的差异。
//
// 真实厂商接口，由 Gowin V1.9.12.04 生成：
//     Gowin_PLL_core_100M  (clkin, init_clk, clkout0, lock);
//     Gowin_PLL_audio_12M5 (clkin, init_clk, clkout0, lock);
// `init_clk` 是供该 IP 内部 PLL_INIT 锁定状态机使用的自由运行参考
// （此处为 50 MHz 晶振）。不存在用户侧 `reset`/`enclk*` 端口：该 IP
// 自行启动；板级复位以及“锁定前保持关断”的策略在下面的
// rst_n / 输出级实现。
//
// 生成的文件位于 rtl/platform/tang_mega_138k_pro/ip/ 下，并列在
// sources.f 中。此处绝不能用行为模型替换它们：
// 若 IP 缺失则构建失败。板级仿真使用的仅供测试的替代模型是
// sim/audio_helpers/board_pll_model.sv（相同的端口列表）。
//
// 复位策略：
//   * 高有效的板级按钮立即将 rst_n 拉低；
//   * 只有两个 PLL 都报告 lock 后，才释放 rst_n；
//   * 一旦失锁就组合逻辑地立即拉低 rst_n，使下游
//     逻辑和功放关断引脚立即停止。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module clock_reset (
    input  logic clk_50m,      // 50 MHz 晶振，板级引脚 P16
    input  logic rst_btn,      // 板级复位按钮，引脚 U4，高有效
    output logic clk_core,     // 100 MHz（PLL 核心）
    output logic clk_audio,    // 12.5 MHz（PLL 音频；并非精确的 12.288 -- 见文件头）
    output logic locked,       // 两个 PLL 均已锁定
    output logic rst_n         // 低有效，锁定后释放，失锁时拉低
);

    // ------------------------------------------------------------------
    // 厂商 PLL IP 实例化（由 Gowin 生成；此处不进行仿真）
    // ------------------------------------------------------------------
    logic core_lock, audio_lock;

    Gowin_PLL_core_100M u_pll_core (
        .clkin   (clk_50m),
        .init_clk(clk_50m),
        .clkout0 (clk_core),
        .lock    (core_lock)
    );

    Gowin_PLL_audio_12M5 u_pll_audio (
        .clkin   (clk_50m),
        .init_clk(clk_50m),
        .clkout0 (clk_audio),
        .lock    (audio_lock)
    );

    assign locked = core_lock & audio_lock;

    // ------------------------------------------------------------------
    // 核心域复位释放。按钮或 !locked 时异步拉低，使 rst_n
    // 在失锁的同一周期拉低；锁定后 3 个核心时钟释放。
    // ------------------------------------------------------------------
    logic [2:0] crst_sync;
    always_ff @(posedge clk_core or negedge locked)
        if (!locked) crst_sync <= 3'b000;
        else         crst_sync <= {crst_sync[1:0], 1'b1};

    assign rst_n = crst_sync[2] & locked & ~rst_btn;

endmodule
