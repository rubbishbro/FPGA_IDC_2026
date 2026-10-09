// -----------------------------------------------------------------------------
// top.sv —— 独立核心时钟观测（clock_probe_top）：把 100 MHz clk_core 直接引到一根引脚，
// 只用示波器测其高低电平 / 频率 / 占空比。
//
// 这是一个刻意最小化、自包含的 bring-up 设计。它不属于自动演奏歌曲工程，也不例化或替代
// 任何歌曲、FIFO、模态引擎、体滤波器、麦克风、音频 PLL 或 I2S 发送器。它存在的唯一目的
// 是：在不经过核心逻辑的情况下，验证「50 MHz 晶振 -> 真实 Gowin_PLL_core_100M -> 100 MHz
// -> 焊盘」这条物理链路是否能输出一个 100 MHz 方波。
//
// 仅使用真实的板级接口：
//   clk       : 50 MHz 晶振，引脚 P16（与官方示例一致）
//   clk_probe : PMOD2 / J26 第 12 脚 = B21（PMOD2_IO4），100 MHz 观察输出
//   amp_sd    : PMOD2 / J26 第 5  脚 = A17（PMOD2_IO3），常量 0，仅用于把现有
//               MAX98357A 功放置于安全静音/关断状态（SD=0 为 shutdown）
//
// 时钟：只使用现有的真实厂商 PLL IP Gowin_PLL_core_100M（clkin=50 MHz 晶振，
// init_clk=同一 50 MHz 晶振，clkout0=clk_core，lock=未使用）。PLL 参数不改动、
// 不新增行为模型、不接音频 PLL。PLL_ADV 的锁定状态机由现有只读 IP/PLL_INIT 提供
// （见 ip/pll_core_100m/ 与 ip/pll_init.v，均只读引用）。
//
// 输出路径刻意保持直通：assign clk_probe = clk_core —— 不门控、不倒相、不分频、
// 不用 LUT/DFF 再生成。因此综合/布局后该网络应为 PLL CLKOUT0 -> OBUF -> 焊盘，
// 没有内部 100 MHz 的 DSP/RAM/逻辑负载，也不冒充生产内部端点的 MPW 实验。
//
// 复位：本设计不使用板级复位按钮（U4），也不使用其它任何复位端口。U4 的物理极性/
// 有效电平在用户侧尚未闭环，因此这里刻意不接、不假设。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module clock_probe_top (
    input  logic clk,        // 50 MHz 晶振，板级引脚 P16
    output logic clk_probe,  // PMOD2 IO4 / B21 / J26 pin12 -> 100 MHz 观察输出
    output logic amp_sd      // PMOD2 IO3 / A17 / J26 pin5  -> 常量 0，功放安全静音
);

    // ------------------------------------------------------------------
    // 真实厂商 PLL IP（用户生成，位于 .. /ip/）。端口列表与 Gowin V1.9.12.04
    // 生成的完全一致：
    //   Gowin_PLL_core_100M (clkin, init_clk, clkout0, lock)
    // 没有用户 reset/enclk 端口；该 IP 自行启动。lock 此处不使用。
    // ------------------------------------------------------------------
    logic clk_core;          // 100.000 MHz（PLL 核心输出）
    logic pll_lock_unused;   // 真实 PLL 锁定指示，本观测设计刻意不使用

    Gowin_PLL_core_100M u_pll_core (
        .clkin   (clk),
        .init_clk(clk),
        .clkout0 (clk_core),
        .lock    (pll_lock_unused)
    );

    // ------------------------------------------------------------------
    // 100 MHz 直接输出到观察焊盘：不门控 / 不倒相 / 不分频。
    // amp_sd 常量 0：MAX98357A 的 SD 低电平为 shutdown，功放保持静音。
    // ------------------------------------------------------------------
    assign clk_probe = clk_core;
    assign amp_sd    = 1'b0;

endmodule
