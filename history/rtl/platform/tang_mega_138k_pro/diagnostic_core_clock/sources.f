// clock_probe_top 综合文件列表（独立核心时钟观测工程 diagnostic_core_clock）。
//
// 路径相对于仓库根目录（SOURCE_ROOT）。gowin_build.tcl 以本文件为唯一清单：逐行解析、
// 解析为 SOURCE_ROOT 下的绝对路径、并校验文件存在；任一缺失或逃出 SOURCE_ROOT 即 abort。
//
// 只读引用现有真实厂商 PLL IP：核心 100 MHz PLL 的两个 v 文件 + PLL_INIT 支持。
// 不引入音频 PLL、行为模型、歌曲/核心/音频 RTL。
// 生产 IP 文件 SHA 必须与冻结快照逐个一致（父会话核对）。
//
// 本文件不进入 Gowin 工程；构建 Tcl 自行读取并 add_file 解析后的绝对路径。

// 独立观测顶层（clock_probe_top）
rtl/platform/tang_mega_138k_pro/diagnostic_core_clock/top.sv

// 生成的 Gowin PLL IP（综合前必须存在；只读引用现有文件）
rtl/platform/tang_mega_138k_pro/ip/pll_init.v
rtl/platform/tang_mega_138k_pro/ip/pll_core_100m/gowin_pll_core_100m.v
rtl/platform/tang_mega_138k_pro/ip/pll_core_100m/gowin_pll_core_100m_mod.v

// 引脚/时序约束
rtl/platform/tang_mega_138k_pro/diagnostic_core_clock/clock_probe.cst
rtl/platform/tang_mega_138k_pro/diagnostic_core_clock/clock_probe.sdc
